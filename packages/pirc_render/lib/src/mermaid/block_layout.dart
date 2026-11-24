import '../render_l10n.dart';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'block_model.dart';

@immutable
class NativeMermaidBlockNodeLayout {
  const NativeMermaidBlockNodeLayout({
    required this.node,
    required this.bounds,
  });

  final NativeMermaidBlockNode node;
  final Rect bounds;
}

@immutable
class NativeMermaidBlockEdgeLayout {
  const NativeMermaidBlockEdgeLayout({
    required this.edge,
    required this.path,
    required this.labelCenter,
  });

  final NativeMermaidBlockEdge edge;
  final Path path;
  final Offset labelCenter;
}

@immutable
class NativeMermaidBlockLayout {
  NativeMermaidBlockLayout({
    required this.viewBoxSize,
    required this.size,
    required this.scale,
    required Iterable<NativeMermaidBlockNodeLayout> nodes,
    required Iterable<NativeMermaidBlockEdgeLayout> edges,
  }) : nodes = List.unmodifiable(nodes),
       edges = List.unmodifiable(edges);

  final Size viewBoxSize;
  final Size size;
  final double scale;
  final List<NativeMermaidBlockNodeLayout> nodes;
  final List<NativeMermaidBlockEdgeLayout> edges;
}

/// Measures and lays out a block chart using the pinned source's recursive
/// column/span sizing and row placement rules. Coordinates are SVG-like units.
NativeMermaidBlockLayout layoutNativeMermaidBlock(
  NativeMermaidBlockDiagram diagram, {
  required double width,
  required bool dark,
  String? fontFamily,
  double fontSize = 13,
  double padding = 8,
}) {
  if (!width.isFinite || width <= 0) {
    throw FormatException(tr("Native block chart width must be positive."));
  }
  if (!fontSize.isFinite || fontSize <= 0 || !padding.isFinite || padding < 0) {
    throw FormatException(tr("Native block chart metrics are invalid."));
  }
  if (_containsZeroColumns(diagram.root)) {
    throw FormatException(tr("Columns must be an integer other than zero."));
  }

  final style = TextStyle(
    fontFamily: fontFamily,
    fontSize: fontSize,
    color: dark ? const Color(0xffcccccc) : const Color(0xff0f1115),
    letterSpacing: 0,
  );
  final root = _measure(diagram.root, style, padding);
  _sizeBlock(root, style, padding);
  _positionBlock(root, padding);

  final allBoxes = <NativeMermaidBlockNodeLayout>[];
  _collectNodeLayouts(root, allBoxes, isRoot: true);
  final byId = <String, NativeMermaidBlockNodeLayout>{
    for (final box in allBoxes) box.node.id: box,
  };
  final edgeLayouts = <NativeMermaidBlockEdgeLayout>[];
  for (final edge in diagram.edges) {
    final from = byId[edge.start];
    final to = byId[edge.end];
    if (from == null || to == null) {
      throw FormatException(
        tr("Block edge {0} to {1} references a missing node.", [
          edge.start,
          edge.end,
        ]),
      );
    }
    final delta = to.bounds.center - from.bounds.center;
    final startScale = _rectIntersectionScale(from.bounds.size, delta);
    final endScale = _rectIntersectionScale(to.bounds.size, delta);
    final start = from.bounds.center + delta * startScale;
    final end = to.bounds.center - delta * endScale;
    final middle = Offset((start.dx + end.dx) / 2, (start.dy + end.dy) / 2);
    final path = Path()
      ..moveTo(start.dx, start.dy)
      ..lineTo(middle.dx, middle.dy)
      ..lineTo(end.dx, end.dy);
    edgeLayouts.add(
      NativeMermaidBlockEdgeLayout(edge: edge, path: path, labelCenter: middle),
    );
  }

  var minX = 0.0;
  var minY = 0.0;
  var maxX = 0.0;
  var maxY = 0.0;
  bool hasBounds = false;
  void include(Rect rect) {
    if (!hasBounds) {
      minX = rect.left;
      minY = rect.top;
      maxX = rect.right;
      maxY = rect.bottom;
      hasBounds = true;
    } else {
      minX = math.min(minX, rect.left);
      minY = math.min(minY, rect.top);
      maxX = math.max(maxX, rect.right);
      maxY = math.max(maxY, rect.bottom);
    }
  }

  for (final box in allBoxes) {
    include(box.bounds);
  }
  for (final edge in edgeLayouts) {
    include(edge.path.getBounds());
    if (edge.edge.label.isNotEmpty) {
      final painter = _textPainter(edge.edge.label, style)..layout();
      include(
        Rect.fromCenter(
          center: edge.labelCenter,
          width: painter.width + 4,
          height: painter.height + 2,
        ),
      );
      painter.dispose();
    }
  }
  if (!hasBounds) {
    return NativeMermaidBlockLayout(
      viewBoxSize: const Size(10, 10),
      size: const Size(10, 10),
      scale: 1,
      nodes: const [],
      edges: const [],
    );
  }

  final shift = Offset(5 - minX, 5 - minY);
  final normalizedNodes = allBoxes
      .map(
        (node) => NativeMermaidBlockNodeLayout(
          node: node.node,
          bounds: node.bounds.shift(shift),
        ),
      )
      .toList(growable: false);
  final normalizedEdges = edgeLayouts
      .map(
        (edge) => NativeMermaidBlockEdgeLayout(
          edge: edge.edge,
          path: edge.path.shift(shift),
          labelCenter: edge.labelCenter + shift,
        ),
      )
      .toList(growable: false);
  final viewBox = Size(maxX - minX + 10, maxY - minY + 10);
  final scale = math.min(1.0, width / viewBox.width);
  return NativeMermaidBlockLayout(
    viewBoxSize: viewBox,
    size: Size(viewBox.width * scale, viewBox.height * scale),
    scale: scale,
    nodes: normalizedNodes,
    edges: normalizedEdges,
  );
}

