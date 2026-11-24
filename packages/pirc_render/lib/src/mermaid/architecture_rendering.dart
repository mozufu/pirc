import '../render_l10n.dart';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'architecture_model.dart';

const _architectureIconSize = 80.0;
const _architecturePadding = 40.0;
const _architectureGridStep = 200.0;

class NativeMermaidArchitectureNodeLayout {
  const NativeMermaidArchitectureNodeLayout({
    required this.id,
    required this.service,
    required this.junction,
    required this.center,
    required this.iconBounds,
    required this.bounds,
    required this.labelBounds,
    required this.labelPainter,
  });

  final String id;
  final NativeMermaidArchitectureService? service;
  final NativeMermaidArchitectureJunction? junction;
  final Offset center;
  final Rect iconBounds;
  final Rect bounds;
  final Rect? labelBounds;
  final TextPainter? labelPainter;
  bool get isJunction => junction != null;
  String? get title => service?.title;
  String? get parentId => service?.parentId ?? junction?.parentId;
  NativeMermaidArchitectureIcon? get icon => service?.icon;
}

class NativeMermaidArchitectureGroupLayout {
  const NativeMermaidArchitectureGroupLayout({
    required this.group,
    required this.bounds,
    required this.iconBounds,
    required this.titleBounds,
    required this.titlePainter,
    required this.depth,
  });

  final NativeMermaidArchitectureGroup group;
  final Rect bounds;
  final Rect? iconBounds;
  final Rect? titleBounds;
  final TextPainter? titlePainter;
  final int depth;
  String get id => group.id;
}

class NativeMermaidArchitectureEdgeLayout {
  const NativeMermaidArchitectureEdgeLayout({
    required this.edge,
    required this.path,
    required this.points,
    required this.start,
    required this.end,
    required this.labelPainter,
    required this.labelCenter,
  });

  final NativeMermaidArchitectureEdge edge;
  final Path path;
  final List<Offset> points;
  final Offset start;
  final Offset end;
  final TextPainter? labelPainter;
  final Offset labelCenter;
  String get sourceId => edge.sourceId;
  String get targetId => edge.targetId;
  bool get sourceInto => edge.sourceInto;
  bool get targetInto => edge.targetInto;
}

class NativeMermaidArchitectureLayout {
  const NativeMermaidArchitectureLayout({
    required this.nodes,
    required this.groups,
    required this.edges,
    required this.viewBox,
    required this.size,
    required this.scale,
  });

  final List<NativeMermaidArchitectureNodeLayout> nodes;
  final List<NativeMermaidArchitectureGroupLayout> groups;
  final List<NativeMermaidArchitectureEdgeLayout> edges;
  final Rect viewBox;
  final Size size;
  final double scale;

  NativeMermaidArchitectureNodeLayout? nodeById(String id) {
    for (final node in nodes) {
      if (node.id == id) return node;
    }
    return null;
  }

  NativeMermaidArchitectureGroupLayout? groupById(String id) {
    for (final group in groups) {
      if (group.id == id) return group;
    }
    return null;
  }
}

