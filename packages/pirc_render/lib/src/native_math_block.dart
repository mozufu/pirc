import 'dart:math' as math;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'native_math_tags.dart';

/// Reproduces the vertical and overflow behavior of the pinned Markdown
/// math-block > katex-display > katex layout.
///
/// [bodyFontSize] is the unscaled Markdown font size. [mathFontSize] is the
/// unscaled font size after the KaTeX 1.08em rule.
class NativeMathDisplayBlock extends StatelessWidget {
  const NativeMathDisplayBlock({
    super.key,
    required this.child,
    required this.bodyFontSize,
    required this.mathFontSize,
  });

  final Widget child;
  final double bodyFontSize;
  final double mathFontSize;

  @override
  Widget build(BuildContext context) {
    final textScaler = MediaQuery.textScalerOf(context);
    final scaledBodyFontSize = textScaler.scale(bodyFontSize);
    final scaledMathFontSize = textScaler.scale(mathFontSize);

    return LayoutBuilder(
      builder: (context, viewportConstraints) {
        final minWidth = viewportConstraints.hasBoundedWidth
            ? viewportConstraints.maxWidth
            : 0.0;
        return SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          clipBehavior: Clip.hardEdge,
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Padding(
            padding: EdgeInsets.symmetric(vertical: scaledBodyFontSize * .3),
            child: ConstrainedBox(
              constraints: BoxConstraints(minWidth: minWidth),
              child: Center(
                child: NativeMathTagViewport(
                  width: minWidth,
                  child: NativeMathLineBox(
                    minAscent: scaledMathFontSize * .9,
                    minDescent: scaledMathFontSize * .3,
                    child: child,
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// A baseline-aware minimum line box for the KaTeX display line.
///
/// It supplies KaTeX's 1.2em normal line height for short formulas. For taller
/// formulas, it expands the ascent and descent independently around the
/// formula's real alphabetic baseline.
class NativeMathLineBox extends SingleChildRenderObjectWidget {
  const NativeMathLineBox({
    super.key,
    required this.minAscent,
    required this.minDescent,
    required super.child,
  });

  final double minAscent;
  final double minDescent;

  @override
  RenderNativeMathLineBox createRenderObject(BuildContext context) =>
      RenderNativeMathLineBox(minAscent: minAscent, minDescent: minDescent);

  @override
  void updateRenderObject(
    BuildContext context,
    RenderNativeMathLineBox renderObject,
  ) {
    renderObject
      ..minAscent = minAscent
      ..minDescent = minDescent;
  }
}

class RenderNativeMathLineBox extends RenderShiftedBox {
  RenderNativeMathLineBox({
    RenderBox? child,
    required double minAscent,
    required double minDescent,
  }) : _metrics = (ascent: minAscent, descent: minDescent),
       super(child);

  ({double ascent, double descent}) _metrics;
  double get minAscent => _metrics.ascent;
  set minAscent(double value) {
    if (_metrics.ascent != value) {
      _metrics = (ascent: value, descent: _metrics.descent);
      markNeedsLayout();
    }
  }

  double get minDescent => _metrics.descent;
  set minDescent(double value) {
    if (_metrics.descent != value) {
      _metrics = (ascent: _metrics.ascent, descent: value);
      markNeedsLayout();
    }
  }

  double _baseline = 0;
  double _childBaseline = 0;
  double get baseline => _baseline;
  double get childBaseline => _childBaseline;

  @override
  double computeMinIntrinsicWidth(double height) =>
      child?.getMinIntrinsicWidth(height) ?? 0;

  @override
  double computeMaxIntrinsicWidth(double height) =>
      child?.getMaxIntrinsicWidth(height) ?? 0;

  @override
  double computeMinIntrinsicHeight(double width) => _intrinsicHeightForWidth(
    width,
    fallbackHeight: child?.getMinIntrinsicHeight(width) ?? 0,
  );

  @override
  double computeMaxIntrinsicHeight(double width) => _intrinsicHeightForWidth(
    width,
    fallbackHeight: child?.getMaxIntrinsicHeight(width) ?? 0,
  );

  double _intrinsicHeightForWidth(
    double width, {
    required double fallbackHeight,
  }) {
    final currentChild = child;
    if (currentChild == null) return minAscent + minDescent;

    if (width.isFinite) {
      final childConstraints = BoxConstraints(maxWidth: width);
      try {
        final childSize = currentChild.getDryLayout(childConstraints);
        final childBaseline = _dryChildBaseline(
          currentChild,
          childConstraints,
          childSize,
        );
        final ascent = math.max(minAscent, childBaseline);
        final descent = math.max(minDescent, childSize.height - childBaseline);
        return ascent + descent;
      } on Object {
        // Some render objects cannot provide a dry layout. Reserve enough
        // room for their intrinsic height plus either minimum line-box side.
      }
    }

    return math.max(
      minAscent + minDescent,
      fallbackHeight + math.max(minAscent, minDescent),
    );
  }

  @override
  double? computeDistanceToActualBaseline(TextBaseline baseline) => _baseline;

  @override
  double? computeDryBaseline(
    BoxConstraints constraints,
    TextBaseline baseline,
  ) {
    final currentChild = child;
    if (currentChild == null) return 0;
    final childConstraints = constraints.loosen();
    final childSize = currentChild.getDryLayout(childConstraints);
    final childBaseline = _dryChildBaseline(
      currentChild,
      childConstraints,
      childSize,
    );
    return math.max(minAscent, childBaseline);
  }

  @override
  Size computeDryLayout(BoxConstraints constraints) {
    final currentChild = child;
    if (currentChild == null) return constraints.smallest;
    final childConstraints = constraints.loosen();
    final childSize = currentChild.getDryLayout(childConstraints);
    final childBaseline = _dryChildBaseline(
      currentChild,
      childConstraints,
      childSize,
    );
    final ascent = math.max(minAscent, childBaseline);
    final descent = math.max(minDescent, childSize.height - childBaseline);
    return constraints.constrain(Size(childSize.width, ascent + descent));
  }

  @override
  void performLayout() {
    final currentChild = child;
    if (currentChild == null) {
      size = constraints.smallest;
      _baseline = 0;
      return;
    }

    final childConstraints = constraints.loosen();
    currentChild.layout(childConstraints, parentUsesSize: true);
    final childBaseline =
        currentChild.getDistanceToBaseline(TextBaseline.alphabetic) ??
        currentChild.size.height;
    final ascent = math.max(minAscent, childBaseline);
    final descent = math.max(
      minDescent,
      currentChild.size.height - childBaseline,
    );
    _baseline = ascent;
    _childBaseline = childBaseline;
    size = constraints.constrain(
      Size(currentChild.size.width, ascent + descent),
    );
    (currentChild.parentData! as BoxParentData).offset = Offset(
      0,
      ascent - childBaseline,
    );
  }

  double _dryChildBaseline(
    RenderBox currentChild,
    BoxConstraints childConstraints,
    Size childSize,
  ) {
    try {
      return currentChild.getDryBaseline(
            childConstraints,
            TextBaseline.alphabetic,
          ) ??
          childSize.height;
    } on Object {
      return childSize.height;
    }
  }
}
