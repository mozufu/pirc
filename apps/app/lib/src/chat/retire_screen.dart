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

/// Archive or delete a pot (E15–E17) in the Chat tab's content pane.
///
/// Segmented Archive / Delete; every item the pot holds gets a target
/// (another pot, you, or no one; a work starts with you, the rest with no
/// one), one by one or with "Give everything to…" (the pick sheet, E17,
/// which shows each choice's fit). Tapping an item shows what it needs and
/// does, and "Adjust ○○'s permissions…" opens the receiver's settings at
/// step ③ (it never changes a permission itself). The preview
/// (`…/retire/preview`, read again on every change and on hints) gives
/// each item's fit, what will stop and what is kept; the button hands over
/// and archives or deletes with the preview's revision. Delete asks once
/// more with the pot's name typed. Afterwards the app returns to the Chat
/// tab.
class RetireScreen extends ConsumerStatefulWidget {
  const RetireScreen({super.key, required this.potId});

  final String potId;

  @override
  ConsumerState<RetireScreen> createState() => _RetireScreenState();
}

class _RetireScreenState extends ConsumerState<RetireScreen> {
  String _mode = 'archive';
  final _targets = <String, HandoverTo>{};
  final _expanded = <String>{};
  bool _busy = false;
  String? _error;

  /// The last preview read, shown while the next one loads.
  RetirePreview? _shown;

  HandoverTo _targetOf(HeldItem item) =>
      _targets[heldKey(item)] ??
      (item.kind == 'work' ? const HandoverTo.user() : const HandoverTo.none());

  RetirePlan _plan(String mode, List<HeldItem> held) => RetirePlan(
    widget.potId,
    mode,
    [for (final item in held) RetireTarget(item: item, to: _targetOf(item))],
  );

