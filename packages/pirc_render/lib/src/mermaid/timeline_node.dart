import '../render_l10n.dart';
// Timeline node text wrapping and classic node paths ported from Mermaid
// 11.17.2 (MIT), rendering-elements/timeline-svgDraw.ts. See
// MERMAID_MIT_LICENSE.txt for the upstream license notice.
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// One SVG tspan produced by Mermaid's timeline `wrap()` helper.
///
/// [rawText] retains the tspan's textContent (including repeated spaces),
/// while [paintText] applies SVG's default whitespace collapsing for width
/// measurement and native painting. Empty lines are retained because they
/// still advance the following tspan by 1.1em.
class NativeTimelineTextLine {
  const NativeTimelineTextLine({
    required this.index,
    required this.rawText,
    required this.paintText,
    required this.dy,
    required this.width,
    required this.baseline,
    required this.glyphBounds,
  });

  final int index;
  final String rawText;
  final String paintText;

  /// The source tspan `dy`: 1em for the first row and 1.1em thereafter.
  final double dy;

  /// Advance width of the collapsed rendered text.
  final double width;

  /// Alphabetic baseline in the text group's local coordinates. The first
  /// source text position is one SVG em. Mermaid's `dominant-baseline:middle`
  /// shifts the alphabetic baseline by half the active font's x-height; later
  /// rows advance by 1.1 SVG em.
  final double baseline;

  /// Centered SVG font-cell bounds in the text group's local coordinates.
  /// Chromium's SVG text BBox uses rounded font ascent/descent cells rather
  /// than the tight ink bounds returned by glyph rasterization.
  final Rect glyphBounds;
}

/// Text and classic SVG node geometry for one Mermaid timeline node.
class NativeTimelineNodeLayout {
  const NativeTimelineNodeLayout({
    required this.lines,
    required this.textBounds,
    required this.virtualHeight,
    required this.height,
    required this.width,
    required this.sectionIndex,
    required this.textTransform,
    required this.backgroundPath,
    required this.localBounds,
    this.bottomRulePath,
  });

  final List<NativeTimelineTextLine> lines;

  /// Union of native text metric boxes, before the SVG text-group transform.
  final Rect textBounds;

  /// `getVirtualNodeHeight`: text bbox height + config font contribution +
  /// node padding. Unlike [height], this is not raised to `maxHeight`.
  final double virtualHeight;

  /// Drawn node height: `max(virtualHeight, maxHeight)`.
  final double height;

  /// Drawn node width, including both horizontal padding sides.
  final double width;

  /// Mermaid's `(fullSection % maxSections) - 1` style index.
  final int sectionIndex;

  /// Translation applied to the SVG text group after node dimensions resolve.
  final Offset textTransform;

  /// Classic timeline node background path in node-local coordinates.
  final Path backgroundPath;

  /// Non-Redux themes draw a separate underline along the bottom edge.
  final Path? bottomRulePath;

  /// Background node bounds. Text can naturally overflow this width for a
  /// single token, as in the source SVG renderer.
  final Rect localBounds;

  /// Text metric bounds after the SVG text group's node-local translation.
  Rect get textBoundsInNode => textBounds.shift(textTransform);
}

