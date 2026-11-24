import 'dart:math' as math;
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// The pinned code header is a row with natural child widths, shrink factor 1,
/// centered children and remaining space between them. Measure rendered children
/// so large text does not force the copy action outside the header.
class NativeHtmlCodeHeader extends MultiChildRenderObjectWidget {
  const NativeHtmlCodeHeader({super.key, required super.children});
  @override
  RenderObject createRenderObject(BuildContext context) => _CodeHeaderBox();
}

class _CodeHeaderBox extends RenderBox
    with
        ContainerRenderObjectMixin<
          RenderBox,
          ContainerBoxParentData<RenderBox>
        >,
        RenderBoxContainerDefaultsMixin<
          RenderBox,
          ContainerBoxParentData<RenderBox>
        > {
  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! ContainerBoxParentData<RenderBox>) {
      child.parentData = _CodeHeaderParentData();
    }
  }

  List<RenderBox> get children {
    final result = <RenderBox>[];
    for (
      var child = firstChild;
      child != null;
      child =
          (child.parentData! as ContainerBoxParentData<RenderBox>).nextSibling
    ) {
      result.add(child);
    }
    return result;
  }

  List<double> widths(List<RenderBox> items, double available) {
    final natural = items
        .map((child) => child.getMaxIntrinsicWidth(double.infinity))
        .toList();
    final total = natural.fold<double>(0, (sum, value) => sum + value);
    if (!available.isFinite || total <= available || total == 0) return natural;
    return natural
        .map((width) => math.max(0.0, width * available / total))
        .toList();
  }

  @override
  void performLayout() {
    final items = children;
    final allocated = widths(items, constraints.maxWidth);
    var usedWidth = 0.0, height = 0.0;
    for (var i = 0; i < items.length; i++) {
      items[i].layout(
        BoxConstraints(maxWidth: allocated[i]),
        parentUsesSize: true,
      );
      usedWidth += items[i].size.width;
      height = math.max(height, items[i].size.height);
    }
    size = constraints.constrain(
      Size(
        constraints.hasBoundedWidth ? constraints.maxWidth : usedWidth,
        height,
      ),
    );
    final gap = items.length < 2
        ? 0.0
        : math.max(0.0, (size.width - usedWidth) / (items.length - 1));
    var left = 0.0;
    for (final child in items) {
      (child.parentData! as ContainerBoxParentData<RenderBox>).offset = Offset(
        left,
        (size.height - child.size.height) / 2,
      );
      left += child.size.width + gap;
    }
  }

  @override
  Size computeDryLayout(BoxConstraints constraints) {
    final items = children;
    final allocated = widths(items, constraints.maxWidth);
    var usedWidth = 0.0, height = 0.0;
    for (var i = 0; i < items.length; i++) {
      final childSize = items[i].getDryLayout(
        BoxConstraints(maxWidth: allocated[i]),
      );
      usedWidth += childSize.width;
      height = math.max(height, childSize.height);
    }
    return constraints.constrain(
      Size(
        constraints.hasBoundedWidth ? constraints.maxWidth : usedWidth,
        height,
      ),
    );
  }

  @override
  double computeMaxIntrinsicWidth(double height) => children.fold<double>(
    0,
    (width, child) => width + child.getMaxIntrinsicWidth(height),
  );
  @override
  double computeMinIntrinsicWidth(double height) => children.fold<double>(
    0,
    (width, child) => width + child.getMinIntrinsicWidth(height),
  );
  @override
  double computeMinIntrinsicHeight(double width) =>
      computeDryLayout(BoxConstraints(maxWidth: width)).height;
  @override
  double computeMaxIntrinsicHeight(double width) =>
      computeMinIntrinsicHeight(width);
  @override
  void paint(PaintingContext context, Offset offset) =>
      defaultPaint(context, offset);
  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) =>
      defaultHitTestChildren(result, position: position);
}

class _CodeHeaderParentData extends ContainerBoxParentData<RenderBox> {}