/// Computes a deterministic directional layout, then sizes every group from
/// its actual descendants. Grid constraints use Mermaid's pinned port-pair
/// rules; the final canvas flips its Y axis back to screen coordinates.
NativeMermaidArchitectureLayout layoutNativeMermaidArchitecture(
  NativeMermaidArchitectureDiagram diagram, {
  required double width,
  required bool dark,
  String? fontFamily,
}) {
  if (!width.isFinite || width <= 0) {
    throw FormatException(tr("Architecture viewport width must be positive"));
  }

  final textColor = dark ? const Color(0xffcccccc) : const Color(0xff0f1115);
  final groupTitleStyle = TextStyle(
    fontFamily: fontFamily,
    fontSize: 13,
    height: 1.25,
    color: textColor,
  );
  final serviceTitleStyle = TextStyle(
    fontFamily: fontFamily,
    fontSize: 13,
    height: 1.25,
    color: textColor,
  );
  TextPainter? measure(
    String? value,
    TextStyle style, {
    double maxWidth = 220,
  }) {
    if (value == null || value.isEmpty) return null;
    final painter = TextPainter(
      text: TextSpan(text: value, style: style),
      textDirection: TextDirection.ltr,
      textAlign: TextAlign.center,
    )..layout(maxWidth: maxWidth);
    return painter;
  }

  final rawNodes =
      <
        String,
        ({
          NativeMermaidArchitectureService? service,
          NativeMermaidArchitectureJunction? junction,
          TextPainter? title,
        })
      >{};
  var widestLabel = 80.0;
  var tallestLabel = 0.0;
  for (final service in diagram.services) {
    final label = measure(service.title, serviceTitleStyle);
    if (label != null) {
      widestLabel = math.max(widestLabel, label.width).toDouble();
      tallestLabel = math.max(tallestLabel, label.height).toDouble();
    }
    rawNodes[service.id] = (service: service, junction: null, title: label);
  }
  for (final junction in diagram.junctions) {
    rawNodes[junction.id] = (service: null, junction: junction, title: null);
  }
  if (rawNodes.length > 200 || diagram.groups.length > 200) {
    throw FormatException(
      tr("Architecture diagram exceeds the native layout limit"),
    );
  }
  final gridX = math.max(_architectureGridStep, widestLabel + 100).toDouble();
  final gridY = math
      .max(_architectureGridStep, _architectureIconSize + tallestLabel + 70)
      .toDouble();
  final gridPositions = _directionalGridPositions(diagram);
  final centers = <String, Offset>{};
  for (final node in rawNodes.keys) {
    final point = gridPositions[node] ?? Offset.zero;
    centers[node] = Offset(point.dx * gridX, -point.dy * gridY);
  }
  _separateCollidingNodes(centers, gridX, gridY);

  final nodes = <NativeMermaidArchitectureNodeLayout>[];
  final nodesById = <String, NativeMermaidArchitectureNodeLayout>{};
  for (final entry in rawNodes.entries) {
    final center = centers[entry.key]!;
    final iconSize = entry.value.junction == null
        ? _architectureIconSize
        : 10.0;
    final iconRect = Rect.fromCenter(
      center: center,
      width: iconSize,
      height: iconSize,
    );
    final title = entry.value.title;
    Rect? labelBounds;
    var bounds = iconRect;
    if (title != null) {
      labelBounds = Rect.fromLTWH(
        center.dx - title.width / 2,
        iconRect.bottom + 1,
        title.width,
        title.height,
      );
      bounds = bounds.expandToInclude(labelBounds);
    }
    final layout = NativeMermaidArchitectureNodeLayout(
      id: entry.key,
      service: entry.value.service,
      junction: entry.value.junction,
      center: center,
      iconBounds: iconRect,
      bounds: bounds,
      labelBounds: labelBounds,
      labelPainter: title,
    );
    nodes.add(layout);
    nodesById[entry.key] = layout;
  }

  final groupModels = {for (final group in diagram.groups) group.id: group};
  final childNodes = <String, List<String>>{
    for (final group in diagram.groups) group.id: <String>[],
  };
  for (final node in nodes) {
    if (node.parentId != null) childNodes[node.parentId]!.add(node.id);
  }
  for (final group in diagram.groups) {
    if (group.parentId != null) childNodes[group.parentId]!.add(group.id);
  }
  final groupBoundsById = <String, Rect>{};
  final groupDepthById = <String, int>{};
  final visiting = <String>{};
  Rect boundsForGroup(String id) {
    final cached = groupBoundsById[id];
    if (cached != null) return cached;
    if (!visiting.add(id)) {
      throw FormatException(
        tr("Architecture group membership cycle includes \"{0}\"", [id]),
      );
    }
    final members = childNodes[id] ?? const <String>[];
    Rect? content;
    for (final member in members) {
      final node = nodesById[member];
      final candidate =
          node?.bounds ??
          (groupModels.containsKey(member) ? boundsForGroup(member) : null);
      if (candidate != null) {
        content = content == null
            ? candidate
            : content.expandToInclude(candidate);
      }
    }
    final group = groupModels[id]!;
    if (content == null) {
      final emptyIndex = groupModels.keys.toList().indexOf(id);
      final center = Offset((emptyIndex + 1) * gridX, 0);
      content = Rect.fromCenter(center: center, width: 0, height: 0);
    }
    final depth = group.parentId == null
        ? 0
        : (groupDepthById[group.parentId!] ?? 0) + 1;
    groupDepthById[id] = depth;
    final titlePainter = measure(group.title, groupTitleStyle, maxWidth: 260);
    final iconSize = group.icon == null ? 0.0 : 30.0;
    final headerWidth = iconSize + (titlePainter?.width ?? 0) + 24;
    final headerHeight = math
        .max(38.0, math.max(iconSize, titlePainter?.height ?? 0) + 16)
        .toDouble();
    final boxWidth = math
        .max(content.width + _architecturePadding * 2, headerWidth)
        .toDouble();
    final left = content.center.dx - boxWidth / 2;
    final top = content.top - _architecturePadding - headerHeight;
    final box = Rect.fromLTWH(
      left,
      top,
      boxWidth,
      content.height + _architecturePadding * 2 + headerHeight,
    );
    groupBoundsById[id] = box;
    visiting.remove(id);
    return box;
  }

  for (final group in diagram.groups) {
    boundsForGroup(group.id);
  }

  final groupLayouts = <NativeMermaidArchitectureGroupLayout>[];
  for (final group in diagram.groups) {
    final bounds = groupBoundsById[group.id]!;
    final title = measure(group.title, groupTitleStyle, maxWidth: 260);
    final hasIcon = group.icon != null;
    final iconBounds = hasIcon
        ? Rect.fromLTWH(bounds.left + 10, bounds.top + 8, 30, 30)
        : null;
    final titleBounds = title == null
        ? null
        : Rect.fromLTWH(
            bounds.left + (hasIcon ? 44 : 12),
            bounds.top + 11,
            title.width,
            title.height,
          );
    groupLayouts.add(
      NativeMermaidArchitectureGroupLayout(
        group: group,
        bounds: bounds,
        iconBounds: iconBounds,
        titleBounds: titleBounds,
        titlePainter: title,
        depth: groupDepthById[group.id] ?? 0,
      ),
    );
  }
  groupLayouts.sort((a, b) => a.depth.compareTo(b.depth));
  final groupLayoutById = {for (final group in groupLayouts) group.id: group};

  final edgeLayouts = <NativeMermaidArchitectureEdgeLayout>[];
  for (final edge in diagram.edges) {
    final source = nodesById[edge.sourceId];
    final target = nodesById[edge.targetId];
    if (source == null || target == null) {
      throw FormatException(
        'Architecture edge ${edge.sourceId} -> ${edge.targetId} refers to a missing node',
      );
    }
    final sourceGroupId = source.parentId;
    final targetGroupId = target.parentId;
    final start = edge.sourceGroup && sourceGroupId != null
        ? _groupPort(
            groupLayoutById[sourceGroupId]!.bounds,
            edge.sourceDirection,
          )
        : _nodePort(source.iconBounds, edge.sourceDirection);
    final end = edge.targetGroup && targetGroupId != null
        ? _groupPort(
            groupLayoutById[targetGroupId]!.bounds,
            edge.targetDirection,
          )
        : _nodePort(target.iconBounds, edge.targetDirection);
    final points = _edgePoints(
      start,
      end,
      edge.sourceDirection,
      edge.targetDirection,
    );
    final path = Path()..moveTo(points.first.dx, points.first.dy);
    for (final point in points.skip(1)) {
      path.lineTo(point.dx, point.dy);
    }
    final edgeLabel = measure(edge.title, serviceTitleStyle, maxWidth: 180);
    final labelCenter = points.length == 2 ? (start + end) / 2 : points[1];
    edgeLayouts.add(
      NativeMermaidArchitectureEdgeLayout(
        edge: edge,
        path: path,
        points: List.unmodifiable(points),
        start: start,
        end: end,
        labelPainter: edgeLabel,
        labelCenter: labelCenter,
      ),
    );
  }

  Rect? allBounds;
  void include(Rect value) {
    allBounds = allBounds == null ? value : allBounds!.expandToInclude(value);
  }

  for (final node in nodes) {
    include(node.bounds);
  }
  for (final group in groupLayouts) {
    include(group.bounds);
  }
  for (final edge in edgeLayouts) {
    include(
      edge.path.getBounds().inflate(
        edge.edge.sourceInto || edge.edge.targetInto ? 8 : 2,
      ),
    );
    if (edge.labelPainter != null) {
      include(
        Rect.fromCenter(
          center: edge.labelCenter,
          width: edge.labelPainter!.width,
          height: edge.labelPainter!.height,
        ),
      );
    }
  }
  final viewBox = (allBounds ?? Rect.fromLTWH(0, 0, 80, 80)).inflate(14);
  final scale = math.min(1.0, width / viewBox.width).toDouble();
  return NativeMermaidArchitectureLayout(
    nodes: List.unmodifiable(nodes),
    groups: List.unmodifiable(groupLayouts),
    edges: List.unmodifiable(edgeLayouts),
    viewBox: viewBox,
    size: Size(viewBox.width * scale, viewBox.height * scale),
    scale: scale,
  );
}

