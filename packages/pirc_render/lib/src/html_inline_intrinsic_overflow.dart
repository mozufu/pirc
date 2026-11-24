import 'document_pointer_events.dart';
import 'document_absolute_position.dart';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

import 'document_element_scroll.dart';

/// A marker for an atomic inline element whose natural width may exceed the
/// paragraph's line width.
///
/// This widget still obeys every constraint passed to it. The companion
/// [NativeHtmlInlineOverflowRichText] recognizes the marker in a paragraph's
/// inline child subtree and lays out that one child with an unbounded maximum
/// width. Other inline children keep Flutter's normal paragraph-width limit.
class NativeHtmlInlineIntrinsicOverflow extends SingleChildRenderObjectWidget {
  const NativeHtmlInlineIntrinsicOverflow({
    super.key,
    required this.intrinsicSize,
    this.baselineFromTop,
    this.useChildIntrinsicSize = false,
    required super.child,
  });

  /// Natural replaced-element box size, already including its CSS box model.
  final Size intrinsicSize;

  /// Alphabetic baseline distance from the top of [intrinsicSize].
  final double? baselineFromTop;

  /// Use the child's live intrinsic dimensions instead of the fixed fallback.
  ///
  /// Raw HTML replaced elements use this so CSS sizing remains authoritative:
  /// an image can report its decoded natural size, while a CSS sizing wrapper
  /// can still apply explicit width, height, or max-width constraints.
  final bool useChildIntrinsicSize;

  @override
  RenderNativeHtmlInlineOverflowMarker createRenderObject(
    BuildContext context,
  ) => RenderNativeHtmlInlineOverflowMarker(
    intrinsicSize,
    baselineFromTop,
    useChildIntrinsicSize,
  );

  @override
  void updateRenderObject(
    BuildContext context,
    RenderNativeHtmlInlineOverflowMarker renderObject,
  ) {
    renderObject
      ..intrinsicSize = intrinsicSize
      ..baselineFromTop = baselineFromTop
      ..useChildIntrinsicSize = useChildIntrinsicSize;
  }
}

/// Lets a marked atomic element lay out at its natural width inside a parent
/// whose own width remains constrained by normal CSS layout.
///
/// When [child] contains a [NativeHtmlInlineIntrinsicOverflow], this host
/// widens only the constraints passed to that subtree to at least its maximum
/// intrinsic width. The host itself still reports a size constrained by its
/// parent. Subtrees without a marker receive the original constraints.
class NativeHtmlInlineOverflowHost extends SingleChildRenderObjectWidget {
  const NativeHtmlInlineOverflowHost({super.key, required super.child});

  @override
  RenderNativeHtmlInlineOverflowHost createRenderObject(BuildContext context) =>
      RenderNativeHtmlInlineOverflowHost();
}

class RenderNativeHtmlInlineOverflowHost extends RenderProxyBox {
  @override
  void performLayout() {
    final currentChild = child;
    if (currentChild == null) {
      size = constraints.smallest;
      return;
    }

    final childConstraints = _overflowChildConstraints(
      currentChild,
      constraints,
    );
    currentChild.layout(childConstraints, parentUsesSize: true);
    size = constraints.constrain(currentChild.size);
  }

  @override
  Size computeDryLayout(BoxConstraints constraints) {
    final currentChild = child;
    if (currentChild == null) return constraints.smallest;
    return constraints.constrain(
      currentChild.getDryLayout(
        _overflowChildConstraints(currentChild, constraints),
      ),
    );
  }

  @override
  double? computeDryBaseline(
    BoxConstraints constraints,
    TextBaseline baseline,
  ) {
    final currentChild = child;
    if (currentChild == null) return null;
    return currentChild.getDryBaseline(
      _overflowChildConstraints(currentChild, constraints),
      baseline,
    );
  }
}

BoxConstraints _overflowChildConstraints(
  RenderBox child,
  BoxConstraints constraints,
) {
  if (!_containsOverflowMarker(child) || !constraints.maxWidth.isFinite) {
    return constraints;
  }

  final intrinsicWidth = child.getMaxIntrinsicWidth(constraints.maxHeight);
  if (!intrinsicWidth.isFinite || intrinsicWidth <= constraints.maxWidth) {
    return constraints;
  }
  return constraints.copyWith(maxWidth: intrinsicWidth);
}

bool _containsOverflowMarker(RenderObject root) {
  if (root is RenderNativeHtmlInlineOverflowMarker) return true;
  var found = false;
  root.visitChildren((child) {
    if (!found && _containsOverflowMarker(child)) found = true;
  });
  return found;
}

