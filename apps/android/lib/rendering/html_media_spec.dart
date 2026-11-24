import 'render_l10n.dart';
import 'package:html/dom.dart' as dom;

enum NativeHtmlMediaKind { audio, video }

enum NativeHtmlMediaCandidateOrigin { srcAttribute, sourceElement }

/// A raw media URL from an element's `src` attribute or a child `<source>`.
///
/// URLs intentionally remain unresolved so the caller can resolve them against
/// the retained document's effective base URL. A source's `type` is preserved
/// as a hint; it is not treated as proof that the decoder supports the media.
class NativeHtmlMediaCandidate {
  const NativeHtmlMediaCandidate({
    required this.url,
    required this.origin,
    this.typeHint,
  });

  final String url;
  final NativeHtmlMediaCandidateOrigin origin;
  final String? typeHint;
}

class NativeHtmlMediaDiagnostic {
  const NativeHtmlMediaDiagnostic({
    required this.location,
    required this.value,
    required this.message,
  });

  final String location;
  final String value;
  final String message;
}

/// Parsed, non-widget metadata for a sanitized `<audio>` or `<video>` element.
///
/// [srcCandidate] and [sourceCandidates] keep the authored sources separate.
/// [candidates] follows HTML's selection rule: a present `src` attribute takes
/// precedence over child `<source>` elements, even when the attribute is
/// empty. When no `src` attribute exists, child sources remain in DOM order.
class NativeHtmlMediaSpec {
  NativeHtmlMediaSpec({
    required this.kind,
    required this.hasSrcAttribute,
    required this.rawSrc,
    required this.srcCandidate,
    required List<NativeHtmlMediaCandidate> sourceCandidates,
    required List<NativeHtmlMediaDiagnostic> diagnostics,
    required this.controls,
    required this.autoplay,
    required this.muted,
    required this.loop,
    required this.preload,
    required this.poster,
    required this.width,
    required this.height,
    required this.rawWidth,
    required this.rawHeight,
  }) : sourceCandidates = List.unmodifiable(sourceCandidates),
       diagnostics = List.unmodifiable(diagnostics),
       candidates = List.unmodifiable(
         hasSrcAttribute
             ? (srcCandidate == null ? const [] : [srcCandidate])
             : sourceCandidates,
       );

  factory NativeHtmlMediaSpec.fromElement(dom.Element element) {
    final kind = switch (element.localName) {
      'audio' => NativeHtmlMediaKind.audio,
      'video' => NativeHtmlMediaKind.video,
      _ => throw FormatException(
        'Expected an <audio> or <video> element; got <${element.localName}>.',
      ),
    };

    final diagnostics = <NativeHtmlMediaDiagnostic>[];
    final hasSrcAttribute = element.attributes.containsKey('src');
    final rawSrc = element.attributes['src'];
    NativeHtmlMediaCandidate? srcCandidate;
    if (hasSrcAttribute && rawSrc != null && _hasNonemptyUrl(rawSrc)) {
      final unsafe = _unsafeMediaUrl(rawSrc);
      if (unsafe != null) {
        throw FormatException('Unsafe media src attribute: $unsafe');
      }
      srcCandidate = NativeHtmlMediaCandidate(
        url: rawSrc,
        origin: NativeHtmlMediaCandidateOrigin.srcAttribute,
      );
    }

    final sourceCandidates = <NativeHtmlMediaCandidate>[];
    var sourceIndex = 0;
    for (final child in element.children) {
      if (child.localName != 'source') continue;
      final index = sourceIndex++;
      final url = child.attributes['src'];
      if (url == null || !_hasNonemptyUrl(url)) {
        if (child.attributes.containsKey('src')) {
          diagnostics.add(
            NativeHtmlMediaDiagnostic(
              location: 'source[$index].src',
              value: url ?? '',
              message: 'An empty source URL is ignored.',
            ),
          );
        }
        continue;
      }
      final unsafe = _unsafeMediaUrl(url);
      if (unsafe != null) {
        diagnostics.add(
          NativeHtmlMediaDiagnostic(
            location: 'source[$index].src',
            value: url,
            message: unsafe,
          ),
        );
        continue;
      }
      sourceCandidates.add(
        NativeHtmlMediaCandidate(
          url: url,
          typeHint: child.attributes['type'],
          origin: NativeHtmlMediaCandidateOrigin.sourceElement,
        ),
      );
    }

    final rawPoster = element.attributes['poster'];
    String? poster = rawPoster;
    if (rawPoster != null) {
      final unsafe = _unsafeMediaUrl(rawPoster, dataMimeCategory: 'image');
      if (unsafe != null) {
        diagnostics.add(
          NativeHtmlMediaDiagnostic(
            location: 'poster',
            value: rawPoster,
            message: unsafe,
          ),
        );
        poster = null;
      }
    }

    final rawWidth = element.attributes['width'];
    final rawHeight = element.attributes['height'];
    return NativeHtmlMediaSpec(
      kind: kind,
      hasSrcAttribute: hasSrcAttribute,
      rawSrc: rawSrc,
      srcCandidate: srcCandidate,
      sourceCandidates: sourceCandidates,
      diagnostics: diagnostics,
      controls: element.attributes.containsKey('controls'),
      autoplay: element.attributes.containsKey('autoplay'),
      muted: element.attributes.containsKey('muted'),
      loop: element.attributes.containsKey('loop'),
      preload: element.attributes['preload'],
      poster: poster,
      width: _parseNonNegativeInteger(rawWidth),
      height: _parseNonNegativeInteger(rawHeight),
      rawWidth: rawWidth,
      rawHeight: rawHeight,
    );
  }

