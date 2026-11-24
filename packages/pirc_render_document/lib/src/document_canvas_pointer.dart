import 'package:pirc_render/src/render_l10n.dart';
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

typedef NativeCanvasPointerEventCallback =
    Future<bool> Function(String type, Map<String, dynamic> data);

/// Sends native canvas pointer input to the document script runtime.
///
/// The pointer state belongs to [documentIdentity] and [elementId], rather
/// than to an individual canvas child snapshot. Callers can keep this widget's
/// key stable while rebuilding the canvas content.
class NativeDocumentCanvasPointer extends StatefulWidget {
  const NativeDocumentCanvasPointer({
    super.key,
    required this.child,
    required this.onEvent,
    required this.documentIdentity,
    required this.elementId,
    required this.touchActionNone,
    this.viewportOrigin,
    this.onTouchClickQueued,
  });

  final Widget child;
  final NativeCanvasPointerEventCallback onEvent;
  final Object documentIdentity;
  final String elementId;
  final bool touchActionNone;

  /// Returns the global logical-pixel origin of the document viewport.
  ///
  /// Canvas client coordinates are calculated by subtracting this value from
  /// the global event position. The callback is evaluated for each event so a
  /// scroll or viewport layout change is reflected immediately.
  final Offset Function()? viewportOrigin;

  /// Called synchronously when an accepted primary touch click is queued.
  /// The returned callback runs once after the click event dispatch finishes.
  final VoidCallback? Function(Map<String, dynamic> data)? onTouchClickQueued;

  @override
  State<NativeDocumentCanvasPointer> createState() =>
      _NativeDocumentCanvasPointerState();
}