Map<String, Offset> _directionalGridPositions(
  NativeMermaidArchitectureDiagram diagram,
) {
  final ids = diagram.nodeIds.toList();
  final adjacency = <String, List<(String id, Offset delta)>>{
    for (final id in ids) id: <(String, Offset)>[],
  };
  for (final edge in diagram.edges) {
    final forward = _mermaidPortPairDelta(
      edge.sourceDirection,
      edge.targetDirection,
    );
    if (forward == null) continue;
    adjacency[edge.sourceId]!.add((edge.targetId, forward));
    adjacency[edge.targetId]!.add((edge.sourceId, -forward));
  }
  final positions = <String, Offset>{};
  var componentOffset = 0.0;
  for (final id in ids) {
    if (positions.containsKey(id)) continue;
    final component = <String>[];
    final queue = <String>[id];
    positions[id] = Offset(componentOffset, 0);
    for (var cursor = 0; cursor < queue.length; cursor++) {
      final current = queue[cursor];
      component.add(current);
      final currentPosition = positions[current]!;
      for (final (neighbor, delta) in adjacency[current]!) {
        if (positions.containsKey(neighbor)) continue;
        positions[neighbor] = currentPosition + delta;
        queue.add(neighbor);
      }
    }
    final maxX = component
        .map((node) => positions[node]!.dx)
        .reduce((left, right) => math.max(left, right).toDouble());
    componentOffset = maxX + 3;
  }

  for (final alignment in diagram.alignments) {
    final members = alignment.members;
    final first = positions[members.first]!;
    for (var i = 0; i < members.length; i++) {
      positions[members[i]] = alignment.direction == 'row'
          ? Offset(first.dx + i, first.dy)
          : Offset(first.dx, first.dy - i);
    }
  }
  return positions;
}

