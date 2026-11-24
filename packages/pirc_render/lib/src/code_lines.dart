import 'package:flutter/painting.dart';

/// CSS pre does not allocate a line after a terminal LF. Keep the entire span
/// available to selection and semantics while excluding only that empty line.
int? nativeCodeVisibleLines(
  TextSpan source, {
  required TextScaler textScaler,
  required TextDirection textDirection,
  Locale? locale,
}) {
  if (!source.toPlainText().endsWith('\n')) return null;
  final painter = TextPainter(
    text: source,
    textDirection: textDirection,
    textScaler: textScaler,
    locale: locale,
  )..layout();
  // Measure actual hard breaks, including Unicode separators. Counting LF
  // alone could truncate visible text containing other native line breaks.
  final count = painter.computeLineMetrics().length - 1;
  painter.dispose();
  return count < 1 ? 1 : count;
}
