import 'package:flutter/gestures.dart';

/// Reconciles accepted touch clicks with a measured document hit target.
///
/// A Canvas callback can finish after a later gesture. Keep the latest real
/// target until that callback completes so it cannot revive an old hover.
/// Exits wait for accepted clicks already in the native queue: dispatching an
/// early exit can otherwise let a library coalesce it ahead of a later click.
class NativeDocumentTouchBoundary {
  NativeDocumentTouchBoundary({required this.onExit});

  final void Function(String id, String? relatedTarget, Offset position) onExit;
  final _touches = <int>{};
  final _hovered = <String>{};
  final _queuedClicks = <(String, int)>{};
  int? _primary;
  int _epoch = 0;
  int _sequence = 0;
  (String?, Offset)? _completedTarget;

  int get epoch => _epoch;
  int get sequence => _sequence;

  void down(PointerDownEvent event) {
    if (event.kind != PointerDeviceKind.touch) return;
    if (_touches.isEmpty) {
      _primary = event.pointer;
      _sequence++;
    }
    _touches.add(event.pointer);
  }

  bool up(PointerUpEvent event) {
    if (event.kind != PointerDeviceKind.touch) return false;
    final primary = _touches.remove(event.pointer) && _primary == event.pointer;
    if (primary) {
      _sequence++;
      _primary = null;
      // An unavailable hit must never reuse the preceding gesture's target.
      _completedTarget = null;
    }
    return primary;
  }

  void cancel(PointerCancelEvent event) {
    _touches.remove(event.pointer);
    if (_primary == event.pointer) {
      _primary = null;
      _sequence++;
    }
  }

  void completeTarget(String? id, Offset position) {
    if (!position.dx.isFinite || !position.dy.isFinite) return;
    _completedTarget = (id, position);
    reconcile();
  }

  void queuedClick(String id, int pointerId) =>
      _queuedClicks.add((id, pointerId));
  void finishedClick(String id, int pointerId) =>
      _queuedClicks.remove((id, pointerId));
  void acceptedClick(String id) => _hovered.add(id);

  void reconcile() {
    final target = _completedTarget;
    if (target == null || _queuedClicks.isNotEmpty) return;
    for (final id in _hovered.toList()) {
      if (id == target.$1) continue;
      _hovered.remove(id);
      onExit(id, target.$1, target.$2);
    }
  }

  void clear() {
    _epoch++;
    _sequence++;
    _touches.clear();
    _hovered.clear();
    _queuedClicks.clear();
    _primary = null;
    _completedTarget = null;
  }
}
