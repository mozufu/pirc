import 'render_l10n.dart';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import 'html_file.dart';

/// One ordered successful control for the binary-aware native form serializer.
///
/// A file entry with [file] set to null represents the empty File value that
/// browsers submit for a file input with no selected files.
@immutable
class NativeHtmlFormDataEntry {
  const NativeHtmlFormDataEntry.text(this.name, this.textValue)
    : fileValue = null;

  const NativeHtmlFormDataEntry.file(this.name, {NativeHtmlFile? file})
    : fileValue = file,
      textValue = null;

  final String name;
  final String? textValue;
  final NativeHtmlFile? fileValue;

  bool get isFile => textValue == null;

  String get stringValue => isFile ? (fileValue?.name ?? '') : textValue!;
}

/// Immutable byte body plus its request Content-Type.
///
/// [bytes] returns a fresh copy so a history/replay snapshot cannot be changed
/// by a transport caller after form submission.
@immutable
class NativeHtmlEncodedBody {
  NativeHtmlEncodedBody({
    required List<int> bytes,
    required this.contentType,
    this.boundary,
  }) : _bytes = Uint8List.fromList(bytes);

  final Uint8List _bytes;
  final String contentType;
  final String? boundary;

  Uint8List get bytes => Uint8List.fromList(_bytes);
  int get byteLength => _bytes.length;
}

/// Serializes entries for GET queries and URL-encoded POSTs.
///
/// A file value contributes its filename (an empty filename when no file was
/// selected), matching the browser's form-data entry-list encoding.
String nativeHtmlFormDataUrlEncode(Iterable<NativeHtmlFormDataEntry> entries) =>
    entries
        .map(
          (entry) =>
              '${_encodeFormComponent(_normalizeNewlines(entry.name))}='
              '${_encodeFormComponent(_normalizeNewlines(entry.stringValue))}',
        )
        .join('&');

/// Encodes ordered entries using application/x-www-form-urlencoded,
/// text/plain, or multipart/form-data.
NativeHtmlEncodedBody nativeHtmlFormDataEncode(
  Iterable<NativeHtmlFormDataEntry> entries, {
  required String enctype,
  String? boundary,
}) {
  final ordered = List<NativeHtmlFormDataEntry>.unmodifiable(entries);
  switch (enctype.trim().toLowerCase()) {
    case 'application/x-www-form-urlencoded':
      return NativeHtmlEncodedBody(
        bytes: utf8.encode(nativeHtmlFormDataUrlEncode(ordered)),
        contentType: 'application/x-www-form-urlencoded',
      );
    case 'text/plain':
      return NativeHtmlEncodedBody(
        bytes: utf8.encode(_encodeTextPlain(ordered)),
        contentType: 'text/plain',
      );
    case 'multipart/form-data':
      final selectedBoundary = boundary ?? _newBoundary(ordered);
      _validateBoundary(selectedBoundary);
      return _encodeMultipart(ordered, selectedBoundary);
    default:
      throw UnsupportedError(
        tr("Unsupported HTML form encoding: {0}", [enctype]),
      );
  }
}

NativeHtmlEncodedBody _encodeMultipart(
  List<NativeHtmlFormDataEntry> entries,
  String boundary,
) {
  final body = BytesBuilder(copy: false);
  final boundaryBytes = ascii.encode('--$boundary');
  for (final entry in entries) {
    body
      ..add(boundaryBytes)
      ..add(ascii.encode('\r\n'));
    final disposition =
        'Content-Disposition: form-data; name="${_escapeHeaderParameter(entry.name)}"';
    body.add(utf8.encode(disposition));
    if (entry.isFile) {
      final file = entry.fileValue;
      final filename = _escapeHeaderParameter(file?.name ?? '');
      body
        ..add(utf8.encode('; filename="$filename"\r\n'))
        ..add(
          ascii.encode(
            'Content-Type: ${_multipartMediaType(file?.mimeType)}\r\n',
          ),
        );
    } else {
      body.add(ascii.encode('\r\n'));
    }
    body.add(ascii.encode('\r\n'));
    if (entry.isFile) {
      body.add(entry.fileValue?.bytes ?? Uint8List(0));
    } else {
      body.add(utf8.encode(_normalizeNewlines(entry.textValue!)));
    }
    body.add(ascii.encode('\r\n'));
  }
  body
    ..add(boundaryBytes)
    ..add(ascii.encode('--\r\n'));

  return NativeHtmlEncodedBody(
    bytes: body.takeBytes(),
    contentType: 'multipart/form-data; boundary=$boundary',
    boundary: boundary,
  );
}