/// Makes visible, marked atomic elements reachable when a nested CSS layout box
/// is narrower than the control, while retaining ordinary clipping behavior.
///
/// Layout and paint are delegated unchanged. During hit testing, the wrapper
/// first visits positioned paint in its overlay order, then normal children.
/// If those miss, it may forward a hit directly to a marked inline control
/// only when the point falls within that control
/// and no explicit clip render object lies between the control and this root.
/// The root's own bounds gate inline overflow. Positioned paint may extend
/// outside the normal-flow root; its actual enclosing viewport gates input.
class NativeHtmlVisibleInlineOverflowRoot
    extends SingleChildRenderObjectWidget {
  const NativeHtmlVisibleInlineOverflowRoot({super.key, required super.child});

  @override
  RenderNativeHtmlVisibleInlineOverflowRoot createRenderObject(
    BuildContext context,
  ) => RenderNativeHtmlVisibleInlineOverflowRoot();
}

class RenderNativeHtmlVisibleInlineOverflowRoot extends RenderProxyBox {
  @override
  bool hitTest(BoxHitTestResult result, {required Offset position}) {
    if (hasSize && size.contains(position)) {
      return super.hitTest(result, position: position);
    }
    // A positioned box can extend below a short normal-flow document. Its
    // enclosing viewport still gates input; normal inline overflow stays gated.
    if (hasSize && _hitPositioned(result, position)) {
      result.add(BoxHitTestEntry(this, position));
      return true;
    }
    return false;
  }

  bool _hitPositioned(BoxHitTestResult result, Offset position) {
    final subtree = child;
    if (subtree != null) {
      for (final target in _positionedTargets(subtree)) {
        if (_hasExplicitClipAncestor(target, this, position)) continue;
        if (result.addWithPaintTransform(
          transform: target.getTransformTo(this),
          position: position,
          hitTest: (result, p) => (target as NativeDocumentPositionedHitTarget)
              .hitTestPositioned(result, position: p),
        )) {
          return true;
        }
      }
    }
    return false;
  }

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) {
    if (_hitPositioned(result, position)) return true;
    if (super.hitTestChildren(result, position: position)) return true;
    final currentChild = child;
    if (currentChild == null) return false;

    for (final marker in _overflowMarkers(currentChild)) {
      if (_hasExplicitClipAncestor(
        marker,
        this,
        position,
        respectPointerEvents: true,
      )) {
        continue;
      }
      final hit = result.addWithPaintTransform(
        transform: marker.getTransformTo(this),
        position: position,
        hitTest: (result, transformedPosition) =>
            marker.hitTest(result, position: transformedPosition),
      );
      if (hit) return true;
    }
    return false;
  }
}

Iterable<RenderBox> _positionedTargets(RenderObject node) sync* {
  if (node is RenderBox && node is NativeDocumentPositionedHitTarget) {
    yield node;
  }
  if (node is NativeDocumentRoutedPositionedRoot) {
    final routed = node as NativeDocumentRoutedPositionedRoot;
    if (routed.viewportRouted) {
      final flow = routed.ordinaryFlow;
      if (flow != null) yield* _positionedTargets(flow);
      return;
    }
  }
  final children = <RenderObject>[];
  node.visitChildren(children.add);
  for (final child in children.reversed) {
    yield* _positionedTargets(child);
  }
}

Iterable<RenderNativeHtmlInlineOverflowMarker> _overflowMarkers(
  RenderObject root,
) sync* {
  if (root is RenderNativeHtmlInlineOverflowMarker) yield root;
  if (root is NativeDocumentRoutedPositionedRoot) {
    final routed = root as NativeDocumentRoutedPositionedRoot;
    if (routed.viewportRouted) {
      final flow = routed.ordinaryFlow;
      if (flow != null) yield* _overflowMarkers(flow);
      return;
    }
  }
  final children = <RenderObject>[];
  root.visitChildren(children.add);
  for (final child in children) {
    yield* _overflowMarkers(child);
  }
}

