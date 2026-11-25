import 'package:flutter/material.dart' hide DrawerButton;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:pirc_client/pirc_client.dart';
import 'package:pirc_ui/pirc_ui.dart';

import '../../l10n/app_localizations.dart';
import '../connection/data.dart';
import '../format.dart';
import '../shell/app_drawer.dart';
import 'calendar_data.dart';
import 'calendar_forms.dart';

/// Opens [item] in the content pane.
void openCalendarItem(BuildContext context, CalendarItem item) => context.go(
  Uri(path: '/calendar', queryParameters: {'open': item.id}).toString(),
);

/// Starts a new personal event at [day] (and [hour], from a long press);
/// only Save creates it.
Future<void> newEvent(
  BuildContext context,
  WidgetRef ref,
  DateTime day, {
  int? hour,
}) async {
  final start = DateTime(day.year, day.month, day.day, hour ?? 9);
  final end = start.add(const Duration(hours: 1));
  final timezone = zoneOffset(ref.read(clockProvider)());
  final spec = await showDialog<Map<String, Object?>>(
    context: context,
    builder: (_) => EventForm(
      timezone: timezone,
      initial: {
        'start': '${dateText(start)}T${timeText(start)}',
        'end': '${dateText(end)}T${timeText(end)}',
      },
    ),
  );
  if (spec == null || !context.mounted) return;
  await calendarAction(
    context,
    (api) => api.createEvent(randomId(), spec),
    ref,
  );
  ref.invalidate(calendarItemsProvider);
}

Future<void> newTask(BuildContext context, WidgetRef ref) async {
  final body = await showDialog<Map<String, Object?>>(
    context: context,
    builder: (_) => TaskForm(timezone: zoneOffset(ref.read(clockProvider)())),
  );
  if (body == null || !context.mounted) return;
  await calendarAction(context, (api) => api.createSchedule(body), ref);
  ref.invalidate(calendarItemsProvider);
}

/// The Calendar tab (D21–D24): month, week, day and list views, the time
/// zone under the title, marks by shape.
class CalendarScreen extends ConsumerWidget {
  const CalendarScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final text = Theme.of(context).textTheme;
    final position = ref.watch(calendarPositionProvider);
    final moves = ref.read(calendarPositionProvider.notifier);
    final items = ref.watch(calendarItemsProvider);
    final locale = Localizations.localeOf(context).toLanguageTag();
    final title = switch (position.view) {
      CalendarView.day => DateFormat.yMMMEd(locale).format(position.anchor),
      _ => DateFormat.yMMMM(locale).format(position.anchor),
    };
    return Scaffold(
      appBar: AppBar(
        leading: const DrawerButton(),
        centerTitle: true,
        title: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(title, style: text.titleSmall),
            Text(
              'UTC${zoneOffset(ref.read(clockProvider)())}',
              style: text.labelSmall,
            ),
          ],
        ),
        actions: [
          PopupMenuButton<String>(
            tooltip: l10n.calendarNew,
            icon: const Icon(LucideIcons.plus),
            onSelected: (what) => what == 'event'
                ? newEvent(context, ref, position.anchor)
                : newTask(context, ref),
            itemBuilder: (_) => [
              PopupMenuItem(value: 'event', child: Text(l10n.eventNew)),
              PopupMenuItem(value: 'task', child: Text(l10n.taskNew)),
            ],
          ),
        ],
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            child: Row(
              children: [
                IconButton(
                  tooltip: l10n.calendarPrevious,
                  icon: const Icon(LucideIcons.chevronLeft),
                  onPressed: () => moves.step(back: true),
                ),
                Expanded(
                  child: SegmentedButton<CalendarView>(
                    showSelectedIcon: false,
                    style: const ButtonStyle(
                      visualDensity: VisualDensity.compact,
                    ),
                    segments: [
                      ButtonSegment(
                        value: CalendarView.month,
                        label: Text(l10n.viewMonth),
                      ),
                      ButtonSegment(
                        value: CalendarView.week,
                        label: Text(l10n.viewWeek),
                      ),
                      ButtonSegment(
                        value: CalendarView.day,
                        label: Text(l10n.viewDay),
                      ),
                      ButtonSegment(
                        value: CalendarView.list,
                        label: Text(l10n.viewList),
                      ),
                    ],
                    selected: {position.view},
                    onSelectionChanged: (v) => moves.show(v.single),
                  ),
                ),
                IconButton(
                  tooltip: l10n.calendarNext,
                  icon: const Icon(LucideIcons.chevronRight),
                  onPressed: moves.step,
                ),
              ],
            ),
          ),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              onPressed: moves.today,
              child: Text(l10n.calendarToday),
            ),
          ),
          Expanded(
            child: switch (items) {
              AsyncValue(:final value?) => switch (position.view) {
                CalendarView.month => _Month(position: position, items: value),
                CalendarView.week => _Days(
                  days: _daysOf(position),
                  items: value,
                ),
                CalendarView.day => _Day(day: position.anchor, items: value),
                CalendarView.list => _Days(
                  days: _daysOf(position),
                  items: value,
                  skipEmpty: true,
                ),
              },
              AsyncValue(:final error?) when error is! NotConnected => Center(
                child: TextButton(
                  onPressed: () => ref.invalidate(calendarItemsProvider),
                  child: Text('${l10n.listFailed} ${l10n.retry}'),
                ),
              ),
              _ => const Center(child: CircularProgressIndicator()),
            },
          ),
        ],
      ),
    );
  }

  static List<DateTime> _daysOf(CalendarPosition position) {
    final (from, to) = viewRange(position);
    return [
      for (var d = from; d.isBefore(to); d = d.add(const Duration(days: 1)))
        DateUtils.dateOnly(d),
    ];
  }
}

