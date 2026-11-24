import '../l10n/app_i18n.dart';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:pirc_render/src/native_equation_numbers.dart';

/// Keeps a local Navigator stack for each retained App history surface while
/// mounting [child] under only the active surface's root route.
class NativeAppSurface extends StatefulWidget {
  const NativeAppSurface({
    super.key,
    required this.activeIdentity,
    required this.retainedIdentities,
    required this.accountIdentity,
    required this.visible,
    required this.child,
    this.onNavigationChanged,
  });

  final Object activeIdentity;
  final Set<Object> retainedIdentities;
  final Object accountIdentity;
  final bool visible;
  final Widget child;
  final VoidCallback? onNavigationChanged;

  @override
  NativeAppSurfaceState createState() => NativeAppSurfaceState();
}

class NativeAppSurfaceState extends State<NativeAppSurface> {
  final Map<Object, _NativeAppSurfaceSlot> _slots = {};
  final ValueNotifier<int> _rootRevision = ValueNotifier<int>(0);
  bool _navigationChangeQueued = false;

  /// Context below the active local Navigator, or null while hidden/unmounted.
  /// Callers must not fall back to the parent State.context.
  BuildContext? get appContext {
    if (!widget.visible) return null;
    return ownedAppContext;
  }

  /// Context below the active local Navigator, even while this surface is
  /// offstage. Callers can use it for work owned by a hidden document without
  /// falling back to the parent Navigator or another surface.
  BuildContext? get ownedAppContext {
    final navigator = _slots[widget.activeIdentity]?.navigatorKey.currentState;
    return navigator?.overlay?.context;
  }

  bool get canPop {
    if (!widget.visible) return false;
    return _slots[widget.activeIdentity]?.navigatorKey.currentState?.canPop() ??
        false;
  }

  /// Pops one route from the visible App surface without reaching the parent
  /// Navigator. Returns false when the local stack has no overlay route.
  Future<bool> popOverlay() async {
    if (!widget.visible) return false;
    final navigator = _slots[widget.activeIdentity]?.navigatorKey.currentState;
    if (navigator == null || !navigator.canPop()) return false;
    return navigator.maybePop();
  }

  /// Removes all overlay routes from this surface's active local Navigator.
  /// This also works while hidden and never touches a parent Navigator.
  Future<void> closeOverlays() {
    final navigator = _slots[widget.activeIdentity]?.navigatorKey.currentState;
    navigator?.popUntil((route) => route.isFirst);
    return Future<void>.value();
  }

  @override
  void initState() {
    super.initState();
    _validateActiveIdentity();
    _slots[widget.activeIdentity] = _createSlot(widget.activeIdentity);
  }

  @override
  void didUpdateWidget(covariant NativeAppSurface oldWidget) {
    super.didUpdateWidget(oldWidget);
    _validateActiveIdentity();

    if (oldWidget.accountIdentity != widget.accountIdentity) {
      _slots.clear();
    } else {
      _slots.removeWhere(
        (identity, _) => !widget.retainedIdentities.contains(identity),
      );
    }
    // Do not allocate Navigators for unknown inactive entries. They get a
    // stack only once they become active.
    _slots.putIfAbsent(
      widget.activeIdentity,
      () => _createSlot(widget.activeIdentity),
    );

    // Root routes read the latest child from this notifier. Exactly one route
    // returns it; all other retained roots keep only a placeholder.
    _rootRevision.value++;
    if (oldWidget.activeIdentity != widget.activeIdentity ||
        oldWidget.accountIdentity != widget.accountIdentity ||
        oldWidget.visible != widget.visible ||
        !_sameIdentities(
          oldWidget.retainedIdentities,
          widget.retainedIdentities,
        )) {
      _scheduleNavigationChanged();
    }
  }

  void _validateActiveIdentity() {
    if (!widget.retainedIdentities.contains(widget.activeIdentity)) {
      throw ArgumentError.value(
        widget.activeIdentity,
        'activeIdentity',
        tr("The active surface identity must be retained."),
      );
    }
  }

  bool _sameIdentities(Set<Object> first, Set<Object> second) =>
      first.length == second.length && first.containsAll(second);

  _NativeAppSurfaceSlot _createSlot(Object identity) {
    return _NativeAppSurfaceSlot(
      identity: identity,
      owner: this,
      accountIdentity: widget.accountIdentity,
    );
  }

  void _routeChanged(Object identity, Object accountIdentity) {
    if (!mounted ||
        !widget.visible ||
        widget.activeIdentity != identity ||
        widget.accountIdentity != accountIdentity) {
      return;
    }
    _scheduleNavigationChanged();
  }

  void _scheduleNavigationChanged() {
    if (_navigationChangeQueued) return;
    _navigationChangeQueued = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _navigationChangeQueued = false;
      if (mounted) widget.onNavigationChanged?.call();
    });
  }

  void _handleSystemPop(Object identity) {
    if (identity == widget.activeIdentity && widget.visible) {
      // The local root route may itself have a PopScope that handles system
      // back (for example, to close an App panel). Let maybePop reach that
      // PopScope even when this Navigator has no overlay route. The public
      // popOverlay API remains limited to overlay routes.
      final navigator = _slots[identity]?.navigatorKey.currentState;
      if (navigator != null) unawaited(navigator.maybePop());
    }
  }

  @override
  Widget build(BuildContext context) {
    AppI18n.watch(context);
    return Stack(
      fit: StackFit.expand,
      children: [
        for (final entry in _slots.entries) _buildSlot(entry.key, entry.value),
      ],
    );
  }

  Widget _buildSlot(Object identity, _NativeAppSurfaceSlot slot) {
    final active = identity == widget.activeIdentity;
    final enabled = active && widget.visible;
    return Offstage(
      offstage: !enabled,
      child: ExcludeFocus(
        excluding: !enabled,
        child: TickerMode(
          enabled: enabled,
          child: ScaffoldMessenger(
            child: NavigatorPopHandler<void>(
              enabled: enabled,
              onPopWithResult: (_) => _handleSystemPop(identity),
              child: NativeEquationNumberDocument(
                child: Navigator(
                  key: slot.navigatorKey,
                  observers: [slot.observer],
                  onGenerateRoute: (settings) => MaterialPageRoute<void>(
                    settings: settings,
                    builder: (_) => ValueListenableBuilder<int>(
                      valueListenable: _rootRevision,
                      builder: (context, _, _) =>
                          identity == widget.activeIdentity
                          ? widget.child
                          : const Scaffold(body: SizedBox.shrink()),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    _rootRevision.dispose();
    _slots.clear();
    super.dispose();
  }
}

class _NativeAppSurfaceSlot {
  _NativeAppSurfaceSlot({
    required Object identity,
    required NativeAppSurfaceState owner,
    required Object accountIdentity,
  }) : navigatorKey = GlobalKey<NavigatorState>(),
       observer = _NativeAppSurfaceObserver(owner, identity, accountIdentity);

  final GlobalKey<NavigatorState> navigatorKey;
  final NavigatorObserver observer;
}

class _NativeAppSurfaceObserver extends NavigatorObserver {
  _NativeAppSurfaceObserver(this.owner, this.identity, this.accountIdentity);

  final NativeAppSurfaceState owner;
  final Object identity;
  final Object accountIdentity;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      owner._routeChanged(identity, accountIdentity);

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      owner._routeChanged(identity, accountIdentity);

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      owner._routeChanged(identity, accountIdentity);

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) =>
      owner._routeChanged(identity, accountIdentity);
}
