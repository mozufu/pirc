import 'package:html/parser.dart' as html;

const nativeReferrerPolicies = <String>{
  'no-referrer',
  'no-referrer-when-downgrade',
  'origin',
  'origin-when-cross-origin',
  'same-origin',
  'strict-origin',
  'strict-origin-when-cross-origin',
  'unsafe-url',
};

/// Per-navigation referrer policy shared by the document host and its cache.
/// The source is the initiating document URL, never an authored base element.
class NativeDocumentReferrer {
  const NativeDocumentReferrer(this.url, this.policy);
  final String url, policy;

  Map<String, String> get requestArguments => {
    'referrerUrl': url,
    'referrerPolicy': policy,
  };

  Map<String, String> requestMetadata(String destination) => {
    'requestReferrer': forTarget(destination),
    'requestReferrerPolicy': policy,
  };

  factory NativeDocumentReferrer.fromRequest(Map<String, dynamic> arguments) =>
      NativeDocumentReferrer.fromDocument(
        url: arguments['referrerUrl'] as String? ?? '',
        headerPolicy: arguments['referrerPolicy'] as String?,
      );

  factory NativeDocumentReferrer.fromDocument({
    required String url,
    String source = '',
    String? headerPolicy,
    String? elementPolicy,
    bool noreferrer = false,
  }) {
    String? attributePolicy(String? value) {
      final normalized = value?.trim().toLowerCase();
      return nativeReferrerPolicies.contains(normalized) ? normalized : null;
    }

    String? policy;
    for (final token in (headerPolicy ?? '').split(',')) {
      final candidate = token.trim().toLowerCase();
      if (nativeReferrerPolicies.contains(candidate)) policy = candidate;
    }
    for (final meta in html.parse(source).querySelectorAll('meta[name]')) {
      if ((meta.attributes['name'] ?? '').toLowerCase() == 'referrer') {
        policy = attributePolicy(meta.attributes['content']) ?? policy;
      }
    }
    return NativeDocumentReferrer(
      url,
      noreferrer
          ? 'no-referrer'
          : attributePolicy(elementPolicy) ??
                policy ??
                'strict-origin-when-cross-origin',
    );
  }

  /// Carries only the value disclosed by the previous hop. A later redirect
  /// policy cannot recover a path which an earlier hop already removed.
  NativeDocumentReferrer afterRequestTo(
    String destination, {
    String? responsePolicy,
  }) {
    var nextPolicy = policy;
    for (final item in (responsePolicy ?? '').split(',')) {
      final candidate = item.trim().toLowerCase();
      if (nativeReferrerPolicies.contains(candidate)) nextPolicy = candidate;
    }
    return NativeDocumentReferrer(forTarget(destination), nextPolicy);
  }

  String forTarget(String destination) {
    var source = Uri.tryParse(url);
    final target = Uri.tryParse(destination);
    if (source == null ||
        target == null ||
        !source.hasAuthority ||
        !target.hasAuthority ||
        source.host.isEmpty ||
        target.host.isEmpty ||
        !{'http', 'https'}.contains(source.scheme) ||
        !{'http', 'https'}.contains(target.scheme)) {
      return '';
    }
    source = source.replace(userInfo: '', fragment: '');
    final origin = source
        .replace(path: '/', query: '', fragment: '')
        .toString()
        .split('?')
        .first
        .split('#')
        .first;
    var full = source.toString().split('#').first;
    if (source.path.isEmpty) {
      full = source.replace(path: '/').toString().split('#').first;
    }
    if (full.length > 4096) full = origin;
    final same =
        source.scheme == target.scheme &&
        source.host == target.host &&
        source.port == target.port;
    final downgrade = _trustworthy(source) && !_trustworthy(target);
    return switch (policy) {
      'no-referrer' => '',
      'no-referrer-when-downgrade' => downgrade ? '' : full,
      'origin' => origin,
      'origin-when-cross-origin' => same ? full : origin,
      'same-origin' => same ? full : '',
      'strict-origin' => downgrade ? '' : origin,
      'strict-origin-when-cross-origin' =>
        same
            ? full
            : downgrade
            ? ''
            : origin,
      'unsafe-url' => full,
      _ => '',
    };
  }
}

bool _trustworthy(Uri url) {
  if (url.scheme == 'https') return true;
  final host = url.host.toLowerCase();
  if (host == 'localhost' || host.endsWith('.localhost') || host == '::1') {
    return true;
  }
  final parts = host.split('.');
  return parts.length == 4 &&
      parts.first == '127' &&
      parts.every((part) {
        final number = int.tryParse(part);
        return number != null && number >= 0 && number <= 255;
      });
}
