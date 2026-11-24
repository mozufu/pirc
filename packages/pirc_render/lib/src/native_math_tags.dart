// ignore_for_file: implementation_imports

import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_math_fork/src/render/layout/line.dart';

/// The available width of the display-math viewport.
///
/// Math renderers commonly receive unbounded horizontal constraints inside a
/// horizontal scroll view. This inherited value keeps equation tags positioned
/// against the visible display width instead of the formula's natural width.
class NativeMathTagViewport extends InheritedWidget {
  const NativeMathTagViewport({
    super.key,
    required this.width,
    required super.child,
  }) : assert(width >= 0 && width < double.infinity);

  final double width;

  static double? maybeOf(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<NativeMathTagViewport>()
      ?.width;

  @override
  bool updateShouldNotify(NativeMathTagViewport oldWidget) =>
      width != oldWidget.width;
}

/// A stable handle to one equation row's live render object.
///
/// The handle stores a [GlobalKey], not a RenderBox reference, so it resolves
/// to the current row after rebuilds and returns null while that row is
/// detached. The keyed wrapper used by [NativeMathTagRow] creates no render
/// object, which is required by flutter_math_fork's EqnArray column alignment.
class NativeMathTagAnchor {
  NativeMathTagAnchor({String? debugLabel})
    : key = GlobalKey(debugLabel: debugLabel);

  final GlobalKey key;

  RenderBox? get renderBox {
    final object = key.currentContext?.findRenderObject();
    if (object is! RenderBox || !object.attached || !object.hasSize) {
      return null;
    }
    return object;
  }

  /// Returns the row's alphabetic baseline in [ancestor]'s local coordinates.
  ///
  /// The value is null when the row is detached or no longer belongs to the
  /// supplied body. It is intentionally resolved on demand so stale render
  /// coordinates are never retained across layout or navigation changes.
  double? baselineOffsetWithin(RenderBox ancestor) {
    final row = renderBox;
    if (row == null) return null;
    try {
      // Anchors intentionally identify flutter_math_fork RenderLine rows. Its
      // cached baseline is public; getDistanceToBaseline cannot be queried on
      // a deep descendant outside that descendant's immediate layout parent.
      if (row is! RenderLine) return null;
      final rowBaseline = row.maxHeightAboveBaseline;
      return row.localToGlobal(Offset(0, rowBaseline), ancestor: ancestor).dy;
    } on Object {
      return null;
    }
  }
}

/// Adds an anchor key without inserting a RenderObject around [child].
class NativeMathTagRow extends StatelessWidget {
  const NativeMathTagRow({
    super.key,
    required this.child,
    required this.anchor,
  });

  final Widget child;
  final NativeMathTagAnchor anchor;

  @override
  Widget build(BuildContext context) =>
      KeyedSubtree(key: anchor.key, child: child);
}

/// A tag rendered at the display's right edge or at an anchored row baseline.
class NativeMathTag {
  const NativeMathTag({required this.math, this.anchor, this.column});

  final Widget math;
  final NativeMathTagAnchor? anchor;

  /// Identity shared by tags that occupy one equation-tag column.
  ///
  /// Null keeps this tag independently right-aligned. Tags in a non-null
  /// column are centered within the maximum natural width of that column.
  final Object? column;
}

/// Places display math independently from its equation tags.
///
/// [math] keeps its natural size and is centered against
/// [NativeMathTagViewport.width]. Each tag is positioned at the viewport's
/// right edge; its optional row anchor changes only its vertical baseline.
class NativeTaggedMath extends MultiChildRenderObjectWidget {
  NativeTaggedMath({
    super.key,
    required this.math,
    required List<NativeMathTag> tags,
  }) : tags = List<NativeMathTag>.unmodifiable(tags),
       super(children: [math, ...tags.map((tag) => tag.math)]);

  final Widget math;
  final List<NativeMathTag> tags;

  @override
  RenderNativeTaggedMath createRenderObject(BuildContext context) =>
      RenderNativeTaggedMath._(
        NativeMathTagViewport.maybeOf(context),
        anchors: tags.map((tag) => tag.anchor).toList(growable: false),
        columns: tags.map((tag) => tag.column).toList(growable: false),
      );

