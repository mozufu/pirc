import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pirc_client/pirc_client.dart';
import 'package:pirc_ui/pirc_ui.dart';

import '../../l10n/app_localizations.dart';
import 'chat_data.dart';
import 'handover_data.dart';
import 'pot_conversation_screen.dart';

/// The parts the handover (E14) and retire (E15–E17) screens share.

/// A receiver's avatar: a pot's colour or picture, the user's neutral
/// "Me", or "—" for no one. [diameter] 26 is the `e-to` chip's, 36 the
/// cards' and the pick sheet's.
class ReceiverAvatar extends ConsumerWidget {
  const ReceiverAvatar({
    super.key,
    required this.to,
    this.pot,
    this.diameter = 36,
  });

  final HandoverTo to;
  final PotSummary? pot;
  final double diameter;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final fontSize = diameter <= 26 ? 11.0 : 14.0;
    final pot = this.pot;
    if (to.kind == 'pot' && pot != null) {
      return Avatar.custom(
        name: pot.name,
        color: pot.avatarColor,
        diameter: diameter,
        fontSize: fontSize,
        image: watchAvatarImage(ref, pot.avatarImage),
      );
    }
    return Avatar.custom(
      name: to.kind == 'user' ? l10n.handoverMeAvatar : '—',
      me: true,
      diameter: diameter,
      fontSize: fontSize,
    );
  }
}

/// `e-rcpt` button: a receiver card, the avatar (36), the name and a line
/// about what it may do; the chosen one has an accent ring.
class ReceiverCard extends StatelessWidget {
  const ReceiverCard({
    super.key,
    required this.avatar,
    required this.name,
    required this.subtitle,
    required this.selected,
    this.onTap,
  });

  final Widget avatar;
  final String name;
  final String subtitle;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final colors = PircColorTokens.of(context);
    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(PircRadius.lg),
      side: selected
          ? BorderSide(color: colors['accent.default'], width: 1.5)
          : BorderSide.none,
    );
    return Semantics(
      inMutuallyExclusiveGroup: true,
      checked: selected,
      button: onTap != null,
      child: Material(
        color: colors['surface.layer'],
        shape: shape,
        child: InkWell(
          onTap: onTap,
          customBorder: shape,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              spacing: 6,
              children: [
                avatar,
                Text(
                  name,
                  textAlign: TextAlign.center,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 14,
                    height: 20 / 14,
                    fontWeight: FontWeight.w500,
                    color: colors['text.primary'],
                  ),
                ),
                Text(
                  subtitle,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 12,
                    height: 16 / 12,
                    color: colors['text.muted'],
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

/// `e-rcpt`: receiver cards two to a row, 8 apart, 16 from the edges.
class ReceiverCards extends StatelessWidget {
  const ReceiverCards({super.key, required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 16),
    child: Column(
      spacing: 8,
      children: [
        for (var i = 0; i < children.length; i += 2)
          IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              spacing: 8,
              children: [
                Expanded(child: children[i]),
                Expanded(
                  child: i + 1 < children.length
                      ? children[i + 1]
                      : const SizedBox.shrink(),
                ),
              ],
            ),
          ),
      ],
    ),
  );
}

/// What a receiver card says under the name: a pot's reach and the
/// tokens it has left today; the user's line for "You".
String receiverSubtitle(
  AppLocalizations l10n,
  HandoverTo to, {
  PotSummary? pot,
  Pot? full,
}) {
  if (to.kind == 'user') return l10n.handoverYouSub;
  final reach = switch (full?.permissions.reach) {
    'work' => l10n.potHeaderWork,
    'observe' => l10n.potHeaderObserve,
    'answer' => l10n.potHeaderAnswer,
    _ => null,
  };
  final tokens = pot?.budgetLeft?.tokens;
  return [
    ?reach,
    if (tokens != null) l10n.handoverTokensLeft(compactTokens(tokens)),
    if (reach == null && tokens == null && pot != null) pot.intro,
  ].join(' · ');
}

/// `d-banner.info`: the accent-tinted note at the top (13.5/20), with an
/// optional bold lead.
class InfoBanner extends StatelessWidget {
  const InfoBanner({super.key, this.lead, required this.text, this.extra});

  final String? lead;
  final String text;

  /// A second paragraph (a pot's reason).
  final String? extra;

  @override
  Widget build(BuildContext context) {
    final colors = PircColorTokens.of(context);
    final ink = colors['accent.onSoft'];
    final style = TextStyle(fontSize: 13.5, height: 20 / 13.5, color: ink);
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 4, 16, 0),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: colors['accent.soft'],
        borderRadius: BorderRadius.circular(PircRadius.md),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: 6,
        children: [
          Text.rich(
            TextSpan(
              children: [
                if (lead != null)
                  TextSpan(
                    text: lead,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                TextSpan(text: text),
              ],
            ),
            style: style,
          ),
          if (extra != null && extra!.isNotEmpty) Text(extra!, style: style),
        ],
      ),
    );
  }
}

