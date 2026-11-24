import 'dart:math' as math;

import 'package:flutter/foundation.dart' show mapEquals;
import 'package:flutter/material.dart';

/// Paints the native HTML control border styles that Flutter's [Border] cannot
/// represent. [styleNames] uses `top`, `right`, `bottom`, and `left` keys.
///
/// `groove`, `ridge`, `inset`, and `outset` use a solid fallback and are listed
/// in [unsupportedStyles] so callers can keep reporting the approximation.
class NativeHtmlControlBorderPainter extends CustomPainter {
  const NativeHtmlControlBorderPainter({
    required this.border,
    required this.styleNames,
    required this.borderRadius,
  });

  final Border border;
  final Map<String, String> styleNames;
  final BorderRadius borderRadius;

  static const _sides = <String>['top', 'right', 'bottom', 'left'];
  static const _unsupportedNames = <String>{
    'groove',
    'ridge',
    'inset',
    'outset',
  };

  /// Unsupported CSS styles and the sides that use them.
  Map<String, String> get unsupportedStyles => Map.unmodifiable({
    for (final side in _sides)
      if (_unsupportedNames.contains(_styleFor(side))) side: _styleFor(side),
  });

  String _styleFor(String side) =>
      (styleNames[side] ?? styleNames['border-$side-style'] ?? 'solid')
          .trim()
          .toLowerCase();

  BorderSide _borderSide(String side) => switch (side) {
    'top' => border.top,
    'right' => border.right,
    'bottom' => border.bottom,
    _ => border.left,
  };

