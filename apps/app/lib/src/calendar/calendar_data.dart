import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pirc_client/pirc_client.dart';

import '../connection/data.dart';
import '../connection/hints.dart';
import '../format.dart';

enum CalendarView { month, week, day, list }

@immutable
class CalendarPosition {
  const CalendarPosition(this.view, this.anchor);
  final CalendarView view;

  /// A day in the shown range (local date, no time).
  final DateTime anchor;
}

final calendarPositionProvider =
    NotifierProvider<CalendarPositionNotifier, CalendarPosition>(
      CalendarPositionNotifier.new,
    );

class CalendarPositionNotifier extends Notifier<CalendarPosition> {
  @override
  CalendarPosition build() => CalendarPosition(
    CalendarView.month,
    DateUtils.dateOnly(ref.read(clockProvider)()),
  );

  void show(CalendarView view) => state = CalendarPosition(view, state.anchor);

  void openDay(DateTime day) =>
      state = CalendarPosition(CalendarView.day, DateUtils.dateOnly(day));

  void today() => state = CalendarPosition(
    state.view,
    DateUtils.dateOnly(ref.read(clockProvider)()),
  );

  /// The next (or, with [back], the previous) range.
  void step({bool back = false}) {
    final a = state.anchor;
    final sign = back ? -1 : 1;
    final next = switch (state.view) {
      CalendarView.month => DateTime(a.year, a.month + sign, 1),
      CalendarView.week => a.add(Duration(days: 7 * sign)),
      CalendarView.day => a.add(Duration(days: sign)),
      CalendarView.list => a.add(Duration(days: 30 * sign)),
    };
    state = CalendarPosition(state.view, DateUtils.dateOnly(next));
  }
}

/// The first and last+1 day a view shows. Weeks start on Sunday.
(DateTime, DateTime) viewRange(CalendarPosition position) {
  final a = position.anchor;
  DateTime weekStart(DateTime d) => d.subtract(Duration(days: d.weekday % 7));
  return switch (position.view) {
    CalendarView.month => (
      weekStart(DateTime(a.year, a.month, 1)),
      weekStart(DateTime(a.year, a.month, 1)).add(const Duration(days: 42)),
    ),
    CalendarView.week => (
      weekStart(a),
      weekStart(a).add(const Duration(days: 7)),
    ),
    CalendarView.day => (a, a.add(const Duration(days: 1))),
    CalendarView.list => (a, a.add(const Duration(days: 30))),
  };
}

/// This device's offset as the Gateway reads a time zone (`+08:00`).
String zoneOffset(DateTime now) {
  final offset = now.timeZoneOffset;
  final sign = offset.isNegative ? '-' : '+';
  final minutes = offset.inMinutes.abs();
  String two(int n) => n.toString().padLeft(2, '0');
  return '$sign${two(minutes ~/ 60)}:${two(minutes % 60)}';
}

/// One calendar item: a personal event occurrence or an agent task run.
@immutable
class CalendarItem {
  const CalendarItem(this.json);
  final Map<String, Object?> json;

  String get id => '${json['id']}';
  bool get isEvent => json['type'] == 'event';
  String get sourceId => '${json['sourceId']}';
  String get title => '${json['title'] ?? ''}';
  bool get allDay => json['allDay'] == true;
  String? get originalStart => json['originalStart'] as String?;
  int? get revision => (json['revision'] as num?)?.toInt();
  DateTime get start => DateTime.fromMillisecondsSinceEpoch(
    (json['startAt'] as num?)?.toInt() ?? 0,
  );
  DateTime get end => DateTime.fromMillisecondsSinceEpoch(
    (json['endAt'] as num?)?.toInt() ?? 0,
  );

  /// Run state for tasks: planned, running, waiting_input, completed,
  /// failed, missed, dismissed, skipped.
  String? get state => json['state'] as String?;
  bool get missed => state == 'missed';
  Map<String, Object?>? get schedule =>
      (json['schedule'] as Map?)?.cast<String, Object?>();
  Map<String, Object?>? get run =>
      (json['run'] as Map?)?.cast<String, Object?>();
  Map<String, Object?>? get event =>
      (json['event'] as Map?)?.cast<String, Object?>();
  bool get recurring => event?['recurrence'] != null;

  /// The days it covers (all-day `endDate` is exclusive).
  bool on(DateTime day) {
    final d = DateUtils.dateOnly(day);
    if (allDay && json['startDate'] is String && json['endDate'] is String) {
      final s = DateTime.parse('${json['startDate']}');
      final e = DateTime.parse('${json['endDate']}');
      return !d.isBefore(s) && d.isBefore(e);
    }
    final s = DateUtils.dateOnly(start);
    final e = DateUtils.dateOnly(end);
    return !d.isBefore(s) && !d.isAfter(e);
  }
}

/// The items of the shown range; read again on `schedules_changed` (which
/// the Gateway also sends for calendar changes).
final calendarItemsProvider = FutureProvider<List<CalendarItem>>((ref) async {
  watchHint(ref, 'schedules_changed');
  final position = ref.watch(calendarPositionProvider);
  final (from, to) = viewRange(position);
  final items = await CalendarApi(requireApi(ref)).items(
    from: from.millisecondsSinceEpoch,
    to: to.millisecondsSinceEpoch,
    timezone: zoneOffset(ref.read(clockProvider)()),
  );
  return [for (final item in items) CalendarItem(item)];
});

/// Agent tasks, for the task list and forms; read again on
/// `schedules_changed`.
final schedulesProvider = FutureProvider<List<Map<String, Object?>>>((ref) {
  watchHint(ref, 'schedules_changed');
  return CalendarApi(requireApi(ref)).schedules();
});

/// A task whose target project is gone: the Gateway pauses it and lists its
/// workspace without `mode`/`available`.
bool targetGone(Map<String, Object?>? schedule) {
  final workspace = schedule?['workspace'];
  return workspace == null ||
      (workspace is Map &&
          (!workspace.containsKey('available') ||
              workspace['available'] == false));
}
