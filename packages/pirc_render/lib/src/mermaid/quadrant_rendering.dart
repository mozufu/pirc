import '../render_l10n.dart';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'quadrant_model.dart';

class NativeMermaidQuadrantLine {
  const NativeMermaidQuadrantLine(this.start, this.end, this.color, this.width);

  final Offset start;
  final Offset end;
  final Color color;
  final double width;
}

class NativeMermaidQuadrantText {
  const NativeMermaidQuadrantText({
    required this.text,
    required this.position,
    required this.fontSize,
    required this.color,
    this.rotation = 0,
    this.centered = true,
    this.middleBaseline = false,
  });

  final String text;
  final Offset position;
  final double fontSize;
  final Color color;
  final double rotation;
  final bool centered;
  final bool middleBaseline;
}

class NativeMermaidQuadrantPointLayout {
  const NativeMermaidQuadrantPointLayout({
    required this.point,
    required this.center,
    required this.radius,
    required this.fill,
    required this.stroke,
    required this.strokeWidth,
    required this.label,
  });

  final NativeMermaidQuadrantPoint point;
  final Offset center;
  final double radius;
  final Color fill;
  final Color stroke;
  final double strokeWidth;
  final NativeMermaidQuadrantText label;
}

/// Mermaid source-derived geometry in SVG user units plus its responsive
/// outer size. Coordinates remain independent of Flutter text scaling.
class NativeMermaidQuadrantLayout {
  NativeMermaidQuadrantLayout({
    required this.viewBoxSize,
    required this.size,
    required this.scale,
    required List<Rect> quadrants,
    required List<Color> quadrantFills,
    required List<NativeMermaidQuadrantText?> quadrantLabels,
    required List<NativeMermaidQuadrantLine> borders,
    required List<NativeMermaidQuadrantPointLayout> points,
    required List<NativeMermaidQuadrantText> axisLabels,
    required this.title,
    required this.fontFamily,
  }) : quadrants = List.unmodifiable(quadrants),
       quadrantFills = List.unmodifiable(quadrantFills),
       quadrantLabels = List.unmodifiable(quadrantLabels),
       borders = List.unmodifiable(borders),
       points = List.unmodifiable(points),
       axisLabels = List.unmodifiable(axisLabels);

  final Size viewBoxSize;
  final Size size;
  final double scale;
  final List<Rect> quadrants;
  final List<Color> quadrantFills;
  final List<NativeMermaidQuadrantText?> quadrantLabels;
  final List<NativeMermaidQuadrantLine> borders;
  final List<NativeMermaidQuadrantPointLayout> points;
  final List<NativeMermaidQuadrantText> axisLabels;
  final NativeMermaidQuadrantText? title;
  final String? fontFamily;
}

