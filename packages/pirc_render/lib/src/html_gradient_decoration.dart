import 'package:flutter/painting.dart';

/// CSS paints the fallback color below the gradient image. Flutter's standard
/// BoxDecoration multiplies the shader by its color's alpha, making an opaque
/// gradient disappear when the fallback color is transparent.
class NativeHtmlGradientBoxDecoration extends BoxDecoration {
  NativeHtmlGradientBoxDecoration(BoxDecoration base, Gradient gradient)
    : super(
        color: base.color,
        image: base.image,
        border: base.border,
        borderRadius: base.borderRadius,
        boxShadow: base.boxShadow,
        gradient: gradient,
        backgroundBlendMode: base.backgroundBlendMode,
        shape: base.shape,
      );

  @override
  BoxPainter createBoxPainter([VoidCallback? onChanged]) =>
      _CssGradientBoxPainter(this, onChanged);
}

class _CssGradientBoxPainter extends BoxPainter {
  _CssGradientBoxPainter(
    NativeHtmlGradientBoxDecoration decoration,
    super.onChanged,
  ) : _layers = [
        BoxDecoration(
          color: decoration.color,
          boxShadow: decoration.boxShadow,
          borderRadius: decoration.borderRadius,
          shape: decoration.shape,
          backgroundBlendMode: decoration.color == null
              ? null
              : decoration.backgroundBlendMode,
        ).createBoxPainter(onChanged),
        BoxDecoration(
          gradient: decoration.gradient,
          borderRadius: decoration.borderRadius,
          shape: decoration.shape,
        ).createBoxPainter(onChanged),
        BoxDecoration(
          image: decoration.image,
          border: decoration.border,
          borderRadius: decoration.borderRadius,
          shape: decoration.shape,
        ).createBoxPainter(onChanged),
      ];

  final List<BoxPainter> _layers;
  @override
  void paint(Canvas canvas, Offset offset, ImageConfiguration configuration) {
    for (final layer in _layers) {
      layer.paint(canvas, offset, configuration);
    }
  }

  @override
  void dispose() {
    for (final layer in _layers) {
      layer.dispose();
    }
    super.dispose();
  }
}
