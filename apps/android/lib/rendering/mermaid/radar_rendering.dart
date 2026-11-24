import '../render_l10n.dart';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'classic_palette.dart';
import 'radar_model.dart';

enum NativeMermaidRadarTextAnchor { start, middle, end }

enum NativeMermaidRadarTextBaseline { hanging, alphabetic, central }

class NativeMermaidRadarAxisLayout {
  const NativeMermaidRadarAxisLayout({
    required this.axis,
    required this.start,
    required this.end,
    required this.labelPosition,
    required this.labelAnchor,
    required this.labelBaseline,
  });

  final NativeMermaidRadarAxis axis;
  final Offset start;
  final Offset end;
  final Offset labelPosition;
  final NativeMermaidRadarTextAnchor labelAnchor;
  final NativeMermaidRadarTextBaseline labelBaseline;
}

class NativeMermaidRadarCubicSegment {
  const NativeMermaidRadarCubicSegment({
    required this.control1,
    required this.control2,
    required this.end,
  });

  final Offset control1;
  final Offset control2;
  final Offset end;
}

class NativeMermaidRadarCurveLayout {
  NativeMermaidRadarCurveLayout({
    required this.curve,
    required this.color,
    required Iterable<Offset> points,
    required Iterable<NativeMermaidRadarCubicSegment> segments,
  }) : points = List.unmodifiable(points),
       segments = List.unmodifiable(segments);

  final NativeMermaidRadarCurve curve;
  final Color color;
  final List<Offset> points;
  final List<NativeMermaidRadarCubicSegment> segments;
}

class NativeMermaidRadarRingLayout {
  NativeMermaidRadarRingLayout({
    required this.radius,
    required Iterable<Offset> points,
  }) : points = List.unmodifiable(points);

  final double radius;
  final List<Offset> points;
}

class NativeMermaidRadarLegendLayout {
  const NativeMermaidRadarLegendLayout({
    required this.curve,
    required this.color,
    required this.marker,
    required this.labelPosition,
  });

  final NativeMermaidRadarCurve curve;
  final Color color;
  final Rect marker;
  final Offset labelPosition;
}

/// Source-derived radar geometry. Coordinates in axes, rings, curves and
/// legend items are chart-center-relative SVG user units, as in Mermaid's g.
class NativeMermaidRadarLayout {
  NativeMermaidRadarLayout({
    required this.viewBoxSize,
    required this.size,
    required this.scale,
    required this.center,
    required this.radius,
    required Iterable<NativeMermaidRadarAxisLayout> axes,
    required Iterable<NativeMermaidRadarRingLayout> graticule,
    required Iterable<NativeMermaidRadarCurveLayout> curves,
    required Iterable<NativeMermaidRadarLegendLayout> legend,
    required this.title,
    required this.titlePosition,
    required this.axisColor,
    required this.textColor,
    required this.graticuleColor,
    required this.graticuleOpacity,
    required this.graticuleStrokeWidth,
    required this.axisStrokeWidth,
    required this.curveOpacity,
    required this.curveStrokeWidth,
    required this.legendBoxSize,
    required this.fontFamily,
    required this.dark,
    required this.smoothCurves,
  }) : axes = List.unmodifiable(axes),
       graticule = List.unmodifiable(graticule),
       curves = List.unmodifiable(curves),
       legend = List.unmodifiable(legend);

  final Size viewBoxSize;
  final Size size;
  final double scale;
  final Offset center;
  final double radius;
  final List<NativeMermaidRadarAxisLayout> axes;
  final List<NativeMermaidRadarRingLayout> graticule;
  final List<NativeMermaidRadarCurveLayout> curves;
  final List<NativeMermaidRadarLegendLayout> legend;
  final String title;
  final Offset titlePosition;
  final Color axisColor;
  final Color textColor;
  final Color graticuleColor;
  final double graticuleOpacity;
  final double graticuleStrokeWidth;
  final double axisStrokeWidth;
  final double curveOpacity;
  final double curveStrokeWidth;
  final double legendBoxSize;
  final String? fontFamily;
  final bool dark;
  final bool smoothCurves;