Offset? _mermaidPortPairDelta(
  NativeMermaidArchitectureDirection left,
  NativeMermaidArchitectureDirection right,
) {
  bool horizontal(NativeMermaidArchitectureDirection side) =>
      side == NativeMermaidArchitectureDirection.left ||
      side == NativeMermaidArchitectureDirection.right;
  final pair = '${_sideCode(left)}${_sideCode(right)}';
  if (pair == 'LL' || pair == 'RR' || pair == 'TT' || pair == 'BB') return null;
  var dx = 0.0, dy = 0.0;
  if (horizontal(left)) {
    dx = left == NativeMermaidArchitectureDirection.left ? -1 : 1;
    if (!horizontal(right)) {
      dy = right == NativeMermaidArchitectureDirection.top ? 1 : -1;
    }
  } else {
    if (horizontal(right)) {
      dx = right == NativeMermaidArchitectureDirection.left ? 1 : -1;
    }
    dy = left == NativeMermaidArchitectureDirection.top ? 1 : -1;
  }
  return Offset(dx, dy);
}

String _sideCode(NativeMermaidArchitectureDirection side) => switch (side) {
  NativeMermaidArchitectureDirection.left => 'L',
  NativeMermaidArchitectureDirection.right => 'R',
  NativeMermaidArchitectureDirection.top => 'T',
  NativeMermaidArchitectureDirection.bottom => 'B',
};

