import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pirc_client/pirc_client.dart';

import '../../l10n/app_localizations.dart';
import '../connection/data.dart';

String _two(int n) => n.toString().padLeft(2, '0');
String dateText(DateTime d) => '${d.year}-${_two(d.month)}-${_two(d.day)}';
String timeText(DateTime d) => '${_two(d.hour)}:${_two(d.minute)}';

/// The repeat scope of an edit or delete of a repeating event: this one,
/// this and later, or the whole series.
Future<String?> askRepeatScope(BuildContext context) {
  final l10n = AppLocalizations.of(context);
  return showModalBottomSheet<String>(
    context: context,
    showDragHandle: true,
    builder: (sheet) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final (scope, label) in [
            ('occurrence', l10n.scopeOccurrence),
            ('following', l10n.scopeFollowing),
            ('series', l10n.scopeSeries),
          ])
            ListTile(
              title: Text(label),
              onTap: () => Navigator.pop(sheet, scope),
            ),
        ],
      ),
    ),
  );
}

/// A personal event form (D25). Only Save changes the event; [initial] is
/// the event (edit) or a draft from a long press (new).
class EventForm extends StatefulWidget {
  const EventForm({super.key, required this.initial, required this.timezone});

  /// A spec: title, start, end, allDay, recurrence, location, description.
  final Map<String, Object?> initial;
  final String timezone;

  @override
  State<EventForm> createState() => _EventFormState();
}

class _EventFormState extends State<EventForm> {
  late final _title = TextEditingController(
    text: '${widget.initial['title'] ?? ''}',
  );
  late final _location = TextEditingController(
    text: '${widget.initial['location'] ?? ''}',
  );
  late final _description = TextEditingController(
    text: '${widget.initial['description'] ?? ''}',
  );
  late bool _allDay = widget.initial['allDay'] == true;
  late final _startDate = TextEditingController(
    text: _part(widget.initial['start'], 0),
  );
  late final _startTime = TextEditingController(
    text: _part(widget.initial['start'], 1),
  );
  late final _endDate = TextEditingController(
    text: _part(widget.initial['end'], 0),
  );
  late final _endTime = TextEditingController(
    text: _part(widget.initial['end'], 1),
  );
  late String _repeat =
      ((widget.initial['recurrence'] as Map?)?['frequency'] as String?) ??
      'none';

  static String _part(Object? value, int index) {
    final parts = '${value ?? ''}'.split('T');
    return index < parts.length ? parts[index] : (index == 1 ? '09:00' : '');
  }

  @override
  void dispose() {
    for (final c in [
      _title,
      _location,
      _description,
      _startDate,
      _startTime,
      _endDate,
      _endTime,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  Map<String, Object?> get _spec => {
    'title': _title.text.trim(),
    'start': _allDay
        ? _startDate.text
        : '${_startDate.text}T${_startTime.text}',
    'end': _allDay ? _endDate.text : '${_endDate.text}T${_endTime.text}',
    'timezone': widget.timezone,
    'allDay': _allDay,
    'recurrence': _repeat == 'none'
        ? null
        : {
            'frequency': _repeat,
            ...?((widget.initial['recurrence'] as Map?)?['frequency'] == _repeat
                ? (widget.initial['recurrence'] as Map).cast<String, Object?>()
                : null),
          },
    'location': _location.text,
    'description': _description.text,
  };

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    Widget field(String key, TextEditingController c, String label) => Expanded(
      child: TextField(
        key: Key(key),
        controller: c,
        decoration: InputDecoration(labelText: label),
      ),
    );
    return AlertDialog(
      title: Text(
        widget.initial['title'] == null ? l10n.eventNew : l10n.eventEdit,
      ),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                key: const Key('event-title'),
                controller: _title,
                decoration: InputDecoration(labelText: l10n.eventTitle),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(l10n.eventAllDay),
                value: _allDay,
                onChanged: (v) => setState(() => _allDay = v),
              ),
              Row(
                children: [
                  field('event-start-date', _startDate, l10n.eventStart),
                  if (!_allDay) ...[
                    const SizedBox(width: 8),
                    field('event-start-time', _startTime, l10n.eventTime),
                  ],
                ],
              ),
              Row(
                children: [
                  field('event-end-date', _endDate, l10n.eventEnd),
                  if (!_allDay) ...[
                    const SizedBox(width: 8),
                    field('event-end-time', _endTime, l10n.eventTime),
                  ],
                ],
              ),
              DropdownButtonFormField<String>(
                key: const Key('event-repeat'),
                initialValue: _repeat,
                decoration: InputDecoration(labelText: l10n.eventRepeat),
                items: [
                  for (final (value, label) in [
                    ('none', l10n.repeatNone),
                    ('daily', l10n.repeatDaily),
                    ('weekly', l10n.repeatWeekly),
                    ('monthly', l10n.repeatMonthly),
                    ('yearly', l10n.repeatYearly),
                  ])
                    DropdownMenuItem(value: value, child: Text(label)),
                ],
                onChanged: (v) => setState(() => _repeat = v ?? 'none'),
              ),
              TextField(
                controller: _location,
                decoration: InputDecoration(labelText: l10n.eventLocation),
              ),
              TextField(
                controller: _description,
                maxLines: 3,
                decoration: InputDecoration(labelText: l10n.eventNotes),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(l10n.cancel),
        ),
        FilledButton(
          onPressed: () {
            if (_title.text.trim().isEmpty) return;
            Navigator.pop(context, _spec);
          },
          child: Text(l10n.save),
        ),
      ],
    );
  }
}

