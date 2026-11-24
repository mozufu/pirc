import 'render_l10n.dart';
import 'dart:collection';
import 'dart:convert';
import 'document_canvas_sizing.dart';
import 'document_offsets.dart';
import 'document_computed_style_spec.dart';
import 'html_document_box.dart';
import 'document_element_scroll.dart';
import 'document_scroll_anchor_state.dart';
import 'document_absolute_position.dart';
import 'document_transform.dart';

import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

/// Collects the laid-out render boxes associated with native document nodes.
///
/// The controller reports only render objects supplied by the document
/// renderer. It does not infer boxes from DOM styles or create boxes for inline
/// text fragments.
class NativeDocumentLayoutController extends ChangeNotifier {
  static const int maximumElementCount = 5000;

  _RenderNativeDocumentLayoutRoot? _root;
  final Map<String, Set<_RenderNativeDocumentLayoutElement>> _elements = {};
  bool _notificationScheduled = false;
  bool _disposed = false;

  /// Hit-tests the current document render tree at a global pointer position.
  ///
  /// The nearest current, unambiguous [NativeDocumentLayoutElement] on the
  /// actual Flutter hit path supplies [NativeDocumentHitTest.elementId]. A
  /// completed hit test can have no mapped element, so its result may carry a
  /// null ID. A null result means the requested layout is unavailable.
  NativeDocumentHitTest? hitTestDocument(
    Offset globalPosition, {
    required int revision,
  }) {
    if (_disposed ||
        !globalPosition.dx.isFinite ||
        !globalPosition.dy.isFinite) {
      return null;
    }
    final root = _root;
    if (root == null ||
        !root.attached ||
        !root.hasSize ||
        root.revision != revision ||
        root.laidOutRevision != revision ||
        root.pendingLayout ||
        !nativeDocumentMarginsAreSettled(root)) {
      return null;
    }

    final Offset localPosition;
    try {
      localPosition = root.globalToLocal(globalPosition);
    } on FlutterError {
      return null;
    }
    if (!localPosition.dx.isFinite || !localPosition.dy.isFinite) return null;
    // Viewport-fixed descendants may paint outside a short flow root. The
    // actual view hit path below proves ownership and all enclosing clips.

    // Start at the actual view root so ancestor transforms, clips, and
    // overlapping render objects participate in the same hit test Flutter
    // uses for pointer dispatch. Testing the document root on its own would
    // incorrectly hit content hidden by a viewport clip or overlay.
    final renderView = root.owner?.rootNode;
    if (renderView is! RenderView || !renderView.attached) {
      return null;
    }
    if (!(Offset.zero & renderView.size).contains(globalPosition)) {
      return const NativeDocumentHitTest(elementId: null);
    }
    final hitTest = HitTestResult();
    renderView.hitTest(hitTest, position: globalPosition);
    final path = hitTest.path.toList(growable: false);

    // HitTestResult is ordered from the deepest hit target out toward the
    // view. Only consider entries up through this document's own root.
    var rootPathIndex = -1;
    for (var index = 0; index < path.length; index++) {
      if (identical(path[index].target, root)) {
        rootPathIndex = index;
        break;
      }
    }
    if (rootPathIndex < 0) {
      return const NativeDocumentHitTest(elementId: null);
    }

    for (var index = 0; index <= rootPathIndex; index++) {
      final target = path[index].target;
      if (target is! _RenderNativeDocumentLayoutElement ||
          !target.attached ||
          target.pendingLayout ||
          !target.hasSize ||
          target.revision != revision ||
          target.laidOutRevision != revision ||
          !root.knownIds.contains(target.id) ||
          root.noBoxIds.contains(target.id) ||
          !identical(_nearestRoot(target), root)) {
        continue;
      }

      final owners = _elements[target.id];
      if (owners == null) continue;
      final currentOwners = owners
          .where(
            (candidate) =>
                candidate.attached &&
                candidate.revision == revision &&
                identical(_nearestRoot(candidate), root),
          )
          .toList(growable: false);
      // Capture marks duplicate ownership unsupported even when only one
      // duplicate happens to lie on the current pointer path.
      if (currentOwners.length == 1 &&
          identical(currentOwners.single, target)) {
        return NativeDocumentHitTest(elementId: target.id);
      }
    }
    return const NativeDocumentHitTest(elementId: null);
  }

  /// Current measured flow boxes in the explicit document coordinate space.
  /// Fixed subtrees are excluded by the caller's DOM policy. Measuring here
  /// does not require outer scroll-decoration transforms to have laid out.
  Map<String, Rect>? scrollAnchorBoxes(Set<String> ids) =>
      scrollAnchorFrame(ids)?.boxes;

  NativeDocumentScrollAnchorFrame? scrollAnchorFrame(
    Set<String> ids, {
    RenderBox? relativeTo,
    Offset contentOffset = Offset.zero,
    Map<String, NativeDocumentScrollAnchorPort> scrollports = const {},
  }) {
    final root = _root;
    if (_disposed ||
        root == null ||
        !root.attached ||
        !root.hasSize ||
        root.pendingLayout ||
        root.laidOutRevision != root.revision ||
        !nativeDocumentMarginsAreSettled(root)) {
      return null;
    }
    final basis = relativeTo ?? root;
    if (!basis.attached ||
        !basis.hasSize ||
        !identical(_nearestRoot(basis), root)) {
      return null;
    }
    Rect? rectangle(RenderBox surface) {
      RenderObject? current = surface;
      while (current != null && !identical(current, basis)) {
        current = current.parent;
      }
      if (current == null) return null;
      final translation = MatrixUtils.getAsTranslation(
        surface.getTransformTo(basis),
      );
      if (translation == null ||
          !translation.dx.isFinite ||
          !translation.dy.isFinite) {
        return null;
      }
      return (translation & surface.size).shift(contentOffset);
    }

    final result = <String, Rect>{};
    final layoutBoxes = <String, Rect>{};
    for (final id in ids) {
      if (!root.knownIds.contains(id) || root.noBoxIds.contains(id)) continue;
      final owners = (_elements[id] ?? {})
          .where(
            (e) =>
                e.attached &&
                e.revision == root.revision &&
                identical(_nearestRoot(e), root),
          )
          .toList();
      if (owners.length != 1) continue;
      final element = owners.single;
      if (element.pendingLayout) return null;
      if (!element.hasSize || element.laidOutRevision != root.revision) {
        continue;
      }
      final surface = element.boxSurface?.call(element) ?? element;
      if (!surface.attached ||
          !surface.hasSize ||
          !identical(_nearestRoot(surface), root)) {
        continue;
      }
      try {
        final rect = rectangle(surface);
        if (rect != null) {
          result[id] = rect;
          var shift = Offset.zero;
          RenderObject? ancestor = surface.parent;
          while (ancestor != null && !identical(ancestor, basis)) {
            shift += nativeDocumentScrollTranslation(ancestor);
            ancestor = ancestor.parent;
          }
          layoutBoxes[id] = rect.shift(shift);
        }
      } on FlutterError {
        return null;
      }
    }
    final clips = <String, Rect>{};
    for (final entry in scrollports.entries) {
      final port = entry.value;
      if (!port.surface.attached ||
          !port.surface.hasSize ||
          !identical(_nearestRoot(port.surface), root)) {
        continue;
      }
      final rect = rectangle(port.surface);
      if (rect == null) continue;
      clips[entry.key] = Rect.fromLTRB(
        port.clipX ? rect.left : double.negativeInfinity,
        port.clipY ? rect.top : double.negativeInfinity,
        port.clipX ? rect.right : double.infinity,
        port.clipY ? rect.bottom : double.infinity,
      );
    }
    return NativeDocumentScrollAnchorFrame(result, clips, layoutBoxes);
  }

