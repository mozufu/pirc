import 'package:flutter/material.dart';

import '../theme.dart';

/// The badge at the end of a [ChatRow]'s second line.
@immutable
class ChatBadge {
  /// Unread messages: ink on the page colour.
  const ChatBadge.unread(this.text) : attention = false;

  /// "Waiting on you": `status.warningSoft` with `text.warning`.
  const ChatBadge.attention(this.text) : attention = true;

  final String text;
  final bool attention;
}

/// `e-row`: one chat (a pot's direct thread or a group) with its [avatar],
/// or a work row without one (`.noav`, 64 high, text from the 16 gutter).
///
/// Line 1: [title] (16/500), [role] (12.5 muted) and [time]. Line 2:
/// [preview] (14, `text.warning` when [previewWarning]) and the [badge].
/// The hairline above starts at 76 (16 without an avatar); [divider] false
/// hides it (the first row, and the rows next to a selected one).
class ChatRow extends StatelessWidget {
  const ChatRow({
    super.key,
    this.avatar,
    required this.title,
    this.role,
    this.time,
    this.preview,
    this.previewLeading,
    this.previewWarning = false,
    this.badge,
    this.divider = true,
    this.selected = false,
    this.onTap,
    this.onLongPress,
    this.minHeight,
  });

  final Widget? avatar;
  final String title;
  final String? role;
  final String? time;
  final String? preview;

  /// Shown before [preview] (a state symbol).
  final Widget? previewLeading;
  final bool previewWarning;
  final ChatBadge? badge;
  final bool divider;
  final bool selected;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  /// 72 with an avatar, 64 without; the mention popover uses 56.
  final double? minHeight;

  @override
  Widget build(BuildContext context) {
    final colors = PircColorTokens.of(context);
    final hasAvatar = avatar != null;
    final muted = colors['text.muted'];
    final content = Row(
      spacing: 12,
      children: [
        ?avatar,
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            spacing: 2,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.baseline,
                textBaseline: TextBaseline.alphabetic,
                spacing: 6,
                children: [
                  // One paragraph, so the role gives way before the title
                  // (CSS: the role grows from 0, the title shrinks last).
                  Expanded(
                    child: Text.rich(
                      TextSpan(
                        children: [
                          TextSpan(
                            text: title,
                            style: TextStyle(
                              fontSize: 16,
                              height: 22 / 16,
                              fontWeight: FontWeight.w500,
                              color: colors['text.primary'],
                            ),
                          ),
                          if (role != null && role!.isNotEmpty) ...[
                            const WidgetSpan(child: SizedBox(width: 6)),
                            TextSpan(
                              text: role,
                              style: TextStyle(fontSize: 12.5, color: muted),
                            ),
                          ],
                        ],
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (time != null)
                    Text(
                      time!,
                      style: TextStyle(
                        fontSize: 12,
                        color: muted,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                ],
              ),
              if (preview != null || badge != null)
                Row(
                  spacing: 8,
                  children: [
                    ?previewLeading,
                    Expanded(
                      child: Text(
                        preview ?? '',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 14,
                          height: 20 / 14,
                          color: previewWarning
                              ? colors['text.warning']
                              : colors['text.secondary'],
                        ),
                      ),
                    ),
                    if (badge != null) _Badge(badge!),
                  ],
                ),
            ],
          ),
        ),
      ],
    );
    return Material(
      color: selected ? colors['fill.active'] : Colors.transparent,
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        onSecondaryTap: onLongPress,
        hoverColor: colors['fill.hover'],
        child: CustomPaint(
          painter: divider && !selected
              ? _TopLine(colors['line.hairline'], hasAvatar ? 76 : 16)
              : null,
          child: ConstrainedBox(
            constraints: BoxConstraints(
              minHeight: minHeight ?? (hasAvatar ? 72 : 64),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: content,
            ),
          ),
        ),
      ),
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge(this.badge);
  final ChatBadge badge;

  @override
  Widget build(BuildContext context) {
    final colors = PircColorTokens.of(context);
    return Container(
      constraints: const BoxConstraints(minWidth: 20),
      height: 20,
      padding: const EdgeInsets.symmetric(horizontal: 6),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: badge.attention
            ? colors['status.warningSoft']
            : colors['text.primary'],
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        badge.text,
        style: TextStyle(
          fontSize: 11.5,
          height: 1,
          fontWeight: FontWeight.w700,
          color: badge.attention
              ? colors['text.warning']
              : colors['surface.page'],
        ),
      ),
    );
  }
}

/// A 1 hairline along the top edge, from [left] to the right edge.
class _TopLine extends CustomPainter {
  const _TopLine(this.color, this.left);
  final Color color;
  final double left;

  @override
  void paint(Canvas canvas, Size size) => canvas.drawRect(
    Rect.fromLTWH(left, 0, size.width - left, 1),
    Paint()..color = color,
  );

  @override
  bool shouldRepaint(_TopLine old) => old.color != color || old.left != left;
}
