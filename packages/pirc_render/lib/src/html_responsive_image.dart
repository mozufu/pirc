import 'package:html/dom.dart' as dom;

const _supportedImageMimes = <String>{
  'image/avif',
  'image/gif',
  'image/jpeg',
  'image/png',
  'image/svg+xml',
  'image/webp',
};

/// A selected safe URL and its source-pixel density.
///
/// An empty [url] means no usable image candidate was found. [density] is the
/// number of source pixels per CSS pixel and should be passed to the image
/// widget as its scale so natural dimensions remain in CSS pixels.
class NativeResponsiveImageSelection {
  NativeResponsiveImageSelection({
    required this.url,
    required this.density,
    required List<String> diagnostics,
  }) : diagnostics = List.unmodifiable(diagnostics);

  final String url;
  final double density;
  final List<String> diagnostics;
}

/// Selects a candidate from a sanitized image and its enclosing picture.
///
/// Supported source-set descriptors are positive density (x) and width (w)
/// values. Width candidates use the first matching basic sizes rule, with a
/// 100vw default. Picture sources are considered in document order before the
/// fallback image.
NativeResponsiveImageSelection selectNativeResponsiveImage(
  dom.Element img, {
  required double viewportWidth,
  required double devicePixelRatio,
  double viewportHeight = 800,
  bool dark = false,
  bool avifSupported = false,
}) {
  final diagnostics = <String>[];
  final width = _positiveFinite(viewportWidth);
  final height = _positiveFinite(viewportHeight);
  final dpr = _positiveFinite(devicePixelRatio);
  if (width == null) diagnostics.add('viewport.invalid-width');
  if (height == null) diagnostics.add('viewport.invalid-height');
  if (dpr == null) diagnostics.add('viewport.invalid-device-pixel-ratio');

  final safeWidth = width ?? 1;
  final safeHeight = height ?? 800;
  final safeDpr = dpr ?? 1;

  final pictureSelection = _selectPictureSource(
    img,
    avifSupported: avifSupported,
    viewportWidth: safeWidth,
    viewportHeight: safeHeight,
    devicePixelRatio: safeDpr,
    dark: dark,
    diagnostics: diagnostics,
  );
  final selected =
      pictureSelection ??
      _selectElementCandidate(
        img,
        allowSrcFallback: true,
        avifSupported: avifSupported,
        viewportWidth: safeWidth,
        viewportHeight: safeHeight,
        devicePixelRatio: safeDpr,
        dark: dark,
        diagnostics: diagnostics,
      );

  return NativeResponsiveImageSelection(
    url: selected?.url ?? '',
    density: selected?.value ?? 1,
    diagnostics: diagnostics,
  );
}

enum _DescriptorKind { density, width }

class _RawCandidate {
  const _RawCandidate(this.url, this.descriptors);

  final String url;
  final List<String> descriptors;
}

class _ResponsiveCandidate {
  const _ResponsiveCandidate({
    required this.url,
    required this.kind,
    required this.value,
    required this.order,
  });

  final String url;
  final _DescriptorKind kind;
  final double value;
  final int order;
}

class _ParsedSourceSet {
  const _ParsedSourceSet(this.kind, this.candidates);

  final _DescriptorKind kind;
  final List<_ResponsiveCandidate> candidates;
}

_ResponsiveCandidate? _selectPictureSource(
  dom.Element img, {
  required bool avifSupported,
  required double viewportWidth,
  required double viewportHeight,
  required double devicePixelRatio,
  required bool dark,
  required List<String> diagnostics,
}) {
  final parent = img.parentNode;
  if (parent is! dom.Element || parent.localName != 'picture') return null;

  final imgIndex = parent.children.indexOf(img);
  if (imgIndex < 0) return null;

  for (var index = 0; index < imgIndex; index++) {
    final source = parent.children[index];
    if (source.localName != 'source') continue;
    if (!_matchesMedia(
      source.attributes['media'],
      viewportWidth: viewportWidth,
      viewportHeight: viewportHeight,
      dark: dark,
      diagnostics: diagnostics,
    )) {
      continue;
    }
    if (!_supportsSourceType(
      source.attributes['type'],
      diagnostics,
      avifSupported,
    )) {
      continue;
    }

    final selected = _selectElementCandidate(
      source,
      allowSrcFallback: false,
      avifSupported: avifSupported,
      viewportWidth: viewportWidth,
      viewportHeight: viewportHeight,
      devicePixelRatio: devicePixelRatio,
      dark: dark,
      diagnostics: diagnostics,
    );
    if (selected != null) return selected;
  }

  return null;
}

