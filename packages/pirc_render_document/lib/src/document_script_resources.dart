import 'package:pirc_render/src/render_l10n.dart';
import 'dart:convert';
import 'dart:typed_data';
import 'package:pirc_render/src/html_document_content.dart';
import 'document_json.dart';
import 'scripts_platform.dart';

/// Only the native transport decides origins, credentials, CORS, MIME and SRI.
/// This boundary decodes verified script bytes and bounds the isolate message.
Json completeDocumentScriptResource(Json request, Json response) {
  final raw = response['bodyBytes'];
  if (!response.containsKey('bodyBytes') ||
      (raw != null &&
          (raw is! List ||
              raw.length > 2 * 1024 * 1024 ||
              raw.any((b) => b is! int || b < 0 || b > 255)))) {
    throw FormatException(
      tr("Invalid document resource bytes (maximum 2 MiB)."),
    );
  }
  final bytes = Uint8List.fromList(
    raw == null ? const [] : (raw as List).cast<int>(),
  );
  final result = <String, dynamic>{
    'id': request['id'],
    'ok': true,
    'url': response['url'],
  };
  if (request['kind'] == 'script') {
    final status = response['status'];
    if (status is! int || status < 200 || status >= 300) {
      throw FormatException(tr("Script resource returned HTTP {0}.", [status]));
    }
    if (response['moduleReferrerPolicy'] != null) {
      result['referrerPolicy'] = response['moduleReferrerPolicy'];
    }
    result['source'] = request['type'] == 'module'
        ? utf8.decode(bytes, allowMalformed: true)
        : NativeHtmlDocumentContent.fromBytes(
            bytes,
            mimeType: 'application/javascript',
            charset: response['charset'] as String?,
          ).text;
  } else {
    result.addAll({
      'status': response['status'],
      'statusText': response['statusText'],
      'headers': response['headers'],
      'type': response['type'],
      'redirected': response['redirected'],
      'bodyBase64': raw == null ? null : base64Encode(bytes),
    });
  }
  if (utf8.encode(jsonEncode(result)).length > 4 * 1024 * 1024 - 128) {
    throw FormatException(
      tr("Document resource exceeds the 4 MiB script message limit."),
    );
  }
  return result;
}

/// The scripts channel request for one runtime resource request (`fetch`,
/// `script` or `stylesheet`).
///
/// The document has an opaque origin, so its requests are never
/// credentialed and send no `Referer`: `credentials`, `crossOrigin` (other
/// than choosing CORS), `referrerPolicy`, `forcePreflight` and the referrer
/// URLs are dropped. `same-origin` fails, because no URL shares an opaque
/// origin. Images never reach this function: they load only after a tap.
/// A credential header fails in [DocumentResourceRequest].
DocumentResourceRequest documentResourceRequest(Json request) {
  final id = request['id'];
  final url = request['url'];
  if (id is! String || url is! String) {
    throw FormatException(tr("Invalid document resource identity."));
  }
  final uri = Uri.tryParse(url);
  if (uri == null) throw FormatException(tr("Invalid document resource URL."));
  final kind = switch (request['kind']) {
    'fetch' => 'fetch',
    'stylesheet' => 'stylesheet',
    'script' when '${request['type'] ?? ''}'.trim().toLowerCase() == 'module' =>
      'module',
    'script' => 'script',
    _ => throw FormatException(tr("Invalid document resource identity.")),
  };
  var mode = request['mode'] as String?;
  if (mode == null && kind != 'fetch' && kind != 'module') {
    // A `crossorigin` attribute asks for CORS; without one, a classic script
    // or a stylesheet is a no-cors request, as in browsers.
    mode = request['crossOrigin'] != null || request['crossorigin'] != null
        ? 'cors'
        : 'no-cors';
  }
  if (mode == 'same-origin') {
    throw StateError(
      tr("A document with an opaque origin has no same-origin URL."),
    );
  }
  if (mode != null && mode != 'cors' && mode != 'no-cors') {
    throw FormatException(tr("Invalid document resource identity."));
  }
  final rawHeaders = request['headers'] ?? const [];
  if (rawHeaders is! List || rawHeaders.length > 128) {
    throw FormatException(tr("Invalid document resource headers."));
  }
  final headers = <(String, String)>[
    for (final pair in rawHeaders)
      if (pair is List &&
          pair.length == 2 &&
          pair[0] is String &&
          pair[1] is String)
        (pair[0] as String, pair[1] as String)
      else
        throw FormatException(tr("Invalid document resource headers.")),
  ];
  Uint8List? body;
  final rawBody = request['bodyBytes'], encoded = request['bodyBase64'];
  if (rawBody is List) {
    body = Uint8List.fromList(rawBody.cast<int>());
  } else if (encoded is String) {
    body = base64Decode(encoded);
  }
  if (body != null && body.length > 2 * 1024 * 1024) {
    throw FormatException(tr("Script request body exceeds 2 MiB."));
  }
  return DocumentResourceRequest(
    id: id,
    url: uri,
    method: request['method'] as String? ?? 'GET',
    headers: headers,
    body: body,
    kind: kind,
    mode: mode,
    redirect: request['redirect'] as String? ?? 'follow',
  );
}

/// The runtime's cookie seed for a document at [url], from its session's
/// `document.cookie` string (Kotlin keeps the cookies, in memory, per
/// session). Each pair becomes a host-only session cookie at `/`: the
/// session store has no domains or paths, because nothing else shares it.
Json documentCookieState(
  String cookie, {
  required String url,
  required int generation,
}) {
  final uri = Uri.parse(url);
  final cookies = <Json>[];
  for (final part in cookie.split(';')) {
    final pair = part.trim();
    if (pair.isEmpty) continue;
    final equals = pair.indexOf('=');
    cookies.add({
      'name': equals < 0 ? '' : pair.substring(0, equals),
      'value': equals < 0 ? pair : pair.substring(equals + 1),
      'domain': uri.host,
      'hostOnly': true,
      'path': '/',
      'secure': false,
      'sameSite': 'lax',
      'expiresAt': null,
      'createdAt': 0,
      'creationOrder': cookies.length + 1,
    });
  }
  return {
    'generation': generation,
    'url': url,
    'cookies': cookies,
    'protections': const [],
    'secureOrigin': uri.scheme == 'https',
    'sameSiteContext': true,
    'allowedDomainSuffixes': [uri.host],
  };
}
