import '../render_l10n.dart';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:html/parser.dart' as html;
import 'state_style.dart';

enum MermaidFlowNodeShape { rectangle, rounded, diamond, circle }

enum MermaidFlowLineStyle { solid, dotted, thick }

enum MermaidFlowMarker { none, arrow, circle, cross }

@immutable
class MermaidFlowNodeStyle {
  const MermaidFlowNodeStyle({
    this.fill,
    this.stroke,
    this.color,
    this.strokeWidth,
  });
  final Color? fill, stroke, color;
  final double? strokeWidth;
  MermaidFlowNodeStyle merge(MermaidFlowNodeStyle other) =>
      MermaidFlowNodeStyle(
        fill: other.fill ?? fill,
        stroke: other.stroke ?? stroke,
        color: other.color ?? color,
        strokeWidth: other.strokeWidth ?? strokeWidth,
      );
}

class MermaidFlowNode {
  const MermaidFlowNode(
    this.id,
    this.label,
    this.shape, {
    this.style = const MermaidFlowNodeStyle(),
  });
  final String id, label;
  final MermaidFlowNodeShape shape;
  final MermaidFlowNodeStyle style;
}

class MermaidFlowEdge {
  const MermaidFlowEdge(
    this.from,
    this.to,
    this.label,
    this.lineStyle,
    this.startMarker,
    this.endMarker,
  );
  final String from, to, label;
  final MermaidFlowLineStyle lineStyle;
  final MermaidFlowMarker startMarker, endMarker;
}

class MermaidFlowchartGraph {
  MermaidFlowchartGraph(
    this.direction,
    Iterable<MermaidFlowNode> nodes,
    Iterable<MermaidFlowEdge> edges,
  ) : nodes = List.unmodifiable(nodes),
      edges = List.unmodifiable(edges);
  final String direction;
  final List<MermaidFlowNode> nodes;
  final List<MermaidFlowEdge> edges;
}

/// Synchronous parser for a documented Mermaid flowchart subset. Unsupported
/// directives and syntax throw FormatException so callers can show source.
MermaidFlowchartGraph parseNativeMermaidFlowchart(String source) {
  final statements = _statements(source);
  if (statements.isEmpty) {
    throw FormatException(tr("Missing flowchart header."));
  }
  final header = RegExp(
    r'^(?:flowchart|graph)\s+(TD|TB|LR|BT|RL)$',
    caseSensitive: false,
  ).firstMatch(statements.first);
  if (header == null) {
    throw FormatException(
      tr("Expected graph/flowchart and a direction (TD, TB, LR, BT, or RL)."),
    );
  }
  final h = header.group(1)!.toUpperCase();
  final direction = h == 'TD' ? 'TB' : h;
  final nodes = <String, MermaidFlowNode>{};
  final edges = <MermaidFlowEdge>[];
  final classDefinitions = <String, MermaidFlowNodeStyle>{};
  final assignedClasses = <String, List<String>>{};
  final nodeStyles = <String, MermaidFlowNodeStyle>{};
  void assign(String id, String name) {
    assignedClasses.putIfAbsent(id, () => <String>[]).add(name);
  }

  void add(_Node n, _Cursor cursor) {
    final old = nodes[n.id];
    if (old == null || n.explicit) {
      nodes[n.id] = MermaidFlowNode(n.id, n.label, n.shape);
    }
    cursor.ws();
    if (cursor.s.startsWith(':::', cursor.i)) {
      cursor.i += 3;
      final start = cursor.i;
      while (!cursor.end &&
          RegExp(r'[A-Za-z0-9_-]').hasMatch(cursor.s[cursor.i])) {
        if (cursor.s[cursor.i] == '-' &&
            cursor.i + 1 < cursor.s.length &&
            ['-', '.', '>'].contains(cursor.s[cursor.i + 1])) {
          break;
        }
        cursor.i++;
      }
      final name = cursor.s.substring(start, cursor.i);
      if (name.isEmpty) {
        throw FormatException(tr("Expected Mermaid class name"));
      }
      assign(n.id, name);
    }
    if (nodes.length > 500) {
      throw FormatException(tr("Native flowcharts support at most 500 nodes."));
    }
  }

  for (var line = 1; line < statements.length; line++) {
    final text = statements[line].trim();
    final definition = RegExp(r'^classDef\s+([^\s]+)\s+(.+)$').firstMatch(text);
    if (definition != null) {
      final style = _parseFlowStyle(definition.group(2)!);
      for (final name in _styleNames(definition.group(1)!)) {
        classDefinitions[name] =
            (classDefinitions[name] ?? const MermaidFlowNodeStyle()).merge(
              style,
            );
      }
      continue;
    }
    final assignment = RegExp(
      r'^class\s+([^\s]+)\s+([^\s]+)$',
    ).firstMatch(text);
    if (assignment != null) {
      for (final id in _styleNames(assignment.group(1)!)) {
        for (final name in _styleNames(assignment.group(2)!)) {
          assign(id, name);
        }
      }
      continue;
    }
    final styled = RegExp(r'^style\s+([^\s]+)\s+(.+)$').firstMatch(text);
    if (styled != null) {
      final style = _parseFlowStyle(styled.group(2)!);
      for (final id in _styleNames(styled.group(1)!)) {
        nodeStyles[id] = (nodeStyles[id] ?? const MermaidFlowNodeStyle()).merge(
          style,
        );
      }
      continue;
    }
    if (RegExp(
      r'^(subgraph|linkStyle|click|accTitle|accDescr|direction|title|flowchart-v)(?:\s|$)',
      caseSensitive: false,
    ).hasMatch(text)) {
      throw FormatException(
        tr(
          "This Mermaid statement is not supported by the native flowchart renderer.",
        ),
      );
    }
    final c = _Cursor(text);
    var from = _node(c);
    add(from, c);
    while (true) {
      c.ws();
      if (c.end) break;
      final link = _edge(c);
      c.ws();
      if (c.end) {
        throw FormatException(tr("Mermaid edge has no destination node."));
      }
      final to = _node(c);
      add(to, c);
      edges.add(
        MermaidFlowEdge(
          from.id,
          to.id,
          link.label,
          link.style,
          link.start,
          link.end,
        ),
      );
      from = to;
    }
  }
  if (edges.length > 500) {
    throw FormatException(tr("Native flowcharts support at most 500 edges."));
  }
  final styledNodes = nodes.values.map((node) {
    var style = classDefinitions['default'] ?? const MermaidFlowNodeStyle();
    final classes = assignedClasses[node.id] ?? const <String>[];
    for (final name in classes) {
      style = style.merge(
        classDefinitions[name] ?? const MermaidFlowNodeStyle(),
      );
    }
    style = style.merge(nodeStyles[node.id] ?? const MermaidFlowNodeStyle());
    return MermaidFlowNode(node.id, node.label, node.shape, style: style);
  });
  return MermaidFlowchartGraph(direction, styledNodes, edges);
}

