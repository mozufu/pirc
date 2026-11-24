import 'dart:convert';
import 'dart:typed_data';

import 'html_file.dart';
import 'html_form_binary.dart';

bool? nativeHtmlFormNoopener(String? rel) {
  final tokens = (rel ?? '').toLowerCase().split(RegExp(r'\s+'));
  if (tokens.contains('noreferrer') || tokens.contains('noopener')) return true;
  return tokens.contains('opener') ? false : null;
}

/// One successful control value in tree order, including empty file entries.
class NativeHtmlFormEntry {
  const NativeHtmlFormEntry(this.name, this.value)
    : file = null,
      isFile = false;

  NativeHtmlFormEntry.file(this.name, {this.file})
    : value = file?.name ?? '',
      isFile = true;

  final String name;
  final String value;
  final NativeHtmlFile? file;
  final bool isFile;

  NativeHtmlFormDataEntry get dataEntry => isFile
      ? NativeHtmlFormDataEntry.file(name, file: file)
      : NativeHtmlFormDataEntry.text(name, value);
}

/// The effective form submission attributes and ordered successful controls.
///
/// [entries] is copied and exposed as an unmodifiable list. File bytes are
/// immutable snapshots; direction-specific values are supplied by the caller.
class NativeHtmlFormSubmission {
  NativeHtmlFormSubmission({
    required this.action,
    required this.method,
    required this.enctype,
    required this.target,
    required Iterable<NativeHtmlFormEntry> entries,
    this.submitterId,
    this.targetSpecified = false,
    this.noopener,
  }) : entries = List<NativeHtmlFormEntry>.unmodifiable(entries);

  /// The action as supplied by the caller. Relative actions are kept relative.
  /// An empty action remains empty unless [buildRequest] receives [documentUrl].
  final String action;

  /// The effective `method` attribute or submitter override.
  final String method;

  /// The effective `enctype` attribute or submitter override.
  final String enctype;

  final String target;
  final bool targetSpecified;
  final bool? noopener;
  final List<NativeHtmlFormEntry> entries;
  final String? submitterId;

  /// Builds a GET or POST request using the effective HTML form encoding.
  ///
  /// `documentUrl` is used only when [action] is empty. Callers that have a
  /// relative nonempty action should resolve it against the document URL before
  /// calling this method if they need an absolute URL. GET replaces the action's
  /// old query and preserves its fragment. For an empty action with no
  /// [documentUrl], [NativeHtmlFormRequest.url] stays empty and the encoded
  /// [NativeHtmlFormRequest.query] is available for the caller to apply after
  /// resolving the current document URL.
  ///
  /// POST supports UTF-8 URL-encoded, text/plain and multipart form bodies.
  /// Multipart uses binary transport to preserve arbitrary file bytes.
  NativeHtmlFormRequest buildRequest({String? documentUrl}) {
    final normalizedMethod = _effectiveMethod(method);
    final actionUrl = action.isEmpty ? documentUrl ?? '' : action;

    if (normalizedMethod == 'GET') {
      final query = nativeHtmlFormEncode(entries);
      return NativeHtmlFormRequest(
        url: actionUrl.isEmpty ? '' : _replaceQuery(actionUrl, query),
        method: normalizedMethod,
        query: query,
        target: target,
        targetSpecified: targetSpecified,
        noopener: noopener,
        submitterId: submitterId,
      );
    }

    final normalizedEnctype = _effectiveEnctype(enctype);
    final encoded = nativeHtmlFormDataEncode(
      entries.map((entry) => entry.dataEntry),
      enctype: normalizedEnctype,
    );
    final multipart = normalizedEnctype == 'multipart/form-data';

    return NativeHtmlFormRequest(
      url: actionUrl,
      method: normalizedMethod,
      body: multipart ? null : utf8.decode(encoded.bytes),
      bodyBytes: multipart ? encoded.bytes : null,
      contentType: encoded.contentType,
      target: target,
      targetSpecified: targetSpecified,
      noopener: noopener,
      submitterId: submitterId,
    );
  }
}

/// A transport-ready result for a supported native HTML form submission.
///
/// GET requests have [query] and no body or content type. POST requests have a
/// either string [body] or binary [bodyBytes], and [contentType]. [url] remains
/// empty for a blank action when
/// no document URL was supplied.
class NativeHtmlFormRequest {
  const NativeHtmlFormRequest({
    required this.url,
    required this.method,
    required this.target,
    this.query,
    this.body,
    this.bodyBytes,
    this.contentType,
    this.submitterId,
    this.targetSpecified = false,
    this.noopener,
  });

  final String url;
  final String method;
  final String target;
  final bool targetSpecified;
  final bool? noopener;
  final String? query;
  final String? body;
  final Uint8List? bodyBytes;
  final String? contentType;
  final String? submitterId;

  /// Freezes binary payloads before asynchronous transport or later resubmission.
  NativeHtmlFormRequest snapshot() {
    final bytes = bodyBytes;
    if (bytes == null) return this;
    return NativeHtmlFormRequest(
      url: url,
      method: method,
      target: target,
      targetSpecified: targetSpecified,
      noopener: noopener,
      query: query,
      body: body,
      bodyBytes: Uint8List.fromList(bytes).asUnmodifiableView(),
      contentType: contentType,
      submitterId: submitterId,
    );
  }
}

/// Serializes ordered string entries using the UTF-8 HTML form URL encoding.
///
/// Names and values have standalone CR and LF characters normalized to CRLF,
/// spaces become `+`, and only ASCII alphanumerics plus `*`, `-`, `.`, and `_`
/// are left unescaped.
String nativeHtmlFormEncode(Iterable<NativeHtmlFormEntry> entries) => entries
    .map(
      (entry) =>
          '${_encodeFormComponent(_normalizeNewlines(entry.name))}='
          '${_encodeFormComponent(_normalizeNewlines(entry.value))}',
    )
    .join('&');

String _effectiveMethod(String method) {
  switch (method.toLowerCase()) {
    case 'post':
      return 'POST';
    case 'dialog':
      throw UnsupportedError(
        'Native HTML form dialog submissions are unsupported.',
      );
    default:
      // HTML's missing and invalid method state is GET.
      return 'GET';
  }
}

String _effectiveEnctype(String enctype) {
  switch (enctype.toLowerCase()) {
    case 'multipart/form-data':
      return 'multipart/form-data';
    case 'text/plain':
      return 'text/plain';
    case 'application/x-www-form-urlencoded':
    default:
      // HTML's missing and invalid enctype state is URL encoded.
      return 'application/x-www-form-urlencoded';
  }
}

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

String _replaceQuery(String action, String query) {
  if (action.isEmpty) return action;

  final fragmentStart = action.indexOf('#');
  final prefix = fragmentStart == -1
      ? action
      : action.substring(0, fragmentStart);
  final fragment = fragmentStart == -1 ? '' : action.substring(fragmentStart);
  final queryStart = prefix.indexOf('?');
  final path = queryStart == -1 ? prefix : prefix.substring(0, queryStart);

  // A form submission sets the URL query component even when it is empty.
  return '$path?$query$fragment';
}