/// A mark by shape: dot (timed event), bar (all-day event), diamond (agent
/// task), yellow diamond (missed run).
class CalendarMark extends StatelessWidget {
  const CalendarMark({super.key, required this.item});
  final CalendarItem item;

  @override
  Widget build(BuildContext context) {
    final colors = PircColorTokens.of(context);
    final l10n = AppLocalizations.of(context);
    if (!item.isEvent) {
      return Icon(
        LucideIcons.diamond,
        size: 10,
        color: item.missed
            ? colors['status.warning']
            : colors['accent.default'],
        semanticLabel: item.missed ? l10n.taskMissed : l10n.taskMark,
      );
    }
    if (item.allDay) {
      return Container(
        width: 10,
        height: 4,
        decoration: BoxDecoration(
          color: colors['accent.default'],
          borderRadius: BorderRadius.circular(2),
        ),
      );
    }
    return Container(
      width: 6,
      height: 6,
      decoration: BoxDecoration(
        color: colors['accent.default'],
        shape: BoxShape.circle,
      ),
    );
  }
}

class _ItemRow extends ConsumerWidget {
  const _ItemRow({required this.item, this.dense = false});
  final CalendarItem item;
  final bool dense;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final locale = Localizations.localeOf(context).toLanguageTag();
    return ListTile(
      dense: true,
      visualDensity: dense ? VisualDensity.compact : null,
      leading: CalendarMark(item: item),
      minLeadingWidth: 12,
      title: Text(item.title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        [
          if (item.allDay)
            l10n.eventAllDay
          else
            DateFormat.Hm(locale).format(item.start),
          if (!item.isEvent) _stateLabel(l10n, item.state),
        ].join(' · '),
      ),
      onTap: () => openCalendarItem(context, item),
    );
  }
}

String _stateLabel(AppLocalizations l10n, String? state) => switch (state) {
  'missed' => l10n.taskMissed,
  'planned' => l10n.taskPlanned,
  'running' || 'waiting_input' => l10n.stateRunning,
  'completed' => l10n.taskDone,
  'failed' => l10n.stepFailed,
  _ => state ?? '',
};

