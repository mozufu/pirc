import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

import 'document_absolute_position.dart';
import 'document_scroll_commands.dart';
import 'document_scroll_anchor_state.dart';
import 'html_document_box.dart';

/// The CSS overflow behavior for one physical axis.
enum NativeDocumentOverflow { visible, hidden, clip, auto, scroll }

/// Whether [object] is a native document scroll viewport clipping [globalPoint].
///
/// This lets other native inline-overflow paths preserve nested CSS scrollport
/// clips when they walk render-object descendants for hit testing.
bool nativeDocumentScrollClipsGlobalPoint(
  RenderObject object,
  Offset globalPoint,
) {
  if (object is! _RenderNativeDocumentElementScrollViewportRender ||
      !object.attached ||
      !object.hasSize) {
    return false;
  }
  final local = object.globalToLocal(globalPoint);
  return (object._clipsX && (local.dx < 0 || local.dx > object.size.width)) ||
      (object._clipsY && (local.dy < 0 || local.dy > object.size.height));
}

/// The translation a document scroll viewport applies to its descendants.
/// Offset coordinates use the unscrolled layout; bounding rectangles retain
/// this paint translation. Other render objects do not add scroll compensation.
Offset nativeDocumentScrollTranslation(RenderObject object) =>
    object is _RenderNativeDocumentElementScrollViewportRender
    ? Offset(object._horizontalOffset.pixels, object._verticalOffset.pixels)
    : Offset.zero;

/// Identity of a real element scroll viewport, before mapping it to a document.
String? nativeDocumentScrollOwnerId(RenderObject object) =>
    object is _RenderNativeDocumentElementScrollViewportRender
    ? object._attachment.id
    : null;

/// The actual padding-box scrollport. Clip-only/visible overflow does not
/// create a scrolling box, while auto/hidden boxes count even at zero range.
Size? nativeDocumentRevealScrollport(RenderObject object) =>
    object is _RenderNativeDocumentElementScrollViewportRender &&
        object.attached &&
        object.hasSize &&
        (object._scrollsX || object._scrollsY)
    ? object.size
    : null;

/// Owns native scroll offsets for elements in one fetched document.
///
/// A controller may be shared by the layout bridge and script host for a view.
/// Offsets survive ordinary element detach/reattach while the document owner
/// remains the same. [beginDocument] retires all current attachments and starts
/// a fresh offset/event scope.
class NativeDocumentElementScrollController extends ChangeNotifier {
  NativeDocumentElementScrollController({Object? documentOwner})
    : _documentOwner = documentOwner ?? Object();

  static const int maximumPendingScrollEvents = 8192;
  static const Duration smoothScrollDuration = Duration(milliseconds: 250);

  Object _documentOwner;
  bool _disposed = false;
  bool _notificationScheduled = false;
  bool _coalescingClearScheduled = false;
  int _coalescingGeneration = 0;
  final Map<String, int> _coalescedSequences = <String, int>{};
  final Map<String, Set<_NativeDocumentScrollAttachment>> _attachments = {};
  final Map<String, Offset> _savedOffsets = {};
  final List<_NativeDocumentScrollEvent> _events =
      <_NativeDocumentScrollEvent>[];
  int _nextSequence = 1;
  int droppedScrollEventCount = 0;

  Object? _anchorHost;
  Map<String, NativeDocumentScrollAnchorNode> Function()? _anchorNodes;
  NativeDocumentScrollAnchorCapture? _anchorCapture;
  VoidCallback? _requestAnchorCheck;
  void Function(Set<String>, Offset, bool)? _anchorScrollChanged;
  final _anchorStates = <String, NativeDocumentScrollAnchorState>{};
  final _pendingAnchoring = <_NativeDocumentScrollAttachment>{};
  final _correctingAnchors = <_NativeDocumentScrollAttachment>{};
  List<({_NativeDocumentScrollAttachment attachment, double target})>
  _anchorPlan = [];
  bool get anchoringSettled => _pendingAnchoring.isEmpty;

  void bindAnchoring(
    Object host, {
    required Map<String, NativeDocumentScrollAnchorNode> Function() nodes,
    required NativeDocumentScrollAnchorCapture capture,
    required VoidCallback requestCheck,
    required void Function(Set<String>, Offset, bool) onScroll,
  }) {
    if (_disposed) return;
    if (!identical(_anchorHost, host)) _anchorStates.clear();
    _anchorHost = host;
    _anchorNodes = nodes;
    _anchorCapture = capture;
    _requestAnchorCheck = requestCheck;
    _anchorScrollChanged = onScroll;
  }

  void unbindAnchoring(Object host) {
    if (!identical(_anchorHost, host)) return;
    _anchorHost = null;
    _anchorNodes = null;
    _anchorCapture = null;
    _requestAnchorCheck = null;
    _anchorScrollChanged = null;
    _anchorStates.clear();
    _pendingAnchoring.clear();
    _anchorPlan = [];
  }

  /// All owned native scroll surfaces, including visible/zero-range wrappers.
  /// Geometry proof must account for them before ignoring a fixed zero range.
  Map<String, RenderBox> get scrollGeometrySurfaces => {
    if (!_disposed)
      for (final a in _allAttachments)
        if (!a.retired &&
            identical(a.documentOwner, _documentOwner) &&
            _activeAttachments(a.id).length == 1 &&
            a.viewportRenderObject?.attached == true &&
            a.viewportRenderObject!.hasSize)
          a.id: a.viewportRenderObject!,
  };

  Map<String, NativeDocumentScrollAnchorPort> get anchorScrollports => {
    if (!_disposed)
      for (final a in _allAttachments)
        if (!a.retired &&
            identical(a.documentOwner, _documentOwner) &&
            _activeAttachments(a.id).length == 1 &&
            a.viewportRenderObject?.attached == true &&
            a.viewportRenderObject!.hasSize &&
            (a.overflowX != NativeDocumentOverflow.visible ||
                a.overflowY != NativeDocumentOverflow.visible))
          a.id: (
            surface: a.viewportRenderObject!,
            clipX: a.overflowX != NativeDocumentOverflow.visible,
            clipY: a.overflowY != NativeDocumentOverflow.visible,
          ),
  };
  void _scheduleAnchoring(_NativeDocumentScrollAttachment a) {
    if (_anchorHost == null ||
        a.retired ||
        !_isProgrammaticallyScrollable(a.overflowY) ||
        _anchorNodes?.call()[a.id] == null) {
      return;
    }
    _pendingAnchoring.add(a);
    _requestAnchorCheck?.call();
  }

