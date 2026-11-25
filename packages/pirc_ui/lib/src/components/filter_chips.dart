import 'package:flutter/material.dart';

import '../theme.dart';
import '../tokens.g.dart';

/// One chip of [FilterChips].
class FilterChipItem<T> {
  const FilterChipItem(this.value, this.label, {this.count});
  final T value;
  final String label;

  /// Shown after the label in `text.warning` when positive.
  final int? count;
}

/// Full-round filter chips (`c-filter`): 32 high, `fill.hover`, the selected
/// one `action.primary`; they scroll sideways.
class FilterChips<T> extends StatelessWidget {
  const FilterChips({
    super.key,
    required this.items,
    required this.selected,
    required this.onSelected,
    this.padding = const EdgeInsets.symmetric(
      horizontal: PircSpacing.gutterPhone,
    ),
  });

  final List<FilterChipItem<T>> items;
  final T selected;
  final ValueChanged<T> onSelected;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    final colors = PircColorTokens.of(context);
    final text = Theme.of(context).textTheme.labelLarge;
    return SizedBox(
      height: 44,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: padding,
        itemCount: items.length,
        separatorBuilder: (_, _) => const SizedBox(width: PircSpacing.stackSm),
        itemBuilder: (context, index) {
          final item = items[index];
          final on = item.value == selected;
          final count = item.count ?? 0;
          return Center(
            child: Semantics(
              selected: on,
              button: true,
              child: Material(
                color: on ? colors['action.primary'] : colors['fill.hover'],
                shape: const StadiumBorder(),
                child: InkWell(
                  customBorder: const StadiumBorder(),
                  onTap: () => onSelected(item.value),
                  child: Container(
                    height: 32,
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                    alignment: Alignment.center,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          item.label,
                          style: text?.copyWith(
                            color: on
                                ? colors['action.onPrimary']
                                : colors['text.primary'],
                          ),
                        ),
                        if (count > 0) ...[
                          const SizedBox(width: 6),
                          Text(
                            '$count',
                            style: text?.copyWith(
                              fontSize: 13,
                              color: on
                                  ? colors['action.onPrimary']
                                  : colors['text.warning'],
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

/// The kinds of [StateDot].
enum DotState { running, waiting, done, failed, idle }

/// A 7 px state dot (`state-dot`). Always shown next to text.
class StateDot extends StatelessWidget {
  const StateDot(this.state, {super.key});

  final DotState state;

  @override
  Widget build(BuildContext context) {
    final colors = PircColorTokens.of(context);
    final color = switch (state) {
      DotState.running => colors['accent.default'],
      DotState.waiting => colors['status.warning'],
      DotState.done => colors['status.success'],
      DotState.failed => colors['status.danger'],
      DotState.idle => colors['text.faint'],
    };
    final hollow = state == DotState.idle;
    return Container(
      width: PircSize.stateDot,
      height: PircSize.stateDot,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: hollow ? null : color,
        border: hollow ? Border.all(color: color, width: 1.5) : null,
      ),
    );
  }
}

/// The small "Needs you" pill at the end of a row (`status.warningSoft`).
class NeedsYouPill extends StatelessWidget {
  const NeedsYouPill(this.label, {super.key});
  final String label;

  @override
  Widget build(BuildContext context) {
    final colors = PircColorTokens.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: colors['status.warningSoft'],
        borderRadius: BorderRadius.circular(PircRadius.pill),
      ),
      child: Text(
        label,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
          color: colors['text.warning'],
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}