List<String> _styleNames(String source) {
  final names = source.split(',');
  if (names.any((name) => !RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(name))) {
    throw FormatException(tr("Unsupported Mermaid style target or class name"));
  }
  return names;
}

MermaidFlowNodeStyle _parseFlowStyle(String source) {
  final entries = <String>[];
  var start = 0, depth = 0;
  for (var i = 0; i < source.length; i++) {
    if (source[i] == '(') depth++;
    if (source[i] == ')') depth--;
    if (depth < 0) throw FormatException(tr("Invalid Mermaid style"));
    if (source[i] == ',' && depth == 0) {
      entries.add(source.substring(start, i));
      start = i + 1;
    }
  }
  if (depth != 0) throw FormatException(tr("Invalid Mermaid style"));
  entries.add(source.substring(start));
  var result = const MermaidFlowNodeStyle();
  for (final entry in entries) {
    final separator = entry.indexOf(':');
    if (separator < 1) {
      throw FormatException(tr("Expected Mermaid style property"));
    }
    final name = entry.substring(0, separator).trim();
    final value = entry.substring(separator + 1).trim();
    if (name == 'fill' || name == 'stroke' || name == 'color') {
      final color = value == 'none' && name != 'color'
          ? const Color(0x00000000)
          : parseNativeMermaidStateColor(value);
      if (color == null) {
        throw FormatException(
          tr("Unsupported Mermaid style color: {0}", [value]),
        );
      }
      result = result.merge(
        MermaidFlowNodeStyle(
          fill: name == 'fill' ? color : null,
          stroke: name == 'stroke' ? color : null,
          color: name == 'color' ? color : null,
        ),
      );
    } else if (name == 'stroke-width') {
      final match = RegExp(r'^(\d+(?:\.\d*)?|\.\d+)(?:px)?$').firstMatch(value);
      final width = match == null ? null : double.tryParse(match.group(1)!);
      if (width == null || !width.isFinite) {
        throw FormatException(tr("Unsupported Mermaid stroke width"));
      }
      result = result.merge(MermaidFlowNodeStyle(strokeWidth: width));
    } else {
      throw FormatException(tr("Unsupported Mermaid node style: {0}", [name]));
    }
  }
  return result;
}

class MermaidFlowchartNodeLayout {
  const MermaidFlowchartNodeLayout(this.node, this.bounds);
  final MermaidFlowNode node;
  final Rect bounds;
}

class MermaidFlowchartEdgeLayout {
  const MermaidFlowchartEdgeLayout(this.edge, this.path, this.labelCenter);
  final MermaidFlowEdge edge;
  final Path path;
  final Offset labelCenter;
}

class MermaidFlowchartLayout {
  MermaidFlowchartLayout(
    this.size,
    Iterable<MermaidFlowchartNodeLayout> nodes,
    Iterable<MermaidFlowchartEdgeLayout> edges,
  ) : nodes = List.unmodifiable(nodes),
      edges = List.unmodifiable(edges);
  final Size size;
  final List<MermaidFlowchartNodeLayout> nodes;
  final List<MermaidFlowchartEdgeLayout> edges;
}