bool _supportsSourceType(
  String? rawType,
  List<String> diagnostics,
  bool avifSupported,
) {
  final value = rawType?.trim();
  if (value == null || value.isEmpty) return true;

  final mime = value.split(';').first.trim().toLowerCase();
  if (_supportedImageMimes.contains(mime) &&
      (mime != 'image/avif' || avifSupported)) {
    return true;
  }
  diagnostics.add('picture.unsupported-type: $mime');
  return false;
}

_ResponsiveCandidate? _selectElementCandidate(
  dom.Element element, {
  required bool allowSrcFallback,
  required bool avifSupported,
  required double viewportWidth,
  required double viewportHeight,
  required double devicePixelRatio,
  required bool dark,
  required List<String> diagnostics,
}) {
  final rawSrcset = element.attributes['srcset'];
  if (rawSrcset != null) {
    if (rawSrcset.trim().isEmpty) {
      diagnostics.add('srcset.empty');
    } else {
      final sourceSet = _parseSrcset(rawSrcset, diagnostics, avifSupported);
      if (sourceSet != null && sourceSet.candidates.isNotEmpty) {
        final candidates = <_ResponsiveCandidate>[...sourceSet.candidates];
        if (allowSrcFallback &&
            sourceSet.kind == _DescriptorKind.density &&
            !candidates.any((candidate) => candidate.value == 1)) {
          final src = _safeSourceUrl(
            element.attributes['src'],
            'img.src',
            diagnostics,
            avifSupported,
          );
          if (src != null) {
            candidates.add(
              _ResponsiveCandidate(
                url: src,
                kind: _DescriptorKind.density,
                value: 1,
                order: candidates.length,
              ),
            );
          }
        }

        final cssSlot = sourceSet.kind == _DescriptorKind.width
            ? _resolveSizes(
                element.attributes['sizes'],
                viewportWidth: viewportWidth,
                viewportHeight: viewportHeight,
                dark: dark,
                diagnostics: diagnostics,
              )
            : 1.0;
        final densityCandidates = <_ResponsiveCandidate>[];
        for (final candidate in candidates) {
          final density = sourceSet.kind == _DescriptorKind.width
              ? candidate.value / cssSlot
              : candidate.value;
          if (!density.isFinite || density <= 0) {
            diagnostics.add('srcset.invalid-density: ${candidate.url}');
            continue;
          }
          densityCandidates.add(
            _ResponsiveCandidate(
              url: candidate.url,
              kind: _DescriptorKind.density,
              value: density,
              order: candidate.order,
            ),
          );
        }

        final selected = _chooseCandidate(densityCandidates, devicePixelRatio);
        if (selected != null) return selected;
      }
    }
  }

  if (!allowSrcFallback) return null;
  final src = _safeSourceUrl(
    element.attributes['src'],
    'img.src',
    diagnostics,
    avifSupported,
  );
  if (src == null) return null;
  return _ResponsiveCandidate(
    url: src,
    kind: _DescriptorKind.density,
    value: 1,
    order: 0,
  );
}

String? _safeSourceUrl(
  String? rawUrl,
  String location,
  List<String> diagnostics,
  bool avifSupported,
) {
  if (rawUrl == null || rawUrl.isEmpty) return null;
  final url = _trimUrlControls(rawUrl);
  if (url.isEmpty) return null;

  final scheme = RegExp(
    r'^([A-Za-z][A-Za-z0-9+.-]*):',
  ).firstMatch(url)?.group(1)?.toLowerCase();
  if (scheme == null ||
      scheme == 'http' ||
      scheme == 'https' ||
      scheme == 'blob') {
    return url;
  }

  if (scheme == 'data') {
    final mime = RegExp(
      r'^data:([^;,]+)(?:;[^,]*)?,',
      caseSensitive: false,
    ).firstMatch(url)?.group(1)?.toLowerCase();
    if (mime != null &&
        _supportedImageMimes.contains(mime) &&
        (mime != 'image/avif' || avifSupported)) {
      return url;
    }
    diagnostics.add('url.unsafe-data-mime: $location');
    return null;
  }

  diagnostics.add('url.unsafe-scheme: $scheme ($location)');
  return null;
}

