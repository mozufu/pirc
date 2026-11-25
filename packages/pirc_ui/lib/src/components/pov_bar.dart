import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../theme.dart';
import '../tokens.g.dart';

/// `e-pov`: the entry into a pot's point of view, on `surface.subtle`:
/// its avatar (28), a bold [title] ("See Tester's point of view") over a
/// [subtitle], and a chevron.
class PovBar extends StatelessWidget {
  const PovBar({
    super.key,
    required this.avatar,
    required this.title,
    required this.subtitle,
    this.onTap,
  });

  final Widget avatar;
  final String title;
  final String subtitle;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final colors = PircColorTokens.of(context);
    final style = TextStyle(
      fontSize: 13,
      height: 18 / 13,
      color: colors['text.secondary'],
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
      child: Material(
        color: colors['surface.subtle'],
        borderRadius: BorderRadius.circular(PircRadius.md),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
            child: Row(
              spacing: 10,
              children: [
                avatar,
                Expanded(
                  child: Text.rich(
                    TextSpan(
                      children: [
                        TextSpan(
                          text: title,
                          style: TextStyle(
                            fontWeight: FontWeight.w600,
                            color: colors['text.primary'],
                          ),
                        ),
                        TextSpan(text: '\n$subtitle'),
                      ],
                    ),
                    style: style,
                  ),
                ),
                Icon(
                  LucideIcons.chevronRight,
                  size: 16,
                  color: colors['text.faint'],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// `e-ro`: the bar that replaces the composer in a point of view: "Read
/// only: …" and a dark [actionLabel] button.
class PovReadOnlyBar extends StatelessWidget {
  const PovReadOnlyBar({
    super.key,
    required this.text,
    this.actionLabel,
    this.onAction,
  });

  final String text;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final colors = PircColorTokens.of(context);
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 0, 12, 8),
      constraints: const BoxConstraints(minHeight: 52),
      padding: const EdgeInsets.fromLTRB(18, 6, 6, 6),
      decoration: BoxDecoration(
        color: colors['surface.subtle'],
        borderRadius: BorderRadius.circular(PircRadius.panel),
      ),
      child: Row(
        spacing: 10,
        children: [
          Expanded(
            child: Text(
              text,
              style: TextStyle(fontSize: 14, color: colors['text.secondary']),
            ),
          ),
          if (actionLabel != null)
            TextButton(
              onPressed: onAction,
              style: TextButton.styleFrom(
                backgroundColor: colors['action.primary'],
                foregroundColor: colors['action.onPrimary'],
                minimumSize: const Size(0, 36),
                padding: const EdgeInsets.symmetric(horizontal: 14),
                shape: const StadiumBorder(),
                textStyle: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                ),
              ),
              child: Text(actionLabel!),
            ),
        ],
      ),
    );
  }
}
