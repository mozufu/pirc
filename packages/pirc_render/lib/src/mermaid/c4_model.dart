/// Immutable, Flutter-independent data model for native Mermaid C4 diagrams.
///
/// Text values are flattened from Mermaid's C4 database `{ text: ... }` values.
class NativeC4Diagram {
  NativeC4Diagram({
    required this.kind,
    required this.title,
    required Iterable<NativeC4Shape> shapes,
    required Iterable<NativeC4Boundary> boundaries,
    required Iterable<NativeC4Relation> relations,
    this.shapeInRow = 4,
    this.boundaryInRow = 2,
    this.wrap = true,
  }) : shapes = List.unmodifiable(shapes),
       boundaries = List.unmodifiable(boundaries),
       relations = List.unmodifiable(relations);

  /// Mermaid header, such as `C4Context` or `C4Deployment`.
  final String kind;
  final String? title;
  final List<NativeC4Shape> shapes;
  final List<NativeC4Boundary> boundaries;
  final List<NativeC4Relation> relations;
  final int shapeInRow;
  final int boundaryInRow;

  /// Mermaid C4 wrapping configuration used by element label layout.
  final bool wrap;
}

/// A person, system, container, or component in a C4 diagram.
class NativeC4Shape {
  const NativeC4Shape({
    required this.alias,
    required this.kind,
    required this.label,
    required this.parentBoundary,
    this.type,
    this.technology,
    this.description,
    this.wrap = false,
    this.backgroundColor,
    this.fontColor,
    this.borderColor,
    this.shadowing,
  });

  final String alias;

  /// Mermaid DB `typeC4Shape.text`, for example `external_system_db`.
  final String kind;
  final String label;

  /// Optional custom type text attached by a `$type=...` argument.
  final String? type;
  final String? technology;
  final String? description;
  final String parentBoundary;
  final bool wrap;
  final String? backgroundColor;
  final String? fontColor;
  final String? borderColor;

  /// Retained from the pinned DB; Mermaid 11.17.2 does not apply it in SVG.
  final String? shadowing;
}

/// A grouping boundary or a deployment node in a C4 diagram.
class NativeC4Boundary {
  const NativeC4Boundary({
    required this.alias,
    required this.label,
    required this.type,
    required this.parentBoundary,
    required this.kind,
    this.description,
    this.technology,
    this.wrap = false,
    this.nodeType,
    this.backgroundColor,
    this.fontColor,
    this.borderColor,
    this.shadowing,
  });

  final String alias;
  final String label;

  /// Mermaid DB `type.text`, such as `SYSTEM`, `CONTAINER`, or `node`.
  final String type;
  final String parentBoundary;

  /// Native grouping variant: `global`, `enterprise_boundary`,
  /// `system_boundary`, `boundary`, `container_boundary`, `deployment_node`,
  /// `node`, `node_l`, or `node_r`.
  final String kind;
  final String? description;
  final String? technology;
  final bool wrap;

  /// Mermaid DB deployment-node variant (`node`, `nodeL`, or `nodeR`).
  final String? nodeType;
  final String? backgroundColor;
  final String? fontColor;
  final String? borderColor;

  /// Retained from the pinned DB; Mermaid 11.17.2 does not apply it in SVG.
  final String? shadowing;
}

/// A directed or bidirectional relationship between C4 shapes.
class NativeC4Relation {
  const NativeC4Relation({
    required this.kind,
    required this.from,
    required this.to,
    required this.label,
    this.technology = '',
    this.description = '',
    this.wrap = false,
    this.textColor,
    this.lineColor,
    this.offsetX,
    this.offsetY,
  });

  /// Mermaid DB type: `rel`, `birel`, `rel_u`, `rel_d`, `rel_l`, `rel_r`,
  /// or `rel_b`.
  final String kind;
  final String from;
  final String to;
  final String label;
  final String technology;
  final String description;
  final bool wrap;
  final String? textColor;
  final String? lineColor;
  final int? offsetX;
  final int? offsetY;
}