/// Directed layered layout. Strongly connected components are condensed first,
/// so cycles remain finite and their feedback edges can use an outer track.
MermaidFlowchartLayout layoutNativeMermaidFlowchart(
  MermaidFlowchartGraph graph, {
  String? fontFamily,
  Map<String, Size>? nodeSizes,
  Size Function(String)? measureEdgeLabel,
  double nodeSpacing = 50,
  double rankSpacing = 50,
  double diagramPadding = 8,
}) {
  if (graph.nodes.isEmpty) {
    return MermaidFlowchartLayout(const Size(16, 16), const [], const []);
  }
  final ids = graph.nodes.map((n) => n.id).toList();
  final adjacency = <String, List<String>>{for (final id in ids) id: []};
  for (final e in graph.edges) {
    adjacency[e.from]!.add(e.to);
  }
  final components = _scc(ids, adjacency);
  final componentOf = <String, int>{};
  for (var i = 0; i < components.length; i++) {
    for (final id in components[i]) {
      componentOf[id] = i;
    }
  }
  final dag = List.generate(components.length, (_) => <int>{});
  final indegree = List.filled(components.length, 0);
  for (final e in graph.edges) {
    final a = componentOf[e.from]!, b = componentOf[e.to]!;
    if (a != b && dag[a].add(b)) indegree[b]++;
  }
  final local = <String, int>{};
  final heights = <int>[];
  for (var i = 0; i < components.length; i++) {
    final root = components[i].first;
    final q = <String>[root];
    local[root] = 0;
    for (var k = 0; k < q.length; k++) {
      for (final n in adjacency[q[k]]!) {
        if (componentOf[n] == i && !local.containsKey(n)) {
          local[n] = local[q[k]]! + 1;
          q.add(n);
        }
      }
    }
    var maxRank = 0;
    for (final id in components[i]) {
      local.putIfAbsent(id, () => 0);
      maxRank = math.max(maxRank, local[id]!).toInt();
    }
    heights.add(maxRank + 1);
  }
  final ready = <int>[
    for (var i = 0; i < indegree.length; i++)
      if (indegree[i] == 0) i,
  ];
  final base = List.filled(components.length, 0);
  for (var k = 0; k < ready.length; k++) {
    final a = ready[k];
    for (final b in dag[a]) {
      base[b] = math.max(base[b], base[a] + heights[a]).toInt();
      if (--indegree[b] == 0) ready.add(b);
    }
  }
  final rank = <String, int>{
    for (final id in ids) id: base[componentOf[id]!] + local[id]!,
  };
  final layers = <int, List<String>>{};
  for (final id in ids) {
    (layers[rank[id]!] ??= <String>[]).add(id);
  }

  final sizes = <String, Size>{
    for (final n in graph.nodes)
      n.id: nodeSizes?[n.id] ?? _measure(n, fontFamily),
  };
  final ranks = layers.keys.toList()..sort();
  final vertical = graph.direction != 'LR' && graph.direction != 'RL';
  final depthSizes = <int, double>{}, crossSizes = <int, double>{};
  var crossMax = 0.0;
  for (final r in ranks) {
    final group = layers[r]!;
    var depth = 0.0, cross = 0.0;
    for (final id in group) {
      final size = sizes[id]!;
      depth = math.max(depth, vertical ? size.height : size.width).toDouble();
      cross += vertical ? size.width : size.height;
    }
    cross += nodeSpacing * (group.length - 1);
    depthSizes[r] = depth;
    crossSizes[r] = cross;
    crossMax = math.max(crossMax, cross).toDouble();
  }
  final backEdges = graph.edges
      .where((e) => rank[e.to]! <= rank[e.from]!)
      .toList();
  final lanePad = backEdges.isEmpty
      ? 0.0
      : 20.0 + math.min(backEdges.length, 8) * 7.0;
  final margin = diagramPadding;
  final crossExtent = crossMax + 2 * (margin + lanePad);
  var depthExtent = margin * 2;
  final maxRank = ranks.isEmpty ? 0 : ranks.last;
  final offsets = List<double>.filled(maxRank + 1, 0);
  var cursor = margin;
  for (var r = 0; r <= maxRank; r++) {
    final depth = depthSizes[r] ?? 0;
    offsets[r] = cursor + depth / 2;
    var labelDepth = 0.0;
    for (final edge in graph.edges.where(
      (e) => rank[e.from] == r && rank[e.to]! > r && e.label.isNotEmpty,
    )) {
      Size labelSize;
      if (measureEdgeLabel != null) {
        labelSize = measureEdgeLabel(edge.label);
      } else {
        final label = _text(edge.label, Colors.black, fontFamily)..layout();
        labelSize = label.size;
        label.dispose();
      }
      labelDepth = math.max(
        labelDepth,
        vertical ? labelSize.height : labelSize.width,
      );
    }
    cursor += depth + rankSpacing + labelDepth;
    depthExtent += depth + rankSpacing + labelDepth;
  }
  if (ranks.isNotEmpty) depthExtent -= rankSpacing;

  final centers = <String, Offset>{};
  final nodeLayouts = <MermaidFlowchartNodeLayout>[];
  for (final r in ranks) {
    final group = layers[r]!;
    final total = crossSizes[r]!;
    var cross = margin + lanePad + (crossMax - total) / 2;
    for (final id in group) {
      final size = sizes[id]!;
      final crossSize = vertical ? size.width : size.height;
      final along = offsets[r], across = cross + crossSize / 2;
      final point = switch (graph.direction) {
        'LR' => Offset(along, across),
        'RL' => Offset(depthExtent - along, across),
        'BT' => Offset(across, depthExtent - along),
        _ => Offset(across, along),
      };
      centers[id] = point;
      final rect = Rect.fromCenter(
        center: point,
        width: size.width,
        height: size.height,
      );
      nodeLayouts.add(
        MermaidFlowchartNodeLayout(
          graph.nodes.firstWhere((n) => n.id == id),
          rect,
        ),
      );
      cross += crossSize + nodeSpacing;
    }
  }
  // Align a singleton parent rank to its children's centers.
  for (final r in ranks.reversed) {
    final group = layers[r]!;
    if (group.length != 1) continue;
    final id = group.single;
    final children = graph.edges
        .where((e) => e.from == id && rank[e.to]! > r)
        .map((e) => centers[e.to]!)
        .toList();
    if (children.isEmpty) continue;
    final cross =
        children.fold(0.0, (sum, p) => sum + (vertical ? p.dx : p.dy)) /
        children.length;
    final previous = centers[id]!;
    final center = vertical
        ? Offset(cross, previous.dy)
        : Offset(previous.dx, cross);
    centers[id] = center;
    final index = nodeLayouts.indexWhere((n) => n.node.id == id);
    final old = nodeLayouts[index];
    nodeLayouts[index] = MermaidFlowchartNodeLayout(
      old.node,
      Rect.fromCenter(
        center: center,
        width: old.bounds.width,
        height: old.bounds.height,
      ),
    );
  }
  final edgeLayouts = <MermaidFlowchartEdgeLayout>[];
  for (var i = 0; i < graph.edges.length; i++) {
    final e = graph.edges[i];
    final from = nodeLayouts.firstWhere((n) => n.node.id == e.from);
    final to = nodeLayouts.firstWhere((n) => n.node.id == e.to);
    final back = rank[e.to]! <= rank[e.from]!;
    final track = margin + lanePad - 8 - (i % 8) * 7;
    final path = back
        ? _backPath(from.bounds, to.bounds, vertical, track, i.isEven)
        : _forwardPath(
            from.bounds,
            to.bounds,
            vertical,
            graph.direction,
            from.node.shape,
            to.node.shape,
          );
    final metric = path.computeMetrics().first;
    edgeLayouts.add(
      MermaidFlowchartEdgeLayout(
        e,
        path,
        back
            ? (metric.getTangentForOffset(metric.length / 2)?.position ??
                  centers[e.from]!)
            : _bendPoint(from.bounds, to.bounds, vertical, graph.direction),
      ),
    );
  }
  final horizontal = !vertical;
  return MermaidFlowchartLayout(
    horizontal
        ? Size(depthExtent, crossExtent)
        : Size(crossExtent, depthExtent),
    nodeLayouts,
    edgeLayouts,
  );
}

