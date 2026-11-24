import '../render_l10n.dart';
// D3 Sankey breadth/relaxation logic adapted from d3-sankey 0.12.3.
// Copyright 2015 Mike Bostock; BSD-3-Clause, see D3_SANKEY_LICENSE.txt.
import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'sankey_model.dart';

const double _extentWidth = 600;
const double _extentHeight = 400;
const double _nodeWidth = 10;
const double _nodePadding = 27; // 12px plus 15px reserved for displayed values.
const int _iterations = 6;

class NativeSankeyNodeLayout {
  const NativeSankeyNodeLayout({
    required this.node,
    required this.value,
    required this.layer,
    required this.sourceBounds,
    required this.bounds,
    required this.label,
    required this.labelBounds,
    required this.labelAnchor,
    required this.color,
  });

  final NativeSankeyNode node;
  final double value;
  final int layer;
  final Rect sourceBounds;
  final Rect bounds;
  final String label;
  final Rect labelBounds;
  final TextAlign labelAnchor;
  final Color color;
}

class NativeSankeyFlowLayout {
  const NativeSankeyFlowLayout({
    required this.flow,
    required this.width,
    required this.rawSourceY,
    required this.rawTargetY,
    required this.sourceY,
    required this.targetY,
    required this.path,
    required this.sourceColor,
    required this.targetColor,
  });

  final NativeSankeyFlow flow;
  final double width;
  final double rawSourceY;
  final double rawTargetY;
  final double sourceY;
  final double targetY;
  final Path path;
  final Color sourceColor;
  final Color targetColor;
}

class NativeSankeyLayout {
  NativeSankeyLayout({
    required this.diagram,
    required this.size,
    required Iterable<NativeSankeyNodeLayout> nodes,
    required Iterable<NativeSankeyFlowLayout> flows,
    required this.labelStyle,
    required this.labelColor,
    required this.prefix,
    required this.suffix,
  }) : nodes = List.unmodifiable(nodes),
       flows = List.unmodifiable(flows);

  final NativeSankeyDiagram diagram;
  final Size size;
  final List<NativeSankeyNodeLayout> nodes;
  final List<NativeSankeyFlowLayout> flows;
  final TextStyle labelStyle;
  final Color labelColor;
  final String prefix;
  final String suffix;

  NativeSankeyNodeLayout? nodeById(String id) {
    for (final node in nodes) {
      if (node.node.id == id) return node;
    }
    return null;
  }
}

class _Node {
  _Node(this.input);

  final NativeSankeyNode input;
  final List<_Flow> sourceLinks = [];
  final List<_Flow> targetLinks = [];
  double value = 0;
  int depth = 0;
  int height = 0;
  int layer = 0;
  double x0 = 0;
  double x1 = 0;
  double y0 = 0;
  double y1 = 0;
}

class _Flow {
  _Flow(this.input, this.source, this.target);

  final NativeSankeyFlow input;
  final _Node source;
  final _Node target;
  double width = 0;
  double y0 = 0;
  double y1 = 0;
}

