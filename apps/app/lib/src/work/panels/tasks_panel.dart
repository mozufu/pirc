import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:pirc_client/pirc_client.dart';
import 'package:pirc_ui/pirc_ui.dart';

import '../../../l10n/app_localizations.dart';
import '../../connection/data.dart';
import 'panel_common.dart';
import '../labels.dart';

PanelKey _state(String sessionId) =>
    panelKey(sessionId, 'panel/state', sections: const ['background', 'team']);

/// 10c. Tasks: background tasks and teammates from `…/panel/state`; a task's
/// output from `…/panel/background/:taskId` and its Stop (lease).
class TasksPanel extends ConsumerStatefulWidget {
  const TasksPanel({super.key, required this.sessionId});
  final String sessionId;

  @override
  ConsumerState<TasksPanel> createState() => _TasksPanelState();
}

class _TasksPanelState extends ConsumerState<TasksPanel> {
  String? _task;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final id = widget.sessionId;
    final task = _task;
    if (task != null) {
      return _TaskDetail(
        sessionId: id,
        taskId: task,
        onBack: () => setState(() => _task = null),
      );
    }
    final key = _state(id);
    return PanelBody<Object?>(
      value: ref.watch(panelReadProvider(key)),
      onRetry: () => ref.invalidate(panelReadProvider(key)),
      emptyText: l10n.tasksEmpty,
      isEmpty: (d) {
        final data = d as Map?;
        return ((data?['backgroundTasks'] as List?)?.isEmpty ?? true) &&
            ((field(data?['team'], 'agents') as List?)?.isEmpty ?? true);
      },
      builder: (d) {
        final data = d! as Map;
        final tasks = (data['backgroundTasks'] as List? ?? const [])
            .cast<Map>();
        final agents = (field(data['team'], 'agents') as List? ?? const [])
            .cast<Map>();
        return ListView(
          children: [
            if (tasks.isNotEmpty) _Section(l10n.tasksBackground),
            for (final task in tasks)
              ListTile(
                dense: true,
                leading: StateDot(switch (task['status']) {
                  'running' || 'stopping' => DotState.running,
                  'completed' => DotState.done,
                  'failed' || 'timed_out' => DotState.failed,
                  _ => DotState.idle,
                }),
                title: Text(
                  '${task['command']}',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontFamily: 'monospace'),
                ),
                subtitle: Text(l10n.taskStatus('${task['status']}')),
                onTap: () => setState(() => _task = '${task['id']}'),
              ),
            if (agents.isNotEmpty) _Section(l10n.tasksTeam),
            for (final agent in agents)
              ListTile(
                dense: true,
                leading: const Icon(LucideIcons.bot, size: 18),
                title: Text('${agent['name'] ?? agent['id'] ?? ''}'),
                subtitle: Text(
                  [
                    if (agent['status'] != null)
                      l10n.taskStatus('${agent['status']}'),
                    if (agent['task'] != null) '${agent['task']}',
                  ].join(' · '),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
          ],
        );
      },
    );
  }
}

Object? field(Object? value, String key) => value is Map ? value[key] : null;

class _Section extends StatelessWidget {
  const _Section(this.title);
  final String title;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
    child: Text(title, style: Theme.of(context).textTheme.labelMedium),
  );
}

class _TaskDetail extends ConsumerWidget {
  const _TaskDetail({
    required this.sessionId,
    required this.taskId,
    required this.onBack,
  });

  final String sessionId;
  final String taskId;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final colors = PircColorTokens.of(context);
    final key = panelKey(
      sessionId,
      'panel/background/${Uri.encodeComponent(taskId)}',
      sections: const ['background'],
    );
    final value = ref.watch(panelReadProvider(key));
    final control = canControl(ref, sessionId);
    final status = field(field(value.value, 'task'), 'status');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            IconButton(
              tooltip: l10n.back,
              icon: const Icon(LucideIcons.chevronLeft),
              onPressed: onBack,
            ),
            const Spacer(),
            if (status == 'running')
              TextButton.icon(
                onPressed: control
                    ? () async {
                        final body = leaseBody(ref, sessionId);
                        if (body == null) return;
                        try {
                          await ref
                              .read(apiProvider)!
                              .post(
                                sessionPath(
                                  sessionId,
                                  'panel/background/${Uri.encodeComponent(taskId)}/stop',
                                ),
                                body,
                              );
                        } on PircException catch (error) {
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text(l10n.actionFailed(error.message)),
                              ),
                            );
                          }
                        }
                        ref.invalidate(panelReadProvider(key));
                      }
                    : null,
                icon: const Icon(LucideIcons.square, size: 14),
                label: Text(l10n.tasksStop),
              ),
          ],
        ),
        if (!control) ReadOnlyNote(sessionId: sessionId),
        Expanded(
          child: PanelBody<Object?>(
            value: value,
            onRetry: () => ref.invalidate(panelReadProvider(key)),
            emptyText: l10n.tasksNoOutput,
            isEmpty: (d) => '${field(d, 'output') ?? ''}'.isEmpty,
            builder: (d) => SingleChildScrollView(
              padding: const EdgeInsets.all(12),
              child: SelectableText(
                '${field(d, 'output')}',
                style: PircType.monoCode.style(color: colors['code.text']),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
