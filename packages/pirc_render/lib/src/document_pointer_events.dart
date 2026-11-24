import 'dart:ui' as ui;
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'document_absolute_position.dart';
import 'document_element_scroll.dart';

/// A paragraph can restore only the fragments whose CSS ancestry accepts input.
abstract interface class NativeDocumentPointerRestoreTarget {
  bool hitTestRestored(BoxHitTestResult result, {required Offset position});
}

/// Metadata stays on the span recognizer, preserving ordinary text layout.
class NativeDocumentPointerTapRecognizer extends TapGestureRecognizer {
  NativeDocumentPointerTapRecognizer({required this.restoresHit});
  final bool restoresHit;
}

bool nativeDocumentHasPointerSpans(InlineSpan span) {
  if (span is! TextSpan) return false;
  return span.recognizer is NativeDocumentPointerTapRecognizer ||
      (span.children?.any(nativeDocumentHasPointerSpans) ?? false);
}

bool nativeDocumentPointerTextAt(RenderParagraph paragraph, Offset point) {
  var offset = 0, found = false;
  void visit(InlineSpan span, GestureRecognizer? inherited) {
    if (span is! TextSpan) {
      offset++;
      return;
    }
    final recognizer = span.recognizer ?? inherited;
    final start = offset;
    offset += span.text?.length ?? 0;
    if (offset > start &&
        recognizer is NativeDocumentPointerTapRecognizer &&
        recognizer.restoresHit) {
      final boxes = paragraph.getBoxesForSelection(
        TextSelection(baseOffset: start, extentOffset: offset),
        boxHeightStyle: ui.BoxHeightStyle.max,
      );
      if (boxes.any((box) => box.toRect().contains(point))) found = true;
    }
    for (final child in span.children ?? const <InlineSpan>[]) {
      visit(child, recognizer);
    }
  }

  visit(paragraph.text, null);
  return found;
}

class NativeDocumentPointerEvents extends SingleChildRenderObjectWidget {
  const NativeDocumentPointerEvents({
    super.key,
    required this.enabled,
    this.surface,
    required super.child,
  });
  final bool enabled;
  final RenderBox? Function(RenderBox)? surface;
  @override
  RenderObject createRenderObject(BuildContext context) =>
      RenderNativeDocumentPointerEvents(enabled, surface: surface);
  @override
  void updateRenderObject(
    BuildContext context,
    covariant RenderNativeDocumentPointerEvents renderObject,
  ) {
    renderObject
      ..enabled = enabled
      ..surface = surface;
  }
}

class RenderNativeDocumentPointerEvents extends RenderProxyBox {
  RenderNativeDocumentPointerEvents(this.enabled, {this.surface});
  bool enabled;
  RenderBox? Function(RenderBox)? surface;
  @override
  bool hitTest(BoxHitTestResult result, {required Offset position}) {
    if (enabled) {
      // Preserve a relative child's visible overflow without another bounds gate.
      if (child?.hitTest(result, position: position) == true) {
        result.add(BoxHitTestEntry(this, position));
        return true;
      }
      final border = surface?.call(this);
      if (border != null &&
          nativeDocumentPointerPathVisible(border, this, position)) {
        final hit = result.addWithPaintTransform(
          transform: border.getTransformTo(this),
          position: position,
          hitTest: (result, p) {
            if (!border.size.contains(p)) return false;
            if (!identical(border, this) &&
                border.hitTest(result, position: p)) {
              return true;
            }
            result.add(BoxHitTestEntry(border, p));
            return true;
          },
        );
        if (hit) {
          _appendPointerAncestors(border, this, result, position);
          result.add(BoxHitTestEntry(this, position));
          return true;
        }
      }
      return false;
    }
    final subtree = child;
    if (subtree == null) return false;
    for (final candidate in _restoredTargets(subtree)) {
      if (!nativeDocumentPointerPathVisible(candidate, this, position)) {
        continue;
      }
      final hit = result.addWithPaintTransform(
        transform: candidate.getTransformTo(this),
        position: position,
        hitTest: (result, p) {
          if (candidate is RenderNativeDocumentPointerEvents) {
            return candidate.hitTest(result, position: p);
          }
          return (candidate as NativeDocumentPointerRestoreTarget)
              .hitTestRestored(result, position: p);
        },
      );
      if (hit) {
        _appendPointerAncestors(candidate, this, result, position);
        result.add(BoxHitTestEntry(this, position));
        return true;
      }
    }
    return false;
  }
}

void _appendPointerAncestors(
  RenderBox target,
  RenderBox root,
  BoxHitTestResult result,
  Offset position,
) {
  RenderObject? node = target.parent;
  while (node != null && node != root) {
    if (node is RenderBox) {
      final box = node;
      result.addWithPaintTransform(
        transform: box.getTransformTo(root),
        position: position,
        hitTest: (result, p) {
          result.add(BoxHitTestEntry(box, p));
          return true;
        },
      );
    }
    node = node.parent;
  }
}

