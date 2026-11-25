import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:pirc_client/pirc_client.dart';
import 'package:pirc_ui/pirc_ui.dart';

import '../../../l10n/app_localizations.dart';
import '../../connection/data.dart';
import '../session_controller.dart';
import 'environment_controller.dart';

/// The banner while a transition is open (D12/D13): its steps; the
/// composer keeps the draft and sends nothing meanwhile.
class EnvironmentBanner extends ConsumerWidget {
  const EnvironmentBanner({super.key, required this.sessionId});
  final String sessionId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final colors = PircColorTokens.of(context);
    final env = ref.watch(environmentProvider(sessionId));
    final step = env.step;
    if (env.active == null && step == null) return const SizedBox.shrink();
    final controls =
        ref.watch(sessionControllerProvider(sessionId)).control ==
        ControlState.mine;
    final actions = ref.read(environmentProvider(sessionId).notifier);
    final steps = [
      (TransitionStep.stopping, l10n.transitionStopping),
      (TransitionStep.confirmingRevocation, l10n.transitionRevoking),
      (TransitionStep.preparingTarget, l10n.transitionPreparing),
      (TransitionStep.switched, l10n.transitionSwitched),
    ];
    final current = switch (step) {
      TransitionStep.needsAcknowledgement => 1,
      TransitionStep.needsAuthority || TransitionStep.uncertain => 0,
      final s => steps.indexWhere((e) => e.$1 == s).clamp(0, 3),
    };
    final text = Theme.of(context).textTheme;
    return Container(
      key: const Key('environment-banner'),
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: colors['surface.subtle'],
        borderRadius: BorderRadius.circular(PircRadius.md),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            step == TransitionStep.cancelled
                ? l10n.transitionCancelled
                : l10n.transitionTitle,
            style: text.titleSmall,
          ),
          if (step != TransitionStep.cancelled)
            for (final (i, (_, label)) in steps.indexed)
              Row(
                children: [
                  StateDot(
                    i < current || step == TransitionStep.switched
                        ? DotState.done
                        : i == current
                        ? DotState.running
                        : DotState.idle,
                  ),
                  const SizedBox(width: 8),
                  Text(label, style: text.bodySmall),
                ],
              ),
          if (env.sourceOffline)
            Text(l10n.transitionSourceOffline, style: text.bodySmall),
          if (step == TransitionStep.needsAcknowledgement)
            Text(l10n.transitionNeedsAck, style: text.bodySmall),
          if (step == TransitionStep.needsAuthority)
            Text(l10n.transitionNeedsAuthority, style: text.bodySmall),
          if (step == TransitionStep.uncertain)
            Text(l10n.transitionUncertain, style: text.bodySmall),
          if (env.error != null)
            Text(
              env.error == 'plan_changed'
                  ? l10n.transitionPlanChanged
                  : env.error!,
              style: text.bodySmall?.copyWith(color: colors['status.danger']),
            ),
          if (env.transitioning && controls)
            Wrap(
              spacing: 8,
              children: [
                if (step == TransitionStep.needsAcknowledgement)
                  FilledButton(
                    onPressed: env.busy ? null : actions.acknowledge,
                    child: Text(l10n.transitionAcknowledge),
                  ),
                if (step == TransitionStep.needsAuthority)
                  FilledButton(
                    onPressed: env.busy ? null : actions.reauthorize,
                    child: Text(l10n.transitionReauthorize),
                  ),
                TextButton(
                  onPressed: env.busy ? null : actions.cancel,
                  child: Text(l10n.transitionCancel),
                ),
              ],
            ),
        ],
      ),
    );
  }
}

/// The workspace sheet (D10): host, folders with their rights, and
/// "Switch host…".
Future<void> showWorkspaceSheet(
  BuildContext context,
  WidgetRef ref,
  String sessionId,
) => showModalBottomSheet<void>(
  context: context,
  showDragHandle: true,
  isScrollControlled: true,
  builder: (_) => _WorkspaceSheet(sessionId: sessionId),
);

