import '../l10n/app_i18n.dart';
import 'dart:convert';
import 'dart:typed_data';
import 'package:pirc_render/src/html_document_content.dart';
import 'gateway.dart';

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
