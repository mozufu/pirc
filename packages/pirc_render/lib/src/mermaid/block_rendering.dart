import '../render_l10n.dart';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'block_layout.dart';
import 'block_model.dart';

/// Paint-only Mermaid block diagram. It does not embed or rasterize Mermaid SVG.
class NativeMermaidBlockChart extends StatelessWidget {
  const NativeMermaidBlockChart({
    super.key,
    required this.diagram,
    required this.dark,
    this.fontFamily,
    this.fontSize = 13,
  });

  final NativeMermaidBlockDiagram diagram;
  final bool dark;
  final String? fontFamily;
  final double fontSize;

  @override
  Widget build(BuildContext context) {
    RenderL10n.watch(context);
    final semantics = StringBuffer(tr("Block diagram."));
    for (final node in diagram.leafNodes) {
      semantics.write(' ');
      semantics.write(node.label);
      semantics.write('.');
    }
    for (final edge in diagram.edges) {
      semantics.write(' ');
      semantics.write(edge.start);
      semantics.write(tr(" connects to "));
      semantics.write(edge.end);
      if (edge.label.isNotEmpty) {
        semantics.write(tr(" with label "));
        semantics.write(edge.label);
      }
      semantics.write('.');
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.hasBoundedWidth
            ? constraints.maxWidth
            : MediaQuery.sizeOf(context).width;
        final layout = layoutNativeMermaidBlock(
          diagram,
          width: width,
          dark: dark,
          fontFamily:
              fontFamily ?? DefaultTextStyle.of(context).style.fontFamily,
          fontSize: fontSize,
        );
        final chart = SizedBox(
          key: const ValueKey('native-mermaid-block-chart'),
          width: layout.size.width,
          height: layout.size.height,
          child: CustomPaint(
            painter: _BlockPainter(
              layout: layout,
              dark: dark,
              fontFamily:
                  fontFamily ?? DefaultTextStyle.of(context).style.fontFamily,
              fontSize: fontSize,
            ),
          ),
        );
        return Semantics(
          image: true,
          label: semantics.toString(),
          child: Align(alignment: Alignment.topCenter, child: chart),
        );
      },
    );
  }
}

class _BlockPainter extends CustomPainter {
  const _BlockPainter({
    required this.layout,
    required this.dark,
    required this.fontFamily,
    required this.fontSize,
  });

  final NativeMermaidBlockLayout layout;
  final bool dark;
  final String? fontFamily;
  final double fontSize;