class NativeMermaidFlowchart extends StatelessWidget {
  const NativeMermaidFlowchart({
    super.key,
    required this.source,
    required this.dark,
  });
  final String source;
  final bool dark;
  @override
  Widget build(BuildContext context) {
    RenderL10n.watch(context);
    final family = DefaultTextStyle.of(context).style.fontFamily;
    final graph = parseNativeMermaidFlowchart(source);
    final layout = layoutNativeMermaidFlowchart(graph, fontFamily: family);
    final description = StringBuffer('Flowchart, direction ');
    description.write(graph.direction);
    for (final n in graph.nodes) {
      description.write('. Node: ');
      description.write(n.label);
    }
    for (final e in graph.edges) {
      description.write('. ');
      description.write(e.from);
      description.write(' to ');
      description.write(e.to);
      if (e.label.isNotEmpty) {
        description.write(', ');
        description.write(e.label);
      }
    }
    final chart = SizedBox(
      key: const ValueKey('native-mermaid-flowchart'),
      width: layout.size.width,
      height: layout.size.height,
      child: CustomPaint(painter: _Painter(layout, dark, source, family)),
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        final child =
            constraints.hasBoundedWidth &&
                constraints.maxWidth < layout.size.width
            ? FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.topLeft,
                child: chart,
              )
            : Align(alignment: Alignment.topCenter, child: chart);
        return Semantics(
          image: true,
          label: description.toString(),
          child: child,
        );
      },
    );
  }
}

