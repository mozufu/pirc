import 'package:flutter/foundation.dart';

enum NativeMermaidBlockShape {
  rectangle,
  rounded,
  circle,
  doubleCircle,
  diamond,
  hexagon,
  stadium,
  subroutine,
  cylinder,
  leanRight,
  leanLeft,
  trapezoid,
  inverseTrapezoid,
  leftArrow,
  blockArrow,
  composite,
  space,
}

@immutable
class NativeMermaidBlockNode {
  const NativeMermaidBlockNode({
    required this.id,
    required this.label,
    required this.shape,
    this.sourceType = 'na',
    this.widthInColumns = 1,
    this.columns = -1,
    this.spaceCount = 0,
    this.children = const [],
  });

  final String id;
  final String label;
  final NativeMermaidBlockShape shape;
  final String sourceType;

  /// A block consumes this many column positions in its parent.
  final int widthInColumns;

  /// Nested blocks use their own column count; -1 means auto columns.
  final int columns;

  /// `space:N` creates N invisible single-column layout slots.
  final int spaceCount;
  final List<NativeMermaidBlockNode> children;

  bool get isComposite => shape == NativeMermaidBlockShape.composite;
  bool get isSpace => shape == NativeMermaidBlockShape.space;
}

@immutable
class NativeMermaidBlockEdge {
  const NativeMermaidBlockEdge({
    required this.id,
    required this.start,
    required this.end,
    this.label = '',
    this.thickness = 'normal',
    this.pattern = 'solid',
    this.arrowTypeStart = 'arrow_open',
    this.arrowTypeEnd = '',
  });

  final String id;
  final String start;
  final String end;
  final String label;
  final String thickness;
  final String pattern;
  final String arrowTypeStart;
  final String arrowTypeEnd;
}

@immutable
class NativeMermaidBlockDiagram {
  NativeMermaidBlockDiagram({
    required this.root,
    required Iterable<NativeMermaidBlockEdge> edges,
  }) : edges = List.unmodifiable(edges);

  final NativeMermaidBlockNode root;
  final List<NativeMermaidBlockEdge> edges;

  Iterable<NativeMermaidBlockNode> get leafNodes sync* {
    Iterable<NativeMermaidBlockNode> visit(NativeMermaidBlockNode node) sync* {
      if (node.isComposite) {
        for (final child in node.children) {
          yield* visit(child);
        }
      } else if (!node.isSpace) {
        yield node;
      }
    }

    yield* visit(root);
  }
}
