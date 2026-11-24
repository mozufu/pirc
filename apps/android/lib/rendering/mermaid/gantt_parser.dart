import '../render_l10n.dart';
import 'gantt_model.dart';

/// Parses the native Mermaid Gantt subset synchronously.
///
/// Supported date formats are YYYY-MM-DD, YYYY-MM-DD HH:mm, and HH:mm. Unsupported
/// directives, task forms and date formats raise FormatException rather than
/// being omitted from the diagram.
NativeMermaidGanttDiagram parseNativeMermaidGantt(
  String source, {
  DateTime? clock,
}) {
  if (source.length > 50000) {
    throw FormatException(tr("Gantt diagram exceeds 50000 characters"));
  }

  final now = clock ?? DateTime.now();
  final clockAnchor = DateTime.utc(now.year, now.month, now.day);
  final lines = source
      .replaceAll('\r\n', '\n')
      .replaceAll('\r', '\n')
      .split('\n');
  var headerFound = false;
  var titleSeen = false;
  var dateFormat = 'YYYY-MM-DD';
  String? axisFormat;
  var todayMarkerEnabled = true;
  var inclusiveEndDates = false;
  var excludesWeekends = false;
  final rawExcludedDates = <String>[];
  final rawTasks = <_RawTask>[];
  final sectionNames = <String>[];
  var activeSection = -1;
  String? title;

  Never invalid(int line, String details) => throw FormatException(
    tr("Invalid Mermaid Gantt at line {0}: {1}", [line, details]),
  );

  for (var index = 0; index < lines.length; index++) {
    final lineNumber = index + 1;
    final line = lines[index].trim();
    if (line.isEmpty) continue;
    if (line.startsWith('%%{')) {
      invalid(lineNumber, tr("Mermaid directives are not supported natively"));
    }
    if (line.startsWith('%%')) continue;

    if (!headerFound) {
      if (line.toLowerCase() != 'gantt') {
        invalid(lineNumber, tr("Expected gantt header"));
      }
      headerFound = true;
      continue;
    }

    final titleMatch = RegExp(
      r'^title(?:\s+|:\s*)(.+)$',
      caseSensitive: false,
    ).firstMatch(line);
    if (titleMatch != null) {
      if (titleSeen) invalid(lineNumber, tr("Only one title is supported"));
      titleSeen = true;
      title = titleMatch.group(1)!.trim();
      if (title.isEmpty) invalid(lineNumber, tr("Title cannot be empty"));
      continue;
    }

    final dateFormatMatch = RegExp(
      r'^dateFormat\s+(.+)$',
      caseSensitive: false,
    ).firstMatch(line);
    if (dateFormatMatch != null) {
      final candidate = dateFormatMatch.group(1)!.trim();
      if (candidate != 'YYYY-MM-DD' &&
          candidate != 'YYYY-MM-DD HH:mm' &&
          candidate != 'HH:mm') {
        invalid(
          lineNumber,
          tr(
            "Only dateFormat YYYY-MM-DD, YYYY-MM-DD HH:mm, and HH:mm are supported",
          ),
        );
      }
      dateFormat = candidate;
      continue;
    }

    final axisMatch = RegExp(
      r'^axisFormat(?:\s+|:\s*)(.+)$',
      caseSensitive: false,
    ).firstMatch(line);
    if (axisMatch != null) {
      axisFormat = axisMatch.group(1)!.trim();
      if (axisFormat.isEmpty) {
        invalid(lineNumber, tr("axisFormat cannot be empty"));
      }
      continue;
    }

    if (line.toLowerCase() == 'inclusiveenddates') {
      inclusiveEndDates = true;
      continue;
    }

    final todayMatch = RegExp(
      r'^todayMarker\s+(.+)$',
      caseSensitive: false,
    ).firstMatch(line);
    if (todayMatch != null) {
      final value = todayMatch.group(1)!.trim();
      if (value.toLowerCase() != 'off') {
        invalid(lineNumber, tr("Only todayMarker off is supported"));
      }
      todayMarkerEnabled = false;
      continue;
    }

    final excludesMatch = RegExp(
      r'^excludes\s+(.+)$',
      caseSensitive: false,
    ).firstMatch(line);
    if (excludesMatch != null) {
      for (final item in excludesMatch.group(1)!.split(',')) {
        final value = item.trim();
        if (value.isEmpty) invalid(lineNumber, tr("Empty excludes entry"));
        if (value.toLowerCase() == 'weekends') {
          excludesWeekends = true;
        } else {
          rawExcludedDates.add(value);
        }
      }
      continue;
    }

    final sectionMatch = RegExp(
      r'^section\s+(.+)$',
      caseSensitive: false,
    ).firstMatch(line);
    if (sectionMatch != null) {
      final name = sectionMatch.group(1)!.trim();
      if (name.isEmpty) invalid(lineNumber, tr("Section name cannot be empty"));
      if (sectionNames.length >= 100) {
        invalid(lineNumber, tr("Native Gantt supports at most 100 sections"));
      }
      sectionNames.add(name);
      activeSection = sectionNames.length - 1;
      continue;
    }

    if (RegExp(
      r'^(click|includes|weekday|weekend|tickInterval|accTitle|accDescr)(?:\s|$)',
      caseSensitive: false,
    ).hasMatch(line)) {
      invalid(lineNumber, tr("This Gantt directive is not supported natively"));
    }

    final separator = line.indexOf(':');
    if (separator <= 0) {
      invalid(
        lineNumber,
        tr("Expected a directive, section, or task label : data"),
      );
    }
    // Keep author whitespace before the separator: Mermaid preserves it in
    // task labels, and renderers use that raw label for layout measurement.
    final label = line.substring(0, separator).trimLeft();
    final data = line.substring(separator + 1).trim();
    if (label.isEmpty || data.isEmpty) {
      invalid(lineNumber, tr("Task label and task data must be non-empty"));
    }
    if (activeSection < 0) {
      sectionNames.add('');
      activeSection = 0;
    }
    if (rawTasks.length >= 500) {
      invalid(lineNumber, tr("Native Gantt supports at most 500 tasks"));
    }
    rawTasks.add(
      _RawTask(
        label: label,
        data: data,
        sectionIndex: activeSection,
        sourceLine: lineNumber,
        previousTask: rawTasks.isEmpty ? null : rawTasks.last,
      ),
    );
  }

  if (!headerFound) {
    throw FormatException(tr("Missing Mermaid Gantt header"));
  }
  if (rawTasks.isEmpty) {
    throw FormatException(tr("Gantt diagram must contain at least one task"));
  }

  final excludedDates = <DateTime>{};
  for (final raw in rawExcludedDates) {
    final parsed = _parseDate(raw, dateFormat, clockAnchor);
    if (parsed == null) {
      throw FormatException(
        tr("Invalid Mermaid Gantt excludes date \"{0}\" for dateFormat {1}", [
          raw,
          dateFormat,
        ]),
      );
    }
    excludedDates.add(_day(parsed));
  }

  final rawById = <String, _RawTask>{};
  final explicitIds = <_RawTask, String>{};
  for (final raw in rawTasks) {
    raw.parseFields(dateFormat, clockAnchor, invalid);
    final id = raw.explicitId;
    if (id != null) {
      if (rawById.containsKey(id)) {
        invalid(raw.sourceLine, tr("Duplicate task id \"{0}\"", [id]));
      }
      rawById[id] = raw;
      explicitIds[raw] = id;
    }
  }

  var autoId = 0;
  for (final raw in rawTasks) {
    if (explicitIds.containsKey(raw)) continue;
    String candidate;
    do {
      autoId++;
      candidate = 'task$autoId';
    } while (rawById.containsKey(candidate));
    rawById[candidate] = raw;
    explicitIds[raw] = candidate;
  }

  final idForRaw = <_RawTask, String>{...explicitIds};
  for (final raw in rawTasks) {
    for (final dependency in raw.dependencies) {
      if (!rawById.containsKey(dependency)) {
        invalid(raw.sourceLine, tr("Unknown dependency \"{0}\"", [dependency]));
      }
    }
  }

  final resolved = <_RawTask, NativeMermaidGanttTask>{};
  final resolving = <_RawTask>{};

  NativeMermaidGanttTask resolve(_RawTask raw) {
    final cached = resolved[raw];
    if (cached != null) return cached;
    if (!resolving.add(raw)) {
      invalid(raw.sourceLine, tr("Task dependencies contain a cycle"));
    }

    DateTime start;
    if (raw.startDate != null) {
      start = raw.startDate!;
    } else if (raw.implicitStart) {
      start = raw.previousTask == null
          ? clockAnchor
          : resolve(raw.previousTask!).end;
    } else {
      final dependencies = raw.dependencies
          .map((id) => resolve(rawById[id]!))
          .toList();
      if (dependencies.isEmpty) {
        invalid(
          raw.sourceLine,
          tr("A task needs a start date or after dependency"),
        );
      }
      start = dependencies.first.end;
      for (final dependency in dependencies.skip(1)) {
        if (dependency.end.isAfter(start)) start = dependency.end;
      }
    }

    final endpoint = raw.endpoint!;
    late final DateTime end;
    DateTime? renderEnd;
    Duration? duration;
    if (endpoint.duration != null) {
      duration = endpoint.duration;
      final interval = _addDuration(
        start,
        duration!,
        endpoint.unit!,
        excludesWeekends: excludesWeekends,
        excludedDates: excludedDates,
        line: raw.sourceLine,
        invalid: invalid,
      );
      end = interval.end;
      renderEnd = interval.renderEnd;
    } else {
      final sourceEnd = endpoint.date!;
      if (raw.statuses.contains(NativeMermaidGanttTaskStatus.milestone)) {
        if (sourceEnd != start) {
          invalid(
            raw.sourceLine,
            tr("Milestone start and end must identify the same instant"),
          );
        }
        end = start;
        renderEnd = null;
      } else {
        end = inclusiveEndDates
            ? sourceEnd.add(const Duration(days: 1))
            : sourceEnd;
        renderEnd = null;
      }
    }

    final milestone = raw.statuses.contains(
      NativeMermaidGanttTaskStatus.milestone,
    );
    if (milestone && duration != null && duration != Duration.zero) {
      invalid(raw.sourceLine, tr("Milestone duration must be zero"));
    }
    if (!milestone && !end.isAfter(start)) {
      invalid(raw.sourceLine, tr("Task end must be after task start"));
    }

    final task = NativeMermaidGanttTask(
      label: raw.label,
      id: idForRaw[raw]!,
      hasExplicitId: raw.explicitId != null,
      sectionIndex: raw.sectionIndex,
      start: start,
      end: end,
      renderEnd: renderEnd,
      previousTaskId: raw.previousTask == null
          ? null
          : idForRaw[raw.previousTask!],
      statuses: raw.statuses,
      dependencies: raw.dependencies,
      duration: duration,
      sourceLine: raw.sourceLine,
    );
    resolved[raw] = task;
    resolving.remove(raw);
    return task;
  }

  final tasks = rawTasks.map(resolve).toList()
    ..sort((a, b) => a.sourceLine.compareTo(b.sourceLine));
  final sections = <NativeMermaidGanttSection>[
    for (var index = 0; index < sectionNames.length; index++)
      NativeMermaidGanttSection(
        name: sectionNames[index],
        index: index,
        tasks: tasks.where((task) => task.sectionIndex == index),
      ),
  ];

  return NativeMermaidGanttDiagram(
    title: title,
    dateFormat: dateFormat,
    axisFormat: axisFormat,
    todayMarkerEnabled: todayMarkerEnabled,
    inclusiveEndDates: inclusiveEndDates,
    excludesWeekends: excludesWeekends,
    excludedDates: excludedDates,
    sections: sections,
    tasks: tasks,
  );
}

