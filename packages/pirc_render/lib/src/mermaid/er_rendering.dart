import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'er_diagram.dart';
import 'flowchart.dart';

class NativeMermaidErEntityLayout {
  const NativeMermaidErEntityLayout(
    this.entity,
    this.bounds,
    this.columnWidths,
    this.rowHeight,
    this.headerHeight,
  );
  final NativeMermaidErEntity entity;
  final Rect bounds;
  final List<double> columnWidths;
  final double rowHeight, headerHeight;
}

class NativeMermaidErRelationshipLayout {
  const NativeMermaidErRelationshipLayout(
    this.relationship,
    this.path,
    this.labelCenter,
  );
  final NativeMermaidErRelationship relationship;
  final Path path;
  final Offset labelCenter;
}

class NativeMermaidErDiagramLayout {
  const NativeMermaidErDiagramLayout(
    this.size,
    this.entities,
    this.relationships,
  );
  final Size size;
  final List<NativeMermaidErEntityLayout> entities;
  final List<NativeMermaidErRelationshipLayout> relationships;
  Rect? boundsForEntity(String id) => entities
      .where((item) => item.entity.id == id || item.entity.name == id)
      .firstOrNull
      ?.bounds;
}

TextPainter _text(
  String value,
  String? family, {
  double size = 13,
  Color color = Colors.black,
}) => TextPainter(
  text: TextSpan(
    text: value,
    style: TextStyle(
      fontFamily: family,
      fontSize: size,
      height: 1.5,
      letterSpacing: 0,
      color: color,
    ),
  ),
  textDirection: TextDirection.ltr,
)..layout();

// erBox.ts multiplies both paddings by 1.25 when the global htmlLabels flag
// is unset. The pinned renderer still creates HTML labels via its defaults.
const _columnPadding = 20.0 * 1.25;
const _textPadding = 15.0 * 1.25;

NativeMermaidErDiagramLayout layoutNativeMermaidErDiagram(
  NativeMermaidErDiagramData data, {
  String? fontFamily,
  TextStyle? inheritedTextStyle,
}) {
  final family = fontFamily ?? inheritedTextStyle?.fontFamily;
  Size measure(String value, {double size = 13}) {
    final painter = _text(value, family, size: size);
    final measured = Size(
      painter.width,
      size * 1.5 * painter.computeLineMetrics().length,
    );
    painter.dispose();
    return measured;
  }

  final metrics = <String, NativeMermaidErEntityLayout>{};
  for (final entity in data.entities) {
    final header = measure(entity.displayLabel);
    if (entity.attributes.isEmpty) {
      // The early drawRect branch uses the unmultiplied diagram padding.
      final size = Size(
        measure(entity.displayLabel, size: 16).width + 40 < 100
            ? math.max(100, header.width + 40)
            : header.width + 40,
        math.max(75, header.height + 60),
      );
      metrics[entity.id] = NativeMermaidErEntityLayout(
        entity,
        Offset.zero & size,
        const [],
        0,
        size.height,
      );
      continue;
    }
    final widths = List<double>.filled(4, 0);
    var widestText = header.width;
    var rowHeight = 0.0;
    for (final attribute in entity.attributes) {
      final fields = [
        attribute.type,
        attribute.name,
        attribute.keys.join(','),
        attribute.comment,
      ];
      for (var i = 0; i < fields.length; i++) {
        final size = measure(fields[i]);
        widths[i] = math.max(widths[i], size.width + _columnPadding);
        widestText = math.max(widestText, size.width);
        rowHeight = math.max(rowHeight, size.height + _textPadding);
      }
    }
    for (final i in [2, 3]) {
      if (widths[i] <= _columnPadding) widths[i] = 0;
    }
    final present = widths.where((width) => width > 0).length;
    final spare =
        header.width + _columnPadding * 2 - widths.reduce((a, b) => a + b);
    if (spare > 0) {
      for (var i = 0; i < widths.length; i++) {
        if (widths[i] > 0) widths[i] += spare / present;
      }
    }
    final width = math.max(
      widestText + _columnPadding * 2,
      widths.reduce((a, b) => a + b),
    );
    final headerHeight = header.height + _textPadding;
    final height = headerHeight + rowHeight * entity.attributes.length;
    metrics[entity.id] = NativeMermaidErEntityLayout(
      entity,
      Rect.fromLTWH(0, 0, width, height),
      widths,
      rowHeight,
      headerHeight,
    );
  }
  final graph = MermaidFlowchartGraph(
    data.direction,
    data.entities.map(
      (entity) => MermaidFlowNode(
        entity.id,
        entity.displayLabel,
        MermaidFlowNodeShape.rectangle,
      ),
    ),
    data.relationships.map(
      (edge) => MermaidFlowEdge(
        edge.entityA,
        edge.entityB,
        edge.roleA,
        edge.pattern == 'dashed'
            ? MermaidFlowLineStyle.dotted
            : MermaidFlowLineStyle.solid,
        MermaidFlowMarker.none,
        MermaidFlowMarker.none,
      ),
    ),
  );
  // Uses the shared native layered graph implementation. General Dagre ordering,
  // crossing minimization and cycle routing remain documented parity gaps.
  final graphLayout = layoutNativeMermaidFlowchart(
    graph,
    fontFamily: family,
    nodeSizes: metrics.map((id, item) => MapEntry(id, item.bounds.size)),
    measureEdgeLabel: (label) => measure(label, size: 14),
    nodeSpacing: 140,
    rankSpacing: 80,
  );
  return NativeMermaidErDiagramLayout(
    graphLayout.size,
    graphLayout.nodes
        .map((node) {
          final item = metrics[node.node.id]!;
          return NativeMermaidErEntityLayout(
            item.entity,
            node.bounds,
            item.columnWidths,
            item.rowHeight,
            item.headerHeight,
          );
        })
        .toList(growable: false),
    [
      for (var i = 0; i < data.relationships.length; i++)
        NativeMermaidErRelationshipLayout(
          data.relationships[i],
          graphLayout.edges[i].path,
          graphLayout.edges[i].labelCenter,
        ),
    ],
  );
}

