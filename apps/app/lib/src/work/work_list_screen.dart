import 'package:flutter/material.dart' hide DrawerButton;
import 'package:flutter/semantics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:pirc_client/pirc_client.dart';
import 'package:pirc_ui/pirc_ui.dart';

import '../../l10n/app_localizations.dart';
import '../connection/data.dart';
import '../format.dart';
import '../chat/decision_sheet.dart';
import '../shell/app_drawer.dart';
import 'project_screen.dart';
import 'work_data.dart';
import 'work_side.dart';

/// The Work tab's list (E2–E4): filters, search, rows grouped by project.
class WorkListScreen extends ConsumerWidget {
  const WorkListScreen({super.key, this.openId, this.onNew});

  /// The open session, highlighted where the list stays visible.
  final String? openId;

  /// Starts a new conversation (step 6); hidden when null.
  final VoidCallback? onNew;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final text = Theme.of(context).textTheme;
    final filter = ref.watch(workFilterProvider);
    final list = ref.watch(workListProvider);
    final needsYou = list.value?.needsYou ?? 0;
    final note = switch (filter) {
      WorkFilter.needsYou => l10n.noteNeedsYou,
      WorkFilter.mine => l10n.noteMine,
      WorkFilter.pots => l10n.notePots,
      _ => null,
    };
    return Scaffold(
      appBar: AppBar(
        leading: const DrawerButton(),
        centerTitle: true,
        title: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(l10n.tabWork, style: text.titleSmall),
            Text(l10n.workSubtitle, style: text.labelSmall),
          ],
        ),
        actions: [
          IconButton(
            tooltip: l10n.projectNew,
            icon: const Icon(LucideIcons.folderPlus),
            onPressed: () => newProject(context, ref),
          ),
          if (onNew != null)
            IconButton(
              tooltip: l10n.newConversation,
              icon: const Icon(LucideIcons.squarePen),
              onPressed: onNew,
            ),
        ],
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
              PircSpacing.gutterPhone,
              PircSpacing.stackXs,
              PircSpacing.gutterPhone,
              PircSpacing.stackSm,
            ),
            child: _Search(hint: l10n.searchWork),
          ),
          FilterChips<WorkFilter>(
            selected: filter,
            onSelected: ref.read(workFilterProvider.notifier).select,
            items: [
              FilterChipItem(WorkFilter.all, l10n.filterAll),
              FilterChipItem(
                WorkFilter.needsYou,
                l10n.filterNeedsYou,
                count: needsYou,
              ),
              FilterChipItem(WorkFilter.running, l10n.filterRunning),
              FilterChipItem(WorkFilter.mine, l10n.filterMine),
              FilterChipItem(WorkFilter.pots, l10n.filterPots),
            ],
          ),
          if (note != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(
                PircSpacing.gutterPhone,
                PircSpacing.stackXs,
                PircSpacing.gutterPhone,
                0,
              ),
              child: Text(note, style: text.bodySmall),
            ),
          Expanded(
            child: switch (list) {
              AsyncValue(:final value?) => _Groups(
                list: value,
                openId: openId,
                empty: filter == WorkFilter.all
                    ? l10n.emptyWork
                    : l10n.emptyFilter,
              ),
              AsyncValue(:final error?) when error is! NotConnected => _Failed(
                onRetry: () => ref.invalidate(sessionsProvider),
              ),
              _ => const Center(child: CircularProgressIndicator()),
            },
          ),
        ],
      ),
    );
  }
}

class _Search extends ConsumerStatefulWidget {
  const _Search({required this.hint});
  final String hint;

  @override
  ConsumerState<_Search> createState() => _SearchState();
}

