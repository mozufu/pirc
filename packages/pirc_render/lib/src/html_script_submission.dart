import 'render_l10n.dart';
import 'dart:convert';
import 'dart:typed_data';

import 'html_file.dart';
import 'html_form_submission.dart';

const _maxInlineFileBytes = 2 * 1024 * 1024;
final _base64Pattern = RegExp(
  r'^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$',
);

/// Decodes captured successful controls, retaining native file bytes outside JS.
/// The runtime freezes values at submission time; a later DOM mutation must not
/// change the request. Encoding and navigation still use the existing native API.
NativeHtmlFormSubmission decodeScriptFormSubmission(
  Map<String, dynamic> action, {
  required NativeHtmlFile? Function(
    String controlId,
    String resetVersion,
    int index,
  )
  resolveFile,
}) {
  String string(String key, [String fallback = '']) {
    final value = action[key];
    if (value == null) return fallback;
    if (value is! String) throw FormatException(tr("Invalid form {0}.", [key]));
    return value;
  }

  final rawEntries = action['entries'];
  if (rawEntries is! List || rawEntries.length > 10000) {
    throw FormatException(tr("Invalid form entries."));
  }
  final entries = <NativeHtmlFormEntry>[];
  var inlineBytesRemaining = _maxInlineFileBytes;
  for (final raw in rawEntries) {
    if (raw is! Map || raw['name'] is! String) {
      throw FormatException(tr("Invalid form entry."));
    }
    final name = raw['name'] as String;
    final hasFile = raw.containsKey('file');
    final hasInlineFile = raw.containsKey('inlineFile');
    final hasValue = raw.containsKey('value');
    if ((hasFile && (hasInlineFile || hasValue)) ||
        (hasInlineFile && hasValue)) {
      throw FormatException(tr("Invalid form entry."));
    }

    if (hasInlineFile) {
      final inlineFile = raw['inlineFile'];
      if (inlineFile is! Map ||
          inlineFile['name'] is! String ||
          inlineFile['type'] is! String ||
          inlineFile['lastModified'] is! int ||
          inlineFile['bytesBase64'] is! String) {
        throw FormatException(tr("Invalid inline file."));
      }
      final bytes = _decodeInlineFileBytes(
        inlineFile['bytesBase64'] as String,
        inlineBytesRemaining,
      );
      inlineBytesRemaining -= bytes.length;
      entries.add(
        NativeHtmlFormEntry.file(
          name,
          file: NativeHtmlFile.script(
            name: inlineFile['name'] as String,
            mimeType: inlineFile['type'] as String,
            lastModified: inlineFile['lastModified'] as int,
            bytes: bytes,
          ),
        ),
      );
      continue;
    }

    if (hasFile) {
      final reference = raw['file'];
      if (reference == null) {
        entries.add(NativeHtmlFormEntry.file(name));
        continue;
      }
      if (reference is! Map ||
          reference['controlId'] is! String ||
          reference['index'] is! int ||
          (reference['index'] as int) < 0 ||
          (reference['resetVersion'] is! String &&
              reference['resetVersion'] is! num) ||
          (reference.containsKey('name') && reference['name'] is! String) ||
          (reference.containsKey('type') && reference['type'] is! String) ||
          (reference.containsKey('lastModified') &&
              reference['lastModified'] is! int)) {
        throw FormatException(tr("Invalid selected-file reference."));
      }
      final file = resolveFile(
        reference['controlId'] as String,
        reference['resetVersion'].toString(),
        reference['index'] as int,
      );
      if (file == null) {
        throw FormatException(tr("The selected file is no longer available."));
      }

      final hasName = reference.containsKey('name');
      final hasType = reference.containsKey('type');
      final hasLastModified = reference.containsKey('lastModified');
      final submittedFile = hasName || hasType || hasLastModified
          ? NativeHtmlFile.script(
              name: hasName ? reference['name'] as String : file.name,
              mimeType: hasType ? reference['type'] as String : file.mimeType,
              lastModified: hasLastModified
                  ? reference['lastModified'] as int
                  : file.lastModified,
              bytes: file.bytes,
            )
          : file;
      entries.add(NativeHtmlFormEntry.file(name, file: submittedFile));
      continue;
    }

    if (raw['value'] is! String) {
      throw FormatException(tr("Invalid form value."));
    }
    entries.add(NativeHtmlFormEntry(name, raw['value'] as String));
  }
  final request = NativeHtmlFormSubmission(
    action: string('action'),
    method: string('method', 'get'),
    enctype: string('enctype', 'application/x-www-form-urlencoded'),
    target: string('target'),
    targetSpecified: action['targetSpecified'] == true,
    noopener: action['noopener'] as bool?,
    submitterId: action['submitterId'] == null ? null : string('submitterId'),
    entries: entries,
  );
  request.buildRequest();
  return request;
}

Uint8List _decodeInlineFileBytes(String encoded, int maximumBytes) {
  // Bound the encoded input before decoding, then check the exact decoded size.
  final maximumEncodedLength = ((maximumBytes + 2) ~/ 3) * 4;
  if (encoded.length > maximumEncodedLength ||
      encoded.length % 4 != 0 ||
      !_base64Pattern.hasMatch(encoded)) {
    throw FormatException(tr("Invalid inline file bytes."));
  }

  final padding = encoded.endsWith('==')
      ? 2
      : encoded.endsWith('=')
      ? 1
      : 0;
  final expectedLength = (encoded.length ~/ 4) * 3 - padding;
  if (expectedLength > maximumBytes) {
    throw FormatException(tr("Inline files exceed the 2 MiB limit."));
  }

  final bytes = base64.decode(encoded);
  if (bytes.length != expectedLength || base64.encode(bytes) != encoded) {
    throw FormatException(tr("Invalid inline file bytes."));
  }
  return Uint8List.fromList(bytes);
}
