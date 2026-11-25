import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:pirc_client/pirc_client.dart';
import 'package:pirc_ui/pirc_ui.dart';

import '../../../l10n/app_localizations.dart';

/// The goal widget (`widgets.goal`): `GOAL · <phase>[ · disarmed] · n[/max]`,
/// then the objective.
class GoalView {
  const GoalView({
    required this.phase,
    required this.rounds,
    this.maxRounds,
    this.objective = '',
  });

  /// active, paused, blocked or complete.
  final String phase;
  final int rounds;
  final int? maxRounds;
  final String objective;

  static GoalView? parse(List<String>? lines) {
    if (lines == null || lines.isEmpty) return null;
    final match = RegExp(
      r'^GOAL · (active|paused|blocked|complete)( · disarmed)? · (\d+)(?:/(\d+))?$',
    ).firstMatch(lines.first);
    if (match == null) return null;
    return GoalView(
      phase: match[1]!,
      rounds: int.parse(match[3]!),
      maxRounds: match[4] == null ? null : int.tryParse(match[4]!),
      objective: lines.length > 1 ? lines[1] : '',
    );
  }
}

/// The todo widget (`widgets.local-todo`): `TODO · done/total`, then one
/// line per item marked ✓, ▶ or ☐.
class TodoView {
  const TodoView(this.items, this.done, this.total);

  /// (status, text): completed, in_progress or pending.
  final List<(String, String)> items;
  final int done;
  final int total;

  static TodoView? parse(List<String>? lines) {
    if (lines == null || lines.isEmpty) return null;
    final header = RegExp(r'^TODO · (\d+)/(\d+)$').firstMatch(lines.first);
    final items = <(String, String)>[];
    for (final line in lines.skip(header == null ? 0 : 1)) {
      if (line.isEmpty) continue;
      final status = const {
        '✓': 'completed',
        '▶': 'in_progress',
        '☐': 'pending',
      }[line.substring(0, 1)];
      if (status == null) continue;
      var text = line.substring(1).trim();
      final tagged = RegExp(r'^\[[^\]]*\] (.*)$').firstMatch(text);
      if (tagged != null) text = tagged[1]!;
      items.add((status, text));
    }
    if (items.isEmpty && header == null) return null;
    final done = header == null
        ? items.where((item) => item.$1 == 'completed').length
        : int.parse(header[1]!);
    final total = header == null ? items.length : int.parse(header[2]!);
    return TodoView(items, done, total);
  }
}

/// `c-dock`: the goal, the todo list and the queue above the composer
/// (default E). Each part folds to one line; tap to expand.
class ComposerDock extends StatefulWidget {
  const ComposerDock({super.key, required this.state});

  final SessionState state;

  @override
  State<ComposerDock> createState() => _ComposerDockState();
}

class _ComposerDockState extends State<ComposerDock> {
  String? _open;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final colors = PircColorTokens.of(context);
    final goal = GoalView.parse(widget.state.widgets['goal']);
    final todo = TodoView.parse(widget.state.widgets['local-todo']);
    final queue = widget.state.queue;
    if (goal == null && todo == null && queue.isEmpty) {
      return const SizedBox.shrink();
    }
    Widget section(
      String key,
      DotState dot,
      String title,
      String trailing,
      List<Widget> body,
    ) {
      final open = _open == key;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            onTap: () => setState(() => _open = open ? null : key),
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: PircSpacing.stackLg,
                vertical: PircSpacing.stackSm,
              ),
              child: Row(
                children: [
                  StateDot(dot),
                  const SizedBox(width: PircSpacing.stackSm),
                  Expanded(
                    child: Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                  Text(trailing, style: Theme.of(context).textTheme.labelSmall),
                  Icon(
                    open ? LucideIcons.chevronUp : LucideIcons.chevronDown,
                    size: 14,
                  ),
                ],
              ),
            ),
          ),
          if (open)
            Padding(
              padding: const EdgeInsets.fromLTRB(
                PircSpacing.stackLg + 15,
                0,
                PircSpacing.stackLg,
                PircSpacing.stackSm,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: body,
              ),
            ),
        ],
      );
    }

    final small = Theme.of(context).textTheme.bodySmall;
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 20),
      decoration: BoxDecoration(
        color: colors['surface.subtle'],
        borderRadius: const BorderRadius.vertical(
          top: Radius.circular(PircRadius.lg),
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (goal != null)
            section(
              'goal',
              switch (goal.phase) {
                'active' => DotState.running,
                'complete' => DotState.done,
                'blocked' => DotState.failed,
                _ => DotState.idle,
              },
              goal.objective.isEmpty ? l10n.dockGoal : goal.objective,
              '${goal.rounds}${goal.maxRounds == null ? '' : '/${goal.maxRounds}'}',
              [Text(goal.objective, style: small)],
            ),
          if (todo != null)
            section(
              'todo',
              todo.done == todo.total ? DotState.done : DotState.running,
              todo.items
                      .where((item) => item.$1 == 'in_progress')
                      .firstOrNull
                      ?.$2 ??
                  l10n.dockTodo,
              '${todo.done}/${todo.total}',
              [
                for (final (status, text) in todo.items)
                  Text(
                    '${switch (status) {
                      'completed' => '✓',
                      'in_progress' => '▶',
                      _ => '☐',
                    }} $text',
                    style: small,
                  ),
              ],
            ),
          if (queue.isNotEmpty)
            section('queue', DotState.waiting, l10n.dockQueue(queue.length), '', [
              for (final item in queue)
                Text(
                  '${item.kind == 'steer' ? l10n.whenSteer : l10n.whenQueue} · ${item.content}',
                  style: small,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
            ]),
        ],
      ),
    );
  }
}
