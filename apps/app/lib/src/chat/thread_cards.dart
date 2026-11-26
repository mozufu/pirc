import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:pirc_client/pirc_client.dart';
import 'package:pirc_ui/pirc_ui.dart';

import '../../l10n/app_localizations.dart';
import '../connection/data.dart';
import '../format.dart';
import '../work/composer/model_sheet.dart';
import '../work/work_data.dart';
import '../work/work_list_screen.dart';
import '../work/work_side.dart';
import 'chat_data.dart';
import 'decision_sheet.dart';
import 'thread_data.dart';

/// The card of a system message, by `card.kind`. Each reads its item and
/// shows its current state; a decided one is a single line. [threadPots]
/// are the thread's pots (the loop guard pauses them with the initiator).
class ThreadCardView extends StatelessWidget {
  const ThreadCardView({
    super.key,
    required this.card,
    this.threadPots = const [],
    this.body = '',
  });

  final ThreadCard card;
  final List<String> threadPots;

  /// The message's text: shown for a card this app does not know.
  final String body;

  @override
  Widget build(BuildContext context) => switch (card) {
    ModelApprovalCard(:final approvalId) => ApprovalCardView(id: approvalId),
    BudgetRequestCard(:final requestId) => BudgetCardView(id: requestId),
    final WorkSessionCard work => WorkCardView(card: work),
    HandoverCard(:final handoverId) => HandoverCardView(id: handoverId),
    LoopGuardCard(:final rootId) => LoopGuardCardView(
      rootId: rootId,
      threadPots: threadPots,
    ),
    UnknownCard(:final kind) => ThreadNotice(
      text: body.isNotEmpty
          ? body
          : AppLocalizations.of(context).cardUnknown(kind),
    ),
  };
}

PotSummary? potById(WidgetRef ref, String? id) {
  if (id == null) return null;
  for (final pot in ref.watch(potsProvider).value ?? const <PotSummary>[]) {
    if (pot.id == id) return pot;
  }
  return null;
}

/// `c-btn.small` on top of an E sheet button style: 36 high, 14 px.
ButtonStyle _small(BuildContext context, ButtonStyle style) => style.copyWith(
  minimumSize: const WidgetStatePropertyAll(Size(0, 36)),
  padding: const WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 14)),
  textStyle: WidgetStatePropertyAll(
    Theme.of(
      context,
    ).textTheme.labelLarge?.copyWith(fontSize: 14, fontWeight: FontWeight.w500),
  ),
);

/// `c-btn.primary.small`: the accent fill.
ButtonStyle _primary(BuildContext context) {
  final colors = PircColorTokens.of(context);
  return _small(
    context,
    inkButtonStyle(context).copyWith(
      backgroundColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.disabled)
            ? colors['accent.default'].withValues(alpha: 0.5)
            : colors['accent.default'],
      ),
      foregroundColor: WidgetStatePropertyAll(colors['accent.on']),
    ),
  );
}

/// A small button of a card.
class _Button extends StatelessWidget {
  const _Button(this.label, this.kind, this.onPressed);

  final String label;

  /// `primary`, `plain` or `ghost`.
  final String kind;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final child = Text(label, maxLines: 1, overflow: TextOverflow.ellipsis);
    return switch (kind) {
      'ghost' => OutlinedButton(
        style: _small(context, ghostButtonStyle(context)),
        onPressed: onPressed,
        child: child,
      ),
      'plain' => FilledButton(
        style: _small(context, plainButtonStyle(context)),
        onPressed: onPressed,
        child: child,
      ),
      _ => FilledButton(
        style: _primary(context),
        onPressed: onPressed,
        child: child,
      ),
    };
  }
}

/// A card's buttons: the [secondary] one and the [main] one side by side,
/// then the [extra] one across (its label is long).
class _Actions extends StatelessWidget {
  const _Actions({required this.secondary, required this.main, this.extra});

  final Widget secondary;
  final Widget main;
  final Widget? extra;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    spacing: 8,
    children: [
      Row(
        spacing: 8,
        children: [
          Expanded(child: secondary),
          Expanded(child: main),
        ],
      ),
      ?extra,
    ],
  );
}

