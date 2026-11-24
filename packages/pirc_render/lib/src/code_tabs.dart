import 'package:flutter/material.dart';

/// CSS tab-size: 2 without replacing source characters. The code highlighter
/// emits TextSpans only; flatten inherited styles while retaining every tab and
/// newline for native selection, semantics and copying.
TextSpan nativeCodeTabStops(
  TextSpan source, {
  required TextScaler textScaler,
  required TextDirection textDirection,
  Locale? locale,
}) {
  if (!source.toPlainText().contains('\t')) return source;
  final output = <InlineSpan>[];
  var x = 0.0;
  double width(String text, TextStyle style) {
    final painter = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: textDirection,
      textScaler: textScaler,
      locale: locale,
    )..layout();
    final value = painter.width;
    painter.dispose();
    return value;
  }

  void append(String text, TextStyle style) {
    if (text.isEmpty) return;
    output.add(TextSpan(text: text, style: style));
    x += width(text, style);
  }

  void visit(TextSpan span, TextStyle inherited) {
    final style = inherited.merge(span.style);
    final text = span.text ?? '';
    var start = 0;
    for (final match in RegExp(r'[\t\n]').allMatches(text)) {
      append(text.substring(start, match.start), style);
      if (match[0] == '\n') {
        output.add(TextSpan(text: '\n', style: style));
        x = 0;
      } else {
        final step = width(' ', style) * 2;
        if (step <= 0) {
          append('\t', style);
        } else {
          final stops = x / step;
          final nearest = stops.round();
          final stopIndex = (stops - nearest).abs() < .000001
              ? nearest
              : stops.floor();
          final advance = (stopIndex + 1) * step - x;
          // A tab has no visible glyph. Adjust its font advance and compensate
          // its line height; letterSpacing shifts selection boxes by half the
          // added spacing even when the overall paragraph width is correct.
          final originalSize = style.fontSize ?? 13;
          final originalScaled = textScaler.scale(originalSize);
          final targetScaled = originalScaled * advance / width('\t', style);
          var low = 0.0;
          var high = originalSize + targetScaled + 1;
          while (textScaler.scale(high) < targetScaled) {
            high *= 2;
          }
          for (var i = 0; i < 40; i++) {
            final middle = (low + high) / 2;
            if (textScaler.scale(middle) < targetScaled) {
              low = middle;
            } else {
              high = middle;
            }
          }
          output.add(
            TextSpan(
              text: '\t',
              style: style.copyWith(
                fontSize: (low + high) / 2,
                height: (style.height ?? 1.6) * originalScaled / targetScaled,
              ),
            ),
          );
          x += advance;
        }
      }
      start = match.end;
    }
    append(text.substring(start), style);
    for (final child in span.children ?? <InlineSpan>[]) {
      visit(child as TextSpan, style);
    }
  }

  visit(source, const TextStyle());
  return TextSpan(style: source.style, children: output);
}