void _separateCollidingNodes(
  Map<String, Offset> centers,
  double gridX,
  double gridY,
) {
  final occupied = <String, int>{};
  for (final entry in centers.entries.toList()) {
    final cell =
        '${(entry.value.dx / gridX).round()},${(entry.value.dy / gridY).round()}';
    final slot = occupied[cell] ?? 0;
    occupied[cell] = slot + 1;
    if (slot > 0) {
      centers[entry.key] =
          entry.value + Offset(gridX * .55 * slot, gridY * .55 * slot);
    }
  }
}

Offset _nodePort(
  Rect rect,
  NativeMermaidArchitectureDirection side,
) => switch (side) {
  NativeMermaidArchitectureDirection.left => Offset(rect.left, rect.center.dy),
  NativeMermaidArchitectureDirection.right => Offset(
    rect.right,
    rect.center.dy,
  ),
  NativeMermaidArchitectureDirection.top => Offset(rect.center.dx, rect.top),
  NativeMermaidArchitectureDirection.bottom => Offset(
    rect.center.dx,
    rect.bottom,
  ),
};

Offset _groupPort(Rect rect, NativeMermaidArchitectureDirection side) {
  final extension = 2.0;
  return switch (side) {
    NativeMermaidArchitectureDirection.left => Offset(
      rect.left - extension,
      rect.center.dy,
    ),
    NativeMermaidArchitectureDirection.right => Offset(
      rect.right + extension,
      rect.center.dy,
    ),
    NativeMermaidArchitectureDirection.top => Offset(
      rect.center.dx,
      rect.top - extension,
    ),
    NativeMermaidArchitectureDirection.bottom => Offset(
      rect.center.dx,
      rect.bottom + extension,
    ),
  };
}

List<Offset> _edgePoints(
  Offset start,
  Offset end,
  NativeMermaidArchitectureDirection sourceSide,
  NativeMermaidArchitectureDirection targetSide,
) {
  final sourceHorizontal =
      sourceSide == NativeMermaidArchitectureDirection.left ||
      sourceSide == NativeMermaidArchitectureDirection.right;
  final targetHorizontal =
      targetSide == NativeMermaidArchitectureDirection.left ||
      targetSide == NativeMermaidArchitectureDirection.right;
  if (sourceHorizontal == targetHorizontal) return [start, end];
  final corner = sourceHorizontal
      ? Offset(end.dx, start.dy)
      : Offset(start.dx, end.dy);
  return [start, corner, end];
}

class NativeMermaidArchitecture extends StatelessWidget {
  const NativeMermaidArchitecture({
    super.key,
    required this.diagram,
    required this.dark,
    this.fontFamily,
  });

  final NativeMermaidArchitectureDiagram diagram;
  final bool dark;
  final String? fontFamily;