class _SearchState extends ConsumerState<_Search> {
  late final _controller = TextEditingController(
    text: ref.read(workQueryProvider),
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = PircColorTokens.of(context);
    return TextField(
      controller: _controller,
      onChanged: ref.read(workQueryProvider.notifier).set,
      textInputAction: TextInputAction.search,
      decoration: InputDecoration(
        isDense: true,
        hintText: widget.hint,
        prefixIcon: const Icon(LucideIcons.search, size: PircSize.iconRow),
        filled: true,
        fillColor: colors['fill.hover'],
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(PircRadius.lg),
          borderSide: BorderSide.none,
        ),
      ),
    );
  }
}

class _Groups extends StatelessWidget {
  const _Groups({required this.list, required this.empty, this.openId});

  final WorkList list;
  final String empty;
  final String? openId;

  @override
  Widget build(BuildContext context) {
    if (list.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(PircSpacing.stackXl),
          child: Text(
            empty,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
      );
    }
    return ListView(
      padding: const EdgeInsets.only(bottom: PircSpacing.stackXl),
      children: [
        for (final group in list.groups) ...[
          _GroupHeader(group: group),
          for (final (index, item) in group.items.indexed) ...[
            if (index > 0)
              const Divider(
                height: 1,
                indent: PircSpacing.gutterPhone,
                endIndent: 0,
              ),
            WorkRow(
              key: ValueKey(item.key),
              item: item,
              selected: item is SessionItem && item.session.id == openId,
            ),
          ],
        ],
      ],
    );
  }
}

class _GroupHeader extends StatelessWidget {
  const _GroupHeader({required this.group});
  final WorkGroup group;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final text = Theme.of(context).textTheme;
    final colors = PircColorTokens.of(context);
    final id = group.workspaceId;
    return Semantics(
      header: true,
      // Default G: a tap on a project header opens the project page.
      child: InkWell(
        onTap: id == null
            ? null
            : () => context.go(
                Uri(
                  path: '/work',
                  queryParameters: {'open': projectOpen(id)},
                ).toString(),
              ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            PircSpacing.gutterPhone,
            PircSpacing.stackXl,
            PircSpacing.gutterPhone,
            PircSpacing.stackSm,
          ),
          child: Row(
            children: [
              Icon(
                LucideIcons.folder,
                size: PircSize.iconRow,
                color: colors['text.secondary'],
              ),
              const SizedBox(width: PircSpacing.stackSm),
              Expanded(
                child: Text(
                  group.name ?? l10n.noProject,
                  style: text.titleMedium?.copyWith(
                    fontWeight: FontWeight.w500,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Text(l10n.groupCount(group.items.length), style: text.bodyMedium),
            ],
          ),
        ),
      ),
    );
  }
}

/// One Work row: line 1 the name, who started it and the time; line 2 the
/// host and the state, with a symbol and text.
class WorkRow extends ConsumerWidget {
  const WorkRow({
    super.key,
    required this.item,
    this.selected = false,
    this.from,
  });

  final WorkItem item;