final _grantsProvider = FutureProvider.autoDispose
    .family<Map<String, Object?>, String>(
      (ref, sessionId) => EnvironmentApi(requireApi(ref), sessionId).grants(),
    );

class _WorkspaceSheet extends ConsumerWidget {
  const _WorkspaceSheet({required this.sessionId});
  final String sessionId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final env = ref.watch(environmentProvider(sessionId));
    final binding = (env.environment?['binding'] as Map?)?['execution'] as Map?;
    final workspaceId = binding?['workspaceId'] as String?;
    final workspaces = ref.watch(workspacesProvider).value ?? const [];
    final current = workspaces.where((w) => w.id == workspaceId).firstOrNull;
    final grants = ref.watch(_grantsProvider(sessionId));
    final controls =
        ref.watch(sessionControllerProvider(sessionId)).control ==
        ControlState.mine;
    return SafeArea(
      child: ListView(
        shrinkWrap: true,
        children: [
          ListTile(
            leading: const Icon(LucideIcons.server),
            title: Text(
              current?.nodeId ?? binding?['nodeId'] as String? ?? '—',
            ),
            subtitle: Text(current?.displayName ?? workspaceId ?? ''),
          ),
          if (env.transitioning) ListTile(title: Text(l10n.transitionTitle)),
          ListTile(title: Text(l10n.envFolders)),
          ...switch (grants) {
            AsyncValue(:final value?) => [
              for (final g
                  in ((value['effectiveAccess'] as Map?)?['grants'] as List? ??
                          const [])
                      .cast<Map>())
                ListTile(
                  dense: true,
                  leading: Icon(switch (g['effective']) {
                    'write' => LucideIcons.pencil,
                    'deny' => LucideIcons.ban,
                    _ => LucideIcons.eye,
                  }, size: 18),
                  title: Text('${g['path']}'),
                  subtitle: Text(switch (g['effective']) {
                    'write' => l10n.envWrite,
                    'deny' => l10n.envDeny,
                    _ => l10n.envRead,
                  }),
                  trailing: controls
                      ? TextButton(
                          onPressed: () async {
                            await ref
                                .read(environmentProvider(sessionId).notifier)
                                .revokeGrant('${g['grantId']}');
                            ref.invalidate(_grantsProvider(sessionId));
                          },
                          child: Text(l10n.envRevoke),
                        )
                      : null,
                ),
              if (value['grantsEnabled'] == true && controls)
                ListTile(
                  leading: const Icon(LucideIcons.plus, size: 18),
                  title: Text(l10n.envAddFolder),
                  onTap: () async {
                    final added = await showDialog<(String, String)>(
                      context: context,
                      builder: (_) => const _GrantDialog(),
                    );
                    if (added == null) return;
                    await ref
                        .read(environmentProvider(sessionId).notifier)
                        .addGrant(added.$1, added.$2);
                    ref.invalidate(_grantsProvider(sessionId));
                  },
                ),
            ],
            AsyncValue(:final error?) when error is! NotConnected => [
              ListTile(title: Text(l10n.listFailed)),
            ],
            _ => [const Center(child: CircularProgressIndicator())],
          },
          const Divider(),
          ListTile(
            leading: const Icon(LucideIcons.arrowLeftRight),
            title: Text(l10n.envSwitch),
            enabled: controls && !env.transitioning,
            onTap: () async {
              final target = await showDialog<WorkspaceInfo>(
                context: context,
                builder: (dialog) => SimpleDialog(
                  title: Text(l10n.envSwitchTo),
                  children: [
                    for (final w in workspaces)
                      if (w.id != workspaceId)
                        SimpleDialogOption(
                          onPressed: () => Navigator.pop(dialog, w),
                          child: Text('${w.displayName} · ${w.nodeId}'),
                        ),
                  ],
                ),
              );
              if (target == null || !context.mounted) return;
              await showDialog<void>(
                context: context,
                builder: (_) =>
                    _PreviewDialog(sessionId: sessionId, target: target),
              );
              if (context.mounted) Navigator.pop(context);
            },
          ),
        ],
      ),
    );
  }
}

class _GrantDialog extends StatefulWidget {
  const _GrantDialog();