/// Runs the pinned d3-sankey 0.12.3 defaults (justify, 600×400, six passes).
///
/// Mermaid 11.17.2 defaults to width=600, nodeWidth=10 and nodePadding=12.
/// Since showValues defaults true, its renderer adds 15px to nodePadding.
/// Mermaid resolves its default `sankey.height` to 400 before rendering.
NativeSankeyLayout layoutNativeMermaidSankey(
  NativeSankeyDiagram diagram, {
  required bool dark,
  String? fontFamily,
  String prefix = '',
  String suffix = '',
}) {
  if (diagram.nodes.isEmpty || diagram.flows.isEmpty) {
    throw FormatException(tr("Sankey needs at least one node and flow."));
  }
  final nodes = [for (final node in diagram.nodes) _Node(node)];
  final byId = {for (final node in nodes) node.input.id: node};
  final flows = <_Flow>[];
  for (final flow in diagram.flows) {
    final source = byId[flow.sourceId];
    final target = byId[flow.targetId];
    if (source == null || target == null) {
      throw FormatException(
        tr("Sankey flow {0} → {1} references a missing node.", [
          flow.sourceId,
          flow.targetId,
        ]),
      );
    }
    final link = _Flow(flow, source, target);
    flows.add(link);
    source.sourceLinks.add(link);
    target.targetLinks.add(link);
  }

  for (final node in nodes) {
    final outgoing = node.sourceLinks.fold<double>(
      0,
      (sum, link) => sum + link.input.value,
    );
    final incoming = node.targetLinks.fold<double>(
      0,
      (sum, link) => sum + link.input.value,
    );
    node.value = math.max(outgoing, incoming);
  }
  _computeDepths(nodes);
  _computeHeights(nodes);

  final layerCount = nodes.map((node) => node.depth).reduce(math.max) + 1;
  if (layerCount < 2) {
    throw FormatException(tr("Sankey layout needs at least two layers."));
  }
  final horizontalScale = (_extentWidth - _nodeWidth) / (layerCount - 1);
  final columns = List<List<_Node>?>.filled(layerCount, null);
  for (final node in nodes) {
    // d3-sankey's default justify alignment moves sinks into the last layer.
    node.layer = node.sourceLinks.isNotEmpty ? node.depth : layerCount - 1;
    node.layer = node.layer.clamp(0, layerCount - 1).toInt();
    node.x0 = node.layer * horizontalScale;
    node.x1 = node.x0 + _nodeWidth;
    (columns[node.layer] ??= <_Node>[]).add(node);
  }
  if (columns.any((column) => column == null || column.isEmpty)) {
    throw FormatException(
      tr(
        "Sankey source has an empty intermediate layer, which d3-sankey cannot lay out.",
      ),
    );
  }
  final completeColumns = columns.cast<List<_Node>>();
  final maxColumnLength = completeColumns
      .map((column) => column.length)
      .reduce(math.max);
  final padding = math.min(_nodePadding, _extentHeight / (maxColumnLength - 1));
  var verticalScale = double.infinity;
  for (final column in completeColumns) {
    final columnValue = column.fold<double>(0, (sum, node) => sum + node.value);
    final scale = (_extentHeight - (column.length - 1) * padding) / columnValue;
    verticalScale = math.min(verticalScale, scale);
  }
  if (!verticalScale.isFinite) {
    throw FormatException(
      tr(
        "Sankey has only zero-valued flows; the pinned D3 layout produces non-finite geometry.",
      ),
    );
  }
  for (final column in completeColumns) {
    var y = 0.0;
    for (final node in column) {
      node.y0 = y;
      node.y1 = y + node.value * verticalScale;
      y = node.y1 + padding;
      for (final flow in node.sourceLinks) {
        flow.width = flow.input.value * verticalScale;
      }
    }
    y = (_extentHeight - y + padding) / (column.length + 1);
    for (var index = 0; index < column.length; index++) {
      final node = column[index];
      node.y0 += y * (index + 1);
      node.y1 += y * (index + 1);
    }
    _reorderLinks(column);
  }

  for (var iteration = 0; iteration < _iterations; iteration++) {
    final alpha = math.pow(0.99, iteration).toDouble();
    final beta = math.max(1 - alpha, (iteration + 1) / _iterations);
    _relaxRightToLeft(completeColumns, alpha, beta, padding);
    _relaxLeftToRight(completeColumns, alpha, beta, padding);
  }
  _computeLinkBreadths(nodes);

  final labelStyle = TextStyle(
    fontFamily: fontFamily,
    fontSize: 14,
    height: kTextHeightNone,
    color: dark ? const Color(0xffcccccc) : const Color(0xff333333),
  );
  final colors = _tableau10;
  final rawNodeBounds = <_Node, Rect>{
    for (final node in nodes)
      node: Rect.fromLTRB(node.x0, node.y0, node.x1, node.y1),
  };
  final labelRects = <_Node, Rect>{};
  final labelPositions = <_Node, (String, Rect, TextAlign)>{};
  for (final node in nodes) {
    final label = _label(node, prefix, suffix);
    final size = _measure(label, labelStyle);
    final anchor = node.x0 < _extentWidth / 2
        ? TextAlign.left
        : TextAlign.right;
    final anchorX = node.x0 < _extentWidth / 2 ? node.x1 + 6 : node.x0 - 6;
    final left = anchor == TextAlign.left ? anchorX : anchorX - size.width;
    final baseline = (node.y0 + node.y1) / 2;
    final labelRect = Rect.fromLTWH(
      left,
      baseline - size.baseline,
      size.width,
      size.height,
    );
    labelRects[node] = labelRect;
    labelPositions[node] = (label, labelRect, anchor);
  }

  var bounds = Rect.zero;
  var hasBounds = false;
  void include(Rect rect) {
    bounds = hasBounds ? bounds.expandToInclude(rect) : rect;
    hasBounds = true;
  }

  for (final rect in rawNodeBounds.values) {
    include(rect);
  }
  for (final rect in labelRects.values) {
    include(rect);
  }
  if (!hasBounds ||
      !bounds.left.isFinite ||
      !bounds.top.isFinite ||
      !bounds.right.isFinite ||
      !bounds.bottom.isFinite) {
    throw FormatException(tr("Sankey layout produced invalid geometry."));
  }
  // Mermaid's setupGraphViewbox uses SVGElement.getBBox() with zero padding.
  // SVG getBBox excludes stroke width, so link strokes do not enlarge the viewBox.
  final shift = Offset(-bounds.left, -bounds.top);
  final size = Size(bounds.width, bounds.height);
  final laidOutNodes = <NativeSankeyNodeLayout>[
    for (final node in nodes)
      NativeSankeyNodeLayout(
        node: node.input,
        value: node.value,
        layer: node.layer,
        sourceBounds: rawNodeBounds[node]!,
        bounds: rawNodeBounds[node]!.shift(shift),
        label: labelPositions[node]!.$1,
        labelBounds: labelPositions[node]!.$2.shift(shift),
        labelAnchor: labelPositions[node]!.$3,
        color: colors[node.input.index % colors.length],
      ),
  ];
  final laidOutFlows = <NativeSankeyFlowLayout>[
    for (final flow in flows)
      NativeSankeyFlowLayout(
        flow: flow.input,
        width: flow.width,
        rawSourceY: flow.y0,
        rawTargetY: flow.y1,
        sourceY: flow.y0 + shift.dy,
        targetY: flow.y1 + shift.dy,
        path: Path()
          ..moveTo(flow.source.x1 + shift.dx, flow.y0 + shift.dy)
          ..cubicTo(
            (flow.source.x1 + flow.target.x0) / 2 + shift.dx,
            flow.y0 + shift.dy,
            (flow.source.x1 + flow.target.x0) / 2 + shift.dx,
            flow.y1 + shift.dy,
            flow.target.x0 + shift.dx,
            flow.y1 + shift.dy,
          ),
        sourceColor: colors[flow.source.input.index % colors.length],
        targetColor: colors[flow.target.input.index % colors.length],
      ),
  ];
  return NativeSankeyLayout(
    diagram: diagram,
    size: size,
    nodes: laidOutNodes,
    flows: laidOutFlows,
    labelStyle: labelStyle,
    labelColor: labelStyle.color!,
    prefix: prefix,
    suffix: suffix,
  );
}

