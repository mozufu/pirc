import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:pirc_client/pirc_client.dart';

import '../../l10n/app_localizations.dart';
import '../connection/data.dart';
import 'work_data.dart';
import 'work_list_screen.dart';

/// The `open` value of the Work tab for a project page.
String projectOpen(String workspaceId) => 'project:$workspaceId';

final _modesProvider = FutureProvider<List<Map<String, Object?>>>(
  (ref) => ModesApi(requireApi(ref)).list(),
);

final _capabilitiesProvider = FutureProvider.autoDispose
    .family<Map<String, Object?>, String>(
      (ref, id) => DirectoryApi(requireApi(ref)).capabilities(id),
    );

final _configProvider = FutureProvider.autoDispose
    .family<Map<String, Object?>, String>(
      (ref, id) => DirectoryApi(requireApi(ref)).projectConfig(id),
    );

/// A project (D4–D6): its conversations, its resources (what its agents may
/// use) and its rules (the project config and its trust). Notes, Board and
/// leaving a project are not built; project files, instructions and the
/// delete preview have no Gateway route since M4 10b.
class ProjectScreen extends ConsumerWidget {
  const ProjectScreen({
    super.key,
    required this.workspaceId,
    this.showBack = true,
  });

  final String workspaceId;
  final bool showBack;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final workspace = ref
        .watch(workspacesProvider)
        .value
        ?.where((w) => w.id == workspaceId)
        .firstOrNull;
    final mode = ref
        .watch(_modesProvider)
        .value
        ?.where((m) => m['id'] == workspace?.mode)
        .firstOrNull;
    final rules = mode?['project_config'] == true;
    final text = Theme.of(context).textTheme;
    return DefaultTabController(
      length: rules ? 3 : 2,
      child: Scaffold(
        appBar: AppBar(
          automaticallyImplyLeading: false,
          leading: showBack
              ? IconButton(
                  tooltip: l10n.back,
                  icon: const Icon(LucideIcons.chevronLeft),
                  onPressed: () => context.go('/work'),
                )
              : null,
          centerTitle: true,
          title: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(workspace?.displayName ?? '', style: text.titleSmall),
              if (workspace != null)
                Text(workspace.nodeId, style: text.labelSmall),
            ],
          ),
          actions: [
            PopupMenuButton<String>(
              tooltip: l10n.moreActions,
              onSelected: (_) => _remove(context, ref, workspace),
              itemBuilder: (_) => [
                PopupMenuItem(value: 'remove', child: Text(l10n.projectRemove)),
              ],
            ),
          ],
          bottom: TabBar(
            tabs: [
              Tab(text: l10n.projectConversations),
              Tab(text: l10n.projectResources),
              if (rules) Tab(text: l10n.projectRules),
            ],
          ),
        ),
        body: TabBarView(
          children: [
            _Conversations(workspaceId: workspaceId),
            _Resources(workspaceId: workspaceId),
            if (rules) _Rules(workspaceId: workspaceId),
          ],
        ),
      ),
    );
  }

  /// Removes the project from the lists. Its host must be online to check
  /// that it is idle; offline, the user tries again later.
  Future<void> _remove(
    BuildContext context,
    WidgetRef ref,
    WorkspaceInfo? workspace,
  ) async {
    final l10n = AppLocalizations.of(context);
    final sure = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: Text(l10n.projectRemoveTitle(workspace?.displayName ?? '')),
        content: Text(l10n.projectRemoveBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialog, false),
            child: Text(l10n.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialog, true),
            child: Text(l10n.projectRemoveConfirm),
          ),
        ],
      ),
    );
    if (sure != true || !context.mounted) return;
    try {
      await DirectoryApi(ref.read(apiProvider)!).removeWorkspace(workspaceId);
      ref.invalidate(workspacesProvider);
      if (context.mounted) context.go('/work');
    } on PircException catch (error) {
      if (!context.mounted) return;
      final offline = error is ApiError && error.code == 'node_offline';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            offline
                ? l10n.projectRemoveOffline
                : l10n.actionFailed(error.message),
          ),
          action: offline
              ? SnackBarAction(
                  label: l10n.retry,
                  onPressed: () => _remove(context, ref, workspace),
                )
              : null,
        ),
      );
    }
  }
}