class _RawTask {
  _RawTask({
    required this.label,
    required this.data,
    required this.sectionIndex,
    required this.sourceLine,
    required this.previousTask,
  });

  final String label;
  final String data;
  final int sectionIndex;
  final int sourceLine;
  final _RawTask? previousTask;
  String? explicitId;
  bool implicitStart = false;
  Set<NativeMermaidGanttTaskStatus> statuses = {};
  List<String> dependencies = [];
  DateTime? startDate;
  _GanttEndpoint? endpoint;

  void parseFields(
    String dateFormat,
    DateTime clockAnchor,
    Never Function(int, String) invalid,
  ) {
    final all = data.split(',').map((part) => part.trim()).toList();
    if (all.any((part) => part.isEmpty)) {
      invalid(
        sourceLine,
        tr("Task data contains an empty comma-separated field"),
      );
    }

    statuses = <NativeMermaidGanttTaskStatus>{};
    var tagCount = 0;
    while (tagCount < all.length) {
      final status = _statusTag(all[tagCount]);
      if (status == null) break;
      statuses.add(status);
      tagCount++;
    }
    final fields = all.skip(tagCount).toList();

    if (fields.length == 1 && _parseDuration(fields.single) != null) {
      implicitStart = true;
      endpoint = _parseEndpoint(fields.single, dateFormat, clockAnchor);
      return;
    }

    final startIndex = fields.indexWhere(
      (field) =>
          field.toLowerCase().startsWith('after ') ||
          _parseDate(field, dateFormat, clockAnchor) != null,
    );
    if (startIndex < 0) {
      invalid(
        sourceLine,
        tr("Task start must be a supported date or an after dependency"),
      );
    }

    final prefix = fields.take(startIndex).toList();
    if (prefix.length > 1) {
      invalid(sourceLine, tr("Task data may contain at most one explicit id"));
    }
    if (prefix.isNotEmpty) {
      final id = prefix.single;
      if (!_validId.hasMatch(id)) {
        invalid(sourceLine, tr("Invalid task id \"{0}\"", [id]));
      }
      explicitId = id;
    }

    final startField = fields[startIndex];
    final remaining = fields.skip(startIndex + 1).toList();
    if (startField.toLowerCase().startsWith('after ')) {
      final firstDependencies = startField.substring(6).trim();
      dependencies.addAll(
        _dependencyWords(firstDependencies, sourceLine, invalid),
      );
      var endpointIndex = -1;
      for (var index = 0; index < remaining.length; index++) {
        if (_parseDate(remaining[index], dateFormat, clockAnchor) != null ||
            _parseDuration(remaining[index]) != null) {
          endpointIndex = index;
          break;
        }
      }
      if (endpointIndex < 0) {
        invalid(sourceLine, tr("after tasks need an end date or duration"));
      }
      for (final item in remaining.take(endpointIndex)) {
        dependencies.addAll(_dependencyWords(item, sourceLine, invalid));
      }
      if (remaining.length != endpointIndex + 1) {
        invalid(sourceLine, tr("Unexpected task fields after its endpoint"));
      }
      endpoint = _parseEndpoint(
        remaining[endpointIndex],
        dateFormat,
        clockAnchor,
      );
    } else {
      startDate = _parseDate(startField, dateFormat, clockAnchor);
      if (remaining.length != 1) {
        invalid(
          sourceLine,
          tr("A task needs exactly one end date or duration"),
        );
      }
      endpoint = _parseEndpoint(remaining.single, dateFormat, clockAnchor);
    }

    if (dependencies.toSet().length != dependencies.length) {
      invalid(sourceLine, tr("A dependency is listed more than once"));
    }
    if (dependencies.any((id) => !_validId.hasMatch(id))) {
      invalid(sourceLine, tr("Invalid dependency id"));
    }
  }
}