class _MeasuredText {
  const _MeasuredText(this.width, this.height, this.baseline);

  final double width;
  final double height;
  final double baseline;
}

_MeasuredText _measure(String text, TextStyle style) {
  final painter = TextPainter(
    text: TextSpan(text: text, style: style),
    textDirection: TextDirection.ltr,
    textScaler: TextScaler.noScaling,
  )..layout();
  final measured = _MeasuredText(
    painter.width,
    painter.height,
    painter.computeDistanceToActualBaseline(TextBaseline.alphabetic),
  );
  painter.dispose();
  return measured;
}

String _label(_Node node, String prefix, String suffix) =>
    '${node.input.id} $prefix${_formatValue(node.value)}$suffix';

String _formatValue(double value) {
  final rounded = (value * 100).round() / 100;
  if (rounded == rounded.roundToDouble()) return rounded.toInt().toString();
  return rounded.toString();
}

void _computeDepths(List<_Node> nodes) {
  var current = List<_Node>.of(nodes);
  var depth = 0;
  while (current.isNotEmpty) {
    if (depth++ > nodes.length) {
      throw FormatException(tr("Sankey contains a circular link."));
    }
    final next = <_Node>{};
    for (final node in current) {
      node.depth = depth - 1;
      for (final flow in node.sourceLinks) {
        next.add(flow.target);
      }
    }
    current = next.toList(growable: false);
  }
}