  /// Flattened point list in curve order for parity assertions and consumers.
  List<List<Offset>> get seriesPoints =>
      List.unmodifiable(curves.map((curve) => curve.points));

  /// Curve labels in the same order as Mermaid's legend entries.
  List<String> get legendLabels =>
      List.unmodifiable(legend.map((item) => item.curve.label));
}

/// Computes Mermaid 11.17.2 radar geometry using the pinned renderer's
/// 600x600 plot, 50-unit margins, polar order and closed Catmull-Rom curves.
NativeMermaidRadarLayout layoutNativeMermaidRadar(
  NativeMermaidRadarDiagram diagram, {
  required double width,
  required bool dark,
  String? fontFamily,
}) {
  final config = diagram.config;
  if (!width.isFinite || width <= 0) {
    throw FormatException(tr("Native radar viewport width must be positive"));
  }
  if (!config.width.isFinite ||
      !config.height.isFinite ||
      config.width <= 0 ||
      config.height <= 0 ||
      !config.marginTop.isFinite ||
      !config.marginRight.isFinite ||
      !config.marginBottom.isFinite ||
      !config.marginLeft.isFinite ||
      config.marginTop < 0 ||
      config.marginRight < 0 ||
      config.marginBottom < 0 ||
      config.marginLeft < 0 ||
      !config.axisScaleFactor.isFinite ||
      !config.axisLabelFactor.isFinite ||
      !config.curveTension.isFinite ||
      config.axisScaleFactor < 0 ||
      config.axisLabelFactor < 0 ||
      config.curveTension < 0 ||
      !config.totalWidth.isFinite ||
      !config.totalHeight.isFinite ||
      config.totalWidth <= 0 ||
      config.totalHeight <= 0) {
    throw FormatException(tr("Native radar chart dimensions must be positive"));
  }
  if (diagram.axes.length < 3 || diagram.curves.isEmpty) {
    throw FormatException(tr("Native radar chart requires axes and curves"));
  }
  if (diagram.axes.length > 24 || diagram.curves.length > 12) {
    throw FormatException(tr("Native radar chart exceeds its source bounds"));
  }
  if (diagram.options.ticks < 0 || diagram.options.ticks > 32) {
    throw FormatException(
      tr("Native radar tick count must be between 0 and 32"),
    );
  }
  for (final curve in diagram.curves) {
    if (curve.entries.length != diagram.axes.length ||
        curve.entries.any((value) => !value.isFinite || value < 0)) {
      throw FormatException(
        tr("Radar curve {0} has invalid values", [curve.name]),
      );
    }
  }

  final scale = config.useMaxWidth
      ? math.min(1.0, width / config.totalWidth)
      : 1.0;
  final viewBoxSize = Size(config.totalWidth, config.totalHeight);
  final size = Size(viewBoxSize.width * scale, viewBoxSize.height * scale);
  final center = Offset(
    config.marginLeft + config.width / 2,
    config.marginTop + config.height / 2,
  );
  final radius = math.min(config.width, config.height) / 2;
  final maxValue =
      diagram.options.max ??
      diagram.curves
          .expand((curve) => curve.entries)
          .reduce((a, b) => a > b ? a : b);
  final minValue = diagram.options.min;
  if (!maxValue.isFinite || !minValue.isFinite || maxValue <= minValue) {
    throw FormatException(tr("Radar max must be greater than min"));
  }

  final axes = <NativeMermaidRadarAxisLayout>[];
  final count = diagram.axes.length;
  for (var i = 0; i < count; i++) {
    final angle = (2 * math.pi * i) / count - math.pi / 2;
    final cosA = math.cos(angle);
    final sinA = math.sin(angle);
    final labelAnchor = cosA > .01
        ? NativeMermaidRadarTextAnchor.start
        : cosA < -.01
        ? NativeMermaidRadarTextAnchor.end
        : NativeMermaidRadarTextAnchor.middle;
    final labelBaseline = sinA > .01
        ? NativeMermaidRadarTextBaseline.hanging
        : sinA < -.01
        ? NativeMermaidRadarTextBaseline.alphabetic
        : NativeMermaidRadarTextBaseline.central;
    axes.add(
      NativeMermaidRadarAxisLayout(
        axis: diagram.axes[i],
        start: Offset.zero,
        end: Offset(
          radius * config.axisScaleFactor * cosA,
          radius * config.axisScaleFactor * sinA,
        ),
        labelPosition: Offset(
          radius * config.axisLabelFactor * cosA + 4 * cosA,
          radius * config.axisLabelFactor * sinA + 4 * sinA,
        ),
        labelAnchor: labelAnchor,
        labelBaseline: labelBaseline,
      ),
    );
  }

  final graticule = <NativeMermaidRadarRingLayout>[];
  for (var tick = 0; tick < diagram.options.ticks; tick++) {
    final ringRadius = radius * (tick + 1) / diagram.options.ticks;
    final ringPoints =
        diagram.options.graticule == NativeMermaidRadarGraticule.polygon
        ? List<Offset>.generate(count, (index) {
            final angle = (2 * index * math.pi) / count - math.pi / 2;
            return Offset(
              ringRadius * math.cos(angle),
              ringRadius * math.sin(angle),
            );
          }, growable: false)
        : const <Offset>[];
    graticule.add(
      NativeMermaidRadarRingLayout(radius: ringRadius, points: ringPoints),
    );
  }

  final curves = <NativeMermaidRadarCurveLayout>[];
  for (var curveIndex = 0; curveIndex < diagram.curves.length; curveIndex++) {
    final curve = diagram.curves[curveIndex];
    if (curve.entries.length != count) {
      throw FormatException(
        tr("Radar curve {0} has {1} values for {2} axes", [
          curve.name,
          curve.entries.length,
          count,
        ]),
      );
    }
    final points = <Offset>[];
    for (var i = 0; i < count; i++) {
      final angle = (2 * math.pi * i) / count - math.pi / 2;
      final clipped = curve.entries[i].clamp(minValue, maxValue).toDouble();
      final pointRadius = radius * (clipped - minValue) / (maxValue - minValue);
      points.add(
        Offset(pointRadius * math.cos(angle), pointRadius * math.sin(angle)),
      );
    }
    curves.add(
      NativeMermaidRadarCurveLayout(
        curve: curve,
        color: mermaidClassicSectionColor(curveIndex, dark),
        points: points,
        segments: _closedCurveSegments(points, config.curveTension),
      ),
    );
  }

  final themeText = dark ? const Color(0xffcccccc) : const Color(0xff0f1115);
  final themeAxis = dark ? const Color(0xffd3d3d3) : const Color(0xff81858c);
  const graticuleColor = Color(0xffdedede);
  const legendBoxSize = 12.0;
  final legend = <NativeMermaidRadarLegendLayout>[];
  if (diagram.options.showLegend) {
    final legendX = ((config.width / 2 + config.marginRight) * 3) / 4;
    final legendY = (-(config.height / 2 + config.marginTop) * 3) / 4;
    for (var i = 0; i < curves.length; i++) {
      final y = legendY + i * 20;
      legend.add(
        NativeMermaidRadarLegendLayout(
          curve: curves[i].curve,
          color: curves[i].color,
          marker: Rect.fromLTWH(legendX, y, legendBoxSize, legendBoxSize),
          labelPosition: Offset(legendX + 16, y),
        ),
      );
    }
  }

  return NativeMermaidRadarLayout(
    viewBoxSize: viewBoxSize,
    size: size,
    scale: scale,
    center: center,
    radius: radius,
    axes: axes,
    graticule: graticule,
    curves: curves,
    legend: legend,
    title: diagram.title,
    titlePosition: Offset(0, -config.height / 2 - config.marginTop),
    axisColor: themeAxis,
    textColor: themeText,
    graticuleColor: graticuleColor,
    graticuleOpacity: .3,
    graticuleStrokeWidth: 1,
    axisStrokeWidth: 2,
    curveOpacity: .5,
    curveStrokeWidth: 2,
    legendBoxSize: legendBoxSize,
    fontFamily: fontFamily,
    dark: dark,
    smoothCurves:
        diagram.options.graticule == NativeMermaidRadarGraticule.circle,
  );
}

