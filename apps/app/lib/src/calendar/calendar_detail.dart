import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:pirc_client/pirc_client.dart';

import '../../l10n/app_localizations.dart';
import '../connection/data.dart';
import 'calendar_data.dart';
import 'calendar_forms.dart';

/// An agent task as `/api/schedules/{id}` shows it, with its runs.
final _scheduleProvider = FutureProvider.autoDispose
    .family<Map<String, Object?>, String>((ref, id) {
      ref.watch(schedulesProvider);
      return CalendarApi(requireApi(ref)).schedule(id);
    });

/// The open calendar item: an event occurrence or an agent task run.
class CalendarDetail extends ConsumerWidget {
  const CalendarDetail({
    super.key,
    required this.itemId,
    this.showBack = true,
    this.askSkip = false,
  });
  final String itemId;
  final bool showBack;

  /// Opened from "Skip…" on a missed-run notification (`action=skip`): asks
  /// once whether to skip the run. Nothing is skipped without that answer.
  final bool askSkip;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final items = ref.watch(calendarItemsProvider).value ?? const [];
    final item = items.where((i) => i.id == itemId).firstOrNull;
    void close() => context.go('/calendar');
    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: false,
        leading: showBack
            ? IconButton(
                tooltip: l10n.back,
                icon: const Icon(LucideIcons.chevronLeft),
                onPressed: close,
              )
            : null,
        title: Text(item?.title ?? ''),
      ),
      body: item == null
          ? Center(child: Text(l10n.calendarItemGone))
          : item.isEvent
          ? _EventDetail(item: item, onGone: close)
          : _SkipAsker(
              item: item,
              ask: askSkip && item.missed,
              child: _TaskDetail(item: item, onGone: close),
            ),
    );
  }
}

class _EventDetail extends ConsumerWidget {
  const _EventDetail({required this.item, required this.onGone});
  final CalendarItem item;
  final VoidCallback onGone;

  Future<void> _edit(BuildContext context, WidgetRef ref) async {
    final api = CalendarApi(ref.read(apiProvider)!);
    // The item holds this occurrence; the series comes from the event.
    final event = await api.event(item.sourceId);
    if (!context.mounted) return;
    final occurrence = item.event ?? event;
    final spec = await showDialog<Map<String, Object?>>(
      context: context,
      builder: (_) => EventForm(
        timezone: '${event['timezone'] ?? ref.read(calendarZoneProvider).name}',
        initial: {...occurrence, 'recurrence': event['recurrence']},
      ),
    );
    if (spec == null || !context.mounted) return;
    final scope = event['recurrence'] == null
        ? 'series'
        : await askRepeatScope(context);
    if (scope == null || !context.mounted) return;
    await calendarAction(
      context,
      (api) => api.updateEvent(
        item.sourceId,
        revision: (event['revision'] as num?)?.toInt() ?? item.revision ?? 0,
        spec: spec,
        scope: scope,
        occurrence: scope == 'series' ? null : item.originalStart,
      ),
      ref,
    );
    ref.invalidate(calendarItemsProvider);
  }

  Future<void> _delete(BuildContext context, WidgetRef ref) async {
    final l10n = AppLocalizations.of(context);
    final event = await CalendarApi(
      ref.read(apiProvider)!,
    ).event(item.sourceId);
    if (!context.mounted) return;
    String? scope;
    if (event['recurrence'] != null) {
      scope = await askRepeatScope(context);
    } else {
      final sure = await showDialog<bool>(
        context: context,
        builder: (dialog) => AlertDialog(
          title: Text(l10n.eventDeleteTitle),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialog, false),
              child: Text(l10n.cancel),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialog, true),
              child: Text(l10n.delete),
            ),
          ],
        ),
      );
      if (sure == true) scope = 'series';
    }
    if (scope == null || !context.mounted) return;
    await calendarAction(
      context,
      (api) => api.deleteEvent(
        item.sourceId,
        revision: (event['revision'] as num?)?.toInt() ?? 0,
        scope: scope!,
        occurrence: scope == 'series' ? null : item.originalStart,
      ),
      ref,
    );
    ref.invalidate(calendarItemsProvider);
    onGone();
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final locale = Localizations.localeOf(context).toLanguageTag();
    final event = item.event ?? const {};
    final time = item.allDay
        ? l10n.eventAllDay
        : '${DateFormat.MMMEd(locale).add_Hm().format(item.start)} – '
              '${DateFormat.Hm(locale).format(item.end)}';
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        ListTile(leading: const Icon(LucideIcons.clock), title: Text(time)),
        if (item.recurring)
          ListTile(
            leading: const Icon(LucideIcons.repeat),
            title: Text(l10n.eventRepeats),
          ),
        if ('${event['location'] ?? ''}'.isNotEmpty)
          ListTile(
            leading: const Icon(LucideIcons.mapPin),
            title: Text('${event['location']}'),
          ),
        if ('${event['description'] ?? ''}'.isNotEmpty)
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text('${event['description']}'),
          ),
        Wrap(
          spacing: 8,
          children: [
            FilledButton.tonal(
              onPressed: () => _edit(context, ref),
              child: Text(l10n.eventEdit),
            ),
            TextButton(
              onPressed: () => _delete(context, ref),
              child: Text(l10n.delete),
            ),
          ],
        ),
      ],
    );
  }
}