String _trimUrlControls(String value) => value
    .replaceAll(RegExp(r'[\t\n\r]'), '')
    .replaceAll(RegExp(r'^[\x00-\x20]+|[\x00-\x20]+$'), '');

_ParsedSourceSet? _parseSrcset(
  String input,
  List<String> diagnostics,
  bool avifSupported,
) {
  final rawCandidates = _tokenizeSrcset(input);
  if (rawCandidates.isEmpty) {
    diagnostics.add('srcset.empty');
    return null;
  }

  final kinds = <_DescriptorKind>{};
  for (final candidate in rawCandidates) {
    // A candidate with multiple descriptors is invalid as a whole. Do not let
    // its extra descriptor make otherwise-valid candidates look like a mixed
    // list (for example, `400w 2x, 800w`).
    if (candidate.descriptors.length > 1) continue;
    if (candidate.descriptors.isEmpty) {
      kinds.add(_DescriptorKind.density);
      continue;
    }
    for (final descriptor in candidate.descriptors) {
      final lower = descriptor.toLowerCase();
      if (lower.endsWith('x')) kinds.add(_DescriptorKind.density);
      if (lower.endsWith('w')) kinds.add(_DescriptorKind.width);
    }
  }
  if (kinds.length > 1) {
    diagnostics.add('srcset.mixed-descriptors');
    return null;
  }
  final kind = kinds.isEmpty ? _DescriptorKind.density : kinds.single;

  final candidates = <_ResponsiveCandidate>[];
  for (var index = 0; index < rawCandidates.length; index++) {
    final raw = rawCandidates[index];
    final descriptor = _parseCandidateDescriptor(raw, kind, diagnostics);
    if (descriptor == null) continue;
    final url = _safeSourceUrl(raw.url, 'srcset', diagnostics, avifSupported);
    if (url == null) continue;
    candidates.add(
      _ResponsiveCandidate(
        url: url,
        kind: kind,
        value: descriptor,
        order: index,
      ),
    );
  }

  return _ParsedSourceSet(kind, candidates);
}

double? _parseCandidateDescriptor(
  _RawCandidate candidate,
  _DescriptorKind listKind,
  List<String> diagnostics,
) {
  if (candidate.descriptors.isEmpty) {
    return listKind == _DescriptorKind.density ? 1 : null;
  }
  if (candidate.descriptors.length > 1) {
    final normalized = candidate.descriptors.map((value) {
      final lower = value.toLowerCase();
      if (lower.endsWith('x')) {
        return 'x:${lower.substring(0, lower.length - 1)}';
      }
      if (lower.endsWith('w')) {
        return 'w:${lower.substring(0, lower.length - 1)}';
      }
      return '?:$lower';
    }).toSet();
    diagnostics.add(
      normalized.length < candidate.descriptors.length
          ? 'srcset.duplicate-descriptor: ${candidate.url}'
          : 'srcset.invalid-descriptor-count: ${candidate.url}',
    );
    return null;
  }

  final descriptor = candidate.descriptors.single.toLowerCase();
  if (listKind == _DescriptorKind.density && descriptor.endsWith('x')) {
    final value = _parsePositiveNumber(
      descriptor.substring(0, descriptor.length - 1),
    );
    if (value != null) return value;
  } else if (listKind == _DescriptorKind.width && descriptor.endsWith('w')) {
    final rawWidth = descriptor.substring(0, descriptor.length - 1);
    if (RegExp(r'^\d+$').hasMatch(rawWidth)) {
      final width = int.tryParse(rawWidth);
      if (width != null && width > 0) return width.toDouble();
    }
  }

  diagnostics.add('srcset.invalid-descriptor: ${candidate.url}');
  return null;
}

