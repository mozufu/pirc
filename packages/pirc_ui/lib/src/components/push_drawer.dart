import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../adaptive_scaffold.dart';
import '../theme.dart';
import '../tokens.g.dart';

/// The ☰ drawer (E21): it pushes the page to the right instead of covering
/// it, so no icon is cut in half. The page keeps its width and its state; a
/// tap on the visible part of the page, Escape or Back closes the drawer.
class PushDrawer extends StatefulWidget {
  const PushDrawer({
    super.key,
    required this.open,
    required this.onClose,
    required this.drawer,
    required this.child,
    this.closeLabel = 'Close',
  });

  final bool open;
  final VoidCallback onClose;
  final Widget drawer;
  final Widget child;

  /// The accessible name of the area that closes the drawer.
  final String closeLabel;

  /// 310 on phones, 396 on tablets, 412 on desktops.
  static double widthFor(PircLayout layout) => switch (layout) {
    PircLayout.compact => 310,
    PircLayout.portrait || PircLayout.landscape => 396,
    PircLayout.desktop => 412,
  };

  @override
  State<PushDrawer> createState() => _PushDrawerState();
}

class _PushDrawerState extends State<PushDrawer>
    with SingleTickerProviderStateMixin {
  late final _controller = AnimationController(
    vsync: this,
    duration: PircMotion.sheet,
    value: widget.open ? 1 : 0,
  );
  late final _position = CurvedAnimation(
    parent: _controller,
    curve: PircMotion.ease,
  );

  @override
  void didUpdateWidget(PushDrawer old) {
    super.didUpdateWidget(old);
    if (widget.open != old.open) {
      widget.open ? _controller.forward() : _controller.reverse();
    }
  }

  @override
  void dispose() {
    _position.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = PircColorTokens.of(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = PushDrawer.widthFor(
          PircLayout.forWidth(constraints.maxWidth),
        ).clamp(0.0, constraints.maxWidth - 56);
        return PopScope(
          canPop: !widget.open,
          onPopInvokedWithResult: (didPop, _) {
            if (!didPop && widget.open) widget.onClose();
          },
          child: CallbackShortcuts(
            bindings: {
              const SingleActivator(LogicalKeyboardKey.escape): () {
                if (widget.open) widget.onClose();
              },
            },
            child: AnimatedBuilder(
              animation: _position,
              builder: (context, _) {
                final shown = _position.value;
                final offset = width * shown;
                return Stack(
                  children: [
                    Positioned(
                      left: offset,
                      top: 0,
                      bottom: 0,
                      width: constraints.maxWidth,
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          ExcludeFocus(
                            excluding: widget.open,
                            child: widget.child,
                          ),
                          if (shown > 0)
                            Semantics(
                              button: true,
                              label: widget.closeLabel,
                              child: GestureDetector(
                                onTap: widget.onClose,
                                child: ColoredBox(
                                  color: colors['scrim'].withValues(
                                    alpha: colors['scrim'].a * shown,
                                  ),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                    if (shown > 0)
                      Positioned(
                        left: offset - width,
                        top: 0,
                        bottom: 0,
                        width: width,
                        child: Focus(
                          autofocus: widget.open,
                          child: Material(
                            color: colors['surface.sidebar'],
                            child: widget.drawer,
                          ),
                        ),
                      ),
                  ],
                );
              },
            ),
          ),
        );
      },
    );
  }
}
