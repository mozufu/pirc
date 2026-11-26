import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:pirc_client/pirc_client.dart';
import 'package:pirc_ui/pirc_ui.dart';

import '../../l10n/app_localizations.dart';
import '../connection/data.dart';
import '../work/work_data.dart';
import 'chat_data.dart';
import 'handover_data.dart';
import 'handover_parts.dart';
import 'new_pot_screen.dart';
import 'thread_data.dart';

/// A handover (E14) in the Chat tab's content pane.
///
/// Started from a pot ([HandoverScreen.start], `handover-new:<potId>`):
/// pick the receiver (another pot or you), tick what it holds, and Next
/// proposes it; the screen then moves to the proposal
/// ([HandoverScreen.existing], `handover:<id>`), which shows each item's
/// fit at the receiver with its reason, Confirm (with the revision) and
/// Cancel (rejects the user's own proposal). A pot's own proposal has the
/// banner and only Confirm / Reject. A decided handover shows its result.
class HandoverScreen extends ConsumerStatefulWidget {
  const HandoverScreen.start({super.key, required String this.potId})
    : handoverId = null;

  const HandoverScreen.existing({super.key, required String this.handoverId})
    : potId = null;

  /// The pot to hand items over from (a new handover).
  final String? potId;

  /// The handover to show.
  final String? handoverId;

  @override
  ConsumerState<HandoverScreen> createState() => _HandoverScreenState();
}

class _HandoverScreenState extends ConsumerState<HandoverScreen> {
  HandoverTo? _to;
  final _ticked = <String>{};
  final _expanded = <String>{};
  bool _busy = false;
  String? _error;

  List<PotSummary> get _pots =>
      ref.watch(potsProvider).value ?? const <PotSummary>[];