  /// The Work item Back returns to from the opened conversation.
  final String? from;
  final bool selected;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final text = Theme.of(context).textTheme;
    final colors = PircColorTokens.of(context);
    final warning = colors['text.warning'];
    final secondary = colors['text.secondary'];
    final item = this.item;
    final (String source, List<InlineSpan> state) = switch (item) {
      SessionItem(:final session, source: final source) => (
        switch (source) {
          FromPot(:final potName) => l10n.fromPot(potName),
          FromSchedule(:final title) => title,
          FromUser() => l10n.fromYou,
        },
        _sessionState(context, session, item.host),
      ),
      ApprovalItem(:final approval) => (
        l10n.fromPot(item.potName),
        [
          WidgetSpan(
            alignment: PlaceholderAlignment.middle,
            child: Icon(LucideIcons.diamond, size: 12, color: warning),
          ),
          TextSpan(
            text: ' ${l10n.approvalWaiting(approval.model)}',
            style: TextStyle(color: warning),
          ),
        ],
      ),
    };
    final unread = item is SessionItem && item.session.unread;
    final settled = item is SessionItem && item.session.settled;
    final pinned = item is SessionItem && item.session.pinned;
    final row = Container(
      color: selected ? colors['fill.active'] : null,
      padding: const EdgeInsets.symmetric(
        horizontal: PircSpacing.gutterPhone,
        vertical: PircSpacing.stackMd,
      ),
      child: Opacity(
        opacity: settled ? 0.6 : 1,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text.rich(
                    TextSpan(
                      children: [
                        if (pinned)
                          WidgetSpan(
                            alignment: PlaceholderAlignment.middle,
                            child: Padding(
                              padding: const EdgeInsets.only(right: 4),
                              child: Icon(
                                LucideIcons.pin,
                                size: 14,
                                color: secondary,
                                semanticLabel: l10n.pinned,
                              ),
                            ),
                          ),
                        TextSpan(
                          text: item.title,
                          style: text.bodyLarge?.copyWith(
                            fontWeight: unread
                                ? FontWeight.w600
                                : FontWeight.w500,
                          ),
                        ),
                        TextSpan(
                          text: '  $source',
                          style: text.bodySmall?.copyWith(
                            color: colors['text.muted'],
                          ),
                        ),
                      ],
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 2),
                  Text.rich(
                    TextSpan(
                      children: state,
                      style: text.bodyMedium?.copyWith(color: secondary),
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            const SizedBox(width: PircSpacing.stackSm),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  listTime(context, item.time, now: ref.read(clockProvider)()),
                  style: text.bodySmall?.copyWith(color: colors['text.muted']),
                ),
                if (item.needsYou) ...[
                  const SizedBox(height: 4),
                  NeedsYouPill(l10n.needsYouPill),
                ],
              ],
            ),
          ],
        ),
      ),
    );
    if (item is ApprovalItem) {
      return MergeSemantics(
        child: InkWell(
          onTap: () => showApprovalSheet(context, item.approval.id),
          child: row,
        ),
      );
    }
    if (item is! SessionItem) return MergeSemantics(child: row);
    void actions() => showWorkRowActions(context, ref, item.session);
    return Semantics(
      selected: selected,
      customSemanticsActions: {
        CustomSemanticsAction(label: l10n.moreActions): actions,
      },
      child: InkWell(
        onTap: () => openWorkSession(context, ref, item.session, from: from),
        onLongPress: actions,
        onSecondaryTap: actions,
        child: row,
      ),
    );
  }

  static List<InlineSpan> _sessionState(
    BuildContext context,
    Session session,
    String? host,
  ) {
    final l10n = AppLocalizations.of(context);
    final colors = PircColorTokens.of(context);
    final warning = colors['text.warning'];
    final (
      Widget symbol,
      String label,
      Color? color,
    ) = switch (session.runStatus) {
      'waiting_input' => (
        Icon(LucideIcons.diamond, size: 12, color: warning),
        l10n.stateWaiting,
        warning,
      ),
      'running' => (const StateDot(DotState.running), l10n.stateRunning, null),
      'queued' => (
        Icon(LucideIcons.clock, size: 12, color: colors['text.secondary']),
        l10n.stateQueued,
        null,
      ),
      'stopping' => (
        const StateDot(DotState.waiting),
        l10n.stateStopping,
        null,
      ),
      _ => (
        const StateDot(DotState.idle),
        session.settled ? l10n.stateSettled : l10n.stateIdle,
        null,
      ),
    };
    return [
      if (host != null && host.isNotEmpty) TextSpan(text: '$host · '),
      WidgetSpan(alignment: PlaceholderAlignment.middle, child: symbol),
      TextSpan(
        text: ' $label',
        style: color == null ? null : TextStyle(color: color),
      ),
    ];
  }
}

