import 'dart:async';
import 'package:flutter/widgets.dart';

/// Runs one axis of a script scroll against its current native position.
/// Animation destinations are not positions: a later scrollBy starts at the
/// actual current pixels. Even an unchanged target must cancel older activity.
void applyNativeDocumentScrollAxis(
  ScrollController controller,
  double? coordinate, {
  required bool relative,
  required String behavior,
  String cssBehavior = 'auto',
}) {
  if (controller.positions.length != 1 ||
      coordinate != null && !coordinate.isFinite) {
    return;
  }
  final position = controller.position;
  if (!position.hasContentDimensions || !position.hasViewportDimension) return;
  final requested = relative
      ? position.pixels + (coordinate ?? 0)
      : coordinate ?? position.pixels;
  final target = requested
      .clamp(position.minScrollExtent, position.maxScrollExtent)
      .toDouble();
  if (behavior == 'smooth' || behavior == 'auto' && cssBehavior == 'smooth') {
    unawaited(
      controller.animateTo(
        target,
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeInOut,
      ),
    );
  } else {
    controller.jumpTo(target);
  }
}
