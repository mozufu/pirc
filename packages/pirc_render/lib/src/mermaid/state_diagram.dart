import '../render_l10n.dart';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:html/parser.dart' as html;
import 'state_model.dart';
import 'state_style.dart';
export 'state_model.dart';

class MermaidStateNodeLayout {
  const MermaidStateNodeLayout(this.node, this.bounds, this.depth);
  final MermaidStateNode node;
  final Rect bounds;
  final int depth;
}

class MermaidStateEdgeLayout {
  const MermaidStateEdgeLayout(this.edge, this.path, this.labelCenter);
  final MermaidStateEdge edge;
  final Path path;
  final Offset labelCenter;
}

class MermaidStateLayout {
  const MermaidStateLayout(this.size, this.nodes, this.edges);
  final Size size;
  final List<MermaidStateNodeLayout> nodes;
  final List<MermaidStateEdgeLayout> edges;
}

String _plain(String value) =>
    html
        .parseFragment(
          value.replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n'),
        )
        .text ??
    '';

TextPainter _text(String value, String? family, {Color color = Colors.black}) =>
    TextPainter(
      text: TextSpan(
        text: _plain(value),
        style: TextStyle(
          fontFamily: family,
          fontSize: 13,
          height: 1.5,
          fontWeight: FontWeight.w400,
          letterSpacing: 0,
          color: color,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();

Size _textSize(String value, String? family) {
  final painter = _text(value, family);
  final size = Size(
    painter.width,
    math.max(1, painter.computeLineMetrics().length) * 19.5,
  );
  painter.dispose();
  return size;
}

class _Region {
  const _Region(this.size, this.boxes);
  final Size size;
  final Map<String, Rect> boxes;
}

/// Recursive compound layout: each container lays out its immediate children,
/// then projects transitions between descendants onto those child containers.
/// Feedback edges are removed only from ranking; every transition is painted.
MermaidStateLayout layoutNativeMermaidStateDiagram(
  MermaidStateDiagramModel model, {
  String? fontFamily,
}) {
  final nodes = {for (final node in model.nodes) node.id: node};
  final children = <String?, List<String>>{};
  for (final node in model.nodes) {
    (children[node.parentId] ??= []).add(node.id);
  }
  final depths = <String, int>{};
  final regionDirections = <String?, String>{};
  final active = <String>{};
  String? lift(String id, String? parent) {
    final seen = <String>{};
    while (seen.add(id)) {
      final node = nodes[id];
      if (node == null || id == parent) return null;
      if (node.parentId == parent) return id;
      if (node.parentId == null) return null;
      id = node.parentId!;
    }
    throw FormatException(tr("Cyclic state containment"));
  }

  Size leafSize(MermaidStateNode node, bool vertical) {
    if (node.isStart || node.isEnd) return const Size(14, 14);
    if (node.shape == 'choice') return const Size(28, 28);
    if (node.shape == 'fork' || node.shape == 'join') {
      return vertical ? const Size(70, 10) : const Size(10, 70);
    }
    final label = _textSize(node.label, fontFamily);
    if (node.shape == 'rectWithTitle') {
      final body = _textSize(node.descriptions.join('\n'), fontFamily);
      // rectWithTitle.ts: half padding 4, title/body gap 4 + 5, padding 8.
      return Size(
        math.max(label.width, body.width) + 8,
        label.height + 9 + body.height + 8,
      );
    }
    final padding = node.shape == 'note' ? 30.0 : 16.0;
    return Size(label.width + padding, label.height + padding);
  }

  late _Region Function(String?, String, int) region;
  region = (parent, inheritedDirection, depth) {
    if (depth > 64) {
      throw FormatException(tr("State nesting exceeds 64 levels"));
    }
    final owner = nodes[parent];
    final direction = owner?.direction ?? inheritedDirection;
    regionDirections[parent] = direction;
    final vertical = direction != 'LR' && direction != 'RL';
    final ids = children[parent] ?? const <String>[];
    final local = <String, _Region>{};
    for (final id in ids) {
      if (!active.add(id)) {
        throw FormatException(tr("Cyclic state containment"));
      }
      final node = nodes[id]!;
      depths[id] = depth;
      if (node.isGroup) {
        local[id] = region(id, direction, depth + 1);
      } else {
        local[id] = _Region(leafSize(node, vertical), const {});
      }
      active.remove(id);
    }
    if (ids.isEmpty) return const _Region(Size(16, 16), {});

    final adjacency = {for (final id in ids) id: <String>{}};
    final labels = <(String, String), List<String>>{};
    for (final edge in model.edges) {
      final from = lift(edge.start, parent), to = lift(edge.end, parent);
      if (from == null || to == null || from == to) continue;
      adjacency[from]!.add(to);
      (labels[(from, to)] ??= []).add(edge.label ?? '');
    }
    final marks = <String, int>{};
    final feedback = <(String, String)>{};
    void visit(String id) {
      marks[id] = 1;
      for (final next in adjacency[id]!) {
        if (marks[next] == 1) {
          feedback.add((id, next));
        } else if (marks[next] != 2) {
          visit(next);
        }
      }
      marks[id] = 2;
    }

    for (final id in ids) {
      if (!marks.containsKey(id)) visit(id);
    }
    final indegree = {for (final id in ids) id: 0};
    for (final id in ids) {
      for (final next in adjacency[id]!) {
        if (!feedback.contains((id, next))) {
          indegree[next] = indegree[next]! + 1;
        }
      }
    }
    final rank = {for (final id in ids) id: 0};
    final queue = ids.where((id) => indegree[id] == 0).toList();
    for (var i = 0; i < queue.length; i++) {
      final id = queue[i];
      for (final next in adjacency[id]!) {
        if (feedback.contains((id, next))) continue;
        rank[next] = math.max(rank[next]!, rank[id]! + 1);
        indegree[next] = indegree[next]! - 1;
        if (indegree[next] == 0) queue.add(next);
      }
    }
    final layers = <int, List<String>>{};
    for (final id in ids) {
      (layers[rank[id]!] ??= []).add(id);
    }
    final ranks = layers.keys.toList()..sort();
    final crossSizes = <int, double>{}, depthSizes = <int, double>{};
    var crossMax = 0.0;
    for (final r in ranks) {
      var across = 0.0, along = 0.0;
      for (final id in layers[r]!) {
        final s = local[id]!.size;
        across += vertical ? s.width : s.height;
        along = math.max(along, vertical ? s.height : s.width);
      }
      across += (layers[r]!.length - 1) * 50;
      crossSizes[r] = across;
      depthSizes[r] = along;
      crossMax = math.max(crossMax, across);
    }
    var sideLane = 0.0;
    for (final entry in labels.entries) {
      for (final label in entry.value.where((s) => s.isNotEmpty)) {
        final text = _textSize(label, fontFamily);
        crossMax = math.max(crossMax, vertical ? text.width : text.height);
        if (feedback.contains(entry.key)) {
          sideLane = math.max(
            sideLane,
            20 + (vertical ? text.width : text.height) / 2,
          );
        }
      }
    }
    if (feedback.isNotEmpty) sideLane = math.max(27, sideLane);
    // Mermaid raises the child graph rank separation by 25 at each
    // compound extraction, including the synthetic parallel-region groups.
    final rankSeparation = 50.0 + depth * 25;
    final alongMargin = parent == null ? 8.0 : rankSeparation / 2;
    // Dagre borders are zero-width dummy nodes: half nodesep (50) plus
    // half edgesep (20) separates them from a regular child.
    final crossMargin = parent == null ? 8.0 : (50.0 + 20.0) / 2;
    var cursor = alongMargin;
    final centers = <int, double>{};
    for (final r in ranks) {
      centers[r] = cursor + depthSizes[r]! / 2;
      var labelDepth = 0.0;
      for (final entry in labels.entries) {
        if (rank[entry.key.$1] != r || rank[entry.key.$2]! <= r) continue;
        for (final label in entry.value.where((s) => s.isNotEmpty)) {
          final size = _textSize(label, fontFamily);
          labelDepth = math.max(
            labelDepth,
            vertical ? size.height : size.width,
          );
        }
      }
      cursor +=
          depthSizes[r]! + (r == ranks.last ? 0 : rankSeparation + labelDepth);
    }
    final alongSize = cursor + alongMargin;
    final acrossSize = crossMax + 2 * (crossMargin + sideLane);
    var size = vertical
        ? Size(acrossSize, alongSize)
        : Size(alongSize, acrossSize);
    if (owner?.shape == 'roundedWithTitle') {
      size = Size(
        math.max(size.width, _textSize(owner!.label, fontFamily).width + 8),
        size.height,
      );
    }
    final boxes = <String, Rect>{};
    for (final r in ranks) {
      var across = crossMargin + sideLane + (crossMax - crossSizes[r]!) / 2;
      for (final id in layers[r]!) {
        final child = local[id]!;
        final cross =
            across + (vertical ? child.size.width : child.size.height) / 2;
        final along = centers[r]!;
        final center = switch (direction) {
          'LR' => Offset(along, cross),
          'RL' => Offset(alongSize - along, cross),
          'BT' => Offset(cross, alongSize - along),
          _ => Offset(cross, along),
        };
        final box = Rect.fromCenter(
          center: center,
          width: child.size.width,
          height: child.size.height,
        );
        boxes[id] = box;
        for (final entry in child.boxes.entries) {
          boxes[entry.key] = entry.value.shift(box.topLeft);
        }
        across += (vertical ? child.size.width : child.size.height) + 50;
      }
    }
    return _Region(size, boxes);
  };
  final result = region(null, model.direction, 0);
  if (result.boxes.length != nodes.length) {
    throw FormatException(tr("State references an unrenderable parent"));
  }
  final layouts = [
    for (final node in model.nodes)
      MermaidStateNodeLayout(
        node,
        result.boxes[node.id]!,
        depths[node.id] ?? 0,
      ),
  ]..sort((a, b) => a.depth.compareTo(b.depth));

  final routes = <MermaidStateEdgeLayout>[];
  for (var i = 0; i < model.edges.length; i++) {
    final edge = model.edges[i];
    final a = result.boxes[edge.start], b = result.boxes[edge.end];
    if (a == null || b == null) {
      throw FormatException(tr("Missing state transition endpoint"));
    }
    final parent = nodes[edge.start]!.parentId;
    final direction = regionDirections[parent] ?? model.direction;
    final vertical = direction != 'LR' && direction != 'RL';
    final reverse = direction == 'RL' || direction == 'BT';
    final forward =
        (vertical ? b.center.dy - a.center.dy : b.center.dx - a.center.dx) *
            (reverse ? -1 : 1) >
        0;
    final reciprocal = model.edges.any(
      (other) => other.start == edge.end && other.end == edge.start,
    );
    final path = Path();
    Offset start, end, labelCenter;
    if (edge.start == edge.end) {
      start = Offset(a.right, a.center.dy - 5);
      end = Offset(a.right, a.center.dy + 5);
      final loop = math.max(
        35.0,
        _textSize(edge.label ?? '', fontFamily).width / 2 + 12,
      );
      path.moveTo(start.dx, start.dy);
      path.cubicTo(
        a.right + loop,
        a.top - 15,
        a.right + loop,
        a.bottom + 15,
        end.dx,
        end.dy,
      );
      labelCenter = Offset(a.right + loop * .75, a.center.dy);
    } else if (reciprocal || !forward) {
      final lane = reciprocal && !forward ? 25.0 : -25.0;
      final delta = vertical ? Offset(lane, 0) : Offset(0, lane);
      final midpoint = (a.center + b.center) / 2 + delta;
      start = _boundary(a, midpoint, nodes[edge.start]!.shape);
      end = _boundary(b, midpoint, nodes[edge.end]!.shape);
      path.moveTo(start.dx, start.dy);
      path.quadraticBezierTo(
        midpoint.dx + delta.dx,
        midpoint.dy + delta.dy,
        end.dx,
        end.dy,
      );
      labelCenter = (start + end) / 2 + delta;
    } else {
      final mid = vertical
          ? Offset((a.center.dx + b.center.dx) / 2, (a.bottom + b.top) / 2)
          : Offset((a.right + b.left) / 2, (a.center.dy + b.center.dy) / 2);
      final approachA = vertical
          ? Offset(mid.dx, b.center.dy)
          : Offset(b.center.dx, mid.dy);
      final approachB = vertical
          ? Offset(mid.dx, a.center.dy)
          : Offset(a.center.dx, mid.dy);
      start = _boundary(a, approachA, nodes[edge.start]!.shape);
      end = _boundary(b, approachB, nodes[edge.end]!.shape);
      path.moveTo(start.dx, start.dy);
      if (vertical) {
        path.cubicTo(start.dx, mid.dy, end.dx, mid.dy, end.dx, end.dy);
      } else {
        path.cubicTo(mid.dx, start.dy, mid.dx, end.dy, end.dx, end.dy);
      }
      labelCenter = mid;
    }
    routes.add(MermaidStateEdgeLayout(edge, path, labelCenter));
  }
  var ink = Offset.zero & result.size;
  for (final route in routes) {
    ink = ink.expandToInclude(route.path.getBounds().inflate(8));
    if ((route.edge.label ?? '').isNotEmpty) {
      final text = _textSize(route.edge.label!, fontFamily);
      ink = ink.expandToInclude(
        Rect.fromCenter(
          center: route.labelCenter,
          width: text.width + 16,
          height: text.height + 16,
        ),
      );
    }
  }
  final shift = -ink.topLeft;
  return MermaidStateLayout(
    ink.size,
    List.unmodifiable(
      layouts.map(
        (item) => MermaidStateNodeLayout(
          item.node,
          item.bounds.shift(shift),
          item.depth,
        ),
      ),
    ),
    List.unmodifiable(
      routes.map(
        (route) => MermaidStateEdgeLayout(
          route.edge,
          route.path.shift(shift),
          route.labelCenter + shift,
        ),
      ),
    ),
  );
}

Offset _boundary(Rect bounds, Offset toward, String shape) {
  final delta = toward - bounds.center;
  if (delta.distance < .001) return bounds.bottomCenter;
  if (shape == 'stateStart' || shape == 'stateEnd') {
    return bounds.center + delta / delta.distance * bounds.width / 2;
  }
  final halfW = math.max(.01, bounds.width / 2),
      halfH = math.max(.01, bounds.height / 2);
  final scale = shape == 'choice'
      ? 1 / (delta.dx.abs() / halfW + delta.dy.abs() / halfH)
      : 1 / math.max(delta.dx.abs() / halfW, delta.dy.abs() / halfH);
  return bounds.center + delta * scale;
}

class NativeMermaidStateDiagram extends StatelessWidget {
  const NativeMermaidStateDiagram({
    super.key,
    required this.source,
    this.dark = false,
  });
  final String source;
  final bool dark;

  @override
  Widget build(BuildContext context) {
    RenderL10n.watch(context);
    final model = parseNativeMermaidStateDiagram(source);
    final family = DefaultTextStyle.of(context).style.fontFamily;
    final layout = layoutNativeMermaidStateDiagram(model, fontFamily: family);
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.hasBoundedWidth
            ? constraints.maxWidth
            : layout.size.width;
        final scale = math.min(1.0, width / layout.size.width);
        final description = [
          'State diagram',
          if (model.accessibleTitle.isNotEmpty) model.accessibleTitle,
          if (model.accessibleDescription.isNotEmpty)
            model.accessibleDescription,
          ...model.nodes
              .where((n) => !n.isStart && !n.isEnd && n.shape != 'divider')
              .map((n) => _plain([n.label, ...n.descriptions].join('. '))),
          ...model.edges.map(
            (e) =>
                '${e.start} to ${e.end}${(e.label ?? '').isEmpty ? '' : ': ${e.label!}'}',
          ),
        ].join('. ');
        return Semantics(
          image: true,
          label: description,
          child: SizedBox(
            width: width,
            height: layout.size.height * scale,
            child: Align(
              alignment: Alignment.topCenter,
              child: SizedBox(
                width: layout.size.width * scale,
                height: layout.size.height * scale,
                child: FittedBox(
                  fit: BoxFit.contain,
                  child: CustomPaint(
                    size: layout.size,
                    painter: MermaidStatePainter(
                      layout,
                      model,
                      dark: dark,
                      fontFamily: family,
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class MermaidStatePainter extends CustomPainter {
  const MermaidStatePainter(
    this.layout,
    this.model, {
    required this.dark,
    this.fontFamily,
  });
  final MermaidStateLayout layout;
  final MermaidStateDiagramModel model;
  final bool dark;
  final String? fontFamily;
  Color get nodeFill =>
      dark ? const Color(0xff1f2020) : const Color(0xffedf3fe);
  Color get nodeStroke =>
      dark ? const Color(0xffcccccc) : const Color(0xff4176e6);
  Color get edgeColor =>
      dark ? const Color(0xffd3d3d3) : const Color(0xff81858c);
  Color get textColor =>
      dark ? const Color(0xffe0dfdf) : const Color(0xff0f1115);
  Color get terminalColor =>
      dark ? const Color(0xfff4f4f4) : const Color(0xff81858c);
  Color get interior => dark ? const Color(0xff333333) : Colors.white;
  Color get labelBackground =>
      dark ? const Color(0xff585858) : const Color(0xfff1f3f5);

  Map<String, String> _styles(MermaidStateNode node) {
    final result = <String, String>{};
    for (final rule in [
      ...?model.styleClasses['default']?.styles,
      for (final name in node.classes) ...?model.styleClasses[name]?.styles,
      ...node.styles,
    ]) {
      final colon = rule.indexOf(':');
      if (colon > 0) {
        result[rule.substring(0, colon).trim()] = rule
            .substring(colon + 1)
            .trim();
      }
    }
    return result;
  }

  void _label(Canvas canvas, String text, Offset center, Color color) {
    final painter = _text(text, fontFamily, color: color);
    painter.paint(
      canvas,
      center - Offset(painter.width / 2, painter.height / 2),
    );
    painter.dispose();
  }

  @override
  void paint(Canvas canvas, Size size) {
    // Containers precede transitions; leaf nodes cover the path endpoints.
    for (final node in layout.nodes.where((n) => n.node.isGroup)) {
      _node(canvas, node);
    }
    final stroke = Paint()
      ..color = edgeColor
      ..strokeWidth = 1
      ..style = PaintingStyle.stroke;
    for (final route in layout.edges) {
      if (route.edge.arrowhead == 'none') {
        // Note links use the pinned .note-edge stroke-dasharray: 5.
        for (final metric in route.path.computeMetrics()) {
          for (var start = 0.0; start < metric.length; start += 10) {
            canvas.drawPath(
              metric.extractPath(start, math.min(start + 5, metric.length)),
              stroke,
            );
          }
        }
      } else {
        canvas.drawPath(route.path, stroke);
      }
      if (route.edge.arrowhead != 'none') {
        final metrics = route.path.computeMetrics().toList();
        if (metrics.isNotEmpty) {
          final tangent = metrics.last.getTangentForOffset(metrics.last.length);
          if (tangent != null) {
            final tip = tangent.position;
            final unit =
                tangent.vector / math.max(.001, tangent.vector.distance);
            final side = Offset(-unit.dy, unit.dx);
            final arrow = Path()
              ..moveTo(tip.dx, tip.dy)
              ..lineTo(
                (tip - unit * 10 + side * 6).dx,
                (tip - unit * 10 + side * 6).dy,
              )
              ..lineTo((tip - unit * 5).dx, (tip - unit * 5).dy)
              ..lineTo(
                (tip - unit * 10 - side * 6).dx,
                (tip - unit * 10 - side * 6).dy,
              )
              ..close();
            canvas.drawPath(arrow, Paint()..color = edgeColor);
            canvas.drawPath(
              arrow,
              Paint()
                ..color = edgeColor
                ..style = PaintingStyle.stroke
                ..strokeWidth = 1,
            );
          }
        }
      }
      final text = route.edge.label ?? '';
      if (text.isNotEmpty) {
        final size = _textSize(text, fontFamily);
        canvas.drawRect(
          Rect.fromCenter(
            center: route.labelCenter,
            width: size.width,
            height: size.height,
          ),
          Paint()..color = labelBackground,
        );
        _label(
          canvas,
          text,
          route.labelCenter,
          dark ? const Color(0xffcccccc) : textColor,
        );
      }
    }
    for (final node in layout.nodes.where((n) => !n.node.isGroup)) {
      _node(canvas, node);
    }
  }

  void _node(Canvas canvas, MermaidStateNodeLayout item) {
    final node = item.node, box = item.bounds;
    if (node.shape == 'noteGroup') return;
    final styles = _styles(node);
    final fill = parseNativeMermaidStateColor(styles['fill']) ?? nodeFill;
    final color = parseNativeMermaidStateColor(styles['color']) ?? textColor;
    final strokeColor =
        parseNativeMermaidStateColor(styles['stroke']) ?? nodeStroke;
    final border = Paint()
      ..color = strokeColor
      ..style = PaintingStyle.stroke
      ..strokeWidth =
          double.tryParse(
            (styles['stroke-width'] ?? '1').replaceAll('px', ''),
          ) ??
          1;
    final fillPaint = Paint()..color = fill;
    switch (node.shape) {
      case 'stateStart':
        canvas.drawCircle(box.center, 7, Paint()..color = terminalColor);
        canvas.drawCircle(
          box.center,
          7,
          Paint()
            ..color = terminalColor
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1,
        );
        return;
      case 'stateEnd':
        canvas.drawCircle(box.center, 7, fillPaint);
        canvas.drawCircle(
          box.center,
          7,
          Paint()
            ..color = edgeColor
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2,
        );
        canvas.drawCircle(box.center, 2.5, Paint()..color = nodeStroke);
        return;
      case 'choice':
        final path = Path()
          ..moveTo(box.center.dx, box.top)
          ..lineTo(box.right, box.center.dy)
          ..lineTo(box.center.dx, box.bottom)
          ..lineTo(box.left, box.center.dy)
          ..close();
        canvas.drawPath(path, fillPaint);
        canvas.drawPath(path, border..strokeWidth = 1.3);
        return;
      case 'fork':
      case 'join':
        canvas.drawRect(box, Paint()..color = edgeColor);
        canvas.drawRect(
          box,
          Paint()
            ..color = edgeColor
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.3,
        );
        return;
      case 'divider':
        canvas.drawRect(
          box,
          Paint()
            ..color = dark ? const Color(0xff555555) : const Color(0xfff9fafb),
        );
        final path = Path()..addRect(box);
        for (final metric in path.computeMetrics()) {
          for (var p = 0.0; p < metric.length; p += 20) {
            canvas.drawPath(
              metric.extractPath(p, math.min(p + 10, metric.length)),
              border,
            );
          }
        }
        return;
      case 'note':
        canvas.drawRect(
          box,
          Paint()
            ..color = dark ? const Color(0xff474949) : const Color(0xfffff5ad),
        );
        canvas.drawRect(
          box,
          Paint()
            ..color = dark ? const Color(0xff2f2f2f) : const Color(0xffe4db95)
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.3,
        );
        _label(
          canvas,
          node.label,
          box.center,
          dark ? const Color(0xffb8b6b6) : const Color(0xff333333),
        );
        return;
    }
    final rounded = RRect.fromRectAndRadius(box, const Radius.circular(5));
    canvas.drawRRect(rounded, fillPaint);
    if (node.shape == 'rectWithTitle') {
      final titleHeight = _textSize(node.label, fontFamily).height;
      final description = node.descriptions.join('\n');
      final bodyHeight = _textSize(description, fontFamily).height;
      final split = box.top + titleHeight + 4;
      canvas.drawLine(
        Offset(box.left, split),
        Offset(box.right, split),
        border,
      );
      _label(
        canvas,
        node.label,
        Offset(box.center.dx, box.top + 3 + titleHeight / 2),
        color,
      );
      _label(
        canvas,
        description,
        Offset(box.center.dx, box.top + titleHeight + 12 + bodyHeight / 2),
        color,
      );
    } else if (node.isGroup) {
      final labelHeight = _textSize(node.label, fontFamily).height;
      // Pinned clusters.js keeps a two-pixel title gap and four-pixel footer.
      final inner = Rect.fromLTRB(
        box.left,
        box.top + labelHeight + 2,
        box.right,
        box.bottom - 4,
      );
      canvas.drawRect(inner, Paint()..color = interior);
      canvas.drawRect(inner, border);
      _label(
        canvas,
        node.label,
        Offset(box.center.dx, box.top + 1 + labelHeight / 2),
        color,
      );
    } else {
      _label(canvas, node.label, box.center, color);
    }
    canvas.drawRRect(rounded, border);
  }

  @override
  bool shouldRepaint(covariant MermaidStatePainter oldDelegate) =>
      oldDelegate.layout != layout ||
      oldDelegate.dark != dark ||
      oldDelegate.fontFamily != fontFamily;
}