/// `c-int`: a decision waiting on the user, in the conversation: the title
/// (17/24, 600), the text (13.5 secondary), a meta line and the buttons.
class DecisionCard extends StatelessWidget {
  const DecisionCard({
    super.key,
    required this.title,
    this.body,
    this.meta,
    this.actions,
    this.error,
    this.onTap,
  });

  final String title;
  final String? body;
  final String? meta;
  final Widget? actions;
  final String? error;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final colors = PircColorTokens.of(context);
    final elevation = Theme.of(context).extension<PircElevationTokens>();
    final radius = BorderRadius.circular(PircRadius.lg);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors['surface.layer'],
        borderRadius: radius,
        boxShadow: elevation?.card,
      ),
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          borderRadius: radius,
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              spacing: 12,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    spacing: 2,
                    children: [
                      Text(
                        title,
                        style: TextStyle(
                          fontSize: 17,
                          height: 24 / 17,
                          fontWeight: FontWeight.w600,
                          color: colors['text.primary'],
                        ),
                      ),
                      if (body != null && body!.isNotEmpty)
                        Text(
                          body!,
                          style: TextStyle(
                            fontSize: 13.5,
                            height: 1.55,
                            color: colors['text.secondary'],
                          ),
                        ),
                    ],
                  ),
                ),
                if (meta != null && meta!.isNotEmpty)
                  Text(
                    meta!,
                    style: TextStyle(
                      fontSize: 12.5,
                      height: 18 / 12.5,
                      color: colors['text.muted'],
                    ),
                  ),
                ?actions,
                if (error != null)
                  Text(
                    error!,
                    style: TextStyle(
                      fontSize: 12.5,
                      height: 18 / 12.5,
                      color: colors['status.danger'],
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// `d-act`: a decided card in one line, with ✓ when it went ahead.
class DecidedLine extends StatelessWidget {
  const DecidedLine({
    super.key,
    required this.text,
    this.ok = true,
    this.onTap,
  });

  final String text;
  final bool ok;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final colors = PircColorTokens.of(context);
    final radius = BorderRadius.circular(PircRadius.md);
    return Material(
      color: colors['surface.subtle'],
      borderRadius: radius,
      child: InkWell(
        borderRadius: radius,
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 40),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            child: Row(
              spacing: 8,
              children: [
                Text(
                  ok ? '✓' : '✕',
                  style: TextStyle(
                    fontSize: 12.5,
                    height: 18 / 12.5,
                    fontWeight: FontWeight.w500,
                    color: ok ? colors['text.success'] : colors['text.muted'],
                  ),
                ),
                Expanded(
                  child: Text(
                    text,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13.5,
                      height: 19 / 13.5,
                      color: colors['text.secondary'],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A system message without a card (`e-hand`); names of known pots in
/// bold.
class ThreadNotice extends ConsumerWidget {
  const ThreadNotice({super.key, required this.text});

  final String text;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final names = [
      for (final pot in ref.watch(potsProvider).value ?? const <PotSummary>[])
        if (pot.name.isNotEmpty) pot.name,
    ]..sort((a, b) => b.length.compareTo(a.length));
    return HandoffLine(parts: noticeParts(text, names));
  }
}

/// [text] cut into plain parts and [names] (bold), trimmed at the cuts.
List<HandoffPart> noticeParts(String text, List<String> names) {
  if (names.isEmpty) return [HandoffPart(text)];
  final pattern = RegExp(names.map(RegExp.escape).join('|'));
  final parts = <HandoffPart>[];
  var at = 0;
  for (final match in pattern.allMatches(text)) {
    final before = text.substring(at, match.start).trim();
    if (before.isNotEmpty) parts.add(HandoffPart(before));
    parts.add(HandoffPart.name(match[0]!));
    at = match.end;
  }
  final rest = text.substring(at).trim();
  if (rest.isNotEmpty) parts.add(HandoffPart(rest));
  return parts.isEmpty ? [HandoffPart(text)] : parts;
}

/// While an item loads, or when it fails (a tap reads it again).
class _ItemState extends StatelessWidget {
  const _ItemState({required this.failed, required this.onRetry});

  final bool failed;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => failed
      ? DecidedLine(
          text: AppLocalizations.of(context).cardFailed,
          ok: false,
          onTap: onRetry,
        )
      : const SizedBox(height: 40);
}

/// `model_approval`: opens the approval sheet (E25).
class ApprovalCardView extends ConsumerWidget {
  const ApprovalCardView({super.key, required this.id});
  final String id;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final value = ref.watch(approvalProvider(id));
    final approval = value.value;
    if (approval == null) {
      return _ItemState(
        failed: value.hasError,
        onRetry: () => ref.invalidate(approvalProvider(id)),
      );
    }
    final potName = potById(ref, approval.potId)?.name ?? '';
    final models = ref.watch(modelsProvider).value ?? const <ModelInfo>[];
    final model =
        currentModel(models, approval.provider, approval.model)?.name ??
        approval.model;
    void open() => showApprovalSheet(context, id);
    if (approval.state != 'pending') {
      final answer = switch (approval.state) {
        'denied' => l10n.answeredDenied,
        'used' => l10n.answeredUsed,
        _ => l10n.answeredAllowedOnce,
      };
      return DecidedLine(
        key: ValueKey('card-approval-$id'),
        text: [answer, model, approval.workTitle].join(' · '),
        ok: approval.state != 'denied',
        onTap: open,
      );
    }
    return DecisionCard(
      key: ValueKey('card-approval-$id'),
      title: l10n.approvalSheetTitle(potName, model),
      body: [
        approval.workTitle,
        if (approval.reason.isNotEmpty) approval.reason,
      ].join(' · '),
      meta: approval.remainingMicros == null
          ? l10n.approvalEstimateNoLimit(usd(approval.estimateMicros))
          : l10n.approvalEstimate(
              usd(approval.estimateMicros),
              potName,
              usd(approval.remainingMicros!),
            ),
      onTap: open,
      actions: Align(
        alignment: Alignment.centerRight,
        child: _Button(l10n.cardReview, 'primary', open),
      ),
    );
  }
}

/// `budget_request`: Approve / Approve another amount / Deny in the card;
/// another amount opens the sheet on its field.
class BudgetCardView extends ConsumerStatefulWidget {
  const BudgetCardView({super.key, required this.id});
  final String id;

  @override
  ConsumerState<BudgetCardView> createState() => _BudgetCardViewState();
}

class _BudgetCardViewState extends ConsumerState<BudgetCardView> {
  bool _busy = false;
  String? _error;

  Future<void> _answer(String answer) async {
    final api = ref.read(apiProvider);
    if (api == null || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await answerBudgetRequest(ref, api, widget.id, answer: answer);
    } on PircException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final id = widget.id;
    final value = ref.watch(budgetRequestProvider(id));
    final request = value.value;
    if (request == null) {
      return _ItemState(
        failed: value.hasError,
        onRetry: () => ref.invalidate(budgetRequestProvider(id)),
      );
    }
    final pot = potById(ref, request.potId);
    final money = request.unit == 'money';
    String asked(int? micros, int? tokens) => money
        ? l10n.budgetMoreMoney(usd(micros ?? 0))
        : l10n.budgetMoreTokens(grouped(context, tokens ?? 0));
    if (!request.pending) {
      return DecidedLine(
        key: ValueKey('card-budget-$id'),
        text: switch (request.state) {
          'denied' =>
            '${l10n.answeredDenied} · ${asked(request.amountMicros, request.tokens)}',
          'approved_amount' => l10n.answeredApprovedAmount(
            asked(request.approvedAmountMicros, request.approvedTokens),
          ),
          _ =>
            '${l10n.answeredApproved} · ${asked(request.amountMicros, request.tokens)}',
        },
        ok: request.state != 'denied',
        onTap: () => showBudgetRequestSheet(context, id),
      );
    }
    final left = pot?.budgetLeft;
    final leftText = money
        ? (left?.moneyMicros == null
              ? null
              : l10n.budgetLeftMoney(usd(left!.moneyMicros!)))
        : (left?.tokens == null
              ? null
              : l10n.budgetLeftTokens(grouped(context, left!.tokens!)));
    final busy = _busy;
    return DecisionCard(
      key: ValueKey('card-budget-$id'),
      title: l10n.budgetSheetTitle(pot?.name ?? ''),
      body: [
        asked(request.amountMicros, request.tokens),
        if (request.reason.isNotEmpty) request.reason,
      ].join(' · '),
      meta: leftText,
      error: _error,
      actions: _Actions(
        secondary: _Button(
          l10n.deny,
          'ghost',
          busy ? null : () => _answer('deny'),
        ),
        main: _Button(
          l10n.approve,
          'primary',
          busy ? null : () => _answer('approve'),
        ),
        extra: _Button(
          l10n.approveOtherAmount,
          'plain',
          busy
              ? null
              : () => showBudgetRequestSheet(context, id, otherAmount: true),
        ),
      ),
    );
  }
}

/// `work`: the work's title and state; opens its conversation (M6).
class WorkCardView extends ConsumerWidget {
  const WorkCardView({super.key, required this.card});
  final WorkSessionCard card;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final value = ref.watch(potWorkProvider(card.workId));
    final work = value.value;
    Session? session;
    for (final s in ref.watch(sessionsProvider).value ?? const <Session>[]) {
      if (s.id == card.sessionId) session = s;
    }
    void open() {
      final known = session;
      if (known != null) {
        openWorkSession(context, ref, known);
      } else {
        context.go(workLocation(card.sessionId));
      }
    }

    if (work == null && value.hasError && session == null) {
      return DecidedLine(
        key: ValueKey('card-work-${card.workId}'),
        text: l10n.cardWorkMissing,
        ok: false,
        onTap: () => ref.invalidate(potWorkProvider(card.workId)),
      );
    }
    final coordinator = work == null
        ? null
        : work.state == 'taken_over'
        ? l10n.cardWorkTakenOver
        : l10n.cardWorkCoordinatedBy(potById(ref, work.potId)?.name ?? '');
    final muted = PircColorTokens.of(context)['text.muted'];
    // E spec § 3: ◐ running, ◆ waiting for you, ◷ queued.
    final (Widget? symbol, String? state) = switch (session?.runStatus) {
      'waiting_input' => (_Diamond(color: muted), l10n.stateWaiting),
      'running' => (const StateDot(DotState.running), l10n.stateRunning),
      'queued' => (
        Icon(LucideIcons.clock, size: 12, color: muted),
        l10n.stateQueued,
      ),
      'stopping' => (null, l10n.stateStopping),
      _ => switch (session) {
        null => (null, null),
        final s => (null, s.settled ? l10n.stateSettled : l10n.stateIdle),
      },
    };
    final lead = [?coordinator, ?session?.nodeId].join(' · ');
    return WorkCard(
      key: ValueKey('card-work-${card.workId}'),
      title: work?.title ?? session?.name ?? '',
      subtitle: TextSpan(
        children: [
          TextSpan(text: lead),
          if (state != null) ...[
            if (lead.isNotEmpty) const TextSpan(text: ' · '),
            if (symbol != null) ...[
              WidgetSpan(alignment: PlaceholderAlignment.middle, child: symbol),
              const TextSpan(text: ' '),
            ],
            TextSpan(text: state),
          ],
        ],
      ),
      onTap: open,
    );
  }
}

/// ◆: a filled diamond the size of the text.
class _Diamond extends StatelessWidget {
  const _Diamond({required this.color});
  final Color color;

  @override
  Widget build(BuildContext context) => Transform.rotate(
    angle: 0.785398,
    child: Container(width: 7.5, height: 7.5, color: color),
  );
}

/// `handover`: a pot's proposal; opens the handover (E14, step 8).
class HandoverCardView extends ConsumerWidget {
  const HandoverCardView({super.key, required this.id});
  final String id;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final value = ref.watch(handoverProvider(id));
    final handover = value.value;
    if (handover == null) {
      return _ItemState(
        failed: value.hasError,
        onRetry: () => ref.invalidate(handoverProvider(id)),
      );
    }
    void open() => context.go(chatLocation(handoverKey(id)));
    if (handover.state != 'proposed') {
      final applied = handover.state == 'applied';
      return DecidedLine(
        key: ValueKey('card-handover-$id'),
        text: applied ? l10n.cardHandoverApplied : l10n.cardHandoverRejected,
        ok: applied,
        onTap: open,
      );
    }
    final to = switch (handover.to.kind) {
      'user' => l10n.chatAuthorYou,
      _ => potById(ref, handover.to.potId)?.name ?? '',
    };
    return DecisionCard(
      key: ValueKey('card-handover-$id'),
      title: l10n.cardHandoverTitle(
        potById(ref, handover.fromPotId)?.name ?? '',
      ),
      body: handover.reason,
      meta: [
        l10n.cardHandoverTo(to),
        ...[for (final entry in handover.items) entry.item.label],
      ].join(' · '),
      onTap: open,
      actions: Align(
        alignment: Alignment.centerRight,
        child: _Button(l10n.cardReview, 'primary', open),
      ),
    );
  }
}

/// `loop_guard`: the loop guard suspended a chain. Resume or stop the
/// causal root, or pause the pots involved: the root's initiator and the
/// thread's pots (the API names no others).
class LoopGuardCardView extends ConsumerStatefulWidget {
  const LoopGuardCardView({
    super.key,
    required this.rootId,
    this.threadPots = const [],
  });

  final String rootId;
  final List<String> threadPots;

  @override
  ConsumerState<LoopGuardCardView> createState() => _LoopGuardCardViewState();
}

class _LoopGuardCardViewState extends ConsumerState<LoopGuardCardView> {
  bool _busy = false;
  String? _error;

  Future<void> _run(Future<void> Function(ApiClient api) action) async {
    final api = ref.read(apiProvider);
    if (api == null || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action(api);
    } on PircException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } finally {
      if (mounted) {
        ref.invalidate(causalRootProvider(widget.rootId));
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _stop() async {
    final l10n = AppLocalizations.of(context);
    final stop = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        content: Text(l10n.cardLoopStopConfirm),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(l10n.cancel),
          ),
          FilledButton(
            key: const ValueKey('confirm-stop-chain'),
            onPressed: () => Navigator.pop(context, true),
            child: Text(l10n.cardLoopStop),
          ),
        ],
      ),
    );
    if (stop != true) return;
    await _run((api) async => DecisionsApi(api).stopCausalRoot(widget.rootId));
  }

  Future<void> _pause(List<String> pots) => _run((api) async {
    final client = PotsApi(api);
    try {
      for (final id in pots) {
        // The summary has no revision: read the pot for it.
        final pot = await client.read(id);
        await client.pause(id, revision: pot.revision);
      }
    } finally {
      if (mounted) ref.invalidate(potsProvider);
    }
  });

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final id = widget.rootId;
    final value = ref.watch(causalRootProvider(id));
    final root = value.value;
    if (root == null) {
      return _ItemState(
        failed: value.hasError,
        onRetry: () => ref.invalidate(causalRootProvider(id)),
      );
    }
    if (!root.suspended) {
      final stopped = root.state == 'stopped';
      return DecidedLine(
        key: ValueKey('card-loop-$id'),
        text: stopped ? l10n.cardLoopStopped : l10n.cardLoopResumed,
        ok: !stopped,
      );
    }
    final involved = <String>{
      if (root.initiatorPot.isNotEmpty) root.initiatorPot,
      ...widget.threadPots,
    };
    final active = [
      for (final potId in involved)
        if (potById(ref, potId)?.state == 'active') potId,
    ];
    final allPaused = involved.isNotEmpty && active.isEmpty;
    final busy = _busy;
    return DecisionCard(
      key: ValueKey('card-loop-$id'),
      title: l10n.cardLoopTitle,
      body: l10n.cardLoopBody(
        potById(ref, root.initiatorPot)?.name ?? '',
        root.wakesSinceProgress,
        root.messagesSinceProgress,
      ),
      meta: [
        if (root.lastProgressAt > 0)
          l10n.cardLoopLastProgress(
            clockTime(
              context,
              root.lastProgressAt,
              now: ref.read(clockProvider)(),
            ),
          ),
        if (allPaused) l10n.cardLoopPotsPaused,
      ].join(' · '),
      error: _error,
      actions: _Actions(
        secondary: _Button(l10n.cardLoopStop, 'ghost', busy ? null : _stop),
        main: _Button(
          l10n.cardLoopResume,
          'primary',
          busy
              ? null
              : () =>
                    _run((api) async => DecisionsApi(api).resumeCausalRoot(id)),
        ),
        extra: active.isEmpty
            ? null
            : _Button(
                l10n.cardLoopPause,
                'plain',
                busy ? null : () => _pause(active),
              ),
      ),
    );
  }
}