  /// Measures an owned editor's caret in the same completed document frame.
  /// The caret is private host evidence and is never exported in script packets.
  Rect? measureOwnedRect(String id, RenderBox surface, Rect localRect) {
    if (!localRect.left.isFinite ||
        !localRect.top.isFinite ||
        !localRect.width.isFinite ||
        !localRect.height.isFinite ||
        localRect.width <= 0 ||
        localRect.height <= 0) {
      return null;
    }
    final root = _root;
    if (_disposed ||
        root == null ||
        !root.attached ||
        !root.hasSize ||
        root.pendingLayout ||
        root.laidOutRevision != root.revision ||
        !root.knownIds.contains(id) ||
        !surface.attached ||
        !surface.hasSize ||
        !identical(_nearestRoot(surface), root)) {
      return null;
    }
    final owners = (_elements[id] ?? {})
        .where(
          (e) =>
              e.attached &&
              e.revision == root.revision &&
              e.laidOutRevision == root.revision &&
              !e.pendingLayout &&
              e.hasSize &&
              identical(_nearestRoot(e), root),
        )
        .toList();
    if (owners.length != 1) return null;
    var owned = false;
    for (
      RenderObject? parent = surface;
      parent != null;
      parent = parent.parent
    ) {
      if (identical(parent, owners.single)) {
        owned = true;
        break;
      }
      if (identical(parent, root)) break;
    }
    if (!owned) return null;
    try {
      final rect = MatrixUtils.transformRect(
        surface.getTransformTo(root),
        localRect,
      );
      if (!rect.left.isFinite ||
          !rect.top.isFinite ||
          !rect.width.isFinite ||
          !rect.height.isFinite ||
          rect.width <= 0 ||
          rect.height <= 0) {
        return null;
      }
      return rect;
    } on FlutterError {
      return null;
    }
  }

  /// Captures the latest completed layout for [revision].
  ///
  /// Element rectangles are relative to the explicit document root. Scroll is
  /// included as viewport metadata and is not applied to the element boxes.
  Map<String, dynamic>? capture({
    required int revision,
    required int generation,
    required Size viewport,
    Offset scrollOffset = Offset.zero,
    Size? contentSize,
    Map<String, dynamic>? Function(String id)? elementScrollMetrics,
    Map<String, double>? Function(String id)? elementScrollRanges,
    bool? Function(String id)? elementScrollActivity,
    Map<String, RenderBox> elementScrollSurfaces = const {},
    List<Map<String, dynamic>> scrollEvents = const [],
    Set<String>? requestedIds,
  }) {
    if (_disposed) return null;
    final root = _root;
    if (root == null) return null;
    final requested = requestedIds ?? root.knownIds;
    if (!root.knownIds.containsAll(requested)) return null;
    if (requested.length > maximumElementCount) {
      throw RangeError.range(
        requested.length,
        0,
        maximumElementCount,
        'knownIds',
        tr("At most {0} native document element IDs are supported.", [
          maximumElementCount,
        ]),
      );
    }
    if (!root.attached ||
        !root.hasSize ||
        root.revision != revision ||
        root.laidOutRevision != revision ||
        root.pendingLayout) {
      return null;
    }

    if (!nativeDocumentMarginsAreSettled(root)) return null;
    final known = requested.toList()..sort();
    final boxes = <Map<String, dynamic>>[];

    final styleSurfaces = <String, RenderBox>{};
    for (final id in known) {
      if (root.noBoxIds.contains(id)) {
        boxes.add(<String, dynamic>{'id': id, 'kind': 'none'});
        continue;
      }

      final candidates = <_RenderNativeDocumentLayoutElement>[];
      for (final element
          in _elements[id] ?? const <_RenderNativeDocumentLayoutElement>{}) {
        if (element.attached &&
            element.revision == revision &&
            identical(_nearestRoot(element), root)) {
          candidates.add(element);
        }
      }

      // Ambiguous ownership must not expose a potentially unrelated box.
      if (candidates.length != 1) {
        boxes.add(<String, dynamic>{'id': id, 'kind': 'unsupported'});
        continue;
      }

      final element = candidates.single;
      if (element.pendingLayout) {
        return null;
      }
      if (!element.hasSize || element.laidOutRevision != revision) {
        boxes.add(<String, dynamic>{'id': id, 'kind': 'unsupported'});
        continue;
      }

      final surface = element.boxSurface?.call(element) ?? element;
      if (!surface.attached ||
          !surface.hasSize ||
          !identical(_nearestRoot(surface), root)) {
        boxes.add(<String, dynamic>{'id': id, 'kind': 'unsupported'});
        continue;
      }
      final Rect rect;
      try {
        rect = MatrixUtils.transformRect(
          surface.getTransformTo(root),
          Offset.zero & surface.size,
        );
      } on FlutterError {
        boxes.add(<String, dynamic>{'id': id, 'kind': 'unsupported'});
        continue;
      }

      final entry = <String, dynamic>{
        'id': id,
        'kind': 'box',
        'x': rect.left,
        'y': rect.top,
        'width': rect.width,
        'height': rect.height,
        'offsetWidth': surface.size.width.round(),
        'offsetHeight': surface.size.height.round(),
      };
      styleSurfaces[id] = surface;
      final offset = _offsetMetrics(element, surface, root);
      if (offset != null) entry['offset'] = offset;
      final client = _clientMetrics(surface);
      if (client != null) entry.addAll(client);
      final scroll = elementScrollMetrics?.call(id);
      if (scroll != null) {
        final range = elementScrollRanges?.call(id);
        final active = elementScrollActivity?.call(id);
        entry['scroll'] = {...scroll, 'range': ?range, 'active': ?active};
      }
      boxes.add(entry);
    }

    _attachComputedStyles(boxes, root.computedStyles, styleSurfaces, viewport);
    final byId = {for (final box in boxes) box['id'] as String: box};
    final ports = {
      for (final entry in elementScrollSurfaces.entries) entry.value: entry.key,
    };
    var references = 0, revealReferences = 0;
    for (final box in boxes) {
      final id = box['id'] as String, surface = styleSurfaces[id];
      if (surface == null ||
          root.computedStyles[id]?.scrollTranslationSupported != true) {
        continue;
      }
      final geometry = _scrollGeometry(
        id,
        surface,
        root,
        byId,
        ports,
        elementScrollRanges,
      );
      if (geometry == null) continue;
      final count = (geometry['ancestors'] as List).length;
      if (references + count > 16384) continue;
      references += count;
      box['scrollGeometry'] = geometry;
      final reveal = _scrollRevealGeometry(
        id,
        surface,
        root,
        byId,
        ports,
        elementScrollRanges,
      );
      if (reveal != null) {
        final n = (reveal['ports'] as List).length;
        if (revealReferences + n <= 16384) {
          revealReferences += n;
          box['scrollReveal'] = reveal;
        }
      }
    }
    return <String, dynamic>{
      'revision': revision,
      'generation': generation,
      'viewport': <String, dynamic>{
        'width': viewport.width,
        'height': viewport.height,
        'scrollX': scrollOffset.dx,
        'scrollY': scrollOffset.dy,
        if (contentSize != null) ...{
          'contentWidth': contentSize.width,
          'contentHeight': contentSize.height,
        },
      },
      'boxes': boxes,
      if (scrollEvents.isNotEmpty) 'scrollEvents': scrollEvents,
    };
  }

