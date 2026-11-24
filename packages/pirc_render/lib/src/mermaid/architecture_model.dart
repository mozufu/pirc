/// Native data model for Mermaid 11.17.2 `architecture-beta` diagrams.
///
/// IDs and membership stay as written in the source so layout and rendering
/// can be inspected without reverse engineering a painted widget tree.
enum NativeMermaidArchitectureDirection { left, right, top, bottom }

enum NativeMermaidArchitectureIcon { cloud, database, disk, internet, server }

class NativeMermaidArchitectureGroup {
  const NativeMermaidArchitectureGroup({
    required this.id,
    required this.icon,
    required this.title,
    required this.parentId,
    required this.sourceLine,
  });

  final String id;
  final NativeMermaidArchitectureIcon? icon;
  final String? title;
  final String? parentId;
  final int sourceLine;
}

class NativeMermaidArchitectureService {
  const NativeMermaidArchitectureService({
    required this.id,
    required this.icon,
    required this.title,
    required this.parentId,
    required this.sourceLine,
  });

  final String id;
  final NativeMermaidArchitectureIcon? icon;
  final String? title;
  final String? parentId;
  final int sourceLine;
}

class NativeMermaidArchitectureJunction {
  const NativeMermaidArchitectureJunction({
    required this.id,
    required this.parentId,
    required this.sourceLine,
  });

  final String id;
  final String? parentId;
  final int sourceLine;
}

class NativeMermaidArchitectureEdge {
  const NativeMermaidArchitectureEdge({
    required this.sourceId,
    required this.sourceDirection,
    required this.sourceInto,
    required this.sourceGroup,
    required this.targetId,
    required this.targetDirection,
    required this.targetInto,
    required this.targetGroup,
    required this.title,
    required this.sourceLine,
  });

  final String sourceId;
  final NativeMermaidArchitectureDirection sourceDirection;
  final bool sourceInto;
  final bool sourceGroup;
  final String targetId;
  final NativeMermaidArchitectureDirection targetDirection;
  final bool targetInto;
  final bool targetGroup;
  final String? title;
  final int sourceLine;
}

class NativeMermaidArchitectureAlignment {
  const NativeMermaidArchitectureAlignment({
    required this.direction,
    required this.members,
    required this.sourceLine,
  });

  /// `row` places members left-to-right; `column` places them top-to-bottom.
  final String direction;
  final List<String> members;
  final int sourceLine;
}

class NativeMermaidArchitectureDiagram {
  NativeMermaidArchitectureDiagram({
    required Iterable<NativeMermaidArchitectureGroup> groups,
    required Iterable<NativeMermaidArchitectureService> services,
    required Iterable<NativeMermaidArchitectureJunction> junctions,
    required Iterable<NativeMermaidArchitectureEdge> edges,
    required Iterable<NativeMermaidArchitectureAlignment> alignments,
    required this.title,
    required this.accessibleTitle,
    required this.accessibleDescription,
  }) : groups = List.unmodifiable(groups),
       services = List.unmodifiable(services),
       junctions = List.unmodifiable(junctions),
       edges = List.unmodifiable(edges),
       alignments = List.unmodifiable(alignments);

  final List<NativeMermaidArchitectureGroup> groups;
  final List<NativeMermaidArchitectureService> services;
  final List<NativeMermaidArchitectureJunction> junctions;
  final List<NativeMermaidArchitectureEdge> edges;
  final List<NativeMermaidArchitectureAlignment> alignments;
  final String title;
  final String accessibleTitle;
  final String accessibleDescription;

  Iterable<String> get nodeIds sync* {
    for (final service in services) {
      yield service.id;
    }
    for (final junction in junctions) {
      yield junction.id;
    }
  }

  NativeMermaidArchitectureGroup? groupById(String id) {
    for (final group in groups) {
      if (group.id == id) return group;
    }
    return null;
  }

  NativeMermaidArchitectureService? serviceById(String id) {
    for (final service in services) {
      if (service.id == id) return service;
    }
    return null;
  }

  NativeMermaidArchitectureJunction? junctionById(String id) {
    for (final junction in junctions) {
      if (junction.id == id) return junction;
    }
    return null;
  }

  String? parentOf(String id) =>
      serviceById(id)?.parentId ??
      junctionById(id)?.parentId ??
      groupById(id)?.parentId;
}