/// Computes the same user-unit chart coordinates as pinned Mermaid's
/// `quadrantBuilder.ts`. `width` is the SVG's available CSS width; the
/// configured viewBox is uniformly reduced when that width is smaller.
NativeMermaidQuadrantLayout layoutNativeMermaidQuadrant(
  NativeMermaidQuadrantDiagram diagram, {
  required double width,
  required bool dark,
  String? fontFamily,
}) {
  final config = diagram.config;
  if (!width.isFinite || width <= 0) {
    throw FormatException(
      tr("Native quadrant viewport width must be positive"),
    );
  }
  if (!config.chartWidth.isFinite ||
      !config.chartHeight.isFinite ||
      config.chartWidth <= 0 ||
      config.chartHeight <= 0) {
    throw FormatException(
      tr("Native quadrant chart dimensions must be positive"),
    );
  }

  final scale = math.min(1.0, width / config.chartWidth);
  final viewBox = Size(config.chartWidth, config.chartHeight);
  final size = Size(viewBox.width * scale, viewBox.height * scale);
  final colors = _QuadrantPalette(dark);
  final hasXAxis =
      config.showXAxis &&
      (diagram.xAxisLeftText.isNotEmpty || diagram.xAxisRightText.isNotEmpty);
  final hasYAxis =
      config.showYAxis &&
      (diagram.yAxisBottomText.isNotEmpty || diagram.yAxisTopText.isNotEmpty);
  final hasTitle = config.showTitle && (diagram.title ?? '').isNotEmpty;
  final xAxisPosition = diagram.points.isNotEmpty
      ? 'bottom'
      : config.xAxisPosition;

  final xAxisSpaceAmount =
      config.xAxisLabelPadding * 2 + config.xAxisLabelFontSize;
  final xAxisTop = xAxisPosition == 'top' && hasXAxis ? xAxisSpaceAmount : 0.0;
  final xAxisBottom = xAxisPosition == 'bottom' && hasXAxis
      ? xAxisSpaceAmount
      : 0.0;
  final yAxisSpaceAmount =
      config.yAxisLabelPadding * 2 + config.yAxisLabelFontSize;
  final yAxisLeft = config.yAxisPosition == 'left' && hasYAxis
      ? yAxisSpaceAmount
      : 0.0;
  final yAxisRight = config.yAxisPosition == 'right' && hasYAxis
      ? yAxisSpaceAmount
      : 0.0;
  final titleTop = hasTitle
      ? config.titleFontSize + config.titlePadding * 2
      : 0.0;

  final qLeft = config.quadrantPadding + yAxisLeft;
  final qTop = config.quadrantPadding + xAxisTop + titleTop;
  final qWidth =
      config.chartWidth - config.quadrantPadding * 2 - yAxisLeft - yAxisRight;
  final qHeight =
      config.chartHeight -
      config.quadrantPadding * 2 -
      xAxisTop -
      xAxisBottom -
      titleTop;
  if (qWidth <= 0 || qHeight <= 0) {
    throw FormatException(
      tr("Native quadrant labels leave no room for the plot"),
    );
  }
  final halfWidth = qWidth / 2;
  final halfHeight = qHeight / 2;
  final quadrantRects = <Rect>[
    Rect.fromLTWH(qLeft + halfWidth, qTop, halfWidth, halfHeight),
    Rect.fromLTWH(qLeft, qTop, halfWidth, halfHeight),
    Rect.fromLTWH(qLeft, qTop + halfHeight, halfWidth, halfHeight),
    Rect.fromLTWH(qLeft + halfWidth, qTop + halfHeight, halfWidth, halfHeight),
  ];

  final quadrantLabels = <NativeMermaidQuadrantText?>[];
  for (var i = 0; i < quadrantRects.length; i++) {
    final text = diagram.quadrants[i];
    if (text.isEmpty) {
      quadrantLabels.add(null);
      continue;
    }
    final rect = quadrantRects[i];
    final hasPoints = diagram.points.isNotEmpty;
    quadrantLabels.add(
      NativeMermaidQuadrantText(
        text: text,
        position: Offset(
          rect.center.dx,
          hasPoints ? rect.top + config.quadrantTextTopPadding : rect.center.dy,
        ),
        fontSize: config.quadrantLabelFontSize,
        color: colors.quadrantText[i],
        middleBaseline: !hasPoints,
      ),
    );
  }

  final externalHalf = config.quadrantExternalBorderStrokeWidth / 2;
  final borders = <NativeMermaidQuadrantLine>[
    NativeMermaidQuadrantLine(
      Offset(qLeft - externalHalf, qTop),
      Offset(qLeft + qWidth + externalHalf, qTop),
      colors.border,
      config.quadrantExternalBorderStrokeWidth,
    ),
    NativeMermaidQuadrantLine(
      Offset(qLeft + qWidth, qTop + externalHalf),
      Offset(qLeft + qWidth, qTop + qHeight - externalHalf),
      colors.border,
      config.quadrantExternalBorderStrokeWidth,
    ),
    NativeMermaidQuadrantLine(
      Offset(qLeft - externalHalf, qTop + qHeight),
      Offset(qLeft + qWidth + externalHalf, qTop + qHeight),
      colors.border,
      config.quadrantExternalBorderStrokeWidth,
    ),
    NativeMermaidQuadrantLine(
      Offset(qLeft, qTop + externalHalf),
      Offset(qLeft, qTop + qHeight - externalHalf),
      colors.border,
      config.quadrantExternalBorderStrokeWidth,
    ),
    NativeMermaidQuadrantLine(
      Offset(qLeft + halfWidth, qTop + externalHalf),
      Offset(qLeft + halfWidth, qTop + qHeight - externalHalf),
      colors.border,
      config.quadrantInternalBorderStrokeWidth,
    ),
    NativeMermaidQuadrantLine(
      Offset(qLeft + externalHalf, qTop + halfHeight),
      Offset(qLeft + qWidth - externalHalf, qTop + halfHeight),
      colors.border,
      config.quadrantInternalBorderStrokeWidth,
    ),
  ];

  final axisLabels = <NativeMermaidQuadrantText>[];
  final xLabelsCentered = diagram.xAxisRightText.isNotEmpty;
  final axisXLeft = qLeft + (xLabelsCentered ? halfWidth / 2 : 0);
  final axisXRight = qLeft + halfWidth + (xLabelsCentered ? halfWidth / 2 : 0);
  final axisY = xAxisPosition == 'top'
      ? config.xAxisLabelPadding + titleTop
      : config.xAxisLabelPadding + qTop + qHeight + config.quadrantPadding;
  if (diagram.xAxisLeftText.isNotEmpty && hasXAxis) {
    axisLabels.add(
      NativeMermaidQuadrantText(
        text: diagram.xAxisLeftText,
        position: Offset(axisXLeft, axisY),
        fontSize: config.xAxisLabelFontSize,
        color: colors.axisText,
        centered: xLabelsCentered,
      ),
    );
  }
  if (diagram.xAxisRightText.isNotEmpty && hasXAxis) {
    axisLabels.add(
      NativeMermaidQuadrantText(
        text: diagram.xAxisRightText,
        position: Offset(axisXRight, axisY),
        fontSize: config.xAxisLabelFontSize,
        color: colors.axisText,
        centered: xLabelsCentered,
      ),
    );
  }

  final yLabelsCentered = diagram.yAxisTopText.isNotEmpty;
  final axisYx = config.yAxisPosition == 'left'
      ? config.yAxisLabelPadding
      : config.yAxisLabelPadding + qLeft + qWidth + config.quadrantPadding;
  final yBottom = qTop + qHeight - (yLabelsCentered ? halfHeight / 2 : 0);
  final yTop = qTop + halfHeight - (yLabelsCentered ? halfHeight / 2 : 0);
  if (diagram.yAxisBottomText.isNotEmpty && hasYAxis) {
    axisLabels.add(
      NativeMermaidQuadrantText(
        text: diagram.yAxisBottomText,
        position: Offset(axisYx, yBottom),
        fontSize: config.yAxisLabelFontSize,
        color: colors.axisText,
        rotation: -math.pi / 2,
      ),
    );
  }
  if (diagram.yAxisTopText.isNotEmpty && hasYAxis) {
    axisLabels.add(
      NativeMermaidQuadrantText(
        text: diagram.yAxisTopText,
        position: Offset(axisYx, yTop),
        fontSize: config.yAxisLabelFontSize,
        color: colors.axisText,
        rotation: -math.pi / 2,
      ),
    );
  }

  final title = hasTitle
      ? NativeMermaidQuadrantText(
          text: diagram.title!,
          position: Offset(config.chartWidth / 2, config.titlePadding),
          fontSize: config.titleFontSize,
          color: colors.title,
        )
      : null;
  final pointLayouts = <NativeMermaidQuadrantPointLayout>[];
  // Mermaid's builder prepends each newly parsed point before the existing
  // list; preserve that SVG paint order.
  for (final point in diagram.points.reversed) {
    final style =
        (point.className == null
                ? const NativeMermaidQuadrantStyle()
                : diagram.classes[point.className] ??
                      const NativeMermaidQuadrantStyle())
            .merge(point.style);
    final pointX = qLeft + point.x * qWidth;
    final pointY = qTop + (1 - point.y) * qHeight;
    pointLayouts.add(
      NativeMermaidQuadrantPointLayout(
        point: point,
        center: Offset(pointX, pointY),
        radius: style.radius?.toDouble() ?? config.pointRadius,
        fill: style.color == null ? colors.pointFill : _color(style.color!),
        stroke: style.strokeColor == null
            ? colors.pointStroke
            : _color(style.strokeColor!),
        strokeWidth: style.strokeWidth == null
            ? 0
            : double.parse(
                style.strokeWidth!.substring(0, style.strokeWidth!.length - 2),
              ),
        label: NativeMermaidQuadrantText(
          text: point.label,
          position: Offset(pointX, pointY + config.pointTextPadding),
          fontSize: config.pointLabelFontSize,
          color: colors.pointText,
        ),
      ),
    );
  }

  return NativeMermaidQuadrantLayout(
    viewBoxSize: viewBox,
    size: size,
    scale: scale,
    quadrants: quadrantRects,
    quadrantFills: colors.quadrants,
    quadrantLabels: quadrantLabels,
    borders: borders,
    points: pointLayouts,
    axisLabels: axisLabels,
    title: title,
    fontFamily: fontFamily,
  );
}