  bool prepareAnchoring() {
    _anchorPlan = [];
    final all =
        _anchorNodes?.call() ??
        const <String, NativeDocumentScrollAnchorNode>{};
    _pendingAnchoring.removeWhere(
      (a) =>
          a.retired ||
          !all.containsKey(a.id) ||
          _activeAttachments(a.id).length != 1 ||
          !_isProgrammaticallyScrollable(a.overflowY),
    );
    if (all.isEmpty) {
      _anchorStates.clear();
      return true;
    }
    final captures =
        <
          ({
            _NativeDocumentScrollAttachment attachment,
            Map<String, NativeDocumentScrollAnchorNode> nodes,
            NativeDocumentScrollAnchorFrame frame,
            ScrollPosition position,
            double left,
          })
        >[];
    for (final a in _allAttachments) {
      if (a.retired ||
          !identical(a.documentOwner, _documentOwner) ||
          !all.containsKey(a.id) ||
          !_isProgrammaticallyScrollable(a.overflowY) ||
          _activeAttachments(a.id).length != 1) {
        continue;
      }
      if (!all[a.id]!.rendered) {
        _anchorStates.remove(a.id);
        _pendingAnchoring.remove(a);
        continue;
      }
      final port = a.viewportRenderObject;
      if (!a.hasMetrics ||
          !a.hasLayoutRevision ||
          a.layoutRevision != a.revision ||
          port == null ||
          !port.attached ||
          !port.hasSize ||
          a.verticalController.positions.length != 1) {
        return false;
      }
      final position = a.verticalController.position;
      if (!position.hasContentDimensions || !position.hasViewportDimension) {
        return false;
      }
      final nodes = nativeDocumentScrollAnchorScope(all, a.id);
      final left = _currentPixels(a.horizontalController, a.lastLeft);
      final frame = _anchorCapture?.call(
        {
          for (final n in nodes.values)
            if (n.id != a.id && !n.excluded) n.id,
        },
        port,
        Offset(left, position.pixels),
      );
      if (frame == null) return false;
      captures.add((
        attachment: a,
        nodes: nodes,
        frame: frame,
        position: position,
        left: left,
      ));
    }
    // All measurements must be available before any state is committed. The
    // host then computes the root plan before applying any layer's correction.
    for (final c in captures) {
      final state = _anchorStates.putIfAbsent(
        c.attachment.id,
        NativeDocumentScrollAnchorState.new,
      );
      final target = state.adjust(
        nodes: c.nodes,
        boxes: c.frame.boxes,
        clips: c.frame.clips,
        layoutBoxes: c.frame.layoutBoxes,
        viewport: Size(
          c.attachment.viewportRenderObject!.size.width,
          c.position.viewportDimension,
        ),
        pixels: c.position.pixels,
        min: c.position.minScrollExtent,
        max: c.position.maxScrollExtent,
        left: c.left,
      );
      _anchorPlan.add((attachment: c.attachment, target: target));
    }
    return true;
  }

  bool applyAnchoring() {
    var changed = false;
    for (final plan in _anchorPlan) {
      final a = plan.attachment;
      if (a.retired ||
          _activeAttachments(a.id).length != 1 ||
          a.verticalController.positions.length != 1) {
        continue;
      }
      final scroll = a.verticalController;
      if ((scroll.offset - plan.target).abs() > .0000001) {
        changed = true;
        _correctingAnchors.add(a);
        try {
          scroll.correctAnchorOffset(plan.target);
        } finally {
          _correctingAnchors.remove(a);
        }
        _scheduleAnchoring(a);
      } else {
        _pendingAnchoring.remove(a);
      }
    }
    _anchorPlan = [];
    return changed;
  }

  void _anchorOffsetChanged(
    _NativeDocumentScrollAttachment a,
    Offset before,
    Offset after,
  ) {
    if (_anchorHost == null) return;
    final all =
        _anchorNodes?.call() ??
        const <String, NativeDocumentScrollAnchorNode>{};
    final descendants = <String>{};
    for (final n in all.values) {
      if (n.parent == a.id || descendants.contains(n.parent)) {
        descendants.add(n.id);
      }
    }
    final correction = _correctingAnchors.contains(a);
    if (!correction) {
      _anchorStates[a.id]?.didScroll(top: after.dy, left: after.dx);
    }
    final shift = before - after;
    for (final entry in _anchorStates.entries) {
      if (entry.key == a.id) continue;
      String? ancestor = all[a.id]?.parent;
      final seen = <String>{};
      while (ancestor != null && seen.add(ancestor)) {
        if (ancestor == entry.key) {
          entry.value.shiftDescendants(
            descendants,
            shift,
            reselect: !correction,
          );
          break;
        }
        ancestor = all[ancestor]?.parent;
      }
    }
    _anchorScrollChanged?.call(descendants, shift, !correction);
    _scheduleAnchoring(a);
  }

  /// Starts a new document lifetime. Old render objects can detach later; their
  /// ScrollControllers are kept alive until their Scrollables have detached.
  void beginDocument(Object owner) {
    if (_disposed || identical(owner, _documentOwner)) return;
    _documentOwner = owner;
    _savedOffsets.clear();
    _anchorStates.clear();
    _pendingAnchoring.clear();
    _anchorPlan = [];
    _events.clear();
    _coalescedSequences.clear();
    _coalescingGeneration++;
    _coalescingClearScheduled = false;
    for (final attachment in _allAttachments) {
      attachment.retired = true;
      attachment.hasMetrics = false;
      _scheduleRetirement(attachment);
    }
    _scheduleNotification();
  }

  /// Discards saved offsets for elements that have been removed from the DOM.
  ///
  /// An empty set is ignored because some callers only have IDs for script
  /// observed elements, not the native renderer's generated fallback IDs.
  void retainIds(Set<String> ids) {
    if (_disposed || ids.isEmpty) return;
    _savedOffsets.removeWhere((id, _) => !ids.contains(id));
    _anchorStates.removeWhere((id, _) => !ids.contains(id));
    _pendingAnchoring.removeWhere((a) => !ids.contains(a.id));
  }

  /// Latest native scroll metrics for an unambiguous, laid-out element.
  ///
  /// Width and height are the actual scrollable content extents, including
  /// padding. They are not estimated from CSS values.
  Map<String, double>? metricsFor(String id) {
    if (_disposed) return null;
    final matches = _activeAttachments(id);
    if (matches.length != 1) return null;
    final attachment = matches.single;
    if (!attachment.hasMetrics ||
        !attachment.hasLayoutRevision ||
        attachment.revision != attachment.layoutRevision) {
      return null;
    }
    final left = _isProgrammaticallyScrollable(attachment.overflowX)
        ? _currentPixels(attachment.horizontalController, attachment.lastLeft)
        : 0.0;
    final top = _isProgrammaticallyScrollable(attachment.overflowY)
        ? _currentPixels(attachment.verticalController, attachment.lastTop)
        : 0.0;
    final width = attachment.contentWidth;
    final height = attachment.contentHeight;
    if (width == null || height == null) {
      return null;
    }
    return <String, double>{
      'left': left,
      'top': top,
      'width': width,
      'height': height,
    };
  }

