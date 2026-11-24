import 'dart:math' as math;

import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

import 'html_document_flex.dart';
import 'document_relative_position.dart';
import 'document_absolute_position.dart';
import 'document_margin_collapse.dart';

class _DocumentContainingBlock {
  const _DocumentContainingBlock({
    required this.width,
    required this.height,
    required this.isActive,
  });

  final double? width;
  final double? height;
  final bool isActive;
}

_DocumentContainingBlock? _findDocumentContainingBlock(RenderObject? ancestor) {
  while (ancestor != null) {
    if (ancestor is NativeDocumentPositioningBasis) {
      final basis = ancestor as NativeDocumentPositioningBasis;
      return _DocumentContainingBlock(
        width: basis.positioningWidth,
        height: basis.positioningHeight,
        isActive: basis.positioningActive,
      );
    }
    if (ancestor is _RenderDocumentBox) {
      return _DocumentContainingBlock(
        width: ancestor.contentWidth,
        height: ancestor.contentHeight,
        isActive: ancestor._hasActiveContext,
      );
    }
    if (ancestor is _RenderNativeDocumentContainingBlock) {
      return _DocumentContainingBlock(
        width: ancestor.contentWidth,
        height: ancestor.contentHeight,
        isActive: ancestor._hasActiveContext,
      );
    }
    ancestor = ancestor.parent;
  }
  return null;
}

void _markLayoutSubtree(RenderObject node) {
  if (node is RenderBox) node.markNeedsLayout();
  node.visitChildren(_markLayoutSubtree);
}

/// Scroll viewports defer dimension commits while percentage margin groups
/// settle, so provisional content sizes cannot clamp the user's scroll offset.
abstract interface class NativeDocumentLayoutMetricsCommitParticipant {
  void commitDocumentLayoutMetrics();
}

int _marginProvisionalLayoutDepth = 0;
int _nativeDocumentBoxLayoutDepth = 0;
bool get nativeDocumentMarginLayoutIsProvisional =>
    _marginProvisionalLayoutDepth > 0;

bool nativeDocumentMarginsAreSettled(RenderObject root) {
  var ready = true;
  void visit(RenderObject object) {
    if (object is _RenderDocumentMarginCollapseRoot && !object.settled) {
      ready = false;
    }
    object.visitChildren(visit);
  }

  visit(root);
  return ready;
}

/// Keep the previous committed dimensions until this viewport's enclosing and
/// nested document margin groups have all completed their real layout passes.
bool nativeDocumentMarginMetricsCanCommit(RenderObject viewport) {
  if (nativeDocumentMarginLayoutIsProvisional) return false;
  RenderObject? ancestor = viewport.parent;
  while (ancestor != null) {
    if (ancestor is _RenderDocumentMarginCollapseRoot && !ancestor.settled) {
      return false;
    }
    ancestor = ancestor.parent;
  }
  return nativeDocumentMarginsAreSettled(viewport);
}

void _invalidateMarginLayoutOwner(RenderObject object) {
  RenderObject? ancestor = object.parent;
  while (ancestor != null) {
    if (ancestor is _RenderDocumentMarginCollapseRoot) {
      ancestor.invalidateFromDescendant();
      return;
    }
    ancestor = ancestor.parent;
  }
}

/// Resolve percentage top-margin groups before painting or exposing geometry.
/// Each pass uses actual native containing-block widths. A changed group is
/// applied through a new real layout, clearing descendant dry/intrinsic caches.
class NativeDocumentMarginCollapseRoot extends SingleChildRenderObjectWidget {
  const NativeDocumentMarginCollapseRoot({
    super.key,
    required super.child,
    this.maximumPasses = 8,
  });
  final int maximumPasses;
  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderDocumentMarginCollapseRoot(maximumPasses);
  @override
  void updateRenderObject(
    BuildContext context,
    covariant RenderObject renderObject,
  ) {
    (renderObject as _RenderDocumentMarginCollapseRoot)
      ..maximumPasses = maximumPasses
      ..markNeedsLayout();
  }
}

class _RenderDocumentMarginCollapseRoot extends RenderProxyBox {
  _RenderDocumentMarginCollapseRoot(this._maximumPasses);
  int _maximumPasses;
  int get maximumPasses => _maximumPasses;
  set maximumPasses(int value) {
    if (_maximumPasses == value) return;
    _maximumPasses = value;
    markNeedsLayout();
  }

  bool settled = false;
  bool _settling = false;
  bool _reflowScheduled = false;
  void invalidateFromDescendant() {
    if (_settling) return;
    settled = false;
    if (_nativeDocumentBoxLayoutDepth == 0) {
      markNeedsLayout();
    } else if (!_reflowScheduled) {
      _reflowScheduled = true;
      SchedulerBinding.instance.addPostFrameCallback((_) {
        _reflowScheduled = false;
        if (attached) markNeedsLayout();
      });
    }
  }

  @override
  void markNeedsLayout() {
    settled = false;
    super.markNeedsLayout();
  }

  @override
  void performLayout() {
    _settling = true;
    try {
      _performMarginLayout();
    } finally {
      _settling = false;
    }
  }

