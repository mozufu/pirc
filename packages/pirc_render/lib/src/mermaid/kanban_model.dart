/// Parsed data for the Mermaid 11.17.2 Kanban diagram subset.
///
/// The first indentation level in the source becomes ordered columns. Every
/// deeper node belongs to the most recent column, matching `kanbanDb.getData`.
class NativeMermaidKanbanBoard {
  NativeMermaidKanbanBoard({
    required Iterable<NativeMermaidKanbanColumn> columns,
  }) : columns = List.unmodifiable(columns);

  final List<NativeMermaidKanbanColumn> columns;
}

class NativeMermaidKanbanColumn {
  NativeMermaidKanbanColumn({
    required this.id,
    required this.label,
    required this.sourceLevel,
    this.ticket,
    required Iterable<NativeMermaidKanbanCard> cards,
  }) : cards = List.unmodifiable(cards);

  final String id;
  final String label;
  final int sourceLevel;
  final String? ticket;
  final List<NativeMermaidKanbanCard> cards;
}

class NativeMermaidKanbanCard {
  const NativeMermaidKanbanCard({
    required this.id,
    required this.label,
    required this.sourceLevel,
    this.ticket,
    this.assigned,
    this.priority,
    this.sourceShape = 'default',
  });

  final String id;
  final String label;
  final int sourceLevel;
  final String? ticket;
  final String? assigned;
  final String? priority;

  /// The shape delimiters from the source. Mermaid's Kanban renderer converts
  /// cards to `kanbanItem` regardless of this value; it affects only parser
  /// padding in the pinned DB.
  final String sourceShape;
}
