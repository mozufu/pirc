/// CSS replaced-element size for a Canvas with no padding/border/min/max sizes.
/// Explicit axes are independent; an auto axis uses the natural aspect ratio,
/// or its natural dimension when either natural axis is zero (no usable ratio).
({double width, double height}) nativeCanvasUsedSize({
  required double intrinsicWidth,
  required double intrinsicHeight,
  double? width,
  double? height,
}) {
  final hasRatio = intrinsicWidth > 0 && intrinsicHeight > 0;
  if (width != null && height != null) return (width: width, height: height);
  if (width != null) {
    return (
      width: width,
      height: hasRatio
          ? width * intrinsicHeight / intrinsicWidth
          : intrinsicHeight,
    );
  }
  if (height != null) {
    return (
      width: hasRatio
          ? height * intrinsicWidth / intrinsicHeight
          : intrinsicWidth,
      height: height,
    );
  }
  return (width: intrinsicWidth, height: intrinsicHeight);
}

/// The bounded synchronous style surface accepts auto, px, percentage and zero.
/// All percentage bases must come from the measured fixed parent content box.
({double width, double height})? nativeCanvasCssUsedSize({
  required String cssWidth,
  required String cssHeight,
  required double parentWidth,
  required double parentHeight,
  required double intrinsicWidth,
  required double intrinsicHeight,
}) {
  double? axis(String raw, double basis) {
    if (raw == 'auto') return null;
    if (raw == '0') return 0;
    final match = RegExp(r'^(\d+(?:\.\d*)?|\.\d+)(px|%)$').firstMatch(raw);
    if (match == null) return double.nan;
    final value = double.tryParse(match.group(1)!);
    return value == null
        ? double.nan
        : match.group(2) == '%'
        ? value * basis / 100
        : value;
  }

  final width = axis(cssWidth, parentWidth),
      height = axis(cssHeight, parentHeight);
  if (width?.isNaN == true || height?.isNaN == true) return null;
  final used = nativeCanvasUsedSize(
    intrinsicWidth: intrinsicWidth,
    intrinsicHeight: intrinsicHeight,
    width: width,
    height: height,
  );
  if (!used.width.isFinite ||
      !used.height.isFinite ||
      used.width < 0 ||
      used.height < 0 ||
      used.width > 1000000 ||
      used.height > 1000000) {
    return null;
  }
  return used;
}