  Future<void> _pick(String mode, List<HeldItem> held, {HeldItem? item}) async {
    final chosen = await showModalBottomSheet<HandoverTo>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      useRootNavigator: true,
      builder: (context) => SafeArea(
        child: SingleChildScrollView(
          child: _PickSheet(
            potId: widget.potId,
            mode: mode,
            held: held,
            item: item,
            current: item == null ? null : _targetOf(item),
          ),
        ),
      ),
    );
    if (chosen == null || !mounted) return;
    setState(() {
      for (final each in item == null ? held : [item]) {
        _targets[heldKey(each)] = chosen;
      }
    });
  }

  Future<bool> _confirmDelete(String name) async {
    final sure = await showDialog<bool>(
      context: context,
      builder: (dialog) => _DeleteDialog(name: name),
    );
    return sure == true;
  }

  Future<void> _retire(
    String mode,
    RetirePlan plan,
    RetirePreview preview,
    String name,
  ) async {
    final api = ref.read(apiProvider);
    if (api == null || _busy) return;
    if (mode == 'delete' && !await _confirmDelete(name)) return;
    if (!mounted) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await PotsApi(api).retire(
        widget.potId,
        mode: mode,
        revision: preview.revision,
        targets: plan.targets,
      );
      ref.invalidate(potsProvider);
      ref.invalidate(threadsProvider);
      for (final target in plan.targets) {
        final to = target.to.potId;
        if (to != null) ref.invalidate(heldProvider(to));
      }
      // An archived pot is not in the Chat tab; a deleted pot's thread is
      // read-only there.
      if (mounted) context.go('/chat');
    } on PircException catch (error) {
      // The pot changed: the preview is read again with its new revision.
      if (error is ApiError && error.status == 409) {
        ref.invalidate(retirePreviewProvider(plan));
      }
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
    final l10n = AppLocalizations.of(context);
    final colors = PircColorTokens.of(context);
    final potId = widget.potId;
    final pots = ref.watch(potsProvider).value ?? const <PotSummary>[];
    final full = ref.watch(potProvider(potId)).value;
    final threads = ref.watch(threadsProvider).value ?? const <PotThread>[];
    final name = full?.name ?? potNamed(pots, potId)?.name ?? '';
    // An archived pot can only be deleted.
    final archived = full?.state == 'archived';
    final mode = archived ? 'delete' : _mode;
    final heldValue = ref.watch(heldProvider(potId));
    final held = heldValue.value;
    final plan = held == null ? null : _plan(mode, held);
    final previewValue = plan == null
        ? null
        : ref.watch(retirePreviewProvider(plan));
    final current = previewValue?.value;
    if (current != null) _shown = current;
    final preview = current ?? _shown;
    final previewError = previewValue?.error;

    RetireItem? previewOf(HeldItem item) {
      final to = _targetOf(item);
      for (final entry in preview?.items ?? const <RetireItem>[]) {
        if (entry.item.kind == item.kind &&
            entry.item.ref == item.ref &&
            entry.to.kind == to.kind &&
            entry.to.potId == to.potId) {
          return entry;
        }
      }
      return null;
    }

    final children = <Widget>[];
    if (held == null) {
      children.add(
        heldValue.hasError
            ? _Failed(onRetry: () => ref.invalidate(heldProvider(potId)))
            : const Padding(
                padding: EdgeInsets.all(24),
                child: Center(child: CircularProgressIndicator()),
              ),
      );
    } else {
      children
        ..add(GroupLabel(l10n.retireItems(held.length)))
        ..add(
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Row(
              spacing: 8,
              children: [
                Expanded(
                  child: Text(
                    l10n.retireItemsNote,
                    style: TextStyle(
                      fontSize: 12.5,
                      height: 18 / 12.5,
                      color: colors['text.muted'],
                    ),
                  ),
                ),
                if (held.isNotEmpty)
                  HandoverTarget(
                    key: const ValueKey('retire-give-all'),
                    label: l10n.retireGiveAll,
                    color: colors['surface.layer'],
                    onTap: _busy ? null : () => _pick(mode, held),
                  ),
              ],
            ),
          ),
        );
      if (held.isNotEmpty) {
        children.add(
          HandoverItemGroup(
            children: [
              for (final (i, item) in held.indexed)
                _item(
                  context,
                  item,
                  first: i == 0,
                  from: full,
                  pots: pots,
                  threads: threads,
                  entry: previewOf(item),
                  onPick: _busy ? null : () => _pick(mode, held, item: item),
                ),
            ],
          ),
        );
      }
    }
    if (preview != null) {
      children
        ..add(GroupLabel(l10n.retireStops))
        ..add(
          _Lines(
            key: const ValueKey('retire-stops'),
            lines: preview.stops,
            stop: true,
          ),
        )
        ..add(GroupLabel(l10n.retireKept))
        ..add(_Lines(key: const ValueKey('retire-kept'), lines: preview.kept));
    } else if (previewError != null) {
      children.add(
        ErrorBox(
          previewError is PircException
              ? previewError.message
              : l10n.listFailed,
        ),
      );
    }
    if (_error != null) {
      children.add(
        KeyedSubtree(
          key: const ValueKey('retire-error'),
          child: ErrorBox(_error!),
        ),
      );
    }

    return Scaffold(
      key: const ValueKey('retire-screen'),
      backgroundColor: colors['surface.grouped'],
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            PotTopBar(
              title: l10n.retireTitle(name),
              subtitle: l10n.retireSubtitle,
              leading: TopTextButton(
                key: const ValueKey('retire-cancel'),
                label: l10n.cancel,
                onPressed: () => context.go(potSettingsLocation(potId)),
              ),
            ),
            narrow720(
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
                child: Segmented<String>(
                  key: const ValueKey('retire-mode'),
                  strong: true,
                  semanticLabel: l10n.retireTitle(name),
                  items: [
                    SegmentedItem('archive', l10n.retireArchive),
                    SegmentedItem('delete', l10n.retireDelete),
                  ],
                  selected: mode,
                  onSelected: archived || _busy
                      ? null
                      : (value) => setState(() => _mode = value),
                ),
              ),
            ),
            narrow720(
              GroupNote(
                mode == 'archive'
                    ? l10n.retireArchiveNote
                    : l10n.retireDeleteNote,
                padding: const EdgeInsets.fromLTRB(32, 8, 32, 4),
              ),
            ),
            Expanded(
              child: SingleChildScrollView(
                key: const ValueKey('retire-scroll'),
                padding: const EdgeInsets.only(bottom: 16),
                child: narrow720(
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: children,
                  ),
                ),
              ),
            ),
            BottomActions(
              primary: FilledButton(
                key: const ValueKey('retire-confirm'),
                style: inkButtonStyle(context),
                onPressed: _busy || plan == null || current == null
                    ? null
                    : () => _retire(mode, plan, current, name),
                child: _busy
                    ? const ButtonSpinner()
                    : Text(
                        mode == 'archive'
                            ? l10n.retireArchiveButton(name)
                            : l10n.retireDeleteButton(name),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _item(
    BuildContext context,
    HeldItem item, {
    required bool first,
    required Pot? from,
    required List<PotSummary> pots,
    required List<PotThread> threads,
    required RetireItem? entry,
    required VoidCallback? onPick,
  }) {
    final l10n = AppLocalizations.of(context);
    final colors = PircColorTokens.of(context);
    final key = heldKey(item);
    final to = _targetOf(item);
    final toPot = to.kind == 'pot' ? potNamed(pots, to.potId) : null;
    final toName = receiverName(l10n, to, pots);
    // Only a pot's own permissions can make an item fit better there.
    final adjust = to.kind == 'pot' && entry != null && entry.fit != 'ok';
    return heldItemView(
      context,
      item,
      first: first,
      from: from,
      threads: threads,
      toLabel: l10n.handoverToLabel,
      target: HandoverTarget(
        key: ValueKey('target-$key'),
        label: toName,
        none: to.kind == 'none',
        avatar: to.kind == 'none'
            ? null
            : ReceiverAvatar(to: to, pot: toPot, diameter: 26),
        onTap: onPick,
      ),
      fit: entry == null ? null : handoverFit(entry.fit),
      fitText: entry == null
          ? null
          : fitText(l10n, entry.fit, entry.reason, entry.to),
      expanded: _expanded.contains(key),
      onExpand: () => setState(
        () => _expanded.contains(key)
            ? _expanded.remove(key)
            : _expanded.add(key),
      ),
      detailsAction: adjust
          ? FilledButton(
              key: ValueKey('adjust-$key'),
              // `c-btn.small` on `surface.layer`.
              style: plainButtonStyle(context).copyWith(
                backgroundColor: WidgetStatePropertyAll(
                  colors['surface.layer'],
                ),
                minimumSize: const WidgetStatePropertyAll(Size(0, 36)),
                padding: const WidgetStatePropertyAll(
                  EdgeInsets.symmetric(horizontal: 14),
                ),
                textStyle: WidgetStatePropertyAll(
                  Theme.of(context).textTheme.labelLarge?.copyWith(
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
              onPressed: () => context.go(
                potSettingsLocation(to.potId!, section: reachSection),
              ),
              child: Text(l10n.handoverAdjust(toName)),
            )
          : null,
    );
  }
}

/// What will stop or is kept, one `d-pi` per sentence of the preview.
class _Lines extends StatelessWidget {
  const _Lines({super.key, required this.lines, this.stop = false});

  final List<String> lines;
  final bool stop;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: PircSpacing.gutterPhone),
    child: Material(
      color: PircColorTokens.of(context)['surface.layer'],
      borderRadius: BorderRadius.circular(PircRadius.lg),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final line in lines) PreviewLine(text: line, stop: stop),
          ],
        ),
      ),
    ),
  );
}

