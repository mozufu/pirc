import 'package:flutter/material.dart';

import 'theme.dart';
import 'tokens.g.dart';

/// The four window layouts (plans/client.md, Design system and layouts).
/// They are chosen by available width, never by device type.
enum PircLayout {
  /// < 600: one screen and a bottom tab bar.
  compact,

  /// 600–899: tab rail and one pane; opening an item replaces the list, info
  /// slides in from the right.
  portrait,

  /// 900–1199: tab rail, list and content; the side pane replaces content.
  landscape,

  /// ≥ 1200: tab rail, list, content and an optional side pane.
  desktop;

  static PircLayout forWidth(double width) => width >= PircBreakpoints.desktop
      ? desktop
      : width >= PircBreakpoints.landscape
      ? landscape
      : width >= PircBreakpoints.portrait
      ? portrait
      : compact;

  double get railWidth => switch (this) {
    compact => 0,
    portrait || landscape => 76,
    desktop => PircSize.railWidth,
  };

  double get listWidth => switch (this) {
    landscape => 320,
    desktop => 340,
    compact || portrait => double.infinity,
  };

  /// Width of the side pane where it sits beside or over the content.
  double get sideWidth => switch (this) {
    portrait => 440,
    desktop => 400,
    compact || landscape => double.infinity,
  };
}

class PircDestination {
  const PircDestination({
    required this.icon,
    required this.label,
    this.selectedIcon,
    this.badge,
  });

  final IconData icon;
  final IconData? selectedIcon;
  final String label;

  /// Unread count shown on the tab (yellow); null or 0 hides it.
  final int? badge;
}

/// The app frame: tab bar or rail, a list pane, a content pane and an
/// optional side pane, arranged by [PircLayout].
///
/// [list], [content] and [side] keep their state when the layout changes:
/// each lives under a [GlobalKey] owned by this widget, so a resize moves the
/// subtree instead of rebuilding it, and a pane that is not visible in the
/// current layout stays mounted offstage.
class AdaptiveScaffold extends StatefulWidget {
  const AdaptiveScaffold({
    super.key,
    required this.destinations,
    required this.selectedIndex,
    required this.onDestinationSelected,
    required this.list,
    this.content,
    this.side,
    this.placeholder,
    this.contentMaxWidth = 760,
    this.trailing,
  });

  final List<PircDestination> destinations;
  final int selectedIndex;
  final ValueChanged<int> onDestinationSelected;

  /// The tab's list (conversations, sessions, …).
  final Widget list;

  /// The open item, if any.
  final Widget? content;

  /// Information or tools about the open item, if shown.
  final Widget? side;

  /// Shown in the content area of wide layouts when nothing is open.
  final Widget? placeholder;

  /// Reading width of the content (760 for conversations, 720 for settings).
  final double contentMaxWidth;

  /// Shown at the end of the rail (for example a settings button).
  final Widget? trailing;

  @override
  State<AdaptiveScaffold> createState() => _AdaptiveScaffoldState();
}

class _AdaptiveScaffoldState extends State<AdaptiveScaffold> {
  final _listKey = GlobalKey(debugLabel: 'list pane');
  final _contentKey = GlobalKey(debugLabel: 'content pane');
  final _sideKey = GlobalKey(debugLabel: 'side pane');

  Widget _pane(GlobalKey key, Widget child, {bool visible = true}) => Offstage(
    offstage: !visible,
    child: TickerMode(
      enabled: visible,
      child: KeyedSubtree(key: key, child: child),
    ),
  );

  Widget _content(PircLayout layout) {
    final content = widget.content;
    if (content == null) {
      return widget.placeholder ?? const SizedBox.expand();
    }
    // The same wrapper in every layout, so a resize never replaces the
    // content's element (and with it a draft or a scroll position).
    final wide = layout == PircLayout.landscape || layout == PircLayout.desktop;
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: wide ? widget.contentMaxWidth : double.infinity,
        ),
        child: content,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final layout = PircLayout.forWidth(constraints.maxWidth);
        final colors = PircColorTokens.of(context);
        final divider = VerticalDivider(
          width: 1,
          thickness: 1,
          color: colors['line.hairline'],
        );
        final hasContent = widget.content != null;
        final hasSide = widget.side != null;
        final content = _content(layout);
        final side = widget.side ?? const SizedBox.shrink();

