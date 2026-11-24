import 'package:flutter/widgets.dart';
import 'package:html/dom.dart' as dom;
import 'document_computed_styles.dart';

/// DOM identity/cascade metadata; geometry always comes from completed layout.
class NativeDocumentScrollAnchorNode {
  NativeDocumentScrollAnchorNode({
    required this.id,
    required this.parent,
    required this.excluded,
    required this.ownExcluded,
    required this.overflowAnchorNone,
    required this.rendered,
    required this.candidate,
    required this.scrollContainer,
    required this.position,
    required this.suppression,
  });
  final String id;
  final String? parent;
  final bool excluded, candidate, scrollContainer;
  final bool ownExcluded, overflowAnchorNone, rendered;
  final String position;
  final Map<String, String?> suppression;
}

Map<String, NativeDocumentScrollAnchorNode> nativeDocumentScrollAnchorNodes({
  required dom.Document document,
  required Map<dom.Element, Map<String, String>> stylesByElement,
  required Map<String, NativeDocumentComputedStyleSpec> computedStyles,
}) {
  final result = <String, NativeDocumentScrollAnchorNode>{};
  final excluded = <dom.Element, bool>{};
  final rendered = <dom.Element, bool>{};
  final anchorPolicy = <dom.Element, String>{};
  for (final e in document.querySelectorAll('*')) {
    final id = e.attributes['data-pirc-script-id'];
    final css = stylesByElement[e] ?? const <String, String>{};
    final spec = computedStyles[id];
    final display = spec?.values['display'];
    final position = spec?.values['position'] ?? 'static';
    final authoredAnchor = css['overflow-anchor']?.trim().toLowerCase();
    final inheritAnchor = authoredAnchor == 'inherit'
        ? anchorPolicy[e.parent] ?? 'auto'
        : authoredAnchor ?? 'auto';
    anchorPolicy[e] = inheritAnchor;
    final ownExcluded =
        inheritAnchor == 'none' ||
        display == 'none' ||
        position == 'fixed' ||
        position == 'sticky' ||
        !const {'', 'none'}.contains(css['transform'] ?? '') ||
        !const {
          '',
          'horizontal-tb',
          'initial',
          'inherit',
          'unset',
        }.contains(css['writing-mode'] ?? '');
    final blocked = (excluded[e.parent] ?? false) || ownExcluded;
    final hasBoxPath =
        (rendered[e.parent] ?? true) &&
        display != 'none' &&
        !e.attributes.containsKey('hidden');
    rendered[e] = hasBoxPath;
    excluded[e] = blocked;
    if (id == null || spec == null) continue;
    var ancestor = e.parent;
    while (ancestor != null &&
        !ancestor.attributes.containsKey('data-pirc-script-id')) {
      ancestor = ancestor.parent;
    }
    result[id] = NativeDocumentScrollAnchorNode(
      id: id,
      parent: ancestor?.attributes['data-pirc-script-id'],
      excluded: blocked,
      ownExcluded: ownExcluded,
      overflowAnchorNone: inheritAnchor == 'none',
      rendered: hasBoxPath,
      candidate: display != null && (display != 'inline' || spec.isReplaced),
      scrollContainer: [
        'overflow',
        'overflow-x',
        'overflow-y',
      ].any((key) => const {'auto', 'scroll', 'hidden'}.contains(css[key])),
      position: position,
      suppression: {
        for (final key in const [
          'top',
          'right',
          'bottom',
          'left',
          'width',
          'height',
          'min-width',
          'max-width',
          'min-height',
          'max-height',
          'margin-top',
          'margin-right',
          'margin-bottom',
          'margin-left',
          'padding-top',
          'padding-right',
          'padding-bottom',
          'padding-left',
        ])
          key: spec.lengths[key],
        'position': position,
        'transform': css['transform'] ?? 'none',
      },
    );
  }
  return result;
}