  /// Native activity distinguishes a completed animation from user interruption.
  bool? isScrollingFor(String id) {
    if (metricsFor(id) == null) return null;
    final attachment = _activeAttachments(id).single;
    return [attachment.horizontalController, attachment.verticalController].any(
      (controller) => controller.positions.any(
        (position) => position.isScrollingNotifier.value,
      ),
    );
  }

  /// Programmatic limits from the actual laid-out native axes, including
  /// disabled/clip axes whose only valid programmatic position is zero.
  Map<String, double>? scrollRangeFor(String id) {
    if (metricsFor(id) == null) return null;
    final attachment = _activeAttachments(id).single;
    Map<String, double>? axis(ScrollController controller, bool enabled) {
      if (!enabled) return {'min': 0, 'max': 0};
      if (controller.positions.length != 1 ||
          !controller.position.hasContentDimensions) {
        return null;
      }
      return {
        'min': controller.position.minScrollExtent,
        'max': controller.position.maxScrollExtent,
      };
    }

    final x = axis(
      attachment.horizontalController,
      _isProgrammaticallyScrollable(attachment.overflowX),
    );
    final y = axis(
      attachment.verticalController,
      _isProgrammaticallyScrollable(attachment.overflowY),
    );
    if (x == null || y == null) return null;
    return {
      'minLeft': x['min']!,
      'maxLeft': x['max']!,
      'minTop': y['min']!,
      'maxTop': y['max']!,
    };
  }

  /// Events waiting to be included in an accepted native layout packet.
  ///
  /// A target contributes at most one event in each frame. [sequence] is
  /// assigned at its first actual offset change, preserving nested event order.
  List<Map<String, dynamic>> get pendingScrollEvents =>
      List<Map<String, dynamic>>.unmodifiable(
        _events.map(
          (event) => <String, dynamic>{
            'id': event.id,
            'sequence': event.sequence,
          },
        ),
      );

  /// Removes events included in an accepted packet through [throughSequence].
  void acknowledgeScrollEvents(int throughSequence) {
    if (_disposed || _events.isEmpty) return;
    for (final event in _events) {
      if (event.sequence <= throughSequence &&
          _coalescedSequences[event.id] == event.sequence) {
        _coalescedSequences.remove(event.id);
      }
    }
    _events.removeWhere((event) => event.sequence <= throughSequence);
  }

  /// Executes each command in order against current native pixels. Omitted
  /// axes stay at their current positions and cancel earlier animation too.
  void applyActions(List<Map<String, dynamic>> actions) {
    if (_disposed || actions.isEmpty) return;
    for (final action in actions) {
      final rawId = action['id'];
      if (rawId is! String || rawId.isEmpty) continue;
      final matches = _activeAttachments(rawId);
      if (matches.length != 1) continue;
      final a = matches.single;
      if (a.retired) continue;
      final operation = switch (action['op']) {
        'by' || 'scrollBy' => 'by',
        'to' || 'scrollTo' => 'to',
        _ => null,
      };
      if (operation == null) continue;
      final behavior = action['behavior'] as String? ?? 'auto';
      if (_isProgrammaticallyScrollable(a.overflowX)) {
        applyNativeDocumentScrollAxis(
          a.horizontalController,
          _number(action['left']),
          relative: operation == 'by',
          behavior: behavior,
          cssBehavior: a.scrollBehavior,
        );
      }
      if (_isProgrammaticallyScrollable(a.overflowY)) {
        applyNativeDocumentScrollAxis(
          a.verticalController,
          _number(action['top']),
          relative: operation == 'by',
          behavior: behavior,
          cssBehavior: a.scrollBehavior,
        );
      }
    }
  }

  Set<_NativeDocumentScrollAttachment> get _allAttachments =>
      _attachments.values.expand((value) => value).toSet();

  Set<_NativeDocumentScrollAttachment> _activeAttachments(String id) {
    final result = <_NativeDocumentScrollAttachment>{};
    for (final attachment
        in _attachments[id] ?? const <_NativeDocumentScrollAttachment>{}) {
      if (!attachment.retired &&
          identical(attachment.documentOwner, _documentOwner)) {
        result.add(attachment);
      }
    }
    return result;
  }

  _NativeDocumentScrollAttachment _attach(
    String id,
    int revision,
    NativeDocumentOverflow overflowX,
    NativeDocumentOverflow overflowY,
    String scrollBehavior,
  ) {
    final activeBefore = _activeAttachments(id);
    final previous =
        _readCurrentOffsets(id) ?? _savedOffsets[id] ?? Offset.zero;
    final attachment = _NativeDocumentScrollAttachment(
      controller: this,
      id: id,
      revision: revision,
      documentOwner: _documentOwner,
      overflowX: overflowX,
      overflowY: overflowY,
      scrollBehavior: scrollBehavior,
      initialOffset: previous,
    );
    (_attachments[id] ??= <_NativeDocumentScrollAttachment>{}).add(attachment);
    if (activeBefore.isNotEmpty) {
      // A retained DOM node may temporarily have two widget leases during a
      // rebuild. Withhold metrics until ownership is unique; retain its last
      // completed anchor history for the surviving lease.
      _pendingAnchoring.removeWhere((a) => a.id == id);
      for (final active in activeBefore) {
        active.hasMetrics = false;
        active.viewportRenderObject?.markNeedsLayout();
      }
    }
    attachment.horizontalController.addListener(attachment.horizontalListener);
    attachment.verticalController.addListener(attachment.verticalListener);
    _scheduleNotification();
    return attachment;
  }

  void _updateAttachment(
    _NativeDocumentScrollAttachment attachment, {
    required int revision,
    required NativeDocumentOverflow overflowX,
    required NativeDocumentOverflow overflowY,
    required String scrollBehavior,
  }) {
    if (attachment.retired) return;
    final changed =
        attachment.revision != revision ||
        attachment.overflowX != overflowX ||
        attachment.overflowY != overflowY ||
        attachment.scrollBehavior != scrollBehavior;
    if (!changed) return;
    if (!_isProgrammaticallyScrollable(attachment.overflowX) &&
        _isProgrammaticallyScrollable(overflowX) &&
        !attachment.horizontalController.hasClients) {
      attachment.replaceHorizontalController();
    }
    if (!_isProgrammaticallyScrollable(attachment.overflowY) &&
        _isProgrammaticallyScrollable(overflowY) &&
        !attachment.verticalController.hasClients) {
      attachment.replaceVerticalController();
    }
    attachment.revision = revision;
    attachment.overflowX = overflowX;
    attachment.overflowY = overflowY;
    attachment.scrollBehavior = scrollBehavior;
    attachment.hasMetrics = false;
    _scheduleNotification();
  }

