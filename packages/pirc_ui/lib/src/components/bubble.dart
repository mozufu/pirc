import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../theme.dart';
import '../tokens.g.dart';
import 'avatar.dart';

/// `e-msg` / `e-bub` / `e-me`: one message in a pot conversation or a pot's
/// point of view (work conversations keep the document style).
///
/// - Mine ([Bubble.mine]): on the right, `surface.bubble`, at most 82 % of
///   the width, no avatar and no name.
/// - Another's: the [avatar] at the bottom left, the [name] above (with a
///   [hostLabel] tag in groups), `surface.subtle`, at most 282 wide.
/// - In a point of view the pot's own messages are on the right
///   ([rightSide]) with its avatar, tinted 18 % of its colour ([tint]).
class Bubble extends StatelessWidget {
  const Bubble({
    super.key,
    required this.text,
    this.avatar,
    this.name,
    this.hostLabel,
    this.meta,
    this.rightSide = false,
    this.tint,
  }) : mine = false;

  /// The user's own message.
  const Bubble.mine({super.key, required this.text, this.meta})
    : mine = true,
      avatar = null,
      name = null,
      hostLabel = null,
      rightSide = true,
      tint = null;

  /// The message; a [String] or an [InlineSpan] (mentions in `e-at`).
  final Object text;
  final bool mine;
  final Widget? avatar;
  final String? name;

  /// "Host" in a group.
  final String? hostLabel;

  /// A small line under the text (12.5, muted).
  final String? meta;
  final bool rightSide;

  /// The avatar colour (1–5) whose 18 % tints this bubble, or null.
  final int? tint;

  /// A mention inside [text] (`e-at`: `accent.pressed`, 600; `accent.onSoft`
  /// in dark).
  static TextSpan mention(BuildContext context, String text) {
    final colors = PircColorTokens.of(context);
    final dark = Theme.of(context).brightness == Brightness.dark;
    return TextSpan(
      text: text,
      style: TextStyle(
        fontWeight: FontWeight.w600,
        color: dark ? colors['accent.onSoft'] : colors['accent.pressed'],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = PircColorTokens.of(context);
    final body = TextStyle(
      fontSize: 15,
      height: 22 / 15,
      color: colors['text.primary'],
    );
    Widget content() => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        text is InlineSpan
            ? Text.rich(text as InlineSpan, style: body)
            : Text('$text', style: body),
        if (meta != null)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              meta!,
              style: TextStyle(
                fontSize: 12.5,
                height: 18 / 12.5,
                color: colors['text.muted'],
              ),
            ),
          ),
      ],
    );
    if (mine) {
      return Align(
        alignment: Alignment.centerRight,
        child: FractionallySizedBox(
          widthFactor: 0.82,
          alignment: Alignment.centerRight,
          child: Align(
            alignment: Alignment.centerRight,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
              decoration: BoxDecoration(
                color: colors['surface.bubble'],
                borderRadius: const BorderRadius.only(
                  topLeft: Radius.circular(18),
                  topRight: Radius.circular(18),
                  bottomLeft: Radius.circular(18),
                  bottomRight: Radius.circular(6),
                ),
              ),
              child: content(),
            ),
          ),
        ),
      );
    }
    final background = tint == null
        ? colors['surface.subtle']
        : Color.lerp(
            colors['surface.page'],
            colors[avatarColorToken(tint!)],
            0.18,
          )!;
    const big = Radius.circular(18);
    const small = Radius.circular(6);
    final bubble = Container(
      padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 9),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.only(
          topLeft: big,
          topRight: big,
          bottomLeft: rightSide ? big : small,
          bottomRight: rightSide ? small : big,
        ),
      ),
      child: content(),
    );
    final column = ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 282),
      child: Column(
        crossAxisAlignment: rightSide
            ? CrossAxisAlignment.end
            : CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        spacing: 4,
        children: [
          if (name != null)
            Padding(
              padding: rightSide
                  ? const EdgeInsets.only(right: 4)
                  : const EdgeInsets.only(left: 4),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                spacing: 6,
                children: [
                  Flexible(
                    child: Text(
                      name!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        height: 16 / 12,
                        color: colors['text.muted'],
                      ),
                    ),
                  ),
                  if (hostLabel != null) HostTag(hostLabel!),
                ],
              ),
            ),
          bubble,
        ],
      ),
    );
    // `.r` is `row-reverse`: the avatar at the right edge, the bubble left
    // of it. In a right-to-left row, start is the right edge.
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      textDirection: rightSide ? TextDirection.rtl : TextDirection.ltr,
      spacing: 8,
      children: [
        if (avatar != null)
          Padding(padding: const EdgeInsets.only(bottom: 2), child: avatar),
        Flexible(
          child: Directionality(
            textDirection: Directionality.of(context),
            child: column,
          ),
        ),
      ],
    );
  }
}

