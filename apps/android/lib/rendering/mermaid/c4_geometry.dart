import '../render_l10n.dart';
import 'dart:math' as math;

import 'dart:ui' show Offset, Path, Radius, Rect, RRect, Size;

/// Geometry for one native Mermaid C4 node.
///
/// [outline] and [accentPaths] use coordinates local to the node's top-left.
/// [labelRect] uses the same coordinate space. [intersect] accepts a point in
/// that space and returns the first outline point on the ray from the node
/// center toward it.
class NativeC4NodeGeometry {
  NativeC4NodeGeometry._({
    required this.size,
    required this.labelRect,
    required this.outline,
    required List<Path> accentPaths,
    required this._intersector,
  }) : accentPaths = List<Path>.unmodifiable(accentPaths);

  final Size size;
  final Rect labelRect;
  final Path outline;
  final List<Path> accentPaths;
  final Offset Function(Offset localPoint) _intersector;

  /// Returns the outline intersection for a point in node-local coordinates.
  Offset intersect(Offset localPoint) => _intersector(localPoint);
}

/// Reproduces Mermaid 11.17.2 C4 node shape dimensions and edge geometry.
///
/// [labelSize] is the measured label block. [minWidth] supplies C4's base
/// element width; [padding] is the Mermaid node padding. Unsupported shape
/// names throw [FormatException] so C4 DB and queue nodes cannot silently
/// become ordinary rectangles.
NativeC4NodeGeometry nativeC4NodeGeometry(
  String shape,
  Size labelSize, {
  double minWidth = 216,
  double padding = 20,
}) {
  if (!labelSize.width.isFinite ||
      !labelSize.height.isFinite ||
      labelSize.width < 0 ||
      labelSize.height < 0) {
    throw ArgumentError.value(
      labelSize,
      'labelSize',
      tr("Must be finite and non-negative."),
    );
  }
  if (!minWidth.isFinite || minWidth <= 0) {
    throw ArgumentError.value(
      minWidth,
      'minWidth',
      tr("Must be finite and greater than zero."),
    );
  }
  if (!padding.isFinite || padding < 0) {
    throw ArgumentError.value(
      padding,
      'padding',
      tr("Must be finite and non-negative."),
    );
  }

  switch (shape.trim().toLowerCase()) {
    case 'person':
      return _personGeometry(labelSize, minWidth, padding);
    case 'rounded':
      return _roundedGeometry(labelSize, minWidth, padding);
    case 'fr-rect':
      return _framedRectGeometry(labelSize, minWidth, padding);
    case 'cylinder':
      return _cylinderGeometry(labelSize, minWidth, padding);
    case 'h-cyl':
      return _horizontalCylinderGeometry(labelSize, minWidth, padding);
    default:
      throw FormatException(
        tr(
          "Unsupported native Mermaid C4 shape \"{0}\". Supported shapes: person, rounded, fr-rect, cylinder, h-cyl.",
          [shape],
        ),
      );
  }
}