  void _detach(_NativeDocumentScrollAttachment attachment) {
    _pendingAnchoring.remove(attachment);
    if (_anchorNodes?.call()[attachment.id]?.rendered == false) {
      _anchorStates.remove(attachment.id);
    }
    if (attachment.retired) {
      _scheduleRetirement(attachment);
      return;
    }
    if (identical(attachment.documentOwner, _documentOwner) &&
        _activeAttachments(attachment.id).length == 1) {
      _saveOffset(attachment);
    }
    attachment.retired = true;
    attachment.hasMetrics = false;
    final owners = _attachments[attachment.id];
    owners?.remove(attachment);
    if (owners != null && owners.isEmpty) _attachments.remove(attachment.id);
    final remaining = _activeAttachments(attachment.id);
    if (remaining.length == 1) {
      final survivor = remaining.single;
      survivor.hasMetrics = false;
      survivor.viewportRenderObject?.markNeedsLayout();
      _scheduleSurvivorRelayout(survivor);
    }
    _scheduleRetirement(attachment);
    _scheduleNotification();
  }

  void _scheduleSurvivorRelayout(_NativeDocumentScrollAttachment survivor) {
    final scheduler = SchedulerBinding.instance;
    scheduler.addPostFrameCallback((_) {
      if (_disposed ||
          survivor.retired ||
          !identical(survivor.documentOwner, _documentOwner) ||
          _activeAttachments(survivor.id).length != 1) {
        return;
      }
      final renderObject = survivor.viewportRenderObject;
      if (renderObject == null || !renderObject.attached) return;
      renderObject.markNeedsLayout();
      scheduler.ensureVisualUpdate();
    });
    scheduler.ensureVisualUpdate();
  }

  void _recordMetrics(
    _NativeDocumentScrollAttachment attachment, {
    required int revision,
    required double contentWidth,
    required double contentHeight,
  }) {
    if (_disposed ||
        attachment.retired ||
        !identical(attachment.documentOwner, _documentOwner) ||
        attachment.revision != revision ||
        _activeAttachments(attachment.id).length != 1) {
      return;
    }
    final changed =
        !attachment.hasMetrics ||
        !attachment.hasLayoutRevision ||
        attachment.layoutRevision != revision ||
        attachment.contentWidth != contentWidth ||
        attachment.contentHeight != contentHeight;
    attachment
      ..layoutRevision = revision
      ..hasLayoutRevision = true
      ..contentWidth = contentWidth
      ..contentHeight = contentHeight
      ..hasMetrics = true;
    if (changed) _scheduleNotification();
    _scheduleAnchoring(attachment);
  }

  void _offsetChanged(_NativeDocumentScrollAttachment attachment) {
    if (_disposed ||
        attachment.retired ||
        !identical(attachment.documentOwner, _documentOwner)) {
      return;
    }
    final left = _currentPixels(
      attachment.horizontalController,
      attachment.lastLeft,
    );
    final top = _currentPixels(
      attachment.verticalController,
      attachment.lastTop,
    );

    final before = Offset(attachment.lastLeft, attachment.lastTop);
    final changed =
        (attachment.lastLeft - left).abs() > 0.0001 ||
        (attachment.lastTop - top).abs() > 0.0001;
    attachment
      ..lastLeft = left
      ..lastTop = top;
    if (!changed) return;
    _anchorOffsetChanged(attachment, before, Offset(left, top));

    if (_activeAttachments(attachment.id).length == 1) {
      _savedOffsets[attachment.id] = Offset(left, top);
      _queueScrollEvent(attachment.id);
    }
    _scheduleNotification();
  }

  void _queueScrollEvent(String id) {
    if (_coalescedSequences.containsKey(id)) return;

    final sequence = _nextSequence++;
    _coalescedSequences[id] = sequence;
    _events.add(_NativeDocumentScrollEvent(id: id, sequence: sequence));
    if (_events.length > maximumPendingScrollEvents) {
      final dropped = _events.removeAt(0);
      if (_coalescedSequences[dropped.id] == dropped.sequence) {
        _coalescedSequences.remove(dropped.id);
      }
      droppedScrollEventCount++;
    }

    if (_coalescingClearScheduled) return;
    _coalescingClearScheduled = true;
    final generation = ++_coalescingGeneration;
    final scheduler = SchedulerBinding.instance;
    unawaited(
      scheduler.endOfFrame.then((_) {
        if (_disposed || generation != _coalescingGeneration) return;
        _coalescedSequences.clear();
        _coalescingClearScheduled = false;
      }),
    );
  }

  Offset? _readCurrentOffsets(String id) {
    final matches = _activeAttachments(id);
    if (matches.length != 1) return null;
    final attachment = matches.single;
    final left = _currentPixels(
      attachment.horizontalController,
      attachment.lastLeft,
    );
    final top = _currentPixels(
      attachment.verticalController,
      attachment.lastTop,
    );
    return Offset(left, top);
  }

  void _saveOffset(_NativeDocumentScrollAttachment attachment) {
    final left = _currentPixels(
      attachment.horizontalController,
      attachment.lastLeft,
    );
    final top = _currentPixels(
      attachment.verticalController,
      attachment.lastTop,
    );
    _savedOffsets[attachment.id] = Offset(left, top);
  }

  void _scheduleRetirement(_NativeDocumentScrollAttachment attachment) {
    if (!attachment.retired || attachment.retirementScheduled) return;
    attachment.retirementScheduled = true;
    scheduleMicrotask(() {
      attachment.retirementScheduled = false;
      if (!attachment.retired) return;
      if (attachment.horizontalController.hasClients ||
          attachment.verticalController.hasClients) {
        return;
      }
      _disposeAttachment(attachment);
    });
  }

  void _disposeAttachment(_NativeDocumentScrollAttachment attachment) {
    if (attachment.controllersDisposed) return;
    attachment.controllersDisposed = true;
    attachment.horizontalController
      ..removeListener(attachment.horizontalListener)
      ..dispose();
    attachment.verticalController
      ..removeListener(attachment.verticalListener)
      ..dispose();
    final owners = _attachments[attachment.id];
    owners?.remove(attachment);
    if (owners != null && owners.isEmpty) _attachments.remove(attachment.id);
  }

