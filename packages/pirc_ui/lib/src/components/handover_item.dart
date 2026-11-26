import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../theme.dart';
import 'log_row.dart';

/// How well an item fits its receiver (`e-fit`).
enum HandoverFit {
  /// The receiver can do it as it is (`text.success`, ✓).
  ok,

  /// It can, with less (`text.warning`, !).
  narrowed,

  /// It cannot; the item stops (`status.danger`, ■).
  stop,

  /// Nothing to check yet, or not handed over (`text.muted`, ·).
  muted,
}

/// `e-to`: the receiver of one item: its avatar (26) and name, or "No one"
/// ([none]) without an avatar, with a small chevron.
class HandoverTarget extends StatelessWidget {
  const HandoverTarget({
    super.key,
    required this.label,
    this.avatar,
    this.none = false,
    this.onTap,
    this.color,
  });

  final String label;
  final Widget? avatar;
  final bool none;
  final VoidCallback? onTap;

  /// The fill; `fill.hover` by default ("Give everything to…" sits on the
  /// grouped page and uses `surface.layer`).
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final colors = PircColorTokens.of(context);
    return Material(
      color: color ?? colors['fill.hover'],
      shape: const StadiumBorder(),
      child: InkWell(
        onTap: onTap,
        customBorder: const StadiumBorder(),
        child: Container(
          height: 34,
          padding: EdgeInsets.only(
            left: none || avatar == null ? 12 : 4,
            right: 10,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            spacing: 6,
            children: [
              if (!none) ?avatar,
              Text(
                label,
                style: TextStyle(
                  fontSize: 13.5,
                  fontWeight: FontWeight.w500,
                  color: none ? colors['text.muted'] : colors['text.primary'],
                ),
              ),
              Icon(
                LucideIcons.chevronDown,
                size: 12,
                color: colors['text.muted'],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// `e-check`: a round tick (26 here): ink when on, a ring when off, in a
/// [hitSize] square (44; a row that is tapped as a whole may pass [size]).
class RoundCheck extends StatelessWidget {
  const RoundCheck({
    super.key,
    required this.value,
    required this.onChanged,
    this.semanticLabel,
    this.size = 26,
    this.hitSize = 44,
  });

  final bool value;
  final ValueChanged<bool>? onChanged;
  final String? semanticLabel;
  final double size;
  final double hitSize;

  @override
  Widget build(BuildContext context) {
    final colors = PircColorTokens.of(context);
    return Semantics(
      checked: value,
      label: semanticLabel,
      enabled: onChanged != null,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onChanged == null ? null : () => onChanged!(!value),
        child: SizedBox.square(
          dimension: hitSize,
          child: Center(
            child: Container(
              width: size,
              height: size,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: value ? colors['text.primary'] : null,
                border: value
                    ? null
                    : Border.all(color: colors['line.strong'], width: 1.5),
              ),
              child: value
                  ? Icon(
                      LucideIcons.check,
                      size: 13,
                      weight: 700,
                      color: colors['surface.page'],
                    )
                  : null,
            ),
          ),
        ),
      ),
    );
  }
}

/// `e-hi`: one item a pot holds, in a handover or retire screen.
///
/// The [kind] tag and [title] with a chevron that opens the [details];
/// under them the [subtitle] and either the receiver ([target], after
/// [toLabel]) or a [RoundCheck] ([checked]); then the [fit] line.
class HandoverItem extends StatelessWidget {
  const HandoverItem({
    super.key,
    required this.kind,
    required this.title,
    this.subtitle,
    this.toLabel,
    this.target,
    this.checked,
    this.onChecked,
    this.checkLabel,
    this.fit,
    this.fitText,
    this.details = const [],
    this.detailsAction,
    this.expanded = false,
    this.onExpand,
    this.first = false,
  });

  final String kind;
  final String title;
  final String? subtitle;

  /// "To" before the [target].
  final String? toLabel;
  final HandoverTarget? target;

  /// Shown as a [RoundCheck] when not null (a pot's own proposal).
  final bool? checked;
  final ValueChanged<bool>? onChecked;
  final String? checkLabel;
  final HandoverFit? fit;
  final String? fitText;

  /// Shown in a box when [expanded].
  final List<String> details;

  /// A button under the [details] in their box ("Adjust ○○'s
  /// permissions…").
  final Widget? detailsAction;
  final bool expanded;
  final VoidCallback? onExpand;

  /// The first item has no hairline above.
  final bool first;

  @override
  Widget build(BuildContext context) {
    final colors = PircColorTokens.of(context);
    final meta = TextStyle(
      fontSize: 12.5,
      height: 18 / 12.5,
      color: colors['text.muted'],
    );
    return CustomPaint(
      painter: first ? null : _Line(colors['line.hairline']),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Semantics(
              button: onExpand != null,
              expanded: details.isEmpty && detailsAction == null
                  ? null
                  : expanded,
              child: InkWell(
                onTap: onExpand,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  spacing: 8,
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(top: 1),
                      child: LogTag(kind),
                    ),
                    Expanded(
                      child: Text(
                        title,
                        style: TextStyle(
                          fontSize: 15,
                          height: 21 / 15,
                          fontWeight: FontWeight.w500,
                          color: colors['text.primary'],
                        ),
                      ),
                    ),
                    if (onExpand != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 3),
                        child: AnimatedRotation(
                          turns: expanded ? 0.5 : 0,
                          duration: const Duration(milliseconds: 150),
                          child: Icon(
                            LucideIcons.chevronDown,
                            size: 16,
                            color: colors['text.muted'],
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            if (subtitle != null || target != null || checked != null)
              ConstrainedBox(
                key: const Key('handover-to'),
                constraints: const BoxConstraints(minHeight: 36),
                child: Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Row(
                    spacing: 8,
                    children: [
                      Expanded(
                        child: Text(
                          subtitle ?? '',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: meta,
                        ),
                      ),
                      if (target != null) ...[
                        if (toLabel != null) Text(toLabel!, style: meta),
                        target!,
                      ],
                      if (checked != null)
                        SizedBox(
                          width: 26,
                          height: 26,
                          child: OverflowBox(
                            maxWidth: 44,
                            maxHeight: 44,
                            child: RoundCheck(
                              value: checked!,
                              onChanged: onChecked,
                              semanticLabel: checkLabel,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            if (fit != null && fitText != null) _FitLine(fit!, fitText!),
            if (expanded && (details.isNotEmpty || detailsAction != null))
              Container(
                margin: const EdgeInsets.only(top: 10),
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 10,
                ),
                decoration: BoxDecoration(
                  color: colors['surface.subtle'],
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  spacing: 4,
                  children: [
                    for (final line in details)
                      Text(
                        line,
                        style: TextStyle(
                          fontSize: 13,
                          height: 19 / 13,
                          color: colors['text.secondary'],
                        ),
                      ),
                    if (detailsAction != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: detailsAction,
                      ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _FitLine extends StatelessWidget {
  const _FitLine(this.fit, this.text);
  final HandoverFit fit;
  final String text;

  @override
  Widget build(BuildContext context) {
    final colors = PircColorTokens.of(context);
    final color = switch (fit) {
      HandoverFit.ok => colors['text.success'],
      HandoverFit.narrowed => colors['text.warning'],
      HandoverFit.stop => colors['status.danger'],
      HandoverFit.muted => colors['text.muted'],
    };
    final style = TextStyle(fontSize: 13, height: 19 / 13, color: color);
    final glyph = switch (fit) {
      HandoverFit.ok => '✓',
      HandoverFit.narrowed => '!',
      HandoverFit.stop => '■',
      HandoverFit.muted => '·',
    };
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: 6,
        children: [
          SizedBox(width: 14, child: Text(glyph, style: style)),
          Expanded(child: Text(text, style: style)),
        ],
      ),
    );
  }
}

class _Line extends CustomPainter {
  const _Line(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) => canvas.drawRect(
    Rect.fromLTWH(16, 0, size.width - 16, 1),
    Paint()..color = color,
  );

  @override
  bool shouldRepaint(_Line old) => old.color != color;
}

/// `e-mode`: how a pot may use a work model, as a small pill that cycles
/// ("Direct" / "Ask you"), 32 high, with a chevron.
class ModelAccess extends StatelessWidget {
  const ModelAccess({
    super.key,
    required this.label,
    required this.onTap,
    this.semanticLabel,
  });

  final String label;
  final VoidCallback? onTap;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final colors = PircColorTokens.of(context);
    return Semantics(
      button: true,
      label: semanticLabel,
      excludeSemantics: semanticLabel != null,
      child: Material(
        color: colors['fill.hover'],
        shape: const StadiumBorder(),
        child: InkWell(
          onTap: onTap,
          customBorder: const StadiumBorder(),
          child: Container(
            height: 32,
            padding: const EdgeInsets.only(left: 12, right: 8),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              spacing: 4,
              children: [
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                    color: colors['text.primary'],
                  ),
                ),
                Icon(
                  LucideIcons.chevronDown,
                  size: 12,
                  color: colors['text.muted'],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