/// A document-owned position preserves its scroll activity during compensation.
/// The host publishes layout only after the corrected native frame is painted.
class NativeDocumentScrollController extends ScrollController {
  NativeDocumentScrollController({
    super.initialScrollOffset,
    super.keepScrollOffset,
    super.debugLabel,
    super.onAttach,
    super.onDetach,
  });
  double? _detachedOffset;

  /// Last unambiguous position, including after the view has detached.
  double? get lastKnownOffset {
    if (positions.isEmpty) return _detachedOffset;
    if (positions.length != 1 || !position.hasPixels) return null;
    return position.pixels.isFinite ? position.pixels : null;
  }

  @override
  void detach(ScrollPosition position) {
    if (keepScrollOffset &&
        positions.length == 1 &&
        position.hasPixels &&
        position.pixels.isFinite) {
      _detachedOffset = position.pixels;
    }
    super.detach(position);
  }

  void correctAnchorOffset(double target) {
    if (positions.length != 1) return;
    final position = this.position;
    if (position is _DocumentAnchorScrollPosition) {
      position.correctAnchorOffset(target);
    }
  }

  @override
  ScrollPosition createScrollPosition(
    ScrollPhysics physics,
    ScrollContext context,
    ScrollPosition? oldPosition,
  ) => _DocumentAnchorScrollPosition(
    physics: physics,
    context: context,
    // A remounted view may have a new PageStorage bucket. Keep the position
    // with the document, while respecting explicit keepScrollOffset opt-out.
    initialPixels: keepScrollOffset
        ? lastKnownOffset ?? initialScrollOffset
        : initialScrollOffset,
    keepScrollOffset: keepScrollOffset,
    oldPosition: oldPosition,
    debugLabel: debugLabel,
  );
}

class _DocumentAnchorScrollPosition extends ScrollPositionWithSingleContext {
  _DocumentAnchorScrollPosition({
    required super.physics,
    required super.context,
    required super.initialPixels,
    required super.keepScrollOffset,
    super.oldPosition,
    super.debugLabel,
  });
  void correctAnchorOffset(double target) {
    final delta = target - pixels;
    if (delta == 0) return;
    forcePixels(target);
    // A ballistic activity restarts from the corrected position at its current
    // velocity; dragging/idle activities retain their normal state.
    activity?.applyNewDimensions();
    didUpdateScrollPositionBy(delta);
  }
}

/// Updated during the document cascade build, before its render objects lay out.
class NativeDocumentScrollAnchorData {
  Map<String, NativeDocumentScrollAnchorNode> nodes = const {};
  bool settled = true;
}

/// One vertical scroll box's completed-frame anchor history. Root and element
/// viewports share selection, suppression, removal and clamping semantics.
class NativeDocumentScrollAnchorState {
  String? _anchor;
  double _pixels = 0, _left = 0;
  double? _savedRelativeY;
  Size? _viewport;
  Map<String, NativeDocumentScrollAnchorNode> _previous = const {};
  Map<String, Rect> _previousBoxes = const {};
  Map<String, Rect> _previousClips = const {};
  Map<String, Rect> _previousLayout = const {};
  void reset() {
    _anchor = null;
    _pixels = 0;
    _left = 0;
    _viewport = null;
    _previous = const {};
    _previousBoxes = const {};
    _previousClips = const {};
    _previousLayout = const {};
    _savedRelativeY = null;
  }

  void didScroll({required double top, double left = 0}) {
    _anchor = null;
    final viewport = _viewport;
    if (viewport == null) return;
    _pixels = top;
    _left = left;
    _anchor = _select(
      _previousBoxes,
      _previous,
      Rect.fromLTWH(left, top, viewport.width, viewport.height),
      _previousClips,
    );
    _savedRelativeY = _previousBoxes[_anchor]?.top;
    if (_savedRelativeY != null) _savedRelativeY = _savedRelativeY! - top;
  }

