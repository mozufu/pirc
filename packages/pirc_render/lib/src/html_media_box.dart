import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter/foundation.dart' show mapEquals;

/// Replaced-element sizing for media. CSS pixels and percentages override
/// content attributes; intrinsic measurement never asks a LayoutBuilder child.
class NativeHtmlMediaBox extends SingleChildRenderObjectWidget {
  const NativeHtmlMediaBox({
    super.key,
    required this.naturalSize,
    required this.styles,
    required super.child,
    this.fontSize = 16,
    this.intrinsicRatio,
    this.widthAttributeSpecified = false,
    this.heightAttributeSpecified = false,
  });
  Size get intrinsicSize => _MediaBoxGeometry(
    naturalSize,
    styles,
    fontSize,
    intrinsicRatio,
    widthAttributeSpecified,
    heightAttributeSpecified,
  ).resolve(const BoxConstraints());
  final Size naturalSize;
  final Map<String, String> styles;
  final double fontSize;
  final double? intrinsicRatio;
  final bool widthAttributeSpecified, heightAttributeSpecified;
  @override
  RenderObject createRenderObject(BuildContext context) =>
      RenderNativeHtmlMediaBox(
        naturalSize,
        styles,
        fontSize,
        intrinsicRatio,
        widthAttributeSpecified,
        heightAttributeSpecified,
      );
  @override
  void updateRenderObject(
    BuildContext context,
    covariant RenderObject renderObject,
  ) {
    (renderObject as RenderNativeHtmlMediaBox).update(
      naturalSize,
      styles,
      fontSize,
      intrinsicRatio,
      widthAttributeSpecified,
      heightAttributeSpecified,
    );
  }
}

class RenderNativeHtmlMediaBox extends RenderProxyBox {
  RenderNativeHtmlMediaBox(
    this.naturalSize,
    this.styles,
    this.fontSize,
    this.intrinsicRatio,
    this.widthAttributeSpecified,
    this.heightAttributeSpecified,
  );
  Size naturalSize;
  Map<String, String> styles;
  double fontSize;
  double? intrinsicRatio;
  bool widthAttributeSpecified, heightAttributeSpecified;
  void update(
    Size size,
    Map<String, String> next,
    double font,
    double? ratio,
    bool widthAttr,
    bool heightAttr,
  ) {
    if (naturalSize == size &&
        mapEquals(styles, next) &&
        fontSize == font &&
        intrinsicRatio == ratio &&
        widthAttributeSpecified == widthAttr &&
        heightAttributeSpecified == heightAttr) {
      return;
    }
    naturalSize = size;
    styles = next;
    fontSize = font;
    intrinsicRatio = ratio;
    widthAttributeSpecified = widthAttr;
    heightAttributeSpecified = heightAttr;
    markNeedsLayout();
  }

  Size resolve(BoxConstraints constraints) => _MediaBoxGeometry(
    naturalSize,
    styles,
    fontSize,
    intrinsicRatio,
    widthAttributeSpecified,
    heightAttributeSpecified,
  ).resolve(constraints);
  @override
  Size computeDryLayout(BoxConstraints constraints) => resolve(constraints);
  @override
  double computeMinIntrinsicWidth(double height) =>
      resolve(const BoxConstraints()).width;
  @override
  double computeMaxIntrinsicWidth(double height) =>
      resolve(const BoxConstraints()).width;
  @override
  double computeMinIntrinsicHeight(double width) =>
      resolve(BoxConstraints(maxWidth: width)).height;
  @override
  double computeMaxIntrinsicHeight(double width) =>
      computeMinIntrinsicHeight(width);
  @override
  double? computeDryBaseline(
    BoxConstraints constraints,
    TextBaseline baseline,
  ) => resolve(constraints).height;
  @override
  double? computeDistanceToActualBaseline(TextBaseline baseline) => size.height;
  @override
  void performLayout() {
    size = resolve(constraints);
    child?.layout(BoxConstraints.tight(size), parentUsesSize: true);
  }
}

class _MediaBoxGeometry {
  const _MediaBoxGeometry(
    this.naturalSize,
    this.styles,
    this.fontSize,
    this.intrinsicRatio,
    this.widthAttributeSpecified,
    this.heightAttributeSpecified,
  );
  final Size naturalSize;
  final Map<String, String> styles;
  final double fontSize;
  final double? intrinsicRatio;
  final bool widthAttributeSpecified, heightAttributeSpecified;
  double? length(String property, double available) {
    final raw = styles[property]?.trim().toLowerCase();
    if (raw == null || raw == 'auto' || raw == 'none') return null;
    final m = RegExp(r'^([0-9]+(?:\.[0-9]+)?)(px|%|em|rem)?$').firstMatch(raw);
    if (m == null) return null;
    final value = double.parse(m[1]!);
    return switch (m[2]) {
      '%' => available.isFinite ? available * value / 100 : null,
      'em' => value * fontSize,
      'rem' => value * 16,
      _ => value,
    };
  }

  Size resolve(BoxConstraints constraints) {
    var width = length('width', constraints.maxWidth) ?? naturalSize.width;
    var height = length('height', constraints.maxHeight) ?? naturalSize.height;
    final ratio = intrinsicRatio ?? 0;
    final widthFixed =
            length('width', constraints.maxWidth) != null ||
            widthAttributeSpecified,
        heightFixed =
            length('height', constraints.maxHeight) != null ||
            heightAttributeSpecified;
    if (ratio > 0) {
      if (widthFixed && !heightFixed) height = width / ratio;
      if (heightFixed && !widthFixed) width = height * ratio;
    }
    final maxW = length('max-width', constraints.maxWidth),
        maxH = length('max-height', constraints.maxHeight);
    if (maxW != null && width > maxW) {
      if (ratio > 0 && !heightFixed) height = maxW / ratio;
      width = maxW;
    }
    if (maxH != null && height > maxH) {
      if (ratio > 0 && !widthFixed) width = maxH * ratio;
      height = maxH;
    }
    final minW = length('min-width', constraints.maxWidth) ?? 0,
        minH = length('min-height', constraints.maxHeight) ?? 0;
    if (width < minW) {
      width = minW;
      if (ratio > 0 && !heightFixed) height = width / ratio;
    }
    if (height < minH) {
      height = minH;
      if (ratio > 0 && !widthFixed) width = height * ratio;
    }
    return constraints.constrain(Size(width, height));
  }
}