class _NativeDocumentCanvasPointerState
    extends State<NativeDocumentCanvasPointer> {
  final GlobalKey _surfaceRenderKey = GlobalKey();
  final Map<int, _CanvasPointerState> _pointers = <int, _CanvasPointerState>{};
  final Set<int> _hoveredPointers = <int>{};
  final List<_QueuedCanvasEvent> _eventQueue = <_QueuedCanvasEvent>[];

  bool _dispatching = false;
  int _gestureGeneration = 0;

  @override
  void didUpdateWidget(covariant NativeDocumentCanvasPointer oldWidget) {
    super.didUpdateWidget(oldWidget);
    final ownerChanged =
        oldWidget.documentIdentity != widget.documentIdentity ||
        oldWidget.elementId != widget.elementId;
    if (ownerChanged) {
      _cancelActivePointers();
      _hoveredPointers.clear();
      // Drop arena entries owned by the previous document. A touch-action
      // change applies only to the next pointer, as in a browser.
      _gestureGeneration++;
    }
  }

  @override
  void dispose() {
    _cancelActivePointers();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    RenderL10n.watch(context);
    return MouseRegion(
      onEnter: _handlePointerEnter,
      onExit: _handlePointerExit,
      child: Listener(
        key: _surfaceRenderKey,
        behavior: HitTestBehavior.opaque,
        onPointerDown: _handlePointerDown,
        onPointerMove: _handlePointerMove,
        onPointerUp: _handlePointerUp,
        onPointerCancel: _handlePointerCancel,
        onPointerHover: _handlePointerHover,
        child: RawGestureDetector(
          key: ValueKey<int>(_gestureGeneration),
          behavior: HitTestBehavior.opaque,
          gestures: {
            _CanvasPointerGestureRecognizer:
                GestureRecognizerFactoryWithHandlers<
                  _CanvasPointerGestureRecognizer
                >(
                  () => _CanvasPointerGestureRecognizer(
                    debugOwner: this,
                    touchActionNone: widget.touchActionNone,
                    onSequenceEnd: _handleGestureSequenceEnd,
                    onArenaLost: _handleGestureArenaLost,
                  ),
                  (_CanvasPointerGestureRecognizer instance) {
                    instance
                      ..touchActionNone = widget.touchActionNone
                      ..onSequenceEnd = _handleGestureSequenceEnd
                      ..onArenaLost = _handleGestureArenaLost;
                  },
                ),
          },
          child: widget.child,
        ),
      ),
    );
  }

  void _handlePointerDown(PointerDownEvent event) {
    final existing = _pointers.remove(event.pointer);
    if (existing != null) {
      _sendCancel(existing, existing.lastEvent);
    }

    final pointerType = _pointerType(event.kind);
    final isPrimary =
        pointerType == 'mouse' ||
        !_pointers.values.any(
          (active) => active.isDown && active.pointerType == pointerType,
        );
    final state = _CanvasPointerState(
      pointerId: event.pointer,
      pointerType: pointerType,
      isPrimary: isPrimary,
      button: _buttonForDown(event.buttons),
      onEvent: widget.onEvent,
      lastEvent: event,
    );
    _pointers[event.pointer] = state;
    _enqueuePointerEvent('pointerdown', event, state);
  }

  void _handlePointerMove(PointerMoveEvent event) {
    final state = _pointers[event.pointer];
    if (state == null || !state.isDown || state.cancelSent || state.upSent) {
      return;
    }
    state.movedPastSlop =
        state.movedPastSlop ||
        (event.position - state.downPosition).distance > kTouchSlop;
    _enqueuePointerEvent('pointermove', event, state, coalesce: true);
  }

  void _handlePointerUp(PointerUpEvent event) {
    final state = _pointers[event.pointer];
    if (state == null || state.cancelSent || state.upSent) return;

    state.lastEvent = event;
    state.isDown = false;
    state.upSent = true;
    final data = _pointerEventData('pointerup', event, state);
    _enqueue('pointerup', data, event.pointer, state.onEvent);

    if (state.gestureEnded) {
      _finishPointerAfterUp(state);
    } else {
      // Pointer routing and hit-test callbacks can run in either order. The
      // recognizer normally reports its result in this dispatch; this cleanup
      // prevents a lost route from retaining a completed stream indefinitely.
      scheduleMicrotask(() {
        if (identical(_pointers[event.pointer], state) && !state.gestureEnded) {
          state.gestureEnded = true;
          _finishPointerAfterUp(state);
        }
      });
    }
  }

  void _handlePointerCancel(PointerCancelEvent event) {
    final state = _pointers[event.pointer];
    if (state == null || state.cancelSent || state.upSent) return;
    _sendCancel(state, event);
  }

  void _handlePointerEnter(PointerEnterEvent event) {
    final pointerType = _pointerType(event.kind);
    if (pointerType == 'touch' || !_hoveredPointers.add(event.pointer)) return;
    _enqueuePointerEvent('pointerover', event, _pointers[event.pointer]);
    _enqueuePointerEvent('pointerenter', event, _pointers[event.pointer]);
  }

  void _handlePointerExit(PointerExitEvent event) {
    if (!_hoveredPointers.remove(event.pointer)) return;
    _enqueuePointerEvent('pointerout', event, _pointers[event.pointer]);
    _enqueuePointerEvent('pointerleave', event, _pointers[event.pointer]);
  }

  void _handlePointerHover(PointerHoverEvent event) {
    _enqueuePointerEvent(
      'pointermove',
      event,
      _pointers[event.pointer],
      coalesce: true,
    );
  }

  void _handleGestureSequenceEnd(int pointer, bool tapAccepted) {
    final state = _pointers[pointer];
    if (state == null || state.cancelSent) return;
    state.gestureEnded = true;
    state.tapAccepted = tapAccepted;
    if (state.upSent) _finishPointerAfterUp(state);
  }

  void _handleGestureArenaLost(int pointer, {required bool sequenceEnded}) {
    final state = _pointers[pointer];
    if (state == null || state.cancelSent) return;
    if (sequenceEnded || state.upSent) {
      state.gestureEnded = true;
      state.gestureLost = true;
      if (state.upSent) _finishPointerAfterUp(state);
      return;
    }
    _sendCancel(state, state.lastEvent);
  }

  void _finishPointerAfterUp(_CanvasPointerState state) {
    if (!identical(_pointers[state.pointerId], state)) return;
    final isPrimaryMouseClick =
        state.pointerType == 'mouse' && state.button == 0 && !state.gestureLost;
    if (!state.clickSent && (state.tapAccepted || isPrimaryMouseClick)) {
      final event = state.lastEvent;
      final coordinates = _coordinatesFor(
        event.position,
        state.lastCoordinates,
      );
      if (state.tapAccepted || coordinates.isInside) {
        state.clickSent = true;
        final clickData = _pointerEventData('click', event, state);
        final onCompleted = state.pointerType == 'touch' && state.isPrimary
            ? widget.onTouchClickQueued?.call(clickData)
            : null;
        _enqueue(
          'click',
          clickData,
          state.pointerId,
          state.onEvent,
          onCompleted: onCompleted,
        );
      }
    }
    _pointers.remove(state.pointerId);
  }

  void _cancelActivePointers() {
    for (final state in _pointers.values.toList(growable: false)) {
      if (state.isDown && !state.upSent && !state.cancelSent) {
        _sendCancel(state, state.lastEvent);
      }
    }
  }

  void _sendCancel(_CanvasPointerState state, PointerEvent event) {
    if (state.cancelSent || state.upSent) return;
    state.cancelSent = true;
    _pointers.remove(state.pointerId);
    _eventQueue.removeWhere(
      (queued) =>
          queued.pointerId == state.pointerId && queued.type == 'pointermove',
    );
    _enqueue(
      'pointercancel',
      _pointerEventData('pointercancel', event, state),
      state.pointerId,
      state.onEvent,
    );
  }

  void _enqueuePointerEvent(
    String type,
    PointerEvent event,
    _CanvasPointerState? state, {
    bool coalesce = false,
  }) {
    final callback = state?.onEvent ?? widget.onEvent;
    final data = _pointerEventData(type, event, state);
    _enqueue(type, data, event.pointer, callback, coalesce: coalesce);
  }

  Map<String, dynamic> _pointerEventData(
    String type,
    PointerEvent event,
    _CanvasPointerState? state,
  ) {
    final phase = _eventPhase(type);
    final coordinates = _coordinatesFor(event.position, state?.lastCoordinates);
    if (state != null) {
      state
        ..lastEvent = event
        ..lastCoordinates = coordinates;
    }

    final pointerType = state?.pointerType ?? _pointerType(event.kind);
    var buttons = _webButtons(event.buttons);
    if (phase == _CanvasPointerPhase.cancel) {
      buttons = 0;
    } else if (phase == _CanvasPointerPhase.down &&
        pointerType == 'touch' &&
        buttons == 0) {
      buttons = 1;
    } else if (phase == _CanvasPointerPhase.move &&
        state?.isDown == true &&
        pointerType == 'touch' &&
        buttons == 0) {
      buttons = 1;
    }

    final button = switch (phase) {
      _CanvasPointerPhase.down =>
        state?.button ?? _buttonForDown(event.buttons),
      _CanvasPointerPhase.up => state?.button ?? 0,
      _CanvasPointerPhase.click => state?.button ?? 0,
      _ => -1,
    };
    final active =
        phase == _CanvasPointerPhase.down ||
        (phase == _CanvasPointerPhase.move &&
            (state?.isDown == true || buttons != 0));
    final pressure = _normalizedPressure(event, active: active);

    return <String, dynamic>{
      'pointerId': _documentPointerId(event.pointer, pointerType),
      'pointerType': pointerType,
      'isPrimary': state?.isPrimary ?? pointerType == 'mouse',
      'clientX': coordinates.client.dx,
      'clientY': coordinates.client.dy,
      'movementX': event.delta.dx,
      'movementY': event.delta.dy,
      'offsetX': coordinates.local.dx,
      'offsetY': coordinates.local.dy,
      'button': button,
      'buttons': buttons,
      'pressure': pressure,
      'tangentialPressure': 0.0,
      'width': _contactDimension(event.radiusMajor),
      'height': _contactDimension(event.radiusMinor),
      'geometry': Map<String, double>.from(coordinates.geometry),
      'metaKey': HardwareKeyboard.instance.isMetaPressed,
      'ctrlKey': HardwareKeyboard.instance.isControlPressed,
      'shiftKey': HardwareKeyboard.instance.isShiftPressed,
      'altKey': HardwareKeyboard.instance.isAltPressed,
    };
  }

  _CanvasCoordinates _coordinatesFor(
    Offset globalPosition,
    _CanvasCoordinates? fallback,
  ) {
    try {
      final renderObject = _surfaceRenderKey.currentContext?.findRenderObject();
      if (renderObject is RenderBox &&
          renderObject.attached &&
          renderObject.hasSize) {
        final local = renderObject.globalToLocal(globalPosition);
        final viewportOrigin = _currentViewportOrigin();
        final bounds = _globalBounds(renderObject);
        final geometry = <String, double>{
          'left': bounds.left - viewportOrigin.dx,
          'top': bounds.top - viewportOrigin.dy,
          'width': bounds.width,
          'height': bounds.height,
        };
        return _CanvasCoordinates(
          local: local,
          client: globalPosition - viewportOrigin,
          geometry: geometry,
          size: renderObject.size,
        );
      }
    } catch (_) {
      // A terminal event can arrive while the keyed surface is being removed.
    }
    final origin = _currentViewportOrigin();
    return fallback == null
        ? _CanvasCoordinates(
            local: globalPosition,
            client: globalPosition - origin,
            geometry: const <String, double>{
              'left': 0,
              'top': 0,
              'width': 0,
              'height': 0,
            },
            size: Size.zero,
          )
        : _CanvasCoordinates(
            local: fallback.local,
            client: globalPosition - origin,
            geometry: fallback.geometry,
            size: fallback.size,
          );
  }

  Rect _globalBounds(RenderBox box) {
    final corners = <Offset>[
      box.localToGlobal(Offset.zero),
      box.localToGlobal(Offset(box.size.width, 0)),
      box.localToGlobal(Offset(0, box.size.height)),
      box.localToGlobal(Offset(box.size.width, box.size.height)),
    ];
    var left = corners.first.dx;
    var right = corners.first.dx;
    var top = corners.first.dy;
    var bottom = corners.first.dy;
    for (final corner in corners.skip(1)) {
      left = math.min(left, corner.dx);
      right = math.max(right, corner.dx);
      top = math.min(top, corner.dy);
      bottom = math.max(bottom, corner.dy);
    }
    return Rect.fromLTRB(left, top, right, bottom);
  }

  Offset _currentViewportOrigin() {
    try {
      final origin = widget.viewportOrigin?.call() ?? Offset.zero;
      if (!origin.dx.isFinite || !origin.dy.isFinite) return Offset.zero;
      return origin;
    } catch (_) {
      return Offset.zero;
    }
  }

  void _enqueue(
    String type,
    Map<String, dynamic> data,
    int pointerId,
    NativeCanvasPointerEventCallback callback, {
    bool coalesce = false,
    VoidCallback? onCompleted,
  }) {
    final queued = _QueuedCanvasEvent(
      type: type,
      data: data,
      pointerId: pointerId,
      callback: callback,
      onCompleted: onCompleted,
    );
    if (coalesce) {
      for (var index = _eventQueue.length - 1; index >= 0; index--) {
        final pending = _eventQueue[index];
        if (pending.pointerId != pointerId) continue;
        if (pending.type == 'pointermove') {
          _eventQueue[index] = queued;
          return;
        }
        if (_isPointerOrderBarrier(pending.type)) break;
      }
    }
    _eventQueue.add(queued);
    _startDispatch();
  }

  bool _isPointerOrderBarrier(String type) => type != 'pointermove';

  void _startDispatch() {
    if (_dispatching) return;
    _dispatching = true;
    unawaited(_dispatchQueuedEvents());
  }

  Future<void> _dispatchQueuedEvents() async {
    try {
      while (_eventQueue.isNotEmpty) {
        final queued = _eventQueue.removeAt(0);
        try {
          await queued.callback(queued.type, queued.data);
        } catch (error, stackTrace) {
          FlutterError.reportError(
            FlutterErrorDetails(
              exception: error,
              stack: stackTrace,
              library: tr("document canvas pointer surface"),
              context: ErrorDescription(
                tr("while dispatching {0} for canvas pointer {1}", [
                  queued.type,
                  queued.pointerId,
                ]),
              ),
            ),
          );
        } finally {
          try {
            queued.onCompleted?.call();
          } catch (error, stackTrace) {
            FlutterError.reportError(
              FlutterErrorDetails(
                exception: error,
                stack: stackTrace,
                library: tr("document canvas pointer surface"),
                context: ErrorDescription(
                  tr("while completing {0} for canvas pointer {1}", [
                    queued.type,
                    queued.pointerId,
                  ]),
                ),
              ),
            );
          }
        }
      }
    } finally {
      _dispatching = false;
      if (_eventQueue.isNotEmpty) _startDispatch();
    }
  }
}

