import 'package:flutter/material.dart';

import '../theme.dart';
import '../tokens.g.dart';

class PanelTab<T> {
  const PanelTab(this.value, this.icon, this.label);
  final T value;
  final IconData icon;
  final String label;
}

/// `c-ptab`: the work panel tabs (icon over label), with a "More" menu for
/// the rest.
class PanelTabs<T> extends StatelessWidget {
  const PanelTabs({
    super.key,
    required this.tabs,
    required this.selected,
    required this.onSelected,
    this.more = const [],
    this.moreLabel = 'More',
    this.moreIcon = Icons.more_horiz,
  });

  final List<PanelTab<T>> tabs;

  /// In the "More" menu.
  final List<PanelTab<T>> more;
  final T selected;
  final ValueChanged<T> onSelected;
  final String moreLabel;
  final IconData moreIcon;

  @override
  Widget build(BuildContext context) {
    final colors = PircColorTokens.of(context);
    final label = Theme.of(context).textTheme.labelSmall;
    Widget tab(IconData icon, String text, bool on, VoidCallback? onTap) =>
        Expanded(
          child: Semantics(
            selected: on,
            button: true,
            child: InkWell(
              onTap: onTap,
              child: SizedBox(
                height: 56,
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      icon,
                      size: 20,
                      color: on
                          ? colors['accent.default']
                          : colors['text.secondary'],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      text,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: label?.copyWith(
                        color: on
                            ? colors['text.primary']
                            : colors['text.secondary'],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
    final inMore = more.where((t) => t.value == selected).firstOrNull;
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: colors['line.hairline'])),
      ),
      child: Row(
        children: [
          for (final t in tabs)
            tab(
              t.icon,
              t.label,
              t.value == selected,
              () => onSelected(t.value),
            ),
          if (more.isNotEmpty)
            Expanded(
              child: PopupMenuButton<T>(
                tooltip: moreLabel,
                onSelected: onSelected,
                itemBuilder: (_) => [
                  for (final t in more)
                    PopupMenuItem(
                      value: t.value,
                      child: Row(
                        children: [
                          Icon(t.icon, size: 18),
                          const SizedBox(width: PircSpacing.stackSm),
                          Text(t.label),
                        ],
                      ),
                    ),
                ],
                child: Row(
                  children: [
                    tab(
                      inMore?.icon ?? moreIcon,
                      inMore?.label ?? moreLabel,
                      inMore != null,
                      null,
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}