  static List<double>? _affineAxes(Matrix4 matrix) {
    final m = matrix.storage;
    if (m.any((value) => !value.isFinite) ||
        m[2].abs() > 1e-9 ||
        m[3].abs() > 1e-9 ||
        m[6].abs() > 1e-9 ||
        m[7].abs() > 1e-9 ||
        m[8].abs() > 1e-9 ||
        m[9].abs() > 1e-9 ||
        m[11].abs() > 1e-9 ||
        m[14].abs() > 1e-9 ||
        (m[10] - 1).abs() > 1e-9 ||
        (m[15] - 1).abs() > 1e-9) {
      return null;
    }
    return [m[0], m[1], m[4], m[5]];
  }

  Map<String, dynamic>? _scrollRevealGeometry(
    String id,
    RenderBox surface,
    _RenderNativeDocumentLayoutRoot root,
    Map<String, Map<String, dynamic>> boxes,
    Map<RenderBox, String> ports,
    Map<String, double>? Function(String)? ranges,
  ) {
    try {
      final chain = <Map<String, dynamic>>[];
      var viewport = true;
      RenderObject? current = surface;
      while (!identical(current, root)) {
        if (current == null) return null;
        if (current is NativeDocumentFixedSurface &&
            (current as NativeDocumentFixedSurface).fixedToViewport) {
          if (!(current as NativeDocumentFixedSurface)
              .scrollTranslationIndependent) {
            return null;
          }
          viewport = false;
          break;
        }
        current = current.parent;
        if (current == null || identical(current, root)) continue;
        final size = nativeDocumentRevealScrollport(current);
        if (size == null) continue;
        final owner = nativeDocumentScrollOwnerId(current);
        if (current is! RenderBox ||
            owner == null ||
            owner == id ||
            ports[current] != owner ||
            boxes[owner]?['kind'] != 'box' ||
            boxes[owner]?['scroll'] is! Map ||
            ranges?.call(owner) == null ||
            chain.length >= 64) {
          return null;
        }
        final axes = _affineAxes(current.getTransformTo(root));
        if (axes == null ||
            (axes[0] * axes[3] - axes[1] * axes[2]).abs() < 1e-12) {
          return null;
        }
        final transform = current.getTransformTo(root);
        final origin = MatrixUtils.transformPoint(transform, Offset.zero);
        final inverse = Matrix4.copy(transform);
        if (inverse.invert() == 0) return null;
        final absolute = MatrixUtils.transformRect(
          surface.getTransformTo(root),
          Offset.zero & surface.size,
        );
        final rect = MatrixUtils.transformRect(inverse, absolute);
        final values = [
          rect.left,
          rect.top,
          rect.width,
          rect.height,
          origin.dx,
          origin.dy,
          size.width,
          size.height,
        ];
        if (values.any((n) => !n.isFinite || n.abs() > 9007199254740990)) {
          return null;
        }
        chain.add({
          'id': owner,
          'rect': [rect.left, rect.top, rect.width, rect.height],
          'origin': [origin.dx, origin.dy],
          'width': size.width,
          'height': size.height,
          'axes': axes,
        });
      }
      return {'viewport': viewport, 'ports': chain};
    } on FlutterError {
      return null;
    }
  }

  Map<String, dynamic>? _scrollGeometry(
    String id,
    RenderBox surface,
    _RenderNativeDocumentLayoutRoot root,
    Map<String, Map<String, dynamic>> boxes,
    Map<RenderBox, String> ports,
    Map<String, double>? Function(String)? ranges,
  ) {
    try {
      if (_affineAxes(surface.getTransformTo(root)) == null) return null;
      final ancestors = <Map<String, dynamic>>[];
      var followsViewport = true;
      RenderObject? current = surface;
      while (!identical(current, root)) {
        if (current == null) return null;
        final fixedSurface = current is NativeDocumentFixedSurface
            ? current as NativeDocumentFixedSurface
            : null;
        if (fixedSurface != null && fixedSurface.fixedToViewport) {
          if (!fixedSurface.scrollTranslationIndependent) return null;
          followsViewport = false;
          break;
        }
        current = current.parent;
        if (current == null || identical(current, root)) continue;
        final ownerId = nativeDocumentScrollOwnerId(current);
        if (ownerId == null) continue;
        if (current is! RenderBox || ports[current] != ownerId) return null;
        final range = ranges?.call(ownerId);
        if (range == null) return null;
        if (range['minLeft'] == range['maxLeft'] &&
            range['minTop'] == range['maxTop']) {
          continue;
        }
        final owner = boxes[ownerId];
        if (ownerId == id ||
            owner?['kind'] != 'box' ||
            owner?['scroll'] is! Map) {
          return null;
        }
        final axes = _affineAxes(current.getTransformTo(root));
        if (axes == null || ancestors.length >= 64) return null;
        ancestors.add({'id': ownerId, 'axes': axes});
      }
      return {'viewport': followsViewport, 'ancestors': ancestors};
    } on FlutterError {
      return null;
    }
  }