class _CanvasPointerState {
  _CanvasPointerState({
    required this.pointerId,
    required this.pointerType,
    required this.isPrimary,
    required this.button,
    required this.onEvent,
    required this.lastEvent,
  }) : downPosition = lastEvent.position;

  final int pointerId;
  final String pointerType;
  final bool isPrimary;
  final int button;
  final Offset downPosition;
  final NativeCanvasPointerEventCallback onEvent;

  PointerEvent lastEvent;
  _CanvasCoordinates? lastCoordinates;
  bool isDown = true;
  bool movedPastSlop = false;
  bool upSent = false;
  bool cancelSent = false;
  bool gestureEnded = false;
  bool gestureLost = false;
  bool tapAccepted = false;
  bool clickSent = false;
}

class _CanvasCoordinates {
  const _CanvasCoordinates({
    required this.local,
    required this.client,
    required this.geometry,
    required this.size,
  });

  final Offset local;
  final Offset client;
  final Map<String, double> geometry;
  final Size size;

  bool get isInside =>
      local.dx >= 0 &&
      local.dy >= 0 &&
      local.dx <= size.width &&
      local.dy <= size.height;
}

class _QueuedCanvasEvent {
  const _QueuedCanvasEvent({
    required this.type,
    required this.data,
    required this.pointerId,
    required this.callback,
    this.onCompleted,
  });