  void _performMarginLayout() {
    settled = false;
    final current = child;
    if (current == null) {
      size = constraints.smallest;
      settled = true;
      return;
    }
    final outermost = _marginProvisionalLayoutDepth == 0;
    _marginProvisionalLayoutDepth++;
    try {
      // Hypothetical dry queries must not poison the current viewport pass.
      invokeLayoutCallback<BoxConstraints>((_) => _markLayoutSubtree(current));
      for (var pass = 0; pass < math.max(1, maximumPasses); pass++) {
        current.layout(constraints, parentUsesSize: true);
        final boxes = <String, List<_RenderDocumentBox>>{};
        final margins = <_RenderNativeDocumentPercentageMargin>[];
        void collect(RenderObject object) {
          if (object is _RenderDocumentMarginCollapseRoot) return;
          if (object is _RenderDocumentBox &&
              object.spec.geometryOwnerId != null) {
            boxes
                .putIfAbsent(object.spec.geometryOwnerId!, () => [])
                .add(object);
          }
          if (object is _RenderNativeDocumentPercentageMargin &&
              (object._collapsedTop?.contributions.isNotEmpty ?? false)) {
            margins.add(object);
          }
          object.visitChildren(collect);
        }

        collect(current);
        var valid = true;
        final changed = <_RenderNativeDocumentPercentageMargin, double>{};
        for (final margin in margins) {
          var top = 0.0;
          for (final term in margin._collapsedTop!.contributions) {
            double value = term.value;
            if (term.percentage) {
              final origins = boxes[term.originId];
              final width = origins?.length == 1
                  ? origins!.single.containingBlockWidth
                  : null;
              if (width == null || !width.isFinite || width < 0) {
                valid = false;
                break;
              }
              value = value / 100 * width;
            }
            top = math.max(top, value);
          }
          if ((top - margin._resolvedTop).abs() > 0.0000001) {
            changed[margin] = top;
          }
        }
        if (!valid) break;
        if (changed.isEmpty) {
          settled = true;
          break;
        }
        // Never publish a value that has not gone through layout on cap.
        if (pass + 1 >= math.max(1, maximumPasses)) break;
        invokeLayoutCallback<BoxConstraints>((_) {
          for (final entry in changed.entries) {
            entry.key._resolvedTop = entry.value;
          }
          _markLayoutSubtree(current);
        });
      }
      size = constraints.constrain(current.size);
    } finally {
      _marginProvisionalLayoutDepth--;
    }
    if (outermost && nativeDocumentMarginsAreSettled(this)) {
      void commit(RenderObject object) {
        object.visitChildren(commit);
        if (object is NativeDocumentLayoutMetricsCommitParticipant) {
          (object as NativeDocumentLayoutMetricsCommitParticipant)
              .commitDocumentLayoutMetrics();
        }
      }

      invokeLayoutCallback<BoxConstraints>((_) => commit(current));
    }
  }
}

/// CSS dimensions for an ordinary block box.
///
/// [horizontalEdges] and [verticalEdges] are the element's fixed padding and
/// border widths. Percentage padding is represented separately because CSS
/// resolves every padding side against the containing block's content width.
/// If [lengthsAreContentBox] is true, explicit width, height, min, and max
/// lengths describe the content box and the corresponding edges are added
/// exactly once. Otherwise, lengths already describe the outer border box.
///
/// With [applySizing] false, this render object leaves child constraints alone
/// and publishes the sizing context used by descendants.
class NativeDocumentBox extends SingleChildRenderObjectWidget {
  const NativeDocumentBox({
    super.key,
    required super.child,
    this.width,
    this.height,
    this.minWidth,
    this.maxWidth,
    this.minHeight,
    this.maxHeight,
    this.applySizing = true,
    this.fillWidth = true,
    this.intrinsicWidthIsMinimum = false,
    this.tightAllocationIsAuthoritative = false,
    this.lengthsAreContentBox = false,
    this.horizontalEdges = 0,
    this.verticalEdges = 0,
    this.percentagePadding = EdgeInsets.zero,
    this.geometryOwner,
    this.geometryOwnerId,
  });

  final NativeFlexLength? width;
  final NativeFlexLength? height;
  final NativeFlexLength? minWidth;
  final NativeFlexLength? maxWidth;
  final NativeFlexLength? minHeight;
  final NativeFlexLength? maxHeight;
  final double horizontalEdges;
  final double verticalEdges;
  final bool fillWidth;

  /// Replaced elements keep their natural width unless CSS constrains it.
  /// Core's min-width:0 wrapper must not turn them into shrink-to-fit text.
  final bool intrinsicWidthIsMinimum;
  final bool applySizing;
  final bool tightAllocationIsAuthoritative;
  final bool lengthsAreContentBox;

  /// Fractional percentage padding, where `0.1` represents `10%`.
  ///
  /// The [NativeDocumentPercentagePadding] child performs the physical inset;
  /// this value lets this box include those insets in content-box conversion
  /// and in the containing-block content dimensions without adding them twice
  /// to the child layout.
  final EdgeInsets percentagePadding;

  /// Optional identity used by the geometry collector to select this
  /// element's own sizing surface through nested native boxes.
  final Object? geometryOwner;
  final String? geometryOwnerId;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderDocumentBox(this);

  @override
  void updateRenderObject(
    BuildContext context,
    covariant RenderObject renderObject,
  ) {
    (renderObject as _RenderDocumentBox).update(this);
  }
}

/// Establishes a definite viewport or grid-area basis for percentage children.
///
/// Full documents supply their viewport explicitly. Grid items can instead use
/// the finite maximum constraints supplied by their placement. This publishes
/// the containing block without sizing the child; ordinary NativeDocumentBox
/// auto heights remain indefinite.
class NativeDocumentContainingBlock extends SingleChildRenderObjectWidget {
  const NativeDocumentContainingBlock({
    super.key,
    required super.child,
    this.width,
    this.height,
  });

  final double? width;
  final double? height;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderNativeDocumentContainingBlock(width, height);

  @override
  void updateRenderObject(
    BuildContext context,
    covariant RenderObject renderObject,
  ) {
    (renderObject as _RenderNativeDocumentContainingBlock).update(
      width,
      height,
    );
  }
}

class _RenderNativeDocumentContainingBlock extends RenderProxyBox {
  _RenderNativeDocumentContainingBlock(this.explicitWidth, this.explicitHeight);

  double? explicitWidth;
  double? explicitHeight;
  double? contentWidth;
  double? contentHeight;
  bool _layoutContextActive = false;
  int _dryContextDepth = 0;

  bool get _hasActiveContext => _layoutContextActive || _dryContextDepth > 0;

  void update(double? width, double? height) {
    if (explicitWidth == width && explicitHeight == height) return;
    explicitWidth = width;
    explicitHeight = height;
    markNeedsLayout();
  }

  double? _widthFor(BoxConstraints constraints) =>
      explicitWidth ??
      (constraints.maxWidth.isFinite ? constraints.maxWidth : null);

  double? _heightFor(BoxConstraints constraints) =>
      explicitHeight ??
      (constraints.maxHeight.isFinite ? constraints.maxHeight : null);

  void _setContext(double? width, double? height) {
    final changed = contentWidth != width || contentHeight != height;
    contentWidth = width;
    contentHeight = height;
    if (changed && (child?.hasSize ?? false)) {
      invokeLayoutCallback<BoxConstraints>((_) => _markLayoutSubtree(child!));
    }
  }