  @override
  Widget build(BuildContext context) {
    RenderL10n.watch(context);
    final summary = [
      if (diagram.title.isNotEmpty) diagram.title,
      for (final group in diagram.groups)
        'Group ${group.id}${group.title == null ? '' : ': ${group.title}'}',
      for (final service in diagram.services)
        'Service ${service.id}${service.title == null ? '' : ': ${service.title}'}${service.parentId == null ? '' : ' in ${service.parentId}'}',
      for (final junction in diagram.junctions)
        'Junction ${junction.id}${junction.parentId == null ? '' : ' in ${junction.parentId}'}',
      for (final edge in diagram.edges)
        '${edge.sourceId} ${_sideCode(edge.sourceDirection)} to ${edge.targetId} ${_sideCode(edge.targetDirection)}${edge.title == null ? '' : ': ${edge.title}'}',
    ].join('. ');
    return Semantics(
      image: true,
      label: summary,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final availableWidth = constraints.hasBoundedWidth
              ? constraints.maxWidth
              : MediaQuery.sizeOf(context).width;
          final layout = layoutNativeMermaidArchitecture(
            diagram,
            width: availableWidth,
            dark: dark,
            fontFamily:
                fontFamily ??
                Theme.of(context).textTheme.bodyMedium?.fontFamily,
          );
          return Align(
            alignment: Alignment.topCenter,
            child: SizedBox(
              key: const ValueKey('native-mermaid-architecture-chart'),
              width: layout.size.width,
              height: layout.size.height,
              child: CustomPaint(
                size: layout.size,
                painter: NativeMermaidArchitecturePainter(layout, dark: dark),
              ),
            ),
          );
        },
      ),
    );
  }
}

class NativeMermaidArchitecturePainter extends CustomPainter {
  const NativeMermaidArchitecturePainter(this.layout, {required this.dark});

  final NativeMermaidArchitectureLayout layout;
  final bool dark;

  Color get _groupColor =>
      dark ? const Color(0xffcccccc) : const Color(0xff000000);
  Color get _edgeColor =>
      dark ? const Color(0xffd3d3d3) : const Color(0xff777777);

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(layout.scale);
    canvas.translate(-layout.viewBox.left, -layout.viewBox.top);

    for (final group in layout.groups) {
      _drawGroup(canvas, group);
    }
    for (final edge in layout.edges) {
      _drawEdge(canvas, edge);
    }
    for (final node in layout.nodes) {
      _drawNode(canvas, node);
    }

