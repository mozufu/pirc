import 'package:flutter/material.dart';

import '../theme.dart';

/// A chip under a profile's intro (`d-chip`: 26 high, 12.5/500), with an
/// optional state dot before the text.
@immutable
class ProfileChip {
  const ProfileChip(this.label, {this.dot, this.labelColor});
  final String label;

  /// The colour token of the label (`accent.pressed` for a running state,
  /// `d-chip.run`); `text.secondary` when null.
  final String? labelColor;

  /// The colour token of a 6 dot before the label (`accent.default` while
  /// observing), or null.
  final String? dot;
}

/// One round action under a profile (`e-act`): a 48 circle on
/// `surface.layer` with a 20 icon, the label under it (12.5).
@immutable
class ProfileAction {
  const ProfileAction({
    required this.icon,
    required this.label,
    required this.onTap,
  });
  final IconData icon;
  final String label;
  final VoidCallback? onTap;
}

/// `e-prof` and `e-acts`: the [avatar] (88), the [name] (22/30, 600), the
/// [intro] (14, `text.secondary`), [chips], then the [actions] row.
class ProfileHeader extends StatelessWidget {
  const ProfileHeader({
    super.key,
    required this.avatar,
    required this.name,
    this.intro,
    this.chips = const [],
    this.actions = const [],
  });

  final Widget avatar;
  final String name;
  final String? intro;
  final List<ProfileChip> chips;
  final List<ProfileAction> actions;

  @override
  Widget build(BuildContext context) {
    final colors = PircColorTokens.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
          child: Column(
            spacing: 4,
            children: [
              avatar,
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Semantics(
                  header: true,
                  child: Text(
                    name,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 22,
                      height: 30 / 22,
                      fontWeight: FontWeight.w600,
                      color: colors['text.primary'],
                    ),
                  ),
                ),
              ),
              if (intro != null && intro!.isNotEmpty)
                Text(
                  intro!,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 14,
                    height: 20 / 14,
                    color: colors['text.secondary'],
                  ),
                ),
              if (chips.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Wrap(
                    alignment: WrapAlignment.center,
                    spacing: 6,
                    runSpacing: 6,
                    children: [for (final chip in chips) _Chip(chip)],
                  ),
                ),
            ],
          ),
        ),
        if (actions.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              spacing: 8,
              // Long labels (or a narrow pane) shrink the actions instead
              // of overflowing.
              children: [
                for (final action in actions) Flexible(child: _Action(action)),
              ],
            ),
          ),
      ],
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip(this.chip);
  final ProfileChip chip;

  @override
  Widget build(BuildContext context) {
    final colors = PircColorTokens.of(context);
    return Container(
      height: 26,
      padding: const EdgeInsets.symmetric(horizontal: 9),
      decoration: BoxDecoration(
        color: colors['fill.hover'],
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        spacing: 6,
        children: [
          if (chip.dot != null)
            Container(
              width: 6,
              height: 6,
              decoration: BoxDecoration(
                color: colors[chip.dot!],
                shape: BoxShape.circle,
              ),
            ),
          Text(
            chip.label,
            style: TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.w500,
              color: colors[chip.labelColor ?? 'text.secondary'],
            ),
          ),
        ],
      ),
    );
  }
}

class _Action extends StatelessWidget {
  const _Action(this.action);
  final ProfileAction action;

  @override
  Widget build(BuildContext context) {
    final colors = PircColorTokens.of(context);
    return Semantics(
      button: true,
      enabled: action.onTap != null,
      child: InkWell(
        onTap: action.onTap,
        borderRadius: BorderRadius.circular(12),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minWidth: 76),
          child: Padding(
            padding: const EdgeInsets.all(4),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              spacing: 6,
              children: [
                Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    color: colors['surface.layer'],
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    action.icon,
                    size: 20,
                    color: colors['text.primary'],
                  ),
                ),
                Text(
                  action.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 12.5,
                    color: colors['text.secondary'],
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