/// Measures one timeline node with Mermaid's source token wrapping and builds
/// its local background/underline geometry.
///
/// [width] is the pre-padding `node.width` used by `wrap(text, node.width)`;
/// [configFontSize] is `conf.fontSize` and intentionally may differ from the
/// computed SVG [textStyle] font size. [maxHeight] is a lower bound, matching
/// `Math.max(node.height, node.maxHeight)` in `drawNode`. [svgXHeight] is the
/// active face's computed x-height in CSS pixels at the computed SVG font size;
/// if unavailable, the SVG middle-baseline shift falls back to x-height 0.5em.
NativeTimelineNodeLayout layoutNativeTimelineNode({
  required String descr,
  required double width,
  required double padding,
  required double maxHeight,
  required double configFontSize,
  required TextStyle textStyle,
  required int sectionDepth,
  double? svgXHeight,
  int maxSections = 12,
  bool reduxTheme = false,
  bool isEvent = false,
}) {
  if (!width.isFinite || width <= 0) {
    throw FormatException(tr("Timeline text width must be positive"));
  }
  if (!padding.isFinite || padding < 0) {
    throw FormatException(tr("Timeline node padding must be non-negative"));
  }
  if (!maxHeight.isFinite || !configFontSize.isFinite || configFontSize <= 0) {
    throw FormatException(
      tr("Timeline node font and max height must be finite"),
    );
  }
  if (maxSections <= 0) {
    throw FormatException(tr("Timeline theme color limit must be positive"));
  }
  final svgFontSize = textStyle.fontSize ?? configFontSize;
  if (!svgFontSize.isFinite || svgFontSize <= 0) {
    throw FormatException(tr("Timeline SVG font size must be positive"));
  }
  if (svgXHeight != null && (!svgXHeight.isFinite || svgXHeight < 0)) {
    throw FormatException(tr("Timeline SVG x-height must be finite"));
  }

  // SVG text layout ignores CSS line-height for explicit tspan positioning.
  // Keep the remaining computed font properties, but use font metrics rather
  // than applying the surrounding HTML paragraph's line height a second time.
  final svgTextStyle = textStyle.copyWith(height: ui.kTextHeightNone);
  final rawLines = _wrapLikeMermaid(descr, width, svgTextStyle, svgFontSize);
  final lines = <NativeTimelineTextLine>[];
  Rect? textBounds;
  var baselineAdvance = 0.0;
  for (var i = 0; i < rawLines.length; i++) {
    final rawText = rawLines[i];
    final paintText = _collapseSvgWhitespace(rawText);
    final painter = _measure(paintText, svgTextStyle, svgFontSize);
    final metrics = painter.computeLineMetrics();
    final sourceTextPosition = svgFontSize + baselineAdvance;
    // TextPainter does not expose the selected font's x-height. Source-accurate
    // callers pass it explicitly; otherwise use the CSS fallback of 0.5em and
    // mark this metric as an estimate in the API documentation.
    final xHeight = svgXHeight ?? svgFontSize * 0.5;
    final middleBaselineShift = _roundToSixtyFourth(xHeight / 2);
    final sourceBaseline = sourceTextPosition + middleBaselineShift;
    Rect glyphBounds = Rect.fromLTWH(0, sourceBaseline, 0, 0);
    if (metrics.isNotEmpty && paintText.isNotEmpty) {
      // Chromium SVG getBBox/getExtentOfChar use the active font's ascent and
      // descent rounded to the nearest CSS pixel. A source-only 17px SFNS
      // probe distinguishes this from ceiling: natural metrics around 16.43 /
      // 3.59 produce a 20px SVG cell (16 + 4), while ceiling would be 21px.
      // TextPainter selection boxes still use its fractional paragraph line
      // box, so keep this cell separate from selection geometry.
      final cellAscent = metrics.first.ascent.roundToDouble();
      final cellDescent = metrics.first.descent.roundToDouble();
      final cellWidth = _roundToSixtyFourth(painter.width);
      glyphBounds = Rect.fromLTWH(
        -cellWidth / 2,
        sourceBaseline - cellAscent,
        cellWidth,
        cellAscent + cellDescent,
      );
      textBounds = textBounds == null
          ? glyphBounds
          : textBounds.expandToInclude(glyphBounds);
    }
    lines.add(
      NativeTimelineTextLine(
        index: i,
        rawText: rawText,
        paintText: paintText,
        dy: svgFontSize * (i == 0 ? 1 : 1.1),
        width: painter.width,
        baseline: sourceBaseline,
        glyphBounds: glyphBounds,
      ),
    );
    painter.dispose();
    if (i + 1 < rawLines.length) baselineAdvance += svgFontSize * 1.1;
  }

  final measuredTextBounds = textBounds ?? Rect.zero;
  final virtualHeight =
      measuredTextBounds.height + configFontSize * 1.1 * 0.5 + padding;
  final nodeHeight = virtualHeight > maxHeight ? virtualHeight : maxHeight;
  final nodeWidth = width + 2 * padding;
  final sectionIndex = sectionDepth.remainder(maxSections) - 1;
  final textOffsetY = reduxTheme
      ? (isEvent ? padding / 2 + 3 : padding)
      : padding / 2;

  final bounds = Rect.fromLTWH(0, 0, nodeWidth, nodeHeight);
  final background = _backgroundPath(
    width: nodeWidth,
    height: nodeHeight,
    reduxTheme: reduxTheme,
  );
  final underline = reduxTheme
      ? null
      : (Path()
          ..moveTo(0, nodeHeight)
          ..lineTo(nodeWidth, nodeHeight));

  return NativeTimelineNodeLayout(
    lines: List.unmodifiable(lines),
    textBounds: measuredTextBounds,
    virtualHeight: virtualHeight,
    height: nodeHeight,
    width: nodeWidth,
    sectionIndex: sectionIndex,
    textTransform: Offset(nodeWidth / 2, textOffsetY),
    backgroundPath: background,
    bottomRulePath: underline,
    localBounds: bounds,
  );
}