  Color get _line => dark ? const Color(0xffd3d3d3) : const Color(0xff81858c);
  Color get _fill => dark ? const Color(0xff1f2020) : const Color(0xffedf3fe);
  Color get _border => dark ? const Color(0xffcccccc) : const Color(0xff4176e6);
  Color get _ink => dark ? const Color(0xffcccccc) : const Color(0xff0f1115);
  Color get _labelBackground =>
      dark ? const Color(0xff535353) : const Color(0xfff1f3f5);
  Color get _clusterFill =>
      dark ? const Color(0x40606060) : const Color(0x80ffffde);
  Color get _clusterBorder =>
      dark ? const Color(0x66909090) : const Color(0x33aaaa33);

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(layout.scale);
    for (final edge in layout.edges) {
      _paintEdge(canvas, edge);
    }
    for (final node in layout.nodes) {
      _paintNode(canvas, node);
    }
    canvas.restore();
  }

  void _paintEdge(Canvas canvas, NativeMermaidBlockEdgeLayout item) {
    final stroke = Paint()
      ..color = _line
      ..style = PaintingStyle.stroke
      ..strokeWidth = item.edge.thickness == 'thick' ? 3 : 2
      ..strokeCap = StrokeCap.round;
    for (final metric in item.path.computeMetrics()) {
      if (item.edge.pattern == 'dotted') {
        for (double offset = 0; offset < metric.length; offset += 8) {
          canvas.drawPath(
            metric.extractPath(offset, math.min(offset + 3, metric.length)),
            stroke,
          );
        }
      } else {
        canvas.drawPath(item.path, stroke);
      }
    }
    final metric = item.path.computeMetrics().firstOrNull;
    if (metric != null) {
      final start = metric.getTangentForOffset(0);
      if (start != null) {
        _paintMarker(
          canvas,
          item.edge.arrowTypeStart,
          start.position,
          -start.vector,
          stroke,
        );
      }
      final end = metric.getTangentForOffset(metric.length);
      if (end != null) {
        _paintMarker(
          canvas,
          item.edge.arrowTypeEnd,
          end.position,
          end.vector,
          stroke,
        );
      }
    }
    if (item.edge.label.isNotEmpty) {
      final text = _text(item.edge.label, _ink)..layout();
      final rect = Rect.fromCenter(
        center: item.labelCenter,
        width: text.width + 4,
        height: text.height + 2,
      );
      canvas.drawRect(rect, Paint()..color = _labelBackground);
      text.paint(
        canvas,
        Offset(
          rect.center.dx - text.width / 2,
          rect.center.dy - text.height / 2,
        ),
      );
      text.dispose();
    }
  }

  void _paintMarker(
    Canvas canvas,
    String marker,
    Offset point,
    Offset direction,
    Paint stroke,
  ) {
    if (marker.isEmpty || direction.distance == 0) return;
    final unit = direction / direction.distance;
    final normal = Offset(-unit.dy, unit.dx);
    if (marker == 'arrow_point') {
      final base = point - unit * 9;
      canvas.drawPath(
        Path()
          ..moveTo(point.dx, point.dy)
          ..lineTo(base.dx + normal.dx * 4, base.dy + normal.dy * 4)
          ..lineTo(base.dx - normal.dx * 4, base.dy - normal.dy * 4)
          ..close(),
        Paint()..color = _line,
      );
    } else if (marker == 'arrow_open') {
      final base = point - unit * 9;
      canvas.drawLine(point, base + normal * 4, stroke);
      canvas.drawLine(point, base - normal * 4, stroke);
    } else if (marker == 'arrow_circle') {
      canvas.drawCircle(
        point - unit * 3,
        3,
        Paint()
          ..color = _line
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1,
      );
    } else if (marker == 'arrow_cross') {
      final center = point - unit * 3;
      canvas.drawLine(
        center - unit * 3 - normal * 3,
        center + unit * 3 + normal * 3,
        stroke,
      );
      canvas.drawLine(
        center - unit * 3 + normal * 3,
        center + unit * 3 - normal * 3,
        stroke,
      );
    }
  }

  void _paintNode(Canvas canvas, NativeMermaidBlockNodeLayout item) {
    final rect = item.bounds;
    if (item.node.isComposite) {
      canvas.drawRect(rect, Paint()..color = _clusterFill);
      canvas.drawRect(
        rect,
        Paint()
          ..color = _clusterBorder
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1,
      );
      return;
    }
    final fill = Paint()..color = _fill;
    final stroke = Paint()
      ..color = _border
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    final path = _nodePath(item.node.shape, rect);
    canvas.drawPath(path, fill);
    canvas.drawPath(path, stroke);

    if (item.node.shape == NativeMermaidBlockShape.subroutine) {
      canvas.drawLine(
        Offset(rect.left + 7, rect.top),
        Offset(rect.left + 7, rect.bottom),
        stroke,
      );
      canvas.drawLine(
        Offset(rect.right - 7, rect.top),
        Offset(rect.right - 7, rect.bottom),
        stroke,
      );
    } else if (item.node.shape == NativeMermaidBlockShape.doubleCircle) {
      final inner = rect.deflate(4);
      canvas.drawOval(inner, stroke);
    } else if (item.node.shape == NativeMermaidBlockShape.cylinder) {
      final arcHeight = math.min(8.0, rect.height / 5);
      canvas.drawArc(
        Rect.fromLTWH(rect.left, rect.top, rect.width, arcHeight * 2),
        math.pi,
        math.pi,
        false,
        stroke,
      );
      canvas.drawArc(
        Rect.fromLTWH(
          rect.left,
          rect.bottom - arcHeight * 2,
          rect.width,
          arcHeight * 2,
        ),
        0,
        math.pi,
        false,
        stroke,
      );
    }

    final text = _text(item.node.label, _ink)..layout();
    text.paint(
      canvas,
      Offset(rect.center.dx - text.width / 2, rect.center.dy - text.height / 2),
    );
    text.dispose();
  }

  Path _nodePath(NativeMermaidBlockShape shape, Rect rect) {
    switch (shape) {
      case NativeMermaidBlockShape.rounded:
        return Path()
          ..addRRect(RRect.fromRectAndRadius(rect, const Radius.circular(5)));
      case NativeMermaidBlockShape.circle:
      case NativeMermaidBlockShape.doubleCircle:
        return Path()..addOval(rect);
      case NativeMermaidBlockShape.diamond:
        return Path()
          ..moveTo(rect.center.dx, rect.top)
          ..lineTo(rect.right, rect.center.dy)
          ..lineTo(rect.center.dx, rect.bottom)
          ..lineTo(rect.left, rect.center.dy)
          ..close();
      case NativeMermaidBlockShape.hexagon:
        return Path()
          ..moveTo(rect.left + rect.width * .2, rect.top)
          ..lineTo(rect.right - rect.width * .2, rect.top)
          ..lineTo(rect.right, rect.center.dy)
          ..lineTo(rect.right - rect.width * .2, rect.bottom)
          ..lineTo(rect.left + rect.width * .2, rect.bottom)
          ..lineTo(rect.left, rect.center.dy)
          ..close();
      case NativeMermaidBlockShape.stadium:
        return Path()..addRRect(
          RRect.fromRectAndRadius(
            rect,
            Radius.circular(math.min(rect.height / 2, 18)),
          ),
        );
      case NativeMermaidBlockShape.leanRight:
        return _polygon(rect, [
          Offset(rect.left, rect.top),
          Offset(rect.right - 8, rect.top),
          Offset(rect.right, rect.bottom),
          Offset(rect.left + 8, rect.bottom),
        ]);
      case NativeMermaidBlockShape.leanLeft:
        return _polygon(rect, [
          Offset(rect.left + 8, rect.top),
          Offset(rect.right, rect.top),
          Offset(rect.right - 8, rect.bottom),
          Offset(rect.left, rect.bottom),
        ]);
      case NativeMermaidBlockShape.trapezoid:
        return _polygon(rect, [
          Offset(rect.left + rect.width * .16, rect.top),
          Offset(rect.right - rect.width * .16, rect.top),
          Offset(rect.right, rect.bottom),
          Offset(rect.left, rect.bottom),
        ]);
      case NativeMermaidBlockShape.inverseTrapezoid:
        return _polygon(rect, [
          Offset(rect.left, rect.top),
          Offset(rect.right, rect.top),
          Offset(rect.right - rect.width * .16, rect.bottom),
          Offset(rect.left + rect.width * .16, rect.bottom),
        ]);
      case NativeMermaidBlockShape.leftArrow:
        final arrow = math.min(rect.height / 2, rect.width * .2);
        return _polygon(rect, [
          Offset(rect.left, rect.center.dy),
          Offset(rect.left + arrow, rect.top),
          Offset(rect.right, rect.top),
          Offset(rect.right, rect.bottom),
          Offset(rect.left + arrow, rect.bottom),
        ]);
      case NativeMermaidBlockShape.blockArrow:
        final arrow = math.min(rect.width / 3, rect.height / 2);
        return _polygon(rect, [
          Offset(rect.left, rect.top),
          Offset(rect.right - arrow, rect.top),
          Offset(rect.right, rect.center.dy),
          Offset(rect.right - arrow, rect.bottom),
          Offset(rect.left, rect.bottom),
        ]);
      case NativeMermaidBlockShape.rectangle:
      case NativeMermaidBlockShape.subroutine:
      case NativeMermaidBlockShape.cylinder:
        return Path()..addRect(rect);
      case NativeMermaidBlockShape.composite:
      case NativeMermaidBlockShape.space:
        return Path();
    }
  }

  Path _polygon(Rect rect, List<Offset> points) {
    final path = Path()..moveTo(points.first.dx, points.first.dy);
    for (final point in points.skip(1)) {
      path.lineTo(point.dx, point.dy);
    }
    return path..close();
  }

  TextPainter _text(String text, Color color) => TextPainter(
    text: TextSpan(
      text: text,
      style: TextStyle(
        fontFamily: fontFamily,
        fontSize: fontSize,
        color: color,
        letterSpacing: 0,
      ),
    ),
    textDirection: TextDirection.ltr,
    textScaler: TextScaler.noScaling,
  );

  @override
  bool shouldRepaint(_BlockPainter old) =>
      layout != old.layout ||
      dark != old.dark ||
      fontFamily != old.fontFamily ||
      fontSize != old.fontSize;
}