List<NativeMermaidRadarCubicSegment> _closedCurveSegments(
  List<Offset> points,
  double tension,
) {
  final segments = <NativeMermaidRadarCubicSegment>[];
  final count = points.length;
  for (var i = 0; i < count; i++) {
    final p0 = points[(i - 1 + count) % count];
    final p1 = points[i];
    final p2 = points[(i + 1) % count];
    final p3 = points[(i + 2) % count];
    segments.add(
      NativeMermaidRadarCubicSegment(
        control1: Offset(
          p1.dx + (p2.dx - p0.dx) * tension,
          p1.dy + (p2.dy - p0.dy) * tension,
        ),
        control2: Offset(
          p2.dx - (p3.dx - p1.dx) * tension,
          p2.dy - (p3.dy - p1.dy) * tension,
        ),
        end: p2,
      ),
    );
  }
  return segments;
}

class NativeMermaidRadar extends StatelessWidget {
  const NativeMermaidRadar({
    super.key,
    required this.diagram,
    required this.dark,
  });

  final NativeMermaidRadarDiagram diagram;
  final bool dark;

  @override
  Widget build(BuildContext context) {
    RenderL10n.watch(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final candidateWidth = constraints.maxWidth;
        final width = candidateWidth.isFinite && candidateWidth > 0
            ? candidateWidth
            : diagram.config.totalWidth;
        final layout = layoutNativeMermaidRadar(
          diagram,
          width: width,
          dark: dark,
          fontFamily: Theme.of(context).textTheme.bodyMedium?.fontFamily,
        );
        return Semantics(
          container: true,
          label: diagram.semanticsLabel,
          child: ExcludeSemantics(
            child: SizedBox(
              width: layout.size.width,
              height: layout.size.height,
              child: CustomPaint(painter: _NativeMermaidRadarPainter(layout)),
            ),
          ),
        );
      },
    );
  }
}

