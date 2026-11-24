import 'render_l10n.dart';
import 'dart:math' as math;

import 'package:flutter/painting.dart';
import 'package:xml/xml.dart';

import 'svg_dimensions.dart';

/// Resolves an SVG image's intrinsic sizing and root viewBox fitting rules for
/// CSS background painting.
///
/// [intrinsicSize] reports the image's intrinsic dimensions, while
/// [sizeFor] resolves CSS `background-size: auto`. An SVG with a viewBox ratio
/// but no intrinsic width or height uses the positioning area's contain
/// constraint. When one intrinsic axis has no ratio, CSS auto uses the
/// positioning area for its missing axis. An SVG with neither dimensions nor
/// ratio uses the positioning area itself. This differs from
/// `HTMLImageElement.naturalWidth`, which can
/// report the SVG fallback size of 300 by 150.
class NativeSvgBackgroundDimensions {
  const NativeSvgBackgroundDimensions._(
    this._autoSizing, {
    required this.intrinsicSize,
    required this.viewBoxSize,
    required this.aspectRatio,
    required this.hasIntrinsicWidth,
    required this.hasIntrinsicHeight,
    required this.pictureFit,
    required this.pictureAlignment,
  });

  factory NativeSvgBackgroundDimensions.fromSource(String source) {
    final XmlElement root;
    try {
      root = XmlDocument.parse(source).rootElement;
    } on XmlException catch (error) {
      throw FormatException('Invalid SVG XML: ${error.message}', source);
    }
    if (root.name.local.toLowerCase() != 'svg') {
      throw FormatException('The image root element is not SVG.', source);
    }

    final hasWidth = _hasAbsoluteSvgLength(root.getAttribute('width'));
    final hasHeight = _hasAbsoluteSvgLength(root.getAttribute('height'));
    final intrinsicSize = svgImageSize(source);
    final viewBoxSize = _parseViewBox(root.getAttribute('viewBox'));
    final viewBoxRatio = viewBoxSize == null || viewBoxSize.height == 0
        ? null
        : viewBoxSize.width / viewBoxSize.height;
    final ratio = hasWidth && hasHeight && intrinsicSize.height > 0
        ? intrinsicSize.width / intrinsicSize.height
        : viewBoxRatio;
    final hasViewBoxRatio = viewBoxRatio != null;
    final autoSizing = !hasViewBoxRatio && hasWidth != hasHeight
        ? hasWidth
              ? _SvgAutoSizing.widthOnly
              : _SvgAutoSizing.heightOnly
        : hasWidth || hasHeight
        ? _SvgAutoSizing.intrinsic
        : hasViewBoxRatio
        ? _SvgAutoSizing.ratioOnly
        : _SvgAutoSizing.positioningArea;
    final (pictureFit, pictureAlignment) = _parsePreserveAspectRatio(
      root.getAttribute('preserveAspectRatio'),
      source,
    );

    return NativeSvgBackgroundDimensions._(
      autoSizing,
      intrinsicSize: intrinsicSize,
      viewBoxSize: viewBoxSize,
      aspectRatio: ratio,
      hasIntrinsicWidth: hasWidth,
      hasIntrinsicHeight: hasHeight,
      pictureFit: pictureFit,
      pictureAlignment: pictureAlignment,
    );
  }

  /// Intrinsic image dimensions from the shared SVG unit parser.
  final Size intrinsicSize;

  /// Parsed viewBox width and height, if valid and positive.
  final Size? viewBoxSize;

  /// The source's intrinsic aspect ratio, when it has one.
  final double? aspectRatio;

  final bool hasIntrinsicWidth;
  final bool hasIntrinsicHeight;

  /// How the SVG viewBox content fits its intrinsic viewport, from the root
  /// `preserveAspectRatio` attribute (`meet`, `slice`, or `none`).
  final BoxFit pictureFit;

  /// SVG viewBox alignment from `preserveAspectRatio`; defaults to center.
  final Alignment pictureAlignment;

  final _SvgAutoSizing _autoSizing;

