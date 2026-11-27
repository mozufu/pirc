import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:pirc_client/pirc_client.dart';
import 'package:pirc_ui/pirc_ui.dart';

import '../../l10n/app_localizations.dart';
import '../known_text.dart';
import '../connection/connection.dart';
import '../connection/data.dart';
import '../format.dart';
import '../work/questions.dart';
import '../work/session_controller.dart';
import '../work/work_side.dart';
import 'notification_open.dart';

/// A choice of a question as the compact read gave it: [id] is the answer's
/// `value`.
@immutable
class AnswerChoice {
  const AnswerChoice(this.id, this.label);
  final String id;
  final String label;
}

/// A question the check found still open, waiting for its conversation to
/// show the answer sheet with [choice] preselected.
@immutable
class NotificationAnswer {
  const NotificationAnswer({
    required this.sessionId,
    required this.interactionId,
    required this.title,
    required this.choices,
    required this.checkedAt,
    this.choice,
  });

  final String sessionId;
  final String interactionId;
  final String title;
  final List<AnswerChoice> choices;
  final int checkedAt;
  final String? choice;
}

final notificationAnswerProvider =
    NotifierProvider<NotificationAnswerInbox, NotificationAnswer?>(
      NotificationAnswerInbox.new,
    );

class NotificationAnswerInbox extends Notifier<NotificationAnswer?> {
  @override
  NotificationAnswer? build() => null;

  void put(NotificationAnswer answer) => state = answer;

  /// The conversation of [sessionId] takes the waiting answer, once.
  NotificationAnswer? take(String sessionId) {
    final answer = state;
    if (answer == null || answer.sessionId != sessionId) return null;
    state = null;
    return answer;
  }
}

/// How the check of a tapped question ended (C § 6.2). Still open and
/// controlled elsewhere continue in the conversation's answer sheet.
enum CheckResult { checking, answered, expired, offline }

/// "Reconnecting and checking the latest state": the whole page, without
/// buttons, until the question's compact state is read. Then the
/// conversation opens with the answer sheet, or the page says the question
/// was answered (by whom and when), expired, or could not be checked (the
/// tapped choice is kept, only "Retry").
class NotificationCheckScreen extends ConsumerStatefulWidget {
  const NotificationCheckScreen({super.key, required this.question});

  final QuestionOpen question;

  @override
  ConsumerState<NotificationCheckScreen> createState() =>
      _NotificationCheckScreenState();
}

