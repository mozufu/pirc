import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:pirc_client/pirc_client.dart';
import 'package:pirc_ui/pirc_ui.dart';

import '../../l10n/app_localizations.dart';
import '../connection/connection.dart';
import '../connection/data.dart';
import '../format.dart';
import 'session_controller.dart';

/// What happened to a question that left the pending list.
@immutable
class ResolvedQuestion {
  const ResolvedQuestion(
    this.interaction, {
    this.summary,
    this.elsewhere = false,
  });
  final Interaction interaction;

  /// This device's answer in one line.
  final String? summary;

  /// Another device answered it.
  final bool elsewhere;
}

@immutable
class QuestionsState {
  const QuestionsState({
    this.sending = const {},
    this.resolved = const {},
    this.errors = const {},
  });

  final Set<String> sending;
  final Map<String, ResolvedQuestion> resolved;
  final Map<String, String> errors;
}

final questionsProvider = NotifierProvider.autoDispose
    .family<QuestionsController, QuestionsState, String>(
      QuestionsController.new,
    );

/// Answers questions with
/// `POST /api/sessions/:id/interactions/:interactionId/answer`. A `relay.*`
/// interaction needs no lease. A pending question that disappears without
/// this device's answer was "handled elsewhere".
class QuestionsController extends Notifier<QuestionsState> {
  QuestionsController(this.sessionId);
  final String sessionId;

  final _pending = <String, Interaction>{};

  @override
  QuestionsState build() {
    final provider = sessionControllerProvider(sessionId);
    _pending
      ..clear()
      ..addAll({
        for (final i in ref.read(provider).state?.interactions ?? const [])
          if (i.status == 'pending') i.id: i,
      });
    ref.listen(
      provider.select((view) => view.state?.interactions),
      (_, next) => _seen(next ?? const []),
    );
    return const QuestionsState();
  }

  void _seen(List<Interaction> interactions) {
    final now = {
      for (final i in interactions)
        if (i.status == 'pending') i.id: i,
    };
    final resolved = Map.of(state.resolved);
    for (final MapEntry(:key, :value) in _pending.entries) {
      if (!now.containsKey(key) && !resolved.containsKey(key)) {
        resolved[key] = ResolvedQuestion(value, elsewhere: true);
      }
    }
    _pending
      ..clear()
      ..addAll(now);
    if (resolved.length != state.resolved.length) {
      state = QuestionsState(
        sending: state.sending,
        resolved: resolved,
        errors: state.errors,
      );
    }
  }

  static bool isRelay(Interaction interaction) =>
      interaction.id.startsWith('relay.');

  /// Sends [answer]; [summary] is the one line the answered card shows.
  Future<void> answer(
    Interaction interaction,
    Map<String, Object?> answer,
    String summary,
  ) async {
    final api = ref.read(apiProvider);
    final lease = ref
        .read(sessionControllerProvider(sessionId).notifier)
        .heldLease;
    final relay = isRelay(interaction);
    if (api == null || (!relay && lease == null)) return;
    state = QuestionsState(
      sending: {...state.sending, interaction.id},
      resolved: state.resolved,
      errors: {...state.errors}..remove(interaction.id),
    );
    String? error;
    try {
      await api.post(
        '/api/sessions/${Uri.encodeComponent(sessionId)}/interactions/'
        '${Uri.encodeComponent(interaction.id)}/answer',
        {
          if (!relay) 'clientId': lease!.clientId,
          if (!relay) 'generation': lease!.generation,
          'answer': answer,
        },
      );
    } on LostControl {
      ref.read(sessionControllerProvider(sessionId).notifier).lostControl();
      error = 'lost_control';
    } on PircException catch (e) {
      if (!ref.read(connectionProvider.notifier).report(e)) error = e.message;
    }
    state = QuestionsState(
      sending: {...state.sending}..remove(interaction.id),
      resolved: error == null
          ? {
              ...state.resolved,
              interaction.id: ResolvedQuestion(interaction, summary: summary),
            }
          : state.resolved,
      errors: error == null
          ? state.errors
          : {...state.errors, interaction.id: error},
    );
  }
}