double _roundToSixtyFourth(double value) => (value * 64).roundToDouble() / 64;

List<String> _wrapLikeMermaid(
  String text,
  double width,
  TextStyle style,
  double fontSize,
) {
  // String.split(/(\s+|<br>)/) in the upstream code retains matched tokens.
  final tokens = <String>[];
  final delimiter = RegExp(r'<br>|\s+', unicode: true);
  var cursor = 0;
  for (final match in delimiter.allMatches(text)) {
    if (match.start > cursor) tokens.add(text.substring(cursor, match.start));
    tokens.add(match.group(0)!);
    cursor = match.end;
  }
  if (cursor < text.length || tokens.isEmpty) {
    tokens.add(text.substring(cursor));
  }

  final result = <String>[''];
  var line = <String>[];
  for (final token in tokens) {
    line.add(token);
    result[result.length - 1] = _joinTrim(line);
    final rendered = _collapseSvgWhitespace(result.last);
    final painter = _measure(rendered, style, fontSize);
    final overflow = painter.width > width;
    painter.dispose();
    if (!overflow && token != '<br>') continue;

    line.removeLast();
    result[result.length - 1] = _joinTrim(line);
    if (token == '<br>') {
      // Mermaid first creates a tspan with literal `<br>` text, then starts
      // the next accumulated line empty. A following token overwrites that
      // tspan's text; a terminal `<br>` remains literal.
      result.add('<br>');
      line = [''];
    } else {
      result.add(token);
      line = [token];
    }
  }
  return result;
}

String _joinTrim(List<String> parts) => parts.join(' ').trim();

String _collapseSvgWhitespace(String text) =>
    text.replaceAll(RegExp(r'\s+', unicode: true), ' ').trim();

TextPainter _measure(String text, TextStyle style, double fontSize) =>
    TextPainter(
      text: TextSpan(
        text: text,
        style: style.copyWith(fontSize: fontSize),
      ),
      textDirection: TextDirection.ltr,
      textScaler: TextScaler.noScaling,
    )..layout();

Path _backgroundPath({
  required double width,
  required double height,
  required bool reduxTheme,
}) {
  const radius = 5.0;
  const rightInset = 5.0;
  final path = Path();
  if (reduxTheme) {
    return path
      ..moveTo(0, height - rightInset)
      ..relativeLineTo(0, -(height - rightInset))
      ..relativeLineTo(width, 0)
      ..relativeLineTo(0, height)
      ..lineTo(0, height)
      ..close();
  }
  return path
    ..moveTo(0, height - rightInset)
    ..relativeLineTo(0, -height + 2 * rightInset)
    ..relativeQuadraticBezierTo(0, -radius, radius, -radius)
    ..relativeLineTo(width - 2 * rightInset, 0)
    ..relativeQuadraticBezierTo(radius, 0, radius, radius)
    ..relativeLineTo(0, height - rightInset)
    ..lineTo(0, height)
    ..close();
}