  final String type;
  final Map<String, dynamic> data;
  final int pointerId;
  final NativeCanvasPointerEventCallback callback;
  final VoidCallback? onCompleted;
}

enum _CanvasPointerPhase { down, move, up, cancel, click, other }

_CanvasPointerPhase _eventPhase(String type) => switch (type) {
  'pointerdown' => _CanvasPointerPhase.down,
  'pointermove' => _CanvasPointerPhase.move,
  'pointerup' => _CanvasPointerPhase.up,
  'pointercancel' => _CanvasPointerPhase.cancel,
  'click' => _CanvasPointerPhase.click,
  _ => _CanvasPointerPhase.other,
};

String _pointerType(PointerDeviceKind kind) => switch (kind) {
  PointerDeviceKind.touch => 'touch',
  PointerDeviceKind.stylus || PointerDeviceKind.invertedStylus => 'pen',
  PointerDeviceKind.mouse || PointerDeviceKind.trackpad => 'mouse',
  _ => '',
};

int _buttonForDown(int flutterButtons) {
  if (flutterButtons & kPrimaryMouseButton != 0) return 0;
  if (flutterButtons & kSecondaryMouseButton != 0) return 2;
  if (flutterButtons & kMiddleMouseButton != 0) return 1;
  if (flutterButtons & kBackMouseButton != 0) return 3;
  if (flutterButtons & kForwardMouseButton != 0) return 4;
  return 0;
}