/// An agent task form (D27): what to do, where, and when. A task whose
/// target is gone keeps Save disabled until a new target is picked.
class TaskForm extends ConsumerStatefulWidget {
  const TaskForm({super.key, this.schedule, required this.timezone});

  /// The task to edit (a `/api/schedules` view), or null for a new one.
  final Map<String, Object?>? schedule;
  final String timezone;

  @override
  ConsumerState<TaskForm> createState() => _TaskFormState();
}

class _TaskFormState extends ConsumerState<TaskForm> {
  late final _title = TextEditingController(
    text: '${widget.schedule?['title'] ?? ''}',
  );
  late final _prompt = TextEditingController(
    text: '${widget.schedule?['prompt'] ?? ''}',
  );
  late final _cron = TextEditingController(
    text: '${widget.schedule?['cron'] ?? '0 9 * * *'}',
  );
  late final _at = TextEditingController();
  late bool _repeat =
      widget.schedule == null || widget.schedule?['cron'] != null;
  late String? _workspace = _initialWorkspace();

  String? _initialWorkspace() {
    final workspace = widget.schedule?['workspace'];
    // A gone target is not offered: the user must pick a new one.
    if (workspace is Map && workspace['available'] == true) {
      return '${workspace['id']}';
    }
    return null;
  }

  @override
  void dispose() {
    _title.dispose();
    _prompt.dispose();
    _cron.dispose();
    _at.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final workspaces =
        ref.watch(workspacesProvider).value ?? const <WorkspaceInfo>[];
    final canSave =
        _workspace != null &&
        _prompt.text.trim().isNotEmpty &&
        (_repeat ? _cron.text.trim().isNotEmpty : _at.text.trim().isNotEmpty);
    return AlertDialog(
      title: Text(widget.schedule == null ? l10n.taskNew : l10n.taskEdit),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                key: const Key('task-title'),
                controller: _title,
                decoration: InputDecoration(labelText: l10n.eventTitle),
              ),
              TextField(
                key: const Key('task-prompt'),
                controller: _prompt,
                maxLines: 4,
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(labelText: l10n.taskPrompt),
              ),
              DropdownButtonFormField<String>(
                key: const Key('task-target'),
                initialValue: _workspace,
                hint: Text(l10n.taskPickTarget),
                isExpanded: true,
                items: [
                  for (final w in workspaces)
                    DropdownMenuItem(
                      value: w.id,
                      child: Text('${w.displayName} · ${w.nodeId}'),
                    ),
                ],
                onChanged: (v) => setState(() => _workspace = v),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(l10n.taskRepeats),
                value: _repeat,
                onChanged: (v) => setState(() => _repeat = v),
              ),
              if (_repeat)
                TextField(
                  key: const Key('task-cron'),
                  controller: _cron,
                  onChanged: (_) => setState(() {}),
                  decoration: InputDecoration(
                    labelText: l10n.taskCron,
                    helperText: l10n.taskCronHelp,
                  ),
                )
              else
                TextField(
                  key: const Key('task-at'),
                  controller: _at,
                  onChanged: (_) => setState(() {}),
                  decoration: InputDecoration(
                    labelText: l10n.taskAt,
                    hintText: 'YYYY-MM-DDTHH:mm',
                  ),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(l10n.cancel),
        ),
        FilledButton(
          key: const Key('task-save'),
          onPressed: canSave
              ? () => Navigator.pop(context, {
                  'workspaceId': _workspace,
                  'prompt': _prompt.text.trim(),
                  if (_title.text.trim().isNotEmpty)
                    'title': _title.text.trim(),
                  'timezone': widget.timezone,
                  if (_repeat)
                    'cron': _cron.text.trim()
                  else
                    'at': _at.text.trim(),
                })
              : null,
          child: Text(l10n.save),
        ),
      ],
    );
  }
}

/// Creates or edits through [run], showing a refusal.
Future<void> calendarAction(
  BuildContext context,
  Future<Object?> Function(CalendarApi api) run,
  WidgetRef ref,
) async {
  final l10n = AppLocalizations.of(context);
  try {
    await run(CalendarApi(ref.read(apiProvider)!));
  } on PircException catch (error) {
    if (context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l10n.actionFailed(error.message))));
    }
  }
}