  void shiftDescendants(
    Set<String> ids,
    Offset shift, {
    bool reselect = false,
  }) {
    _previousBoxes = {
      for (final entry in _previousBoxes.entries)
        entry.key: ids.contains(entry.key)
            ? entry.value.shift(shift)
            : entry.value,
    };
    _previousClips = {
      for (final entry in _previousClips.entries)
        entry.key: ids.contains(entry.key)
            ? entry.value.shift(shift)
            : entry.value,
    };
    if (reselect) didScroll(top: _pixels, left: _left);
  }

  bool _suppressed(
    String id,
    Map<String, NativeDocumentScrollAnchorNode> nodes,
  ) {
    for (final entry in nodes.entries) {
      final old = _previous[entry.key];
      if (old != null &&
          (old.position == 'absolute') !=
              (entry.value.position == 'absolute')) {
        return true;
      }
    }
    String? current = id;
    final seen = <String>{};
    while (current != null && seen.add(current)) {
      final old = _previous[current], now = nodes[current];
      if (old == null ||
          now == null ||
          now.excluded ||
          old.parent != now.parent) {
        return true;
      }
      for (final entry in old.suppression.entries) {
        if (now.suppression[entry.key] != entry.value) return true;
      }
      current = now.parent;
    }
    return false;
  }

  String? _select(
    Map<String, Rect> boxes,
    Map<String, NativeDocumentScrollAnchorNode> nodes,
    Rect region, [
    Map<String, Rect> clips = const {},
  ]) {
    final children = <String?, List<String>>{};
    for (final node in nodes.values) {
      (children[node.parent] ??= []).add(node.id);
    }
    final visited = <String>{};
    String? examine(String id, Rect visible) {
      if (!visited.add(id)) return null;
      final node = nodes[id]!;
      if (node.excluded) return null;
      final box = boxes[id];
      if (box != null) {
        if (box.isEmpty || !box.overlaps(visible)) return null;
        if (node.candidate &&
            visible.contains(box.topLeft) &&
            box.right <= visible.right &&
            box.bottom <= visible.bottom) {
          return id;
        }
      }
      final clip = clips[id];
      final childRegion = clip == null ? visible : visible.intersect(clip);
      if (!childRegion.isEmpty) {
        for (final child in children[id] ?? const <String>[]) {
          final found = examine(child, childRegion);
          if (found != null) return found;
        }
      }
      return box != null && node.candidate ? id : null;
    }

    for (final id in children[null] ?? const <String>[]) {
      final found = examine(id, region);
      if (found != null) return found;
    }
    return null;
  }

  bool _sameLayout(Map<String, Rect> a, Map<String, Rect> b) {
    if (a.length != b.length) return false;
    for (final entry in a.entries) {
      final other = b[entry.key];
      if (other == null) return false;
      if ((entry.value.left - other.left).abs() > 1e-6 ||
          (entry.value.top - other.top).abs() > 1e-6 ||
          (entry.value.width - other.width).abs() > 1e-6 ||
          (entry.value.height - other.height).abs() > 1e-6) {
        return false;
      }
    }
    return true;
  }