bool _hasExplicitClipAncestor(
  RenderObject marker,
  RenderBox root,
  Offset position, {
  bool respectPointerEvents = false,
}) {
  var pointerPolicyFound = false;
  final globalPosition = root.localToGlobal(position);
  RenderObject? ancestor = marker.parent;
  while (ancestor != null && ancestor != root) {
    if (respectPointerEvents &&
        !pointerPolicyFound &&
        ancestor is RenderNativeDocumentPointerEvents) {
      pointerPolicyFound = true;
      if (!ancestor.enabled) return true;
    }
    if (nativeDocumentScrollClipsGlobalPoint(ancestor, globalPosition) ||
        ancestor is RenderIgnorePointer && ancestor.ignoring ||
        ancestor is RenderAbsorbPointer && ancestor.absorbing ||
        ancestor is RenderOffstage && ancestor.offstage) {
      return true;
    }
    if (ancestor is RenderClipRect && ancestor.clipBehavior != Clip.none ||
        ancestor is RenderClipRRect && ancestor.clipBehavior != Clip.none ||
        ancestor is RenderClipOval && ancestor.clipBehavior != Clip.none ||
        ancestor is RenderClipPath && ancestor.clipBehavior != Clip.none ||
        ancestor is RenderPhysicalModel && ancestor.clipBehavior != Clip.none ||
        ancestor is RenderPhysicalShape && ancestor.clipBehavior != Clip.none) {
      return true;
    }
    ancestor = ancestor.parent;
  }
  return ancestor != root;
}

/// Framework-facing marker searched for by [RenderNativeHtmlInlineOverflowParagraph].
class RenderNativeHtmlInlineOverflowMarker extends RenderProxyBox {
  RenderNativeHtmlInlineOverflowMarker(
    this._intrinsicSize,
    this._baselineFromTop,
    this._useChildIntrinsicSize,
  );

  Size _intrinsicSize;
  double? _baselineFromTop;
  bool _useChildIntrinsicSize;

  set intrinsicSize(Size value) {
    if (_intrinsicSize == value) return;
    _intrinsicSize = value;
    markNeedsLayout();
  }

  set baselineFromTop(double? value) {
    if (_baselineFromTop == value) return;
    _baselineFromTop = value;
    markNeedsLayout();
  }

  set useChildIntrinsicSize(bool value) {
    if (_useChildIntrinsicSize == value) return;
    _useChildIntrinsicSize = value;
    markNeedsLayout();
  }

  @override
  double computeMinIntrinsicWidth(double height) =>
      _childIntrinsicWidth(height, minimum: true);

  @override
  double computeMaxIntrinsicWidth(double height) =>
      _childIntrinsicWidth(height, minimum: false);

  @override
  double computeMinIntrinsicHeight(double width) =>
      _childIntrinsicHeight(width, minimum: true);

  @override
  double computeMaxIntrinsicHeight(double width) =>
      _childIntrinsicHeight(width, minimum: false);

  double _childIntrinsicWidth(double height, {required bool minimum}) {
    final currentChild = child;
    if (_useChildIntrinsicSize && currentChild != null) {
      final width = minimum
          ? currentChild.getMinIntrinsicWidth(height)
          : currentChild.getMaxIntrinsicWidth(height);
      if (width.isFinite && width >= 0) return width;
    }
    return _intrinsicSize.width;
  }

  double _childIntrinsicHeight(double width, {required bool minimum}) {
    final currentChild = child;
    if (_useChildIntrinsicSize && currentChild != null) {
      final height = minimum
          ? currentChild.getMinIntrinsicHeight(width)
          : currentChild.getMaxIntrinsicHeight(width);
      if (height.isFinite && height >= 0) return height;
    }
    return _intrinsicSize.height;
  }

  @override
  Size computeDryLayout(BoxConstraints constraints) {
    final currentChild = child;
    if (_useChildIntrinsicSize && currentChild != null) {
      return constraints.constrain(currentChild.getDryLayout(constraints));
    }
    return constraints.constrain(_intrinsicSize);
  }

  @override
  double? computeDryBaseline(
    BoxConstraints constraints,
    TextBaseline baseline,
  ) {
    final height = computeDryLayout(constraints).height;
    return _baselineDistance(height);
  }

  @override
  double? computeDistanceToActualBaseline(TextBaseline baseline) {
    return _baselineDistance(size.height);
  }

  double _baselineDistance(double height) {
    if (_useChildIntrinsicSize && _baselineFromTop == null) return height;
    return (_baselineFromTop ?? _intrinsicSize.height)
        .clamp(0.0, height)
        .toDouble();
  }

  @override
  void performLayout() {
    final currentChild = child;
    if (currentChild == null) {
      size = constraints.constrain(_intrinsicSize);
      return;
    }
    currentChild.layout(constraints, parentUsesSize: true);
    size = constraints.constrain(currentChild.size);
  }
}