class _Month extends ConsumerWidget {
  const _Month({required this.position, required this.items});
  final CalendarPosition position;
  final List<CalendarItem> items;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = PircColorTokens.of(context);
    final text = Theme.of(context).textTheme;
    final (from, _) = viewRange(position);
    final today = DateUtils.dateOnly(ref.read(clockProvider)());
    final locale = Localizations.localeOf(context).toLanguageTag();
    return Column(
      children: [
        Row(
          children: [
            for (var i = 0; i < 7; i++)
              Expanded(
                child: Center(
                  child: Text(
                    DateFormat.E(locale).format(from.add(Duration(days: i))),
                    style: text.labelSmall,
                  ),
                ),
              ),
          ],
        ),
        Expanded(
          child: Column(
            children: [
              for (var week = 0; week < 6; week++)
                Expanded(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (var d = 0; d < 7; d++)
                        Expanded(
                          child: Builder(
                            builder: (context) {
                              final day = DateUtils.dateOnly(
                                from.add(Duration(days: week * 7 + d)),
                              );
                              final dayItems = items
                                  .where((i) => i.on(day))
                                  .toList();
                              final inMonth =
                                  day.month == position.anchor.month;
                              return InkWell(
                                key: Key('day-${dateText(day)}'),
                                onTap: () => ref
                                    .read(calendarPositionProvider.notifier)
                                    .openDay(day),
                                onLongPress: () => newEvent(context, ref, day),
                                child: Container(
                                  decoration: BoxDecoration(
                                    border: Border.all(
                                      color: colors['line.hairline'],
                                      width: 0.5,
                                    ),
                                  ),
                                  padding: const EdgeInsets.all(2),
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        '${day.day}',
                                        style: text.labelSmall?.copyWith(
                                          color: day == today
                                              ? colors['accent.default']
                                              : inMonth
                                              ? colors['text.primary']
                                              : colors['text.faint'],
                                          fontWeight: day == today
                                              ? FontWeight.w700
                                              : null,
                                        ),
                                      ),
                                      Wrap(
                                        spacing: 2,
                                        runSpacing: 2,
                                        children: [
                                          for (final item in dayItems.take(4))
                                            CalendarMark(item: item),
                                        ],
                                      ),
                                    ],
                                  ),
                                ),
                              );
                            },
                          ),
                        ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Week and list: one section per day.
class _Days extends StatelessWidget {
  const _Days({
    required this.days,
    required this.items,
    this.skipEmpty = false,
  });
  final List<DateTime> days;
  final List<CalendarItem> items;
  final bool skipEmpty;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final locale = Localizations.localeOf(context).toLanguageTag();
    final sections = [
      for (final day in days) (day, items.where((i) => i.on(day)).toList()),
    ].where((s) => !skipEmpty || s.$2.isNotEmpty).toList();
    if (sections.isEmpty) {
      return Center(child: Text(l10n.emptyCalendar));
    }
    return ListView(
      children: [
        for (final (day, dayItems) in sections) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Text(
              DateFormat.MMMEd(locale).format(day),
              style: Theme.of(context).textTheme.labelMedium,
            ),
          ),
          for (final item in dayItems) _ItemRow(item: item, dense: true),
        ],
      ],
    );
  }
}

/// Day: all-day items, then one row per hour; a long press on an hour
/// opens a draft there.
class _Day extends ConsumerWidget {
  const _Day({required this.day, required this.items});
  final DateTime day;
  final List<CalendarItem> items;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final dayItems = items.where((i) => i.on(day)).toList();
    final colors = PircColorTokens.of(context);
    return ListView(
      children: [
        for (final item in dayItems.where((i) => i.allDay))
          _ItemRow(item: item),
        for (var hour = 0; hour < 24; hour++)
          InkWell(
            key: Key('hour-$hour'),
            onLongPress: () => newEvent(context, ref, day, hour: hour),
            child: Container(
              constraints: const BoxConstraints(minHeight: 44),
              decoration: BoxDecoration(
                border: Border(top: BorderSide(color: colors['line.hairline'])),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 52,
                    child: Padding(
                      padding: const EdgeInsets.all(4),
                      child: Text(
                        '${hour.toString().padLeft(2, '0')}:00',
                        style: Theme.of(context).textTheme.labelSmall,
                      ),
                    ),
                  ),
                  Expanded(
                    child: Column(
                      children: [
                        for (final item in dayItems.where(
                          (i) =>
                              !i.allDay &&
                              DateUtils.isSameDay(i.start, day) &&
                              i.start.hour == hour,
                        ))
                          _ItemRow(item: item, dense: true),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}
