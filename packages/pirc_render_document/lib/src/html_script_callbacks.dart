import 'dart:convert';

import 'package:pirc_render/pirc_render.dart';
import 'package:pirc_render/src/html_file.dart';
import 'package:pirc_render/src/render_l10n.dart' show tr;

/// The wire format of script callbacks: the messages between a rendered
/// document and its script about picked files and queued actions.
class NativeDocumentScriptCallbacks implements DocumentScriptCallbacks {
  const NativeDocumentScriptCallbacks();

  @override
  List<Map<String, dynamic>> pendingActions(
    List<Map<String, dynamic>> actions,
    int lastConsumed,
  ) => [
    for (final action in actions)
      if (action['sequence'] case final int sequence
          when sequence > lastConsumed)
        action,
  ];

  @override
  void sortFocusActions(List<Map<String, dynamic>> actions) {
    actions.sort((left, right) {
      final sequence = (left['sequence'] as int).compareTo(
        right['sequence'] as int,
      );
      if (sequence != 0) return sequence;
      return ((left['actionOrder'] as int?) ?? 0).compareTo(
        (right['actionOrder'] as int?) ?? 0,
      );
    });
  }

  @override
  (List<Map<String, dynamic>>, int) encodeFiles(
    Iterable<NativeHtmlFile> files,
    int budget,
  ) {
    var remaining = budget;
    final wire = <Map<String, dynamic>>[];
    for (final file in files) {
      final include = file.length <= remaining;
      if (include) remaining -= file.length;
      wire.add({
        'name': file.name,
        'type': file.mimeType,
        'size': file.length,
        'lastModified': file.lastModified,
        if (include)
          'bytesBase64': base64Encode(file.bytes)
        else
          'contentError': tr("選取檔案的腳本內容超過 2 MiB 限制。"),
      });
    }
    return (wire, remaining);
  }

  @override
  DocumentScriptFilePick decodeFilePick(Map<String, dynamic> action) =>
      DocumentScriptFilePick(
        id: action['id'] as int,
        controlId: action['controlId'] as String,
        resetVersion: action['resetVersion'] as String,
        request: NativeHtmlFilePickerRequest(
          accept: (action['accept'] as String)
              .split(',')
              .map((s) => s.trim().toLowerCase())
              .where((s) => s.isNotEmpty)
              .toList(),
          multiple: action['multiple'] as bool,
        ),
      );
}