class NativeMermaidQuadrant extends StatelessWidget {
  const NativeMermaidQuadrant({
    super.key,
    required this.diagram,
    required this.dark,
  });

  final NativeMermaidQuadrantDiagram diagram;
  final bool dark;

  @override
  Widget build(BuildContext context) {
    RenderL10n.watch(context);
    final fontFamily = Theme.of(context).textTheme.bodyMedium?.fontFamily;
    return Semantics(
      image: true,
      label: diagram.semanticsLabel,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final width = constraints.maxWidth.isFinite
              ? constraints.maxWidth
              : diagram.config.chartWidth;
          final layout = layoutNativeMermaidQuadrant(
            diagram,
            width: width,
            dark: dark,
            fontFamily: fontFamily,
          );
          return Center(
            child: CustomPaint(
              size: layout.size,
              painter: _NativeMermaidQuadrantPainter(layout),
            ),
          );
        },
      ),
    );
  }
}

class _NativeMermaidQuadrantPainter extends CustomPainter {
  const _NativeMermaidQuadrantPainter(this.layout);
  final NativeMermaidQuadrantLayout layout;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(layout.scale);

    final fill = Paint()..style = PaintingStyle.fill;
    for (var i = 0; i < layout.quadrants.length; i++) {
      fill.color = layout.quadrantFills[i];
      canvas.drawRect(layout.quadrants[i], fill);
    }
    for (final line in layout.borders) {
      canvas.drawLine(
        line.start,
        line.end,
        Paint()
          ..color = line.color
          ..strokeWidth = line.width,
      );
    }