  /// Resolves the concrete CSS background image size inside [box].
  ///
  /// `BoxFit.none` models CSS `background-size: auto`. Other fits scale the
  /// intrinsic object into the positioning area using the corresponding
  /// uniform-fit rule; `BoxFit.fill` uses the area dimensions directly.
  Size sizeFor(Size box, {BoxFit fit = BoxFit.none}) {
    if (!box.width.isFinite ||
        !box.height.isFinite ||
        box.width < 0 ||
        box.height < 0) {
      return Size.zero;
    }

    if (_autoSizing == _SvgAutoSizing.widthOnly) {
      return fit == BoxFit.none ? Size(intrinsicSize.width, box.height) : box;
    }
    if (_autoSizing == _SvgAutoSizing.heightOnly) {
      return fit == BoxFit.none ? Size(box.width, intrinsicSize.height) : box;
    }

    final Size sourceSize;
    if (_autoSizing == _SvgAutoSizing.positioningArea) {
      sourceSize = box;
    } else if (_autoSizing == _SvgAutoSizing.ratioOnly) {
      final ratio = aspectRatio;
      if (ratio == null || ratio <= 0 || !ratio.isFinite) return box;
      sourceSize = Size(ratio, 1);
    } else {
      sourceSize = intrinsicSize;
    }

    if (fit == BoxFit.none) {
      if (_autoSizing == _SvgAutoSizing.ratioOnly) {
        return _fit(sourceSize, box, BoxFit.contain);
      }
      return sourceSize;
    }
    if (fit == BoxFit.fill) return box;
    return _fit(sourceSize, box, fit);
  }

  static Size _fit(Size source, Size box, BoxFit fit) {
    if (box.width <= 0 ||
        box.height <= 0 ||
        source.width <= 0 ||
        source.height <= 0 ||
        !source.width.isFinite ||
        !source.height.isFinite) {
      return Size.zero;
    }

    final scaleX = box.width / source.width;
    final scaleY = box.height / source.height;
    final double scale;
    switch (fit) {
      case BoxFit.contain:
        scale = math.min(scaleX, scaleY);
      case BoxFit.cover:
        scale = math.max(scaleX, scaleY);
      case BoxFit.fitWidth:
        scale = scaleX;
      case BoxFit.fitHeight:
        scale = scaleY;
      case BoxFit.scaleDown:
        scale = math.min(1, math.min(scaleX, scaleY));
      case BoxFit.fill:
        return box;
      case BoxFit.none:
        return source;
    }
    if (!scale.isFinite || scale < 0) return Size.zero;
    return Size(source.width * scale, source.height * scale);
  }
}

enum _SvgAutoSizing {
  intrinsic,
  widthOnly,
  heightOnly,
  ratioOnly,
  positioningArea,
}

bool _hasAbsoluteSvgLength(String? value) {
  final match = RegExp(
    r'^\s*([+-]?(?:\d+|\d*\.\d+)(?:[eE][+-]?\d+)?)(?:px|pt|pc|in|cm|mm|q)?\s*$',
    caseSensitive: false,
  ).firstMatch(value ?? '');
  if (match == null) return false;
  final length = double.tryParse(match[1]!);
  return length != null && length >= 0 && length.isFinite;
}

Size? _parseViewBox(String? value) {
  final parts = (value ?? '')
      .trim()
      .split(RegExp(r'[\s,]+'))
      .map(double.tryParse)
      .toList(growable: false);
  if (parts.length != 4 ||
      parts.any((part) => part == null || !part.isFinite)) {
    return null;
  }
  final width = parts[2]!;
  final height = parts[3]!;
  if (width <= 0 || height <= 0) return null;
  return Size(width, height);
}

(BoxFit, Alignment) _parsePreserveAspectRatio(String? value, String source) {
  var tokens = (value ?? '').trim().split(RegExp(r'\s+'))
    ..removeWhere((token) => token.isEmpty);
  if (tokens.isNotEmpty && tokens.first.toLowerCase() == 'defer') {
    tokens = tokens.skip(1).toList();
  }
  if (tokens.isEmpty) return (BoxFit.contain, Alignment.center);
  final alignmentName = tokens.first.toLowerCase();
  if (alignmentName == 'none') {
    if (tokens.length != 1) {
      throw FormatException(
        tr("Invalid preserveAspectRatio none value."),
        source,
      );
    }
    return (BoxFit.fill, Alignment.center);
  }

  const alignments = <String, Alignment>{
    'xminymin': Alignment.topLeft,
    'xmidymin': Alignment.topCenter,
    'xmaxymin': Alignment.topRight,
    'xminymid': Alignment.centerLeft,
    'xmidymid': Alignment.center,
    'xmaxymid': Alignment.centerRight,
    'xminymax': Alignment.bottomLeft,
    'xmidymax': Alignment.bottomCenter,
    'xmaxymax': Alignment.bottomRight,
  };
  final alignment = alignments[alignmentName];
  if (alignment == null || tokens.length > 2) {
    throw FormatException(
      tr("Unsupported preserveAspectRatio value: {0}.", [value]),
      source,
    );
  }
  final mode = tokens.length == 1 ? 'meet' : tokens[1].toLowerCase();
  return switch (mode) {
    'meet' => (BoxFit.contain, alignment),
    'slice' => (BoxFit.cover, alignment),
    _ => throw FormatException(
      tr("Unsupported preserveAspectRatio mode: {0}.", [mode]),
      source,
    ),
  };
}
