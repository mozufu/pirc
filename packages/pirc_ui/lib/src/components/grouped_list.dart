import 'package:flutter/material.dart';

import '../theme.dart';
import '../tokens.g.dart';

/// `c-gl`: a group's title, `label.section` 32 from the edge.
class GroupLabel extends StatelessWidget {
  const GroupLabel(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(
      PircSpacing.gutterGroupedText,
      22,
      PircSpacing.gutterGroupedText,
      6,
    ),
    child: Text(text, style: Theme.of(context).textTheme.labelMedium),
  );
}

/// `c-gn`: a note under a group, 12.5/18 muted (or `status.danger` for
/// an [error]).
class GroupNote extends StatelessWidget {
  const GroupNote(
    this.text, {
    super.key,
    this.error = false,
    this.textAlign,
    this.padding = const EdgeInsets.fromLTRB(
      PircSpacing.gutterGroupedText,
      8,
      PircSpacing.gutterGroupedText,
      0,
    ),
  });

  final String text;
  final bool error;
  final TextAlign? textAlign;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final colors = PircColorTokens.of(context);
    return Padding(
      padding: padding,
      child: Text(
        text,
        textAlign: textAlign,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
          color: error ? colors['status.danger'] : colors['text.muted'],
        ),
      ),
    );
  }
}

/// `c-group`: rows on `surface.layer`, radius 16, 16 from the edges, with
/// a hairline between rows from the text start (16).
class GroupedList extends StatelessWidget {
  const GroupedList({super.key, required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final colors = PircColorTokens.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: PircSpacing.gutterPhone),
      child: Material(
        color: colors['surface.layer'],
        borderRadius: BorderRadius.circular(PircRadius.lg),
        clipBehavior: Clip.antiAlias,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final (i, child) in children.indexed) ...[
              if (i > 0)
                Padding(
                  padding: const EdgeInsets.only(left: PircSpacing.gutterPhone),
                  child: Container(height: 1, color: colors['line.hairline']),
                ),
              child,
            ],
          ],
        ),
      ),
    );
  }
}

/// `c-grow`: a grouped row, at least 56 high, 16 inside: [leading], the
/// title (`row`) with an optional subtitle (13/18 muted), [trailing].
class GroupedRow extends StatelessWidget {
  const GroupedRow({
    super.key,
    this.title,
    this.titleWidget,
    this.subtitle,
    this.leading,
    this.trailing,
    this.onTap,
    this.enabled = true,
    this.wrapSubtitle = false,
    this.titleColor,
    this.semanticLabel,
  });

  final String? title;

  /// Replaces [title] (an editable field, a "＋ Add" label).
  final Widget? titleWidget;
  final String? subtitle;
  final Widget? leading;
  final Widget? trailing;
  final VoidCallback? onTap;

  /// A disabled row is drawn at 45 %.
  final bool enabled;

  /// Lets the subtitle wrap instead of ending with an ellipsis.
  final bool wrapSubtitle;
  final Color? titleColor;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final title = this.title;
    final subtitle = this.subtitle;
    Widget row = ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 56),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: PircSpacing.gutterPhone,
          vertical: 8,
        ),
        child: Row(
          spacing: 12,
          children: [
            ?leading,
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                spacing: 1,
                children: [
                  if (titleWidget != null)
                    titleWidget!
                  else if (title != null)
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: text.bodyMedium?.copyWith(color: titleColor),
                    ),
                  if (subtitle != null && subtitle.isNotEmpty)
                    Text(
                      subtitle,
                      maxLines: wrapSubtitle ? null : 1,
                      overflow: wrapSubtitle ? null : TextOverflow.ellipsis,
                      style: text.bodySmall,
                    ),
                ],
              ),
            ),
            ?trailing,
          ],
        ),
      ),
    );
    if (onTap != null && enabled) {
      row = InkWell(onTap: onTap, child: row);
    }
    if (!enabled) row = Opacity(opacity: 0.45, child: row);
    return Semantics(
      label: semanticLabel,
      button: onTap != null,
      enabled: enabled,
      child: row,
    );
  }
}

/// `c-switch`: 52 × 32, `line.strong` off and `accent.default` on, with a
/// 24 white knob. Null [onChanged] disables it (drawn at 50 %).
class PircSwitch extends StatelessWidget {
  const PircSwitch({
    super.key,
    required this.value,
    required this.onChanged,
    this.semanticLabel,
  });