class NativeMermaidErDiagram extends StatelessWidget {
  const NativeMermaidErDiagram({
    super.key,
    required this.source,
    required this.dark,
  });
  final String source;
  final bool dark;
  @override
  Widget build(BuildContext context) {
    final data = parseNativeMermaidErDiagram(source);
    final family = DefaultTextStyle.of(context).style.fontFamily;
    final layout = layoutNativeMermaidErDiagram(data, fontFamily: family);
    final chart = SizedBox(
      width: layout.size.width,
      height: layout.size.height,
      child: CustomPaint(painter: _ErPainter(layout, dark, family)),
    );
    return Semantics(
      image: true,
      label: data.semanticsLabel,
      child: LayoutBuilder(
        builder: (context, constraints) =>
            constraints.hasBoundedWidth &&
                constraints.maxWidth < layout.size.width
            ? FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.topLeft,
                child: chart,
              )
            : Align(alignment: Alignment.topCenter, child: chart),
      ),
    );
  }
}

class _ErPainter extends CustomPainter {
  const _ErPainter(this.layout, this.dark, this.family);
  final NativeMermaidErDiagramLayout layout;
  final bool dark;
  final String? family;
  Color get ink => dark ? const Color(0xffcccccc) : const Color(0xff0f1115);
  Color get border => dark ? const Color(0xffcccccc) : const Color(0xff4176e6);
  Color get line => dark ? const Color(0xffd3d3d3) : const Color(0xff81858c);
  Color get fill => dark ? const Color(0xff1f2020) : const Color(0xffedf3fe);

