import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// Supplies explicit intrinsic metrics for a native HTML control whose actual
/// layout depends on parent constraints (for example, a CSS `LayoutBuilder`).
///
/// Flutter's [LayoutBuilder] cannot answer intrinsic or dry-layout queries.
/// Some browser-like parents, such as a fieldset legend, ask for those metrics
/// before performing the final layout. This wrapper answers those queries
/// from [intrinsicSize] and still forwards real layout constraints unchanged to
/// [child].
class NativeHtmlControlIntrinsic extends SingleChildRenderObjectWidget {
  const NativeHtmlControlIntrinsic({
    super.key,
    required this.intrinsicSize,
    this.baselineFromTop,
    required super.child,
  });

  /// Natural border-box size used only for intrinsic and dry-layout queries.
  final Size intrinsicSize;

  /// Alphabetic baseline distance from the top of the natural border box.
  ///
  /// Replaced controls without an internal text baseline use their bottom edge
  /// by default. Supplying a measured text baseline keeps inline controls
  /// aligned with surrounding text while making baseline queries safe through
  /// proxy and semantics render objects.
  final double? baselineFromTop;

  @override
  RenderNativeHtmlControlIntrinsic createRenderObject(BuildContext context) =>
      RenderNativeHtmlControlIntrinsic(intrinsicSize, baselineFromTop);

  @override
  void updateRenderObject(
    BuildContext context,
    RenderNativeHtmlControlIntrinsic renderObject,
  ) {
    renderObject
      ..intrinsicSize = intrinsicSize
      ..baselineFromTop = baselineFromTop;
  }
}

class RenderNativeHtmlControlIntrinsic extends RenderProxyBox {
  RenderNativeHtmlControlIntrinsic(this._intrinsicSize, this._baselineFromTop);

  Size _intrinsicSize;
  double? _baselineFromTop;

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

  @override
  double computeMinIntrinsicWidth(double height) => _intrinsicSize.width;

  @override
  double computeMaxIntrinsicWidth(double height) => _intrinsicSize.width;

  @override
  double computeMinIntrinsicHeight(double width) => _intrinsicSize.height;

  @override
  double computeMaxIntrinsicHeight(double width) => _intrinsicSize.height;

  @override
  Size computeDryLayout(BoxConstraints constraints) =>
      constraints.constrain(_intrinsicSize);

  @override
  double computeDryBaseline(BoxConstraints constraints, TextBaseline baseline) {
    final constrainedHeight = constraints.constrain(_intrinsicSize).height;
    return _baselineDistance(constrainedHeight);
  }

  @override
  double computeDistanceToActualBaseline(TextBaseline baseline) =>
      _baselineDistance(size.height);

  double _baselineDistance(double height) =>
      (_baselineFromTop ?? _intrinsicSize.height).clamp(0.0, height).toDouble();

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