/// The question cards below the last message: pending ones, then the ones
/// answered here (one line) or elsewhere.
List<Widget> questionCards(String sessionId, SessionView view) => [
  for (final interaction in view.state?.interactions ?? const <Interaction>[])
    if (interaction.status == 'pending')
      QuestionCard(
        key: ValueKey('q-${interaction.id}'),
        sessionId: sessionId,
        interaction: interaction,
      ),
  _Resolved(sessionId: sessionId),
];

class _Resolved extends ConsumerWidget {
  const _Resolved({required this.sessionId});
  final String sessionId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final colors = PircColorTokens.of(context);
    final resolved = ref.watch(questionsProvider(sessionId)).resolved.values;
    if (resolved.isEmpty) return const SizedBox.shrink();
    final text = Theme.of(context).textTheme.bodySmall;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final item in resolved)
          Padding(
            padding: const EdgeInsets.only(top: PircSpacing.stackXs),
            child: Row(
              children: [
                Icon(
                  item.elsewhere
                      ? LucideIcons.monitorSmartphone
                      : LucideIcons.check,
                  size: 14,
                  color: item.elsewhere
                      ? colors['text.muted']
                      : colors['status.success'],
                ),
                const SizedBox(width: PircSpacing.stackXs),
                Expanded(
                  child: Text(
                    item.elsewhere
                        ? l10n.handledElsewhere(item.interaction.title)
                        : '${item.interaction.title} · ${item.summary}',
                    style: text,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

/// `c-int`: a question from the agent. States: waiting, sending, expired
/// (no buttons) and "control is on another device" (Send disabled, with
/// "Take control"). Kinds: select, confirm, input, editor.
class QuestionCard extends ConsumerStatefulWidget {
  const QuestionCard({
    super.key,
    required this.sessionId,
    required this.interaction,
  });

  final String sessionId;
  final Interaction interaction;

  @override
  ConsumerState<QuestionCard> createState() => _QuestionCardState();
}

class _QuestionCardState extends ConsumerState<QuestionCard> {
  final _picked = <String>{};
  late final _text = TextEditingController(
    text: widget.interaction.initialValue ?? '',
  );
  Timer? _expiry;

  Interaction get _q => widget.interaction;

  @override
  void initState() {
    super.initState();
    _armExpiry();
  }

  void _armExpiry() {
    final at = _q.expiresAt;
    if (at == null) return;
    final left = at - ref.read(clockProvider)().millisecondsSinceEpoch;
    if (left > 0) {
      _expiry = Timer(Duration(milliseconds: left), () {
        if (mounted) setState(() {});
      });
    }
  }

  @override
  void dispose() {
    _expiry?.cancel();
    _text.dispose();
    super.dispose();
  }

  bool get _expired {
    final at = _q.expiresAt;
    return at != null && at <= ref.read(clockProvider)().millisecondsSinceEpoch;
  }

  void _send(Map<String, Object?> answer, String summary) => ref
      .read(questionsProvider(widget.sessionId).notifier)
      .answer(_q, answer, summary);

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final colors = PircColorTokens.of(context);
    final text = Theme.of(context).textTheme;
    final questions = ref.watch(questionsProvider(widget.sessionId));
    final view = ref.watch(sessionControllerProvider(widget.sessionId));
    final sending = questions.sending.contains(_q.id);
    final expired = _expired;
    final relay = QuestionsController.isRelay(_q);
    final controlled = relay || view.control == ControlState.mine;
    final enabled = controlled && !sending && !expired;
    final error = switch (questions.errors[_q.id]) {
      null => null,
      'lost_control' => l10n.controlledElsewhere,
      final message => message,
    };

    Widget body;
    Map<String, Object?>? answer;
    String summary = '';
    switch (_q.kind) {
      case 'select':
        body = Column(
          children: [
            for (final option in _q.options)
              _Option(
                label: option.label,
                description: option.description,
                selected: _picked.contains(option.value),
                multiple: _q.multiple,
                enabled: enabled,
                onTap: () => setState(() {
                  if (_q.multiple) {
                    _picked.contains(option.value)
                        ? _picked.remove(option.value)
                        : _picked.add(option.value);
                  } else {
                    _picked
                      ..clear()
                      ..add(option.value);
                  }
                }),
              ),
          ],
        );
        if (_picked.isNotEmpty) {
          final values = [
            for (final option in _q.options)
              if (_picked.contains(option.value)) option.value,
          ];
          answer = _q.multiple
              ? {'value': values.join(', '), 'values': values}
              : {'value': values.single};
          summary = [
            for (final option in _q.options)
              if (_picked.contains(option.value)) option.label,
          ].join(', ');
        }
      case 'confirm':
        body = const SizedBox.shrink();
      default:
        body = TextField(
          key: Key('answer-${_q.id}'),
          controller: _text,
          enabled: enabled,
          minLines: _q.kind == 'editor' ? 4 : 1,
          maxLines: _q.kind == 'editor' ? 12 : 4,
          style: _q.kind == 'editor'
              ? PircType.monoCode.style(color: colors['text.primary'])
              : null,
          onChanged: (_) => setState(() {}),
          decoration: InputDecoration(
            hintText: _q.placeholder,
            filled: true,
            fillColor: colors['fill.hover'],
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(PircRadius.md),
              borderSide: BorderSide.none,
            ),
          ),
        );
        if (_text.text.trim().isNotEmpty) {
          answer = {'value': _text.text};
          summary = _text.text.trim().split('\n').first;
        }
    }

    final actions = <Widget>[
      if (expired)
        Text(l10n.questionExpired, style: text.bodySmall)
      else if (_q.expiresAt != null)
        Text(
          l10n.expiresAt(
            clockTime(context, _q.expiresAt!, now: ref.read(clockProvider)()),
          ),
          style: text.bodySmall?.copyWith(color: colors['text.warning']),
        ),
      const Spacer(),
      if (!expired && !controlled)
        TextButton(
          onPressed: () => ref
              .read(sessionControllerProvider(widget.sessionId).notifier)
              .takeControl(force: true),
          child: Text(l10n.takeControl),
        ),
      if (!expired && _q.kind == 'confirm') ...[
        OutlinedButton(
          onPressed: enabled
              ? () => _send({'confirmed': false}, _q.cancelLabel ?? l10n.no)
              : null,
          child: Text(_q.cancelLabel ?? l10n.no),
        ),
        const SizedBox(width: PircSpacing.stackSm),
        FilledButton(
          onPressed: enabled
              ? () => _send({'confirmed': true}, _q.confirmLabel ?? l10n.yes)
              : null,
          child: Text(_q.confirmLabel ?? l10n.yes),
        ),
      ] else if (!expired) ...[
        TextButton(
          onPressed: enabled
              ? () => _send({'cancelled': true}, l10n.questionSkipped)
              : null,
          child: Text(l10n.skip),
        ),
        const SizedBox(width: PircSpacing.stackSm),
        FilledButton(
          key: Key('send-answer-${_q.id}'),
          onPressed: enabled && answer != null
              ? () => _send(answer!, summary)
              : null,
          child: sending
              ? const SizedBox.square(
                  dimension: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text(l10n.send),
        ),
      ],
    ];

    return Opacity(
      opacity: expired ? 0.6 : 1,
      child: Container(
        padding: const EdgeInsets.all(PircSpacing.stackLg),
        decoration: BoxDecoration(
          color: colors['surface.layer'],
          borderRadius: BorderRadius.circular(PircRadius.lg),
          boxShadow: Theme.of(context).extension<PircElevationTokens>()?.card,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                CircleAvatar(
                  radius: 16,
                  backgroundColor: colors['accent.soft'],
                  child: Icon(
                    LucideIcons.circleHelp,
                    size: 18,
                    color: colors['accent.default'],
                  ),
                ),
                const SizedBox(width: PircSpacing.stackMd),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(_q.title, style: text.titleMedium),
                      if (_q.description?.isNotEmpty ?? false)
                        Text(_q.description!, style: text.bodySmall),
                      if (!controlled && !expired)
                        Text(l10n.controlledElsewhere, style: text.bodySmall),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: PircSpacing.stackMd),
            body,
            if (error != null)
              Padding(
                padding: const EdgeInsets.only(top: PircSpacing.stackXs),
                child: Text(
                  error,
                  style: text.bodySmall?.copyWith(
                    color: colors['status.danger'],
                  ),
                ),
              ),
            const SizedBox(height: PircSpacing.stackSm),
            Row(children: actions),
          ],
        ),
      ),
    );
  }
}

class _Option extends StatelessWidget {
  const _Option({
    required this.label,
    required this.selected,
    required this.multiple,
    required this.enabled,
    required this.onTap,
    this.description,
  });

  final String label;
  final String? description;
  final bool selected;
  final bool multiple;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = PircColorTokens.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: PircSpacing.stackSm),
      child: Material(
        color: selected ? colors['accent.soft'] : colors['fill.hover'],
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(PircRadius.md),
          side: selected
              ? BorderSide(color: colors['accent.default'])
              : BorderSide.none,
        ),
        child: InkWell(
          onTap: enabled ? onTap : null,
          borderRadius: BorderRadius.circular(PircRadius.md),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 48),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(
                children: [
                  Icon(
                    multiple
                        ? (selected
                              ? LucideIcons.squareCheck
                              : LucideIcons.square)
                        : (selected
                              ? LucideIcons.circleDot
                              : LucideIcons.circle),
                    size: 18,
                    color: selected
                        ? colors['accent.default']
                        : colors['text.faint'],
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(label),
                        if (description != null)
                          Text(
                            description!,
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The approval mode control (`set_approval_mode`): read only, auto, full
/// access. Full access asks first.
class ApprovalModeButton extends ConsumerWidget {
  const ApprovalModeButton({
    super.key,
    required this.mode,
    required this.enabled,
    required this.onSelected,
  });

  final String? mode;
  final bool enabled;
  final ValueChanged<String> onSelected;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    String label(String? mode) => switch (mode) {
      'read-only' => l10n.approvalReadOnly,
      'full-access' => l10n.approvalFullAccess,
      _ => l10n.approvalAuto,
    };
    return PopupMenuButton<String>(
      tooltip: l10n.approvalMode,
      enabled: enabled,
      icon: Icon(
        mode == 'full-access'
            ? LucideIcons.shieldOff
            : mode == 'read-only'
            ? LucideIcons.shieldCheck
            : LucideIcons.shield,
      ),
      initialValue: mode,
      onSelected: (next) async {
        if (next == mode) return;
        if (next == 'full-access') {
          final sure = await showDialog<bool>(
            context: context,
            builder: (context) => AlertDialog(
              title: Text(l10n.approvalFullAccess),
              content: Text(l10n.approvalFullAccessWarning),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: Text(l10n.cancel),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(context, true),
                  child: Text(l10n.approvalFullAccessConfirm),
                ),
              ],
            ),
          );
          if (sure != true) return;
        }
        onSelected(next);
      },
      itemBuilder: (context) => [
        for (final value in const ['read-only', 'auto', 'full-access'])
          CheckedPopupMenuItem(
            value: value,
            checked: value == (mode ?? 'auto'),
            child: Text(label(value)),
          ),
      ],
    );
  }
}
