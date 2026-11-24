import 'render_l10n.dart';
import 'dart:math' as math;
import 'dart:ui';

class NativeDocumentRevealAction {
  const NativeDocumentRevealAction(this.elementId, this.destination);
  final String? elementId;
  final Offset destination;
}

/// Plans a standard fragment reveal against one completed native layout.
/// Every destination is computed before any native scroll action is applied.
List<NativeDocumentRevealAction> nativeDocumentRevealPlan(
  Map<String, dynamic> packet,
  String id,
  String rootId, {
  bool centerFocus = false,
}) {
  if (!centerFocus) return _nativeDocumentRevealPlan(packet, id, rootId);
  final focusPlan = _nativeDocumentRevealPlan(packet, id, rootId, focus: true);
  if (focusPlan.isEmpty) return focusPlan;
  // Focus can center a newly focused target before the fragment's start/nearest
  // reveal. Translate only our own planned scrolls through proven native axes;
  // DOM/focus handlers have already completed before this measurement. Apply
  // the final destinations once, so native caret reveal cannot compete with it.
  final boxes = [
    for (final raw in packet['boxes'] as List)
      Map<String, dynamic>.from(raw as Map),
  ];
  final byId = {for (final box in boxes) box['id'] as String: box};
  final target = byId[id]!;
  final proof = Map<String, dynamic>.from(target['scrollReveal'] as Map);
  final ports = [
    for (final raw in proof['ports'] as List)
      {
        ...Map<String, dynamic>.from(raw as Map),
        'origin': List<num>.from(raw['origin'] as List),
      },
  ];
  proof['ports'] = ports;
  target['scrollReveal'] = proof;
  final viewport = Map<String, dynamic>.from(packet['viewport'] as Map);
  for (final action in focusPlan) {
    final owner = byId[action.elementId ?? rootId];
    // A following fragment reveal supersedes a not-yet-ticked smooth focus
    // command. Instant focus effects are already positions; smooth goals are not.
    if ((owner?['computedStyle'] as Map?)?['scroll-behavior'] == 'smooth') {
      continue;
    }
    if (action.elementId == null) {
      viewport['scrollX'] = action.destination.dx;
      viewport['scrollY'] = action.destination.dy;
      continue;
    }
    final index = ports.indexWhere((p) => p['id'] == action.elementId);
    final metrics = Map<String, dynamic>.from(
      byId[action.elementId]!['scroll'] as Map,
    );
    byId[action.elementId]!['scroll'] = metrics;
    final axes = ports[index]['axes'] as List;
    final dx = (metrics['left'] as num) - action.destination.dx,
        dy = (metrics['top'] as num) - action.destination.dy;
    final x = (axes[0] as num) * dx + (axes[2] as num) * dy,
        y = (axes[1] as num) * dx + (axes[3] as num) * dy;
    target['x'] = (target['x'] as num) + x;
    target['y'] = (target['y'] as num) + y;
    for (var j = 0; j < index; j++) {
      final origin = ports[j]['origin'] as List<num>;
      origin[0] += x;
      origin[1] += y;
    }
    metrics['left'] = action.destination.dx;
    metrics['top'] = action.destination.dy;
  }
  return _nativeDocumentRevealPlan(
    {...packet, 'boxes': boxes, 'viewport': viewport},
    id,
    rootId,
  );
}

