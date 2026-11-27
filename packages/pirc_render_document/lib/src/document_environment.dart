import 'package:pirc_render/src/render_l10n.dart';

/// CSS-pixel document viewport and the host preferences exposed to page scripts.
/// Text scaling is deliberately separate: it is not browser pinch zoom or DPR.
class NativeDocumentEnvironment {
  const NativeDocumentEnvironment({
    this.width = 390,
    this.height = 844,
    this.devicePixelRatio = 1,
    this.dark = false,
    this.reducedMotion = false,
    this.pointer = 'coarse',
    this.hover = 'none',
    double? screenWidth,
    double? screenHeight,
  }) : screenWidth = screenWidth ?? width,
       screenHeight = screenHeight ?? height;

  final double width, height, devicePixelRatio, screenWidth, screenHeight;
  final bool dark, reducedMotion;
  final String pointer, hover;

  Map<String, dynamic> toJson() {
    for (final value in [width, height, screenWidth, screenHeight]) {
      if (!value.isFinite || value < 0 || value > 100000) {
        throw ArgumentError(tr("Invalid CSS-pixel document viewport."));
      }
    }
    if (!devicePixelRatio.isFinite ||
        devicePixelRatio <= 0 ||
        devicePixelRatio > 16 ||
        !const {'coarse', 'fine', 'none'}.contains(pointer) ||
        !const {'hover', 'none'}.contains(hover)) {
      throw ArgumentError(tr("Invalid document display environment."));
    }
    return {
      'width': width,
      'height': height,
      'devicePixelRatio': devicePixelRatio,
      'dark': dark,
      'reducedMotion': reducedMotion,
      'pointer': pointer,
      'hover': hover,
      'screenWidth': screenWidth,
      'screenHeight': screenHeight,
    };
  }

  @override
  bool operator ==(Object other) =>
      other is NativeDocumentEnvironment &&
      width == other.width &&
      height == other.height &&
      devicePixelRatio == other.devicePixelRatio &&
      dark == other.dark &&
      reducedMotion == other.reducedMotion &&
      pointer == other.pointer &&
      hover == other.hover &&
      screenWidth == other.screenWidth &&
      screenHeight == other.screenHeight;
  @override
  int get hashCode => Object.hash(
    width,
    height,
    devicePixelRatio,
    dark,
    reducedMotion,
    pointer,
    hover,
    screenWidth,
    screenHeight,
  );
}
