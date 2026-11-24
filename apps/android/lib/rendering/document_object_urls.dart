import 'render_l10n.dart';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:html/parser.dart' as html;

/// Computes the referrer for a navigation to a same-origin blob URL.
///
/// Referrer policies which would disclose an origin or URL to a same-origin
/// destination keep the source URL (without its fragment). Origin-only
/// policies return the source origin, and no-referrer returns an empty string.
String nativeBlobNavigationReferrer({
  required String sourceUrl,
  required String html,
  String? headerPolicy,
  String? elementPolicy,
  bool noreferrer = false,
}) {
  if (noreferrer) return '';
  final source = _parseHttpReferrerSource(sourceUrl);
  if (source == null) return '';

  final policy =
      _validReferrerPolicy(elementPolicy) ??
      _lastMetaReferrerPolicy(html) ??
      _lastHeaderReferrerPolicy(headerPolicy) ??
      'strict-origin-when-cross-origin';
  if (policy == 'no-referrer') return '';
  if (policy == 'origin' || policy == 'strict-origin') {
    return '${_httpOrigin(source)}/';
  }
  return sourceUrl.split('#').first;
}

const _referrerPolicies = <String>{
  'no-referrer',
  'no-referrer-when-downgrade',
  'origin',
  'origin-when-cross-origin',
  'same-origin',
  'strict-origin',
  'strict-origin-when-cross-origin',
  'unsafe-url',
};

String? _validReferrerPolicy(String? value) {
  if (value == null) return null;
  final normalized = value.trim().toLowerCase();
  return _referrerPolicies.contains(normalized) ? normalized : null;
}

String? _lastHeaderReferrerPolicy(String? header) {
  if (header == null) return null;
  String? result;
  for (final item in header.split(',')) {
    result = _validReferrerPolicy(item) ?? result;
  }
  return result;
}

String? _lastMetaReferrerPolicy(String source) {
  String? result;
  for (final element in html.parse(source).querySelectorAll('meta')) {
    if ((element.attributes['name'] ?? '').trim().toLowerCase() != 'referrer') {
      continue;
    }
    result = _validReferrerPolicy(element.attributes['content']) ?? result;
  }
  return result;
}

Uri? _parseHttpReferrerSource(String sourceUrl) {
  if (sourceUrl.trim() != sourceUrl) return null;
  final uri = Uri.tryParse(sourceUrl);
  if (uri == null ||
      !uri.hasAuthority ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      !{'http', 'https'}.contains(uri.scheme.toLowerCase())) {
    return null;
  }
  return uri;
}

String _httpOrigin(Uri uri) {
  final scheme = uri.scheme.toLowerCase();
  final host = uri.host.toLowerCase();
  final formattedHost = host.startsWith('[') && host.endsWith(']')
      ? host
      : host.contains(':')
      ? '[$host]'
      : host;
  final port = uri.hasPort ? uri.port : (scheme == 'https' ? 443 : 80);
  final defaultPort = scheme == 'https' ? 443 : 80;
  return '$scheme://$formattedHost${port == defaultPort ? '' : ':$port'}';
}

/// Bytes remain bound to the isolated document which created the opaque URL.
class NativeDocumentBlob {
  NativeDocumentBlob._(this.url, this.mimeType, this._bytes);
  static const maxBytes = 2 * 1024 * 1024;
  final String url, mimeType;
  final Uint8List _bytes;
  Uint8List get bytes => Uint8List.fromList(_bytes);
  factory NativeDocumentBlob.fromBridge(
    String requestedUrl,
    Map<String, dynamic> value,
  ) {
    final expected = requestedUrl.split('#').first;
    final encoded = value['bytesBase64'];
    final size = value['size'];
    if (!expected.startsWith('blob:') ||
        value['ok'] != true ||
        value['url'] != expected ||
        value['type'] is! String ||
        size is! int ||
        size < 0 ||
        size > maxBytes ||
        encoded is! String ||
        encoded.length > ((maxBytes + 2) ~/ 3) * 4 ||
        encoded.length % 4 != 0 ||
        !RegExp(r'^[A-Za-z0-9+/]*={0,2}$').hasMatch(encoded)) {
      throw const FormatException(
        'Invalid or unavailable document object URL.',
      );
    }
    final bytes = base64Decode(encoded);
    if (bytes.length != size || base64Encode(bytes) != encoded) {
      throw const FormatException('Invalid object URL byte count.');
    }
    return NativeDocumentBlob._(expected, value['type'] as String, bytes);
  }
}