final _validId = RegExp(r'^[A-Za-z0-9_.-]+$');

List<String> _dependencyWords(
  String value,
  int line,
  Never Function(int, String) invalid,
) {
  final result = value
      .split(RegExp(r'\s+'))
      .where((word) => word.isNotEmpty)
      .toList();
  if (result.isEmpty) invalid(line, tr("after must name at least one task id"));
  return result;
}

class _GanttEndpoint {
  const _GanttEndpoint.date(this.date) : duration = null, unit = null;
  const _GanttEndpoint.length(this.duration, this.unit) : date = null;

  final DateTime? date;
  final Duration? duration;
  final String? unit;
}

_GanttEndpoint? _parseEndpoint(
  String value,
  String format,
  DateTime clockAnchor,
) {
  final date = _parseDate(value, format, clockAnchor);
  if (date != null) return _GanttEndpoint.date(date);
  final parsed = _parseDuration(value);
  if (parsed != null) return _GanttEndpoint.length(parsed.$1, parsed.$2);
  return null;
}

(Duration, String)? _parseDuration(String value) {
  final match = RegExp(r'^(\d+(?:\.\d+)?)(d|w|h|m)$').firstMatch(value);
  if (match == null) return null;
  final amount = double.tryParse(match.group(1)!);
  if (amount == null) return null;
  final unit = match.group(2)!;
  final microseconds = switch (unit) {
    'd' => amount * Duration.microsecondsPerDay,
    'w' => amount * 7 * Duration.microsecondsPerDay,
    'h' => amount * Duration.microsecondsPerHour,
    'm' => amount * Duration.microsecondsPerMinute,
    _ => 0,
  };
  return (Duration(microseconds: microseconds.round()), unit);
}