/// `e-host`: the host's tag next to its name in a group.
class HostTag extends StatelessWidget {
  const HostTag(this.label, {super.key});
  final String label;

  @override
  Widget build(BuildContext context) {
    final colors = PircColorTokens.of(context);
    return Container(
      height: 16,
      padding: const EdgeInsets.symmetric(horizontal: 6),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: colors['fill.hoverStrong'],
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 10.5,
          height: 1,
          fontWeight: FontWeight.w600,
          color: colors['text.secondary'],
        ),
      ),
    );
  }
}

/// One part of a [HandoffLine]: plain, or a name in bold.
@immutable
class HandoffPart {
  const HandoffPart(this.text) : strong = false;
  const HandoffPart.name(this.text) : strong = true;
  final String text;
  final bool strong;
}

/// `e-hand`: "A asked B to …", centred in a pill (12.5, `text.secondary`,
/// names in `text.primary` 600), at most 92 % of the width. The backend's
/// events produce it; the app never writes one itself.
class HandoffLine extends StatelessWidget {
  const HandoffLine({super.key, required this.parts});

  final List<HandoffPart> parts;

  @override
  Widget build(BuildContext context) {
    final colors = PircColorTokens.of(context);
    return Center(
      child: FractionallySizedBox(
        widthFactor: 0.92,
        child: Center(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
            decoration: BoxDecoration(
              color: colors['fill.hover'],
              borderRadius: BorderRadius.circular(999),
            ),
            child: Text.rich(
              TextSpan(
                children: [
                  for (final (i, part) in parts.indexed) ...[
                    if (i > 0) const WidgetSpan(child: SizedBox(width: 6)),
                    TextSpan(
                      text: part.text,
                      style: part.strong
                          ? TextStyle(
                              fontWeight: FontWeight.w600,
                              color: colors['text.primary'],
                            )
                          : null,
                    ),
                  ],
                ],
              ),
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 12.5,
                height: 18 / 12.5,
                color: colors['text.secondary'],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// `e-work`: a work conversation inside a pot conversation; no icon. The
/// [title] (14.5/500) over a [subtitle] (12.5 muted: who coordinates it,
/// the host and its state), then a chevron. Conversations indent it 36
/// (`e-indent`) under the pot's bubbles.
class WorkCard extends StatelessWidget {
  const WorkCard({
    super.key,
    required this.title,
    required this.subtitle,
    this.onTap,
  });

  final String title;

  /// A [String], or an [InlineSpan] (a state symbol as a [WidgetSpan]).
  final Object subtitle;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final colors = PircColorTokens.of(context);
    final dark = Theme.of(context).brightness == Brightness.dark;
    final subtitleStyle = TextStyle(
      fontSize: 12.5,
      height: 17 / 12.5,
      color: colors['text.muted'],
    );
    final subtitle = this.subtitle;
    return Container(
      decoration: BoxDecoration(
        color: colors['surface.layer'],
        borderRadius: BorderRadius.circular(14),
        boxShadow: dark ? PircElevation.cardDark : PircElevation.cardLight,
      ),
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(14),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Row(
              spacing: 10,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    spacing: 1,
                    children: [
                      Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 14.5,
                          height: 20 / 14.5,
                          fontWeight: FontWeight.w500,
                          color: colors['text.primary'],
                        ),
                      ),
                      subtitle is InlineSpan
                          ? Text.rich(
                              subtitle,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: subtitleStyle,
                            )
                          : Text(
                              '$subtitle',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: subtitleStyle,
                            ),
                    ],
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
