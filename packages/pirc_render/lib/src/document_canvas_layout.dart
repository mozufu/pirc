import 'dart:math' as math;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

import 'document_canvas_sizing.dart';

/// Canvas bitmap limits; larger canvases are refused, not scaled.
abstract final class NativeCanvasLimits {
  static const int maxDimension = 8192;
  static const int maxPixels = 16 * 1024 * 1024;
}

/// What the static renderer needs to know about a canvas drawn by a document
/// script. The drawing itself belongs to the document runtime.
abstract interface class RenderCanvasSnapshot {
  double get width;
  double get height;
}

/// A canvas with no drawing: what chat content shows for `<canvas>`, since
/// it never runs scripts.
class NativeBlankCanvas extends StatelessWidget {
  const NativeBlankCanvas({
    super.key,
    required this.width,
    required this.height,
    this.cssWidthSpecified = false,
    this.cssHeightSpecified = false,
  });
  final double width, height;
  final bool cssWidthSpecified, cssHeightSpecified;
  @override
  Widget build(BuildContext context) => NativeDocumentCanvasLayout(
    intrinsicSize: Size(width, height),
    width: null,
    height: null,
    cssWidthSpecified: cssWidthSpecified,
    cssHeightSpecified: cssHeightSpecified,
    child: const SizedBox.expand(),
  );
}

/// Sizes a canvas like an HTML replaced element: its bitmap size is the
/// intrinsic size, CSS width/height override it and keep the aspect ratio.
class NativeDocumentCanvasLayout extends SingleChildRenderObjectWidget {
  const NativeDocumentCanvasLayout({
    super.key,
    required this.intrinsicSize,
    required this.width,
    required this.height,
    required this.cssWidthSpecified,
    required this.cssHeightSpecified,
    required super.child,
  });

  final Size intrinsicSize;
  final double? width;
  final double? height;
  final bool cssWidthSpecified;
  final bool cssHeightSpecified;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      RenderNativeDocumentCanvasLayout(
        intrinsicSize: intrinsicSize,
        width: width,
        height: height,
        cssWidthSpecified: cssWidthSpecified,
        cssHeightSpecified: cssHeightSpecified,
      );

  @override
  void updateRenderObject(
    BuildContext context,
    covariant RenderNativeDocumentCanvasLayout renderObject,
  ) {
    renderObject
      ..intrinsicSize = intrinsicSize
      ..width = width
      ..height = height
      ..cssWidthSpecified = cssWidthSpecified
      ..cssHeightSpecified = cssHeightSpecified;
  }
}

class RenderNativeDocumentCanvasLayout extends RenderProxyBox {
  RenderNativeDocumentCanvasLayout({
    required this._intrinsicSize,
    required this._width,
    required this._height,
    required this._cssWidthSpecified,
    required this._cssHeightSpecified,
    RenderBox? child,
  }) : super(child);

  Size _intrinsicSize;
  double? _width;
  double? _height;
  bool _cssWidthSpecified;
  bool _cssHeightSpecified;
  set cssWidthSpecified(bool value) {
    if (_cssWidthSpecified == value) return;
    _cssWidthSpecified = value;
    markNeedsLayout();
  }

  set cssHeightSpecified(bool value) {
    if (_cssHeightSpecified == value) return;
    _cssHeightSpecified = value;
    markNeedsLayout();
  }

  set intrinsicSize(Size value) {
    if (_intrinsicSize == value) return;
    _intrinsicSize = value;
    markNeedsLayout();
  }

  set width(double? value) {
    if (_width == value) return;
    _width = value;
    markNeedsLayout();
  }

  set height(double? value) {
    if (_height == value) return;
    _height = value;
    markNeedsLayout();
  }

  Size _sized({double? width, double? height}) {
    final used = nativeCanvasUsedSize(
      intrinsicWidth: _intrinsicSize.width,
      intrinsicHeight: _intrinsicSize.height,
      width: width,
      height: height,
    );
    return Size(used.width, used.height);
  }

  Size _desiredSize() => _sized(width: _width, height: _height);

  Size _constrainedAspectSize(BoxConstraints constraints) {
    // The HTML core may pass a preferred CSS width as a loose maximum. Honor
    // both authored axes independently, while auto axes retain intrinsic ratio.
    if (_cssWidthSpecified && _cssHeightSpecified) {
      // The HTML core probes one axis at a time to detect an intrinsic aspect
      // ratio. Two authored dimensions must allow independent scaling instead.
      return constraints.constrain(_desiredSize());
    }
    final cssWidth = _cssWidthSpecified && constraints.hasBoundedWidth;
    final cssHeight = _cssHeightSpecified && constraints.hasBoundedHeight;
    if (cssWidth) {
      return constraints.constrain(_sized(width: constraints.maxWidth));
    }
    if (cssHeight) {
      return constraints.constrain(_sized(height: constraints.maxHeight));
    }
    if (_width != null && _height != null) {
      return constraints.constrain(_desiredSize());
    }
    if (constraints.hasTightWidth && constraints.hasTightHeight) {
      return constraints.biggest;
    }
    if (constraints.hasTightWidth) {
      return constraints.constrain(_sized(width: constraints.maxWidth));
    }
    if (constraints.hasTightHeight) {
      return constraints.constrain(_sized(height: constraints.maxHeight));
    }
    final desired = _desiredSize();
    var scale = 1.0;
    if (constraints.maxWidth.isFinite && desired.width > constraints.maxWidth) {
      scale = math.min(scale, constraints.maxWidth / desired.width);
    }
    if (constraints.maxHeight.isFinite &&
        desired.height > constraints.maxHeight) {
      scale = math.min(scale, constraints.maxHeight / desired.height);
    }
    return constraints.constrain(
      Size(desired.width * scale, desired.height * scale),
    );
  }

  @override
  void performLayout() {
    size = _constrainedAspectSize(constraints);
    child?.layout(BoxConstraints.tight(size), parentUsesSize: true);
  }

  @override
  Size computeDryLayout(BoxConstraints constraints) =>
      _constrainedAspectSize(constraints);

  double _intrinsicWidth(double height) {
    if (_width != null && _height != null) return _width!;
    if (_width != null) return _width!;
    if (_height != null) return _sized(height: _height).width;
    return height.isFinite
        ? _sized(height: height).width
        : _intrinsicSize.width;
  }

  double _intrinsicHeight(double width) {
    if (_width != null && _height != null) return _height!;
    if (_height != null) return _height!;
    if (_width != null) return _sized(width: _width).height;
    return width.isFinite ? _sized(width: width).height : _intrinsicSize.height;
  }

  @override
  double computeMinIntrinsicWidth(double height) => _intrinsicWidth(height);

  @override
  double computeMaxIntrinsicWidth(double height) => _intrinsicWidth(height);

  @override
  double computeMinIntrinsicHeight(double width) => _intrinsicHeight(width);

  @override
  double computeMaxIntrinsicHeight(double width) => _intrinsicHeight(width);
}