        Widget body;
        switch (layout) {
          case PircLayout.compact:
          case PircLayout.portrait:
            body = Stack(
              fit: StackFit.expand,
              children: [
                _pane(_listKey, widget.list, visible: !hasContent),
                _pane(_contentKey, content, visible: hasContent),
                if (layout == PircLayout.compact)
                  _pane(_sideKey, side, visible: hasSide)
                else
                  Positioned(
                    top: 0,
                    right: 0,
                    bottom: 0,
                    width: layout.sideWidth,
                    child: _pane(
                      _sideKey,
                      DecoratedBox(
                        decoration: BoxDecoration(
                          color: colors['surface.layer'],
                          boxShadow:
                              Theme.of(
                                context,
                              ).extension<PircElevationTokens>()?.float ??
                              const [],
                        ),
                        child: side,
                      ),
                      visible: hasSide,
                    ),
                  ),
              ],
            );
          case PircLayout.landscape:
            body = Row(
              children: [
                SizedBox(
                  width: layout.listWidth,
                  child: _pane(_listKey, widget.list),
                ),
                divider,
                Expanded(
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      _pane(_contentKey, content, visible: !hasSide),
                      _pane(_sideKey, side, visible: hasSide),
                    ],
                  ),
                ),
              ],
            );
          case PircLayout.desktop:
            body = Row(
              children: [
                SizedBox(
                  width: layout.listWidth,
                  child: _pane(_listKey, widget.list),
                ),
                divider,
                Expanded(child: _pane(_contentKey, content)),
                if (hasSide) divider,
                SizedBox(
                  width: hasSide ? layout.sideWidth : 0,
                  child: _pane(_sideKey, side, visible: hasSide),
                ),
              ],
            );
        }

        if (layout == PircLayout.compact) {
          return Scaffold(
            body: SafeArea(bottom: false, child: body),
            bottomNavigationBar: NavigationBar(
              selectedIndex: widget.selectedIndex,
              onDestinationSelected: widget.onDestinationSelected,
              destinations: [
                for (final d in widget.destinations)
                  NavigationDestination(
                    icon: _badged(d, d.icon),
                    selectedIcon: _badged(d, d.selectedIcon ?? d.icon),
                    label: d.label,
                  ),
              ],
            ),
          );
        }
        return Scaffold(
          body: SafeArea(
            child: Row(
              children: [
                _Rail(
                  width: layout.railWidth,
                  destinations: widget.destinations,
                  selectedIndex: widget.selectedIndex,
                  onSelected: widget.onDestinationSelected,
                  trailing: widget.trailing,
                  badged: _badged,
                ),
                divider,
                Expanded(child: body),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _badged(PircDestination destination, IconData icon) {
    final count = destination.badge ?? 0;
    final child = Icon(icon);
    if (count <= 0) return child;
    return Badge(label: Text(count > 99 ? '99+' : '$count'), child: child);
  }
}

/// The tab rail: a fixed-width column of icon-and-label buttons.
class _Rail extends StatelessWidget {
  const _Rail({
    required this.width,
    required this.destinations,
    required this.selectedIndex,
    required this.onSelected,
    required this.badged,
    this.trailing,
  });

  final double width;
  final List<PircDestination> destinations;
  final int selectedIndex;
  final ValueChanged<int> onSelected;
  final Widget Function(PircDestination, IconData) badged;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final colors = PircColorTokens.of(context);
    final label = Theme.of(context).textTheme.labelSmall;
    return Material(
      color: colors['surface.sidebar'],
      child: SizedBox(
        width: width,
        child: Column(
          children: [
            const SizedBox(height: PircSpacing.stackSm),
            for (final (index, destination) in destinations.indexed)
              Semantics(
                selected: index == selectedIndex,
                button: true,
                child: InkWell(
                  onTap: () => onSelected(index),
                  child: SizedBox(
                    width: width,
                    height: 64,
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Container(
                          width: 48,
                          height: 32,
                          decoration: BoxDecoration(
                            color: index == selectedIndex
                                ? colors['accent.soft']
                                : null,
                            borderRadius: BorderRadius.circular(
                              PircRadius.pill,
                            ),
                          ),
                          child: IconTheme.merge(
                            data: IconThemeData(
                              size: PircSize.iconBar,
                              color: index == selectedIndex
                                  ? colors['accent.default']
                                  : colors['text.secondary'],
                            ),
                            child: badged(
                              destination,
                              index == selectedIndex
                                  ? destination.selectedIcon ?? destination.icon
                                  : destination.icon,
                            ),
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          destination.label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: label?.copyWith(
                            color: index == selectedIndex
                                ? colors['text.primary']
                                : colors['text.secondary'],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            const Spacer(),
            ?trailing,
          ],
        ),
      ),
    );
  }
}