  Map<String, dynamic>? _offsetMetrics(
    _RenderNativeDocumentLayoutElement element,
    RenderBox surface,
    _RenderNativeDocumentLayoutRoot root,
  ) {
    final spec = element.offsetSpec;
    if (spec == null) return null;
    if (spec.origin == NativeDocumentOffsetOrigin.zero) {
      return {'top': 0, 'left': 0, 'parentId': null};
    }
    final positioned = _nativePositionedSurface(element, surface, root);
    if (spec.requiresPositionedSurface && positioned == null) return null;
    if (spec.origin == NativeDocumentOffsetOrigin.viewport) {
      if (positioned == null || !positioned.viewportFixed) return null;
      final local = _unscrolledOrigin(surface, positioned.surface);
      if (local == null) return null;
      final offset = local + positioned.offset;
      if (!offset.dx.isFinite ||
          !offset.dy.isFinite ||
          offset.dx.abs() > 9007199254740990 ||
          offset.dy.abs() > 9007199254740990) {
        return null;
      }
      return {
        'top': (offset.dy + .5).floor(),
        'left': (offset.dx + .5).floor(),
        'parentId': null,
      };
    }
    if (spec.requiresPositionedSurface && positioned!.viewportFixed) {
      return null;
    }
    final initialParent =
        spec.requiresPositionedSurface &&
        spec.origin == NativeDocumentOffsetOrigin.initialContainingBlock &&
        positioned?.initialContainingBlock == true;
    RenderBox? measuredAncestor(String? id) {
      if (id == null ||
          !root.knownIds.contains(id) ||
          root.noBoxIds.contains(id)) {
        return null;
      }
      final owners = (_elements[id] ?? {}).where(
        (candidate) =>
            candidate.attached && identical(_nearestRoot(candidate), root),
      );
      if (owners.length != 1) return null;
      final owner = owners.single;
      if (owner.pendingLayout ||
          !owner.hasSize ||
          owner.laidOutRevision != root.revision ||
          owner.revision != root.revision) {
        return null;
      }
      RenderObject? current = element.parent;
      while (current != null &&
          !identical(current, owner) &&
          !identical(current, root)) {
        current = current.parent;
      }
      if (!identical(current, owner) && !initialParent) return null;
      final box = owner.boxSurface?.call(owner) ?? owner;
      if (!box.attached ||
          !box.hasSize ||
          !identical(_nearestRoot(box), root)) {
        return null;
      }
      if (owner.offsetSpec?.requiresPositionedSurface == true &&
          _nativePositionedSurface(owner, box, root) == null) {
        return null;
      }
      return box;
    }

    // Ordinary parents remain unique current native ancestors. A proved
    // initial containing block can name the logical body outside its physical
    // out-of-flow branch; both owners still belong to this measured root.
    if (spec.parentId != null && measuredAncestor(spec.parentId) == null) {
      return null;
    }
    final position = _unscrolledOrigin(surface, root);
    if (position == null) return null;
    var origin = Offset.zero;
    if (spec.origin != NativeDocumentOffsetOrigin.initialContainingBlock) {
      final ancestor = measuredAncestor(spec.originId);
      if (ancestor == null) return null;
      final measured = _unscrolledOrigin(ancestor, root);
      if (measured == null) return null;
      origin = measured;
      if (spec.origin == NativeDocumentOffsetOrigin.paddingEdge) {
        final border = _borderInsets(ancestor);
        if (border == null) return null;
        origin += Offset(border.left, border.top);
      }
    }
    final offset = position - origin;
    if (!offset.dx.isFinite ||
        !offset.dy.isFinite ||
        offset.dx.abs() > 9007199254740990 ||
        offset.dy.abs() > 9007199254740990) {
      return null;
    }
    // CSSOM long rounding ties toward positive infinity, including negatives.
    return {
      'top': (offset.dy + .5).floor(),
      'left': (offset.dx + .5).floor(),
      'parentId': spec.parentId,
    };
  }

  void _attachRoot(_RenderNativeDocumentLayoutRoot root) {
    if (_disposed || identical(_root, root)) return;
    _root = root;
    _scheduleNotification();
  }

  void _detachRoot(_RenderNativeDocumentLayoutRoot root) {
    if (_disposed || !identical(_root, root)) return;
    _root = null;
    _scheduleNotification();
  }

  void _rootChanged(_RenderNativeDocumentLayoutRoot root) {
    if (_disposed || !identical(_root, root)) return;
    _scheduleNotification();
  }

  void _attachElement(_RenderNativeDocumentLayoutElement element) {
    if (_disposed) return;
    (_elements[element.id] ??=
            HashSet<_RenderNativeDocumentLayoutElement>.identity())
        .add(element);
    _scheduleNotification();
  }

  void _detachElement(_RenderNativeDocumentLayoutElement element) {
    if (_disposed) return;
    final owners = _elements[element.id];
    if (owners == null || !owners.remove(element)) return;
    if (owners.isEmpty) _elements.remove(element.id);
    _scheduleNotification();
  }

  void _elementChanged() {
    if (_disposed) return;
    _scheduleNotification();
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

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _root = null;
    _elements.clear();
    super.dispose();
  }
}

/// The result of a completed actual render-tree hit test in a native document.
///
/// [elementId] is null when the hit path contains no current, unambiguous
/// document element box, or when the point is outside the document content.
class NativeDocumentHitTest {
  const NativeDocumentHitTest({required this.elementId});

  final String? elementId;
}

/// Establishes the explicit coordinate space and ID set for one document.
class NativeDocumentLayoutRoot extends SingleChildRenderObjectWidget {
  NativeDocumentLayoutRoot({
    super.key,
    required this.controller,
    required this.revision,
    required Set<String> knownIds,
    Set<String> noBoxIds = const <String>{},
    Map<String, NativeDocumentComputedStyleSpec> computedStyles = const {},
    required super.child,
  }) : knownIds = Set<String>.unmodifiable(knownIds),
       noBoxIds = Set<String>.unmodifiable(noBoxIds),
       computedStyles =
           Map<String, NativeDocumentComputedStyleSpec>.unmodifiable(
             computedStyles,
           );