Iterable<RenderBox> _restoredTargets(RenderObject node) sync* {
  if (node is RenderNativeDocumentPointerEvents && node.enabled) {
    yield node;
    return;
  }
  if (node is RenderBox && node is NativeDocumentPointerRestoreTarget) {
    yield node;
  }
  final children = <RenderObject>[];
  node.visitChildren(children.add);
  if (node is NativeDocumentPositionedHitTarget && node is RenderBox) {
    // Positioned layers expose their paint order rather than insertion order.
    final ordered = node as NativeDocumentPositionedHitTarget;
    if (ordered is NativeDocumentPositionedChildOrder) {
      children
        ..clear()
        ..addAll(
          (ordered as NativeDocumentPositionedChildOrder)
              .positionedPaintChildren,
        );
    }
  }
  for (final child in children.reversed) {
    yield* _restoredTargets(child);
  }
}

/// Check real clips, without treating pointer-events:none as a subtree barrier.
bool nativeDocumentPointerPathVisible(
  RenderBox target,
  RenderBox root,
  Offset rootPosition,
) {
  final global = root.localToGlobal(rootPosition);
  RenderObject? node = target.parent;
  while (node != null && node != root) {
    if (nativeDocumentScrollClipsGlobalPoint(node, global) ||
        node is RenderIgnorePointer && node.ignoring ||
        node is RenderAbsorbPointer && node.absorbing ||
        node is RenderOffstage && node.offstage) {
      return false;
    }
    if (node is RenderBox) {
      final p = node.globalToLocal(global);
      if (!p.dx.isFinite || !p.dy.isFinite) return false;
      if (node is RenderClipRect &&
          node.clipBehavior != Clip.none &&
          !(node.clipper?.getClip(node.size) ?? Offset.zero & node.size)
              .contains(p)) {
        return false;
      }
      if (node is RenderClipRRect &&
          node.clipBehavior != Clip.none &&
          !(node.clipper?.getClip(node.size) ??
                  node.borderRadius
                      .resolve(node.textDirection)
                      .toRRect(Offset.zero & node.size))
              .contains(p)) {
        return false;
      }
      if (node is RenderClipOval && node.clipBehavior != Clip.none) {
        final r = node.clipper?.getClip(node.size) ?? Offset.zero & node.size;
        if (r.isEmpty) return false;
        final dx = (p.dx - r.center.dx) / (r.width / 2),
            dy = (p.dy - r.center.dy) / (r.height / 2);
        if (dx * dx + dy * dy > 1) return false;
      }
      if (node is RenderClipPath &&
          node.clipBehavior != Clip.none &&
          !(node.clipper?.getClip(node.size) ??
                  (Path()..addRect(Offset.zero & node.size)))
              .contains(p)) {
        return false;
      }
      if (node is RenderPhysicalShape &&
          node.clipBehavior != Clip.none &&
          !(node.clipper?.getClip(node.size) ??
                  (Path()..addRect(Offset.zero & node.size)))
              .contains(p)) {
        return false;
      }
      if (node is RenderPhysicalModel && node.clipBehavior != Clip.none) {
        final rect = Offset.zero & node.size;
        final path = Path();
        if (node.shape == BoxShape.circle) {
          path.addOval(rect);
        } else {
          path.addRRect((node.borderRadius ?? BorderRadius.zero).toRRect(rect));
        }
        if (!path.contains(p)) return false;
      }
    }
    node = node.parent;
  }
  return node == root;
}

/// Recover enabled descendants outside an absolute ancestor's normal box.
bool nativeDocumentRestorePointerHit(
  RenderBox root,
  BoxHitTestResult result,
  Offset position,
) {
  Iterable<RenderBox> roots(RenderObject node) sync* {
    if (node is RenderNativeDocumentPointerEvents && !node.enabled) {
      yield node;
      return;
    }
    final children = <RenderObject>[];
    node.visitChildren(children.add);
    if (node is NativeDocumentPositionedChildOrder) {
      children
        ..clear()
        ..addAll(
          (node as NativeDocumentPositionedChildOrder).positionedPaintChildren,
        );
    }
    for (final child in children.reversed) {
      yield* roots(child);
    }
  }

  final children = <RenderObject>[];
  root.visitChildren(children.add);
  for (final child in children.reversed) {
    for (final target in roots(child)) {
      if (!nativeDocumentPointerPathVisible(target, root, position)) continue;
      if (result.addWithPaintTransform(
        transform: target.getTransformTo(root),
        position: position,
        hitTest: (result, p) => target.hitTest(result, position: p),
      )) {
        _appendPointerAncestors(target, root, result, position);
        return true;
      }
    }
  }
  return false;
}