  @override
  State<_GrantDialog> createState() => _GrantDialogState();
}

class _GrantDialogState extends State<_GrantDialog> {
  final _path = TextEditingController();
  String _access = 'read';

  @override
  void dispose() {
    _path.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return AlertDialog(
      title: Text(l10n.envAddFolder),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            key: const Key('grant-path'),
            controller: _path,
            decoration: InputDecoration(labelText: l10n.envFolderPath),
          ),
          DropdownButton<String>(
            value: _access,
            isExpanded: true,
            items: [
              DropdownMenuItem(value: 'read', child: Text(l10n.envRead)),
              DropdownMenuItem(value: 'write', child: Text(l10n.envWrite)),
              DropdownMenuItem(value: 'deny', child: Text(l10n.envDeny)),
            ],
            onChanged: (v) => setState(() => _access = v ?? 'read'),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(l10n.cancel),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, (_path.text.trim(), _access)),
          child: Text(l10n.save),
        ),
      ],
    );
  }
}

/// The preview (D11): what stops, what stays, what the target lacks.
/// Cancel changes nothing; Confirm starts the transition.
class _PreviewDialog extends ConsumerStatefulWidget {
  const _PreviewDialog({required this.sessionId, required this.target});
  final String sessionId;
  final WorkspaceInfo target;

  @override
  ConsumerState<_PreviewDialog> createState() => _PreviewDialogState();
}

class _PreviewDialogState extends ConsumerState<_PreviewDialog> {
  Map<String, Object?>? _preview;
  String? _error;
  bool _confirming = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final env = ref.read(environmentProvider(widget.sessionId));
    final binding = ExpectedBinding.maybe(env.environment?['binding']);
    final api = ref.read(apiProvider);
    if (binding == null || api == null) {
      setState(() => _error = 'stale_environment');
      return;
    }
    try {
      final preview = await EnvironmentApi(api, widget.sessionId).preview(
        operationId: 'switch-${randomId()}',
        targetWorkspaceId: widget.target.id,
        binding: binding,
      );
      if (mounted) setState(() => _preview = preview);
    } on PircException catch (error) {
      if (mounted) {
        setState(() => _error = error is ApiError ? error.code : error.message);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final preview = _preview;
    final blocked = (preview?['blockedBy'] as List? ?? const []).cast<String>();
    final canConfirm = preview?['canConfirm'] == true;
    final envError = ref.watch(environmentProvider(widget.sessionId)).error;
    return AlertDialog(
      title: Text(l10n.envPreviewTitle(widget.target.displayName)),
      content: SizedBox(
        width: 420,
        child: preview == null && _error == null
            ? const Center(heightFactor: 2, child: CircularProgressIndicator())
            : Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(l10n.envPreviewStops),
                  const SizedBox(height: 4),
                  Text(l10n.envPreviewStays),
                  const SizedBox(height: 8),
                  for (final reason in blocked)
                    Text('• ${_reason(l10n, reason)}'),
                  if (_error != null) Text(_error!),
                  if (envError != null && _confirming) Text(envError),
                ],
              ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(l10n.cancel),
        ),
        FilledButton(
          key: const Key('confirm-switch'),
          onPressed: canConfirm && !_confirming
              ? () async {
                  setState(() => _confirming = true);
                  final ok = await ref
                      .read(environmentProvider(widget.sessionId).notifier)
                      .confirm(preview!);
                  if (!context.mounted) return;
                  if (ok) {
                    Navigator.pop(context);
                  } else {
                    setState(() => _confirming = false);
                  }
                }
              : null,
          child: Text(l10n.envConfirm),
        ),
      ],
    );
  }

  static String _reason(AppLocalizations l10n, String reason) =>
      switch (reason) {
        'cross_node_handoff_not_available' => l10n.envBlockedCrossNode,
        'source_has_pending_work' => l10n.envBlockedPendingWork,
        'node_unavailable_or_unsupported' => l10n.envBlockedNode,
        'environment_unchanged' => l10n.envBlockedUnchanged,
        'resource_unavailable' => l10n.envBlockedResource,
        _ => reason,
      };
}