  @override
  void performLayout() {
    _setContext(_widthFor(constraints), _heightFor(constraints));
    _layoutContextActive = true;
    try {
      if (child == null) {
        size = constraints.smallest;
      } else {
        child!.layout(constraints, parentUsesSize: true);
        size = constraints.constrain(child!.size);
      }
    } finally {
      _layoutContextActive = false;
    }
  }

  @override
  Size computeDryLayout(BoxConstraints constraints) {
    final oldWidth = contentWidth;
    final oldHeight = contentHeight;
    contentWidth = _widthFor(constraints);
    contentHeight = _heightFor(constraints);
    _dryContextDepth++;
    try {
      return constraints.constrain(
        child?.getDryLayout(constraints) ?? Size.zero,
      );
    } finally {
      _dryContextDepth--;
      contentWidth = oldWidth;
      contentHeight = oldHeight;
    }
  }

  @override
  double? computeDryBaseline(
    BoxConstraints constraints,
    TextBaseline baseline,
  ) {
    final oldWidth = contentWidth;
    final oldHeight = contentHeight;
    contentWidth = _widthFor(constraints);
    contentHeight = _heightFor(constraints);
    _dryContextDepth++;
    try {
      return child?.getDryBaseline(constraints, baseline);
    } finally {
      _dryContextDepth--;
      contentWidth = oldWidth;
      contentHeight = oldHeight;
    }
  }

  @override
  double computeMinIntrinsicWidth(double height) =>
      child?.getMinIntrinsicWidth(height) ?? 0;

  @override
  double computeMaxIntrinsicWidth(double height) =>
      child?.getMaxIntrinsicWidth(height) ?? 0;

  @override
  double computeMinIntrinsicHeight(double width) =>
      child?.getMinIntrinsicHeight(width) ?? 0;

  @override
  double computeMaxIntrinsicHeight(double width) =>
      child?.getMaxIntrinsicHeight(width) ?? 0;
}

/// Applies CSS relative-position painting without changing the child's flow
/// size or baseline. Its percentage insets use the nearest active native
/// containing-block context.
class NativeDocumentRelativePosition extends SingleChildRenderObjectWidget {
  const NativeDocumentRelativePosition({
    super.key,
    required super.child,
    required this.spec,
    required this.direction,
  });

  final NativeDocumentRelativePositionSpec spec;
  final TextDirection direction;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderNativeDocumentRelativePosition(spec, direction);

  @override
  void updateRenderObject(
    BuildContext context,
    covariant RenderObject renderObject,
  ) {
    (renderObject as _RenderNativeDocumentRelativePosition).update(
      spec,
      direction,
    );
  }
}

class _RenderNativeDocumentRelativePosition extends RenderProxyBox {
  _RenderNativeDocumentRelativePosition(this._spec, this._direction);

  NativeDocumentRelativePositionSpec _spec;
  TextDirection _direction;
  Offset _paintOffset = Offset.zero;

  void update(
    NativeDocumentRelativePositionSpec spec,
    TextDirection direction,
  ) {
    if (identical(_spec, spec) && _direction == direction) return;
    _spec = spec;
    _direction = direction;
    markNeedsLayout();
  }

  Offset _resolveOffset({required bool dry}) {
    var containingBlock = _findDocumentContainingBlock(parent);
    if (dry && !(containingBlock?.isActive ?? false)) {
      containingBlock = null;
    }
    return _spec.resolve(
      containingWidth: containingBlock?.width,
      containingHeight: containingBlock?.height,
      direction: _direction,
    );
  }

  @override
  void performLayout() {
    _paintOffset = _resolveOffset(dry: false);
    final currentChild = child;
    if (currentChild == null) {
      size = constraints.smallest;
      return;
    }
    currentChild.layout(constraints, parentUsesSize: true);
    size = constraints.constrain(currentChild.size);
  }

  @override
  Size computeDryLayout(BoxConstraints constraints) => constraints.constrain(
    child?.getDryLayout(constraints) ?? constraints.smallest,
  );

  @override
  double? computeDryBaseline(
    BoxConstraints constraints,
    TextBaseline baseline,
  ) => child?.getDryBaseline(constraints, baseline);

  @override
  double? computeDistanceToActualBaseline(TextBaseline baseline) =>
      child?.getDistanceToActualBaseline(baseline) ??
      super.computeDistanceToActualBaseline(baseline);

  @override
  double computeMinIntrinsicWidth(double height) =>
      child?.getMinIntrinsicWidth(height) ?? 0;

  @override
  double computeMaxIntrinsicWidth(double height) =>
      child?.getMaxIntrinsicWidth(height) ?? 0;

  @override
  double computeMinIntrinsicHeight(double width) =>
      child?.getMinIntrinsicHeight(width) ?? 0;

  @override
  double computeMaxIntrinsicHeight(double width) =>
      child?.getMaxIntrinsicHeight(width) ?? 0;

  @override
  Rect get paintBounds {
    final currentChild = child;
    final ownBounds = Offset.zero & size;
    if (currentChild == null) return ownBounds;
    return ownBounds.expandToInclude(
      currentChild.paintBounds.shift(_paintOffset),
    );
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    final currentChild = child;
    if (currentChild != null) {
      context.paintChild(currentChild, offset + _paintOffset);
    }
  }

  @override
  bool hitTest(BoxHitTestResult result, {required Offset position}) {
    if (!hasSize) return false;
    if (hitTestChildren(result, position: position)) {
      result.add(BoxHitTestEntry(this, position));
      return true;
    }
    if (size.contains(position) && hitTestSelf(position)) {
      result.add(BoxHitTestEntry(this, position));
      return true;
    }
    return false;
  }

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) {
    final currentChild = child;
    if (currentChild == null) return false;
    return result.addWithPaintOffset(
      offset: _paintOffset,
      position: position,
      hitTest: (result, transformed) =>
          currentChild.hitTest(result, position: transformed),
    );
  }

  @override
  void applyPaintTransform(RenderObject child, Matrix4 transform) {
    transform.translateByDouble(_paintOffset.dx, _paintOffset.dy, 0, 1);
  }
}

class _RenderDocumentBox extends RenderProxyBox {
  _RenderDocumentBox(this.spec);

  NativeDocumentBox spec;
  @override
  void markNeedsLayout() {
    _invalidateMarginLayoutOwner(this);
    super.markNeedsLayout();
  }

  /// The content dimensions this box publishes to its descendants.
  double? contentWidth;
  double? contentHeight;