bool _containsZeroColumns(NativeMermaidBlockNode node) =>
    node.columns == 0 || node.children.any(_containsZeroColumns);

_BlockMeasure _measure(
  NativeMermaidBlockNode node,
  TextStyle style,
  double padding,
) {
  if (node.isComposite) {
    final children = <_BlockMeasure>[];
    for (final child in node.children) {
      if (child.isSpace) {
        for (var i = 0; i < child.spaceCount; i++) {
          children.add(_BlockMeasure(node: child, width: 0, height: 0));
        }
      } else {
        children.add(_measure(child, style, padding));
      }
    }
    return _BlockMeasure(node: node, width: 0, height: 0, children: children);
  }
  if (node.isSpace) {
    return _BlockMeasure(node: node, width: 0, height: 0);
  }
  final text = _textPainter(node.label, style)..layout();
  final horizontalPadding = switch (node.shape) {
    NativeMermaidBlockShape.rectangle => padding * 2,
    _ => padding,
  };
  final size = Size(
    text.width + horizontalPadding * 2,
    text.height + padding * 2,
  );
  text.dispose();
  return _BlockMeasure(node: node, width: size.width, height: size.height);
}

void _sizeBlock(_BlockMeasure block, TextStyle style, double padding) {
  if (!block.node.isComposite || block.children.isEmpty) return;
  for (final child in block.children) {
    _sizeBlock(child, style, padding);
  }
  final maxChild = _maxChildSize(block.children);
  final maxWidth = maxChild.width;
  final maxHeight = maxChild.height;
  for (final child in block.children) {
    final span = child.node.widthInColumns;
    child
      ..width = maxWidth * span + padding * (span - 1)
      ..height = maxHeight
      ..x = 0
      ..y = 0;
  }
  for (final child in block.children) {
    if (child.node.isComposite) {
      child
        ..siblingWidth = maxWidth
        ..siblingHeight = maxHeight;
      _sizeBlock(child, style, padding);
    }
  }

  final columns = block.node.columns;
  var numItems = 0;
  for (final child in block.children) {
    numItems += child.node.widthInColumns;
  }
  var xSize = block.children.length;
  if (columns > 0 && columns < numItems) xSize = columns;
  if (xSize <= 0) return;
  final ySize = (numItems / xSize).ceil();
  var width = xSize * (maxWidth + padding) + padding;
  var height = ySize * (maxHeight + padding) + padding;

  if (width < block.siblingWidth) {
    width = block.siblingWidth;
    height = block.siblingHeight;
    final childWidth = (block.siblingWidth - xSize * padding - padding) / xSize;
    final childHeight =
        (block.siblingHeight - ySize * padding - padding) / ySize;
    for (final child in block.children) {
      child
        ..width = childWidth
        ..height = childHeight
        ..x = 0
        ..y = 0;
    }
  }
  if (width < block.width) {
    width = block.width;
    final count = columns > 0
        ? math.min(block.children.length, columns)
        : block.children.length;
    if (count > 0) {
      final childWidth = (width - count * padding - padding) / count;
      for (final child in block.children) {
        child.width = childWidth;
      }
    }
  }
  block
    ..width = width
    ..height = height;
}