List<_RawCandidate> _tokenizeSrcset(String input) {
  final candidates = <_RawCandidate>[];
  var position = 0;
  while (position < input.length) {
    while (position < input.length &&
        (_isHtmlWhitespace(input.codeUnitAt(position)) ||
            input.codeUnitAt(position) == 0x2c)) {
      position++;
    }
    if (position >= input.length) break;

    final urlStart = position;
    while (position < input.length &&
        !_isHtmlWhitespace(input.codeUnitAt(position))) {
      position++;
    }
    var url = input.substring(urlStart, position);
    final endedWithComma = url.endsWith(',');
    while (url.endsWith(',')) {
      url = url.substring(0, url.length - 1);
    }
    if (url.isEmpty) continue;

    if (endedWithComma) {
      candidates.add(_RawCandidate(url, const []));
      continue;
    }

    final descriptors = <String>[];
    while (position < input.length) {
      while (position < input.length &&
          _isHtmlWhitespace(input.codeUnitAt(position))) {
        position++;
      }
      if (position >= input.length) break;
      if (input.codeUnitAt(position) == 0x2c) {
        position++;
        break;
      }

      final descriptorStart = position;
      while (position < input.length &&
          !_isHtmlWhitespace(input.codeUnitAt(position)) &&
          input.codeUnitAt(position) != 0x2c) {
        position++;
      }
      if (descriptorStart < position) {
        descriptors.add(input.substring(descriptorStart, position));
      }
      if (position < input.length && input.codeUnitAt(position) == 0x2c) {
        position++;
        break;
      }
    }
    candidates.add(_RawCandidate(url, descriptors));
  }
  return candidates;
}

bool _isHtmlWhitespace(int codeUnit) =>
    codeUnit == 0x09 ||
    codeUnit == 0x0a ||
    codeUnit == 0x0c ||
    codeUnit == 0x0d ||
    codeUnit == 0x20;

double? _parsePositiveNumber(String value) {
  if (!RegExp(
    r'^\+?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?$',
  ).hasMatch(value)) {
    return null;
  }
  final number = double.tryParse(value);
  return number != null && number.isFinite && number > 0 ? number : null;
}

_ResponsiveCandidate? _chooseCandidate(
  List<_ResponsiveCandidate> candidates,
  double devicePixelRatio,
) {
  if (candidates.isEmpty) return null;
  candidates.sort((left, right) {
    final byDensity = left.value.compareTo(right.value);
    return byDensity == 0 ? left.order.compareTo(right.order) : byDensity;
  });
  for (final candidate in candidates) {
    if (candidate.value >= devicePixelRatio) return candidate;
  }
  return candidates.last;
}

double _resolveSizes(
  String? rawSizes, {
  required double viewportWidth,
  required double viewportHeight,
  required bool dark,
  required List<String> diagnostics,
}) {
  if (rawSizes == null || rawSizes.trim().isEmpty) return viewportWidth;

  for (final rule in _splitTopLevel(rawSizes, ',')) {
    final value = rule.trim();
    if (value.isEmpty) continue;

    final directLength = _parseSourceSize(value, viewportWidth);
    if (directLength != null && directLength > 0) return directLength;

    final split = _splitLastWhitespaceOutsideParens(value);
    if (split == null) {
      diagnostics.add('sizes.unsupported-length: $value');
      continue;
    }
    final size = _parseSourceSize(split.$2, viewportWidth);
    if (size == null || size <= 0) {
      diagnostics.add('sizes.unsupported-length: ${split.$2}');
      continue;
    }
    if (_matchesMedia(
      split.$1,
      viewportWidth: viewportWidth,
      viewportHeight: viewportHeight,
      dark: dark,
      diagnostics: diagnostics,
    )) {
      return size;
    }
  }

  return viewportWidth;
}

double? _parseSourceSize(String value, double viewportWidth) {
  final normalized = value.trim();
  final minFunction = RegExp(
    r'^min\((.*)\)$',
    caseSensitive: false,
  ).firstMatch(normalized);
  if (minFunction != null) {
    final arguments = _splitTopLevel(minFunction.group(1)!, ',');
    if (arguments.length < 2) return null;
    final lengths = <double>[];
    for (final argument in arguments) {
      final length = _parseSimpleSourceSize(argument, viewportWidth);
      if (length == null) return null;
      lengths.add(length);
    }
    return lengths.reduce((left, right) => left < right ? left : right);
  }

  return _parseSimpleSourceSize(normalized, viewportWidth);
}

double? _parseSimpleSourceSize(String value, double viewportWidth) {
  final match = RegExp(
    r'^(\d+(?:\.\d+)?|\.\d+)(px|vw)$',
    caseSensitive: false,
  ).firstMatch(value.trim());
  if (match == null) return null;
  final amount = double.tryParse(match.group(1)!);
  if (amount == null || !amount.isFinite) return null;
  if (match.group(2)!.toLowerCase() == 'px') return amount;
  return viewportWidth * amount / 100;
}