class _Painter extends CustomPainter {
  const _Painter(this.layout, this.dark, this.source, this.family);
  final MermaidFlowchartLayout layout;
  final bool dark;
  final String source;
  final String? family;
  Color get line => dark ? const Color(0xffd3d3d3) : const Color(0xff81858c);
  Color get fill => dark ? const Color(0xff1f2020) : const Color(0xffedf3fe);
  Color get border => dark ? const Color(0xffcccccc) : const Color(0xff4176e6);
  Color get ink => dark ? const Color(0xffcccccc) : const Color(0xff0f1115);

  @override
  void paint(Canvas c, Size size) {
    for (final item in layout.edges) {
      final p = Paint()
        ..color = line
        ..style = PaintingStyle.stroke
        ..strokeWidth = item.edge.lineStyle == MermaidFlowLineStyle.thick
            ? 3
            : 1;
      for (final metric in item.path.computeMetrics()) {
        final start = item.edge.startMarker == MermaidFlowMarker.circle
            ? 6.0
            : 0.0;
        final end =
            metric.length -
            (item.edge.endMarker == MermaidFlowMarker.circle ? 6 : 0);
        if (end <= start) continue;
        if (item.edge.lineStyle == MermaidFlowLineStyle.dotted) {
          for (double x = start; x < end; x += 8) {
            c.drawPath(metric.extractPath(x, math.min(x + 4, end)), p);
          }
        } else {
          c.drawPath(metric.extractPath(start, end), p);
        }
      }
      final m = item.path.computeMetrics().first;
      final endTangent = m.getTangentForOffset(m.length);
      if (endTangent != null) {
        _paintMarker(
          c,
          item.edge.endMarker,
          endTangent.position,
          endTangent.vector,
          p,
        );
      }
      final startTangent = m.getTangentForOffset(0);
      if (startTangent != null) {
        _paintMarker(
          c,
          item.edge.startMarker,
          startTangent.position,
          -startTangent.vector,
          p,
        );
      }
      if (item.edge.label.isNotEmpty) {
        final text = _text(item.edge.label, ink, family)..layout();
        final box = Rect.fromCenter(
          center: item.labelCenter,
          width: text.width,
          height: text.height,
        );
        c.drawRect(
          box,
          Paint()
            ..color = dark ? const Color(0xff535353) : const Color(0xfff1f3f5),
        );
        text.paint(
          c,
          Offset(
            box.center.dx - text.width / 2,
            box.center.dy - text.height / 2,
          ),
        );
      }
    }
    for (final item in layout.nodes) {
      final r = item.bounds,
          f = Paint()..color = item.node.style.fill ?? fill,
          s = Paint()
            ..color = item.node.style.strokeWidth == 0
                ? const Color(0x00000000)
                : item.node.style.stroke ?? border
            ..style = PaintingStyle.stroke
            ..strokeWidth = item.node.style.strokeWidth ?? 1;
      switch (item.node.shape) {
        case MermaidFlowNodeShape.rectangle:
          c.drawRect(r, f);
          c.drawRect(r, s);
          break;
        case MermaidFlowNodeShape.rounded:
          final rr = RRect.fromRectAndRadius(r, const Radius.circular(5));
          c.drawRRect(rr, f);
          c.drawRRect(rr, s);
          break;
        case MermaidFlowNodeShape.circle:
          c.drawOval(r, f);
          c.drawOval(r, s);
          break;
        case MermaidFlowNodeShape.diamond:
          final path = Path()
            ..moveTo(r.center.dx, r.top)
            ..lineTo(r.right, r.center.dy)
            ..lineTo(r.center.dx, r.bottom)
            ..lineTo(r.left, r.center.dy)
            ..close();
          c.drawPath(path, f);
          c.drawPath(path, s);
          break;
      }
      final text = _text(item.node.label, item.node.style.color ?? ink, family)
        ..layout();
      text.paint(
        c,
        Offset(r.center.dx - text.width / 2, r.center.dy - text.height / 2),
      );
    }
  }

  void _paintMarker(
    Canvas canvas,
    MermaidFlowMarker marker,
    Offset point,
    Offset direction,
    Paint stroke,
  ) {
    if (marker == MermaidFlowMarker.none || direction.distance == 0) return;
    final unit = direction / direction.distance;
    if (marker == MermaidFlowMarker.arrow) {
      final base = point - unit * 9;
      final normal = Offset(-unit.dy, unit.dx) * 4;
      canvas.drawPath(
        Path()
          ..moveTo(point.dx, point.dy)
          ..lineTo(base.dx + normal.dx, base.dy + normal.dy)
          ..lineTo(base.dx - normal.dx, base.dy - normal.dy)
          ..close(),
        Paint()..color = line,
      );
    } else if (marker == MermaidFlowMarker.circle) {
      canvas.drawCircle(
        point - unit * 3,
        3,
        Paint()
          ..color = line
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1,
      );
    } else if (marker == MermaidFlowMarker.cross) {
      final center = point - unit * 3;
      final normal = Offset(-unit.dy, unit.dx) * 3;
      canvas.drawLine(
        center - unit * 3 - normal,
        center + unit * 3 + normal,
        stroke,
      );
      canvas.drawLine(
        center - unit * 3 + normal,
        center + unit * 3 - normal,
        stroke,
      );
    }
  }