  /// The dimensions of this box's own containing block. Percentage padding
  /// uses its containing block's width on all four sides.
  double? containingBlockWidth;
  double? containingBlockHeight;

  bool _layoutContextActive = false;
  int _dryContextDepth = 0;

  void update(NativeDocumentBox next) {
    spec = next;
    markNeedsLayout();
  }

  _DocumentContainingBlock? get _ancestorContainingBlock =>
      _findDocumentContainingBlock(parent);

  bool get _hasActiveContext => _layoutContextActive || _dryContextDepth > 0;

  double? _percentWidthForDescendants(BoxConstraints constraints) {
    final ancestor = _ancestorContainingBlock;
    if (ancestor != null) {
      return ancestor.width;
    }
    if (constraints.hasTightWidth) return constraints.maxWidth;
    return constraints.maxWidth.isFinite ? constraints.maxWidth : null;
  }

  double? _percentHeightForDescendants(BoxConstraints constraints) {
    final ancestor = _ancestorContainingBlock;
    if (ancestor != null) {
      return ancestor.height;
    }
    // A finite max-height is only a limit. It does not make the root's auto
    // height definite for CSS percentage-height descendants.
    return constraints.hasTightHeight ? constraints.maxHeight : null;
  }

  double? _dryContainingBlockWidth(BoxConstraints constraints) {
    final ancestor = _ancestorContainingBlock;
    if (ancestor != null) {
      return ancestor.isActive ? ancestor.width : null;
    }
    if (constraints.hasTightWidth) return constraints.maxWidth;
    return constraints.maxWidth.isFinite ? constraints.maxWidth : null;
  }

  double? _dryContainingBlockHeight(BoxConstraints constraints) {
    final ancestor = _ancestorContainingBlock;
    if (ancestor != null) {
      return ancestor.isActive ? ancestor.height : null;
    }
    return constraints.hasTightHeight ? constraints.maxHeight : null;
  }

  EdgeInsets _resolvedPercentagePadding(double? containingWidth) {
    if (containingWidth == null ||
        !containingWidth.isFinite ||
        containingWidth < 0) {
      return EdgeInsets.zero;
    }
    double side(double fraction) =>
        fraction.isFinite ? math.max(0.0, fraction * containingWidth) : 0;
    return EdgeInsets.fromLTRB(
      side(spec.percentagePadding.left),
      side(spec.percentagePadding.top),
      side(spec.percentagePadding.right),
      side(spec.percentagePadding.bottom),
    );
  }

  double _horizontalEdges(double? containingWidth) =>
      math.max(0.0, spec.horizontalEdges) +
      _resolvedPercentagePadding(containingWidth).horizontal;

  double _verticalEdges(double? containingWidth) =>
      math.max(0.0, spec.verticalEdges) +
      _resolvedPercentagePadding(containingWidth).vertical;

  double? _resolve(NativeFlexLength? value, double? extent) =>
      value?.resolve(extent != null && extent.isFinite ? extent : null);

  double? _outerLength(NativeFlexLength? value, double? basis, double edges) {
    final resolved = _resolve(value, basis);
    if (resolved == null || !spec.lengthsAreContentBox) return resolved;
    return resolved + edges;
  }

  (double, double) _axis({
    required double incomingMin,
    required double incomingMax,
    required NativeFlexLength? preferred,
    required NativeFlexLength? minimum,
    required NativeFlexLength? maximum,
    required double? percentageBasis,
    required double edges,
    required bool fill,
    bool tightAllocationIsAuthoritative = true,
  }) {
    // Flex/grid parents already provide the authoritative border-box size.
    if (tightAllocationIsAuthoritative && incomingMin == incomingMax) {
      return (incomingMin, incomingMax);
    }

    final lower = math.max(
      edges,
      _outerLength(minimum, percentageBasis, edges) ?? 0,
    );
    final upper = math.max(
      lower,
      _outerLength(maximum, percentageBasis, edges) ?? double.infinity,
    );
    final authored = _outerLength(preferred, percentageBasis, edges);
    final target =
        authored ?? (fill && incomingMax.isFinite ? incomingMax : null);
    if (target != null) {
      // Explicit CSS sizes may overflow the available parent width after
      // padding and borders. Keep the child at its authored size; the parent
      // proxy can clip its own size while measurement selects the decorated
      // child surface.
      final used = target.clamp(lower, upper).toDouble();
      return (used, used);
    }
    final min = math.max(incomingMin, lower);
    return (min, math.max(min, math.min(incomingMax, upper)));
  }

  BoxConstraints _inner(
    BoxConstraints constraints, {
    required double? containingWidth,
    required double? containingHeight,
  }) {
    NativeFlexLength? width = spec.width;
    if (!spec.fillWidth &&
        width == null &&
        !constraints.hasTightWidth &&
        child != null) {
      // A flex item's automatic cross size is shrink-to-fit. Core's inner
      // block sizing can otherwise fill the entire loose width before its
      // decoration is measured, even when the parent requests flex-start.
      double? intrinsicHeight;
      if (spec.intrinsicWidthIsMinimum) {
        final edges = _verticalEdges(containingWidth);
        intrinsicHeight = _outerLength(spec.height, containingHeight, edges);
        if (intrinsicHeight == null &&
            (spec.minHeight != null || spec.maxHeight != null)) {
          final naturalHeight = child!.getMaxIntrinsicHeight(double.infinity);
          if (naturalHeight.isFinite) {
            final lower = math.max(
              edges,
              _outerLength(spec.minHeight, containingHeight, edges) ?? 0,
            );
            final upper = math.max(
              lower,
              _outerLength(spec.maxHeight, containingHeight, edges) ??
                  double.infinity,
            );
            intrinsicHeight = naturalHeight.clamp(lower, upper).toDouble();
          }
        }
      }
      // Query natural dimensions independently. Image-provider and clipping
      // wrappers may ignore a finite-height intrinsic-width query (or return
      // zero), so derive the replaced content ratio from their real intrinsic
      // axes and keep the owned padding/border edges outside that ratio.
      var preferred = child!.getMaxIntrinsicWidth(double.infinity);
      if (spec.intrinsicWidthIsMinimum && intrinsicHeight != null) {
        final naturalHeight = child!.getMaxIntrinsicHeight(double.infinity);
        final horizontal = _horizontalEdges(containingWidth);
        final vertical = _verticalEdges(containingWidth);
        if (preferred.isFinite &&
            naturalHeight.isFinite &&
            preferred >= horizontal &&
            naturalHeight > vertical) {
          preferred =
              horizontal +
              (preferred - horizontal) *
                  math.max(0.0, intrinsicHeight - vertical) /
                  (naturalHeight - vertical);
        }
      }
      final minimum = spec.intrinsicWidthIsMinimum
          ? preferred
          : child!.getMinIntrinsicWidth(double.infinity);
      final available = constraints.maxWidth;
      final fit = math.min(math.max(minimum, available), preferred);
      if (fit.isFinite) width = NativeFlexLength.pixels(fit);
    }
    final horizontalEdges = _horizontalEdges(containingWidth);
    final verticalEdges = _verticalEdges(containingWidth);
    final w = _axis(
      incomingMin: constraints.minWidth,
      incomingMax: constraints.maxWidth,
      preferred: width,
      minimum: spec.minWidth,
      maximum: spec.maxWidth,
      percentageBasis: containingWidth,
      edges: horizontalEdges,
      fill: spec.fillWidth,
    );
    final h = _axis(
      incomingMin:
          constraints.hasTightHeight &&
              !spec.tightAllocationIsAuthoritative &&
              _outerLength(spec.height, containingHeight, verticalEdges) == null
          ? 0.0
          : constraints.minHeight,
      incomingMax: constraints.maxHeight,
      preferred: spec.height,
      minimum: spec.minHeight,
      maximum: spec.maxHeight,
      percentageBasis: containingHeight,
      edges: verticalEdges,
      fill: false,
      tightAllocationIsAuthoritative: spec.tightAllocationIsAuthoritative,
    );
    return BoxConstraints(
      minWidth: w.$1,
      maxWidth: w.$2,
      minHeight: h.$1,
      maxHeight: h.$2,
    );
  }