    final title = layout.title;
    if (title != null) _paintText(canvas, title, layout.fontFamily);
    for (final label in layout.quadrantLabels) {
      if (label != null) _paintText(canvas, label, layout.fontFamily);
    }
    for (final label in layout.axisLabels) {
      _paintText(canvas, label, layout.fontFamily);
    }
    for (final point in layout.points) {
      canvas.drawCircle(
        point.center,
        point.radius,
        Paint()
          ..color = point.fill
          ..style = PaintingStyle.fill,
      );
      if (point.strokeWidth > 0) {
        canvas.drawCircle(
          point.center,
          point.radius,
          Paint()
            ..color = point.stroke
            ..strokeWidth = point.strokeWidth
            ..style = PaintingStyle.stroke,
        );
      }
      _paintText(canvas, point.label, layout.fontFamily);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _NativeMermaidQuadrantPainter oldDelegate) =>
      oldDelegate.layout != layout;
}

void _paintText(
  Canvas canvas,
  NativeMermaidQuadrantText text,
  String? fontFamily,
) {
  final painter = TextPainter(
    text: TextSpan(
      text: text.text,
      style: TextStyle(
        color: text.color,
        fontFamily: fontFamily,
        fontSize: text.fontSize,
        fontWeight: FontWeight.w400,
        height: 1,
        letterSpacing: 0,
        // CSS font-optical-sizing defaults to auto. Variable system fonts use
        // their optical-size axis at the authored pixel size; fonts without an
        // `opsz` axis ignore this variation.
        fontVariations: [ui.FontVariation('opsz', text.fontSize)],
      ),
    ),
    textDirection: TextDirection.ltr,
    textScaler: TextScaler.noScaling,
    maxLines: 1,
  )..layout();
  canvas.save();
  canvas.translate(text.position.dx, text.position.dy);
  if (text.rotation != 0) canvas.rotate(text.rotation);
  final x = text.centered ? -painter.width / 2 : 0.0;
  final y = text.middleBaseline ? -text.fontSize / 2 : 0.0;
  painter.paint(canvas, Offset(x, y));
  canvas.restore();
  painter.dispose();
}

class _QuadrantPalette {
  _QuadrantPalette(bool dark)
    : quadrants = dark
          ? const [
              Color(0xff1f2020),
              Color(0xff242525),
              Color(0xff292a2a),
              Color(0xff2e2f2f),
            ]
          : const [
              Color(0xffedf3fe),
              Color(0xfff2f8ff),
              Color(0xfff7fdff),
              Color(0xfffcffff),
            ],
      quadrantText = dark
          ? const [
              Color(0xffe0dfdf),
              Color(0xffdbdada),
              Color(0xffd6d5d5),
              Color(0xffd1d0d0),
            ]
          : const [
              Color(0xff0f1115),
              Color(0xff0a0c10),
              Color(0xff05070b),
              Color(0xff000206),
            ],
      border = dark ? const Color(0xffcccccc) : const Color(0xff4176e6),
      axisText = dark ? const Color(0xffe0dfdf) : const Color(0xff0f1115),
      title = dark ? const Color(0xffe0dfdf) : const Color(0xff0f1115),
      pointFill = dark ? const Color(0xffcccccc) : const Color(0xff0f1115),
      pointStroke = Colors.transparent,
      pointText = dark ? const Color(0xffe0dfdf) : const Color(0xff0f1115);

  final List<Color> quadrants;
  final List<Color> quadrantText;
  final Color border;
  final Color axisText;
  final Color title;
  final Color pointFill;
  final Color pointStroke;
  final Color pointText;
}

Color _color(String source) {
  var hex = source.startsWith('#') ? source.substring(1) : source;
  if (hex.length == 3) {
    hex = hex.split('').map((part) => '$part$part').join();
  }
  return Color(0xff000000 | int.parse(hex, radix: 16));
}