void _computeHeights(List<_Node> nodes) {
  var current = List<_Node>.of(nodes);
  var height = 0;
  while (current.isNotEmpty) {
    if (height++ > nodes.length) {
      throw FormatException(tr("Sankey contains a circular link."));
    }
    final next = <_Node>{};
    for (final node in current) {
      node.height = height - 1;
      for (final flow in node.targetLinks) {
        next.add(flow.source);
      }
    }
    current = next.toList(growable: false);
  }
}

void _reorderLinks(List<_Node> column) {
  for (final node in column) {
    node.sourceLinks.sort((a, b) {
      final breadth = a.target.y0.compareTo(b.target.y0);
      return breadth != 0 ? breadth : a.input.index.compareTo(b.input.index);
    });
    node.targetLinks.sort((a, b) {
      final breadth = a.source.y0.compareTo(b.source.y0);
      return breadth != 0 ? breadth : a.input.index.compareTo(b.input.index);
    });
  }
}

void _reorderNodeLinks(_Node node) {
  for (final flow in node.targetLinks) {
    flow.source.sourceLinks.sort((a, b) {
      final breadth = a.target.y0.compareTo(b.target.y0);
      return breadth != 0 ? breadth : a.input.index.compareTo(b.input.index);
    });
  }
  for (final flow in node.sourceLinks) {
    flow.target.targetLinks.sort((a, b) {
      final breadth = a.source.y0.compareTo(b.source.y0);
      return breadth != 0 ? breadth : a.input.index.compareTo(b.input.index);
    });
  }
}

void _relaxRightToLeft(
  List<List<_Node>> columns,
  double alpha,
  double beta,
  double padding,
) {
  for (var columnIndex = columns.length - 2; columnIndex >= 0; columnIndex--) {
    final column = columns[columnIndex];
    for (final node in column) {
      var weighted = 0.0;
      var weight = 0.0;
      for (final flow in node.sourceLinks) {
        final value = flow.input.value * (flow.target.layer - node.layer);
        weighted += _sourceTop(flow, padding) * value;
        weight += value;
      }
      if (weight <= 0) continue;
      final delta = (weighted / weight - node.y0) * alpha;
      node.y0 += delta;
      node.y1 += delta;
      _reorderNodeLinks(node);
    }
    _sortNodesByBreadth(column);
    _resolveCollisions(column, beta, padding);
  }
}

void _relaxLeftToRight(
  List<List<_Node>> columns,
  double alpha,
  double beta,
  double padding,
) {
  for (var columnIndex = 1; columnIndex < columns.length; columnIndex++) {
    final column = columns[columnIndex];
    for (final node in column) {
      var weighted = 0.0;
      var weight = 0.0;
      for (final flow in node.targetLinks) {
        final value = flow.input.value * (node.layer - flow.source.layer);
        weighted += _targetTop(flow, padding) * value;
        weight += value;
      }
      if (weight <= 0) continue;
      final delta = (weighted / weight - node.y0) * alpha;
      node.y0 += delta;
      node.y1 += delta;
      _reorderNodeLinks(node);
    }
    _sortNodesByBreadth(column);
    _resolveCollisions(column, beta, padding);
  }
}

