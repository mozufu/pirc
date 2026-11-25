import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:pirc_client/pirc_client.dart';
import 'package:pirc_ui/pirc_ui.dart';

import '../../../l10n/app_localizations.dart';
import '../../connection/connection.dart';
import '../../connection/data.dart';
import '../../connection/hints.dart';
import '../../connection/storage.dart';
import '../composer/attachments.dart';
import '../composer/model_sheet.dart';
import 'first_send_controller.dart';

/// The `open` value of the Work tab that shows a new conversation draft.
const newConversationKey = 'new';

const _draftKey = '${PrefKeys.draftPrefix}new';

/// A workspace the sheet offers, with why it cannot be picked.
class WorkspaceChoice {
  const WorkspaceChoice(this.workspace, {this.offline = false});
  final WorkspaceInfo workspace;

  /// Its host is not connected.
  final bool offline;
  bool get pickable => !offline && workspace.available && !workspace.deleting;
}

/// Workspaces grouped by host; offline hosts are listed but not pickable.
final workspaceChoicesProvider =
    Provider<AsyncValue<Map<String, List<WorkspaceChoice>>>>((ref) {
      final workspaces = ref.watch(workspacesProvider);
      final nodes = ref.watch(nodesProvider).value ?? const <NodeInfo>[];
      final online = {for (final node in nodes) node.id};
      return workspaces.whenData((list) {
        final byHost = <String, List<WorkspaceChoice>>{};
        for (final workspace in list) {
          byHost
              .putIfAbsent(workspace.nodeId, () => [])
              .add(
                WorkspaceChoice(
                  workspace,
                  offline: !online.contains(workspace.nodeId),
                ),
              );
        }
        return byHost;
      });
    });

/// D2/D3: a draft with a workspace sheet. The first Send runs the first-send
/// flow; the conversation is not in the Work list until it is accepted.
class NewConversationScreen extends ConsumerStatefulWidget {
  const NewConversationScreen({super.key, this.showBack = true});
  final bool showBack;

  @override
  ConsumerState<NewConversationScreen> createState() =>
      _NewConversationScreenState();
}

class _NewConversationScreenState extends ConsumerState<NewConversationScreen> {
  late final _text = TextEditingController(
    text:
        ref.read(firstSendProvider).message.isNotEmpty &&
            ref.read(firstSendProvider).phase != FirstSendPhase.idle
        ? ref.read(firstSendProvider).message
        : ref.read(sharedPreferencesProvider).getString(_draftKey) ?? '',
  );
  WorkspaceInfo? _workspace;
  ModelInfo? _model;
  String? _thinking;
  final _attachments = <PendingAttachment>[];

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  void _saveDraft(String text) {
    final prefs = ref.read(sharedPreferencesProvider);
    text.isEmpty ? prefs.remove(_draftKey) : prefs.setString(_draftKey, text);
    setState(() {});
  }