List<NativeDocumentRevealAction> _nativeDocumentRevealPlan(
  Map<String, dynamic> packet,
  String id,
  String rootId, {
  bool focus = false,
}) {
  Never unavailable(String reason) =>
      throw UnsupportedError(tr("Native fragment reveal: {0}", [reason]));
  final boxes = {
    for (final raw in packet['boxes'] as List)
      raw['id'] as String: Map<String, dynamic>.from(raw as Map),
  };
  final target = boxes[id];
  if (target?['kind'] == 'none') return const [];
  if (target?['kind'] != 'box') {
    unavailable(tr("target has no proved native box"));
  }
  final proof = target!['scrollReveal'];
  if (proof is! Map || target['scrollGeometry'] is! Map) {
    unavailable(tr("missing scrollport ancestry"));
  }
  Map style(Map? owner) {
    final value = owner?['computedStyle'];
    if (value is! Map ||
        value['direction'] != 'ltr' ||
        value['writing-mode'] != 'horizontal-tb') {
      unavailable(tr("unsupported writing mode"));
    }
    return value;
  }

  double number(Object? value) {
    if (value is! num || !value.isFinite || value.abs() > 9007199254740990) {
      unavailable(tr("invalid coordinate"));
    }
    return value.toDouble();
  }

  double inset(Map css, String name, double basis, {bool padding = false}) {
    final value = css[name];
    if (padding && value == 'auto') return 0;
    if (value is! String) unavailable(tr("unmeasured {0}", [name]));
    final match = RegExp(
      r'^([+-]?(?:\d+(?:\.\d*)?|\.\d+))(px|%)$',
    ).firstMatch(value);
    if (match == null || !padding && match[2] == '%') {
      unavailable(tr("unresolved {0}", [name]));
    }
    final result =
        double.parse(match[1]!) * (match[2] == '%' ? basis / 100 : 1);
    if (!result.isFinite || padding && result < 0) {
      unavailable(tr("invalid {0}", [name]));
    }
    return result;
  }

  final css = style(target);
  final margin = (
    left: inset(css, 'scroll-margin-left', 0),
    top: inset(css, 'scroll-margin-top', 0),
    right: inset(css, 'scroll-margin-right', 0),
    bottom: inset(css, 'scroll-margin-bottom', 0),
  );
  double nearest(
    double start,
    double end,
    double visibleStart,
    double visibleEnd,
  ) {
    if (end < start || visibleEnd < visibleStart) {
      unavailable(tr("inverted reveal region"));
    }
    if (start < visibleStart && end > visibleEnd) return 0;
    final larger = end - start > visibleEnd - visibleStart;
    if (start < visibleStart && !larger || end > visibleEnd && larger) {
      return start - visibleStart;
    }
    if (start < visibleStart && larger || end > visibleEnd && !larger) {
      return end - visibleEnd;
    }
    return 0;
  }

  double centerIfNeeded(
    double start,
    double end,
    double visibleStart,
    double visibleEnd,
  ) {
    if (end < start || visibleEnd < visibleStart) {
      unavailable(tr("inverted focus region"));
    }
    if (start >= visibleStart && end <= visibleEnd) return 0;
    return (start + end - visibleStart - visibleEnd) / 2;
  }

  Offset destination(
    Rect rect,
    Size port,
    Map css,
    Offset position,
    Map? range,
  ) {
    if (range == null) unavailable(tr("missing native scroll limits"));
    final left = inset(css, 'scroll-padding-left', port.width, padding: true),
        right =
            port.width -
            inset(css, 'scroll-padding-right', port.width, padding: true),
        top = inset(css, 'scroll-padding-top', port.height, padding: true),
        bottom =
            port.height -
            inset(css, 'scroll-padding-bottom', port.height, padding: true);
    if (right < left ||
        bottom < top ||
        rect.bottom + margin.bottom < rect.top - margin.top) {
      unavailable(tr("inverted reveal region"));
    }
    final x =
            position.dx +
            (focus ? centerIfNeeded : nearest)(
              rect.left - margin.left,
              rect.right + margin.right,
              left,
              right,
            ),
        y =
            position.dy +
            (focus
                ? centerIfNeeded(
                    rect.top - margin.top,
                    rect.bottom + margin.bottom,
                    top,
                    bottom,
                  )
                : rect.top - margin.top - top);
    final minX = number(range['minLeft']),
        maxX = number(range['maxLeft']),
        minY = number(range['minTop']),
        maxY = number(range['maxTop']);
    if (minX > maxX || minY > maxY) unavailable(tr("inverted native limits"));
    return Offset(
      number(x).roundToDouble().clamp(minX, maxX),
      number(y).roundToDouble().clamp(minY, maxY),
    );
  }

  Rect mapRect(Rect rect, Offset Function(Offset) map) {
    final points = [
      rect.topLeft,
      rect.topRight,
      rect.bottomLeft,
      rect.bottomRight,
    ].map(map).toList();
    return Rect.fromLTRB(
      points.map((p) => p.dx).reduce(math.min),
      points.map((p) => p.dy).reduce(math.min),
      points.map((p) => p.dx).reduce(math.max),
      points.map((p) => p.dy).reduce(math.max),
    );
  }

  final viewport = packet['viewport'] as Map,
      scroll = Offset(number(viewport['scrollX']), number(viewport['scrollY']));
  final caret = focus ? target['focusRect'] as List? : null;
  var absolute = Rect.fromLTWH(
    number(caret?[0] ?? target['x']) - scroll.dx,
    number(caret?[1] ?? target['y']) - scroll.dy,
    number(caret?[2] ?? target['width']),
    number(caret?[3] ?? target['height']),
  );
  final plan = <NativeDocumentRevealAction>[];
  for (final raw in proof['ports'] as List) {
    final port = raw as Map, owner = boxes[port['id']];
    if (owner?['kind'] != 'box' || owner?['scroll'] is! Map) {
      unavailable(tr("scroll owner has no current native box"));
    }
    final metrics = owner!['scroll'] as Map,
        axes = (port['axes'] as List).map(number).toList(),
        origin = (port['origin'] as List).map(number).toList();
    final ox = origin[0] - scroll.dx,
        oy = origin[1] - scroll.dy,
        det = axes[0] * axes[3] - axes[1] * axes[2];
    if (!det.isFinite || det.abs() < 1e-12) {
      unavailable(tr("singular scroll transform"));
    }
    final rect = mapRect(
      absolute,
      (p) => Offset(
        (axes[3] * (p.dx - ox) - axes[2] * (p.dy - oy)) / det,
        (-axes[1] * (p.dx - ox) + axes[0] * (p.dy - oy)) / det,
      ),
    );
    final size = Size(number(port['width']), number(port['height'])),
        current = Offset(number(metrics['left']), number(metrics['top']));
    final next = destination(
      rect,
      size,
      style(owner),
      current,
      metrics['range'] as Map?,
    );
    plan.add(NativeDocumentRevealAction(port['id'] as String, next));
    final moved = rect.shift(current - next),
        clip = moved.intersect(Offset.zero & size);
    absolute = mapRect(
      clip.width > 0 && clip.height > 0 ? clip : moved,
      (p) => Offset(
        ox + axes[0] * p.dx + axes[2] * p.dy,
        oy + axes[1] * p.dx + axes[3] * p.dy,
      ),
    );
  }
  if (proof['viewport'] == true) {
    final size = Size(number(viewport['width']), number(viewport['height'])),
        range = viewport['scrollRange'] as Map?;
    if (absolute.right + margin.right > size.width && range?['maxLeft'] == 0) {
      unavailable(tr("root horizontal reveal has no native range"));
    }
    plan.add(
      NativeDocumentRevealAction(
        null,
        destination(absolute, size, style(boxes[rootId]), scroll, range),
      ),
    );
  }
  return List.unmodifiable(plan);
}