  final NativeDocumentLayoutController controller;
  final int revision;
  final Set<String> knownIds;
  final Set<String> noBoxIds;
  final Map<String, NativeDocumentComputedStyleSpec> computedStyles;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderNativeDocumentLayoutRoot(
        controller: controller,
        revision: revision,
        knownIds: knownIds,
        noBoxIds: noBoxIds,
        computedStyles: computedStyles,
      );

  @override
  void updateRenderObject(
    BuildContext context,
    covariant RenderObject renderObject,
  ) {
    (renderObject as _RenderNativeDocumentLayoutRoot).update(
      controller: controller,
      revision: revision,
      knownIds: knownIds,
      noBoxIds: noBoxIds,
      computedStyles: computedStyles,
    );
  }
}

class _RenderNativeDocumentLayoutRoot extends RenderProxyBox {
  _RenderNativeDocumentLayoutRoot({
    required this.controller,
    required this.revision,
    required this.knownIds,
    required this.noBoxIds,
    required this.computedStyles,
  });

  NativeDocumentLayoutController controller;
  int revision;
  Set<String> knownIds;
  Set<String> noBoxIds;
  Map<String, NativeDocumentComputedStyleSpec> computedStyles;
  int? laidOutRevision;
  bool pendingLayout = true;

  void update({
    required NativeDocumentLayoutController controller,
    required int revision,
    required Set<String> knownIds,
    required Set<String> noBoxIds,
    required Map<String, NativeDocumentComputedStyleSpec> computedStyles,
  }) {
    final ownerChanged = !identical(this.controller, controller);
    final changed =
        this.revision != revision ||
        !_sameIds(this.knownIds, knownIds) ||
        !_sameIds(this.noBoxIds, noBoxIds) ||
        !identical(this.computedStyles, computedStyles);
    if (!ownerChanged && !changed) return;

    if (ownerChanged) this.controller._detachRoot(this);
    this.controller = controller;
    this.revision = revision;
    this.knownIds = Set<String>.unmodifiable(knownIds);
    this.noBoxIds = Set<String>.unmodifiable(noBoxIds);
    this.computedStyles = computedStyles;
    laidOutRevision = null;
    if (ownerChanged && attached) controller._attachRoot(this);
    markNeedsLayout();
    controller._rootChanged(this);
  }

  @override
  void markNeedsLayout() {
    pendingLayout = true;
    super.markNeedsLayout();
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    pendingLayout = true;
    laidOutRevision = null;
    controller._attachRoot(this);
  }

  @override
  void detach() {
    pendingLayout = true;
    laidOutRevision = null;
    controller._detachRoot(this);
    super.detach();
  }

  @override
  void performLayout() {
    super.performLayout();
    pendingLayout = false;
    laidOutRevision = revision;
    controller._rootChanged(this);
  }
}

/// Associates an actual RenderBox with a native document element ID.
///
/// This is a transparent proxy: it leaves the child's constraints, size,
/// intrinsic dimensions, and baseline behavior unchanged.
class NativeDocumentLayoutElement extends SingleChildRenderObjectWidget {
  const NativeDocumentLayoutElement({
    super.key,
    required this.controller,
    required this.revision,
    required this.id,
    this.boxSurface,
    this.offsetSpec,
    required super.child,
  });

  final NativeDocumentLayoutController controller;
  final int revision;
  final String id;
  final RenderBox? Function(RenderBox)? boxSurface;
  final NativeDocumentOffsetSpec? offsetSpec;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderNativeDocumentLayoutElement(
        controller: controller,
        revision: revision,
        id: id,
        boxSurface: boxSurface,
        offsetSpec: offsetSpec,
      );

  @override
  void updateRenderObject(
    BuildContext context,
    covariant RenderObject renderObject,
  ) {
    (renderObject as _RenderNativeDocumentLayoutElement).update(
      controller: controller,
      revision: revision,
      id: id,
      boxSurface: boxSurface,
      offsetSpec: offsetSpec,
    );
  }
}

class _RenderNativeDocumentLayoutElement extends RenderProxyBox {
  _RenderNativeDocumentLayoutElement({
    required this.controller,
    required this.revision,
    required this.id,
    this.boxSurface,
    this.offsetSpec,
  });

  NativeDocumentLayoutController controller;
  int revision;
  String id;
  RenderBox? Function(RenderBox)? boxSurface;
  NativeDocumentOffsetSpec? offsetSpec;
  int? laidOutRevision;
  bool pendingLayout = true;

  void update({
    required NativeDocumentLayoutController controller,
    required int revision,
    required String id,
    RenderBox? Function(RenderBox)? boxSurface,
    NativeDocumentOffsetSpec? offsetSpec,
  }) {
    final ownerChanged = !identical(this.controller, controller);
    final registrationChanged = ownerChanged || this.id != id;
    final layoutChanged =
        registrationChanged ||
        this.revision != revision ||
        this.boxSurface != boxSurface ||
        this.offsetSpec != offsetSpec;
    if (registrationChanged) {
      this.controller._detachElement(this);
      this.controller = controller;
      this.id = id;
      if (attached) controller._attachElement(this);
    }
    if (!layoutChanged) return;
    this.boxSurface = boxSurface;
    this.offsetSpec = offsetSpec;
    this.revision = revision;
    laidOutRevision = null;
    markNeedsLayout();
    controller._elementChanged();
  }

  @override
  void markNeedsLayout() {
    pendingLayout = true;
    super.markNeedsLayout();
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    pendingLayout = true;
    laidOutRevision = null;
    controller._attachElement(this);
  }

  @override
  void detach() {
    pendingLayout = true;
    laidOutRevision = null;
    controller._detachElement(this);
    super.detach();
  }

  @override
  void performLayout() {
    super.performLayout();
    pendingLayout = false;
    laidOutRevision = revision;
    controller._elementChanged();
  }
}

_RenderNativeDocumentLayoutRoot? _nearestRoot(RenderObject element) {
  RenderObject? current = element;
  while (current != null) {
    if (current is _RenderNativeDocumentLayoutRoot) return current;
    current = current.parent;
  }
  return null;
}