  @override
  bool shouldRepaint(_Painter old) =>
      source != old.source || dark != old.dark || family != old.family;
}

class _Cursor {
  _Cursor(this.s);
  final String s;
  int i = 0;
  bool get end => i >= s.length;
  void ws() {
    while (!end && s[i].trim().isEmpty) {
      i++;
    }
  }
}

class _Node {
  const _Node(this.id, this.label, this.shape, this.explicit);
  final String id, label;
  final MermaidFlowNodeShape shape;
  final bool explicit;
}

class _Link {
  const _Link(this.label, this.style, this.start, this.end);
  final String label;
  final MermaidFlowLineStyle style;
  final MermaidFlowMarker start, end;
}

List<String> _statements(String source) {
  final out = <String>[], b = StringBuffer(), stack = <String>[];
  var quote = false, escape = false, pipeLabel = false;
  void flush() {
    final s = b.toString().trim();
    if (s.isNotEmpty && !s.startsWith('%%')) out.add(s);
    b.clear();
  }

  for (var i = 0; i < source.length; i++) {
    final x = source[i], next = i + 1 < source.length ? source[i + 1] : '';
    if (escape) {
      b.write(x);
      escape = false;
      continue;
    }
    if (x == r'\') {
      b.write(x);
      escape = true;
      continue;
    }
    if (x == '"') {
      quote = !quote;
      b.write(x);
      continue;
    }
    if (!quote) {
      if (stack.isEmpty && !pipeLabel && x == '%' && next == '%') {
        if (RegExp(r'^%%\s*\{').hasMatch(source.substring(i))) {
          throw FormatException(tr("Mermaid directives are unsupported."));
        }
        while (i < source.length && source[i] != '\n') {
          i++;
        }
        flush();
        continue;
      }
      if (stack.isEmpty && x == '|') pipeLabel = !pipeLabel;
      if (!pipeLabel && (x == '[' || x == '{' || x == '(')) {
        stack.add(
          x == '['
              ? ']'
              : x == '{'
              ? '}'
              : ')',
        );
      } else if (stack.isNotEmpty && x == stack.last) {
        stack.removeLast();
      }
      if (stack.isEmpty && !pipeLabel && (x == '\n' || x == ';')) {
        flush();
        continue;
      }
    }
    b.write(x);
  }
  if (quote || pipeLabel || stack.isNotEmpty) {
    throw FormatException(tr("Unclosed Mermaid label."));
  }
  flush();
  return out;
}

_Node _node(_Cursor c) {
  c.ws();
  final start = c.i;
  while (!c.end && RegExp(r'[A-Za-z0-9_-]').hasMatch(c.s[c.i])) {
    if (c.s[c.i] == '-' &&
        c.i + 1 < c.s.length &&
        ['-', '.', '>'].contains(c.s[c.i + 1])) {
      break;
    }
    c.i++;
  }
  if (start == c.i) throw FormatException(tr("Expected a node ID."));
  final id = c.s.substring(start, c.i), endId = c.i;
  c.ws();
  var shape = MermaidFlowNodeShape.rectangle, label = id, explicit = false;
  if (!c.end && (c.s[c.i] == '[' || c.s[c.i] == '(' || c.s[c.i] == '{')) {
    explicit = true;
    if ([
      '[[',
      '[(',
      '[/',
      '[\\',
      '([',
      '{{',
      '(((',
    ].any((prefix) => c.s.startsWith(prefix, c.i))) {
      throw FormatException(
        tr("This Mermaid node shape is not yet supported natively."),
      );
    }
    final open = c.s[c.i],
        close = open == '['
            ? ']'
            : open == '{'
            ? '}'
            : ')';
    if (open == '(' && c.i + 1 < c.s.length && c.s[c.i + 1] == '(') {
      shape = MermaidFlowNodeShape.circle;
      c.i += 2;
      final begin = c.i;
      var nesting = 0;
      var closed = false;
      while (!c.end) {
        final x = c.s[c.i];
        if (x == '(') nesting++;
        if (x == ')' && nesting > 0) {
          nesting--;
        } else if (x == ')' && c.i + 1 < c.s.length && c.s[c.i + 1] == ')') {
          label = c.s.substring(begin, c.i);
          c.i += 2;
          closed = true;
          break;
        }
        c.i++;
      }
      if (!closed) throw FormatException(tr("Unclosed circle node."));
    } else {
      shape = open == '['
          ? MermaidFlowNodeShape.rectangle
          : open == '{'
          ? MermaidFlowNodeShape.diamond
          : MermaidFlowNodeShape.rounded;
      c.i++;
      final begin = c.i;
      var depth = 1, quoted = false, closed = false;
      while (!c.end) {
        final x = c.s[c.i];
        if (x == '"') quoted = !quoted;
        if (!quoted && x == open) depth++;
        if (!quoted && x == close) {
          depth--;
          if (depth == 0) {
            label = c.s.substring(begin, c.i);
            c.i++;
            closed = true;
            break;
          }
        }
        c.i++;
      }
      if (!closed) throw FormatException(tr("Unclosed node label."));
    }
    label = _plainLabel(label);
  } else {
    c.i = endId;
  }
  return _Node(id, label, shape, explicit);
}