String _encodeTextPlain(List<NativeHtmlFormDataEntry> entries) {
  final output = StringBuffer();
  for (final entry in entries) {
    output
      ..write(_normalizeNewlines(entry.name))
      ..write('=')
      ..write(_normalizeNewlines(entry.stringValue))
      ..write('\r\n');
  }
  return output.toString();
}

String _multipartMediaType(String? value) {
  if (value == null ||
      !RegExp(
        r'^[a-zA-Z0-9!#$&^_.+-]+/[a-zA-Z0-9!#$&^_.+-]+$',
      ).hasMatch(value)) {
    return 'application/octet-stream';
  }
  return value.toLowerCase();
}

String _escapeHeaderParameter(String value) => value
    .replaceAll('\r\n', '%0D%0A')
    .replaceAll('\r', '%0D')
    .replaceAll('\n', '%0A')
    .replaceAll('"', '%22');

String _normalizeNewlines(String input) => input
    .replaceAll('\r\n', '\n')
    .replaceAll('\r', '\n')
    .replaceAll('\n', '\r\n');

String _encodeFormComponent(String input) {
  final output = StringBuffer();
  for (final byte in utf8.encode(input)) {
    if (_isFormSafeByte(byte)) {
      output.writeCharCode(byte);
    } else if (byte == 0x20) {
      output.write('+');
    } else {
      output
        ..write('%')
        ..write(byte.toRadixString(16).padLeft(2, '0').toUpperCase());
    }
  }
  return output.toString();
}

bool _isFormSafeByte(int byte) =>
    (byte >= 0x30 && byte <= 0x39) ||
    (byte >= 0x41 && byte <= 0x5a) ||
    (byte >= 0x61 && byte <= 0x7a) ||
    byte == 0x2a ||
    byte == 0x2d ||
    byte == 0x2e ||
    byte == 0x5f;

const _boundaryAlphabet =
    'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789';

String _newBoundary(List<NativeHtmlFormDataEntry> entries) {
  final random = math.Random.secure();
  while (true) {
    final suffix = List.generate(
      16,
      (_) => _boundaryAlphabet[random.nextInt(_boundaryAlphabet.length)],
    ).join();
    final candidate = '----WebKitFormBoundary$suffix';
    if (!_containsBoundary(entries, '--$candidate')) return candidate;
  }
}

bool _containsBoundary(List<NativeHtmlFormDataEntry> entries, String needle) {
  final needleBytes = ascii.encode(needle);
  bool includes(List<int> bytes) {
    if (bytes.length < needleBytes.length) return false;
    for (var start = 0; start <= bytes.length - needleBytes.length; start++) {
      var matches = true;
      for (var index = 0; index < needleBytes.length; index++) {
        if (bytes[start + index] != needleBytes[index]) {
          matches = false;
          break;
        }
      }
      if (matches) return true;
    }
    return false;
  }

  for (final entry in entries) {
    if (includes(utf8.encode(entry.name)) ||
        (entry.isFile
            ? includes(entry.fileValue?.bytes ?? const <int>[])
            : includes(utf8.encode(entry.textValue!)))) {
      return true;
    }
  }
  return false;
}

void _validateBoundary(String boundary) {
  if (boundary.isEmpty ||
      boundary.length > 70 ||
      !RegExp(r"^[0-9A-Za-z'()+_,./:=?-]+$").hasMatch(boundary)) {
    throw ArgumentError.value(
      boundary,
      'boundary',
      tr("Must be a 1–70 character multipart boundary."),
    );
  }
}