(String, String)? _splitLastWhitespaceOutsideParens(String value) {
  var depth = 0;
  for (var index = value.length - 1; index >= 0; index--) {
    final character = value[index];
    if (character == ')') depth++;
    if (character == '(') depth--;
    if (depth == 0 && _isHtmlWhitespace(character.codeUnitAt(0))) {
      final left = value.substring(0, index).trim();
      final right = value.substring(index + 1).trim();
      if (left.isNotEmpty && right.isNotEmpty) return (left, right);
    }
  }
  return null;
}

bool _matchesMedia(
  String? rawMedia, {
  required double viewportWidth,
  required double viewportHeight,
  required bool dark,
  required List<String> diagnostics,
}) {
  if (rawMedia == null || rawMedia.trim().isEmpty) return true;

  var matched = false;
  for (final alternative in _splitTopLevel(rawMedia, ',')) {
    final result = _evaluateMediaAlternative(
      alternative.trim(),
      viewportWidth: viewportWidth,
      viewportHeight: viewportHeight,
      dark: dark,
    );
    if (result == null) {
      diagnostics.add('media.unsupported-query: ${alternative.trim()}');
    } else if (result) {
      matched = true;
    }
  }
  return matched;
}

bool? _evaluateMediaAlternative(
  String query, {
  required double viewportWidth,
  required double viewportHeight,
  required bool dark,
}) {
  if (query.isEmpty) return null;
  final parts = _splitMediaAnd(query);
  if (parts == null || parts.isEmpty) return null;

  var matches = true;
  for (final rawPart in parts) {
    final part = rawPart.trim().toLowerCase();
    if (part == 'all' || part == 'screen') continue;
    if (part == 'print') {
      matches = false;
      continue;
    }
    if (!part.startsWith('(') || !part.endsWith(')')) return null;

    final feature = part.substring(1, part.length - 1).trim();
    final colorScheme = RegExp(
      r'^prefers-color-scheme\s*:\s*(dark|light)$',
    ).firstMatch(feature);
    if (colorScheme != null) {
      final wantsDark = colorScheme.group(1) == 'dark';
      matches = matches && (dark == wantsDark);
      continue;
    }

    final dimension = RegExp(
      r'^(min|max)-(width|height)\s*:\s*(\d+(?:\.\d+)?|\.\d+)(px|em|rem)$',
    ).firstMatch(feature);
    if (dimension == null) return null;
    final amount = double.tryParse(dimension.group(3)!);
    if (amount == null || !amount.isFinite || amount < 0) return null;
    final unit = dimension.group(4)!;
    final pixels = unit == 'px' ? amount : amount * 16;
    final viewport = dimension.group(2) == 'width'
        ? viewportWidth
        : viewportHeight;
    final conditionMatches = dimension.group(1) == 'min'
        ? viewport >= pixels
        : viewport <= pixels;
    matches = matches && conditionMatches;
  }
  return matches;
}

List<String>? _splitMediaAnd(String value) {
  final parts = <String>[];
  final lower = value.toLowerCase();
  var depth = 0;
  var start = 0;
  var index = 0;
  while (index < value.length) {
    final character = value[index];
    if (character == '(') depth++;
    if (character == ')') {
      depth--;
      if (depth < 0) return null;
    }

    if (depth == 0 &&
        lower.startsWith('and', index) &&
        index > 0 &&
        index + 3 < value.length &&
        _isHtmlWhitespace(value.codeUnitAt(index - 1)) &&
        _isHtmlWhitespace(value.codeUnitAt(index + 3))) {
      parts.add(value.substring(start, index).trim());
      index += 3;
      start = index;
      continue;
    }
    index++;
  }
  if (depth != 0) return null;
  parts.add(value.substring(start).trim());
  return parts;
}

List<String> _splitTopLevel(String value, String separator) {
  final result = <String>[];
  var depth = 0;
  var start = 0;
  for (var index = 0; index < value.length; index++) {
    if (value[index] == '(') depth++;
    if (value[index] == ')') depth--;
    if (depth == 0 && value[index] == separator) {
      result.add(value.substring(start, index));
      start = index + 1;
    }
  }
  result.add(value.substring(start));
  return result;
}

double? _positiveFinite(double value) =>
    value.isFinite && value > 0 ? value : null;