NativeC4NodeGeometry _personGeometry(
  Size labelSize,
  double minWidth,
  double padding,
) {
  final width = math
      .max(math.max(labelSize.width + padding * 2, minWidth), 100.0)
      .toDouble();
  final headRadius = (width * 0.23).clamp(16.0, 56.0).toDouble();
  final overlap = headRadius * 0.27;
  final bodyHeight = math.max(labelSize.height + padding * 2, 0.0).toDouble();
  final bodyRadius = math.min(width * 0.177, bodyHeight * 0.45).toDouble();
  final totalHeight = bodyHeight + 2 * headRadius - overlap;
  final top = -totalHeight / 2;
  final headCenterY = top + headRadius;
  final bodyTop = top + 2 * headRadius - overlap;
  final bodyCenterY = bodyTop + bodyHeight / 2;
  final center = Offset(width / 2, totalHeight / 2);

  // These points follow Mermaid's generateCirclePoints helper and are used for
  // both the outline and polygon-based connector intersection.
  final phiRight = math.asin(
    ((bodyTop - headCenterY) / headRadius).clamp(-1.0, 1.0),
  );
  final outlinePoints = <Offset>[
    ..._mermaidCirclePoints(
      0,
      -headCenterY,
      headRadius,
      24,
      180 + phiRight * 180 / math.pi,
      -phiRight * 180 / math.pi,
    ),
    ..._mermaidCirclePoints(
      width / 2 - bodyRadius,
      -(bodyTop + bodyRadius),
      bodyRadius,
      12,
      90,
      0,
    ),
    ..._mermaidCirclePoints(
      width / 2 - bodyRadius,
      -(totalHeight / 2 - bodyRadius),
      bodyRadius,
      12,
      360,
      270,
    ),
    ..._mermaidCirclePoints(
      -width / 2 + bodyRadius,
      -(totalHeight / 2 - bodyRadius),
      bodyRadius,
      12,
      270,
      180,
    ),
    ..._mermaidCirclePoints(
      -width / 2 + bodyRadius,
      -(bodyTop + bodyRadius),
      bodyRadius,
      12,
      180,
      90,
    ),
  ];
  final outline = _centeredPolygonPath(outlinePoints, center);

  return NativeC4NodeGeometry._(
    size: Size(width, totalHeight),
    labelRect: Rect.fromLTWH(
      (width - labelSize.width) / 2,
      center.dy + bodyCenterY - labelSize.height / 2,
      labelSize.width,
      labelSize.height,
    ),
    outline: outline,
    accentPaths: const <Path>[],
    intersector: (point) =>
        _polygonRayIntersection(point, center, outlinePoints),
  );
}

NativeC4NodeGeometry _roundedGeometry(
  Size labelSize,
  double minWidth,
  double padding,
) {
  final width = math.max(labelSize.width + padding * 2, minWidth).toDouble();
  final height = labelSize.height + padding * 2;
  final bounds = Offset.zero & Size(width, height);
  final outline = Path()
    ..addRRect(RRect.fromRectAndRadius(bounds, const Radius.circular(12)));
  final center = Offset(width / 2, height / 2);

  return NativeC4NodeGeometry._(
    size: Size(width, height),
    labelRect: Rect.fromLTWH(
      center.dx - labelSize.width / 2,
      center.dy - labelSize.height / 2,
      labelSize.width,
      labelSize.height,
    ),
    outline: outline,
    accentPaths: const <Path>[],
    // Mermaid's drawRect connector calculation uses the node rectangle even
    // when the rendered corners are rounded.
    intersector: (point) => _rectRayIntersection(point, Size(width, height)),
  );
}

NativeC4NodeGeometry _framedRectGeometry(
  Size labelSize,
  double minWidth,
  double padding,
) {
  const frameWidth = 8.0;
  final width = math
      .max(labelSize.width + frameWidth * 2 + padding, minWidth)
      .toDouble();
  final height = labelSize.height + padding;
  final bounds = Offset.zero & Size(width, height);
  final outline = Path()..addRect(bounds);
  final leftRail = frameWidth;
  final rightRail = width - frameWidth;
  final accents = <Path>[
    Path()
      ..moveTo(leftRail, 0)
      ..lineTo(leftRail, height),
    Path()
      ..moveTo(rightRail, 0)
      ..lineTo(rightRail, height),
  ];
  final center = Offset(width / 2, height / 2);

  return NativeC4NodeGeometry._(
    size: Size(width, height),
    labelRect: Rect.fromLTWH(
      center.dx - labelSize.width / 2,
      center.dy - labelSize.height / 2,
      labelSize.width,
      labelSize.height,
    ),
    outline: outline,
    accentPaths: accents,
    intersector: (point) => _rectRayIntersection(point, Size(width, height)),
  );
}