  void _scheduleNotification() {
    if (_disposed || _notificationScheduled) return;
    _notificationScheduled = true;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _notificationScheduled = false;
      if (!_disposed) notifyListeners();
    });
    SchedulerBinding.instance.ensureVisualUpdate();
  }

  static double _currentPixels(ScrollController controller, double fallback) =>
      controller.hasClients && controller.positions.length == 1
      ? controller.position.pixels
      : fallback;

  static double? _number(Object? value) {
    if (value is num && value.isFinite) return value.toDouble();
    return null;
  }

  static bool _isProgrammaticallyScrollable(NativeDocumentOverflow overflow) =>
      overflow == NativeDocumentOverflow.hidden ||
      overflow == NativeDocumentOverflow.auto ||
      overflow == NativeDocumentOverflow.scroll;

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _anchorHost = null;
    _anchorNodes = null;
    _anchorCapture = null;
    _requestAnchorCheck = null;
    _anchorScrollChanged = null;
    _anchorStates.clear();
    _pendingAnchoring.clear();
    _anchorPlan = [];
    _events.clear();
    _savedOffsets.clear();
    _coalescingGeneration++;
    _coalescingClearScheduled = false;
    _coalescedSequences.clear();
    for (final attachment in _allAttachments) {
      attachment
        ..retired = true
        ..hasMetrics = false;
      _scheduleRetirement(attachment);
    }
    super.dispose();
  }
}

/// Places a native CSS overflow viewport around one document element.
///
/// The child should include the element's padding, but not its border. The
/// surrounding border remains stationary while padding and content scroll.
class NativeDocumentElementScroll extends StatefulWidget {
  const NativeDocumentElementScroll({
    super.key,
    required this.controller,
    required this.id,
    required this.revision,
    required this.overflowX,
    required this.overflowY,
    this.expandVisibleOverflow = false,
    this.scrollBehavior = 'auto',
    required this.child,
  });

  final NativeDocumentElementScrollController controller;
  final String id;
  final int revision;
  final NativeDocumentOverflow overflowX;
  final NativeDocumentOverflow overflowY;

  /// Only the full document root exposes visible vertical overflow as its
  /// outer scroll extent. Nested elements keep their CSS border-box heights.
  final bool expandVisibleOverflow;
  final String scrollBehavior;
  final Widget child;

  @override
  State<NativeDocumentElementScroll> createState() =>
      _NativeDocumentElementScrollState();
}

class _NativeDocumentElementScrollState
    extends State<NativeDocumentElementScroll> {
  late _NativeDocumentScrollAttachment _attachment;

  @override
  void initState() {
    super.initState();
    _attachment = widget.controller._attach(
      widget.id,
      widget.revision,
      widget.overflowX,
      widget.overflowY,
      widget.scrollBehavior,
    );
  }

  @override
  void didUpdateWidget(covariant NativeDocumentElementScroll oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.controller, widget.controller) ||
        oldWidget.id != widget.id ||
        _attachment.retired ||
        !identical(
          _attachment.documentOwner,
          widget.controller._documentOwner,
        )) {
      oldWidget.controller._detach(_attachment);
      _attachment = widget.controller._attach(
        widget.id,
        widget.revision,
        widget.overflowX,
        widget.overflowY,
        widget.scrollBehavior,
      );
    } else {
      widget.controller._updateAttachment(
        _attachment,
        revision: widget.revision,
        overflowX: widget.overflowX,
        overflowY: widget.overflowY,
        scrollBehavior: widget.scrollBehavior,
      );
    }
  }

  @override
  void dispose() {
    widget.controller._detach(_attachment);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    Widget viewport(ViewportOffset horizontal, ViewportOffset vertical) =>
        _NativeDocumentElementScrollViewport(
          attachment: _attachment,
          revision: widget.revision,
          overflowX: widget.overflowX,
          overflowY: widget.overflowY,
          expandVisibleOverflow: widget.expandVisibleOverflow,
          horizontalOffset: horizontal,
          verticalOffset: vertical,
          child: widget.child,
        );

    Widget withHorizontal(ViewportOffset vertical) {
      if (!_needsScrollable(widget.overflowX)) {
        return viewport(ViewportOffset.fixed(0.0), vertical);
      }
      return Scrollable(
        key: ObjectKey(_attachment),
        axisDirection: AxisDirection.right,
        controller: _attachment.horizontalController,
        physics: _allowsUserScroll(widget.overflowX)
            ? const ClampingScrollPhysics()
            : const NeverScrollableScrollPhysics(),
        scrollBehavior: const ScrollBehavior(),
        viewportBuilder: (context, horizontal) =>
            viewport(horizontal, vertical),
      );
    }

    if (!_needsScrollable(widget.overflowY)) {
      return withHorizontal(ViewportOffset.fixed(0.0));
    }
    return Scrollable(
      key: ObjectKey(_attachment),
      axisDirection: AxisDirection.down,
      controller: _attachment.verticalController,
      physics: _allowsUserScroll(widget.overflowY)
          ? const ClampingScrollPhysics()
          : const NeverScrollableScrollPhysics(),
      scrollBehavior: const ScrollBehavior(),
      viewportBuilder: (context, vertical) => withHorizontal(vertical),
    );
  }

  static bool _needsScrollable(NativeDocumentOverflow overflow) =>
      overflow == NativeDocumentOverflow.hidden ||
      overflow == NativeDocumentOverflow.auto ||
      overflow == NativeDocumentOverflow.scroll;

  static bool _allowsUserScroll(NativeDocumentOverflow overflow) =>
      overflow == NativeDocumentOverflow.auto ||
      overflow == NativeDocumentOverflow.scroll;
}

class _NativeDocumentElementScrollViewport
    extends SingleChildRenderObjectWidget {
  const _NativeDocumentElementScrollViewport({
    required this.attachment,
    required this.revision,
    required this.overflowX,
    required this.overflowY,
    required this.expandVisibleOverflow,
    required this.horizontalOffset,
    required this.verticalOffset,
    required super.child,
  });

  final _NativeDocumentScrollAttachment attachment;
  final int revision;
  final NativeDocumentOverflow overflowX;
  final NativeDocumentOverflow overflowY;
  final bool expandVisibleOverflow;
  final ViewportOffset horizontalOffset;
  final ViewportOffset verticalOffset;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderNativeDocumentElementScrollViewportRender(
        attachment: attachment,
        revision: revision,
        overflowX: overflowX,
        overflowY: overflowY,
        expandVisibleOverflow: expandVisibleOverflow,
        horizontalOffset: horizontalOffset,
        verticalOffset: verticalOffset,
      );

  @override
  void updateRenderObject(
    BuildContext context,
    covariant RenderObject renderObject,
  ) {
    (renderObject as _RenderNativeDocumentElementScrollViewportRender).update(
      attachment: attachment,
      revision: revision,
      overflowX: overflowX,
      overflowY: overflowY,
      expandVisibleOverflow: expandVisibleOverflow,
      horizontalOffset: horizontalOffset,
      verticalOffset: verticalOffset,
    );
  }
}