class _Conversations extends ConsumerWidget {
  const _Conversations({required this.workspaceId});
  final String workspaceId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final list = buildWorkList(
      sessions: ref.watch(sessionsProvider).value ?? const [],
      workspaces: ref.watch(workspacesProvider).value ?? const [],
      works: ref.watch(potWorksProvider).value ?? const [],
      pots: ref.watch(potsProvider).value ?? const [],
      approvals: ref.watch(pendingApprovalsProvider).value ?? const [],
    );
    final items = list.groups
        .where((g) => g.workspaceId == workspaceId)
        .expand((g) => g.items)
        .toList();
    if (items.isEmpty) return Center(child: Text(l10n.emptyWork));
    return ListView(children: [for (final item in items) WorkRow(item: item)]);
  }
}

class _Resources extends ConsumerWidget {
  const _Resources({required this.workspaceId});
  final String workspaceId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final value = ref.watch(_capabilitiesProvider(workspaceId));
    return switch (value) {
      AsyncValue(:final value?) => ListView(
        children: [
          for (final (key, label) in [
            ('memory_search', l10n.capMemorySearch),
            ('remote_recall', l10n.capRemoteRecall),
            ('schedules', l10n.capSchedules),
            ('web_search', l10n.capWebSearch),
          ])
            SwitchListTile(
              title: Text(label),
              value: value[key] == true,
              onChanged: (on) async {
                try {
                  await DirectoryApi(
                    ref.read(apiProvider)!,
                  ).setCapabilities(workspaceId, {key: on});
                } on PircException catch (error) {
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text(l10n.actionFailed(error.message))),
                    );
                  }
                }
                ref.invalidate(_capabilitiesProvider(workspaceId));
              },
            ),
        ],
      ),
      AsyncValue(:final error?) when error is! NotConnected => Center(
        child: TextButton(
          onPressed: () => ref.invalidate(_capabilitiesProvider(workspaceId)),
          child: Text('${l10n.listFailed} ${l10n.retry}'),
        ),
      ),
      _ => const Center(child: CircularProgressIndicator()),
    };
  }
}

/// The project config (`.pirc/config.json`): hooks, environment, allowed
/// paths and default model. It runs only once trusted; a changed config
/// must be reviewed again.
class _Rules extends ConsumerWidget {
  const _Rules({required this.workspaceId});
  final String workspaceId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final value = ref.watch(_configProvider(workspaceId));
    Future<void> trust(String? hash) async {
      try {
        await DirectoryApi(
          ref.read(apiProvider)!,
        ).trustProject(workspaceId, hash: hash);
      } on PircException catch (error) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                error is ApiError && error.status == 409
                    ? l10n.projectConfigChanged
                    : l10n.actionFailed(error.message),
              ),
            ),
          );
        }
      }
      ref.invalidate(_configProvider(workspaceId));
    }

    return switch (value) {
      AsyncValue(:final value?) => ListView(
        children: [
          if (value['error'] != null)
            ListTile(
              leading: const Icon(LucideIcons.circleAlert),
              title: Text(l10n.projectConfigInvalid),
              subtitle: Text('${value['error']}'),
            )
          else if (value['empty'] == true)
            ListTile(title: Text(l10n.projectConfigEmpty))
          else ...[
            ListTile(
              leading: Icon(
                value['trusted'] == true
                    ? LucideIcons.shieldCheck
                    : LucideIcons.shieldAlert,
              ),
              title: Text(
                value['trusted'] == true
                    ? l10n.projectTrusted
                    : l10n.projectNotTrusted,
              ),
              trailing: value['trusted'] == true
                  ? TextButton(
                      onPressed: () => trust(null),
                      child: Text(l10n.projectUntrust),
                    )
                  : FilledButton(
                      onPressed: () => trust('${value['hash']}'),
                      child: Text(l10n.projectTrust),
                    ),
            ),
            for (final MapEntry(key: hook, value: list)
                in ((value['hooks'] as Map?) ?? const {}).entries)
              for (final h in (list as List? ?? const []).cast<Map>())
                ListTile(
                  dense: true,
                  leading: const Icon(LucideIcons.terminal, size: 18),
                  title: Text('${h['command']}'),
                  subtitle: Text('$hook'),
                ),
            for (final path in (value['allowedPaths'] as List? ?? const []))
              ListTile(
                dense: true,
                leading: const Icon(LucideIcons.folderOpen, size: 18),
                title: Text('$path'),
              ),
            for (final key in ((value['env'] as Map?) ?? const {}).keys)
              ListTile(
                dense: true,
                leading: const Icon(LucideIcons.variable, size: 18),
                title: Text('$key'),
              ),
          ],
        ],
      ),
      AsyncValue(:final error?) when error is! NotConnected => Center(
        child: TextButton(
          onPressed: () => ref.invalidate(_configProvider(workspaceId)),
          child: Text(
            error is ApiError && error.code == 'node_offline'
                ? l10n.panelHostOffline
                : '${l10n.listFailed} ${l10n.retry}',
          ),
        ),
      ),
      _ => const Center(child: CircularProgressIndicator()),
    };
  }
}

