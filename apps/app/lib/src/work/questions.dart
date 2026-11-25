import 'dart:async';

import 'package:flutter/foundation.dart' show mapEquals;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:pirc_client/pirc_client.dart';
import 'package:pirc_ui/pirc_ui.dart';

import '../../l10n/app_localizations.dart';
import '../connection/connection.dart';
import '../connection/data.dart';
import '../format.dart';
import 'client_names.dart';
import 'session_controller.dart';

@immutable
class QuestionsState {
  const QuestionsState({
    this.sending = const {},
    this.answers = const {},
    this.ended = const {},
    this.errors = const {},
  });

  final Set<String> sending;

  /// This device's answer in one line, until the snapshot reports the end.
  final Map<String, String> answers;

  /// Questions that left an older snapshot without an end status: the one
  /// neutral fallback, used only when the backend does not say.
  final Map<String, Interaction> ended;
  final Map<String, String> errors;
}

final questionsProvider = NotifierProvider.autoDispose
    .family<QuestionsController, QuestionsState, String>(
      QuestionsController.new,
    );

/// Answers questions with
/// `POST /api/sessions/:id/interactions/:interactionId/answer`: any device may
/// answer without control, and the node keeps the first answer. Snapshots
/// carry how each question ended, so nothing is guessed from disappearance.
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
    final interactions = ref.read(provider).state?.interactions ?? const [];
    _resolveNames(interactions);
    ref.listen(
      provider.select((view) => view.state?.interactions),
      (_, next) => _seen(next ?? const []),
    );
    return const QuestionsState();
  }

  void _seen(List<Interaction> interactions) {
    final current = {
      for (final i in interactions)
        if (i.status == 'pending') i.id: i,
    };
    final ended = Map.of(state.ended);
    for (final MapEntry(:key, :value) in _pending.entries) {
      // A snapshot from an older Gateway says no status: only then fall back
      // to a neutral "ended" line when the question disappears.
      if (!current.containsKey(key) && !value.statusKnown) {
        ended[key] = value;
      }
    }
    ended.removeWhere((id, _) => current.containsKey(id));
    _pending
      ..clear()
      ..addAll(current);
    _resolveNames(interactions);
    if (!mapEquals(ended, state.ended)) {
      state = QuestionsState(
        sending: state.sending,
        answers: state.answers,
        ended: ended,
        errors: state.errors,
      );
    }
  }

  /// The names of answering clients come from the cached client list.
  void _resolveNames(List<Interaction> interactions) {
    final me = ref.read(clientIdProvider);
    for (final i in interactions) {
      if (i.answeredBy case final by? when by != me) {
        unawaited(ref.read(clientNamesProvider.notifier).resolve(by));
      }
    }
  }

  /// Sends [answer]; [summary] is the one line this device's card shows.
  Future<void> answer(
    Interaction interaction,
    Map<String, Object?> answer,
    String summary,
  ) async {
    final api = ref.read(apiProvider);
    if (api == null) return;
    state = QuestionsState(
      sending: {...state.sending, interaction.id},
      answers: state.answers,
      ended: state.ended,
      errors: {...state.errors}..remove(interaction.id),
    );
    String? error;
    var stale = false;
    try {
      await api.post(
        '/api/sessions/${Uri.encodeComponent(sessionId)}/interactions/'
        '${Uri.encodeComponent(interaction.id)}/answer',
        {'clientId': ref.read(clientIdProvider), 'answer': answer},
      );
    } on ApiError catch (e) {
      if (e.code == 'stale_interaction') {
        // Another device answered first, or the runner restarted. The fresh
        // snapshot says how it really ended; that is not an error.
        stale = true;
        unawaited(
          ref.read(sessionControllerProvider(sessionId).notifier).reload(),
        );
      } else {
        ref.read(connectionProvider.notifier).report(e);
        error = e.message;
      }
    } on PircException catch (e) {
      // A fatal error (pairing gone, app too old) is handled app-wide; the
      // question still did not get its answer.
      ref.read(connectionProvider.notifier).report(e);
      error = e.message;
    }
    state = QuestionsState(
      sending: {...state.sending}..remove(interaction.id),
      answers: error == null && !stale
          ? {...state.answers, interaction.id: summary}
          : state.answers,
      ended: state.ended,
      errors: error == null
          ? state.errors
          : {...state.errors, interaction.id: error},
    );
  }
}