/// A refusal or failure in a `status.dangerSoft` box.
class ErrorBox extends StatelessWidget {
  const ErrorBox(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    final colors = PircColorTokens.of(context);
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: colors['status.dangerSoft'],
        borderRadius: BorderRadius.circular(PircRadius.md),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 13.5,
          height: 20 / 13.5,
          color: colors['status.danger'],
        ),
      ),
    );
  }
}

/// `c-group` holding [HandoverItem]s (they draw their own hairlines).
class HandoverItemGroup extends StatelessWidget {
  const HandoverItemGroup({super.key, required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: PircSpacing.gutterPhone),
    child: Material(
      color: PircColorTokens.of(context)['surface.layer'],
      borderRadius: BorderRadius.circular(PircRadius.lg),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: children,
      ),
    ),
  );
}

/// `d-pi` in a `c-group`: a 22 square (■ on `status.dangerSoft` for what
/// stops, ✓ on `fill.hoverStrong` for what is kept) and the line (14/20).
class PreviewLine extends StatelessWidget {
  const PreviewLine({super.key, required this.text, this.stop = false});

  final String text;
  final bool stop;

  @override
  Widget build(BuildContext context) {
    final colors = PircColorTokens.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: 10,
        children: [
          Container(
            width: 22,
            height: 22,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: stop
                  ? colors['status.dangerSoft']
                  : colors['fill.hoverStrong'],
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text(
              stop ? '■' : '✓',
              textScaler: TextScaler.noScaling,
              style: TextStyle(
                fontSize: 12,
                height: 1,
                fontWeight: FontWeight.w700,
                color: stop
                    ? colors['status.danger']
                    : colors['text.secondary'],
              ),
            ),
          ),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                fontSize: 14,
                height: 20 / 14,
                color: colors['text.primary'],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The `c-top` text button ("Cancel").
class TopTextButton extends StatelessWidget {
  const TopTextButton({
    super.key,
    required this.label,
    required this.onPressed,
  });

  final String label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => TextButton(
    onPressed: onPressed,
    style: TextButton.styleFrom(
      foregroundColor: PircColorTokens.of(context)['text.primary'],
      minimumSize: const Size(0, 36),
      padding: const EdgeInsets.symmetric(horizontal: 14),
      shape: const StadiumBorder(),
      textStyle: Theme.of(context).textTheme.labelLarge?.copyWith(fontSize: 14),
    ),
    child: Text(label),
  );
}

/// Keeps settings-like content 720 wide and centred on wide layouts
/// (E spec § 9).
Widget narrow720(Widget child) => Center(
  child: ConstrainedBox(
    constraints: const BoxConstraints(maxWidth: 720),
    child: SizedBox(width: double.infinity, child: child),
  ),
);

/// `e-cta`: the bottom buttons, 10 16 4, 8 apart: an optional
/// [secondary] at its own width and the [primary] filling the rest.
class BottomActions extends StatelessWidget {
  const BottomActions({super.key, required this.primary, this.secondary});

  final Widget primary;
  final Widget? secondary;

  @override
  Widget build(BuildContext context) => narrow720(
    Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
      child: Row(
        spacing: 8,
        children: [
          ?secondary,
          Expanded(child: primary),
        ],
      ),
    ),
  );
}

/// A spinner the size of a button label.
class ButtonSpinner extends StatelessWidget {
  const ButtonSpinner({super.key});

  @override
  Widget build(BuildContext context) => SizedBox(
    width: 18,
    height: 18,
    child: CircularProgressIndicator(
      strokeWidth: 2,
      color: PircColorTokens.of(context)['action.onPrimary'],
    ),
  );
}

/// The item list's tag, title, line and details for [item].
HandoverItem heldItemView(
  BuildContext context,
  HeldItem item, {
  required bool first,
  Pot? from,
  List<PotThread> threads = const [],
  String? toLabel,
  HandoverTarget? target,
  bool? checked,
  ValueChanged<bool>? onChecked,
  HandoverFit? fit,
  String? fitText,
  bool expanded = false,
  VoidCallback? onExpand,
  Widget? detailsAction,
}) {
  final l10n = AppLocalizations.of(context);
  return HandoverItem(
    key: ValueKey('held-${heldKey(item)}'),
    kind: heldKindLabel(l10n, item.kind),
    title: item.label,
    subtitle: heldSubtitle(l10n, item, from: from, threads: threads),
    toLabel: toLabel,
    target: target,
    checked: checked,
    onChecked: onChecked,
    checkLabel: l10n.handoverCheckLabel,
    fit: fitText == null || fitText.isEmpty ? null : fit,
    fitText: fitText,
    details: heldDetails(l10n, item, from),
    detailsAction: detailsAction,
    expanded: expanded,
    onExpand: onExpand,
    first: first,
  );
}