class _NotificationCheckScreenState
    extends ConsumerState<NotificationCheckScreen> {
  CheckResult _result = CheckResult.checking;
  String? _answeredOn;
  int? _answeredAt;
  bool _reading = false;

  QuestionOpen get _q => widget.question;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _phase());
  }

  @override
  void didUpdateWidget(NotificationCheckScreen old) {
    super.didUpdateWidget(old);
    if (old.question.location != widget.question.location) {
      setState(() => _result = CheckResult.checking);
      _phase();
    }
  }

  /// Reads once the connection is online; offline is a result of its own.
  void _phase() {
    if (!mounted || _result != CheckResult.checking) return;
    switch (ref.read(connectionProvider).phase) {
      case ConnectionPhase.online:
        unawaited(_read());
      case ConnectionPhase.offline:
        setState(() => _result = CheckResult.offline);
      default:
        break;
    }
  }

  Future<void> _read() async {
    final api = ref.read(apiProvider);
    if (api == null || _reading) return;
    _reading = true;
    try {
      final reply = await api.get(
        '/api/sessions/${Uri.encodeComponent(_q.sessionId)}/interactions/'
        '${Uri.encodeComponent(_q.interactionId)}',
      );
      if (!mounted) return;
      final body = reply is Map ? reply : const {};
      final state = body['state'];
      final epoch = '${body['epoch']}';
      if (state == 'pending' && epoch == _q.epoch) {
        _open(body);
      } else if (state == 'answered') {
        final by = body['answeredBy'];
        setState(() {
          _result = CheckResult.answered;
          _answeredOn = by is Map ? by['deviceName'] as String? : null;
          _answeredAt = by is Map ? (by['at'] as num?)?.toInt() : null;
        });
      } else {
        setState(() => _result = CheckResult.expired);
      }
    } on ApiError catch (error) {
      if (!mounted) return;
      if (error.status == 404) {
        setState(() => _result = CheckResult.expired);
      } else if (!ref.read(connectionProvider.notifier).report(error)) {
        setState(() => _result = CheckResult.offline);
      }
    } on PircException {
      if (mounted) setState(() => _result = CheckResult.offline);
    } finally {
      _reading = false;
    }
  }

  /// Still open: the conversation, with the answer sheet when the question
  /// has choices (else its card in the conversation answers it).
  void _open(Map body) {
    final l10n = AppLocalizations.of(context);
    final choices = [
      for (final c in (body['choices'] as List? ?? const []).whereType<Map>())
        if ('${c['id'] ?? ''}'.isNotEmpty)
          AnswerChoice(
            '${c['id']}',
            // The agent's "Other" (`other`) in the app's words.
            c['other'] == true
                ? l10n.questionOther
                : '${c['label'] ?? c['id']}',
          ),
    ];
    final question = body['question'];
    if (choices.isNotEmpty) {
      ref
          .read(notificationAnswerProvider.notifier)
          .put(
            NotificationAnswer(
              sessionId: _q.sessionId,
              interactionId: _q.interactionId,
              title: question is Map
                  ? questionTitle(l10n, '${question['title'] ?? ''}')
                  : '',
              choices: choices,
              checkedAt: ref.read(clockProvider)().millisecondsSinceEpoch,
              // Only a choice the Gateway still offers stays preselected.
              choice: choices.any((c) => c.id == _q.choice) ? _q.choice : null,
            ),
          );
    }
    context.go(workLocation(_q.sessionId));
  }

  void _retry() {
    setState(() => _result = CheckResult.checking);
    final connection = ref.read(connectionProvider.notifier);
    if (ref.read(connectionProvider).phase == ConnectionPhase.online) {
      unawaited(_read());
    } else {
      connection.retryNow();
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(connectionProvider.select((s) => s.phase), (_, phase) {
      if (_result == CheckResult.checking) _phase();
    });
    final l10n = AppLocalizations.of(context);
    final colors = PircColorTokens.of(context);
    final text = Theme.of(context).textTheme;
    final conversation = FilledButton.tonal(
      onPressed: () => context.go(workLocation(_q.sessionId)),
      child: Text(l10n.notificationOpenConversation),
    );
    final (
      IconData? icon,
      String title,
      String? detail,
      Widget? action,
    ) = switch (_result) {
      CheckResult.checking => (null, l10n.notificationChecking, null, null),
      CheckResult.answered => (
        LucideIcons.circleCheck,
        l10n.notificationHandled,
        _answeredLine(context),
        conversation,
      ),
      CheckResult.expired => (
        LucideIcons.clock,
        l10n.notificationExpired,
        l10n.notificationExpiredDetail,
        conversation,
      ),
      CheckResult.offline => (
        LucideIcons.wifiOff,
        l10n.notificationOffline,
        _q.label == null ? null : l10n.notificationChoiceKept(_q.label!),
        FilledButton(onPressed: _retry, child: Text(l10n.retry)),
      ),
    };
    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: false,
        leading: _result == CheckResult.checking
            ? null
            : IconButton(
                tooltip: l10n.back,
                icon: const Icon(LucideIcons.chevronLeft),
                onPressed: () => context.go(workLocation(_q.sessionId)),
              ),
      ),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(PircSpacing.stackXl),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (icon == null)
                  const CircularProgressIndicator()
                else
                  Icon(icon, size: 40, color: colors['text.muted']),
                const SizedBox(height: PircSpacing.stackLg),
                Text(
                  title,
                  textAlign: TextAlign.center,
                  style: text.titleMedium,
                ),
                if (detail != null) ...[
                  const SizedBox(height: PircSpacing.stackSm),
                  Text(
                    detail,
                    textAlign: TextAlign.center,
                    style: text.bodySmall,
                  ),
                ],
                if (action != null) ...[
                  const SizedBox(height: PircSpacing.stackLg),
                  action,
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  String _answeredLine(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final who = _answeredOn == null || _answeredOn!.isEmpty
        ? l10n.anotherDevice
        : _answeredOn!;
    final at = _answeredAt;
    return at != null && at > 0
        ? l10n.answeredOn(
            who,
            clockTime(context, at, now: ref.read(clockProvider)()),
          )
        : l10n.answeredOnName(who);
  }
}

/// Shows the answer sheet over [child] (a conversation) when a checked
/// notification left an answer for [sessionId].
class NotificationAnswerOpener extends ConsumerStatefulWidget {
  const NotificationAnswerOpener({
    super.key,
    required this.sessionId,
    required this.child,
  });

  final String sessionId;
  final Widget child;

  @override
  ConsumerState<NotificationAnswerOpener> createState() =>
      _NotificationAnswerOpenerState();
}

class _NotificationAnswerOpenerState
    extends ConsumerState<NotificationAnswerOpener> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _check());
  }

  void _check() {
    if (!mounted) return;
    final answer = ref
        .read(notificationAnswerProvider.notifier)
        .take(widget.sessionId);
    if (answer == null) return;
    unawaited(
      showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        showDragHandle: true,
        builder: (_) => NotificationAnswerSheet(answer: answer),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(notificationAnswerProvider, (_, next) {
      if (next?.sessionId == widget.sessionId) {
        WidgetsBinding.instance.addPostFrameCallback((_) => _check());
      }
    });
    return widget.child;
  }
}

/// "Confirm your answer" (C screenshot 9): where the check came from, who
/// controls the session ("Take control" when another device does), the
/// question with the tapped choice preselected, Cancel and "Send answer".
/// Only "Send answer" sends, and only while this device controls the
/// session and the conversation still lists the question as open.
class NotificationAnswerSheet extends ConsumerStatefulWidget {
  const NotificationAnswerSheet({super.key, required this.answer});

  final NotificationAnswer answer;

  @override
  ConsumerState<NotificationAnswerSheet> createState() =>
      _NotificationAnswerSheetState();
}

