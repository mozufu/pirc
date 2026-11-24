/// Port of the pinned web file-links.ts; paths are validated by the server.
class FileTarget {
  const FileTarget(this.path, {this.line, this.endLine});
  final String path;
  final int? line, endLine;
  String get href =>
      '${Uri(path: path)}${line == null ? '' : '#L$line${endLine == null ? '' : '-L$endLine'}'}';
}

FileTarget? parseFileTarget(String? href, {String base = ''}) {
  var value = (href ?? '').trim();
  if (value.isEmpty || value.startsWith('#') || value.startsWith('//')) {
    return null;
  }
  if (RegExp(r'^file:', caseSensitive: false).hasMatch(value)) {
    value = value.replaceFirst(
      RegExp(r'^file:(//(localhost)?)?', caseSensitive: false),
      '',
    );
  } else if (RegExp(
    r'^[a-z][a-z0-9+.-]*:',
    caseSensitive: false,
  ).hasMatch(value)) {
    return null;
  }
  final hash = RegExp(
    r'#L(\d+)(?:C\d+)?(?:-L?(\d+)(?:C\d+)?)?$',
    caseSensitive: false,
  ).firstMatch(value);
  value = value.replaceFirst(RegExp(r'[?#].*$'), '');
  try {
    value = Uri.decodeComponent(value);
  } on ArgumentError {
    // Invalid URL encoding stays literal, as in decodeURIComponent catch.
  } on FormatException {
    /* Keep a literal malformed escape, like web. */
  }
  final suffix = RegExp(r':(\d+)(?::\d+|-(\d+))?$').firstMatch(value);
  if (suffix != null) value = value.substring(0, suffix.start);
  if (value.isEmpty || value.endsWith('/')) return null;
  if (!value.startsWith('/') && base.isNotEmpty) value = '$base/$value';
  final absolute = value.startsWith('/'), parts = <String>[];
  for (final part in value.split('/')) {
    if (part.isEmpty || part == '.') continue;
    if (part == '..' && parts.isNotEmpty && parts.last != '..') {
      parts.removeLast();
    } else if (part == '..' && absolute) {
      continue;
    } else {
      parts.add(part);
    }
  }
  final path = '${absolute ? '/' : ''}${parts.join('/')}';
  if (path.isEmpty || path == '/') return null;
  final line = int.tryParse((hash ?? suffix)?.group(1) ?? '');
  final end = int.tryParse((hash ?? suffix)?.group(2) ?? '');
  return FileTarget(
    path,
    line: line == null || line == 0 ? null : line,
    endLine: line != null && line != 0 && end != null && end > line
        ? end
        : null,
  );
}
