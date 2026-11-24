import 'render_l10n.dart';
import 'dart:convert';

/// Resolves an HTTP(S) document reference against an absolute HTTP(S) base.
///
/// Query and fragment percent escapes are kept byte-for-byte; raw non-ASCII
/// and URL-forbidden characters are UTF-8 percent-encoded. Path dot segments,
/// including WHATWG percent-encoded dot forms, are resolved. This helper is
/// intentionally narrower than the browser URL parser: it rejects IDN hosts,
/// IPv6, user info, backslashes, non-canonical IPv4 aliases, and non-hierarchical
/// HTTP(S) references rather than guessing how to normalize them.
///
/// Leading and trailing C0 controls/spaces are trimmed, and ASCII tab/newline
/// characters are removed as the WHATWG URL parser does. Other controls in path,
/// query, or fragment are percent-encoded.
String resolveNativeDocumentUrl(String reference, String base) {
  final input = _cleanUrlInput(reference);
  final cleanedBase = _cleanUrlInput(base);
  // An opaque blob base cannot resolve relative HTTP resources. An absolute
  // HTTP reference remains valid independently of that base, as in URL().
  final absoluteFromBlob =
      cleanedBase.startsWith('blob:') &&
      RegExp(r'^https?:', caseSensitive: false).hasMatch(input);
  final baseUrl = _parseAbsoluteHttpUrl(absoluteFromBlob ? input : cleanedBase);

  if (input.isEmpty) {
    return _serialize(baseUrl.withoutFragment());
  }

  if (input.contains(r'\')) {
    throw UnsupportedError(tr("Backslashes in document URLs are unsupported."));
  }

  final scheme = _schemePattern.matchAsPrefix(input);
  if (scheme != null) {
    return _serialize(_parseAbsoluteHttpUrl(input));
  }

  if (input.startsWith('//')) {
    return _serialize(_parseAbsoluteHttpUrl('${baseUrl.scheme}:$input'));
  }

  final referenceParts = _splitPathQueryFragment(input);
  late final String path;
  late final String? query;
  late final bool hasQuery;

  if (referenceParts.path.isEmpty) {
    path = baseUrl.path;
    if (referenceParts.hasQuery) {
      query = referenceParts.query;
      hasQuery = true;
    } else {
      query = baseUrl.query;
      hasQuery = baseUrl.hasQuery;
    }
  } else {
    final mergedPath = referenceParts.path.startsWith('/')
        ? referenceParts.path
        : _mergeWithBaseDirectory(baseUrl.path, referenceParts.path);
    path = _normalizePath(mergedPath);
    query = referenceParts.query;
    hasQuery = referenceParts.hasQuery;
  }

  return _serialize(
    _HttpUrl(
      scheme: baseUrl.scheme,
      authority: baseUrl.authority,
      path: path,
      query: query,
      hasQuery: hasQuery,
      fragment: referenceParts.fragment,
      hasFragment: referenceParts.hasFragment,
    ),
  );
}

/// Returns true only when an explicit fragment delimiter is present and the
/// URL before it exactly matches the current URL before its fragment.
///
/// Callers handling form submissions must force a network navigation even when
/// this returns true. Chrome reloads for a form GET to the same path and hash.
bool nativeSameDocumentFragment(String resolved, String current) {
  final resolvedFragment = resolved.indexOf('#');
  if (resolvedFragment < 0) return false;

  final currentFragment = current.indexOf('#');
  final resolvedWithoutFragment = resolved.substring(0, resolvedFragment);
  final currentWithoutFragment = currentFragment < 0
      ? current
      : current.substring(0, currentFragment);
  return resolvedWithoutFragment == currentWithoutFragment;
}

final _schemePattern = RegExp(r'^([A-Za-z][A-Za-z0-9+.-]*):');

class _HttpUrl {
  const _HttpUrl({
    required this.scheme,
    required this.authority,
    required this.path,
    required this.query,
    required this.hasQuery,
    required this.fragment,
    required this.hasFragment,
  });

  final String scheme;
  final String authority;
  final String path;
  final String? query;
  final bool hasQuery;
  final String? fragment;
  final bool hasFragment;

  _HttpUrl withoutFragment() => _HttpUrl(
    scheme: scheme,
    authority: authority,
    path: path,
    query: query,
    hasQuery: hasQuery,
    fragment: null,
    hasFragment: false,
  );
}

class _PathQueryFragment {
  const _PathQueryFragment({
    required this.path,
    required this.query,
    required this.hasQuery,
    required this.fragment,
    required this.hasFragment,
  });

  final String path;
  final String? query;
  final bool hasQuery;
  final String? fragment;
  final bool hasFragment;
}

String _cleanUrlInput(String input) {
  final withoutTabsAndNewlines = input.replaceAll(RegExp(r'[\t\n\r]'), '');
  return withoutTabsAndNewlines.replaceAll(
    RegExp(r'^[\x00-\x20]+|[\x00-\x20]+$'),
    '',
  );
}

_HttpUrl _parseAbsoluteHttpUrl(String input) {
  if (input.contains(r'\')) {
    throw UnsupportedError(tr("Backslashes in document URLs are unsupported."));
  }

  final schemeMatch = _schemePattern.matchAsPrefix(input);
  if (schemeMatch == null) {
    throw UnsupportedError(
      tr("The document base must be an absolute HTTP(S) URL."),
    );
  }

  final scheme = schemeMatch.group(1)!.toLowerCase();
  if (scheme != 'http' && scheme != 'https') {
    throw UnsupportedError(tr("Only HTTP(S) document URLs are supported."));
  }

  final rest = input.substring(schemeMatch.end);
  if (!rest.startsWith('//')) {
    throw UnsupportedError(
      tr("HTTP(S) URLs without an authority are unsupported."),
    );
  }

  final afterSlashes = rest.substring(2);
  final authorityEnd = afterSlashes.indexOf(RegExp(r'[/?#]'));
  final rawAuthority = authorityEnd < 0
      ? afterSlashes
      : afterSlashes.substring(0, authorityEnd);
  final tail = authorityEnd < 0 ? '' : afterSlashes.substring(authorityEnd);
  final authority = _normalizeAuthority(scheme, rawAuthority);
  final parts = _splitPathQueryFragment(tail);
  final path = _normalizePath(parts.path.isEmpty ? '/' : parts.path);

  return _HttpUrl(
    scheme: scheme,
    authority: authority,
    path: path,
    query: parts.query,
    hasQuery: parts.hasQuery,
    fragment: parts.fragment,
    hasFragment: parts.hasFragment,
  );
}

String _normalizeAuthority(String scheme, String authority) {
  if (authority.isEmpty) {
    throw UnsupportedError(tr("HTTP(S) URLs must include a host."));
  }
  if (authority.contains('@')) {
    throw UnsupportedError(tr("HTTP(S) URL user info is unsupported."));
  }
  if (authority.contains('[') || authority.contains(']')) {
    throw UnsupportedError(tr("IPv6 URL hosts are unsupported."));
  }

  final colon = authority.lastIndexOf(':');
  final rawHost = colon < 0 ? authority : authority.substring(0, colon);
  final rawPort = colon < 0 ? null : authority.substring(colon + 1);
  if (rawHost.contains(':')) {
    throw UnsupportedError(tr("IPv6 URL hosts are unsupported."));
  }
  if (rawHost.codeUnits.any((unit) => unit > 0x7F)) {
    throw UnsupportedError(tr("Non-ASCII and IDN URL hosts are unsupported."));
  }
  if (rawHost
      .toLowerCase()
      .split('.')
      .any((label) => label.startsWith('xn--'))) {
    throw UnsupportedError(tr("Non-ASCII and IDN URL hosts are unsupported."));
  }
  if (rawHost.contains('%')) {
    throw UnsupportedError(tr("Percent-encoded URL hosts are unsupported."));
  }
  if (!RegExp(r'^[A-Za-z0-9._-]+$').hasMatch(rawHost)) {
    throw UnsupportedError(tr("This HTTP(S) host syntax is unsupported."));
  }

  final hostWithoutTrailingDot = rawHost.endsWith('.')
      ? rawHost.substring(0, rawHost.length - 1)
      : rawHost;
  final labels = hostWithoutTrailingDot.split('.');
  if (hostWithoutTrailingDot.isEmpty ||
      labels.any(
        (label) =>
            label.isEmpty || label.startsWith('-') || label.endsWith('-'),
      ) ||
      labels.any((label) => label.length > 63)) {
    throw UnsupportedError(tr("This HTTP(S) host syntax is unsupported."));
  }

  final canonicalIpv4 = _isCanonicalIpv4(hostWithoutTrailingDot);
  final lastLabel = labels.last.toLowerCase();
  final ipv4LikeEnding = RegExp(
    r'^(?:0x[0-9a-f]*|[0-9]+)$',
  ).hasMatch(lastLabel);
  if (ipv4LikeEnding && !canonicalIpv4) {
    throw UnsupportedError(tr("Non-canonical IPv4 URL hosts are unsupported."));
  }

  var port = '';
  if (rawPort != null && rawPort.isNotEmpty) {
    if (!RegExp(r'^[0-9]+$').hasMatch(rawPort)) {
      throw UnsupportedError(
        tr("Non-numeric HTTP(S) URL ports are unsupported."),
      );
    }
    final parsedPort = int.tryParse(rawPort);
    if (parsedPort == null || parsedPort > 65535) {
      throw UnsupportedError(
        tr("HTTP(S) URL ports must be between 0 and 65535."),
      );
    }
    final isDefaultPort =
        (scheme == 'http' && parsedPort == 80) ||
        (scheme == 'https' && parsedPort == 443);
    if (!isDefaultPort) port = ':$parsedPort';
  }

  return rawHost.toLowerCase() + port;
}

bool _isCanonicalIpv4(String host) {
  if (!RegExp(r'^[0-9.]+$').hasMatch(host)) return false;
  final parts = host.split('.');
  if (parts.length != 4) return false;
  for (final part in parts) {
    if (part.isEmpty || (part.length > 1 && part.startsWith('0'))) return false;
    final octet = int.tryParse(part);
    if (octet == null || octet > 255) return false;
  }
  return true;
}

_PathQueryFragment _splitPathQueryFragment(String input) {
  final hash = input.indexOf('#');
  final hasFragment = hash >= 0;
  final beforeFragment = hasFragment ? input.substring(0, hash) : input;
  final fragment = hasFragment
      ? _encodeUrlComponent(input.substring(hash + 1), _fragmentNeedsEncoding)
      : null;

  final question = beforeFragment.indexOf('?');
  final hasQuery = question >= 0;
  final path = hasQuery
      ? beforeFragment.substring(0, question)
      : beforeFragment;
  final query = hasQuery
      ? _encodeUrlComponent(
          beforeFragment.substring(question + 1),
          _specialQueryNeedsEncoding,
        )
      : null;

  return _PathQueryFragment(
    path: path,
    query: query,
    hasQuery: hasQuery,
    fragment: fragment,
    hasFragment: hasFragment,
  );
}

String _mergeWithBaseDirectory(String basePath, String relativePath) {
  final lastSlash = basePath.lastIndexOf('/');
  final directory = lastSlash < 0 ? '/' : basePath.substring(0, lastSlash + 1);
  return directory + relativePath;
}

String _normalizePath(String path) {
  final absolutePath = path.startsWith('/') ? path : '/$path';
  final segments = absolutePath.split('/');
  final normalized = <String>[''];

  for (var index = 1; index < segments.length; index++) {
    final segment = segments[index];
    final isLast = index == segments.length - 1;
    final lower = segment.toLowerCase();

    if (lower == '.' || lower == '%2e') {
      if (isLast) normalized.add('');
      continue;
    }

    if (lower == '..' ||
        lower == '.%2e' ||
        lower == '%2e.' ||
        lower == '%2e%2e') {
      if (normalized.length > 1) normalized.removeLast();
      if (isLast) normalized.add('');
      continue;
    }

    normalized.add(_encodeUrlComponent(segment, _pathNeedsEncoding));
  }

  return normalized.join('/');
}

String _encodeUrlComponent(String input, bool Function(int) shouldEncode) {
  final output = StringBuffer();
  for (final codePoint in input.runes) {
    if (!shouldEncode(codePoint)) {
      output.writeCharCode(codePoint);
      continue;
    }
    for (final byte in utf8.encode(String.fromCharCode(codePoint))) {
      output
        ..write('%')
        ..write(byte.toRadixString(16).padLeft(2, '0').toUpperCase());
    }
  }
  return output.toString();
}

bool _pathNeedsEncoding(int codePoint) =>
    codePoint <= 0x20 ||
    codePoint > 0x7E ||
    codePoint == 0x22 ||
    codePoint == 0x23 ||
    codePoint == 0x3C ||
    codePoint == 0x3E ||
    codePoint == 0x3F ||
    codePoint == 0x5E ||
    codePoint == 0x60 ||
    codePoint == 0x7B ||
    codePoint == 0x7D;

bool _specialQueryNeedsEncoding(int codePoint) =>
    codePoint <= 0x20 ||
    codePoint > 0x7E ||
    codePoint == 0x22 ||
    codePoint == 0x23 ||
    codePoint == 0x27 ||
    codePoint == 0x3C ||
    codePoint == 0x3E;

bool _fragmentNeedsEncoding(int codePoint) =>
    codePoint <= 0x20 ||
    codePoint > 0x7E ||
    codePoint == 0x22 ||
    codePoint == 0x3C ||
    codePoint == 0x3E ||
    codePoint == 0x60;

String _serialize(_HttpUrl url) {
  final output = StringBuffer()
    ..write(url.scheme)
    ..write('://')
    ..write(url.authority)
    ..write(url.path);
  if (url.hasQuery) {
    output
      ..write('?')
      ..write(url.query ?? '');
  }
  if (url.hasFragment) {
    output
      ..write('#')
      ..write(url.fragment ?? '');
  }
  return output.toString();
}