  ({double? width, double? height}) _publishedContentSize(
    BoxConstraints constraints,
    BoxConstraints childConstraints, {
    required double? containingWidth,
    required double? containingHeight,
  }) {
    final edgesWidth = _horizontalEdges(containingWidth);
    final edgesHeight = _verticalEdges(containingWidth);

    double? publishedWidth;
    if (constraints.hasTightWidth) {
      publishedWidth = constraints.maxWidth;
    } else {
      final authored = _outerLength(spec.width, containingWidth, edgesWidth);
      if (authored != null) {
        publishedWidth = authored;
      } else if (!spec.applySizing) {
        // Intrinsic-only wrappers leave the existing child width alone but
        // still describe the available block containing width to descendants.
        if (constraints.maxWidth.isFinite) {
          publishedWidth = constraints.maxWidth;
        }
      } else if (childConstraints.hasTightWidth) {
        publishedWidth = childConstraints.maxWidth;
      } else if (spec.fillWidth && constraints.maxWidth.isFinite) {
        publishedWidth = childConstraints.maxWidth;
      }
    }

    double? publishedHeight;
    if (constraints.hasTightHeight && spec.tightAllocationIsAuthoritative) {
      publishedHeight = constraints.maxHeight;
    } else {
      final authored = _outerLength(spec.height, containingHeight, edgesHeight);
      if (authored != null) {
        publishedHeight = authored;
      } else if (spec.tightAllocationIsAuthoritative &&
          childConstraints.hasTightHeight) {
        publishedHeight = childConstraints.maxHeight;
      }
    }

    return (
      width: publishedWidth == null
          ? null
          : math.max(0.0, publishedWidth - edgesWidth),
      height: publishedHeight == null
          ? null
          : math.max(0.0, publishedHeight - edgesHeight),
    );
  }

  bool _setContext({
    required double? nextContainingWidth,
    required double? nextContainingHeight,
    required double? nextContentWidth,
    required double? nextContentHeight,
  }) {
    final changed =
        containingBlockWidth != nextContainingWidth ||
        containingBlockHeight != nextContainingHeight ||
        contentWidth != nextContentWidth ||
        contentHeight != nextContentHeight;
    containingBlockWidth = nextContainingWidth;
    containingBlockHeight = nextContainingHeight;
    contentWidth = nextContentWidth;
    contentHeight = nextContentHeight;
    return changed;
  }

  void _invalidateChildLayout() {
    final current = child;
    if (current == null) return;
    // Intermediate proxies can otherwise skip layout when their constraints
    // are unchanged, hiding a changed percentage basis from descendants.
    void invalidate(RenderObject node) {
      if (node is RenderBox) node.markNeedsLayout();
      node.visitChildren(invalidate);
    }

    invalidate(current);
  }

  void _withDryContext<T>(
    BoxConstraints constraints,
    BoxConstraints childConstraints,
    double? containingWidth,
    double? containingHeight,
    T Function() callback,
  ) {
    final oldContainingWidth = containingBlockWidth;
    final oldContainingHeight = containingBlockHeight;
    final oldContentWidth = contentWidth;
    final oldContentHeight = contentHeight;
    final next = _publishedContentSize(
      constraints,
      childConstraints,
      containingWidth: containingWidth,
      containingHeight: containingHeight,
    );
    containingBlockWidth = containingWidth;
    containingBlockHeight = containingHeight;
    contentWidth = next.width;
    contentHeight = next.height;
    _dryContextDepth++;
    try {
      callback();
    } finally {
      _dryContextDepth--;
      containingBlockWidth = oldContainingWidth;
      containingBlockHeight = oldContainingHeight;
      contentWidth = oldContentWidth;
      contentHeight = oldContentHeight;
    }
  }

  Size? publishedBorderSize;

  @override
  void performLayout() {
    _nativeDocumentBoxLayoutDepth++;
    try {
      _performBoxLayout();
      final actual = child?.size ?? size;
      publishedBorderSize = Size(actual.width, actual.height);
    } finally {
      _nativeDocumentBoxLayoutDepth--;
    }
  }

