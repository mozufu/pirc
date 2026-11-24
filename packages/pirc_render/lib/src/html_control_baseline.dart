import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// Checkbox/radio/range are replaced boxes whose inline baseline is their
/// bottom margin edge. Supply it explicitly for dry and real layout; Flutter
/// proxy renderers cannot propagate a null dry baseline through a gesture tree.
class NativeHtmlReplacedBaseline extends SingleChildRenderObjectWidget {
  const NativeHtmlReplacedBaseline({super.key, required super.child});
  @override
  RenderObject createRenderObject(BuildContext context) =>
      _ReplacedBaselineBox();
}

class _ReplacedBaselineBox extends RenderProxyBox {
  @override
  double computeDryBaseline(
    BoxConstraints constraints,
    TextBaseline baseline,
  ) => getDryLayout(constraints).height;
  @override
  double computeDistanceToActualBaseline(TextBaseline baseline) => size.height;
}