({
  RenderBox surface,
  Offset offset,
  bool viewportFixed,
  bool initialContainingBlock,
})?
_nativePositionedSurface(
  _RenderNativeDocumentLayoutElement element,
  RenderBox surface,
  _RenderNativeDocumentLayoutRoot root,
) {
  RenderObject? current = surface;
  while (current != null && !identical(current, root)) {
    final geometry = nativeDocumentPositionedLayout(current);
    if (geometry != null && current is RenderBox) {
      return (
        surface: current,
        offset: geometry.offset,
        viewportFixed: geometry.fixedToViewport,
        initialContainingBlock: geometry.initialContainingBlock,
      );
    }
    if (current is _RenderNativeDocumentLayoutElement &&
        !identical(current, element)) {
      return null;
    }
    current = current.parent;
  }
  return null;
}

Offset? _unscrolledOrigin(RenderBox element, RenderBox root) {
  var position = Offset.zero;
  RenderObject current = element;
  try {
    while (!identical(current, root)) {
      final parent = current.parent;
      if (parent == null) return null;
      // CSS paint transforms do not enter CSSOM offset layout coordinates.
      // Keep relative/positioned native offsets and remove each actual scroll
      // translation in its local layout space, without inverting paint bounds.
      if (!nativeDocumentIsCssTransform(parent)) {
        final matrix = Matrix4.identity();
        parent.applyPaintTransform(current, matrix);
        final translation = MatrixUtils.getAsTranslation(matrix);
        if (translation == null) return null;
        position += translation;
      }
      position += nativeDocumentScrollTranslation(parent);
      current = parent;
    }
  } on FlutterError {
    return null;
  }
  return position;
}

EdgeInsets? _borderInsets(RenderBox element) {
  final borders = <EdgeInsets>[];
  var unresolvedBorder = false;

  void visit(RenderObject current, {required bool isElement}) {
    if (!isElement && current is _RenderNativeDocumentLayoutElement) return;
    if (current is RenderDecoratedBox && current.decoration is BoxDecoration) {
      final decoration = current.decoration as BoxDecoration;
      final border = decoration.border;
      if (border != null) {
        final dimensions = border.dimensions;
        final direction = current.configuration.textDirection;
        if (direction == null && dimensions is! EdgeInsets) {
          unresolvedBorder = true;
        } else {
          try {
            final resolved = dimensions.resolve(direction ?? TextDirection.ltr);
            if (resolved.left > 0 ||
                resolved.top > 0 ||
                resolved.right > 0 ||
                resolved.bottom > 0) {
              borders.add(resolved);
            }
          } on Object {
            unresolvedBorder = true;
          }
        }
      }
    }
    current.visitChildren((child) => visit(child, isElement: false));
  }

  visit(element, isElement: true);
  if (unresolvedBorder || borders.length > 1) return null;
  return borders.isEmpty ? EdgeInsets.zero : borders.single;
}

Map<String, dynamic>? _clientMetrics(RenderBox element) {
  final border = _borderInsets(element);
  if (border == null) return null;
  final clientWidth = (element.size.width - border.left - border.right).clamp(
    0.0,
    double.infinity,
  );
  final clientHeight = (element.size.height - border.top - border.bottom).clamp(
    0.0,
    double.infinity,
  );
  return <String, dynamic>{
    'clientLeft': border.left.round(),
    'clientTop': border.top.round(),
    'clientWidth': clientWidth.round(),
    'clientHeight': clientHeight.round(),
  };
}

bool _sameIds(Set<String> left, Set<String> right) {
  if (identical(left, right)) return true;
  if (left.length != right.length) return false;
  return left.containsAll(right);
}