/// "New project": a folder on a connected host.
Future<void> newProject(BuildContext context, WidgetRef ref) async {
  final l10n = AppLocalizations.of(context);
  final created = await showDialog<WorkspaceInfo>(
    context: context,
    builder: (_) => const _NewProjectDialog(),
  );
  if (created == null || !context.mounted) return;
  ref.invalidate(workspacesProvider);
  context.go(
    Uri(
      path: '/work',
      queryParameters: {'open': projectOpen(created.id)},
    ).toString(),
  );
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(content: Text(l10n.projectCreated(created.displayName))),
  );
}

class _NewProjectDialog extends ConsumerStatefulWidget {
  const _NewProjectDialog();

  @override
  ConsumerState<_NewProjectDialog> createState() => _NewProjectDialogState();
}

class _NewProjectDialogState extends ConsumerState<_NewProjectDialog> {
  final _name = TextEditingController();
  final _path = TextEditingController();
  String? _node;
  String? _error;
  bool _busy = false;

  @override
  void dispose() {
    _name.dispose();
    _path.dispose();
    super.dispose();
  }

  Future<void> _create() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final created = await DirectoryApi(ref.read(apiProvider)!)
          .createWorkspace(
            nodeId: _node!,
            displayName: _name.text.trim(),
            path: _path.text.trim(),
          );
      if (mounted) Navigator.pop(context, created);
    } on PircException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final nodes = ref.watch(nodesProvider).value ?? const <NodeInfo>[];
    final ready =
        _node != null &&
        _name.text.trim().isNotEmpty &&
        _path.text.trim().isNotEmpty &&
        !_busy;
    return AlertDialog(
      title: Text(l10n.projectNew),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            DropdownButtonFormField<String>(
              key: const Key('project-host'),
              initialValue: _node,
              hint: Text(l10n.projectHost),
              isExpanded: true,
              items: [
                for (final node in nodes)
                  DropdownMenuItem(value: node.id, child: Text(node.id)),
              ],
              onChanged: (v) => setState(() => _node = v),
            ),
            TextField(
              key: const Key('project-name'),
              controller: _name,
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(labelText: l10n.projectName),
            ),
            TextField(
              key: const Key('project-path'),
              controller: _path,
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                labelText: l10n.projectPath,
                hintText: '~/code/project',
              ),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(_error!),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(l10n.cancel),
        ),
        FilledButton(
          key: const Key('project-create'),
          onPressed: ready ? _create : null,
          child: Text(l10n.projectCreate),
        ),
      ],
    );
  }
}