double _targetTop(_Flow flow, double padding) {
  var y = flow.source.y0 - (flow.source.sourceLinks.length - 1) * padding / 2;
  for (final sibling in flow.source.sourceLinks) {
    if (identical(sibling.target, flow.target)) break;
    y += sibling.width + padding;
  }
  for (final incoming in flow.target.targetLinks) {
    if (identical(incoming.source, flow.source)) break;
    y -= incoming.width;
  }
  return y;
}

double _sourceTop(_Flow flow, double padding) {
  var y = flow.target.y0 - (flow.target.targetLinks.length - 1) * padding / 2;
  for (final sibling in flow.target.targetLinks) {
    if (identical(sibling.source, flow.source)) break;
    y += sibling.width + padding;
  }
  for (final outgoing in flow.source.sourceLinks) {
    if (identical(outgoing.target, flow.target)) break;
    y -= outgoing.width;
  }
  return y;
}

void _sortNodesByBreadth(List<_Node> column) {
  // List.sort is not guaranteed stable, so retain the prior order on ties.
  final priorOrder = {for (var i = 0; i < column.length; i++) column[i]: i};
  column.sort((a, b) {
    final breadth = a.y0.compareTo(b.y0);
    return breadth != 0 ? breadth : priorOrder[a]!.compareTo(priorOrder[b]!);
  });
}

void _resolveCollisions(List<_Node> nodes, double alpha, double padding) {
  final middle = nodes.length >> 1;
  _resolveBottomToTop(
    nodes,
    nodes[middle].y0 - padding,
    middle - 1,
    alpha,
    padding,
  );
  _resolveTopToBottom(
    nodes,
    nodes[middle].y1 + padding,
    middle + 1,
    alpha,
    padding,
  );
  _resolveBottomToTop(nodes, _extentHeight, nodes.length - 1, alpha, padding);
  _resolveTopToBottom(nodes, 0, 0, alpha, padding);
}

void _resolveTopToBottom(
  List<_Node> nodes,
  double y,
  int startIndex,
  double alpha,
  double padding,
) {
  for (var index = startIndex; index < nodes.length; index++) {
    final node = nodes[index];
    final delta = (y - node.y0) * alpha;
    if (delta > 1e-6) {
      node.y0 += delta;
      node.y1 += delta;
    }
    y = node.y1 + padding;
  }
}

void _resolveBottomToTop(
  List<_Node> nodes,
  double y,
  int startIndex,
  double alpha,
  double padding,
) {
  for (var index = startIndex; index >= 0; index--) {
    final node = nodes[index];
    final delta = (node.y1 - y) * alpha;
    if (delta > 1e-6) {
      node.y0 -= delta;
      node.y1 -= delta;
    }
    y = node.y0 - padding;
  }
}

void _computeLinkBreadths(List<_Node> nodes) {
  for (final node in nodes) {
    var y0 = node.y0;
    var y1 = y0;
    for (final flow in node.sourceLinks) {
      flow.y0 = y0 + flow.width / 2;
      y0 += flow.width;
    }
    for (final flow in node.targetLinks) {
      flow.y1 = y1 + flow.width / 2;
      y1 += flow.width;
    }
  }
}

const _tableau10 = <Color>[
  Color(0xff4e79a7),
  Color(0xfff28e2c),
  Color(0xffe15759),
  Color(0xff76b7b2),
  Color(0xff59a14f),
  Color(0xffedc949),
  Color(0xffaf7aa1),
  Color(0xffff9da7),
  Color(0xff9c755f),
  Color(0xffbab0ab),
];