  void _performBoxLayout() {
    final cbWidth = _percentWidthForDescendants(constraints);
    final cbHeight = _percentHeightForDescendants(constraints);
    final childConstraints = spec.applySizing
        ? _inner(
            constraints,
            containingWidth: cbWidth,
            containingHeight: cbHeight,
          )
        : constraints;
    final next = _publishedContentSize(
      constraints,
      childConstraints,
      containingWidth: cbWidth,
      containingHeight: cbHeight,
    );
    if (_setContext(
      nextContainingWidth: cbWidth,
      nextContainingHeight: cbHeight,
      nextContentWidth: next.width,
      nextContentHeight: next.height,
    )) {
      invokeLayoutCallback<BoxConstraints>((_) => _invalidateChildLayout());
    }
    _layoutContextActive = true;
    try {
      if (child == null) {
        size = constraints.smallest;
      } else {
        child!.layout(childConstraints, parentUsesSize: true);
        size = constraints.constrain(child!.size);
        if (spec.intrinsicWidthIsMinimum && spec.width == null) {
          // Publishing a changed containing block invalidates child caches.
          // Restore the intrinsic dependency after that invalidation/layout:
          // a later image decode must resize this auto-width box even when
          // its initially empty image received tight width/height constraints.
          child!.getMaxIntrinsicWidth(double.infinity);
          child!.getMaxIntrinsicHeight(double.infinity);
        }
      }
    } finally {
      _layoutContextActive = false;
    }
  }

  @override
  Size computeDryLayout(BoxConstraints constraints) {
    final cbWidth = _dryContainingBlockWidth(constraints);
    final cbHeight = _dryContainingBlockHeight(constraints);
    final childConstraints = spec.applySizing
        ? _inner(
            constraints,
            containingWidth: cbWidth,
            containingHeight: cbHeight,
          )
        : constraints;
    Size result = Size.zero;
    _withDryContext(constraints, childConstraints, cbWidth, cbHeight, () {
      result = constraints.constrain(
        child?.getDryLayout(childConstraints) ?? Size.zero,
      );
    });
    return result;
  }

  @override
  double? computeDryBaseline(
    BoxConstraints constraints,
    TextBaseline baseline,
  ) {
    final cbWidth = _dryContainingBlockWidth(constraints);
    final cbHeight = _dryContainingBlockHeight(constraints);
    final childConstraints = spec.applySizing
        ? _inner(
            constraints,
            containingWidth: cbWidth,
            containingHeight: cbHeight,
          )
        : constraints;
    double? result;
    _withDryContext(constraints, childConstraints, cbWidth, cbHeight, () {
      result = child?.getDryBaseline(childConstraints, baseline);
    });
    return result;
  }

  double _intrinsic(
    double natural,
    NativeFlexLength? preferred,
    NativeFlexLength? minimum,
    NativeFlexLength? maximum,
    double edges,
  ) {
    // Intrinsic queries have no definite containing block, so percentage
    // lengths remain unresolved. Fixed values still contribute their edges.
    double? outer(NativeFlexLength? value) {
      final resolved = value?.resolve(null);
      if (resolved == null) return null;
      return spec.lengthsAreContentBox ? resolved + edges : resolved;
    }

    final lower = math.max(edges, outer(minimum) ?? 0);
    final upper = math.max(lower, outer(maximum) ?? double.infinity);
    return (outer(preferred) ?? natural).clamp(lower, upper).toDouble();
  }

  @override
  double computeMinIntrinsicWidth(double height) => _intrinsic(
    child?.getMinIntrinsicWidth(height) ?? 0,
    spec.width,
    spec.minWidth,
    spec.maxWidth,
    math.max(0.0, spec.horizontalEdges),
  );

  @override
  double computeMaxIntrinsicWidth(double height) => _intrinsic(
    child?.getMaxIntrinsicWidth(height) ?? 0,
    spec.width,
    spec.minWidth,
    spec.maxWidth,
    math.max(0.0, spec.horizontalEdges),
  );

  double _intrinsicHeight(double width, bool maximum) {
    final edges = math.max(0.0, spec.verticalEdges);
    final horizontalEdges = math.max(0.0, spec.horizontalEdges);
    double? outerWidth(NativeFlexLength? value) {
      final resolved = value?.resolve(null);
      if (resolved == null) return null;
      return spec.lengthsAreContentBox ? resolved + horizontalEdges : resolved;
    }

    final lowerWidth = math.max(
      horizontalEdges,
      outerWidth(spec.minWidth) ?? 0,
    );
    final upperWidth = math.max(
      lowerWidth,
      outerWidth(spec.maxWidth) ?? double.infinity,
    );
    final authoredWidth = outerWidth(spec.width);
    final childWidth = (authoredWidth ?? width)
        .clamp(lowerWidth, upperWidth)
        .toDouble();
    final natural = maximum
        ? child?.getMaxIntrinsicHeight(childWidth) ?? 0
        : child?.getMinIntrinsicHeight(childWidth) ?? 0;
    return _intrinsic(
      natural,
      spec.height,
      spec.minHeight,
      spec.maxHeight,
      edges,
    );
  }

  @override
  double computeMinIntrinsicHeight(double width) =>
      _intrinsicHeight(width, false);

  @override
  double computeMaxIntrinsicHeight(double width) =>
      _intrinsicHeight(width, true);
}

/// Adds CSS percentage padding using the nearest NativeDocumentBox's
/// containing-block content width for all four sides.
class NativeDocumentPercentagePadding extends SingleChildRenderObjectWidget {
  const NativeDocumentPercentagePadding({
    super.key,
    required super.child,
    required this.fractions,
  });

  /// Fractions where `0.1` represents `10%`.
  final EdgeInsets fractions;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderNativeDocumentPercentagePadding(fractions);

  @override
  void updateRenderObject(
    BuildContext context,
    covariant RenderObject renderObject,
  ) {
    (renderObject as _RenderNativeDocumentPercentagePadding).fractions =
        fractions;
  }
}

/// Applies percentage CSS margins using the ancestor containing block's
/// content width for all four sides.
class NativeDocumentPercentageMargin extends SingleChildRenderObjectWidget {
  const NativeDocumentPercentageMargin({
    super.key,
    required super.child,
    required this.fractions,
    this.fixed = EdgeInsets.zero,
    this.collapsedTop,
  });

  /// Fractions where `0.1` represents `10%`.
  final EdgeInsets fractions;

  /// Fixed signed insets supplement percentage margins (for negative CSS
  /// horizontal margins, which the HTML core clamps to zero).
  final EdgeInsets fixed;
  final NativeDocumentTopMarginGroup? collapsedTop;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderNativeDocumentPercentageMargin(fractions, fixed, collapsedTop);

  @override
  void updateRenderObject(
    BuildContext context,
    covariant RenderObject renderObject,
  ) {
    (renderObject as _RenderNativeDocumentPercentageMargin)
      ..fractions = fractions
      ..fixed = fixed
      ..collapsedTop = collapsedTop;
  }
}

