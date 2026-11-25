import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pirc_client/pirc_client.dart';

import '../connection/data.dart';
import '../connection/hints.dart';
import '../format.dart';
import '../preferences.dart';

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
    DateUtils.dateOnly(ref.read(calendarZoneProvider).now()),
  );

  void show(CalendarView view) => state = CalendarPosition(view, state.anchor);

  /// Selects [day] in the current view.
  void select(DateTime day) =>
      state = CalendarPosition(state.view, DateUtils.dateOnly(day));

  void openDay(DateTime day) =>
      state = CalendarPosition(CalendarView.day, DateUtils.dateOnly(day));

  void today() => state = CalendarPosition(
    state.view,
    DateUtils.dateOnly(ref.read(calendarZoneProvider).now()),
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
String zoneOffset(DateTime now) => offsetText(now.timeZoneOffset);

/// [offset] as the Gateway reads a time zone (`+08:00`, `-03:30`).
String offsetText(Duration offset) {
  final sign = offset.isNegative ? '-' : '+';
  final minutes = offset.inMinutes.abs();
  String two(int n) => n.toString().padLeft(2, '0');
  return '$sign${two(minutes ~/ 60)}:${two(minutes % 60)}';
}

/// `+05:30` as a duration; null when it is not an offset.
Duration? parseOffset(String text) {
  final match = RegExp(r'^([+-])(\d{2}):(\d{2})$').firstMatch(text);
  if (match == null) return null;
  final minutes = int.parse(match[2]!) * 60 + int.parse(match[3]!);
  return Duration(minutes: match[1] == '-' ? -minutes : minutes);
}

/// The calendar's time zone (the general setting): the device's own, or a
/// fixed offset. Times are shown as "wall" [DateTime]s in that zone: local
/// [DateTime] values whose fields are the zone's date and clock time.
@immutable
class CalendarZone {
  const CalendarZone(this.fixed, this.clock);

  /// The fixed offset, or null for the device's time zone.
  final Duration? fixed;
  final DateTime Function() clock;

  /// The zone as the Gateway reads it.
  String get name => fixed == null ? zoneOffset(clock()) : offsetText(fixed!);

  /// The instant [millis] as a wall time in this zone.
  DateTime wall(int millis) {
    if (fixed == null) return DateTime.fromMillisecondsSinceEpoch(millis);
    final t = DateTime.fromMillisecondsSinceEpoch(
      millis,
      isUtc: true,
    ).add(fixed!);
    return DateTime(t.year, t.month, t.day, t.hour, t.minute, t.second);
  }

  /// The instant of the wall time [wall] in this zone.
  int epoch(DateTime wall) => fixed == null
      ? wall.millisecondsSinceEpoch
      : DateTime.utc(
          wall.year,
          wall.month,
          wall.day,
          wall.hour,
          wall.minute,
          wall.second,
        ).subtract(fixed!).millisecondsSinceEpoch;

  /// The current wall time in this zone.
  DateTime now() => wall(clock().millisecondsSinceEpoch);
}

final calendarZoneProvider = Provider<CalendarZone>((ref) {
  final saved = ref.watch(timeZoneProvider);
  return CalendarZone(
    saved == null ? null : parseOffset(saved),
    ref.watch(clockProvider),
  );
});

/// One calendar item: a personal event occurrence or an agent task run.
@immutable
class CalendarItem {
  const CalendarItem(this.json, [this.zone]);
  final Map<String, Object?> json;

  /// The zone its times are shown in; null is the device's.
  final CalendarZone? zone;

  String get id => '${json['id']}';
  bool get isEvent => json['type'] == 'event';
  String get sourceId => '${json['sourceId']}';
  String get title => '${json['title'] ?? ''}';
  bool get allDay => json['allDay'] == true;
  String? get originalStart => json['originalStart'] as String?;
  int? get revision => (json['revision'] as num?)?.toInt();
  DateTime get start => _wall(json['startAt']);
  DateTime get end => _wall(json['endAt']);

  DateTime _wall(Object? millis) {
    final value = (millis as num?)?.toInt() ?? 0;
    return zone?.wall(value) ?? DateTime.fromMillisecondsSinceEpoch(value);
  }

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
  final (from, to) = ref.watch(calendarPositionProvider.select(viewRange));
  final zone = ref.watch(calendarZoneProvider);
  final items = await CalendarApi(
    requireApi(ref),
  ).items(from: zone.epoch(from), to: zone.epoch(to), timezone: zone.name);
  return [for (final item in items) CalendarItem(item, zone)];
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
