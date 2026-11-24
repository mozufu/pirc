import 'package:flutter/widgets.dart';

/// Source pixels per CSS pixel for a responsive HTML image.
class NativeImageDensity extends InheritedWidget {
  const NativeImageDensity({
    super.key,
    required this.density,
    this.loadingLazy = false,
    this.crossOrigin,
    required super.child,
  });
  final double density;
  final bool loadingLazy;
  final String? crossOrigin;

  static double of(BuildContext context) {
    final value =
        context
            .dependOnInheritedWidgetOfExactType<NativeImageDensity>()
            ?.density ??
        1;
    return value.isFinite && value > 0 ? value : 1;
  }

  static bool loadingLazyOf(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<NativeImageDensity>()
          ?.loadingLazy ??
      false;

  static String? crossOriginOf(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<NativeImageDensity>()
      ?.crossOrigin;

  @override
  bool updateShouldNotify(NativeImageDensity oldWidget) =>
      oldWidget.density != density ||
      oldWidget.loadingLazy != loadingLazy ||
      oldWidget.crossOrigin != crossOrigin;
}