/// A [RichText] replacement that lets marked atomic elements use their natural
/// inline width while retaining the source widget's text and selection setup.
///
/// Use this as a drop-in replacement for framework-generated [RichText]
/// widgets. It copies every public RichText rendering field, including the
/// nonlinear [TextScaler] and selection registrar/color pair.
class NativeHtmlInlineOverflowRichText extends RichText {
  NativeHtmlInlineOverflowRichText.fromRichText(
    RichText source, {
    TextOverflow? overflow,
    bool? softWrap,
  }) : super(
         key: source.key,
         text: source.text,
         textAlign: source.textAlign,
         textDirection: source.textDirection,
         softWrap: softWrap ?? source.softWrap,
         overflow: overflow ?? source.overflow,
         textScaler: source.textScaler,
         maxLines: source.maxLines,
         locale: source.locale,
         strutStyle: source.strutStyle,
         textWidthBasis: source.textWidthBasis,
         textHeightBehavior: source.textHeightBehavior,
         selectionRegistrar: source.selectionRegistrar,
         selectionColor: source.selectionColor,
       );

  @override
  RenderNativeHtmlInlineOverflowParagraph createRenderObject(
    BuildContext context,
  ) {
    assert(textDirection != null || debugCheckHasDirectionality(context));
    return RenderNativeHtmlInlineOverflowParagraph(
      text,
      textAlign: textAlign,
      textDirection: textDirection ?? Directionality.of(context),
      softWrap: softWrap,
      overflow: overflow,
      textScaler: textScaler,
      maxLines: maxLines,
      strutStyle: strutStyle,
      textWidthBasis: textWidthBasis,
      textHeightBehavior: textHeightBehavior,
      locale: locale ?? Localizations.maybeLocaleOf(context),
      registrar: selectionRegistrar,
      selectionColor: selectionColor,
    );
  }
}

/// [RenderParagraph] that relaxes the width only for inline subtrees marked by
/// [NativeHtmlInlineIntrinsicOverflow].
class RenderNativeHtmlInlineOverflowParagraph extends RenderParagraph
    implements NativeDocumentPointerRestoreTarget {
  @override
  bool hitTestRestored(BoxHitTestResult result, {required Offset position}) {
    if (!nativeDocumentPointerTextAt(this, position)) return false;
    hitTestChildren(result, position: position);
    result.add(BoxHitTestEntry(this, position));
    return true;
  }

  RenderNativeHtmlInlineOverflowParagraph(
    super.text, {
    super.textAlign,
    required super.textDirection,
    super.softWrap,
    super.overflow,
    super.textScaler,
    super.maxLines,
    super.locale,
    super.strutStyle,
    super.textWidthBasis,
    super.textHeightBehavior,
    super.children,
    super.selectionColor,
    super.registrar,
  });

  @override
  bool hitTest(BoxHitTestResult result, {required Offset position}) {
    if (size.contains(position)) {
      return super.hitTest(result, position: position);
    }

    // RenderBox normally rejects every point outside this paragraph's own
    // bounds before consulting its children. A marked replaced control may
    // paint beyond those bounds, so allow the hit only when that point lies in
    // the actual marked inline child and the child itself accepts the hit.
    if (!_containsMarkedChildAt(position)) return false;
    if (!hitTestChildren(result, position: position)) return false;
    result.add(BoxHitTestEntry(this, position));
    return true;
  }

  @override
  List<PlaceholderDimensions> layoutInlineChildren(
    double maxWidth,
    ChildLayouter layoutChild,
    ChildBaselineGetter getChildBaseline,
  ) {
    final dimensions = <PlaceholderDimensions>[];
    for (
      RenderBox? child = firstChild;
      child != null;
      child = childAfter(child)
    ) {
      final parentData = child.parentData! as TextParentData;
      final span = parentData.span;
      if (span == null) {
        dimensions.add(PlaceholderDimensions.empty);
        continue;
      }

      final childConstraints = BoxConstraints(
        maxWidth: _containsOverflowMarker(child) ? double.infinity : maxWidth,
      );
      dimensions.add(
        PlaceholderDimensions(
          size: layoutChild(child, childConstraints),
          alignment: span.alignment,
          baseline: span.baseline,
          baselineOffset: switch (span.alignment) {
            ui.PlaceholderAlignment.aboveBaseline ||
            ui.PlaceholderAlignment.belowBaseline ||
            ui.PlaceholderAlignment.bottom ||
            ui.PlaceholderAlignment.middle ||
            ui.PlaceholderAlignment.top => null,
            ui.PlaceholderAlignment.baseline => getChildBaseline(
              child,
              childConstraints,
              span.baseline!,
            ),
          },
        ),
      );
    }
    return dimensions;
  }

  bool _containsMarkedChildAt(Offset position) {
    for (
      RenderBox? child = firstChild;
      child != null;
      child = childAfter(child)
    ) {
      if (!_containsOverflowMarker(child)) continue;
      final offset = (child.parentData! as TextParentData).offset;
      if (offset == null) continue;
      if ((offset & child.size).contains(position)) return true;
    }
    return false;
  }
}