class _RenderNativeDocumentPercentageMargin extends RenderShiftedBox {
  _RenderNativeDocumentPercentageMargin(
    this._fractions,
    this._fixed,
    this._collapsedTop,
  ) : super(null);

  NativeDocumentTopMarginGroup? _collapsedTop;
  double _resolvedTop = 0;
  set collapsedTop(NativeDocumentTopMarginGroup? value) {
    if (identical(_collapsedTop, value)) return;
    _collapsedTop = value;
    markNeedsLayout();
  }

  @override
  void markNeedsLayout() {
    _invalidateMarginLayoutOwner(this);
    super.markNeedsLayout();
  }

  EdgeInsets _fixed;
  set fixed(EdgeInsets value) {
    if (_fixed == value) return;
    _fixed = value;
    markNeedsLayout();
  }

  EdgeInsets _fractions;
  set fractions(EdgeInsets value) {
    if (_fractions == value) return;
    _fractions = value;
    markNeedsLayout();
  }

  EdgeInsets _margin({bool dry = false}) {
    final context = _findDocumentContainingBlock(parent);
    if (dry && !(context?.isActive ?? false)) return _fixed;
    final width = context?.width;
    if (width == null || !width.isFinite || width < 0) return _fixed;
    double side(double fraction) => fraction.isFinite ? fraction * width : 0;
    return EdgeInsets.fromLTRB(
          side(_fractions.left),
          side(_fractions.top),
          side(_fractions.right),
          side(_fractions.bottom),
        ) +
        _fixed;
  }

  @override
  void setupParentData(covariant RenderObject child) {
    if (child.parentData is! BoxParentData) {
      child.parentData = BoxParentData();
    }
  }

  @override
  void performLayout() {
    final rawMargin = _margin();
    final margin = _collapsedTop == null
        ? rawMargin
        : rawMargin.copyWith(top: _resolvedTop);
    if (child == null) {
      size = constraints.constrain(
        Size(math.max(0.0, margin.horizontal), math.max(0.0, margin.vertical)),
      );
      return;
    }
    child!.layout(constraints.deflate(margin), parentUsesSize: true);
    size = constraints.constrain(
      Size(
        math.max(0.0, child!.size.width + margin.horizontal),
        math.max(0.0, child!.size.height + margin.vertical),
      ),
    );
    (child!.parentData! as BoxParentData).offset = Offset(
      margin.left,
      margin.top,
    );
  }

  @override
  Size computeDryLayout(BoxConstraints constraints) {
    final rawMargin = _margin(dry: true);
    final margin = _collapsedTop == null
        ? rawMargin
        : rawMargin.copyWith(top: _resolvedTop);
    final childSize = child?.getDryLayout(constraints.deflate(margin));
    return constraints.constrain(
      Size(
        math.max(0.0, (childSize?.width ?? 0) + margin.horizontal),
        math.max(0.0, (childSize?.height ?? 0) + margin.vertical),
      ),
    );
  }

  @override
  double? computeDryBaseline(
    BoxConstraints constraints,
    TextBaseline baseline,
  ) {
    final rawMargin = _margin(dry: true);
    final margin = _collapsedTop == null
        ? rawMargin
        : rawMargin.copyWith(top: _resolvedTop);
    final value = child?.getDryBaseline(constraints.deflate(margin), baseline);
    return value == null ? null : value + margin.top;
  }

  @override
  double computeMinIntrinsicWidth(double height) =>
      child?.getMinIntrinsicWidth(height) ?? 0;

  @override
  double computeMaxIntrinsicWidth(double height) =>
      child?.getMaxIntrinsicWidth(height) ?? 0;

  @override
  double computeMinIntrinsicHeight(double width) =>
      (child?.getMinIntrinsicHeight(width) ?? 0) +
      (_collapsedTop == null ? 0 : _resolvedTop);

  @override
  double computeMaxIntrinsicHeight(double width) =>
      (child?.getMaxIntrinsicHeight(width) ?? 0) +
      (_collapsedTop == null ? 0 : _resolvedTop);
}

/// Returns actual padding from the latest completed native layout.
/// Scroll viewports use this to retain trailing padding in overflow extents.
EdgeInsets? nativeDocumentPaddingInsets(RenderBox box) {
  if (!box.attached || !box.hasSize) return null;
  if (box is _RenderNativeDocumentPercentagePadding) return box.laidOutPadding;
  if (box is RenderPadding) {
    try {
      return box.padding.resolve(box.textDirection);
    } on Object {
      return null;
    }
  }
  return null;
}

class _RenderNativeDocumentPercentagePadding extends RenderShiftedBox {
  _RenderNativeDocumentPercentagePadding(this._fractions) : super(null);

  EdgeInsets _fractions;
  EdgeInsets? laidOutPadding;
  set fractions(EdgeInsets value) {
    if (_fractions == value) return;
    _fractions = value;
    markNeedsLayout();
  }

  EdgeInsets _padding({bool dry = false}) {
    RenderObject? ancestor = parent;
    while (ancestor != null &&
        ancestor is! _RenderDocumentBox &&
        ancestor is! _RenderNativeDocumentContainingBlock) {
      ancestor = ancestor.parent;
    }
    final context = _findDocumentContainingBlock(parent);
    if (dry && !(context?.isActive ?? false)) return EdgeInsets.zero;
    final width = ancestor is _RenderDocumentBox
        ? ancestor.containingBlockWidth
        : ancestor is _RenderNativeDocumentContainingBlock
        ? ancestor.contentWidth
        : null;
    if (width == null || !width.isFinite || width < 0) return EdgeInsets.zero;
    double side(double fraction) =>
        fraction.isFinite ? math.max(0.0, fraction * width) : 0;
    return EdgeInsets.fromLTRB(
      side(_fractions.left),
      side(_fractions.top),
      side(_fractions.right),
      side(_fractions.bottom),
    );
  }

  BoxConstraints _deflate(BoxConstraints constraints, EdgeInsets padding) =>
      constraints.deflate(padding);

  @override
  void setupParentData(covariant RenderObject child) {
    if (child.parentData is! BoxParentData) {
      child.parentData = BoxParentData();
    }
  }