class _Failed extends StatelessWidget {
  const _Failed({required this.onRetry});
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        spacing: 8,
        children: [
          Text(l10n.listFailed),
          OutlinedButton(onPressed: onRetry, child: Text(l10n.retry)),
        ],
      ),
    );
  }
}

/// "Who takes …?" (E17): every other pot, you and (for one item) no one,
/// each with the fit it would have there, from one preview per choice with
/// every item given to it. For "Give everything to…" a choice says how
/// many items would not fully fit.
class _PickSheet extends ConsumerWidget {
  const _PickSheet({
    required this.potId,
    required this.mode,
    required this.held,
    this.item,
    this.current,
  });

  final String potId;
  final String mode;
  final List<HeldItem> held;

  /// The item to choose for; null for every item.
  final HeldItem? item;
  final HandoverTo? current;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final colors = PircColorTokens.of(context);
    final pots = ref.watch(potsProvider).value ?? const <PotSummary>[];
    final item = this.item;
    final choices = [
      for (final pot in pots)
        if (pot.id != potId && pot.state != 'archived') HandoverTo.pot(pot.id),
      const HandoverTo.user(),
      if (item != null) const HandoverTo.none(),
    ];
    final rows = <Widget>[];
    for (final (i, to) in choices.indexed) {
      final preview = ref
          .watch(
            retirePreviewProvider(
              RetirePlan(potId, mode, [
                for (final each in held) RetireTarget(item: each, to: to),
              ]),
            ),
          )
          .value;
      HandoverFit? fit;
      String? text;
      if (preview != null && item != null) {
        for (final entry in preview.items) {
          if (entry.item.kind == item.kind && entry.item.ref == item.ref) {
            fit = handoverFit(entry.fit);
            text = fitText(l10n, entry.fit, entry.reason, to);
          }
        }
      } else if (preview != null) {
        final misfits = preview.items.where((e) => e.fit != 'ok').length;
        fit = misfits == 0 ? HandoverFit.ok : HandoverFit.narrowed;
        text = misfits == 0
            ? l10n.retirePickAllFits
            : l10n.retirePickAllMisfits(misfits);
      }
      final pot = to.kind == 'pot' ? potNamed(pots, to.potId) : null;
      rows.add(
        _PickRow(
          key: ValueKey('pick-${to.potId ?? to.kind}'),
          first: i == 0,
          avatar: ReceiverAvatar(to: to, pot: pot),
          name: receiverName(l10n, to, pots),
          fit: fit,
          fitText: text,
          selected:
              current != null &&
              current!.kind == to.kind &&
              current!.potId == to.potId,
          onTap: () => Navigator.pop(context, to),
        ),
      );
    }
    return Column(
      key: const ValueKey('pick-sheet'),
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
          child: Text(
            item == null
                ? l10n.retirePickAllTitle
                : l10n.retirePickTitle(l10n.handoverQuoted(item.label)),
            style: TextStyle(
              fontSize: 20,
              height: 28 / 20,
              fontWeight: FontWeight.w600,
              color: colors['text.primary'],
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
          child: Text(
            item == null ? l10n.retirePickAllSub : l10n.retirePickSub,
            style: TextStyle(
              fontSize: 12.5,
              height: 18 / 12.5,
              color: colors['text.muted'],
            ),
          ),
        ),
        ...rows,
        const SizedBox(height: 8),
      ],
    );
  }
}

