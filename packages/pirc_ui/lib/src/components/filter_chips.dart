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

/// Full-round filter chips (`e-f`): 34 high, `fill.hover`, the selected one
/// `action.primary`; label 14, count 12/600 in `text.warning`; they scroll
/// sideways.
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
    return SizedBox(
      height: 40,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: padding.copyWith(bottom: 6),
        itemCount: items.length,
        separatorBuilder: (_, _) => const SizedBox(width: 6),
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
                    height: 34,
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                    alignment: Alignment.center,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      spacing: 6,
                      children: [
                        Text(
                          item.label,
                          style: TextStyle(
                            fontSize: 14,
                            height: 20 / 14,
                            fontWeight: on ? FontWeight.w500 : FontWeight.w400,
                            color: on
                                ? colors['action.onPrimary']
                                : colors['text.secondary'],
                          ),
                        ),
                        if (count > 0)
                          Text(
                            '$count',
                            style: TextStyle(
                              fontSize: 12,
                              height: 20 / 12,
                              fontWeight: FontWeight.w600,
                              color: on
                                  ? colors['action.onPrimary']
                                  : colors['text.warning'],
                            ),
                          ),
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