  Future<void> _create(List<HeldItem> held) async {
    final api = ref.read(apiProvider);
    final to = _to;
    if (api == null || to == null || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final handover = await DecisionsApi(api).createHandover(
        fromPotId: widget.potId!,
        to: to,
        items: [
          for (final item in held)
            if (_ticked.contains(heldKey(item))) item,
        ],
      );
      if (mounted) context.go(chatLocation(handoverKey(handover.id)));
    } on PircException catch (error) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = error.message;
        });
      }
    }
  }

  /// Where the proposal goes back to: a pot's proposal to its
  /// conversation (its card), the user's own to the pot's profile.
  String _back(Handover handover) {
    final from = handover.fromPotId;
    if (from == null) return '/chat';
    return handover.proposedBy == 'pot'
        ? chatLocation(potChatKey(from))
        : potProfileLocation(from);
  }

  void _refresh(Handover handover) {
    ref.invalidate(handoverProvider(handover.id));
    ref.invalidate(potsProvider);
    for (final id in [handover.fromPotId, handover.to.potId]) {
      if (id == null) continue;
      ref.invalidate(potProvider(id));
      ref.invalidate(heldProvider(id));
    }
  }

  /// Confirms with the handover's revision, or rejects it; a refusal
  /// (another device decided, the handover changed) shows its message and
  /// reads the handover again.
  Future<void> _decide(Handover handover, {required bool confirm}) async {
    final api = ref.read(apiProvider);
    if (api == null || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final decisions = DecisionsApi(api);
    try {
      if (confirm) {
        await decisions.confirmHandover(
          handover.id,
          revision: handover.revision,
        );
      } else {
        await decisions.rejectHandover(handover.id);
      }
      _refresh(handover);
      if (mounted) context.go(_back(handover));
    } on PircException catch (error) {
      ref.invalidate(handoverProvider(handover.id));
      if (mounted) {
        setState(() {
          _busy = false;
          _error = error.message;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final handoverId = widget.handoverId;
    return handoverId == null ? _buildStart(context) : _buildExisting(context);
  }

  Widget _frame({
    required String subtitle,
    required Widget leading,
    required Widget body,
    Widget? actions,
  }) {
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      key: const ValueKey('handover-screen'),
      backgroundColor: PircColorTokens.of(context)['surface.grouped'],
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            PotTopBar(
              title: l10n.handoverTitle,
              subtitle: subtitle,
              leading: leading,
            ),
            Expanded(child: body),
            ?actions,
          ],
        ),
      ),
    );
  }

  Widget _failed(VoidCallback onRetry) {
    final l10n = AppLocalizations.of(context);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        spacing: 8,
        children: [
          Text(l10n.listFailed),
          OutlinedButton(onPressed: onRetry, child: Text(l10n.retry)),
        ],
      ),
    );
  }

  Widget _scroll(List<Widget> children) => SingleChildScrollView(
    key: const ValueKey('handover-scroll'),
    padding: const EdgeInsets.only(bottom: 16),
    child: narrow720(
      Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: children,
      ),
    ),
  );

  ReceiverCard _card(HandoverTo to, {required bool selected, bool tap = true}) {
    final l10n = AppLocalizations.of(context);
    final pot = to.kind == 'pot' ? potNamed(_pots, to.potId) : null;
    final full = to.kind == 'pot' && to.potId != null
        ? ref.watch(potProvider(to.potId!)).value
        : null;
    return ReceiverCard(
      key: ValueKey('receiver-${to.potId ?? to.kind}'),
      avatar: ReceiverAvatar(to: to, pot: pot),
      name: receiverName(l10n, to, _pots),
      subtitle: receiverSubtitle(l10n, to, pot: pot, full: full),
      selected: selected,
      onTap: tap && !_busy ? () => setState(() => _to = to) : null,
    );
  }

  void _toggle(String key) => setState(
    () => _expanded.contains(key) ? _expanded.remove(key) : _expanded.add(key),
  );

  Widget _buildStart(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final potId = widget.potId!;
    final pots = _pots;
    final from = potNamed(pots, potId);
    final full = ref.watch(potProvider(potId)).value;
    final threads = ref.watch(threadsProvider).value ?? const <PotThread>[];
    final heldValue = ref.watch(heldProvider(potId));
    final held = heldValue.value;
    final fromName = from?.name ?? full?.name ?? '';
    final to = _to;
    final candidates = [
      for (final pot in pots)
        if (pot.id != potId && pot.state != 'archived') HandoverTo.pot(pot.id),
      const HandoverTo.user(),
    ];
    bool same(HandoverTo a, HandoverTo? b) =>
        b != null && a.kind == b.kind && a.potId == b.potId;

    final Widget items;
    if (held == null) {
      items = heldValue.hasError
          ? _failed(() => ref.invalidate(heldProvider(potId)))
          : const Padding(
              padding: EdgeInsets.all(24),
              child: Center(child: CircularProgressIndicator()),
            );
    } else if (held.isEmpty) {
      items = GroupNote(l10n.handoverEmpty(fromName));
    } else {
      items = HandoverItemGroup(
        children: [
          for (final (i, item) in held.indexed)
            heldItemView(
              context,
              item,
              first: i == 0,
              from: full,
              threads: threads,
              checked: _ticked.contains(heldKey(item)),
              onChecked: _busy
                  ? null
                  : (on) => setState(
                      () => on
                          ? _ticked.add(heldKey(item))
                          : _ticked.remove(heldKey(item)),
                    ),
              expanded: _expanded.contains(heldKey(item)),
              onExpand: () => _toggle(heldKey(item)),
            ),
        ],
      );
    }
    final count = held == null
        ? 0
        : held.where((item) => _ticked.contains(heldKey(item))).length;
    return _frame(
      subtitle: l10n.handoverRoute(
        fromName,
        to == null ? '…' : receiverName(l10n, to, pots),
      ),
      leading: TopTextButton(
        key: const ValueKey('handover-cancel'),
        label: l10n.cancel,
        onPressed: () => context.go(handoverBackLocation(potId)),
      ),
      body: _scroll([
        GroupLabel(l10n.handoverWho),
        ReceiverCards(
          children: [
            for (final candidate in candidates)
              _card(candidate, selected: same(candidate, to)),
          ],
        ),
        GroupLabel(l10n.handoverItems),
        items,
        GroupNote(l10n.handoverNote(fromName)),
        if (_error != null)
          KeyedSubtree(
            key: const ValueKey('handover-error'),
            child: ErrorBox(_error!),
          ),
      ]),
      actions: BottomActions(
        primary: FilledButton(
          key: const ValueKey('handover-next'),
          style: inkButtonStyle(context),
          onPressed: _busy || to == null || count == 0 || held == null
              ? null
              : () => _create(held),
          child: _busy ? const ButtonSpinner() : Text(l10n.handoverNext),
        ),
      ),
    );
  }

  Widget _buildExisting(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final id = widget.handoverId!;
    final value = ref.watch(handoverProvider(id));
    final handover = value.value;
    if (handover == null) {
      return _frame(
        subtitle: '',
        leading: TopTextButton(
          label: l10n.cancel,
          onPressed: () => context.go('/chat'),
        ),
        body: value.hasError
            ? _failed(() => ref.invalidate(handoverProvider(id)))
            : const Center(child: CircularProgressIndicator()),
      );
    }
    final pots = _pots;
    final fromId = handover.fromPotId;
    final from = potNamed(pots, fromId);
    final full = fromId == null ? null : ref.watch(potProvider(fromId)).value;
    final threads = ref.watch(threadsProvider).value ?? const <PotThread>[];
    final fromName = from?.name ?? full?.name ?? '';
    final toName = receiverName(l10n, handover.to, pots);
    final pending = handover.state == 'proposed';
    final byPot = handover.proposedBy == 'pot';
    final movable = handover.items.where((e) => e.fit != 'stop').length;
    final gap = Localizations.localeOf(context).languageCode == 'zh' ? '' : ' ';
    final quoted = [
      for (final entry in handover.items) l10n.handoverQuoted(entry.item.label),
    ].join(l10n.potListSeparator);

    return _frame(
      subtitle: l10n.handoverRoute(fromName, toName),
      leading: TopTextButton(
        key: const ValueKey('handover-cancel'),
        label: l10n.cancel,
        // Leaving the user's own proposal withdraws it; a pot's waits.
        onPressed: _busy
            ? null
            : pending && !byPot
            ? () => _decide(handover, confirm: false)
            : () => context.go(_back(handover)),
      ),
      body: _scroll([
        if (pending && byPot)
          InfoBanner(
            key: const ValueKey('handover-banner'),
            lead: l10n.handoverProposedTitle(fromName),
            text: '$gap${l10n.handoverProposedText(quoted, toName)}',
            extra: handover.reason,
          )
        else if (!pending)
          InfoBanner(
            key: const ValueKey('handover-result'),
            text: handover.state == 'applied'
                ? l10n.handoverApplied
                : l10n.handoverRejected,
          ),
        GroupLabel(l10n.handoverWho),
        ReceiverCards(
          children: [_card(handover.to, selected: true, tap: false)],
        ),
        GroupLabel(l10n.handoverItems),
        HandoverItemGroup(
          children: [
            for (final (i, entry) in handover.items.indexed)
              heldItemView(
                context,
                entry.item,
                first: i == 0,
                from: full,
                threads: threads,
                checked: true,
                fit: handoverFit(entry.fit),
                fitText: fitText(l10n, entry.fit, entry.reason, handover.to),
                expanded: _expanded.contains(heldKey(entry.item)),
                onExpand: () => _toggle(heldKey(entry.item)),
              ),
          ],
        ),
        if (pending && movable == 0)
          GroupNote(
            l10n.handoverNothingFits(toName),
            key: const ValueKey('handover-nothing-fits'),
          ),
        if (pending) GroupNote(l10n.handoverNote(fromName)),
        if (_error != null)
          KeyedSubtree(
            key: const ValueKey('handover-error'),
            child: ErrorBox(_error!),
          ),
      ]),
      actions: pending
          ? BottomActions(
              secondary: FilledButton(
                key: const ValueKey('handover-reject'),
                style: plainButtonStyle(context),
                onPressed: _busy
                    ? null
                    : () => _decide(handover, confirm: false),
                child: Text(byPot ? l10n.handoverReject : l10n.cancel),
              ),
              primary: FilledButton(
                key: const ValueKey('handover-confirm'),
                style: inkButtonStyle(context),
                onPressed: _busy || movable == 0
                    ? null
                    : () => _decide(handover, confirm: true),
                child: _busy
                    ? const ButtonSpinner()
                    : Text(
                        l10n.handoverConfirm(movable, toName),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
              ),
            )
          : null,
    );
  }
}