  double adjust({
    required Map<String, NativeDocumentScrollAnchorNode> nodes,
    required Map<String, Rect> boxes,
    Map<String, Rect> clips = const {},
    Map<String, Rect>? layoutBoxes,
    required Size viewport,
    required double pixels,
    required double min,
    required double max,
    double left = 0,
  }) {
    final pureLayout = layoutBoxes ?? boxes;
    final layoutChanged = !_sameLayout(pureLayout, _previousLayout);
    final first = _viewport == null, resized = !first && _viewport != viewport;
    var target = pixels;
    var old = resized ? null : _anchor;
    var relative = resized ? null : _savedRelativeY;
    if (old != null &&
        (!boxes.containsKey(old) || nodes[old]?.excluded != false)) {
      old = _select(
        _previousBoxes,
        nodes,
        Rect.fromLTWH(left, _pixels, viewport.width, viewport.height),
        _previousClips,
      );
      relative = old == null ? null : _previousBoxes[old]!.top - _pixels;
    } else if (old == null &&
        !resized &&
        layoutChanged &&
        _previousBoxes.isNotEmpty &&
        _pixels > min) {
      old = _select(
        _previousBoxes,
        nodes,
        Rect.fromLTWH(left, _pixels, viewport.width, viewport.height),
        _previousClips,
      );
      relative = old == null ? null : _previousBoxes[old]!.top - _pixels;
    }
    var suppressed = false;
    if (!resized &&
        layoutChanged &&
        old != null &&
        relative != null &&
        _pixels > min &&
        boxes.containsKey(old)) {
      final wanted = boxes[old]!.top - relative;
      if (wanted.isFinite) {
        suppressed =
            _suppressed(old, nodes) && ((wanted - pixels).abs() > 1e-6);
        if (!suppressed) target = wanted.clamp(min, max);
      }
    }
    if (suppressed) {
      old = null;
      relative = null;
    } else if (old == null && (first || resized || layoutChanged)) {
      old = _select(
        boxes,
        nodes,
        Rect.fromLTWH(left, target, viewport.width, viewport.height),
        clips,
      );
      relative = old == null ? null : boxes[old]!.top - target;
    }
    _anchor = old;
    _savedRelativeY = relative;
    _previousBoxes = boxes;
    _previousClips = clips;
    _previousLayout = pureLayout;
    _left = left;
    _pixels = target;
    _viewport = viewport;
    _previous = nodes;
    return target;
  }
}

/// A nested scroll box starts a new exclusion scope. overflow-anchor:none on
/// an outer ancestor excludes it from that ancestor's anchor search, but does
/// not disable this scroll box unless the box itself opts out.
Map<String, NativeDocumentScrollAnchorNode> nativeDocumentScrollAnchorScope(
  Map<String, NativeDocumentScrollAnchorNode> all,
  String ownerId,
) {
  final owner = all[ownerId];
  if (owner == null) return const {};
  final scoped = <String, NativeDocumentScrollAnchorNode>{};
  for (final n in all.values) {
    if (n.id != ownerId && !scoped.containsKey(n.parent)) continue;
    final isOwner = n.id == ownerId;
    final blocked = isOwner
        ? n.overflowAnchorNone || !n.rendered
        : scoped[n.parent]!.excluded || n.ownExcluded;
    scoped[n.id] = NativeDocumentScrollAnchorNode(
      id: n.id,
      parent: isOwner ? null : n.parent,
      excluded: blocked,
      ownExcluded: n.ownExcluded,
      overflowAnchorNone: n.overflowAnchorNone,
      rendered: n.rendered,
      candidate: !isOwner && n.candidate,
      scrollContainer: !isOwner && n.scrollContainer,
      position: n.position,
      suppression: n.suppression,
    );
  }
  return scoped;
}

/// Completed native flow boxes and actual scrollport clips in one coordinate
/// space. Clips may be unbounded along an axis that does not clip overflow.
class NativeDocumentScrollAnchorFrame {
  const NativeDocumentScrollAnchorFrame(
    this.boxes,
    this.clips, [
    Map<String, Rect>? layoutBoxes,
  ]) : layoutBoxes = layoutBoxes ?? boxes;
  final Map<String, Rect> boxes;
  final Map<String, Rect> clips;
  final Map<String, Rect> layoutBoxes;
}

typedef NativeDocumentScrollAnchorPort = ({
  RenderBox surface,
  bool clipX,
  bool clipY,
});
typedef NativeDocumentScrollAnchorCapture =
    NativeDocumentScrollAnchorFrame? Function(
      Set<String> ids,
      RenderBox? relativeTo,
      Offset contentOffset,
    );