int _documentPointerId(int flutterPointerId, String pointerType) =>
    pointerType == 'mouse' ? 1 : flutterPointerId + 2;

int _webButtons(int flutterButtons) {
  var buttons = 0;
  if (flutterButtons & kPrimaryMouseButton != 0) buttons |= 1;
  if (flutterButtons & kSecondaryMouseButton != 0) buttons |= 2;
  if (flutterButtons & kMiddleMouseButton != 0) buttons |= 4;
  if (flutterButtons & kBackMouseButton != 0) buttons |= 8;
  if (flutterButtons & kForwardMouseButton != 0) buttons |= 16;
  return buttons;
}

double _normalizedPressure(PointerEvent event, {required bool active}) {
  if (!active) return 0;
  if (event.kind == PointerDeviceKind.mouse ||
      event.kind == PointerDeviceKind.trackpad) {
    return 0.5;
  }
  final range = event.pressureMax - event.pressureMin;
  if (event.pressure.isFinite && range.isFinite && range > 0) {
    final normalized = (event.pressure - event.pressureMin) / range;
    if (normalized.isFinite && normalized > 0 && normalized <= 1) {
      return normalized;
    }
  }
  return 0.5;
}

double _contactDimension(double radius) =>
    radius.isFinite && radius > 0 ? radius * 2 : 1;

typedef _CanvasGestureEndCallback =
    void Function(int pointer, bool tapAccepted);
typedef _CanvasGestureLostCallback =
    void Function(int pointer, {required bool sequenceEnded});