class _RenderNativeDocumentElementScrollViewportRender extends RenderProxyBox
    implements
        NativeDocumentLayoutMetricsCommitParticipant,
        NativeDocumentPositioningScrollport {
  _RenderNativeDocumentElementScrollViewportRender({
    required this._attachment,
    required this._revision,
    required this._overflowX,
    required this._overflowY,
    required this._expandVisibleOverflow,
    required this._horizontalOffset,
    required this._verticalOffset,
  });

  _NativeDocumentScrollAttachment _attachment;
  int _revision;
  NativeDocumentOverflow _overflowX;
  NativeDocumentOverflow _overflowY;
  bool _expandVisibleOverflow;
  ViewportOffset _horizontalOffset;
  ViewportOffset _verticalOffset;
  Rect _contentBounds = Rect.zero;
  double _scrollWidth = 0;
  double _scrollHeight = 0;

  double get scrollWidth => _scrollWidth;
  double get scrollHeight => _scrollHeight;
  Rect get contentBounds => _contentBounds;

  void update({
    required _NativeDocumentScrollAttachment attachment,
    required int revision,
    required NativeDocumentOverflow overflowX,
    required NativeDocumentOverflow overflowY,
    required bool expandVisibleOverflow,
    required ViewportOffset horizontalOffset,
    required ViewportOffset verticalOffset,
  }) {
    final offsetsChanged =
        !identical(_horizontalOffset, horizontalOffset) ||
        !identical(_verticalOffset, verticalOffset);
    final changed =
        !identical(_attachment, attachment) ||
        _revision != revision ||
        _overflowX != overflowX ||
        _overflowY != overflowY ||
        _expandVisibleOverflow != expandVisibleOverflow ||
        offsetsChanged;
    if (!changed) return;

    if (offsetsChanged) {
      if (attached) {
        _horizontalOffset.removeListener(_offsetPaintChanged);
        _verticalOffset.removeListener(_offsetPaintChanged);
      }
      _horizontalOffset = horizontalOffset;
      _verticalOffset = verticalOffset;
      if (attached) {
        _horizontalOffset.addListener(_offsetPaintChanged);
        _verticalOffset.addListener(_offsetPaintChanged);
      }
    }
    if (!identical(_attachment, attachment)) {
      if (identical(_attachment.viewportRenderObject, this)) {
        _attachment.viewportRenderObject = null;
      }
      _attachment = attachment;
      if (attached) _attachment.viewportRenderObject = this;
    }
    _revision = revision;
    _overflowX = overflowX;
    _overflowY = overflowY;
    _expandVisibleOverflow = expandVisibleOverflow;
    markNeedsLayout();
  }

  void _offsetPaintChanged() => markNeedsPaint();

  bool get _clipsX => _overflowX != NativeDocumentOverflow.visible;
  bool get _clipsY => _overflowY != NativeDocumentOverflow.visible;
  bool get _scrollsX =>
      NativeDocumentElementScrollController._isProgrammaticallyScrollable(
        _overflowX,
      );
  bool get _scrollsY =>
      NativeDocumentElementScrollController._isProgrammaticallyScrollable(
        _overflowY,
      );

  BoxConstraints _childConstraints(BoxConstraints constraints) {
    return BoxConstraints(
      minWidth: constraints.minWidth,
      maxWidth: constraints.maxWidth,
      minHeight: _scrollsY ? 0.0 : constraints.minHeight,
      maxHeight: _scrollsY ? double.infinity : constraints.maxHeight,
    );
  }

  @override
  Size positioningPaddingSize(Size flowSize) => constraints.constrain(flowSize);

  @override
  void performLayout() {
    final childConstraints = _childConstraints(constraints);
    if (child == null) {
      size = constraints.smallest;
    } else {
      child!.layout(childConstraints, parentUsesSize: true);
      size = constraints.constrain(child!.size);
    }

    Rect? measuredBounds;
    invokeLayoutCallback<BoxConstraints>((_) {
      measuredBounds = _measureContentBounds();
    });
    _contentBounds =
        measuredBounds ?? Rect.fromLTWH(0, 0, size.width, size.height);
    if (_expandVisibleOverflow && !_clipsY && !constraints.hasBoundedHeight) {
      size = constraints.constrain(
        Size(size.width, math.max(size.height, _contentBounds.bottom)),
      );
    }
    _scrollWidth = math.max(size.width, _contentBounds.right);
    _scrollHeight = math.max(size.height, _contentBounds.bottom);
    _laidOutViewportSize = size;
    _metricsDeferred = true;
    if (nativeDocumentMarginMetricsCanCommit(this)) {
      commitDocumentLayoutMetrics();
    }
  }

  bool _metricsDeferred = false;
  Size _laidOutViewportSize = Size.zero;
  @override
  void commitDocumentLayoutMetrics() {
    if (!_metricsDeferred || !nativeDocumentMarginMetricsCanCommit(this)) {
      return;
    }
    _metricsDeferred = false;
    _horizontalOffset.applyViewportDimension(_laidOutViewportSize.width);
    _verticalOffset.applyViewportDimension(_laidOutViewportSize.height);
    final horizontalMax = _scrollsX
        ? math.max(0.0, _scrollWidth - _laidOutViewportSize.width)
        : 0.0;
    final verticalMax = _scrollsY
        ? math.max(0.0, _scrollHeight - _laidOutViewportSize.height)
        : 0.0;

    // Layout clamping is a correction, not a user/programmatic scroll that
    // selects new anchors in ancestor scroll boxes.
    final alreadyCorrecting = _attachment.controller._correctingAnchors
        .contains(_attachment);
    _attachment.controller._correctingAnchors.add(_attachment);
    try {
      _applyDimensions(_horizontalOffset, horizontalMax);
      _applyDimensions(_verticalOffset, verticalMax);
    } finally {
      if (!alreadyCorrecting) {
        _attachment.controller._correctingAnchors.remove(_attachment);
      }
    }
    if (_scrollsX) _attachment.lastLeft = _horizontalOffset.pixels;
    if (_scrollsY) _attachment.lastTop = _verticalOffset.pixels;

    _attachment.controller._recordMetrics(
      _attachment,
      revision: _revision,
      contentWidth: _scrollWidth,
      contentHeight: _scrollHeight,
    );
  }

  static void _applyDimensions(ViewportOffset offset, double maximum) {
    // CSS scroll extents clamp synchronously when content shrinks. Letting an
    // idle ScrollActivity spring back first changes ancestor anchor selection
    // and can over-correct a nested panel on the following frame.
    if (offset.hasPixels) {
      final clamped = offset.pixels.clamp(0.0, maximum);
      if (clamped != offset.pixels) offset.correctBy(clamped - offset.pixels);
    }
    var accepted = offset.applyContentDimensions(0.0, maximum);
    var attempts = 0;
    while (!accepted && attempts++ < 4) {
      accepted = offset.applyContentDimensions(0.0, maximum);
    }
  }

  Rect _measureContentBounds() {
    final unscroll = Offset(_horizontalOffset.pixels, _verticalOffset.pixels);
    final viewportBounds = Rect.fromLTWH(0, 0, size.width, size.height);

    Rect union(Rect first, Rect second) => Rect.fromLTRB(
      math.min(first.left, second.left),
      math.min(first.top, second.top),
      math.max(first.right, second.right),
      math.max(first.bottom, second.bottom),
    );

    bool clipsDescendants(RenderObject object) => switch (object) {
      RenderClipRect value => value.clipBehavior != Clip.none,
      RenderClipRRect value => value.clipBehavior != Clip.none,
      RenderClipOval value => value.clipBehavior != Clip.none,
      RenderClipPath value => value.clipBehavior != Clip.none,
      RenderPhysicalModel value => value.clipBehavior != Clip.none,
      RenderPhysicalShape value => value.clipBehavior != Clip.none,
      _ => false,
    };

    Rect? visit(RenderObject object) {
      if (object is NativeDocumentFixedSurface &&
          (object as NativeDocumentFixedSurface).fixedToViewport) {
        return null;
      }
      if (object is RenderBox && (!object.attached || !object.hasSize)) {
        return null;
      }

      Rect? bounds;
      if (object is RenderBox) {
        bounds = MatrixUtils.transformRect(
          object.getTransformTo(this),
          Offset.zero & object.size,
        ).shift(unscroll);

        if (object is _RenderNativeDocumentElementScrollViewportRender) {
          final visibleBounds = Rect.fromLTRB(
            object._overflowX == NativeDocumentOverflow.visible
                ? object._contentBounds.left
                : 0.0,
            object._overflowY == NativeDocumentOverflow.visible
                ? object._contentBounds.top
                : 0.0,
            object._overflowX == NativeDocumentOverflow.visible
                ? object._contentBounds.right
                : object.size.width,
            object._overflowY == NativeDocumentOverflow.visible
                ? object._contentBounds.bottom
                : object.size.height,
          );
          return union(
            bounds,
            MatrixUtils.transformRect(
              object.getTransformTo(this),
              visibleBounds,
            ).shift(unscroll),
          );
        }
        if (clipsDescendants(object)) return bounds;
      }

      final childBounds = <Rect>[];
      object.visitChildren((child) {
        final measured = visit(child);
        if (measured != null) childBounds.add(measured);
      });
      for (final childRect in childBounds) {
        bounds = bounds == null ? childRect : union(bounds, childRect);
      }

      if (object is RenderBox && bounds != null) {
        final padding = nativeDocumentPaddingInsets(object);
        if (padding != null) {
          final ownRect = MatrixUtils.transformRect(
            object.getTransformTo(this),
            Offset.zero & object.size,
          ).shift(unscroll);
          final paddedRight =
              _overflowX != NativeDocumentOverflow.clip &&
                  bounds.right > ownRect.right
              ? bounds.right + padding.right
              : bounds.right;
          final paddedBottom =
              _overflowY != NativeDocumentOverflow.clip &&
                  bounds.bottom > ownRect.bottom
              ? bounds.bottom + padding.bottom
              : bounds.bottom;
          bounds = Rect.fromLTRB(
            bounds.left,
            bounds.top,
            paddedRight,
            paddedBottom,
          );
        }
      }
      return bounds;
    }

    var bounds = viewportBounds;
    final currentChild = child;
    if (currentChild != null) {
      final childBounds = visit(currentChild);
      if (childBounds != null) bounds = union(bounds, childBounds);
    }
    return Rect.fromLTRB(
      math.min(0.0, bounds.left),
      math.min(0.0, bounds.top),
      math.max(size.width, bounds.right),
      math.max(size.height, bounds.bottom),
    );
  }

  @override
  Size computeDryLayout(BoxConstraints constraints) {
    final childConstraints = _childConstraints(constraints);
    return constraints.constrain(
      child?.getDryLayout(childConstraints) ?? constraints.smallest,
    );
  }

  @override
  double? computeDryBaseline(
    BoxConstraints constraints,
    TextBaseline baseline,
  ) => child?.getDryBaseline(_childConstraints(constraints), baseline);

  @override
  double computeMinIntrinsicWidth(double height) =>
      child?.getMinIntrinsicWidth(height) ?? 0.0;

  @override
  double computeMaxIntrinsicWidth(double height) =>
      child?.getMaxIntrinsicWidth(height) ?? 0.0;

  @override
  double computeMinIntrinsicHeight(double width) =>
      child?.getMinIntrinsicHeight(width) ?? 0.0;

  @override
  double computeMaxIntrinsicHeight(double width) =>
      child?.getMaxIntrinsicHeight(width) ?? 0.0;

  @override
  double? computeDistanceToActualBaseline(TextBaseline baseline) =>
      child?.getDistanceToActualBaseline(baseline) ??
      super.computeDistanceToActualBaseline(baseline);

  @override
  void applyPaintTransform(RenderObject child, Matrix4 transform) {
    transform.translateByDouble(
      -_horizontalOffset.pixels,
      -_verticalOffset.pixels,
      0,
      1,
    );
  }

  @override
  bool hitTest(BoxHitTestResult result, {required Offset position}) {
    final withinX = !_clipsX || (position.dx >= 0 && position.dx <= size.width);
    final withinY =
        !_clipsY || (position.dy >= 0 && position.dy <= size.height);
    if (!withinX || !withinY) return false;
    if (hitTestChildren(result, position: position)) {
      result.add(BoxHitTestEntry(this, position));
      return true;
    }
    return false;
  }

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) {
    final currentChild = child;
    if (currentChild == null) return false;
    final hitNormally = result.addWithPaintOffset(
      offset: Offset(-_horizontalOffset.pixels, -_verticalOffset.pixels),
      position: position,
      hitTest: (result, transformed) =>
          currentChild.hitTest(result, position: transformed),
    );
    if (hitNormally) return true;

    // OverflowBox and Stack descendants can paint in the scrollport while an
    // intermediate box remains only viewport-sized. Flutter's ordinary box
    // hit test rejects the point at that intermediate box. Walk only this
    // subtree as a fallback, preserving descendant transforms and clip nodes.
    return _hitTestOverflowingDescendants(
      result,
      currentChild,
      position,
      localToGlobal(position),
    );
  }

  bool _hitTestOverflowingDescendants(
    BoxHitTestResult result,
    RenderObject object,
    Offset viewportPosition,
    Offset globalPosition,
  ) {
    if (object is RenderIgnorePointer && object.ignoring) return false;
    if (object is RenderOffstage && object.offstage) return false;
    if (nativeDocumentScrollClipsGlobalPoint(object, globalPosition)) {
      return false;
    }

    Matrix4? paintTransform;
    if (object is RenderBox) {
      if (!object.attached || !object.hasSize) return false;
      paintTransform = object.getTransformTo(this);
      final hitInsideBounds = result.addWithPaintTransform(
        transform: paintTransform,
        position: viewportPosition,
        hitTest: (result, localPosition) =>
            object.size.contains(localPosition) &&
            object.hitTest(result, position: localPosition),
      );
      if (hitInsideBounds) return true;
      if (object is RenderAbsorbPointer && object.absorbing) return false;
      if (_clipsDescendantsForHitTesting(object)) return false;
    }

    final children = <RenderObject>[];
    object.visitChildren(children.add);
    for (final descendant in children.reversed) {
      if (_hitTestOverflowingDescendants(
        result,
        descendant,
        viewportPosition,
        globalPosition,
      )) {
        if (object is RenderBox && paintTransform != null) {
          result.addWithPaintTransform(
            transform: paintTransform,
            position: viewportPosition,
            hitTest: (result, localPosition) {
              result.add(BoxHitTestEntry(object, localPosition));
              return true;
            },
          );
        }
        return true;
      }
    }
    return false;
  }

  static bool _clipsDescendantsForHitTesting(RenderObject object) =>
      switch (object) {
        RenderClipRect value => value.clipBehavior != Clip.none,
        RenderClipRRect value => value.clipBehavior != Clip.none,
        RenderClipOval value => value.clipBehavior != Clip.none,
        RenderClipPath value => value.clipBehavior != Clip.none,
        RenderPhysicalModel value => value.clipBehavior != Clip.none,
        RenderPhysicalShape value => value.clipBehavior != Clip.none,
        _ => false,
      };

  @override
  void paint(PaintingContext context, Offset offset) {
    if (child == null) return;

    void paintTranslated(PaintingContext context, Offset offset) {
      context.pushTransform(
        needsCompositing,
        offset,
        Matrix4.translationValues(
          -_horizontalOffset.pixels,
          -_verticalOffset.pixels,
          0,
        ),
        super.paint,
      );
    }

    if (!_clipsX && !_clipsY) {
      paintTranslated(context, offset);
      return;
    }

    final canvasBounds = context.canvas.getLocalClipBounds().shift(-offset);
    final clipRect = Rect.fromLTRB(
      _clipsX ? 0.0 : canvasBounds.left,
      _clipsY ? 0.0 : canvasBounds.top,
      _clipsX ? size.width : canvasBounds.right,
      _clipsY ? size.height : canvasBounds.bottom,
    );
    context.pushClipRect(
      needsCompositing,
      offset,
      clipRect,
      paintTranslated,
      clipBehavior: Clip.hardEdge,
    );
  }

  @override
  void detach() {
    _horizontalOffset.removeListener(_offsetPaintChanged);
    _verticalOffset.removeListener(_offsetPaintChanged);
    if (identical(_attachment.viewportRenderObject, this)) {
      _attachment.viewportRenderObject = null;
    }
    super.detach();
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _attachment.viewportRenderObject = this;
    _horizontalOffset.addListener(_offsetPaintChanged);
    _verticalOffset.addListener(_offsetPaintChanged);
  }
}

