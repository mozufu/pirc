/// Immutable parsed model for Mermaid 11.17.2 user-journey diagrams.
///
/// Sections retain their source declarations, including empty declarations.
/// Tasks are source ordered and keep their own section name, actor list and
/// numeric satisfaction score. Rendered section runs are derived at layout
/// time, matching Mermaid's task renderer.
class NativeMermaidJourneyDiagram {
  NativeMermaidJourneyDiagram({
    required this.title,
    required this.accessibleTitle,
    required this.accessibleDescription,
    required Iterable<NativeMermaidJourneySection> sections,
    required Iterable<NativeMermaidJourneyTask> tasks,
    required Iterable<String> actors,
  }) : sections = List.unmodifiable(sections),
       tasks = List.unmodifiable(tasks),
       actors = List.unmodifiable(actors);

  final String title;
  final String accessibleTitle;
  final String accessibleDescription;
  final List<NativeMermaidJourneySection> sections;
  final List<NativeMermaidJourneyTask> tasks;

  /// Mermaid's getActors() returns unique actor names in sorted order.
  final List<String> actors;
}

class NativeMermaidJourneySection {
  const NativeMermaidJourneySection({
    required this.index,
    required this.name,
    required this.sourceLine,
  });

  final int index;
  final String name;
  final int sourceLine;
}

class NativeMermaidJourneyTask {
  NativeMermaidJourneyTask({
    required this.index,
    required this.label,
    required this.sectionName,
    required this.score,
    required this.sourceLine,
    required Iterable<String> actors,
  }) : actors = List.unmodifiable(actors);

  final int index;

  /// Text drawn in the task cell. Mermaid treats br tags as line breaks and
  /// treats other markup as text in its foreignObject label.
  final String label;
  final String sectionName;

  /// The source parser calls JavaScript Number() and the face is positioned
  /// from this value without clamping it to the conventional 1–5 range.
  final double score;
  final int sourceLine;
  final List<String> actors;
}