  @override
  void paint(Canvas canvas, Size size) {
    final stroke = Paint()
      ..style = PaintingStyle.stroke
      ..color = line
      ..strokeWidth = 1;
    for (final edge in layout.relationships) {
      if (edge.relationship.pattern == 'dashed') {
        for (final metric in edge.path.computeMetrics()) {
          for (var distance = 0.0; distance < metric.length; distance += 6) {
            canvas.drawPath(
              metric.extractPath(
                distance,
                math.min(distance + 3, metric.length),
              ),
              stroke,
            );
          }
        }
      } else {
        canvas.drawPath(edge.path, stroke);
      }
      final metric = edge.path.computeMetrics().firstOrNull;
      if (metric != null && metric.length > 0) {
        final start = metric.getTangentForOffset(0),
            end = metric.getTangentForOffset(metric.length);
        if (start != null) {
          _marker(
            canvas,
            start.position,
            start.vector,
            edge.relationship.cardB,
            false,
          );
        }
        if (end != null) {
          _marker(
            canvas,
            end.position,
            end.vector,
            edge.relationship.cardA,
            true,
          );
        }
      }
      if (edge.relationship.roleA.isNotEmpty) {
        final label = _text(
          edge.relationship.roleA,
          family,
          size: 14,
          color: ink,
        );
        final box = Rect.fromCenter(
          center: edge.labelCenter,
          width: label.width,
          height: label.height,
        );
        canvas.drawRect(
          box,
          Paint()
            ..color = dark ? const Color(0x80201f1f) : const Color(0x80f9fafb),
        );
        label.paint(canvas, box.topLeft);
        label.dispose();
      }
    }
    for (final entity in layout.entities) {
      final rect = entity.bounds;
      canvas.drawRect(rect, Paint()..color = fill);
      canvas.drawRect(
        rect,
        Paint()
          ..color = border
          ..style = PaintingStyle.stroke
          ..strokeWidth = entity.entity.attributes.isEmpty ? 1 : 1.3,
      );
      final header = _text(entity.entity.displayLabel, family, color: ink);
      header.paint(
        canvas,
        Offset(
          rect.center.dx - header.width / 2,
          rect.top +
              (entity.entity.attributes.isEmpty
                  ? (rect.height - header.height) / 2
                  : _textPadding / 2),
        ),
      );
      header.dispose();
      if (entity.entity.attributes.isEmpty) continue;
      final rowStroke = Paint()
        ..color = border
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.3;
      for (var row = 0; row < entity.entity.attributes.length; row++) {
        final top = rect.top + entity.headerHeight + row * entity.rowHeight;
        final rowRect = Rect.fromLTWH(
          rect.left,
          top,
          rect.width,
          entity.rowHeight,
        );
        canvas.drawRect(
          rowRect,
          Paint()
            ..color = (dark
                ? (row % 2 == 0
                      ? const Color(0xff2c2d2d)
                      : const Color(0xff060606))
                : Colors.white),
        );
        canvas.drawRect(rowRect, rowStroke);
        final value = entity.entity.attributes[row];
        final fields = [
          value.type,
          value.name,
          value.keys.join(','),
          value.comment,
        ];
        var left = rect.left;
        for (var column = 0; column < 4; column++) {
          if (entity.columnWidths[column] == 0) continue;
          final text = _text(fields[column], family, color: ink);
          text.paint(
            canvas,
            Offset(left + _columnPadding / 2, top + _textPadding / 2),
          );
          text.dispose();
          left += entity.columnWidths[column];
        }
      }
      final divider = Paint()
        ..color = border
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.3;
      canvas.drawLine(
        Offset(rect.left, rect.top + entity.headerHeight),
        Offset(rect.right, rect.top + entity.headerHeight),
        divider,
      );
      var left = rect.left;
      for (var column = 0; column < 3; column++) {
        left += entity.columnWidths[column];
        if (entity.columnWidths.skip(column + 1).any((width) => width > 0)) {
          canvas.drawLine(
            Offset(left, rect.top + entity.headerHeight),
            Offset(left, rect.bottom),
            divider,
          );
        }
      }
    }
  }

  // Exact paths/reference coordinates from pinned markers.js; directions are
  // the path tangents, not a guessed axis direction.
  void _marker(
    Canvas canvas,
    Offset point,
    Offset vector,
    String cardinality,
    bool end,
  ) {
    canvas.save();
    canvas.translate(point.dx, point.dy);
    canvas.rotate(math.atan2(vector.dy, vector.dx));
    final stroke = Paint()
      ..style = PaintingStyle.stroke
      ..color = line
      ..strokeWidth = 1;
    final path = Path();
    void bar(double x) => path
      ..moveTo(x, -9)
      ..lineTo(x, 9);
    void circle(double x) {
      canvas.drawCircle(Offset(x, 0), 6, Paint()..color = Colors.white);
      canvas.drawCircle(Offset(x, 0), 6, stroke);
    }

    switch (cardinality) {
      case 'ONLY_ONE':
        bar(end ? -15 : 9);
        bar(end ? -9 : 15);
      case 'ZERO_OR_ONE':
        circle(end ? -21 : 21);
        bar(end ? -9 : 9);
      case 'ONE_OR_MORE':
        const x = -18.0;
        path
          ..moveTo(x, 0)
          ..quadraticBezierTo(x + 18, -18, x + 36, 0)
          ..quadraticBezierTo(x + 18, 18, x, 0);
        bar(end ? -24 : 24);
      case 'ZERO_OR_MORE':
        const x = -18.0;
        path
          ..moveTo(x, 0)
          ..quadraticBezierTo(x + 18, -18, x + 36, 0)
          ..quadraticBezierTo(x + 18, 18, x, 0);
        circle(end ? -30 : 30);
    }
    canvas.drawPath(path, stroke);
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _ErPainter old) =>
      old.layout != layout || old.dark != dark || old.family != family;
}