class _NativeDocumentScrollAttachment {
  _NativeDocumentScrollAttachment({
    required this.controller,
    required this.id,
    required this.revision,
    required this.documentOwner,
    required this.overflowX,
    required this.overflowY,
    required this.scrollBehavior,
    required Offset initialOffset,
  }) : lastLeft = initialOffset.dx,
       lastTop = initialOffset.dy {
    horizontalListener = () => controller._offsetChanged(this);
    verticalListener = () => controller._offsetChanged(this);
    horizontalController = ScrollController(
      initialScrollOffset: initialOffset.dx,
      keepScrollOffset: false,
      debugLabel: 'document:$id:x',
      onDetach: (_) => controller._scheduleRetirement(this),
    );
    verticalController = NativeDocumentScrollController(
      initialScrollOffset: initialOffset.dy,
      keepScrollOffset: false,
      debugLabel: 'document:$id:y',
      onDetach: (_) => controller._scheduleRetirement(this),
    );
  }

  final NativeDocumentElementScrollController controller;
  final String id;
  final Object documentOwner;
  late final VoidCallback horizontalListener;
  late final VoidCallback verticalListener;
  late ScrollController horizontalController;
  late NativeDocumentScrollController verticalController;
  int revision;
  int? layoutRevision;
  NativeDocumentOverflow overflowX;
  NativeDocumentOverflow overflowY;
  String scrollBehavior;
  double lastLeft;
  double lastTop;
  double? contentWidth;
  double? contentHeight;
  bool hasLayoutRevision = false;
  bool hasMetrics = false;
  _RenderNativeDocumentElementScrollViewportRender? viewportRenderObject;
  bool retired = false;
  bool retirementScheduled = false;
  bool controllersDisposed = false;

  void replaceHorizontalController() {
    horizontalController.removeListener(horizontalListener);
    horizontalController.dispose();
    horizontalController = ScrollController(
      initialScrollOffset: lastLeft,
      keepScrollOffset: false,
      debugLabel: 'document:$id:x',
      onDetach: (_) => controller._scheduleRetirement(this),
    )..addListener(horizontalListener);
  }

  void replaceVerticalController() {
    verticalController.removeListener(verticalListener);
    verticalController.dispose();
    verticalController = NativeDocumentScrollController(
      initialScrollOffset: lastTop,
      keepScrollOffset: false,
      debugLabel: 'document:$id:y',
      onDetach: (_) => controller._scheduleRetirement(this),
    )..addListener(verticalListener);
  }
}

class _NativeDocumentScrollEvent {
  const _NativeDocumentScrollEvent({required this.id, required this.sequence});

  final String id;
  final int sequence;
}