  @override
  void performLayout() {
    final padding = _padding();
    laidOutPadding = padding;
    if (child == null) {
      size = constraints.constrain(Size(padding.horizontal, padding.vertical));
      return;
    }
    child!.layout(_deflate(constraints, padding), parentUsesSize: true);
    size = constraints.constrain(
      Size(
        child!.size.width + padding.horizontal,
        child!.size.height + padding.vertical,
      ),
    );
    final parentData = child!.parentData! as BoxParentData;
    parentData.offset = Offset(padding.left, padding.top);
  }

  @override
  Size computeDryLayout(BoxConstraints constraints) {
    final padding = _padding(dry: true);
    final childSize = child?.getDryLayout(_deflate(constraints, padding));
    return constraints.constrain(
      Size(
        (childSize?.width ?? 0) + padding.horizontal,
        (childSize?.height ?? 0) + padding.vertical,
      ),
    );
  }

  @override
  double? computeDryBaseline(
    BoxConstraints constraints,
    TextBaseline baseline,
  ) {
    final padding = _padding(dry: true);
    final value = child?.getDryBaseline(
      _deflate(constraints, padding),
      baseline,
    );
    return value == null ? null : value + padding.top;
  }

  @override
  double computeMinIntrinsicWidth(double height) =>
      child?.getMinIntrinsicWidth(height) ?? 0;

  @override
  double computeMaxIntrinsicWidth(double height) =>
      child?.getMaxIntrinsicWidth(height) ?? 0;

  @override
  double computeMinIntrinsicHeight(double width) =>
      child?.getMinIntrinsicHeight(width) ?? 0;

  @override
  double computeMaxIntrinsicHeight(double width) =>
      child?.getMaxIntrinsicHeight(width) ?? 0;
}

/// Returns the decorated border-box surface owned by the native sizing wrapper
/// below a geometry marker. The marker itself may be wrapped in transparent
/// layout proxies. If the subtree is ambiguous, its marker is returned so
/// callers never accidentally measure a nested element's box.
RenderBox? nativeDocumentBoxSurface(RenderBox marker, {Object? owner}) {
  _RenderDocumentBox? found;
  var ambiguous = false;

  void visit(RenderObject object) {
    if (found != null && ambiguous) return;
    if (object is _RenderDocumentBox) {
      if (owner == null || identical(object.spec.geometryOwner, owner)) {
        if (found == null) {
          found = object;
        } else if (!identical(found, object)) {
          ambiguous = true;
        }
      }
      // Stop at each NativeDocumentBox: a nested native box belongs to a
      // different DOM element and must never replace this box's own surface.
      return;
    }
    object.visitChildren(visit);
  }

  visit(marker);
  if (ambiguous || found == null) return marker;
  final box = found!;
  // In intrinsic-only mode the native flow child may have a smaller
  // descendant surface than the CSS block box represented by the marker.
  // The marker is the authoritative outer block in that mode.
  if (!box.spec.applySizing) return marker;
  if (box.spec.applySizing && box.child != null) return box.child;
  return box;
}

/// Captures the containing block and applied box edges of an owned sizing box.
/// The surface must be the exact child returned by [nativeDocumentBoxSurface];
/// walking to an arbitrary ancestor could expose another DOM node's metrics.
({
  double? containingWidth,
  double? containingHeight,
  double? usedContainingHeight,
  double horizontalEdges,
  double verticalEdges,
})?
nativeDocumentComputedBoxMetrics(RenderBox surface) {
  final box = surface.parent;
  if (box is! _RenderDocumentBox ||
      !identical(box.child, surface) ||
      !box.spec.applySizing ||
      !box.attached ||
      !box.hasSize) {
    return null;
  }
  final width = box.containingBlockWidth;
  final percentageWidth = width != null && width.isFinite ? width : 0.0;
  final containing = nativeDocumentContainingBlockMetrics(box);
  return (
    containingWidth: width,
    containingHeight: box.containingBlockHeight,
    usedContainingHeight: containing?.usedHeight,
    horizontalEdges:
        box.spec.horizontalEdges +
        box.spec.percentagePadding.horizontal * percentageWidth,
    verticalEdges:
        box.spec.verticalEdges +
        box.spec.percentagePadding.vertical * percentageWidth,
  );
}

/// Reads the real containing block of an atomic inline surface that has no
/// owned sizing wrapper. This supplies percentage bases only; it never borrows
/// another element's box edges or substitutes ancestor dimensions for its own.
({double? width, double? height, double? usedHeight})?
nativeDocumentContainingBlockMetrics(RenderBox surface) {
  RenderObject? ancestor = surface.parent;
  while (ancestor != null) {
    if (ancestor is _RenderDocumentBox) {
      final child = ancestor.child;
      if (!ancestor.attached ||
          !ancestor.hasSize ||
          child == null ||
          !child.attached ||
          !child.hasSize) {
        return null;
      }
      final parentWidth = ancestor.containingBlockWidth ?? 0;
      final usedHeight = math.max(
        0.0,
        child.size.height -
            ancestor.spec.verticalEdges -
            ancestor.spec.percentagePadding.vertical * parentWidth,
      );
      return (
        width: ancestor.contentWidth,
        height: ancestor.contentHeight,
        usedHeight: usedHeight,
      );
    }
    if (ancestor is _RenderNativeDocumentContainingBlock) {
      if (!ancestor.attached || !ancestor.hasSize) return null;
      return (
        width: ancestor.contentWidth,
        height: ancestor.contentHeight,
        usedHeight:
            ancestor.contentHeight ??
            ((ancestor.child?.hasSize ?? false)
                ? ancestor.child!.size.height
                : null),
      );
    }
    ancestor = ancestor.parent;
  }
  return null;
}

/// The owned box publishes its actual border size during its own layout.
/// An ancestor must not read a grandchild RenderBox.size during layout.
({RenderBox surface, Size size})? nativeDocumentPositioningSurface(
  RenderBox marker, {
  required Object owner,
}) {
  _RenderDocumentBox? found;
  void visit(RenderObject node) {
    if (node is _RenderDocumentBox) {
      if (identical(node.spec.geometryOwner, owner)) found = node;
      return;
    }
    node.visitChildren(visit);
  }

  visit(marker);
  final actual = found?.publishedBorderSize;
  if (actual == null) return null;
  final surface = nativeDocumentBoxSurface(marker, owner: owner);
  return surface == null ? null : (surface: surface, size: actual);
}