/// With [ask], asks once whether to skip [item], a missed run, and takes
/// `action=skip` out of the location so Back or a rebuild does not ask again.
/// It stays in the tree either way, so the answer still applies after the
/// location changed.
class _SkipAsker extends ConsumerStatefulWidget {
  const _SkipAsker({
    required this.item,
    required this.ask,
    required this.child,
  });
  final CalendarItem item;
  final bool ask;
  final Widget child;

  @override
  ConsumerState<_SkipAsker> createState() => _SkipAskerState();
}

class _SkipAskerState extends ConsumerState<_SkipAsker> {
  @override
  void initState() {
    super.initState();
    if (widget.ask) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _ask());
    }
  }

  Future<void> _ask() async {
    if (!mounted) return;
    final here = GoRouterState.of(context).uri;
    context.go(
      here
          .replace(queryParameters: {...here.queryParameters}..remove('action'))
          .toString(),
    );
    final l10n = AppLocalizations.of(context);
    final skip = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.taskSkipAsk),
        content: Text(l10n.taskSkipAskNote),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(l10n.cancel),
          ),
          FilledButton(
            key: const Key('confirm-skip'),
            onPressed: () => Navigator.pop(context, true),
            child: Text(l10n.taskDismiss),
          ),
        ],
      ),
    );
    if (skip != true || !mounted) return;
    final run = widget.item.run;
    await calendarAction(
      context,
      (api) => api.dismiss(widget.item.sourceId, '${run?['id']}'),
      ref,
    );
    ref.invalidate(calendarItemsProvider);
    ref.invalidate(schedulesProvider);
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

class _TaskDetail extends ConsumerWidget {
  const _TaskDetail({required this.item, required this.onGone});
  final CalendarItem item;
  final VoidCallback onGone;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final value = ref.watch(_scheduleProvider(item.sourceId));
    final schedule =
        (value.value?['schedule'] as Map?)?.cast<String, Object?>() ??
        item.schedule;
    final status = schedule?['status'];
    final gone = value.hasValue && targetGone(schedule);
    final run = item.run;
    Future<void> act(Future<Object?> Function(CalendarApi api) action) async {
      await calendarAction(context, action, ref);
      ref.invalidate(calendarItemsProvider);
      ref.invalidate(schedulesProvider);
    }

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        if (item.missed) ...[
          // A missed run never runs again without a choice.
          ListTile(
            leading: const Icon(LucideIcons.diamond),
            title: Text(l10n.taskMissed),
            subtitle: Text('${run?['result'] ?? ''}'),
          ),
          Wrap(
            spacing: 8,
            children: [
              FilledButton(
                onPressed: () => act(
                  (api) => api.run(item.sourceId, runId: '${run?['id']}'),
                ),
                child: Text(l10n.taskAllowRun),
              ),
              TextButton(
                onPressed: () =>
                    act((api) => api.dismiss(item.sourceId, '${run?['id']}')),
                child: Text(l10n.taskDismiss),
              ),
            ],
          ),
          const Divider(),
        ],
        if (gone)
          ListTile(
            leading: const Icon(LucideIcons.circlePause),
            title: Text(l10n.taskTargetGone),
          )
        else if (status == 'paused')
          ListTile(
            leading: const Icon(LucideIcons.circlePause),
            title: Text(l10n.taskPaused),
          ),
        ListTile(
          leading: const Icon(LucideIcons.folder),
          title: Text(
            '${(schedule?['workspace'] as Map?)?['name'] ?? schedule?['workspaceId'] ?? ''}',
          ),
        ),
        ListTile(
          leading: const Icon(LucideIcons.clock),
          title: Text('${schedule?['cron'] ?? ''}'),
          subtitle: Text(_stateText(l10n, item.state)),
        ),
        if ('${schedule?['prompt'] ?? ''}'.isNotEmpty)
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text('${schedule?['prompt']}'),
          ),
        Wrap(
          spacing: 8,
          children: [
            if (!gone && status == 'active')
              FilledButton.tonal(
                onPressed: () => act((api) => api.run(item.sourceId)),
                child: Text(l10n.taskRunNow),
              ),
            if (!gone)
              TextButton(
                onPressed: () => act(
                  (api) => api.updateSchedule(item.sourceId, {
                    'status': status == 'paused' ? 'active' : 'paused',
                  }),
                ),
                child: Text(
                  status == 'paused' ? l10n.taskResume : l10n.taskPause,
                ),
              ),
            TextButton(
              onPressed: value.hasValue
                  ? () async {
                      final body = await showDialog<Map<String, Object?>>(
                        context: context,
                        builder: (_) => TaskForm(
                          schedule: schedule,
                          timezone: ref.read(calendarZoneProvider).name,
                        ),
                      );
                      if (body == null) return;
                      await act(
                        (api) => api.updateSchedule(item.sourceId, {
                          ...body,
                          // A task paused by a gone target resumes with a
                          // new one.
                          if (gone) 'status': 'active',
                        }),
                      );
                    }
                  : null,
              child: Text(l10n.taskEdit),
            ),
            TextButton(
              onPressed: () async {
                await act((api) => api.deleteSchedule(item.sourceId));
                onGone();
              },
              child: Text(l10n.delete),
            ),
          ],
        ),
      ],
    );
  }

  static String _stateText(AppLocalizations l10n, String? state) =>
      switch (state) {
        'missed' => l10n.taskMissed,
        'planned' => l10n.taskPlanned,
        'completed' => l10n.taskDone,
        'failed' => l10n.stepFailed,
        'running' || 'waiting_input' => l10n.stateRunning,
        _ => state ?? '',
      };
}