  EdgeInsets _insets(double fraction) => EdgeInsets.fromLTRB(
    border.left.width * fraction,
    border.top.width * fraction,
    border.right.width * fraction,
    border.bottom.width * fraction,
  );

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0 || size.height <= 0) return;
    final rect = Offset.zero & size;
    final outer = borderRadius.resolve(TextDirection.ltr).toRRect(rect);
    canvas.save();
    canvas.clipRRect(outer, doAntiAlias: true);
    for (final side in _sides) {
      final borderSide = _borderSide(side);
      final styleName = _styleFor(side);
      if (borderSide.width <= 0 ||
          styleName == 'none' ||
          styleName == 'hidden') {
        continue;
      }
      final paint = Paint()
        ..color = borderSide.color
        ..isAntiAlias = true;
      switch (styleName) {
        case 'dotted':
          _paintDotted(canvas, rect, outer, side, borderSide.width, paint);
          break;
        case 'dashed':
          _paintDashed(canvas, rect, outer, side, borderSide.width, paint);
          break;
        case 'double':
          if (borderSide.width < 3) {
            _paintBand(canvas, rect, outer, side, paint, 0, 1);
          } else {
            _paintBand(canvas, rect, outer, side, paint, 0, 1 / 3);
            _paintBand(canvas, rect, outer, side, paint, 2 / 3, 1);
          }
          break;
        default:
          // Solid is exact. The unsupported relief styles deliberately fall
          // back to solid; [unsupportedStyles] exposes that limitation.
          _paintBand(canvas, rect, outer, side, paint, 0, 1);
          break;
      }
    }
    canvas.restore();
  }

  void _paintBand(
    Canvas canvas,
    Rect rect,
    RRect outer,
    String side,
    Paint paint,
    double startFraction,
    double endFraction,
  ) {
    final startInsets = _insets(startFraction);
    final endInsets = _insets(endFraction);
    final startRoundRect = _insetRoundRect(rect, outer, startInsets);
    final endRoundRect = _insetRoundRect(rect, outer, endInsets);
    final ring = Path.combine(
      PathOperation.difference,
      _roundRectPath(startRoundRect),
      _roundRectPath(endRoundRect),
    );
    final wedge = _sideWedge(
      startRoundRect.outerRect,
      endRoundRect.outerRect,
      side,
    );
    final sideBand = Path.combine(PathOperation.intersect, ring, wedge);
    canvas.drawPath(sideBand, paint..style = PaintingStyle.fill);
  }

  RRect _insetRoundRect(Rect rect, RRect outer, EdgeInsets insets) {
    final bounds = _insetRect(rect, insets);
    Radius insetRadius(double x, double y, double dx, double dy) =>
        Radius.elliptical(
          math.max(0.0, x - dx).toDouble(),
          math.max(0.0, y - dy).toDouble(),
        );
    return RRect.fromLTRBAndCorners(
      bounds.left,
      bounds.top,
      bounds.right,
      bounds.bottom,
      topLeft: insetRadius(
        outer.tlRadiusX,
        outer.tlRadiusY,
        insets.left,
        insets.top,
      ),
      topRight: insetRadius(
        outer.trRadiusX,
        outer.trRadiusY,
        insets.right,
        insets.top,
      ),
      bottomRight: insetRadius(
        outer.brRadiusX,
        outer.brRadiusY,
        insets.right,
        insets.bottom,
      ),
      bottomLeft: insetRadius(
        outer.blRadiusX,
        outer.blRadiusY,
        insets.left,
        insets.bottom,
      ),
    ).scaleRadii();
  }

  Rect _insetRect(Rect rect, EdgeInsets insets) {
    var left = rect.left + insets.left;
    var right = rect.right - insets.right;
    var top = rect.top + insets.top;
    var bottom = rect.bottom - insets.bottom;
    if (left > right) left = right = (left + right) / 2;
    if (top > bottom) top = bottom = (top + bottom) / 2;
    return Rect.fromLTRB(left, top, right, bottom);
  }

  Path _roundRectPath(RRect roundRect) => Path()..addRRect(roundRect);

  Path _sideWedge(Rect outer, Rect inner, String side) {
    final path = Path();
    switch (side) {
      case 'top':
        path
          ..moveTo(outer.left, outer.top)
          ..lineTo(outer.right, outer.top)
          ..lineTo(inner.right, inner.top)
          ..lineTo(inner.left, inner.top);
        break;
      case 'right':
        path
          ..moveTo(outer.right, outer.top)
          ..lineTo(outer.right, outer.bottom)
          ..lineTo(inner.right, inner.bottom)
          ..lineTo(inner.right, inner.top);
        break;
      case 'bottom':
        path
          ..moveTo(outer.right, outer.bottom)
          ..lineTo(outer.left, outer.bottom)
          ..lineTo(inner.left, inner.bottom)
          ..lineTo(inner.right, inner.bottom);
        break;
      default:
        path
          ..moveTo(outer.left, outer.bottom)
          ..lineTo(outer.left, outer.top)
          ..lineTo(inner.left, inner.top)
          ..lineTo(inner.left, inner.bottom);
    }
    return path..close();
  }

  void _paintDotted(
    Canvas canvas,
    Rect rect,
    RRect outer,
    String side,
    double width,
    Paint paint,
  ) {
    final metric = _sidePath(rect, outer, side).computeMetrics().firstOrNull;
    if (metric == null || metric.length <= width) return;
    final radius = width / 2;
    final step = math.max(width * 2, 1.0).toDouble();
    paint.style = PaintingStyle.fill;
    for (
      var distance = radius;
      distance <= metric.length - radius;
      distance += step
    ) {
      final point = metric.getTangentForOffset(distance)?.position;
      if (point != null) canvas.drawCircle(point, radius, paint);
    }
  }

  void _paintDashed(
    Canvas canvas,
    Rect rect,
    RRect outer,
    String side,
    double width,
    Paint paint,
  ) {
    final metric = _sidePath(rect, outer, side).computeMetrics().firstOrNull;
    if (metric == null || metric.length <= 0) return;
    final dashLength = width * 3;
    final gapLength = width * 2;
    paint
      ..style = PaintingStyle.stroke
      ..strokeWidth = width
      ..strokeCap = StrokeCap.butt;
    for (
      var distance = 0.0;
      distance < metric.length;
      distance += dashLength + gapLength
    ) {
      final end = math.min(distance + dashLength, metric.length);
      canvas.drawPath(metric.extractPath(distance, end), paint);
    }
  }

  Path _sidePath(Rect rect, RRect outer, String side) {
    final halfWidths = _insets(.5);
    final centerBounds = _insetRect(rect, halfWidths);
    Radius radius(double x, double y, double dx, double dy) =>
        Radius.elliptical(
          math.max(0.0, x - dx).toDouble(),
          math.max(0.0, y - dy).toDouble(),
        );
    final topLeft = radius(
      outer.tlRadiusX,
      outer.tlRadiusY,
      halfWidths.left,
      halfWidths.top,
    );
    final topRight = radius(
      outer.trRadiusX,
      outer.trRadiusY,
      halfWidths.right,
      halfWidths.top,
    );
    final bottomRight = radius(
      outer.brRadiusX,
      outer.brRadiusY,
      halfWidths.right,
      halfWidths.bottom,
    );
    final bottomLeft = radius(
      outer.blRadiusX,
      outer.blRadiusY,
      halfWidths.left,
      halfWidths.bottom,
    );
    final path = Path();
    switch (side) {
      case 'top':
        path
          ..moveTo(centerBounds.left, centerBounds.top + topLeft.y)
          ..arcToPoint(
            Offset(centerBounds.left + topLeft.x, centerBounds.top),
            radius: topLeft,
            clockwise: true,
          )
          ..lineTo(centerBounds.right - topRight.x, centerBounds.top)
          ..arcToPoint(
            Offset(centerBounds.right, centerBounds.top + topRight.y),
            radius: topRight,
            clockwise: true,
          );
        break;
      case 'right':
        path
          ..moveTo(centerBounds.right - topRight.x, centerBounds.top)
          ..arcToPoint(
            Offset(centerBounds.right, centerBounds.top + topRight.y),
            radius: topRight,
            clockwise: true,
          )
          ..lineTo(centerBounds.right, centerBounds.bottom - bottomRight.y)
          ..arcToPoint(
            Offset(centerBounds.right - bottomRight.x, centerBounds.bottom),
            radius: bottomRight,
            clockwise: true,
          );
        break;
      case 'bottom':
        path
          ..moveTo(centerBounds.right, centerBounds.bottom - bottomRight.y)
          ..arcToPoint(
            Offset(centerBounds.right - bottomRight.x, centerBounds.bottom),
            radius: bottomRight,
            clockwise: true,
          )
          ..lineTo(centerBounds.left + bottomLeft.x, centerBounds.bottom)
          ..arcToPoint(
            Offset(centerBounds.left, centerBounds.bottom - bottomLeft.y),
            radius: bottomLeft,
            clockwise: true,
          );
        break;
      default:
        path
          ..moveTo(centerBounds.left + bottomLeft.x, centerBounds.bottom)
          ..arcToPoint(
            Offset(centerBounds.left, centerBounds.bottom - bottomLeft.y),
            radius: bottomLeft,
            clockwise: true,
          )
          ..lineTo(centerBounds.left, centerBounds.top + topLeft.y)
          ..arcToPoint(
            Offset(centerBounds.left + topLeft.x, centerBounds.top),
            radius: topLeft,
            clockwise: true,
          );
        break;
    }
    return path;
  }

  @override
  bool shouldRepaint(covariant NativeHtmlControlBorderPainter oldDelegate) =>
      border != oldDelegate.border ||
      !mapEquals(styleNames, oldDelegate.styleNames) ||
      borderRadius != oldDelegate.borderRadius;
}