DateTime? _parseDate(String value, String format, DateTime clockAnchor) {
  if (format == 'HH:mm') {
    final match = RegExp(r'^(\d{2}):(\d{2})$').firstMatch(value);
    if (match == null) return null;
    final hour = int.parse(match.group(1)!);
    final minute = int.parse(match.group(2)!);
    if (hour > 23 || minute > 59) return null;
    return DateTime.utc(
      clockAnchor.year,
      clockAnchor.month,
      clockAnchor.day,
      hour,
      minute,
    );
  }
  final match = format == 'YYYY-MM-DD'
      ? RegExp(r'^(\d{4})-(\d{2})-(\d{2})$').firstMatch(value)
      : RegExp(r'^(\d{4})-(\d{2})-(\d{2}) (\d{2}):(\d{2})$').firstMatch(value);
  if (match == null) return null;
  final year = int.parse(match.group(1)!);
  final month = int.parse(match.group(2)!);
  final day = int.parse(match.group(3)!);
  final hour = format == 'YYYY-MM-DD HH:mm' ? int.parse(match.group(4)!) : 0;
  final minute = format == 'YYYY-MM-DD HH:mm' ? int.parse(match.group(5)!) : 0;
  final lastDay = DateTime.utc(year, month + 1, 0).day;
  if (month < 1 ||
      month > 12 ||
      day < 1 ||
      day > lastDay ||
      hour < 0 ||
      hour > 23 ||
      minute < 0 ||
      minute > 59) {
    return null;
  }
  return DateTime.utc(year, month, day, hour, minute);
}