  final bool value;
  final ValueChanged<bool>? onChanged;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final colors = PircColorTokens.of(context);
    final reduce = MediaQuery.disableAnimationsOf(context);
    final enabled = onChanged != null;
    Widget body = SizedBox(
      width: 52,
      height: 32,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: value ? colors['accent.default'] : colors['line.strong'],
          borderRadius: BorderRadius.circular(16),
        ),
        child: Stack(
          children: [
            AnimatedPositioned(
              duration: reduce ? Duration.zero : PircMotion.fast,
              left: value ? 24 : 4,
              top: 4,
              child: Container(
                width: 24,
                height: 24,
                decoration: const BoxDecoration(
                  color: Colors.white,
                  shape: BoxShape.circle,
                  boxShadow: [
                    BoxShadow(
                      color: Color(0x40000000),
                      blurRadius: 3,
                      offset: Offset(0, 1),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
    if (!enabled) body = Opacity(opacity: 0.5, child: body);
    return Semantics(
      toggled: value,
      enabled: enabled,
      label: semanticLabel,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: enabled ? () => onChanged!(!value) : null,
        child: body,
      ),
    );
  }
}

/// One choice of a [Segmented].
@immutable
class SegmentedItem<T> {
  const SegmentedItem(this.value, this.label);
  final T value;
  final String label;
}

/// `c-seg`: equal segments 36 high in a 3-padded track (radius 12); the
/// chosen one on `surface.layer` with a small shadow. [strong] uses the
/// `fill.hoverStrong` track the E steps use.
class Segmented<T> extends StatelessWidget {
  const Segmented({
    super.key,
    required this.items,
    required this.selected,
    required this.onSelected,
    this.strong = false,
    this.semanticLabel,
  });

  final List<SegmentedItem<T>> items;
  final T? selected;
  final ValueChanged<T>? onSelected;
  final bool strong;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final colors = PircColorTokens.of(context);
    final style = Theme.of(context).textTheme.labelLarge;
    final enabled = onSelected != null;
    Widget track = Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: colors[strong ? 'fill.hoverStrong' : 'fill.hover'],
        borderRadius: BorderRadius.circular(PircRadius.md),
      ),
      child: Row(
        spacing: 2,
        children: [
          for (final item in items)
            Expanded(
              child: Semantics(
                inMutuallyExclusiveGroup: true,
                checked: item.value == selected,
                button: true,
                enabled: enabled,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: enabled ? () => onSelected!(item.value) : null,
                  child: Container(
                    height: 36,
                    alignment: Alignment.center,
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    decoration: item.value == selected
                        ? BoxDecoration(
                            color: colors['surface.layer'],
                            borderRadius: BorderRadius.circular(10),
                            boxShadow: const [
                              BoxShadow(
                                color: Color(0x14000000),
                                blurRadius: 2,
                                offset: Offset(0, 1),
                              ),
                            ],
                          )
                        : null,
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text(
                        item.label,
                        maxLines: 1,
                        style: style?.copyWith(
                          fontSize: 13.5,
                          color:
                              colors[item.value == selected
                                  ? 'text.primary'
                                  : 'text.muted'],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
    if (!enabled) track = Opacity(opacity: 0.45, child: track);
    return Semantics(label: semanticLabel, container: true, child: track);
  }
}

/// `c-chip`: 38 high, pill, `fill.hover` with 14 `text.secondary`; on,
/// the ink fill with 500 text.
class PillChip extends StatelessWidget {
  const PillChip({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final colors = PircColorTokens.of(context);
    return Semantics(
      selected: selected,
      button: true,
      child: Material(
        color: colors[selected ? 'action.primary' : 'fill.hover'],
        shape: const StadiumBorder(),
        child: InkWell(
          customBorder: const StadiumBorder(),
          onTap: onTap,
          child: Container(
            height: 38,
            padding: const EdgeInsets.symmetric(horizontal: 14),
            child: Center(
              widthFactor: 1,
              child: Text(
                label,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  fontSize: 14,
                  height: 20 / 14,
                  fontWeight: selected ? FontWeight.w500 : FontWeight.w400,
                  color:
                      colors[selected ? 'action.onPrimary' : 'text.secondary'],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// `d-radio`: a grouped row with an 18 radio mark (5 accent border when
/// chosen), the title and a wrapping subtitle.
class RadioRow extends StatelessWidget {
  const RadioRow({
    super.key,
    required this.title,
    this.subtitle,
    required this.selected,
    required this.onTap,
  });

  final String title;
  final String? subtitle;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final colors = PircColorTokens.of(context);
    return Semantics(
      inMutuallyExclusiveGroup: true,
      checked: selected,
      child: GroupedRow(
        title: title,
        subtitle: subtitle,
        wrapSubtitle: true,
        onTap: onTap,
        leading: Container(
          width: 18,
          height: 18,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: selected
                ? Border.all(color: colors['accent.default'], width: 5)
                : Border.all(color: colors['line.strong'], width: 1.5),
          ),
        ),
      ),
    );
  }
}