// Styles are optional alongside geometry: a large document must keep working
// when its computed declarations exceed the scripting packet's style budget.
void _attachComputedStyles(
  List<Map<String, dynamic>> boxes,
  Map<String, NativeDocumentComputedStyleSpec> specs,
  Map<String, RenderBox> surfaces,
  Size viewport,
) {
  var remaining = 2 * 1024 * 1024;
  for (final box in boxes) {
    final id = box['id'] as String;
    final spec = specs[id];
    if (spec == null) continue;
    if (box['kind'] == 'box' &&
        surfaces.containsKey(id) &&
        spec.available &&
        spec.canvasBitmapSizeIndependent) {
      box['canvasBitmapSizeIndependent'] = true;
    }
    if (box['kind'] == 'box' &&
        surfaces.containsKey(id) &&
        spec.available &&
        spec.clientWidthIndependentOfDescendantSizes &&
        box['clientWidth'] is num) {
      box['clientWidthIndependentOfDescendantSizes'] = true;
    }
    final exactDimensions = <String, double>{};
    var positionedAutoInsets = const <String, double>{};
    final styleSurface = surfaces[id];
    if (styleSurface != null &&
        const {'absolute', 'fixed'}.contains(spec.values['position'])) {
      final root = _nearestRoot(styleSurface);
      for (
        RenderObject? current = styleSurface;
        current != null;
        current = current.parent
      ) {
        if (current is! _RenderNativeDocumentLayoutElement) continue;
        if (current.id == id && root != null) {
          final positioned = _nativePositionedSurface(
            current,
            styleSurface,
            root,
          );
          if (positioned != null) {
            positionedAutoInsets =
                nativeDocumentPositionedLayout(
                  positioned.surface,
                )?.autoInsets ??
                const {};
          }
        }
        break;
      }
    }
    final values = _resolvedComputedStyles(
      spec,
      surfaces[id],
      viewport,
      noBox: box['kind'] == 'none',
      positionedAutoInsets: positionedAutoInsets,
      onUsedDimension: spec.canvasEquivalentStyleWrites
          ? (name, value) => exactDimensions[name] = value
          : null,
    );
    final resize = _resizeMetrics(spec, surfaces[id], values, box['kind']);
    if (resize != null) box['resize'] = resize;
    if (!spec.available || values.length > 256) continue;
    final accepted = <String, String>{};
    var valid = true;
    var size = 0;
    for (final entry in values.entries) {
      if (entry.key.length > 128 ||
          entry.value.length > 4096 ||
          RegExp(r'[\x00-\x08\x0b\x0e-\x1f\x7f]').hasMatch(entry.value) ||
          !RegExp(
            r'^(?:--[a-zA-Z0-9_-]+|-?[a-z][a-z0-9-]*)$',
          ).hasMatch(entry.key)) {
        valid = false;
        break;
      }
      final cost = entry.key.length + entry.value.length;
      if (size + cost > 16 * 1024) {
        valid = false;
        break;
      }
      accepted[entry.key] = entry.value;
      size += cost;
    }
    // Never truncate a declaration: dropping a custom property would make
    // its read incorrectly look like an unset property instead of unavailable.
    if (!valid) continue;
    // Count encoded bytes too: non-ASCII custom values and JSON escapes must
    // not push the complete host response beyond its 4 MiB envelope.
    final textIndependent = spec.textContentSelectorsIndependent
        ? [
            for (final entry in spec.values.entries)
              if (accepted[entry.key] == entry.value) entry.key,
          ]
        : const <String>[];
    final encodedSize =
        utf8.encode(jsonEncode(accepted)).length +
        (textIndependent.isEmpty
            ? 0
            : utf8.encode(jsonEncode(textIndependent)).length);
    final cost = encodedSize > size ? encodedSize : size;
    if (cost > remaining) continue;
    remaining -= cost;
    box['computedStyle'] = accepted;
    if (textIndependent.isNotEmpty) {
      box['textIndependentStyleProperties'] = textIndependent;
    }
    // CSSOM serializes dimensions to six decimals. Never use a rounded value
    // as proof of an identical used size: even a tiny change can wrap a line.
    if (box['kind'] == 'box' &&
        surfaces.containsKey(id) &&
        spec.canvasEquivalentStyleWrites &&
        exactDimensions.length == 2 &&
        const ['width', 'height'].every((name) {
          final value = accepted[name];
          return value != null &&
              value.endsWith('px') &&
              double.tryParse(value.substring(0, value.length - 2)) ==
                  exactDimensions[name];
        })) {
      box['canvasEquivalentStyleWrites'] = true;
      if (spec.replacedBoxStyleProjection) {
        box['replacedBoxStyleProjection'] = true;
      }
    }
  }
  final byId = {for (final box in boxes) box['id']: box};
  for (final box in boxes) {
    final childId = specs[box['id']]?.fixedBlockChildId;
    final child = byId[childId];
    final childStyle = child?['computedStyle'];
    final childSpec = specs[childId];
    final content = (box['resize'] as Map?)?['contentRect'] as Map?;
    final intrinsic = childSpec?.canvasIntrinsicSize;
    if (box['kind'] == 'box' &&
        box['computedStyle'] is Map &&
        child?['kind'] == 'box' &&
        childStyle is Map &&
        childSpec?.canvasSizingProjection == true &&
        content != null &&
        intrinsic != null) {
      final width = childSpec!.lengths['width'] ?? 'auto';
      final height = childSpec.lengths['height'] ?? 'auto';
      final used = nativeCanvasCssUsedSize(
        cssWidth: width,
        cssHeight: height,
        parentWidth: (content['width'] as num).toDouble(),
        parentHeight: (content['height'] as num).toDouble(),
        intrinsicWidth: intrinsic.width,
        intrinsicHeight: intrinsic.height,
      );
      double? pixels(String key) {
        final raw = childStyle[key];
        return raw is String && raw.endsWith('px')
            ? double.tryParse(raw.substring(0, raw.length - 2))
            : null;
      }

      double cssPrecision(double value) =>
          (value * 1000000).roundToDouble() / 1000000;
      if (used != null &&
          pixels('width') == cssPrecision(used.width) &&
          pixels('height') == cssPrecision(used.height)) {
        child!['canvasSizingProjection'] = {
          'parentId': box['id'],
          'width': width,
          'height': height,
        };
      }
    }
    if (box['kind'] == 'box' &&
        box['computedStyle'] is Map &&
        (child?['replacedBoxStyleProjection'] == true ||
            child?['canvasSizingProjection'] is Map) &&
        childStyle is Map &&
        const [
          'margin-top',
          'margin-right',
          'margin-bottom',
          'margin-left',
        ].every((name) => childStyle[name] == '0px')) {
      box['stableReplacedChildId'] = childId;
    }
  }
}

// Dimensions are captured from the owned native surface before transforms.
// Missing edges withhold observer data; integer client/offset sizes and authored
// width/height are not substitutes for a measured content box.
Map<String, dynamic>? _resizeMetrics(
  NativeDocumentComputedStyleSpec spec,
  RenderBox? surface,
  Map<String, String> values,
  Object? kind,
) {
  if (!spec.resizeSupported) return null;
  final display = values['display'];
  if (kind == 'none' ||
      display == 'contents' ||
      (display == 'inline' && !spec.isReplaced)) {
    return {'kind': 'none'};
  }
  if (kind != 'box' || surface == null || display == null) return null;
  double? pixels(String name) {
    final raw = values[name];
    if (raw == null || !raw.endsWith('px')) return null;
    final value = double.tryParse(raw.substring(0, raw.length - 2));
    return value != null && value.isFinite && value >= 0 ? value : null;
  }

  final padding = <String, double?>{
    for (final side in const ['left', 'right', 'top', 'bottom'])
      side: pixels('padding-$side'),
  };
  final border = <String, double?>{
    for (final side in const ['left', 'right', 'top', 'bottom'])
      side: pixels('border-$side-width'),
  };
  if (padding.values.any((value) => value == null) ||
      border.values.any((value) => value == null)) {
    return null;
  }
  final contentWidth =
      (surface.size.width -
              padding['left']! -
              padding['right']! -
              border['left']! -
              border['right']!)
          .clamp(0.0, double.infinity);
  final contentHeight =
      (surface.size.height -
              padding['top']! -
              padding['bottom']! -
              border['top']! -
              border['bottom']!)
          .clamp(0.0, double.infinity);
  return {
    'kind': 'box',
    'contentRect': {
      'x': padding['left']!,
      'y': padding['top']!,
      'width': contentWidth,
      'height': contentHeight,
    },
    'borderBoxSize': {
      'inlineSize': surface.size.width,
      'blockSize': surface.size.height,
    },
  };
}