_Link _edge(_Cursor c) {
  c.ws();
  const ops = [
    '<-->',
    'o--o',
    'x--x',
    'o--x',
    'x--o',
    'o-->',
    'x-->',
    '--o',
    '--x',
    '-->',
    '---',
    '--',
    '-.->',
    '-.-',
    '-.',
    '==>',
    '===',
    '==',
  ];
  String? op;
  for (final candidate in ops) {
    if (c.s.startsWith(candidate, c.i)) {
      op = candidate;
      break;
    }
  }
  if (op == null) {
    throw FormatException(tr("Unsupported Mermaid edge syntax."));
  }
  c.i += op.length;
  final style = op.startsWith('=')
      ? MermaidFlowLineStyle.thick
      : (op.contains('.')
            ? MermaidFlowLineStyle.dotted
            : MermaidFlowLineStyle.solid);
  var start = op.startsWith('<')
      ? MermaidFlowMarker.arrow
      : (op.startsWith('o')
            ? MermaidFlowMarker.circle
            : (op.startsWith('x')
                  ? MermaidFlowMarker.cross
                  : MermaidFlowMarker.none));
  var end = op.endsWith('>')
      ? MermaidFlowMarker.arrow
      : (op.endsWith('o')
            ? MermaidFlowMarker.circle
            : (op.endsWith('x')
                  ? MermaidFlowMarker.cross
                  : MermaidFlowMarker.none));
  var label = '';
  final legacy = RegExp(
    r'^\s+(.+?)\s+(-\.->|-->|==>|--o|--x|---|===|-\.-)(?=\s|[A-Za-z0-9_])',
  ).firstMatch(c.s.substring(c.i));
  if (['--', '==', '-.'].contains(op) && legacy != null) {
    label = legacy.group(1)!.trim();
    final suffix = legacy.group(2)!;
    end = suffix.endsWith('o')
        ? MermaidFlowMarker.circle
        : suffix.endsWith('x')
        ? MermaidFlowMarker.cross
        : suffix.endsWith('>')
        ? MermaidFlowMarker.arrow
        : MermaidFlowMarker.none;
    c.i += legacy.end;
  } else {
    if (['--', '==', '-.'].contains(op)) {
      throw FormatException(tr("Incomplete Mermaid edge operator."));
    }
    c.ws();
    if (!c.end && c.s[c.i] == '|') {
      final begin = ++c.i;
      var quoted = false, escaped = false;
      while (!c.end) {
        final ch = c.s[c.i];
        if (escaped) {
          escaped = false;
        } else if (ch == r'\') {
          escaped = true;
        } else if (ch == '"') {
          quoted = !quoted;
        } else if (ch == '|' && !quoted) {
          break;
        }
        c.i++;
      }
      if (c.end) throw FormatException(tr("Unclosed edge label."));
      label = c.s.substring(begin, c.i).trim();
      c.i++;
    }
  }
  if (start != end) start = MermaidFlowMarker.none;
  return _Link(_plainLabel(label), style, start, end);
}

String _plainLabel(String value) {
  var label = value.trim();
  if (label.length >= 2 && label.startsWith('"') && label.endsWith('"')) {
    label = label.substring(1, label.length - 1);
  }
  label = label.replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n');
  if (RegExp(r'<[^>]*>').hasMatch(label) ||
      label.contains(String.fromCharCode(96))) {
    throw FormatException(tr("Unsupported Mermaid label markup."));
  }
  // Mermaid's encode/decodeEntities preprocesses #name; and #decimal; before
  // inserting the label into HTML. Flutter keeps only the decoded text.
  label = label.replaceAllMapped(RegExp(r'#(\w+);'), (match) {
    final body = match[1]!;
    return '${RegExp(r'^\d+$').hasMatch(body) ? '&#' : '&'}$body;';
  });
  return html
          .parseFragment(label.replaceAll('<', '&lt;').replaceAll('>', '&gt;'))
          .text ??
      '';
}

Size _measure(MermaidFlowNode node, String? family) {
  final p = _text(node.label, Colors.black, family)..layout();
  var w = p.width + 60, h = p.height + 30;
  if (node.shape == MermaidFlowNodeShape.circle) {
    w = h = math.max(p.width, p.height) + 30;
  }
  if (node.shape == MermaidFlowNodeShape.diamond) {
    w = h = p.width + p.height + 30;
  }
  p.dispose();
  return Size(w, h);
}

