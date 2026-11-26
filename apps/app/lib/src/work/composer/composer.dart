import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:pirc_client/pirc_client.dart';
import 'package:pirc_ui/pirc_ui.dart';

import '../../../l10n/app_localizations.dart';
import '../../connection/connection.dart';
import '../../connection/hints.dart';
import '../session_controller.dart';
import 'composer_controller.dart';
import 'dock.dart';
import 'model_sheet.dart';

/// Runs in these states take `steer`/`follow_up` and show "Stop this work".
bool runActive(SessionState state) =>
    const {'queued', 'running', 'waiting_input'}.contains(state.run?.status);

/// The composer of an open session (`c-composer`), with the dock above it.
class SessionComposer extends ConsumerStatefulWidget {
  const SessionComposer({
    super.key,
    required this.sessionId,
    required this.view,
    this.messagesAllowed = true,
    this.lockedHint,
  });

  final String sessionId;
  final SessionView view;

  /// False while a pot coordinates the work: only Stop (and answers to
  /// questions, in their cards) remain.
  final bool messagesAllowed;

  /// The hint shown when messages are not allowed.
  final String? lockedHint;

  @override
  ConsumerState<SessionComposer> createState() => _SessionComposerState();
}

class _SessionComposerState extends ConsumerState<SessionComposer> {
  late final _text = TextEditingController(
    text: ref.read(composerProvider(widget.sessionId)).draft,
  );

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<bool> _confirmTakeover(BuildContext context, String name) async {
    final l10n = AppLocalizations.of(context);
    final holder = name.isEmpty ? l10n.anotherDevice : name;
    final send = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.takeoverConfirm(holder)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(l10n.cancel),
          ),
          FilledButton(
            key: const Key('send-anyway'),
            onPressed: () => Navigator.pop(context, true),
            child: Text(l10n.send),
          ),
        ],
      ),
    );
    return send == true;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final colors = PircColorTokens.of(context);
    final elevation = Theme.of(context).extension<PircElevationTokens>();
    final composer = ref.watch(composerProvider(widget.sessionId));
    final actions = ref.read(composerProvider(widget.sessionId).notifier);
    // A stop or a "never arrived" check may change the draft.
    ref.listen(composerProvider(widget.sessionId).select((s) => s.draft), (
      _,
      draft,
    ) {
      if (_text.text != draft) _text.text = draft;
    });
    final state = widget.view.state!;
    final active = runActive(state);
    final online =
        ref.watch(appConnectionStateProvider) == AppConnectionState.online;
    final mine = widget.view.control == ControlState.mine;
    // Sending takes control for this device; only an explicit-control action
    // (model, thinking) waits for the lease.
    final canWrite = online && widget.messagesAllowed;
    final canCommand = canWrite && mine;
    final hasText =
        composer.draft.trim().isNotEmpty || composer.attachments.isNotEmpty;
    final canSend =
        canWrite && hasText && !composer.sending && composer.uncertain == null;
    final hint = !widget.messagesAllowed
        ? widget.lockedHint ?? l10n.composerLocked
        : !online
        ? l10n.composerOffline
        : l10n.composerHint;
    final model = currentModel(
      ref.watch(modelsProvider).value ?? const [],
      state.selectedModelProvider,
      state.selectedModelId,
    );
    final error = switch (composer.error) {
      null => null,
      'rejected' => l10n.commandRejected,
      'stale_environment' => l10n.staleEnvironment,
      final message => message,
    };
    return SafeArea(
      top: false,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ComposerDock(state: state),
          if (composer.uncertain != null)
            _Uncertain(
              checking: composer.checking,
              onCheck: actions.checkStatus,
            ),
          if (error != null)
            Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: 20,
                vertical: PircSpacing.stackXs,
              ),
              child: Text(
                error,
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: colors['status.danger']),
              ),
            ),
          Container(
            margin: const EdgeInsets.fromLTRB(
              PircSpacing.composerSideInset,
              0,
              PircSpacing.composerSideInset,
              PircSpacing.stackMd,
            ),
            decoration: BoxDecoration(
              color: colors['surface.input'],
              borderRadius: BorderRadius.circular(PircRadius.panel),
              boxShadow: elevation?.float,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (composer.attachments.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                    child: Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: [
                        for (final a in composer.attachments)
                          InputChip(
                            label: Text(a.name),
                            onDeleted: () => actions.removeAttachment(a.id),
                          ),
                      ],
                    ),
                  ),
                TextField(
                  key: const Key('composer-field'),
                  controller: _text,
                  enabled: canWrite,
                  minLines: 1,
                  maxLines: 8,
                  onChanged: actions.setDraft,
                  decoration: InputDecoration(
                    hintText: hint,
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
                        onPressed: canWrite ? actions.attach : null,
                      ),
                      Flexible(
                        child: TextButton(
                          key: const Key('model-button'),
                          onPressed: canCommand
                              ? () => showModelSheet(
                                  context,
                                  provider: state.selectedModelProvider,
                                  modelId: state.selectedModelId,
                                  thinking: state.thinkingLevel,
                                  onModel: actions.changeModel,
                                  onThinking: actions.setThinking,
                                )
                              : null,
                          style: TextButton.styleFrom(
                            backgroundColor: colors['fill.hover'],
                            shape: const StadiumBorder(),
                          ),
                          child: Text(
                            [
                              model?.name ??
                                  state.selectedModelId ??
                                  l10n.modelDefault,
                              if (state.thinkingLevel != null)
                                thinkingLabel(l10n, state.thinkingLevel),
                            ].join(' · '),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ),
                      if (active && canWrite) ...[
                        const SizedBox(width: 4),
                        _WhenToggle(
                          when: composer.when,
                          onChanged: actions.setWhen,
                        ),
                      ],
                      const Spacer(),
                      if (active)
                        Tooltip(
                          message: l10n.stopWork,
                          child: TextButton.icon(
                            key: const Key('stop-button'),
                            onPressed: online ? actions.stop : null,
                            icon: const Icon(LucideIcons.square, size: 14),
                            label: Text(l10n.stopWork),
                          ),
                        ),
                      IconButton.filled(
                        tooltip: l10n.send,
                        style: IconButton.styleFrom(
                          backgroundColor: colors['action.primary'],
                          foregroundColor: colors['action.onPrimary'],
                          disabledBackgroundColor: colors['surface.subtle'],
                          disabledForegroundColor: colors['text.faint'],
                        ),
                        onPressed: canSend
                            ? () => actions.send(
                                runActive: active,
                                confirmTakeover: (name) =>
                                    _confirmTakeover(context, name),
                              )
                            : null,
                        icon: composer.sending
                            ? const SizedBox.square(
                                dimension: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(LucideIcons.arrowUp),
                      ),
                      const SizedBox(width: 6),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Steer the current turn, or queue after it.
class _WhenToggle extends StatelessWidget {
  const _WhenToggle({required this.when, required this.onChanged});
  final SendWhen when;
  final ValueChanged<SendWhen> onChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return SegmentedButton<SendWhen>(
      showSelectedIcon: false,
      style: const ButtonStyle(visualDensity: VisualDensity.compact),
      segments: [
        ButtonSegment(value: SendWhen.steer, label: Text(l10n.whenSteer)),
        ButtonSegment(value: SendWhen.followUp, label: Text(l10n.whenQueue)),
      ],
      selected: {when},
      onSelectionChanged: (value) => onChanged(value.single),
    );
  }
}

class _Uncertain extends StatelessWidget {
  const _Uncertain({required this.checking, required this.onCheck});
  final bool checking;
  final VoidCallback onCheck;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final colors = PircColorTokens.of(context);
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 0, 12, 8),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        color: colors['status.warningSoft'],
        borderRadius: BorderRadius.circular(PircRadius.md),
      ),
      child: Row(
        children: [
          Icon(LucideIcons.circleHelp, size: 16, color: colors['text.warning']),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              l10n.notSureArrived,
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: colors['text.warning']),
            ),
          ),
          TextButton(
            onPressed: checking ? null : onCheck,
            child: Text(l10n.checkStatus),
          ),
        ],
      ),
    );
  }
}
