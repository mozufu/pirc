/// Immutable model for the bounded native Mermaid Gantt subset.
///
/// All timestamps are UTC. Task intervals use the pinned Mermaid half-open
/// [start, end) convention; inclusiveEndDates shifts explicit date ends by a
/// day. renderEnd is nullable because Mermaid uses end when it is absent.
enum NativeMermaidGanttTaskStatus {
  done,
  active,
  critical,
  milestone,
  vertical,
}

class NativeMermaidGanttTask {
  NativeMermaidGanttTask({
    required this.label,
    required this.id,
    required this.hasExplicitId,
    required this.sectionIndex,
    required this.start,
    required this.end,
    this.renderEnd,
    this.previousTaskId,
    required Iterable<NativeMermaidGanttTaskStatus> statuses,
    Iterable<String> dependencies = const [],
    this.duration,
    this.sourceLine = 0,
  }) : statuses = Set.unmodifiable(statuses),
       dependencies = List.unmodifiable(dependencies);

  final String label;
  final String id;
  final bool hasExplicitId;
  final int sectionIndex;
  final DateTime start;
  final DateTime end;
  final DateTime? renderEnd;
  final String? previousTaskId;
  final Set<NativeMermaidGanttTaskStatus> statuses;
  final List<String> dependencies;
  final Duration? duration;
  final int sourceLine;

  bool get isMilestone =>
      statuses.contains(NativeMermaidGanttTaskStatus.milestone);
}

class NativeMermaidGanttSection {
  NativeMermaidGanttSection({
    required this.name,
    required this.index,
    required Iterable<NativeMermaidGanttTask> tasks,
  }) : tasks = List.unmodifiable(tasks);

  final String name;
  final int index;
  final List<NativeMermaidGanttTask> tasks;
}

class NativeMermaidGanttDiagram {
  NativeMermaidGanttDiagram({
    required this.title,
    required this.dateFormat,
    required this.axisFormat,
    required this.todayMarkerEnabled,
    required this.inclusiveEndDates,
    required this.excludesWeekends,
    required Iterable<DateTime> excludedDates,
    required Iterable<NativeMermaidGanttSection> sections,
    required Iterable<NativeMermaidGanttTask> tasks,
  }) : excludedDates = Set.unmodifiable(excludedDates),
       sections = List.unmodifiable(sections),
       tasks = List.unmodifiable(tasks);

  final String? title;
  final String dateFormat;
  final String? axisFormat;
  final bool todayMarkerEnabled;
  final bool inclusiveEndDates;
  final bool excludesWeekends;
  final Set<DateTime> excludedDates;
  final List<NativeMermaidGanttSection> sections;
  final List<NativeMermaidGanttTask> tasks;

  DateTime get start {
    var value = tasks.first.start;
    for (final task in tasks.skip(1)) {
      if (task.start.isBefore(value)) value = task.start;
    }
    return value;
  }

  DateTime get end {
    var value = tasks.first.end;
    for (final task in tasks.skip(1)) {
      if (task.end.isAfter(value)) value = task.end;
    }
    return value;
  }

  bool isExcluded(DateTime value) {
    final day = DateTime.utc(value.year, value.month, value.day);
    if (excludesWeekends &&
        (day.weekday == DateTime.saturday || day.weekday == DateTime.sunday)) {
      return true;
    }
    return excludedDates.contains(day);
  }
}