({double width, double height}) _maxChildSize(List<_BlockMeasure> children) {
  var width = 0.0;
  var height = 0.0;
  for (final child in children) {
    if (child.node.isSpace) continue;
    final normalized = child.width / child.node.widthInColumns;
    width = math.max(width, normalized);
    height = math.max(height, child.height);
  }
  return (width: width, height: height);
}

void _positionBlock(_BlockMeasure block, double padding) {
  final columns = block.node.columns;
  if (columns == 0) {
    throw FormatException(tr("Columns must be an integer other than zero."));
  }
  if (block.children.isEmpty) return;

  final rowHeights = <int, double>{};
  var columnPosition = 0;
  for (final child in block.children) {
    final row = _blockPosition(columns, columnPosition).$2;
    rowHeights[row] = math.max(rowHeights[row] ?? 0, child.height);
    var filled = child.node.widthInColumns;
    if (columns > 0) {
      filled = math.min(filled, columns - (columnPosition % columns));
    }
    columnPosition += filled;
  }
  final rowOffsets = <int, double>{};
  var offset = 0.0;
  final rows = rowHeights.keys.toList()..sort();
  for (final row in rows) {
    rowOffsets[row] = offset;
    offset += rowHeights[row]! + padding;
  }

  columnPosition = 0;
  var rowPosition = 0;
  var startingX = block.x != 0 ? block.x - block.width / 2 : -padding;
  for (final child in block.children) {
    final row = _blockPosition(columns, columnPosition).$2;
    if (row != rowPosition) {
      rowPosition = row;
      startingX = block.x != 0 ? block.x - block.width / 2 : -padding;
    }
    final centerX = startingX + padding + child.width / 2;
    startingX = centerX + child.width / 2;
    final rowHeight = rowHeights[row] ?? child.height;
    child
      ..x = centerX
      ..y =
          block.y -
          block.height / 2 +
          (rowOffsets[row] ?? 0) +
          rowHeight / 2 +
          padding;
    _positionBlock(child, padding);
    var filled = child.node.widthInColumns;
    if (columns > 0) {
      filled = math.min(filled, columns - (columnPosition % columns));
    }
    columnPosition += filled;
  }
}

(int, int) _blockPosition(int columns, int position) {
  if (position < 0) {
    throw FormatException(tr("Block positions cannot be negative."));
  }
  if (columns == 0) {
    throw FormatException(tr("Columns must be an integer other than zero."));
  }
  if (columns < 0) return (position, 0);
  if (columns == 1) return (0, position);
  return (position % columns, position ~/ columns);
}

void _collectNodeLayouts(
  _BlockMeasure block,
  List<NativeMermaidBlockNodeLayout> result, {
  bool isRoot = false,
}) {
  if (block.node.isComposite) {
    if (!isRoot) {
      result.add(
        NativeMermaidBlockNodeLayout(
          node: block.node,
          bounds: Rect.fromCenter(
            center: Offset(block.x, block.y),
            width: block.width,
            height: block.height,
          ),
        ),
      );
    }
    for (final child in block.children) {
      _collectNodeLayouts(child, result);
    }
  } else if (!block.node.isSpace) {
    result.add(
      NativeMermaidBlockNodeLayout(
        node: block.node,
        bounds: Rect.fromCenter(
          center: Offset(block.x, block.y),
          width: block.width,
          height: block.height,
        ),
      ),
    );
  }
}

double _rectIntersectionScale(Size size, Offset delta) {
  final dx = delta.dx.abs();
  final dy = delta.dy.abs();
  if (dx == 0 && dy == 0) return 0;
  final xScale = dx == 0 ? double.infinity : size.width / 2 / dx;
  final yScale = dy == 0 ? double.infinity : size.height / 2 / dy;
  return math.min(xScale, yScale);
}

TextPainter _textPainter(String text, TextStyle style) => TextPainter(
  text: TextSpan(text: text, style: style),
  textDirection: TextDirection.ltr,
  textScaler: TextScaler.noScaling,
);

class _BlockMeasure {
  _BlockMeasure({
    required this.node,
    required this.width,
    required this.height,
    List<_BlockMeasure>? children,
  }) : children = children ?? <_BlockMeasure>[];

  final NativeMermaidBlockNode node;
  double width;
  double height;
  double siblingWidth = 0;
  double siblingHeight = 0;
  double x = 0;
  double y = 0;
  final List<_BlockMeasure> children;
}
