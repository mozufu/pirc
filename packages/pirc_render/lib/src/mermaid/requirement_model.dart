/// Immutable native model for Mermaid 11.17.2 requirement diagrams.
///
/// Requirement and element nodes share the same fields because Mermaid's
/// requirement database keeps them in separate maps but serializes them into
/// one graph node list.
class NativeRequirementNode {
  NativeRequirementNode({
    required this.name,
    this.type = '',
    this.requirementId = '',
    this.text = '',
    this.risk = '',
    this.verifyMethod = '',
    this.docRef = '',
    this.isElement = false,
    Iterable<String> cssStyles = const [],
    Iterable<String> classes = const ['default'],
    this.label,
  }) : cssStyles = List.unmodifiable(cssStyles),
       classes = List.unmodifiable(classes);

  final String name;
  final String type;
  final String requirementId;
  final String text;
  final String risk;
  final String verifyMethod;
  final String docRef;
  final bool isElement;
  final List<String> cssStyles;
  final List<String> classes;

  /// Optional presentation label. When present it takes precedence over the
  /// source name; Mermaid's requirement grammar does not itself define this
  /// field, but consumers may supply it when adapting the parsed model.
  final String? label;

  String get displayLabel => label ?? name;
}

/// A directed relation. Reverse Mermaid arrows are normalized into [from] and
/// [to] so renderers can treat every relation the same way.
class NativeRequirementRelation {
  const NativeRequirementRelation({
    required this.type,
    required this.from,
    required this.to,
  });

  final String type;
  final String from;
  final String to;
}

/// Parsed requirementDiagram data in Mermaid database insertion order.
class NativeRequirementDiagram {
  NativeRequirementDiagram({
    this.direction = 'TB',
    this.title,
    this.accTitle,
    this.accDescription,
    Iterable<NativeRequirementNode> requirements = const [],
    Iterable<NativeRequirementNode> elements = const [],
    Iterable<NativeRequirementRelation> relations = const [],
    Map<String, List<String>> classDefinitions = const {},
  }) : requirements = List.unmodifiable(requirements),
       elements = List.unmodifiable(elements),
       relations = List.unmodifiable(relations),
       classDefinitions = Map.unmodifiable(
         classDefinitions.map(
           (name, styles) => MapEntry(name, List<String>.unmodifiable(styles)),
         ),
       );

  final String? direction;
  final String? title;
  final String? accTitle;
  final String? accDescription;
  final List<NativeRequirementNode> requirements;
  final List<NativeRequirementNode> elements;
  final List<NativeRequirementRelation> relations;

  /// Mermaid `classDef` rules in declaration order, including repeated
  /// definitions. Nodes retain the styles copied onto them by the DB as well.
  final Map<String, List<String>> classDefinitions;

  /// Mermaid emits requirements first and elements second in graph data.
  List<NativeRequirementNode> get nodes =>
      List.unmodifiable([...requirements, ...elements]);

  NativeRequirementNode? node(String name) {
    for (final item in requirements) {
      if (item.name == name) return item;
    }
    for (final item in elements) {
      if (item.name == name) return item;
    }
    return null;
  }
}
