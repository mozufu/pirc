import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html;

import 'package:pirc_render/src/html_document_content.dart';
import 'app_document_route.dart';

const _pircDescription =
    'A calm command surface for persistent coding-agent sessions.';

/// Returns the Pirc app route only when a successful GET returned the pinned
/// Pirc SPA shell at its configured root, `index.html` alias, or app-prefix
/// fallback path.
///
/// This deliberately does not recognize arbitrary SPA fallback paths. A
/// same-origin server may serve an actual HTML document, or route an unknown
/// path to its SPA shell; callers should keep those paths on the document
/// navigation path until they have an explicit fallback policy.
NativeAppDocumentRoute? nativePircAppDocumentRoute({
  required NativeHtmlDocumentContent content,
  required int status,
  required String finalMethod,
  required String canonicalUrl,
  required String appRootUrl,
}) {
  if (status < 200 || status >= 300 || status == 204 || status == 205) {
    return null;
  }
  if (finalMethod.toUpperCase() != 'GET' || !content.isHtml) return null;

  final documentUri = _webUri(canonicalUrl);
  final rootUri = _webUri(appRootUrl);
  if (documentUri == null ||
      rootUri == null ||
      !_isPircShell(content, documentUri, rootUri)) {
    return null;
  }

  // Only after the full Pirc shell signature passes do we permit the SPA's
  // static-server fallback paths. The route parser still rejects API paths,
  // foreign origins, and paths outside the app root prefix.
  return NativeAppDocumentRoute.parse(
    canonicalUrl,
    appRootUrl: appRootUrl,
    allowSpaFallback: true,
  );
}

bool _isPircShell(
  NativeHtmlDocumentContent content,
  Uri documentUri,
  Uri rootUri,
) {
  final document = html.parse(content.text);
  if (document.querySelector('head title')?.text.trim() != 'pirc') return false;
  if (!_hasMeta(document, 'description', _pircDescription)) return false;
  if (!_hasMeta(document, 'apple-mobile-web-app-title', 'pirc')) return false;
  if (document.body?.querySelector('div#app') == null) return false;

  return document.querySelectorAll('script[type]').any((script) {
    if ((script.attributes['type'] ?? '').trim().toLowerCase() != 'module') {
      return false;
    }
    final source = script.attributes['src'];
    if (source == null || source.trim().isEmpty) return false;

    try {
      // Vite adds a `crossorigin` attribute to production module scripts; that
      // is still same-origin in this app. Only a genuinely foreign script is
      // rejected here.
      final entry = documentUri.resolve(source.trim());
      if (!_sameOrigin(entry, rootUri) || entry.userInfo.isNotEmpty) {
        return false;
      }
      final path = entry.path;
      return path == '/src/main.ts' ||
          RegExp(r'^/assets/[^/]+\.js$').hasMatch(path);
    } on FormatException {
      return false;
    }
  });
}

bool _hasMeta(dom.Document document, String name, String value) {
  return document.querySelectorAll('head meta[name][content]').any((meta) {
    return (meta.attributes['name'] ?? '').trim().toLowerCase() == name &&
        meta.attributes['content'] == value;
  });
}

Uri? _webUri(String source) {
  try {
    final uri = Uri.parse(source);
    if (!uri.hasScheme ||
        !uri.hasAuthority ||
        uri.host.isEmpty ||
        (uri.scheme != 'http' && uri.scheme != 'https')) {
      return null;
    }
    return uri;
  } on FormatException {
    return null;
  }
}

bool _sameOrigin(Uri first, Uri second) =>
    first.scheme == second.scheme &&
    first.host.toLowerCase() == second.host.toLowerCase() &&
    _effectivePort(first) == _effectivePort(second);

int _effectivePort(Uri uri) =>
    uri.hasPort ? uri.port : (uri.scheme == 'https' ? 443 : 80);