NativeMermaidGanttTaskStatus? _statusTag(String item) =>
    switch (item.toLowerCase()) {
      'done' => NativeMermaidGanttTaskStatus.done,
      'active' => NativeMermaidGanttTaskStatus.active,
      'crit' => NativeMermaidGanttTaskStatus.critical,
      'milestone' => NativeMermaidGanttTaskStatus.milestone,
      'vert' => NativeMermaidGanttTaskStatus.vertical,
      _ => null,
    };

DateTime _day(DateTime value) =>
    DateTime.utc(value.year, value.month, value.day);

({DateTime end, DateTime? renderEnd}) _addDuration(
  DateTime start,
  Duration duration,
  String unit, {
  required bool excludesWeekends,
  required Set<DateTime> excludedDates,
  required int line,
  required Never Function(int, String) invalid,
}) {
  final rawEnd = start.add(duration);
  if (duration == Duration.zero) return (end: start, renderEnd: null);
  final hasExclusions = excludesWeekends || excludedDates.isNotEmpty;
  if (!hasExclusions || (unit != 'd' && unit != 'w')) {
    return (end: rawEnd, renderEnd: null);
  }

  // Mermaid keeps calendar duration for the rendered endpoint, then extends
  // logical endTime over excluded days for dependent task scheduling.
  var logicalEnd = rawEnd;
  var cursor = DateTime.utc(start.year, start.month, start.day + 1);
  var crossedExcludedDay = false;
  for (
    var attempts = 0;
    !cursor.isAfter(logicalEnd) && attempts < 36600;
    attempts++
  ) {
    final excluded =
        (excludesWeekends &&
            (cursor.weekday == DateTime.saturday ||
                cursor.weekday == DateTime.sunday)) ||
        excludedDates.contains(cursor);
    if (excluded) {
      crossedExcludedDay = true;
      logicalEnd = logicalEnd.add(const Duration(days: 1));
    }
    cursor = DateTime.utc(cursor.year, cursor.month, cursor.day + 1);
  }
  if (!cursor.isAfter(logicalEnd)) {
    invalid(line, tr("Task duration exceeds the supported range"));
  }
  if (!crossedExcludedDay) return (end: logicalEnd, renderEnd: null);

  final rawEndDay = _day(rawEnd);
  final rawEndExcluded =
      (excludesWeekends &&
          (rawEndDay.weekday == DateTime.saturday ||
              rawEndDay.weekday == DateTime.sunday)) ||
      excludedDates.contains(rawEndDay);
  return (end: logicalEnd, renderEnd: rawEndExcluded ? rawEnd : logicalEnd);
}