/// `d-radio` in the pick sheet: the avatar (36), the name and its fit,
/// and the radio mark at the end.
class _PickRow extends StatelessWidget {
  const _PickRow({
    super.key,
    required this.first,
    required this.avatar,
    required this.name,
    required this.selected,
    required this.onTap,
    this.fit,
    this.fitText,
  });

  final bool first;
  final Widget avatar;
  final String name;
  final HandoverFit? fit;
  final String? fitText;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = PircColorTokens.of(context);
    final fit = this.fit;
    final color = switch (fit) {
      HandoverFit.ok => colors['text.success'],
      HandoverFit.narrowed => colors['text.warning'],
      HandoverFit.stop => colors['status.danger'],
      _ => colors['text.muted'],
    };
    final fitStyle = TextStyle(fontSize: 13, height: 19 / 13, color: color);
    return Semantics(
      inMutuallyExclusiveGroup: true,
      checked: selected,
      button: true,
      child: InkWell(
        onTap: onTap,
        child: Container(
          constraints: const BoxConstraints(minHeight: 56),
          decoration: BoxDecoration(
            border: first
                ? null
                : Border(top: BorderSide(color: colors['line.hairline'])),
          ),
          margin: EdgeInsets.only(left: first ? 0 : 16),
          padding: EdgeInsets.fromLTRB(first ? 16 : 0, 8, 16, 8),
          child: Row(
            spacing: 12,
            children: [
              avatar,
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 15,
                        height: 22 / 15,
                        color: colors['text.primary'],
                      ),
                    ),
                    if (fit != null && fitText != null && fitText!.isNotEmpty)
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        spacing: 6,
                        children: [
                          SizedBox(
                            width: 14,
                            child: Text(switch (fit) {
                              HandoverFit.ok => '✓',
                              HandoverFit.narrowed => '!',
                              HandoverFit.stop => '■',
                              HandoverFit.muted => '·',
                            }, style: fitStyle),
                          ),
                          Expanded(child: Text(fitText!, style: fitStyle)),
                        ],
                      ),
                  ],
                ),
              ),
              Container(
                width: 18,
                height: 18,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: selected
                      ? Border.all(color: colors['accent.default'], width: 5)
                      : Border.all(color: colors['line.strong'], width: 1.5),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Delete asks once more: the pot's name must be typed.
class _DeleteDialog extends StatefulWidget {
  const _DeleteDialog({required this.name});
  final String name;

  @override
  State<_DeleteDialog> createState() => _DeleteDialogState();
}

class _DeleteDialogState extends State<_DeleteDialog> {
  final _field = TextEditingController();

  @override
  void dispose() {
    _field.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final colors = PircColorTokens.of(context);
    final typed =
        widget.name.trim().isNotEmpty &&
        _field.text.trim() == widget.name.trim();
    return AlertDialog(
      key: const ValueKey('retire-delete-dialog'),
      title: Text(l10n.retireDeleteTitle(widget.name)),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: 12,
        children: [
          Text(l10n.retireDeleteBody(widget.name)),
          TextField(
            key: const ValueKey('retire-delete-name'),
            controller: _field,
            autofocus: true,
            decoration: InputDecoration(hintText: l10n.retireDeleteField),
            onChanged: (_) => setState(() {}),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: Text(l10n.cancel),
        ),
        FilledButton(
          key: const ValueKey('retire-delete-confirm'),
          style: FilledButton.styleFrom(
            backgroundColor: colors['status.danger'],
            foregroundColor: Colors.white,
          ),
          onPressed: typed ? () => Navigator.pop(context, true) : null,
          child: Text(l10n.retireDelete),
        ),
      ],
    );
  }
}