NativeC4NodeGeometry _cylinderGeometry(
  Size labelSize,
  double minWidth,
  double padding,
) {
  // Mermaid's cylinder handler removes horizontal padding from its requested
  // width before measuring, then adds the padding once after measurement.
  final contentWidth = math.max(minWidth - padding, 8.0).toDouble();
  final width = math.max(contentWidth, labelSize.width).toDouble() + padding;
  final rx = width / 2;
  final ry = rx / (2.5 + width / 50);
  final innerHeight = labelSize.height + padding + ry;
  final height = innerHeight + 2 * ry;
  final topEllipse = Rect.fromLTWH(0, 0, width, 2 * ry);
  final bottomEllipse = Rect.fromLTWH(0, innerHeight, width, 2 * ry);

  // Mermaid's path contains a complete top ellipse. Keep the visible top half
  // in the silhouette and draw its lower half as a separate accent stroke.
  final outline = Path()
    ..moveTo(0, ry)
    ..arcTo(topEllipse, math.pi, math.pi, false)
    ..lineTo(width, ry + innerHeight)
    ..arcTo(bottomEllipse, 0, math.pi, false)
    ..lineTo(0, ry)
    ..close();
  final topInnerLine = Path()
    ..moveTo(0, ry)
    ..arcTo(topEllipse, math.pi, -math.pi, false);
  final center = Offset(width / 2, height / 2);

  return NativeC4NodeGeometry._(
    size: Size(width, height),
    labelRect: Rect.fromLTWH(
      center.dx - labelSize.width / 2,
      center.dy + padding / 1.5 - labelSize.height / 2,
      labelSize.width,
      labelSize.height,
    ),
    outline: outline,
    accentPaths: <Path>[topInnerLine],
    intersector: (point) =>
        _verticalCylinderIntersection(point, Size(width, height), rx, ry),
  );
}

NativeC4NodeGeometry _horizontalCylinderGeometry(
  Size labelSize,
  double minWidth,
  double padding,
) {
  // Mermaid's tiltedCylinder receives the C4 element width, subtracts half
  // the node padding, then adds the horizontal end radius and padding back.
  const minContentWidth = 10.0;
  final labelPadding = padding / 2;
  final contentWidth = math
      .max(minWidth - labelPadding, minContentWidth)
      .toDouble();
  final height = labelSize.height + labelPadding;
  final ry = height / 2;
  final rx = ry / (2.5 + height / 50);
  final bodyWidth =
      math.max(contentWidth, labelSize.width).toDouble() + rx + labelPadding;
  final width = bodyWidth + 2 * rx;
  final leftCap = Rect.fromLTWH(0, 0, 2 * rx, height);
  final rightCap = Rect.fromLTWH(bodyWidth, 0, 2 * rx, height);

  final outline = Path()
    ..moveTo(rx, height)
    ..arcTo(leftCap, math.pi / 2, math.pi, false)
    ..lineTo(bodyWidth + rx, 0)
    ..arcTo(rightCap, -math.pi / 2, math.pi, false)
    ..lineTo(rx, height)
    ..close();
  final innerEnd = Path()
    ..moveTo(bodyWidth + rx, 0)
    ..arcTo(rightCap, -math.pi / 2, -math.pi, false)
    ..lineTo(rx, height);
  final center = Offset(width / 2, height / 2);

  return NativeC4NodeGeometry._(
    size: Size(width, height),
    labelRect: Rect.fromLTWH(
      center.dx - rx - labelSize.width / 2,
      center.dy - labelSize.height / 2,
      labelSize.width,
      labelSize.height,
    ),
    outline: outline,
    accentPaths: <Path>[innerEnd],
    intersector: (point) =>
        _horizontalCylinderIntersection(point, Size(width, height), rx, ry),
  );
}

List<Offset> _mermaidCirclePoints(
  double centerX,
  double centerY,
  double radius,
  int count,
  double startAngle,
  double endAngle,
) {
  final start = startAngle * math.pi / 180;
  final sweep = (endAngle - startAngle) * math.pi / 180;
  return List<Offset>.generate(count, (index) {
    final angle = start + sweep * index / (count - 1);
    return Offset(
      -(centerX + radius * math.cos(angle)),
      -(centerY + radius * math.sin(angle)),
    );
  }, growable: false);
}

Path _centeredPolygonPath(List<Offset> centeredPoints, Offset center) {
  final path = Path();
  if (centeredPoints.isEmpty) return path;
  path.moveTo(
    centeredPoints.first.dx + center.dx,
    centeredPoints.first.dy + center.dy,
  );
  for (final point in centeredPoints.skip(1)) {
    path.lineTo(point.dx + center.dx, point.dy + center.dy);
  }
  path.close();
  return path;
}

