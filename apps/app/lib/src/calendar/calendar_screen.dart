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
            Text(l10n.tabCalendar, style: text.titleSmall),
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
            padding: const EdgeInsets.fromLTRB(16, 4, 8, 4),
            child: Row(
              children: [
                Expanded(child: Text(title, style: text.titleLarge)),
                IconButton(
                  tooltip: l10n.calendarPrevious,
                  icon: const Icon(LucideIcons.chevronLeft),
                  onPressed: () => moves.step(back: true),
                ),
                IconButton(
                  tooltip: l10n.calendarNext,
                  icon: const Icon(LucideIcons.chevronRight),
                  onPressed: moves.step,
                ),
                FilledButton.tonal(
                  onPressed: moves.today,
                  child: Text(l10n.calendarToday),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: SegmentedButton<CalendarView>(
              showSelectedIcon: false,
              style: const ButtonStyle(visualDensity: VisualDensity.compact),
              segments: [
                for (final (view, label) in [
                  (CalendarView.month, l10n.viewMonth),
                  (CalendarView.week, l10n.viewWeek),
                  (CalendarView.day, l10n.viewDay),
                  (CalendarView.list, l10n.viewList),
                ])
                  ButtonSegment(
                    value: view,
                    label: Text(label, maxLines: 1, softWrap: false),
                  ),
              ],
              selected: {position.view},
              onSelectionChanged: (v) => moves.show(v.single),
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
      return Semantics(
        label: item.missed ? l10n.taskMissed : l10n.taskMark,
        child: Transform.rotate(
          angle: 0.785398,
          child: Container(
            width: 7,
            height: 7,
            color: item.missed
                ? colors['status.warning']
                : colors['text.primary'],
          ),
        ),
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

/// Month (D21): a compact grid with marks by shape, a legend, then the
/// selected day's items. A tap selects a day; a long press opens a draft.
class _Month extends ConsumerWidget {
  const _Month({required this.position, required this.items});
  final CalendarPosition position;
  final List<CalendarItem> items;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final colors = PircColorTokens.of(context);
    final text = Theme.of(context).textTheme;
    final (from, _) = viewRange(position);
    final today = DateUtils.dateOnly(ref.read(clockProvider)());
    final locale = Localizations.localeOf(context).toLanguageTag();
    final selected = position.anchor;
    final selectedItems = items.where((i) => i.on(selected)).toList()
      ..sort((a, b) => a.start.compareTo(b.start));
    Widget legend(Widget mark, String label) => Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        mark,
        const SizedBox(width: 6),
        Text(label, style: text.bodySmall),
      ],
    );
    return ListView(
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
        for (var week = 0; week < 6; week++)
          Row(
            children: [
              for (var d = 0; d < 7; d++)
                Expanded(
                  child: Builder(
                    builder: (context) {
                      final day = DateUtils.dateOnly(
                        from.add(Duration(days: week * 7 + d)),
                      );
                      final dayItems = items.where((i) => i.on(day)).toList();
                      final inMonth = day.month == position.anchor.month;
                      final isSelected = day == selected;
                      return InkWell(
                        key: Key('day-${dateText(day)}'),
                        onTap: () => ref
                            .read(calendarPositionProvider.notifier)
                            .select(day),
                        onLongPress: () => newEvent(context, ref, day),
                        child: SizedBox(
                          height: 56,
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Container(
                                width: 30,
                                height: 30,
                                alignment: Alignment.center,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: isSelected
                                      ? colors['action.primary']
                                      : null,
                                ),
                                child: Text(
                                  '${day.day}',
                                  style: text.bodyMedium?.copyWith(
                                    color: isSelected
                                        ? colors['action.onPrimary']
                                        : day == today
                                        ? colors['accent.default']
                                        : inMonth
                                        ? colors['text.primary']
                                        : colors['text.faint'],
                                    fontWeight: day == today || isSelected
                                        ? FontWeight.w600
                                        : null,
                                  ),
                                ),
                              ),
                              const SizedBox(height: 4),
                              SizedBox(
                                height: 8,
                                child: Row(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    for (final item in dayItems.take(3))
                                      Padding(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 1.5,
                                        ),
                                        child: CalendarMark(item: item),
                                      ),
                                  ],
                                ),
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
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          child: Wrap(
            spacing: 16,
            runSpacing: 4,
            children: [
              legend(
                CalendarMark(item: CalendarItem(const {'type': 'event'})),
                l10n.legendEvent,
              ),
              legend(
                CalendarMark(
                  item: CalendarItem(const {'type': 'event', 'allDay': true}),
                ),
                l10n.eventAllDay,
              ),
              legend(
                CalendarMark(item: CalendarItem(const {'type': 'schedule'})),
                l10n.taskMark,
              ),
              legend(
                CalendarMark(
                  item: CalendarItem(const {
                    'type': 'schedule',
                    'state': 'missed',
                  }),
                ),
                l10n.taskMissed,
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: Text(
            l10n.calendarDayCount(
              DateFormat.MMMEd(locale).format(selected),
              selectedItems.length,
            ),
            style: text.titleMedium,
          ),
        ),
        if (selectedItems.isEmpty)
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(l10n.emptyCalendar, style: text.bodySmall),
          ),
        for (final item in selectedItems) _ItemRow(item: item),
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