  Future<void> _pickWorkspace() async {
    final picked = await showModalBottomSheet<WorkspaceInfo>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (context) => const _WorkspaceSheet(),
    );
    if (picked != null) setState(() => _workspace = picked);
  }

  Future<void> _send() async {
    final workspace = _workspace;
    if (workspace == null) return _pickWorkspace();
    await ref
        .read(firstSendProvider.notifier)
        .send(
          workspaceId: workspace.id,
          message: _text.text.trim(),
          model: _model,
          thinking: _thinking,
          attachments: List.of(_attachments),
        );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final colors = PircColorTokens.of(context);
    final first = ref.watch(firstSendProvider);
    ref.listen(firstSendProvider, (_, next) {
      if (next.phase == FirstSendPhase.done && next.sessionId != null) {
        ref.read(sharedPreferencesProvider).remove(_draftKey);
        ref.read(firstSendProvider.notifier).reset();
        context.go(
          Uri(
            path: '/work',
            queryParameters: {'open': next.sessionId},
          ).toString(),
        );
      }
    });
    final online =
        ref.watch(appConnectionStateProvider) == AppConnectionState.online;
    final busy = first.phase == FirstSendPhase.sending;
    final open =
        first.phase == FirstSendPhase.uncertain ||
        first.phase == FirstSendPhase.refused;
    final canSend =
        online &&
        !busy &&
        !open &&
        (_text.text.trim().isNotEmpty || _attachments.isNotEmpty);
    final workspaceName =
        _workspace?.displayName ??
        ref
            .watch(workspacesProvider)
            .value
            ?.where((w) => w.id == first.workspaceId)
            .firstOrNull
            ?.displayName;
    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: false,
        leading: widget.showBack
            ? IconButton(
                tooltip: l10n.back,
                icon: const Icon(LucideIcons.chevronLeft),
                onPressed: () => context.go('/work'),
              )
            : null,
        centerTitle: true,
        title: Text(l10n.newConversation),
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ListTile(
            key: const Key('workspace-row'),
            leading: const Icon(LucideIcons.folder),
            title: Text(workspaceName ?? l10n.pickWorkspace),
            subtitle: _workspace == null ? null : Text(_workspace!.nodeId),
            trailing: const Icon(LucideIcons.chevronDown),
            enabled: !busy && !open,
            onTap: _pickWorkspace,
          ),
          Expanded(
            child: Center(
              child: Padding(
                padding: const EdgeInsets.all(PircSpacing.stackXl),
                child: _Status(state: first),
              ),
            ),
          ),
          SafeArea(
            top: false,
            child: Container(
              margin: const EdgeInsets.fromLTRB(12, 0, 12, 12),
              decoration: BoxDecoration(
                color: colors['surface.input'],
                borderRadius: BorderRadius.circular(PircRadius.panel),
                boxShadow: Theme.of(
                  context,
                ).extension<PircElevationTokens>()?.float,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (_attachments.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                      child: Wrap(
                        spacing: 6,
                        children: [
                          for (final a in _attachments)
                            InputChip(
                              label: Text(a.name),
                              onDeleted: () =>
                                  setState(() => _attachments.remove(a)),
                            ),
                        ],
                      ),
                    ),
                  TextField(
                    key: const Key('new-conversation-field'),
                    controller: _text,
                    enabled: !busy && !open,
                    minLines: 1,
                    maxLines: 8,
                    onChanged: _saveDraft,
                    decoration: InputDecoration(
                      hintText: l10n.composerHint,
                      border: InputBorder.none,
                      contentPadding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
                    ),
                  ),
                  SizedBox(
                    height: 52,
                    child: Row(
                      children: [
                        const SizedBox(width: 6),
                        IconButton(
                          tooltip: l10n.attach,
                          icon: const Icon(LucideIcons.plus),
                          onPressed: busy || open
                              ? null
                              : () async {
                                  final picked = await ref.read(
                                    filePickerProvider,
                                  )();
                                  setState(() => _attachments.addAll(picked));
                                },
                        ),
                        Flexible(
                          child: TextButton(
                            onPressed: () => showModelSheet(
                              context,
                              provider: _model?.provider,
                              modelId: _model?.id,
                              thinking: _thinking,
                              onModel: (model) =>
                                  setState(() => _model = model),
                              onThinking: (level) =>
                                  setState(() => _thinking = level),
                            ),
                            style: TextButton.styleFrom(
                              backgroundColor: colors['fill.hover'],
                              shape: const StadiumBorder(),
                            ),
                            child: Text(
                              [
                                _model?.name ?? l10n.modelDefault,
                                if (_thinking != null)
                                  thinkingLabel(l10n, _thinking),
                              ].join(' · '),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ),
                        const Spacer(),
                        IconButton.filled(
                          tooltip: l10n.send,
                          style: IconButton.styleFrom(
                            backgroundColor: colors['action.primary'],
                            foregroundColor: colors['action.onPrimary'],
                            disabledBackgroundColor: colors['surface.subtle'],
                            disabledForegroundColor: colors['text.faint'],
                          ),
                          onPressed: canSend ? _send : null,
                          icon: const Icon(LucideIcons.arrowUp),
                        ),
                        const SizedBox(width: 6),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// What became of the first send: sending, "Not sure it arrived" with
/// "Check status", refused with "Send again", or not sent.
class _Status extends ConsumerWidget {
  const _Status({required this.state});
  final FirstSendState state;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final text = Theme.of(context).textTheme;
    final colors = PircColorTokens.of(context);
    final actions = ref.read(firstSendProvider.notifier);
    final (String? title, Widget? action) = switch (state.phase) {
      FirstSendPhase.idle || FirstSendPhase.done => (null, null),
      FirstSendPhase.sending => (l10n.firstSending, null),
      FirstSendPhase.uncertain => (
        l10n.notSureArrived,
        OutlinedButton(
          onPressed: actions.checkStatus,
          child: Text(l10n.checkStatus),
        ),
      ),
      FirstSendPhase.refused => (
        l10n.firstRefused,
        state.commandId != null && state.sessionId != null
            ? FilledButton(
                onPressed: actions.sendAgain,
                child: Text(l10n.sendAgain),
              )
            : null,
      ),
      FirstSendPhase.notSent => (l10n.firstNotSent, null),
    };
    if (title == null) {
      return Text(l10n.newConversationEmpty, style: text.bodySmall);
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (state.phase == FirstSendPhase.sending)
          const Padding(
            padding: EdgeInsets.only(bottom: 12),
            child: CircularProgressIndicator(),
          ),
        Text(title, style: text.titleSmall, textAlign: TextAlign.center),
        if (state.message.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              state.message,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: text.bodySmall,
              textAlign: TextAlign.center,
            ),
          ),
        if (state.error != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              state.error!,
              style: text.bodySmall?.copyWith(color: colors['status.danger']),
              textAlign: TextAlign.center,
            ),
          ),
        if (action != null)
          Padding(padding: const EdgeInsets.only(top: 12), child: action),
      ],
    );
  }
}

class _WorkspaceSheet extends ConsumerWidget {
  const _WorkspaceSheet();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final text = Theme.of(context).textTheme;
    final choices = ref.watch(workspaceChoicesProvider);
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.8,
        ),
        child: switch (choices) {
          AsyncValue(:final value?) when value.isEmpty => Padding(
            padding: const EdgeInsets.all(24),
            child: Text(l10n.noWorkspaces),
          ),
          AsyncValue(:final value?) => ListView(
            shrinkWrap: true,
            children: [
              for (final MapEntry(key: host, value: list) in value.entries) ...[
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 16, 24, 4),
                  child: Text(
                    list.first.offline ? l10n.hostOffline(host) : host,
                    style: text.labelMedium,
                  ),
                ),
                for (final choice in list)
                  ListTile(
                    enabled: choice.pickable,
                    leading: const Icon(LucideIcons.folder),
                    title: Text(choice.workspace.displayName),
                    subtitle: choice.pickable
                        ? null
                        : Text(
                            choice.offline
                                ? l10n.workspaceHostOffline
                                : l10n.workspaceUnavailable,
                          ),
                    onTap: () => Navigator.pop(context, choice.workspace),
                  ),
              ],
            ],
          ),
          AsyncValue(:final error?) when error is! NotConnected => Padding(
            padding: const EdgeInsets.all(24),
            child: Text(l10n.listFailed),
          ),
          _ => const Padding(
            padding: EdgeInsets.all(24),
            child: Center(child: CircularProgressIndicator()),
          ),
        },
      ),
    );
  }
}