Offset _polygonRayIntersection(
  Offset localPoint,
  Offset center,
  List<Offset> centeredPolygon,
) {
  final direction = localPoint - center;
  if (direction.distanceSquared == 0 || centeredPolygon.isEmpty) return center;

  var closestT = double.infinity;
  for (var index = 0; index < centeredPolygon.length; index++) {
    final a = centeredPolygon[index];
    final b = centeredPolygon[(index + 1) % centeredPolygon.length];
    final edge = b - a;
    final denominator = _cross(direction, edge);
    if (denominator.abs() < 1e-12) continue;
    final t = _cross(a, edge) / denominator;
    final u = _cross(a, direction) / denominator;
    if (t >= 0 && u >= 0 && u <= 1 && t < closestT) {
      closestT = t;
    }
  }
  if (!closestT.isFinite) return center;
  return center + direction * closestT;
}

double _cross(Offset a, Offset b) => a.dx * b.dy - a.dy * b.dx;

Offset _rectRayIntersection(Offset localPoint, Size size) {
  final center = Offset(size.width / 2, size.height / 2);
  final direction = localPoint - center;
  if (direction.distanceSquared == 0) return center;
  final halfWidth = size.width / 2;
  final halfHeight = size.height / 2;
  // Set the hit axis exactly, like Mermaid's intersectRect. Multiplying the
  // ray by a fractional t can leave a point an ulp inside the cylinder's top
  // edge and incorrectly activate its elliptical side correction.
  if (direction.dy.abs() * halfWidth > direction.dx.abs() * halfHeight) {
    final y = direction.dy < 0 ? -halfHeight : halfHeight;
    return center + Offset(y * direction.dx / direction.dy, y);
  }
  final x = direction.dx < 0 ? -halfWidth : halfWidth;
  return center + Offset(x, x * direction.dy / direction.dx);
}

Offset _verticalCylinderIntersection(
  Offset localPoint,
  Size size,
  double rx,
  double ry,
) {
  final center = Offset(size.width / 2, size.height / 2);
  final direction = localPoint - center;
  if (direction.distanceSquared == 0) return center;

  var hit = _rectRayIntersection(localPoint, size);
  final x = hit.dx - center.dx;
  final y = hit.dy - center.dy;
  final halfWidth = size.width / 2;
  final halfHeight = size.height / 2;
  final onSide = (x.abs() - halfWidth).abs() < 1e-9;
  if (rx != 0 &&
      (x.abs() < halfWidth || (onSide && y.abs() > halfHeight - ry))) {
    final radicand = ry * ry * (1 - x * x / (rx * rx));
    final ellipseY = radicand > 0 ? math.sqrt(radicand) : 0.0;
    var correction = ry - ellipseY;
    if (direction.dy > 0) correction = -correction;
    hit = Offset(hit.dx, hit.dy + correction);
  }
  return hit;
}

Offset _horizontalCylinderIntersection(
  Offset localPoint,
  Size size,
  double rx,
  double ry,
) {
  final center = Offset(size.width / 2, size.height / 2);
  final direction = localPoint - center;
  if (direction.distanceSquared == 0) return center;

  var hit = _rectRayIntersection(localPoint, size);
  final x = hit.dx - center.dx;
  final y = hit.dy - center.dy;
  final halfWidth = size.width / 2;
  final halfHeight = size.height / 2;
  final onTopOrBottom = (y.abs() - halfHeight).abs() < 1e-9;
  if (ry != 0 &&
      (y.abs() < halfHeight || (onTopOrBottom && x.abs() > halfWidth - rx))) {
    final radicand = rx * rx * (1 - y * y / (ry * ry));
    final ellipseX = math.sqrt(radicand.abs());
    var correction = rx - ellipseX;
    if (direction.dx > 0) correction = -correction;
    hit = Offset(hit.dx + correction, hit.dy);
  }
  return hit;
}
