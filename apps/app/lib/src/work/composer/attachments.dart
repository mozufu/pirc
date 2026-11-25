import 'package:crypto/crypto.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pirc_client/pirc_client.dart';

/// A file the user picked, not uploaded yet.
@immutable
class PendingAttachment {
  const PendingAttachment({
    required this.id,
    required this.name,
    required this.mimeType,
    required this.bytes,
  });

  final String id;
  final String name;
  final String mimeType;
  final Uint8List bytes;

  /// As a first-send declaration (with its SHA-256).
  SubmissionAttachment get declaration => SubmissionAttachment(
    id: id,
    name: name,
    mimeType: mimeType,
    byteSize: bytes.length,
    sha256: sha256.convert(bytes).toString(),
  );
}

/// Picks files; the native pickers come in M8, M6 uses `file_selector`.
/// Tests replace it.
final filePickerProvider = Provider<Future<List<PendingAttachment>> Function()>(
  (ref) => () async {
    final files = await openFiles();
    return [
      for (final file in files)
        PendingAttachment(
          id: randomId(),
          name: file.name,
          mimeType: file.mimeType ?? _mimeFor(file.name),
          bytes: await file.readAsBytes(),
        ),
    ];
  },
);

String _mimeFor(String name) {
  final extension = name.split('.').last.toLowerCase();
  return const {
        'png': 'image/png',
        'jpg': 'image/jpeg',
        'jpeg': 'image/jpeg',
        'gif': 'image/gif',
        'webp': 'image/webp',
        'pdf': 'application/pdf',
        'txt': 'text/plain',
        'md': 'text/markdown',
        'json': 'application/json',
      }[extension] ??
      'application/octet-stream';
}