class NativeDocumentObjectUrlBinding {
  NativeDocumentObjectUrlBinding({
    required this.owner,
    required this.isCurrent,
    required this.readBytes,
  });
  final Object owner;
  final bool Function() isCurrent;
  final Future<Map<String, dynamic>> Function(String) readBytes;
  bool get current => isCurrent();
  Future<NativeDocumentBlob> read(String url) async {
    if (!current || !url.startsWith('blob:')) {
      throw StateError(tr("Object URL document is unavailable."));
    }
    final value = await readBytes(url);
    if (!current) throw StateError(tr("Object URL document changed."));
    return NativeDocumentBlob.fromBridge(url, value);
  }
}

/// A capability to re-read an object URL from the document that created it.
///
/// This keeps only the creator identity and its live reader. Bytes are fetched
/// for each navigation or reload so revocation and creator teardown take effect.
class NativeDocumentBlobNavigationSource {
  NativeDocumentBlobNavigationSource({
    required this.creatorUrl,
    required this.binding,
    this.referrer,
    this.referrerPolicy = 'strict-origin-when-cross-origin',
    this._initialBlob,
  });

  NativeDocumentBlob? _initialBlob;
  final String creatorUrl;
  final NativeDocumentObjectUrlBinding binding;
  final String? referrer;
  final String referrerPolicy;

  String get documentReferrer =>
      referrer ??
      (_parseHttpReferrerSource(creatorUrl) == null
          ? ''
          : creatorUrl.split('#').first);

  Future<NativeDocumentBlob> read(String url) async {
    final creatorOrigin = _creatorHttpOrigin(creatorUrl);
    final requestedOrigin = _objectUrlHttpOrigin(url);
    if (creatorOrigin == null ||
        requestedOrigin == null ||
        creatorOrigin != requestedOrigin) {
      throw FormatException(
        tr("Object URL does not belong to its creator origin."),
      );
    }
    final captured = _initialBlob;
    if (captured != null && captured.url == url.split('#').first) {
      if (!binding.current) {
        throw StateError(tr("Object URL document changed."));
      }
      // Activation captured this immutable Blob before a subsequent revoke.
      // Only the initial load may use it; reload still consults the live URL.
      _initialBlob = null;
      return captured;
    }
    return binding.read(url);
  }

  static String? _creatorHttpOrigin(String value) {
    if (value.trim() != value) return null;
    final uri = Uri.tryParse(value);
    if (uri == null) return null;
    final scheme = uri.scheme.toLowerCase();
    if (scheme == 'http' || scheme == 'https') {
      return _httpOrigin(uri);
    }
    if (scheme == 'blob') {
      return _objectUrlHttpOrigin(value);
    }
    return null;
  }

  static String? _objectUrlHttpOrigin(String value) {
    if (value.trim() != value) return null;
    final match = RegExp(
      r'^blob:(https?://[^/?#]+)(?:[/?#]|$)',
      caseSensitive: false,
    ).firstMatch(value);
    if (match == null) return null;
    final uri = Uri.tryParse(match.group(1)!);
    if (uri == null) return null;
    return _httpOrigin(uri);
  }

  static String? _httpOrigin(Uri uri) {
    final scheme = uri.scheme.toLowerCase();
    if ((scheme != 'http' && scheme != 'https') ||
        !uri.hasAuthority ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty) {
      return null;
    }
    final port = uri.hasPort ? uri.port : (scheme == 'https' ? 443 : 80);
    return '$scheme://${uri.host.toLowerCase()}:$port';
  }
}

class NativeDocumentObjectUrlScope extends InheritedWidget {
  const NativeDocumentObjectUrlScope({
    super.key,
    required this.binding,
    required super.child,
  });
  final NativeDocumentObjectUrlBinding binding;
  static NativeDocumentObjectUrlScope? maybeOf(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<NativeDocumentObjectUrlScope>();
  @override
  bool updateShouldNotify(NativeDocumentObjectUrlScope oldWidget) =>
      !identical(binding, oldWidget.binding);
}
