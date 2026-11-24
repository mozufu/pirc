/// Parsed source-order model for Mermaid 11.17.2 timeline diagrams.
///
/// Mermaid's timeline DB keeps a module-global task counter which is not reset
/// by its `clear()` method. Native IDs are intentionally stable within each
/// parsed document and start at zero; they do not reproduce that cross-document
/// side effect.
class NativeMermaidTimelineDiagram {
  NativeMermaidTimelineDiagram({
    required this.direction,
    required this.title,
    required this.accessibleTitle,
    required this.accessibleDescription,
    required Iterable<NativeMermaidTimelineSection> sections,
    required Iterable<NativeMermaidTimelineTask> tasks,
  }) : sections = List.unmodifiable(sections),
       tasks = List.unmodifiable(tasks);

  /// Mermaid timeline direction (`LR` or `TD`).
  final String direction;

  /// Raw diagram title assigned by the parser, or an empty string.
  final String title;

  /// Accessibility title, after Mermaid's parser-level trimming.
  final String accessibleTitle;

  /// Accessibility description, after Mermaid's parser-level trimming and
  /// multiline indentation cleanup.
  final String accessibleDescription;

  /// Sections in source order. Duplicate names and empty sections are kept.
  final List<NativeMermaidTimelineSection> sections;

  /// Timeline tasks in source order.
  final List<NativeMermaidTimelineTask> tasks;
}

class NativeMermaidTimelineSection {
  const NativeMermaidTimelineSection({
    required this.index,
    required this.name,
    required this.sourceLine,
  });

  final int index;
  final String name;

  /// One-based line in the original source passed to the native parser.
  final int sourceLine;
}

class NativeMermaidTimelineTask {
  NativeMermaidTimelineTask({
    required this.id,
    required this.period,
    required this.sectionName,
    required this.sourceLine,
    Iterable<NativeMermaidTimelineEvent> events = const [],
    this.score = 0,
  }) : events = List.unmodifiable(events);

  /// Stable zero-based source-order ID within this parsed document.
  final int id;

  /// Raw period token. Trailing whitespace is significant and is preserved.
  final String period;

  /// Current section name at the point this task was parsed; empty if none.
  final String sectionName;

  /// Mermaid DB's timeline score (the parser currently supplies zero).
  final int score;

  /// One-based line containing the period token.
  final int sourceLine;

  final List<NativeMermaidTimelineEvent> events;

  /// Alias for Mermaid's DB task field.
  String get task => period;

  /// Alias for Mermaid's DB section and type fields.
  String get section => sectionName;

  String get type => sectionName;
}

class NativeMermaidTimelineEvent {
  const NativeMermaidTimelineEvent({
    required this.text,
    required this.sourceLine,
  });

  /// Event token text after Mermaid removes the initial colon and one
  /// following whitespace code unit. Remaining whitespace is retained.
  final String text;

  /// One-based line containing the event token.
  final int sourceLine;
}
