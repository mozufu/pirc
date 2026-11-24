import 'dart:math' as math;
import 'dart:ui';
import 'package:xml/xml.dart';

/// Intrinsic viewport size of an SVG used as an image. The graphics decoder
/// reports its viewBox, which can differ from the root width/height attributes.
Size svgImageSize(String source) {
  final root = XmlDocument.parse(source).rootElement;
  double? length(String? value) {
    final match = RegExp(
      r'^\s*([+-]?(?:\d+|\d*\.\d+)(?:[eE][+-]?\d+)?)(px|pt|pc|in|cm|mm|q)?\s*$',
      caseSensitive: false,
    ).firstMatch(value ?? '');
    if (match == null) return null;
    const units = {
      'px': 1.0,
      'pt': 96 / 72,
      'pc': 16.0,
      'in': 96.0,
      'cm': 96 / 2.54,
      'mm': 96 / 25.4,
      'q': 96 / 101.6,
    };
    final pixels =
        double.parse(match[1]!) * (units[match[2]?.toLowerCase()] ?? 1);
    return pixels.isFinite ? math.max(0, pixels) : null;
  }

  final width = length(root.getAttribute('width')),
      height = length(root.getAttribute('height'));
  final view = (root.getAttribute('viewBox') ?? '')
      .trim()
      .split(RegExp(r'[ ,\s]+'))
      .map(double.tryParse)
      .toList();
  final ratio =
      view.length == 4 &&
          view[2] != null &&
          view[3] != null &&
          view[2]! > 0 &&
          view[3]! > 0
      ? view[2]! / view[3]!
      : null;
  if (width != null && height != null) return Size(width, height);
  if (width != null) return Size(width, ratio == null ? 150 : width / ratio);
  if (height != null) return Size(ratio == null ? 300 : height * ratio, height);
  if (ratio == null) return const Size(300, 150);
  final naturalWidth = math.min(300.0, 150 * ratio);
  return Size(naturalWidth, naturalWidth / ratio);
}
