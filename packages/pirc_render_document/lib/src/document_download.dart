import 'dart:typed_data';

/// Saves bytes through the system save picker and returns the saved name, or
/// null when the user cancelled. In the app this is `FilesPlatform.save`.
typedef DocumentSaver =
    Future<String?> Function(
      Uint8List bytes, {
      required String name,
      required String mimeType,
    });

/// A download a document asked for (`<a download>`), ported from the old
/// app's `live/document_download.dart`.
///
/// A message document has an opaque origin and no credentials, so only
/// content it already holds can be saved: a `data:` URL. A remote `http(s)`
/// download would need a request on the document's behalf and is refused, as
/// are `blob:` URLs of a document that is not running.
class DocumentDownload {
  DocumentDownload({
    required this.bytes,
    required String name,
    required String mimeType,
  }) : name = documentDownloadName(name),
       mimeType = _mimeType(mimeType) {
    if (bytes.length > maxBytes) {
      throw const DocumentDownloadRefused('larger than 32 MiB');
    }
  }

  /// Reads the target of an `<a download="name" href="...">`.
  factory DocumentDownload.link(String href, {String? download}) {
    final uri = Uri.tryParse(href.trim());
    if (uri == null || uri.scheme != 'data') {
      throw const DocumentDownloadRefused(
        'only data: links can be saved from a message',
      );
    }
    if (href.length > maxBytes * 4 ~/ 3 + 4096) {
      throw const DocumentDownloadRefused('larger than 32 MiB');
    }
    final data = uri.data!;
    return DocumentDownload(
      bytes: data.contentAsBytes(),
      name: download?.trim().isNotEmpty == true ? download! : 'download',
      mimeType: data.mimeType,
    );
  }

  static const maxBytes = 32 * 1024 * 1024;

  final Uint8List bytes;
  final String name;
  final String mimeType;

  /// Opens the save picker; returns the saved name or null (cancelled).
  Future<String?> save(DocumentSaver saver) =>
      saver(bytes, name: name, mimeType: mimeType);

  static String _mimeType(String value) {
    final type = value.split(';').first.trim().toLowerCase();
    return type.isEmpty ? 'application/octet-stream' : type;
  }
}

class DocumentDownloadRefused implements Exception {
  const DocumentDownloadRefused(this.reason);
  final String reason;
  @override
  String toString() => 'Download refused: $reason';
}

/// A file name without folders or control characters, at most 180
/// characters; `download` when nothing usable is left.
String documentDownloadName(String value) {
  final base = value
      .split(RegExp(r'[/\\]'))
      .last
      .replaceAll(RegExp(r'[\x00-\x1f\x7f-\x9f]'), '')
      .trim();
  if (base.isEmpty || base == '.' || base == '..') return 'download';
  return String.fromCharCodes(base.runes.take(180));
}