/// Opens [session] and clears its unread mark on every device.
///
/// [from] is the Work item Back returns to (a project page), if any.
void openWorkSession(
  BuildContext context,
  WidgetRef ref,
  Session session, {
  String? from,
}) {
  context.go(workLocation(session.id, from: from));
  final api = ref.read(apiProvider);
  if (session.unread && api != null) {
    SessionsApi(api).markRead(session.id).ignore();
  }
}

/// Rename, pin, settle and delete.
Future<void> showWorkRowActions(
  BuildContext context,
  WidgetRef ref,
  Session session,
) async {
  final l10n = AppLocalizations.of(context);
  final choice = await showModalBottomSheet<String>(
    context: context,
    showDragHandle: true,
    builder: (context) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: const Icon(LucideIcons.pencil),
            title: Text(l10n.actionRename),
            onTap: () => Navigator.pop(context, 'rename'),
          ),
          ListTile(
            leading: Icon(
              session.pinned ? LucideIcons.pinOff : LucideIcons.pin,
            ),
            title: Text(session.pinned ? l10n.actionUnpin : l10n.actionPin),
            onTap: () => Navigator.pop(context, 'pin'),
          ),
          ListTile(
            leading: Icon(
              session.settled ? LucideIcons.rotateCcw : LucideIcons.check,
            ),
            title: Text(
              session.settled ? l10n.actionUnsettle : l10n.actionSettle,
            ),
            onTap: () => Navigator.pop(context, 'settle'),
          ),
          ListTile(
            leading: const Icon(LucideIcons.trash2),
            title: Text(l10n.actionDelete),
            onTap: () => Navigator.pop(context, 'delete'),
          ),
        ],
      ),
    ),
  );
  if (choice == null || !context.mounted) return;
  final api = ref.read(apiProvider);
  if (api == null) return;
  final sessions = SessionsApi(api);
  Future<void> run(Future<void> Function() action) async {
    try {
      await action();
      ref.invalidate(sessionsProvider);
    } on PircException catch (error) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l10n.actionFailed(error.message))));
    }
  }

  switch (choice) {
    case 'rename':
      final name = await _askName(context, session.name);
      if (name != null) {
        await run(() => sessions.update(session.id, name: name));
      }
    case 'pin':
      await run(() => sessions.update(session.id, pinned: !session.pinned));
    case 'settle':
      await run(() => sessions.update(session.id, settled: !session.settled));
    case 'delete':
      final sure = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(l10n.deleteWorkTitle),
          content: Text(l10n.deleteWorkBody),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(l10n.cancel),
            ),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: PircColorTokens.of(context)['status.danger'],
              ),
              onPressed: () => Navigator.pop(context, true),
              child: Text(l10n.delete),
            ),
          ],
        ),
      );
      if (sure == true) await run(() => sessions.delete(session.id));
  }
}

Future<String?> _askName(BuildContext context, String current) =>
    showDialog<String>(
      context: context,
      builder: (context) => _RenameDialog(current: current),
    ).then(
      (name) => name == null || name.isEmpty || name == current ? null : name,
    );

class _RenameDialog extends StatefulWidget {
  const _RenameDialog({required this.current});
  final String current;

  @override
  State<_RenameDialog> createState() => _RenameDialogState();
}

class _RenameDialogState extends State<_RenameDialog> {
  late final _controller = TextEditingController(text: widget.current);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return AlertDialog(
      title: Text(l10n.actionRename),
      content: TextField(
        key: const Key('rename-field'),
        controller: _controller,
        autofocus: true,
        maxLength: 200,
        onSubmitted: (value) => Navigator.pop(context, value.trim()),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(l10n.cancel),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, _controller.text.trim()),
          child: Text(l10n.save),
        ),
      ],
    );
  }
}

class _Failed extends StatelessWidget {
  const _Failed({required this.onRetry});
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(l10n.listFailed, style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: PircSpacing.stackSm),
          OutlinedButton(onPressed: onRetry, child: Text(l10n.retry)),
        ],
      ),
    );
  }
}