class _NotificationAnswerSheetState
    extends ConsumerState<NotificationAnswerSheet> {
  late String? _picked = widget.answer.choice;
  bool _taking = false;

  NotificationAnswer get _a => widget.answer;

  Future<void> _takeControl() async {
    setState(() => _taking = true);
    await ref
        .read(sessionControllerProvider(_a.sessionId).notifier)
        .takeControl(force: true);
    if (mounted) setState(() => _taking = false);
  }

  Future<void> _send(Interaction interaction) async {
    final picked = _a.choices.firstWhere((c) => c.id == _picked);
    await ref.read(questionsProvider(_a.sessionId).notifier).answer(
      interaction,
      {'value': picked.id},
      picked.label,
    );
    if (!mounted) return;
    final failed = ref
        .read(questionsProvider(_a.sessionId))
        .errors
        .containsKey(interaction.id);
    if (!failed) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final colors = PircColorTokens.of(context);
    final text = Theme.of(context).textTheme;
    final view = ref.watch(sessionControllerProvider(_a.sessionId));
    final questions = ref.watch(questionsProvider(_a.sessionId));
    final interaction = view.state?.interactions
        .where((i) => i.id == _a.interactionId)
        .firstOrNull;
    final ended = interaction != null && interaction.status != 'pending';
    final sending = questions.sending.contains(_a.interactionId);
    final error = questions.errors[_a.interactionId];
    final other = view.control == ControlState.other;
    final holder = view.lease?.holder?.name;
    final checked = clockTime(
      context,
      _a.checkedAt,
      now: ref.read(clockProvider)(),
    );
    final canSend =
        _picked != null &&
        interaction != null &&
        !ended &&
        !other &&
        !sending &&
        !_taking;

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          PircSpacing.gutterPhone,
          0,
          PircSpacing.gutterPhone,
          PircSpacing.stackLg,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(l10n.answerSheetTitle, style: text.titleLarge),
            const SizedBox(height: PircSpacing.stackMd),
            Container(
              padding: const EdgeInsets.all(PircSpacing.stackMd),
              decoration: BoxDecoration(
                color: colors['fill.hover'],
                borderRadius: BorderRadius.circular(PircRadius.md),
              ),
              child: Row(
                children: [
                  Container(
                    width: 10,
                    height: 10,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: ended || other
                          ? colors['status.warning']
                          : colors['status.success'],
                    ),
                  ),
                  const SizedBox(width: PircSpacing.stackSm),
                  Expanded(
                    child: Text(
                      ended
                          ? l10n.notificationHandled
                          : other
                          ? l10n.answerSheetControlledBy(
                              holder == null || holder.isEmpty
                                  ? l10n.anotherDevice
                                  : holder,
                            )
                          : view.control == ControlState.mine
                          ? l10n.answerSheetCheckedHere(checked)
                          : l10n.answerSheetChecked(checked),
                      style: text.bodySmall,
                    ),
                  ),
                  if (other && !ended)
                    TextButton(
                      onPressed: _taking ? null : _takeControl,
                      child: Text(l10n.answerSheetTakeControl),
                    ),
                ],
              ),
            ),
            const SizedBox(height: PircSpacing.stackLg),
            if (_a.title.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: PircSpacing.stackMd),
                child: Text(_a.title, style: text.titleMedium),
              ),
            for (final choice in _a.choices)
              Padding(
                padding: const EdgeInsets.only(bottom: PircSpacing.stackSm),
                child: Material(
                  color: _picked == choice.id
                      ? colors['accent.soft']
                      : colors['fill.hover'],
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(PircRadius.md),
                    side: _picked == choice.id
                        ? BorderSide(color: colors['accent.default'])
                        : BorderSide.none,
                  ),
                  child: InkWell(
                    key: Key('answer-choice-${choice.id}'),
                    borderRadius: BorderRadius.circular(PircRadius.md),
                    onTap: ended || sending
                        ? null
                        : () => setState(() => _picked = choice.id),
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(minHeight: 48),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 8,
                        ),
                        child: Row(
                          children: [
                            Icon(
                              _picked == choice.id
                                  ? LucideIcons.circleDot
                                  : LucideIcons.circle,
                              size: 18,
                              color: _picked == choice.id
                                  ? colors['accent.default']
                                  : colors['text.faint'],
                            ),
                            const SizedBox(width: 12),
                            Expanded(child: Text(choice.label)),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            if (error != null)
              Padding(
                padding: const EdgeInsets.only(bottom: PircSpacing.stackSm),
                child: Text(
                  error,
                  style: text.bodySmall?.copyWith(
                    color: colors['status.danger'],
                  ),
                ),
              ),
            const SizedBox(height: PircSpacing.stackSm),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: Text(l10n.cancel),
                  ),
                ),
                const SizedBox(width: PircSpacing.stackMd),
                Expanded(
                  flex: 2,
                  child: FilledButton(
                    key: const Key('send-answer'),
                    onPressed: canSend ? () => _send(interaction) : null,
                    child: sending
                        ? const SizedBox.square(
                            dimension: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : Text(l10n.answerSheetSend),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