class _CanvasPointerGestureRecognizer extends OneSequenceGestureRecognizer {
  _CanvasPointerGestureRecognizer({
    required Object debugOwner,
    required this.touchActionNone,
    required this.onSequenceEnd,
    required this.onArenaLost,
  }) : super(debugOwner: debugOwner);

  bool touchActionNone;
  _CanvasGestureEndCallback onSequenceEnd;
  _CanvasGestureLostCallback onArenaLost;
  final Map<int, _CanvasGestureSequence> _sequences =
      <int, _CanvasGestureSequence>{};

  @override
  String get debugDescription => tr("native canvas pointer");

  @override
  void addAllowedPointer(PointerDownEvent event) {
    final sequence = _CanvasGestureSequence(
      kind: event.kind,
      startPosition: event.position,
    );
    _sequences[event.pointer] = sequence;
    startTrackingPointer(event.pointer, event.transform);
    if (touchActionNone && _isDirectPointer(event.kind)) {
      resolvePointer(event.pointer, GestureDisposition.accepted);
    }
  }

  @override
  void handleEvent(PointerEvent event) {
    final sequence = _sequences[event.pointer];
    if (sequence == null || sequence.lost || sequence.endNotified) return;

    if (event is PointerMoveEvent) {
      if (!sequence.moved &&
          (event.position - sequence.startPosition).distance > kTouchSlop) {
        sequence.moved = true;
      }
      return;
    }

    if (event is PointerCancelEvent) {
      sequence.ended = true;
      if (!sequence.won) {
        resolvePointer(event.pointer, GestureDisposition.rejected);
      }
      _notifySequenceEnd(event.pointer, sequence, tapAccepted: false);
      _stopTracking(event.pointer, sequence);
      return;
    }

    if (event is PointerUpEvent) {
      sequence.ended = true;
      final canClick = !_isDirectPointer(sequence.kind) || !sequence.moved;
      if (canClick && !sequence.won && !sequence.lost) {
        resolvePointer(event.pointer, GestureDisposition.accepted);
      } else if (!canClick && !sequence.won && !sequence.lost) {
        resolvePointer(event.pointer, GestureDisposition.rejected);
      }
      _notifySequenceEnd(
        event.pointer,
        sequence,
        tapAccepted: canClick && sequence.won && !sequence.lost,
      );
      _stopTracking(event.pointer, sequence);
    }
  }

  @override
  void acceptGesture(int pointer) {
    final sequence = _sequences[pointer];
    if (sequence != null) sequence.won = true;
  }

  @override
  void rejectGesture(int pointer) {
    final sequence = _sequences[pointer];
    if (sequence == null || sequence.lost) return;
    sequence.lost = true;
    if (sequence.ended) {
      _notifySequenceEnd(pointer, sequence, tapAccepted: false);
    } else {
      scheduleMicrotask(() {
        onArenaLost(pointer, sequenceEnded: false);
      });
    }
    _stopTracking(pointer, sequence);
  }

  @override
  void didStopTrackingLastPointer(int pointer) {}

  @override
  void dispose() {
    for (final entry in _sequences.entries.toList(growable: false)) {
      final pointer = entry.key;
      final sequence = entry.value;
      if (!sequence.lost && !sequence.won) {
        resolvePointer(pointer, GestureDisposition.rejected);
      }
      _stopTracking(pointer, sequence);
    }
    super.dispose();
  }

  void _notifySequenceEnd(
    int pointer,
    _CanvasGestureSequence sequence, {
    required bool tapAccepted,
  }) {
    if (sequence.endNotified) return;
    sequence.endNotified = true;
    onSequenceEnd(pointer, tapAccepted);
  }

  void _stopTracking(int pointer, _CanvasGestureSequence sequence) {
    _sequences.remove(pointer);
    if (!sequence.stopped) {
      sequence.stopped = true;
      stopTrackingPointer(pointer);
    }
  }
}

class _CanvasGestureSequence {
  _CanvasGestureSequence({required this.kind, required this.startPosition});

  final PointerDeviceKind kind;
  final Offset startPosition;
  bool moved = false;
  bool won = false;
  bool lost = false;
  bool ended = false;
  bool endNotified = false;
  bool stopped = false;
}

bool _isDirectPointer(PointerDeviceKind kind) =>
    kind == PointerDeviceKind.touch ||
    kind == PointerDeviceKind.stylus ||
    kind == PointerDeviceKind.invertedStylus;