/// The question cards below the last message: pending ones, then how each
/// ended as the backend reports it.
List<Widget> questionCards(String sessionId) => [
  _QuestionList(sessionId: sessionId),
];

class _QuestionList extends ConsumerWidget {
  const _QuestionList({required this.sessionId});
  final String sessionId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final interactions =
        ref.watch(sessionControllerProvider(sessionId)).state?.interactions ??
        const <Interaction>[];
    final questions = ref.watch(questionsProvider(sessionId));
    final cards = <Widget>[];
    final resolved = <Widget>[];
    for (final interaction in interactions) {
      if (interaction.status == 'pending') {
        final summary = questions.answers[interaction.id];
        if (summary != null) {
          resolved.add(
            _ResolvedLine(interaction: interaction, summary: summary),
          );
        } else {
          cards.add(
            QuestionCard(
              key: ValueKey('q-${interaction.id}'),
              sessionId: sessionId,
              interaction: interaction,
            ),
          );
        }
      } else {
        resolved.add(
          _ResolvedLine(
            interaction: interaction,
            summary: questions.answers[interaction.id],
          ),
        );
      }
    }
    for (final interaction in questions.ended.values) {
      if (!interactions.any((it) => it.id == interaction.id)) {
        resolved.add(_ResolvedLine(interaction: interaction));
      }
    }
    if (cards.isEmpty && resolved.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [...cards, ...resolved],
    );
  }
}

/// One ended question: the normal answered line for this device's answer,
/// otherwise how and where it ended.
class _ResolvedLine extends ConsumerWidget {
  const _ResolvedLine({required this.interaction, this.summary});
  final Interaction interaction;
  final String? summary;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final colors = PircColorTokens.of(context);
    final text = Theme.of(context).textTheme.bodySmall;
    final by = interaction.answeredBy;
    final name = by == null ? null : ref.watch(clientNamesProvider)[by]?.name;
    final mine = by != null && by == ref.read(clientIdProvider);
    final combined =
        summary != null || (mine && interaction.status == 'answered');
    final time = interaction.resolvedAt;
    final watcher = by == null ? null : ref.read(clockProvider)();
    final String status;
    final IconData icon;
    final Color color;
    if (summary != null) {
      status = '${interaction.title} · $summary';
      icon = LucideIcons.check;
      color = colors['status.success'];
    } else {
      switch (interaction.status) {
        case 'answered' when mine:
          status = '${interaction.title} · ${l10n.questionAnswered}';
          icon = LucideIcons.check;
          color = colors['status.success'];
        case 'answered':
          final who = name == null || name.isEmpty ? l10n.anotherDevice : name;
          status = time != null && time > 0
              ? l10n.answeredOn(who, clockTime(context, time, now: watcher))
              : l10n.answeredOnName(who);
          icon = LucideIcons.monitorSmartphone;
          color = colors['text.muted'];
        case 'cancelled':
          status = l10n.questionWithdrawn;
          icon = LucideIcons.x;
          color = colors['text.muted'];
        case 'expired':
          status = l10n.questionExpired;
          icon = LucideIcons.clock;
          color = colors['text.muted'];
        case 'stale':
          status = l10n.questionStale;
          icon = LucideIcons.refreshCw;
          color = colors['text.muted'];
        default:
          status = l10n.questionEnded(interaction.title);
          icon = LucideIcons.circleHelp;
          color = colors['text.muted'];
      }
    }
    return Padding(
      padding: const EdgeInsets.only(top: PircSpacing.stackXs),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: PircSpacing.stackXs),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (!combined)
                  Text(
                    interaction.title,
                    style: text,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                Text(
                  status,
                  style: text,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// `c-int`: a question from the agent. Any device may answer; states are
/// waiting, sending and expired (no buttons). Kinds: select, confirm, input,
/// editor.
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
    final sending = questions.sending.contains(_q.id);
    final expired = _expired;
    final enabled = !sending && !expired;
    final error = questions.errors[_q.id];

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