  @override
  void updateRenderObject(
    BuildContext context,
    RenderNativeTaggedMath renderObject,
  ) {
    renderObject
      ..viewportWidth = NativeMathTagViewport.maybeOf(context)
      ..anchors = tags.map((tag) => tag.anchor).toList(growable: false)
      ..columns = tags.map((tag) => tag.column).toList(growable: false);
  }
}

class _NativeMathTagParentData extends ContainerBoxParentData<RenderBox> {}

/// Render object for [NativeTaggedMath].
class RenderNativeTaggedMath extends RenderBox
    with
        ContainerRenderObjectMixin<RenderBox, _NativeMathTagParentData>,
        RenderBoxContainerDefaultsMixin<RenderBox, _NativeMathTagParentData> {
  RenderNativeTaggedMath._(
    this._viewportWidth, {
    List<RenderBox>? children,
    required List<NativeMathTagAnchor?> anchors,
    required List<Object?> columns,
  }) : _anchors = List<NativeMathTagAnchor?>.unmodifiable(anchors) {
    _columns = List<Object?>.unmodifiable(columns);
    addAll(children);
  }

  double? get viewportWidth => _viewportWidth;
  double? _viewportWidth;
  set viewportWidth(double? value) {
    if (_viewportWidth != value) {
      _viewportWidth = value;
      markNeedsLayout();
    }
  }

  List<NativeMathTagAnchor?> get anchors => _anchors;
  List<NativeMathTagAnchor?> _anchors;
  set anchors(List<NativeMathTagAnchor?> value) {
    if (!listEquals(_anchors, value)) {
      _anchors = List<NativeMathTagAnchor?>.unmodifiable(value);
      markNeedsLayout();
    }
  }

  List<Object?> get columns => _columns;
  late List<Object?> _columns;
  set columns(List<Object?> value) {
    if (_sameIdentityList(_columns, value)) return;
    _columns = List<Object?>.unmodifiable(value);
    markNeedsLayout();
  }

  bool _sameIdentityList(List<Object?> first, List<Object?> second) {
    if (identical(first, second)) return true;
    if (first.length != second.length) return false;
    for (var index = 0; index < first.length; index++) {
      if (!identical(first[index], second[index])) return false;
    }
    return true;
  }

  double _baseline = 0;
  double get baseline => _baseline;

  double _resolvedViewport(double bodyWidth, BoxConstraints constraints) {
    final inherited = _viewportWidth;
    if (inherited != null && inherited.isFinite) return inherited;
    if (constraints.hasBoundedWidth) return constraints.maxWidth;
    return bodyWidth;
  }

  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! _NativeMathTagParentData) {
      child.parentData = _NativeMathTagParentData();
    }
  }

  RenderBox? get _body => firstChild;

  List<RenderBox> get _tagChildren {
    final result = <RenderBox>[];
    final body = firstChild;
    if (body == null) return result;
    var child = childAfter(body);
    while (child != null) {
      result.add(child);
      child = childAfter(child);
    }
    return result;
  }

  @override
  void performLayout() {
    final body = _body;
    if (body == null) {
      size = constraints.smallest;
      _baseline = size.height;
      return;
    }

    // Formula and tag glyphs retain natural width even when the visible math
    // viewport is narrower. NativeMathDisplayBlock provides horizontal scroll.
    final naturalConstraints = BoxConstraints(
      maxWidth: double.infinity,
      maxHeight: constraints.maxHeight,
    );
    body.layout(naturalConstraints, parentUsesSize: true);
    final tags = _tagChildren;
    for (final tag in tags) {
      tag.layout(naturalConstraints, parentUsesSize: true);
    }

    final columnWidths = Map<Object, double>.identity();
    for (
      var index = 0;
      index < tags.length && index < _columns.length;
      index++
    ) {
      final column = _columns[index];
      if (column == null) continue;
      columnWidths.update(
        column,
        (width) => math.max(width, tags[index].size.width),
        ifAbsent: () => tags[index].size.width,
      );
    }

    final viewport = _resolvedViewport(body.size.width, constraints);
    final bodyLeft = (viewport - body.size.width) / 2;
    final bodyBaseline =
        body.getDistanceToBaseline(TextBaseline.alphabetic) ?? body.size.height;
    final tagTops = <double>[];
    var minY = 0.0;
    var maxY = body.size.height;
    for (var index = 0; index < tags.length; index++) {
      final tag = tags[index];
      final anchorBaseline = index < _anchors.length
          ? _anchors[index]?.baselineOffsetWithin(body)
          : null;
      final tagBaseline =
          tag.getDistanceToBaseline(TextBaseline.alphabetic) ?? tag.size.height;
      final top = (anchorBaseline ?? bodyBaseline) - tagBaseline;
      tagTops.add(top);
      minY = math.min(minY, top);
      maxY = math.max(maxY, top + tag.size.height);
    }

    // A centered overwide formula can extend to the left of the scroll
    // viewport. Its visible right extent determines the scrollable child size.
    final contentRight = math.max(viewport, bodyLeft + body.size.width);
    size = constraints.constrain(Size(contentRight, maxY - minY));
    _baseline = bodyBaseline - minY;

    final bodyData = body.parentData! as _NativeMathTagParentData;
    bodyData.offset = Offset(bodyLeft, -minY);
    for (var index = 0; index < tags.length; index++) {
      final tag = tags[index];
      final data = tag.parentData! as _NativeMathTagParentData;
      final column = index < _columns.length ? _columns[index] : null;
      final columnWidth = column == null ? null : columnWidths[column];
      final left = columnWidth == null
          ? viewport - tag.size.width
          : viewport - columnWidth + (columnWidth - tag.size.width) / 2;
      data.offset = Offset(left, tagTops[index] - minY);
    }
  }

  @override
  Size computeDryLayout(BoxConstraints constraints) {
    final body = _body;
    if (body == null) return constraints.smallest;
    final naturalConstraints = BoxConstraints(
      maxWidth: double.infinity,
      maxHeight: constraints.maxHeight,
    );
    final bodySize = body.getDryLayout(naturalConstraints);
    final viewport = _resolvedViewport(bodySize.width, constraints);
    final bodyLeft = (viewport - bodySize.width) / 2;
    var height = bodySize.height;
    var tag = childAfter(body);
    while (tag != null) {
      final tagSize = tag.getDryLayout(naturalConstraints);
      // RenderLine in the pinned math fork does not implement dry-baseline
      // queries. Keep dry sizing finite; actual layout applies row baselines.
      height = math.max(height, tagSize.height);
      tag = childAfter(tag);
    }
    return constraints.constrain(
      Size(math.max(viewport, bodyLeft + bodySize.width), height),
    );
  }

  @override
  double? computeDryBaseline(
    BoxConstraints constraints,
    TextBaseline baseline,
  ) {
    // RenderLine has no dry-baseline implementation in flutter_math_fork.
    // Actual layout still exposes the body's measured baseline.
    return null;
  }

  @override
  double computeMinIntrinsicWidth(double height) {
    final body = _body;
    if (body == null) return 0;
    final bodyWidth = body.getMinIntrinsicWidth(height);
    final viewport = _viewportWidth ?? 0;
    return math.max(viewport, (viewport - bodyWidth) / 2 + bodyWidth);
  }

  @override
  double computeMaxIntrinsicWidth(double height) {
    final body = _body;
    if (body == null) return 0;
    final bodyWidth = body.getMaxIntrinsicWidth(height);
    final viewport = _viewportWidth ?? 0;
    var width = math.max(viewport, (viewport - bodyWidth) / 2 + bodyWidth);
    var tag = childAfter(body);
    while (tag != null) {
      width = math.max(width, viewport);
      tag = childAfter(tag);
    }
    return width;
  }

  @override
  double computeMinIntrinsicHeight(double width) {
    var height = _body?.getMinIntrinsicHeight(width) ?? 0;
    final body = _body;
    var tag = body == null ? null : childAfter(body);
    while (tag != null) {
      height = math.max(height, tag.getMinIntrinsicHeight(width));
      tag = childAfter(tag);
    }
    return height;
  }

  @override
  double computeMaxIntrinsicHeight(double width) {
    var height = _body?.getMaxIntrinsicHeight(width) ?? 0;
    final body = _body;
    var tag = body == null ? null : childAfter(body);
    while (tag != null) {
      height = math.max(height, tag.getMaxIntrinsicHeight(width));
      tag = childAfter(tag);
    }
    return height;
  }

  @override
  double? computeDistanceToActualBaseline(TextBaseline baseline) => _baseline;

  @override
  void paint(PaintingContext context, Offset offset) =>
      defaultPaint(context, offset);

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) =>
      defaultHitTestChildren(result, position: position);

  @override
  void applyPaintTransform(RenderBox child, Matrix4 transform) =>
      transform.translateByDouble(
        (child.parentData! as _NativeMathTagParentData).offset.dx,
        (child.parentData! as _NativeMathTagParentData).offset.dy,
        0,
        1,
      );
}
