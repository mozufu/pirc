/// The shape selected by Mermaid's mindmap node delimiters.
///
/// `defaultNode` is the source's unadorned node. The other values correspond
/// to Mermaid's six explicit node forms.
enum NativeMermaidMindmapShape {
  defaultNode,
  rectangle,
  roundedRectangle,
  circle,
  cloud,
  bang,
  hexagon,
}

/// A node in a parsed Mermaid mindmap.
///
/// [id] is Mermaid's generated, source-order integer id. [nodeId] is the
/// author's node id (or the label when the source does not provide one).
/// Labels have already passed through the native safe-HTML sanitizer; this is
/// a conservative subset of Mermaid's DOMPurify behavior, not a claim of full
/// DOMPurify compatibility.
class NativeMermaidMindmapNode {
  NativeMermaidMindmapNode({
    required this.id,
    required this.nodeId,
    required this.label,
    required this.level,
    required this.sourceIndent,
    required this.parentId,
    required Iterable<int> childIds,
    required this.shape,
    this.sectionIndex,
    this.className,
    this.icon,
    this.sourceLine = 0,
  }) : childIds = List.unmodifiable(childIds);

  /// Generated Mermaid node id in source order, starting at zero.
  final int id;

  /// Explicit source id, or the source label if no id was supplied.
  final String nodeId;

  /// Safe label text for the renderer. Mermaid assigns `labelType: markdown`
  /// to mindmap nodes, exposed here as [textType].
  final String label;

  /// Indentation level relative to the first node's indentation.
  final int level;

  /// Number of leading whitespace UTF-16 code units on the source line.
  final int sourceIndent;

  final int? parentId;
  final List<int> childIds;
  final NativeMermaidMindmapShape shape;

  /// Root nodes have no section. Root children receive an index modulo 11;
  /// deeper descendants inherit their root child's section.
  final int? sectionIndex;

  /// Decoration metadata from Mermaid's `:::class` directive.
  final String? className;

  /// Decoration metadata from Mermaid's `::icon(name)` directive.
  /// Icon rendering is outside the parser's scope.
  final String? icon;

  final int sourceLine;

  /// Mermaid mindmap nodes are rendered as Markdown labels.
  String get textType => 'markdown';

  /// Alias matching Mermaid's flattened layout-node field name.
  String get labelType => textType;
}

/// Immutable source-order model for a Mermaid mindmap.
class NativeMermaidMindmapDiagram {
  NativeMermaidMindmapDiagram({
    required Iterable<NativeMermaidMindmapNode> nodes,
  }) : nodes = List.unmodifiable(nodes),
       assert(nodes.isNotEmpty, 'A mindmap must have a root node');

  final List<NativeMermaidMindmapNode> nodes;

  NativeMermaidMindmapNode get root => nodes.first;

  NativeMermaidMindmapNode? nodeById(int id) {
    for (final node in nodes) {
      if (node.id == id) return node;
    }
    return null;
  }
}