Map<String, String> _resolvedComputedStyles(
  NativeDocumentComputedStyleSpec spec,
  RenderBox? surface,
  Size viewport, {
  required bool noBox,
  Map<String, double> positionedAutoInsets = const {},
  void Function(String, double)? onUsedDimension,
}) {
  final values = Map<String, String>.of(spec.values);
  final metrics = surface == null
      ? null
      : nativeDocumentComputedBoxMetrics(surface);
  final containing = metrics == null && spec.isReplaced && surface != null
      ? nativeDocumentContainingBlockMetrics(surface)
      : null;
  final containingWidth = metrics?.containingWidth ?? containing?.width;
  final usedContainingHeight =
      metrics?.usedContainingHeight ?? containing?.usedHeight;
  double? length(String raw, {double? basis}) {
    final value = nativeComputedCssLength(
      raw,
      fontSize: spec.fontSize,
      rootFontSize: spec.rootFontSize,
      viewportWidth: viewport.width,
      viewportHeight: viewport.height,
      percentageBasis: basis,
    );
    return value != null && value.isFinite && value.abs() <= 9007199254740990
        ? value
        : null;
  }

  String px(double value) {
    final rounded = (value * 1000000).roundToDouble() / 1000000;
    return '${rounded == rounded.truncateToDouble() ? rounded.toInt() : rounded}px';
  }

  String? computedLength(
    String raw, {
    double? basis,
    bool preservePercent = false,
  }) {
    final normalized = raw.trim().toLowerCase();
    if (normalized == 'auto' || normalized == 'none') return normalized;
    if (preservePercent &&
        normalized.endsWith('%') &&
        double.tryParse(normalized.substring(0, normalized.length - 1)) !=
            null) {
      return normalized;
    }
    final resolved = length(raw, basis: basis);
    return resolved == null ||
            !resolved.isFinite ||
            resolved.abs() > 9007199254740990
        ? null
        : px(resolved);
  }

  final display = values['display'];
  // Use the owned untransformed border box, never the axis-aligned paint bounds.
  // No-box nodes retain percentage origins and have no used transform matrix.
  if (noBox || (surface != null && (display != 'inline' || spec.isReplaced))) {
    final size = noBox ? null : surface?.size;
    final origin = spec.transformOrigin == null
        ? null
        : NativeDocumentTransformSpec.computedOrigin(
            spec.transformOrigin,
            size: size,
            fontSize: spec.fontSize,
            viewport: viewport,
          );
    if (origin != null) values['transform-origin'] = origin;
    final raw = spec.transform;
    String? transform;
    if (raw != null) {
      if (noBox || raw == 'none') {
        transform = 'none';
      } else if (size != null) {
        transform = NativeDocumentTransformSpec.parse(
          raw,
          origin: spec.transformOrigin,
        )?.computedMatrix(size, fontSize: spec.fontSize, viewport: viewport);
      }
    }
    if (transform != null) values['transform'] = transform;
  }
  final usesComputedDimensions =
      noBox ||
      (display == 'inline' && !spec.isReplaced) ||
      display == 'contents';
  for (final entry in spec.lengths.entries) {
    final name = entry.key;
    if (const {'top', 'right', 'bottom', 'left'}.contains(name)) continue;
    final dimension = name == 'width' || name == 'height';
    if (dimension && !usesComputedDimensions) continue;
    final isMarginOrPadding =
        name.startsWith('margin-') || name.startsWith('padding-');
    if (!noBox && name.startsWith('margin-') && entry.value == 'auto') continue;
    final basis = isMarginOrPadding ? containingWidth : null;
    final value = computedLength(
      entry.value,
      basis: basis,
      preservePercent: noBox || !isMarginOrPadding,
    );
    if (value != null) values[name] = value;
  }
  // Real border-box dimensions include native constraints, min/max sizes,
  // flex/grid allocation, and fractional padding. Never use authored width
  // as a substitute for the result of layout.
  if (!noBox && surface != null && (metrics != null || spec.isReplaced)) {
    final borderBox = values['box-sizing'] == 'border-box';
    final borders = <String, double?>{
      for (final side in const ['top', 'right', 'bottom', 'left'])
        side: values['border-$side-width'] == null
            ? null
            : length(values['border-$side-width']!),
    };
    final padding = <String, double?>{
      for (final side in const ['top', 'right', 'bottom', 'left'])
        side: values['padding-$side'] == null
            ? null
            : length(values['padding-$side']!),
    };
    // Core HTML applies UA padding (for example the list's 40px indent)
    // outside the author's sizing declarations. Include those known edges
    // when turning the measured border box into a CSS content-box dimension.
    final knownEdges =
        padding.values.every((value) => value != null) &&
        borders.values.every((value) => value != null);
    final horizontalEdges = knownEdges
        ? borders['left']! +
              borders['right']! +
              padding['left']! +
              padding['right']!
        : metrics?.horizontalEdges;
    final verticalEdges = knownEdges
        ? borders['top']! +
              borders['bottom']! +
              padding['top']! +
              padding['bottom']!
        : metrics?.verticalEdges;
    if (borderBox || horizontalEdges != null) {
      final width = surface.size.width - (borderBox ? 0 : horizontalEdges!);
      if (width.isFinite) {
        final used = width.clamp(0, double.infinity).toDouble();
        values['width'] = px(used);
        onUsedDimension?.call('width', used);
      }
    }
    if (borderBox || verticalEdges != null) {
      final height = surface.size.height - (borderBox ? 0 : verticalEdges!);
      if (height.isFinite) {
        final used = height.clamp(0, double.infinity).toDouble();
        values['height'] = px(used);
        onUsedDimension?.call('height', used);
      }
    }
  }
  final relative = values['position'] == 'relative' && !noBox;
  for (final pair in const [
    ['left', 'right'],
    ['top', 'bottom'],
  ]) {
    if (!spec.lengths.containsKey(pair[0]) ||
        !spec.lengths.containsKey(pair[1])) {
      continue;
    }
    final basis = pair.first == 'left' ? containingWidth : usedContainingHeight;
    double? resolved(String name) {
      final raw = spec.lengths[name] ?? 'auto';
      return raw == 'auto' ? null : length(raw, basis: basis);
    }

    if (relative) {
      final first = resolved(pair[0]);
      final second = resolved(pair[1]);
      // CSSOM resolves percentage insets against the containing block
      // used height, even when CSS2 paint displacement treats it as auto.
      // Unsupported syntax stays unavailable.
      bool supported(String name) {
        final raw = spec.lengths[name] ?? 'auto';
        return raw == 'auto' || length(raw, basis: basis) != null;
      }

      if (supported(pair[0]) && supported(pair[1])) {
        values[pair[0]] = px(first ?? (second == null ? 0 : -second));
        values[pair[1]] = px(second ?? (first == null ? 0 : -first));
      }
    } else {
      for (final name in pair) {
        final measured = positionedAutoInsets[name];
        final value =
            (spec.lengths[name] ?? 'auto') == 'auto' && measured != null
            ? px(measured)
            : computedLength(
                spec.lengths[name] ?? 'auto',
                preservePercent: true,
              );
        if (value != null) values[name] = value;
      }
    }
  }
  return values;
}

typedef NativeDocumentFocusCaret = ({String id, RenderBox surface, Rect rect});
