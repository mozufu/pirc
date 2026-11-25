import 'package:flutter/material.dart';

import '../theme.dart';
import '../tokens.g.dart';
import 'bubble.dart';

/// One member in a [MentionPopover].
@immutable
class MentionOption<T> {
  const MentionOption({
    required this.value,
    required this.avatar,
    required this.name,
    required this.detail,
    this.hostLabel,
  });

  final T value;

  /// A 36 avatar (`AvatarSize.md`), or a group avatar for "@all".
  final Widget avatar;
  final String name;

  /// What it may do and its budget left ("Can start work · $4.20 / $20").
  final String detail;

  /// "Host" for the group's host.
  final String? hostLabel;
}

/// `e-pop`: the members a composer's @ can name, over the composer: a
/// [header] line, then one 56 row per member with its reach and budget.
/// The caller places it (12 from each side, just above the composer).
class MentionPopover<T> extends StatelessWidget {
  const MentionPopover({
    super.key,
    required this.header,
    required this.options,
    required this.onSelected,
    this.semanticLabel,
  });

  final String header;
  final List<MentionOption<T>> options;
  final ValueChanged<T> onSelected;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final colors = PircColorTokens.of(context);
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Semantics(
      container: true,
      label: semanticLabel,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 6),
        decoration: BoxDecoration(
          color: colors['surface.layer'],
          borderRadius: BorderRadius.circular(18),
          boxShadow: dark ? PircElevation.floatDark : PircElevation.floatLight,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
              child: Text(
                header,
                style: TextStyle(fontSize: 12, color: colors['text.muted']),
              ),
            ),
            for (final (i, option) in options.indexed)
              _MentionRow(
                option: option,
                first: i == 0,
                onTap: () => onSelected(option.value),
              ),
          ],
        ),
      ),
    );
  }
}

class _MentionRow<T> extends StatelessWidget {
  const _MentionRow({
    required this.option,
    required this.first,
    required this.onTap,
  });

  final MentionOption<T> option;
  final bool first;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = PircColorTokens.of(context);
    return Semantics(
      button: true,
      child: InkWell(
        onTap: onTap,
        hoverColor: colors['fill.hover'],
        child: CustomPaint(
          painter: first ? null : _Hairline(colors['line.hairline']),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 56),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Row(
                spacing: 12,
                children: [
                  option.avatar,
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      spacing: 2,
                      children: [
                        Row(
                          spacing: 6,
                          children: [
                            Flexible(
                              child: Text(
                                option.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 16,
                                  height: 22 / 16,
                                  fontWeight: FontWeight.w500,
                                  color: colors['text.primary'],
                                ),
                              ),
                            ),
                            if (option.hostLabel != null)
                              HostTag(option.hostLabel!),
                          ],
                        ),
                        Text(
                          option.detail,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 14,
                            height: 20 / 14,
                            color: colors['text.secondary'],
                          ),
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

/// The popover's row line starts at 60.
class _Hairline extends CustomPainter {
  const _Hairline(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) => canvas.drawRect(
    Rect.fromLTWH(60, 0, size.width - 60, 1),
    Paint()..color = color,
  );

  @override
  bool shouldRepaint(_Hairline old) => old.color != color;
}