    canvas.restore();
  }

  void _drawGroup(Canvas canvas, NativeMermaidArchitectureGroupLayout group) {
    _drawDashedRect(
      canvas,
      group.bounds,
      Paint()
        ..color = _groupColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );
    if (group.iconBounds != null && group.group.icon != null) {
      canvas.save();
      canvas.translate(group.iconBounds!.left, group.iconBounds!.top);
      canvas.scale(group.iconBounds!.width / 80);
      _drawArchitectureIcon(canvas, group.group.icon!);
      canvas.restore();
    }
    if (group.titleBounds != null && group.titlePainter != null) {
      group.titlePainter!.paint(
        canvas,
        Offset(group.titleBounds!.left, group.titleBounds!.top),
      );
    }
  }

  void _drawEdge(Canvas canvas, NativeMermaidArchitectureEdgeLayout edge) {
    canvas.drawPath(
      edge.path,
      Paint()
        ..color = _edgeColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.6
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );
    if (edge.sourceInto) {
      _drawArrow(canvas, _firstDistinctPoint(edge.points), edge.start, 13.333);
    }
    if (edge.targetInto) {
      _drawArrow(canvas, _lastDistinctPoint(edge.points), edge.end, 13.333);
    }
    final label = edge.labelPainter;
    if (label != null) {
      final rect = Rect.fromCenter(
        center: edge.labelCenter,
        width: label.width + 8,
        height: label.height + 4,
      );
      canvas.drawRRect(
        RRect.fromRectAndRadius(rect, const Radius.circular(3)),
        Paint()
          ..color = dark ? const Color(0xff202127) : const Color(0xfffafafa),
      );
      label.paint(
        canvas,
        edge.labelCenter - Offset(label.width / 2, label.height / 2),
      );
    }
  }

  Offset _firstDistinctPoint(List<Offset> points) {
    for (final point in points.skip(1)) {
      if (point != points.first) return point;
    }
    return points.first;
  }

  Offset _lastDistinctPoint(List<Offset> points) {
    for (final point in points.reversed.skip(1)) {
      if (point != points.last) return point;
    }
    return points.last;
  }

  void _drawArrow(Canvas canvas, Offset toward, Offset endpoint, double size) {
    final vector = endpoint - toward;
    final distance = vector.distance;
    if (distance < 0.001) return;
    final direction = vector / distance;
    final normal = Offset(-direction.dy, direction.dx);
    final tip = endpoint - direction * 1.5;
    final base = tip - direction * size;
    final triangle = Path()
      ..moveTo(tip.dx, tip.dy)
      ..lineTo(
        base.dx + normal.dx * size * .48,
        base.dy + normal.dy * size * .48,
      )
      ..lineTo(
        base.dx - normal.dx * size * .48,
        base.dy - normal.dy * size * .48,
      )
      ..close();
    canvas.drawPath(triangle, Paint()..color = _edgeColor);
  }

  void _drawNode(Canvas canvas, NativeMermaidArchitectureNodeLayout node) {
    if (node.isJunction) {
      canvas.drawCircle(
        node.center,
        5,
        Paint()..color = const Color(0xff087ebf),
      );
      canvas.drawCircle(
        node.center,
        5,
        Paint()
          ..color = const Color(0xffffffff)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5,
      );
      return;
    }
    final icon = node.icon;
    if (icon == null) {
      final rect = node.iconBounds;
      final path = Path()
        ..moveTo(rect.left, rect.bottom)
        ..lineTo(rect.left, rect.top + 5)
        ..quadraticBezierTo(rect.left, rect.top, rect.left + 5, rect.top)
        ..lineTo(rect.right - 5, rect.top)
        ..quadraticBezierTo(rect.right, rect.top, rect.right, rect.top + 5)
        ..lineTo(rect.right, rect.bottom)
        ..close();
      canvas.drawPath(
        path,
        Paint()
          ..color = const Color(0xffedf3fe)
          ..style = PaintingStyle.fill,
      );
      canvas.drawPath(
        path,
        Paint()
          ..color = const Color(0xff4176e6)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2,
      );
    } else {
      canvas.save();
      canvas.translate(node.iconBounds.left, node.iconBounds.top);
      _drawArchitectureIcon(canvas, icon);
      canvas.restore();
    }
    if (node.labelBounds != null && node.labelPainter != null) {
      node.labelPainter!.paint(
        canvas,
        Offset(node.labelBounds!.left, node.labelBounds!.top),
      );
    }
  }

  void _drawArchitectureIcon(
    Canvas canvas,
    NativeMermaidArchitectureIcon icon,
  ) {
    final blue = Paint()..color = const Color(0xff087ebf);
    final whiteStroke = Paint()
      ..color = const Color(0xffffffff)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final whiteFill = Paint()..color = const Color(0xffffffff);
    canvas.drawRect(const Rect.fromLTWH(0, 0, 80, 80), blue);
    switch (icon) {
      case NativeMermaidArchitectureIcon.cloud:
        final path = Path()
          ..moveTo(20, 52)
          ..cubicTo(15, 52, 13, 48, 14, 44)
          ..cubicTo(15, 40, 18, 38, 22, 38)
          ..cubicTo(24, 31, 31, 28, 37, 30)
          ..cubicTo(44, 22, 59, 26, 60, 39)
          ..cubicTo(68, 40, 69, 51, 60, 53)
          ..lineTo(20, 53)
          ..close();
        canvas.drawPath(path, whiteStroke);
        break;
      case NativeMermaidArchitectureIcon.database:
        final body = Path()
          ..moveTo(20, 22)
          ..lineTo(20, 58)
          ..moveTo(60, 22)
          ..lineTo(60, 58);
        canvas.drawPath(body, whiteStroke);
        for (final y in [22.0, 34.0, 46.0, 58.0]) {
          canvas.drawOval(
            Rect.fromCenter(center: Offset(40, y), width: 40, height: 14),
            whiteStroke,
          );
        }
        break;
      case NativeMermaidArchitectureIcon.disk:
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            const Rect.fromLTWH(20, 15, 40, 50),
            const Radius.circular(2),
          ),
          whiteStroke,
        );
        canvas.drawOval(const Rect.fromLTWH(26, 19, 28, 29), whiteStroke);
        canvas.drawCircle(const Offset(40, 33.5), 4, whiteFill);
        final arm = Path()
          ..moveTo(37, 43)
          ..lineTo(30, 55)
          ..lineTo(35, 58)
          ..lineTo(40, 44);
        canvas.drawPath(arm, whiteStroke);
        for (final dot in const [
          Offset(24, 19),
          Offset(56, 19),
          Offset(24, 61),
          Offset(56, 61),
        ]) {
          canvas.drawCircle(dot, 1, whiteFill);
        }
        break;
      case NativeMermaidArchitectureIcon.internet:
        canvas.drawCircle(const Offset(40, 40), 22.5, whiteStroke);
        canvas.drawLine(
          const Offset(40, 17.5),
          const Offset(40, 62.5),
          whiteStroke,
        );
        canvas.drawLine(
          const Offset(17.5, 40),
          const Offset(62.5, 40),
          whiteStroke,
        );
        final leftLongitude = Path()
          ..moveTo(40, 17.5)
          ..cubicTo(25, 27, 25, 53, 40, 62.5);
        final rightLongitude = Path()
          ..moveTo(40, 17.5)
          ..cubicTo(55, 27, 55, 53, 40, 62.5);
        canvas.drawPath(leftLongitude, whiteStroke);
        canvas.drawPath(rightLongitude, whiteStroke);
        canvas.drawLine(
          const Offset(20, 30),
          const Offset(60, 30),
          whiteStroke,
        );
        canvas.drawLine(
          const Offset(20, 50),
          const Offset(60, 50),
          whiteStroke,
        );
        break;
      case NativeMermaidArchitectureIcon.server:
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            const Rect.fromLTWH(17.5, 17.5, 45, 45),
            const Radius.circular(2),
          ),
          whiteStroke,
        );
        for (final y in [32.5, 47.5]) {
          canvas.drawLine(Offset(17.5, y), Offset(62.5, y), whiteStroke);
        }
        for (final y in [25.0, 40.0, 55.0]) {
          for (final x in [22.5, 27.5, 32.5]) {
            canvas.drawCircle(Offset(x, y), .75, whiteFill);
          }
          canvas.drawLine(Offset(44.5, y), Offset(55.75, y), whiteStroke);
        }
        break;
    }
  }

  void _drawDashedRect(Canvas canvas, Rect rect, Paint paint) {
    const dash = 8.0, gap = 5.0;
    _drawDashedLine(canvas, rect.topLeft, rect.topRight, paint, dash, gap);
    _drawDashedLine(canvas, rect.topRight, rect.bottomRight, paint, dash, gap);
    _drawDashedLine(
      canvas,
      rect.bottomRight,
      rect.bottomLeft,
      paint,
      dash,
      gap,
    );
    _drawDashedLine(canvas, rect.bottomLeft, rect.topLeft, paint, dash, gap);
  }

  void _drawDashedLine(
    Canvas canvas,
    Offset start,
    Offset end,
    Paint paint,
    double dash,
    double gap,
  ) {
    final vector = end - start;
    final length = vector.distance;
    if (length <= 0) return;
    final direction = vector / length;
    var cursor = 0.0;
    while (cursor < length) {
      final next = math.min(cursor + dash, length).toDouble();
      canvas.drawLine(
        start + direction * cursor,
        start + direction * next,
        paint,
      );
      cursor = next + gap;
    }
  }

  @override
  bool shouldRepaint(covariant NativeMermaidArchitecturePainter oldDelegate) =>
      oldDelegate.layout != layout || oldDelegate.dark != dark;
}