class _NativeMermaidRadarPainter extends CustomPainter {
  _NativeMermaidRadarPainter(this.layout);

  final NativeMermaidRadarLayout layout;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(layout.scale);
    canvas.translate(layout.center.dx, layout.center.dy);
    _paintGraticule(canvas);
    _paintAxes(canvas);
    _paintCurves(canvas);
    _paintLabels(canvas);
    canvas.restore();
  }

  void _paintGraticule(Canvas canvas) {
    final fill = Paint()
      ..color = layout.graticuleColor.withValues(alpha: layout.graticuleOpacity)
      ..style = PaintingStyle.fill;
    final stroke = Paint()
      ..color = layout.graticuleColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = layout.graticuleStrokeWidth;
    for (final ring in layout.graticule) {
      if (ring.points.isEmpty) {
        canvas.drawCircle(Offset.zero, ring.radius, fill);
        canvas.drawCircle(Offset.zero, ring.radius, stroke);
      } else {
        final path = Path()..moveTo(ring.points.first.dx, ring.points.first.dy);
        for (final point in ring.points.skip(1)) {
          path.lineTo(point.dx, point.dy);
        }
        path.close();
        canvas.drawPath(path, fill);
        canvas.drawPath(path, stroke);
      }
    }
  }

  void _paintAxes(Canvas canvas) {
    final paint = Paint()
      ..color = layout.axisColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = layout.axisStrokeWidth;
    for (final axis in layout.axes) {
      canvas.drawLine(axis.start, axis.end, paint);
    }
  }

  void _paintCurves(Canvas canvas) {
    for (final curve in layout.curves) {
      final path = Path()..moveTo(curve.points.first.dx, curve.points.first.dy);
      if (layout.smoothCurves && curve.segments.isNotEmpty) {
        for (final segment in curve.segments) {
          path.cubicTo(
            segment.control1.dx,
            segment.control1.dy,
            segment.control2.dx,
            segment.control2.dy,
            segment.end.dx,
            segment.end.dy,
          );
        }
      } else {
        for (final point in curve.points.skip(1)) {
          path.lineTo(point.dx, point.dy);
        }
      }
      path.close();
      canvas.drawPath(
        path,
        Paint()
          ..color = curve.color.withValues(alpha: layout.curveOpacity)
          ..style = PaintingStyle.fill,
      );
      canvas.drawPath(
        path,
        Paint()
          ..color = curve.color
          ..style = PaintingStyle.stroke
          ..strokeWidth = layout.curveStrokeWidth,
      );
    }
  }

  void _paintLabels(Canvas canvas) {
    for (final axis in layout.axes) {
      _drawText(
        canvas,
        axis.axis.label,
        axis.labelPosition,
        12,
        layout.textColor,
        anchor: axis.labelAnchor,
        baseline: axis.labelBaseline,
      );
    }
    for (final item in layout.legend) {
      canvas.drawRect(
        item.marker,
        Paint()
          ..color = item.color.withValues(alpha: layout.curveOpacity)
          ..style = PaintingStyle.fill,
      );
      canvas.drawRect(
        item.marker,
        Paint()
          ..color = item.color
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1,
      );
      _drawText(
        canvas,
        item.curve.label,
        item.labelPosition,
        12,
        layout.textColor,
        anchor: NativeMermaidRadarTextAnchor.start,
        baseline: NativeMermaidRadarTextBaseline.hanging,
      );
    }
    if (layout.title.isNotEmpty) {
      _drawText(
        canvas,
        layout.title,
        layout.titlePosition,
        13,
        layout.textColor,
        anchor: NativeMermaidRadarTextAnchor.middle,
        baseline: NativeMermaidRadarTextBaseline.hanging,
      );
    }
  }

  void _drawText(
    Canvas canvas,
    String text,
    Offset position,
    double fontSize,
    Color color, {
    required NativeMermaidRadarTextAnchor anchor,
    required NativeMermaidRadarTextBaseline baseline,
  }) {
    final painter = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          color: color,
          fontSize: fontSize,
          fontFamily: layout.fontFamily,
        ),
      ),
      textDirection: TextDirection.ltr,
      maxLines: 1,
    )..layout();
    final dx = switch (anchor) {
      NativeMermaidRadarTextAnchor.start => position.dx,
      NativeMermaidRadarTextAnchor.middle => position.dx - painter.width / 2,
      NativeMermaidRadarTextAnchor.end => position.dx - painter.width,
    };
    final lineMetrics = painter.computeLineMetrics();
    final metrics = lineMetrics.isEmpty ? null : lineMetrics.first;
    final dy = switch (baseline) {
      NativeMermaidRadarTextBaseline.hanging => position.dy - 2.5,
      NativeMermaidRadarTextBaseline.alphabetic =>
        position.dy - (metrics?.baseline ?? painter.height),
      NativeMermaidRadarTextBaseline.central =>
        position.dy - painter.height / 2,
    };
    painter.paint(canvas, Offset(dx, dy));
  }

  @override
  bool shouldRepaint(covariant _NativeMermaidRadarPainter oldDelegate) =>
      oldDelegate.layout != layout;
}
