import 'dart:math' as math;
import 'package:flutter/widgets.dart';
import 'package:flutter/rendering.dart';

/// Gives replaced images CSS-like intrinsic widths without a
/// LayoutBuilder: tables may shrink the image below its natural width, while
/// unconstrained rows retain the natural dimensions.
class NativeImageFrame extends SingleChildRenderObjectWidget {
  const NativeImageFrame({
    super.key,
    required this.naturalSize,
    required super.child,
  });

  final Size naturalSize;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      RenderNativeImageFrame(naturalSize);

  @override
  void updateRenderObject(
    BuildContext context,
    covariant RenderNativeImageFrame renderObject,
  ) {
    renderObject.naturalSize = naturalSize;
  }
}

class RenderNativeImageFrame extends RenderProxyBox {
  RenderNativeImageFrame(this._naturalSize);

  Size _naturalSize;

  Size get naturalSize => _naturalSize;
  set naturalSize(Size value) {
    if (_naturalSize == value) return;
    _naturalSize = value;
    markNeedsLayout();
  }

  double get _aspectRatio => _naturalSize.width / _naturalSize.height;

  @override
  double computeMinIntrinsicWidth(double height) => 0;

  @override
  double computeMaxIntrinsicWidth(double height) => height.isFinite
      ? math.min(_naturalSize.width, math.max(0, height) * _aspectRatio)
      : _naturalSize.width;

  @override
  double computeMinIntrinsicHeight(double width) => width.isFinite
      ? math.min(_naturalSize.width, math.max(0, width)) / _aspectRatio
      : _naturalSize.height;

  @override
  double computeMaxIntrinsicHeight(double width) =>
      computeMinIntrinsicHeight(width);

  Size _computeSize(BoxConstraints constraints) {
    var width = _naturalSize.width;
    if (constraints.hasBoundedWidth) {
      width = math.min(width, constraints.maxWidth);
    }
    if (constraints.hasBoundedHeight) {
      width = math.min(width, constraints.maxHeight * _aspectRatio);
    }
    var height = width / _aspectRatio;
    if (width < constraints.minWidth) {
      width = constraints.minWidth;
      height = width / _aspectRatio;
    }
    if (height < constraints.minHeight) {
      height = constraints.minHeight;
      width = height * _aspectRatio;
    }
    return constraints.constrain(Size(width, height));
  }

  @override
  Size computeDryLayout(BoxConstraints constraints) =>
      _computeSize(constraints);

  @override
  double? computeDryBaseline(
    BoxConstraints constraints,
    TextBaseline baseline,
  ) => _computeSize(constraints).height;

  @override
  double? computeDistanceToActualBaseline(TextBaseline baseline) => size.height;

  @override
  void performLayout() {
    size = _computeSize(constraints);
    child?.layout(BoxConstraints.tight(size), parentUsesSize: true);
  }
}