TextPainter _text(String t, Color color, String? family) => TextPainter(
  text: TextSpan(
    text: t,
    style: TextStyle(
      fontFamily: family,
      fontSize: 13,
      height: 1.5,
      letterSpacing: 0,
      color: color,
    ),
  ),
  textDirection: TextDirection.ltr,
  textAlign: TextAlign.center,
);
List<List<String>> _scc(List<String> nodes, Map<String, List<String>> adj) {
  var index = 0;
  final ix = <String, int>{},
      low = <String, int>{},
      stack = <String>[],
      on = <String>{},
      out = <List<String>>[];
  void visit(String id) {
    ix[id] = index;
    low[id] = index;
    index++;
    stack.add(id);
    on.add(id);
    for (final n in adj[id]!) {
      if (!ix.containsKey(n)) {
        visit(n);
        low[id] = math.min(low[id]!, low[n]!).toInt();
      } else if (on.contains(n)) {
        low[id] = math.min(low[id]!, ix[n]!).toInt();
      }
    }
    if (low[id] == ix[id]) {
      final component = <String>[];
      late String n;
      do {
        n = stack.removeLast();
        on.remove(n);
        component.add(n);
      } while (n != id);
      out.add(component);
    }
  }

  for (final n in nodes) {
    if (!ix.containsKey(n)) visit(n);
  }
  return out;
}

Offset _bendPoint(Rect a, Rect b, bool vertical, String direction) {
  final reverse = direction == 'BT' || direction == 'RL';
  if (vertical) {
    return Offset(
      b.center.dx,
      reverse ? (a.top + b.bottom) / 2 : (a.bottom + b.top) / 2,
    );
  }
  return Offset(
    reverse ? (a.left + b.right) / 2 : (a.right + b.left) / 2,
    b.center.dy,
  );
}

Path _forwardPath(
  Rect a,
  Rect b,
  bool vertical,
  String direction,
  MermaidFlowNodeShape sa,
  MermaidFlowNodeShape sb,
) {
  final middle = _bendPoint(a, b, vertical, direction);
  final p = _intersection(a, sa, middle - a.center);
  final q = _intersection(b, sb, middle - b.center);
  // d3 curveBasis for the three-point route, with a rank-aligned approach.
  final start = (p * 5 + middle) / 6;
  final firstEnd = (p + middle * 4 + q) / 6;
  final end = (middle + q * 5) / 6;
  final c1 = (p * 2 + middle) / 3;
  final c2 = (p + middle * 2) / 3;
  final c3 = (middle * 2 + q) / 3;
  final c4 = (middle + q * 2) / 3;
  return Path()
    ..moveTo(p.dx, p.dy)
    ..lineTo(start.dx, start.dy)
    ..cubicTo(c1.dx, c1.dy, c2.dx, c2.dy, firstEnd.dx, firstEnd.dy)
    ..cubicTo(c3.dx, c3.dy, c4.dx, c4.dy, end.dx, end.dy)
    ..lineTo(q.dx, q.dy);
}

Path _backPath(Rect a, Rect b, bool vertical, double track, bool leading) {
  final p = Path();
  if (vertical) {
    final x = leading ? track : a.right + 8,
        s = Offset(leading ? a.left : a.right, a.center.dy),
        e = Offset(leading ? b.left : b.right, b.center.dy);
    return p
      ..moveTo(s.dx, s.dy)
      ..lineTo(x, s.dy)
      ..lineTo(x, e.dy)
      ..lineTo(e.dx, e.dy);
  }
  final y = leading ? track : a.bottom + 8,
      s = Offset(a.center.dx, leading ? a.top : a.bottom),
      e = Offset(b.center.dx, leading ? b.top : b.bottom);
  return p
    ..moveTo(s.dx, s.dy)
    ..lineTo(s.dx, y)
    ..lineTo(e.dx, y)
    ..lineTo(e.dx, e.dy);
}

Offset _intersection(Rect r, MermaidFlowNodeShape shape, Offset v) {
  final dx = v.dx == 0 && v.dy == 0 ? 1.0 : v.dx,
      dy = v.dx == 0 && v.dy == 0 ? 0.0 : v.dy;
  final scale = switch (shape) {
    MermaidFlowNodeShape.circle => (r.width / 2) / math.sqrt(dx * dx + dy * dy),
    MermaidFlowNodeShape.diamond =>
      1 / (dx.abs() / (r.width / 2) + dy.abs() / (r.height / 2)),
    _ =>
      math
          .min(
            dx == 0 ? double.infinity : r.width / 2 / dx.abs(),
            dy == 0 ? double.infinity : r.height / 2 / dy.abs(),
          )
          .toDouble(),
  };
  return r.center + Offset(dx * scale, dy * scale);
}