  final NativeHtmlMediaKind kind;
  final bool hasSrcAttribute;
  final String? rawSrc;
  final NativeHtmlMediaCandidate? srcCandidate;
  final List<NativeHtmlMediaCandidate> sourceCandidates;

  /// Actual candidates in HTML selection order, before decoder `type` checks.
  ///
  /// Child sources are not fallbacks when the element has a `src` attribute.
  final List<NativeHtmlMediaCandidate> candidates;
  final List<NativeHtmlMediaDiagnostic> diagnostics;

  /// Boolean HTML attributes are true by presence, even when their text is
  /// `"false"` or empty.
  final bool controls;
  final bool autoplay;
  final bool muted;
  final bool loop;

  /// Literal `preload` hint. Null means the attribute was not authored.
  final String? preload;

  /// Safe raw poster URL, still relative when authored relative. Unsafe schemes
  /// are omitted and described in [diagnostics].
  final String? poster;

  /// Non-negative integer prefix from each authored width and height attribute.
  ///
  /// These are content attributes, not intrinsic media metadata. Null means an
  /// attribute has no leading non-negative integer or exceeds the integer
  /// range; zero is retained. The raw values remain available for CSS fallback.
  final int? width;
  final int? height;
  final String? rawWidth;
  final String? rawHeight;
}

bool _hasNonemptyUrl(String value) => _trimUrlControls(value).isNotEmpty;

int? _parseNonNegativeInteger(String? value) {
  if (value == null) return null;
  final match = RegExp(r'^[\t\n\f\r ]*(\d+)').firstMatch(value);
  if (match == null) return null;
  return int.tryParse(match.group(1)!);
}

String? _unsafeMediaUrl(
  String value, {
  String dataMimeCategory = 'audio|video',
}) {
  final canonical = _trimUrlControls(value);
  if (canonical.isEmpty) return null;
  final scheme = RegExp(
    r'^([A-Za-z][A-Za-z0-9+.-]*):',
  ).firstMatch(canonical)?.group(1)?.toLowerCase();
  if (scheme == null ||
      scheme == 'http' ||
      scheme == 'https' ||
      scheme == 'blob') {
    return null;
  }
  if (scheme == 'data') {
    final mime = RegExp(
      '^data:(?:$dataMimeCategory)/[A-Za-z0-9!#\$&^_.+-]+(?:;[^,]*)?,',
      caseSensitive: false,
    );
    if (mime.hasMatch(canonical)) return null;
    return tr("Only data:{0}/* URLs are allowed here.", [dataMimeCategory]);
  }
  return tr("The {0}: URL scheme is not allowed for native media.", [scheme]);
}

String _trimUrlControls(String value) => value
    .replaceAll(RegExp(r'[\t\n\r]'), '')
    .replaceAll(RegExp(r'^[\x00-\x20]+|[\x00-\x20]+$'), '');
