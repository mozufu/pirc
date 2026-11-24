import '../render_l10n.dart';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'xy_model.dart';

enum NativeMermaidXYTextAnchor { start, middle, end }

enum NativeMermaidXYTextBaseline { top, middle, alphabetic }

class NativeMermaidXYChartText {
  const NativeMermaidXYChartText({
    required this.text,
    required this.position,
    required this.fontSize,
    required this.color,
    this.anchor = NativeMermaidXYTextAnchor.middle,
    this.baseline = NativeMermaidXYTextBaseline.top,
    this.rotation = 0,
    this.role = '',
  });

  final String text;
  final Offset position;
  final double fontSize;
  final Color color;
  final NativeMermaidXYTextAnchor anchor;
  final NativeMermaidXYTextBaseline baseline;
  final double rotation;
  final String role;
}

class NativeMermaidXYChartStroke {
  const NativeMermaidXYChartStroke(
    this.start,
    this.end,
    this.color,
    this.width,
  );

  final Offset start;
  final Offset end;
  final Color color;
  final double width;
}

class NativeMermaidXYChartBar {
  const NativeMermaidXYChartBar({
    required this.rect,
    required this.color,
    required this.seriesIndex,
    required this.pointIndex,
  });

  final Rect rect;
  final Color color;
  final int seriesIndex;
  final int pointIndex;
}

class NativeMermaidXYChartSeriesLayout {
  NativeMermaidXYChartSeriesLayout({
    required this.series,
    required this.color,
    required this.points,
    required Iterable<NativeMermaidXYChartBar> bars,
    required Iterable<NativeMermaidXYChartText> labels,
  }) : bars = List.unmodifiable(bars),
       labels = List.unmodifiable(labels);

  final NativeMermaidXYChartSeries series;
  final Color color;
  final List<Offset> points;
  final List<NativeMermaidXYChartBar> bars;
  final List<NativeMermaidXYChartText> labels;
}

class NativeMermaidXYChartAxisLayout {
  NativeMermaidXYChartAxisLayout({
    required this.position,
    required this.bounds,
    required this.range,
    required Iterable<double> tickPositions,
    required Iterable<NativeMermaidXYChartText> labels,
    required this.title,
    required Iterable<NativeMermaidXYChartStroke> strokes,
    required Iterable<String> tickLabels,
    required this.outerPadding,
  }) : tickPositions = List.unmodifiable(tickPositions),
       labels = List.unmodifiable(labels),
       strokes = List.unmodifiable(strokes),
       tickLabels = List.unmodifiable(tickLabels);

  final Axis position;
  final Rect bounds;
  final (double, double) range;
  final List<double> tickPositions;
  final List<String> tickLabels;
  final List<NativeMermaidXYChartText> labels;
  final NativeMermaidXYChartText? title;
  final List<NativeMermaidXYChartStroke> strokes;
  final double outerPadding;
}

class NativeMermaidXYChartLegendItem {
  const NativeMermaidXYChartLegendItem({
    required this.type,
    required this.color,
    required this.marker,
    required this.label,
  });

  final NativeMermaidXYPlotType type;
  final Color color;
  final Rect marker;
  final NativeMermaidXYChartText label;
}

class NativeMermaidXYChartLayout {
  NativeMermaidXYChartLayout({
    required this.viewBoxSize,
    required this.size,
    required this.scale,
    required this.background,
    required this.plotBounds,
    required Iterable<NativeMermaidXYChartSeriesLayout> series,
    required this.xAxis,
    required this.yAxis,
    required this.title,
    required Iterable<NativeMermaidXYChartLegendItem> legend,
    required this.fontFamily,
    required this.dark,
  }) : series = List.unmodifiable(series),
       legend = List.unmodifiable(legend);

  final Size viewBoxSize;
  final Size size;
  final double scale;
  final Color background;
  final Rect plotBounds;
  final List<NativeMermaidXYChartSeriesLayout> series;
  final NativeMermaidXYChartAxisLayout xAxis;
  final NativeMermaidXYChartAxisLayout yAxis;
  final NativeMermaidXYChartText? title;
  final List<NativeMermaidXYChartLegendItem> legend;
  final String? fontFamily;
  final bool dark;
}

/// Computes SVG user-unit geometry from Mermaid 11.17.2's XY chart builder.
/// The canvas is scaled uniformly to Mermaid's responsive max-width SVG size.
NativeMermaidXYChartLayout layoutNativeMermaidXYChart(
  NativeMermaidXYChartDiagram diagram, {
  required double width,
  required bool dark,
  String? fontFamily,
  double? measurementViewportWidth,
}) {
  final config = diagram.config;
  if (!width.isFinite || width <= 0) {
    throw FormatException(
      tr("Native XY chart viewport width must be positive"),
    );
  }
  if (!config.width.isFinite ||
      !config.height.isFinite ||
      config.width <= 0 ||
      config.height <= 0) {
    throw FormatException(tr("Native XY chart dimensions must be positive"));
  }
  if (diagram.series.isEmpty) {
    throw FormatException(tr("XY chart has no plot data"));
  }

  final themeText = dark
      ? NativeMermaidXYChartPalette.darkText
      : NativeMermaidXYChartPalette.lightText;
  // Mermaid measures hidden SVG tspans with getBoundingClientRect() and then
  // uses those CSS-pixel dimensions as SVG user units. Its hidden SVG inherits
  // the viewport width, while the rendered diagram may be inside a narrower
  // padded Markdown block. Keep those widths separate.
  final scale = math.min(1.0, width / config.width);
  final measurementScale = math.min(
    1.0,
    (measurementViewportWidth ?? width) / config.width,
  );
  final colors = dark
      ? NativeMermaidXYChartPalette.darkSeries
      : NativeMermaidXYChartPalette.lightSeries;
  final xDomain = _xDomain(diagram);
  final yDomain = _yDomain(diagram);
  final xTickValues = _axisTicks(
    diagram.xAxis,
    xDomain,
    reverse: config.orientation == Axis.horizontal,
  );
  final yTickValues = _axisTicks(
    diagram.yAxis,
    yDomain,
    reverse: config.orientation == Axis.vertical,
  );
  final titleText = config.showTitle && diagram.title.isNotEmpty
      ? diagram.title
      : '';

  var availableWidth = config.width;
  var availableHeight = config.height;
  var chartWidth = (availableWidth * config.plotReservedSpacePercent / 100)
      .floorToDouble();
  var chartHeight = (availableHeight * config.plotReservedSpacePercent / 100)
      .floorToDouble();
  availableWidth -= chartWidth;
  availableHeight -= chartHeight;

  final titleMetrics = _maxTextDimension(
    [titleText],
    config.titleFontSize,
    fontFamily,
    measurementScale,
  );
  var titleHeight = 0.0;
  NativeMermaidXYChartText? title;
  if (titleText.isNotEmpty) {
    titleHeight = titleMetrics.height + 2 * config.titlePadding;
    title = NativeMermaidXYChartText(
      text: titleText,
      position: Offset(config.width / 2, titleHeight / 2),
      fontSize: config.titleFontSize,
      color: themeText,
      baseline: NativeMermaidXYTextBaseline.middle,
      role: 'title',
    );
  }
  availableHeight -= titleHeight;

  final xAxisPosition = config.orientation == Axis.horizontal
      ? Axis.vertical
      : Axis.horizontal;
  final yAxisPosition = config.orientation == Axis.horizontal
      ? Axis.horizontal
      : Axis.vertical;
  final xAxisState = _AxisState(
    axis: diagram.xAxis,
    config: config.xAxis,
    position: xAxisPosition,
    side: config.orientation == Axis.horizontal ? 'left' : 'bottom',
    domain: xDomain,
    ticks: xTickValues,
    textColor: themeText,
    fontFamily: fontFamily,
    measurementScale: measurementScale,
  );
  final yAxisState = _AxisState(
    axis: diagram.yAxis,
    config: config.yAxis,
    position: yAxisPosition,
    side: config.orientation == Axis.horizontal ? 'top' : 'left',
    domain: yDomain,
    ticks: yTickValues,
    textColor: themeText,
    fontFamily: fontFamily,
    measurementScale: measurementScale,
  );

  var plotX = 0.0;
  var plotY = 0.0;
  late _AxisSpace xAxisSpace;
  late _AxisSpace yAxisSpace;
  if (config.orientation == Axis.horizontal) {
    xAxisSpace = xAxisState.calculateSpace(
      Size(availableWidth, availableHeight),
    );
    availableWidth -= xAxisSpace.width;
    plotX = xAxisSpace.width;
    yAxisSpace = yAxisState.calculateSpace(
      Size(availableWidth, availableHeight),
    );
    availableHeight -= yAxisSpace.height;
    plotY = titleHeight + yAxisSpace.height;
  } else {
    xAxisSpace = xAxisState.calculateSpace(
      Size(availableWidth, availableHeight),
    );
    availableHeight -= xAxisSpace.height;
    yAxisSpace = yAxisState.calculateSpace(
      Size(availableWidth, availableHeight),
    );
    plotX = yAxisSpace.width;
    availableWidth -= yAxisSpace.width;
    plotY = titleHeight;
  }

  final legendIndices = config.showLegend
      ? <int>[
          for (var index = 0; index < diagram.series.length; index++)
            if (diagram.series[index].title.isNotEmpty) index,
        ]
      : <int>[];
  final legendMarkerSize = config.legendFontSize * .75;
  final legendMarkerGap = config.legendFontSize * .35;
  final legendItemGap = config.legendFontSize * .5;
  final legendMaxLabel = _maxTextDimension(
    [for (final index in legendIndices) diagram.series[index].title],
    config.legendFontSize,
    fontFamily,
    measurementScale,
  );
  var legendWidth = 0.0;
  var legendHeight = 0.0;
  final legendAvailableHeight =
      (config.height * config.plotReservedSpacePercent / 100).floorToDouble();
  if (legendIndices.isNotEmpty) {
    final requiredWidth =
        config.legendPadding * 2 +
        legendMarkerSize +
        legendMarkerGap +
        legendMaxLabel.width;
    final requiredHeight =
        config.legendPadding * 2 +
        legendIndices.length * config.legendFontSize +
        (legendIndices.length - 1) * legendItemGap;
    if (requiredWidth <= availableWidth &&
        requiredHeight <= legendAvailableHeight) {
      legendWidth = requiredWidth;
      legendHeight = requiredHeight;
    } else {
      legendIndices.clear();
    }
  }
  availableWidth -= legendWidth;
  if (availableWidth > 0) {
    chartWidth += availableWidth;
    availableWidth = 0;
  }
  if (availableHeight > 0) {
    chartHeight += availableHeight;
    availableHeight = 0;
  }

  var plotBounds = Rect.fromLTWH(plotX, plotY, chartWidth, chartHeight);
  xAxisState.setRange(
    config.orientation == Axis.horizontal
        ? (plotY, plotY + chartHeight)
        : (plotX, plotX + chartWidth),
  );
  yAxisState.setRange(
    config.orientation == Axis.horizontal
        ? (plotX, plotX + chartWidth)
        : (plotY, plotY + chartHeight),
  );
  if (diagram.series.any((plot) => plot.type == NativeMermaidXYPlotType.bar)) {
    xAxisState.recalculateOuterPaddingForBars();
  }
  final xAxisLayout = xAxisState.finalizeSpace(
    config.orientation == Axis.horizontal
        ? Rect.fromLTWH(0, plotY, xAxisSpace.width, chartHeight)
        : Rect.fromLTWH(
            plotX,
            plotY + chartHeight,
            chartWidth,
            xAxisSpace.height,
          ),
  );
  final yAxisLayout = yAxisState.finalizeSpace(
    config.orientation == Axis.horizontal
        ? Rect.fromLTWH(plotX, titleHeight, chartWidth, yAxisSpace.height)
        : Rect.fromLTWH(0, plotY, yAxisSpace.width, chartHeight),
  );

  final seriesLayouts = <NativeMermaidXYChartSeriesLayout>[];
  for (
    var seriesIndex = 0;
    seriesIndex < diagram.series.length;
    seriesIndex++
  ) {
    final item = diagram.series[seriesIndex];
    final color = colors[seriesIndex == 0 ? 0 : seriesIndex % colors.length];
    final points = <Offset>[];
    final bars = <NativeMermaidXYChartBar>[];
    for (var i = 0; i < item.values.length; i++) {
      final dataX = _dataX(diagram, item, i, xDomain);
      if (dataX == null) continue;
      final xValue = xAxisState.scaleValue(dataX);
      final yValue = yAxisState.scaleValue(item.values[i]);
      final point = config.orientation == Axis.horizontal
          ? Offset(yValue, xValue)
          : Offset(xValue, yValue);
      points.add(point);
      if (item.type == NativeMermaidXYPlotType.bar) {
        final thickness =
            math.min(xAxisState.outerPadding * 2, xAxisState.tickDistance) *
            .95;
        final rect = config.orientation == Axis.horizontal
            ? Rect.fromLTRB(
                plotBounds.left,
                point.dy - thickness / 2,
                point.dx,
                point.dy + thickness / 2,
              )
            : Rect.fromLTRB(
                point.dx - thickness / 2,
                point.dy,
                point.dx + thickness / 2,
                plotBounds.bottom,
              );
        bars.add(
          NativeMermaidXYChartBar(
            rect: rect,
            color: color,
            seriesIndex: seriesIndex,
            pointIndex: i,
          ),
        );
      }
    }
    seriesLayouts.add(
      NativeMermaidXYChartSeriesLayout(
        series: item,
        color: color,
        points: points,
        bars: bars,
        labels: _pointLabels(item, points, color, config.orientation),
      ),
    );
  }

  final labelsBySeries = _barDataLabels(
    diagram,
    seriesLayouts,
    config,
    themeText,
    fontFamily,
  );
  if (labelsBySeries.isNotEmpty) {
    // Data labels are drawn after their bars but remain part of the matching
    // series geometry so capture and tests can inspect them.
    for (final entry in labelsBySeries.entries) {
      final seriesIndex = entry.key;
      if (seriesIndex >= seriesLayouts.length) continue;
      final prior = seriesLayouts[seriesIndex];
      seriesLayouts[seriesIndex] = NativeMermaidXYChartSeriesLayout(
        series: prior.series,
        color: prior.color,
        points: prior.points,
        bars: prior.bars,
        labels: [...prior.labels, ...entry.value],
      );
    }
  }

  final legend = <NativeMermaidXYChartLegendItem>[];
  if (legendIndices.isNotEmpty) {
    final x = plotBounds.right + config.legendPadding;
    final y =
        plotBounds.top +
        math.max((plotBounds.height - legendHeight) / 2, 0) +
        config.legendPadding;
    final rowHeight = config.legendFontSize + legendItemGap;
    for (var row = 0; row < legendIndices.length; row++) {
      final seriesIndex = legendIndices[row];
      final item = diagram.series[seriesIndex];
      final marker = Rect.fromLTWH(
        x,
        y + row * rowHeight,
        legendMarkerSize,
        item.type == NativeMermaidXYPlotType.bar ? legendMarkerSize : 0,
      );
      legend.add(
        NativeMermaidXYChartLegendItem(
          type: item.type,
          color: colors[seriesIndex == 0 ? 0 : seriesIndex % colors.length],
          marker: marker,
          label: NativeMermaidXYChartText(
            text: item.title,
            position: Offset(
              x + legendMarkerSize + legendMarkerGap,
              y + row * rowHeight + legendMarkerSize / 2,
            ),
            fontSize: config.legendFontSize,
            color: themeText,
            anchor: NativeMermaidXYTextAnchor.start,
            baseline: NativeMermaidXYTextBaseline.middle,
            role: 'legend',
          ),
        ),
      );
    }
  }

  final viewBoxSize = Size(config.width, config.height);
  final size = Size(viewBoxSize.width * scale, viewBoxSize.height * scale);
  plotBounds = Rect.fromLTWH(plotX, plotY, chartWidth, chartHeight);
  return NativeMermaidXYChartLayout(
    viewBoxSize: viewBoxSize,
    size: size,
    scale: scale,
    background: dark
        ? NativeMermaidXYChartPalette.darkBackground
        : NativeMermaidXYChartPalette.lightBackground,
    plotBounds: plotBounds,
    series: seriesLayouts,
    xAxis: xAxisLayout,
    yAxis: yAxisLayout,
    title: title,
    legend: legend,
    fontFamily: fontFamily,
    dark: dark,
  );
}

List<NativeMermaidXYChartText> _pointLabels(
  NativeMermaidXYChartSeries series,
  List<Offset> points,
  Color color,
  Axis orientation,
) {
  if (series.type != NativeMermaidXYPlotType.line ||
      series.pointLabels.isEmpty) {
    return const [];
  }
  final labels = <NativeMermaidXYChartText>[];
  for (
    var index = 0;
    index < points.length && index < series.pointLabels.length;
    index++
  ) {
    final label = series.pointLabels[index];
    if (label == null || label.isEmpty) continue;
    final point = points[index];
    final horizontal = orientation == Axis.horizontal;
    labels.add(
      NativeMermaidXYChartText(
        text: label,
        position: horizontal
            ? Offset(point.dx + 10, point.dy)
            : Offset(point.dx, point.dy - 10),
        fontSize: 12,
        color: color,
        anchor: horizontal
            ? NativeMermaidXYTextAnchor.start
            : NativeMermaidXYTextAnchor.middle,
        baseline: NativeMermaidXYTextBaseline.middle,
        role: 'line-point-label',
      ),
    );
  }
  return labels;
}

Map<int, List<NativeMermaidXYChartText>> _barDataLabels(
  NativeMermaidXYChartDiagram diagram,
  List<NativeMermaidXYChartSeriesLayout> layouts,
  NativeMermaidXYChartConfig config,
  Color color,
  String? fontFamily,
) {
  if (!config.showDataLabel || layouts.isEmpty || layouts.first.bars.isEmpty) {
    return const {};
  }
  final labels = <int, List<NativeMermaidXYChartText>>{};
  final firstValues = diagram.series.first.values;
  for (var seriesIndex = 0; seriesIndex < layouts.length; seriesIndex++) {
    final layout = layouts[seriesIndex];
    if (layout.bars.isEmpty) continue;
    final validBars = <NativeMermaidXYChartBar>[];
    final candidateFontSizes = <double>[];
    for (var index = 0; index < layout.bars.length; index++) {
      final bar = layout.bars[index];
      if (bar.rect.width <= 0 ||
          bar.rect.height <= 0 ||
          index >= firstValues.length) {
        continue;
      }
      final text = _formatNumber(firstValues[index]);
      var fontSize = config.orientation == Axis.horizontal
          ? bar.rect.height * .7
          : bar.rect.width / math.max(text.length * .7, 1);
      if (config.orientation == Axis.horizontal) {
        while (fontSize > 0 &&
            fontSize * text.length * .7 > bar.rect.width - 10) {
          fontSize -= 1;
        }
      } else {
        const yOffset = 10.0;
        while (fontSize > 0) {
          final textWidth = fontSize * text.length * .7;
          final centerX = bar.rect.center.dx;
          final leftEdge = centerX - textWidth / 2;
          final rightEdge = centerX + textWidth / 2;
          final fitsHorizontally =
              leftEdge >= bar.rect.left && rightEdge <= bar.rect.right;
          final fitsVertically =
              bar.rect.top + yOffset + fontSize <= bar.rect.bottom;
          if (fitsHorizontally && fitsVertically) break;
          fontSize -= 1;
        }
      }
      if (fontSize <= 0) continue;
      validBars.add(bar);
      candidateFontSizes.add(fontSize);
    }
    if (candidateFontSizes.isEmpty) continue;
    final uniformFontSize = candidateFontSizes.reduce(math.min).floorToDouble();
    if (uniformFontSize <= 0) continue;

    for (var index = 0; index < validBars.length; index++) {
      final bar = validBars[index];
      final pointIndex = bar.pointIndex;
      if (pointIndex >= firstValues.length) continue;
      final text = _formatNumber(firstValues[pointIndex]);
      final outside = config.showDataLabelOutsideBar;
      final horizontal = config.orientation == Axis.horizontal;
      final position = horizontal
          ? Offset(
              outside ? bar.rect.right + 10 : bar.rect.right - 10,
              bar.rect.center.dy,
            )
          : Offset(
              bar.rect.center.dx,
              outside ? bar.rect.top - 10 : bar.rect.top + 10,
            );
      final label = NativeMermaidXYChartText(
        text: text,
        position: position,
        fontSize: uniformFontSize,
        color: color,
        anchor: horizontal
            ? (outside
                  ? NativeMermaidXYTextAnchor.start
                  : NativeMermaidXYTextAnchor.end)
            : NativeMermaidXYTextAnchor.middle,
        baseline: horizontal
            ? NativeMermaidXYTextBaseline.middle
            : (outside
                  ? NativeMermaidXYTextBaseline.alphabetic
                  : NativeMermaidXYTextBaseline.top),
        role: 'data-label',
      );
      labels
          .putIfAbsent(seriesIndex, () => <NativeMermaidXYChartText>[])
          .add(label);
    }
  }
  return labels;
}

(double, double) _xDomain(NativeMermaidXYChartDiagram diagram) {
  final axis = diagram.xAxis;
  if (axis.type == NativeMermaidXYAxisType.band) {
    return (0, math.max(axis.categories.length - 1, 0).toDouble());
  }
  if (axis.type == NativeMermaidXYAxisType.linear &&
      axis.min != null &&
      axis.max != null) {
    return (axis.min!, axis.max!);
  }
  return (
    1.0,
    diagram.series
        .map((item) => item.values.length)
        .fold<int>(1, math.max)
        .toDouble(),
  );
}

(double, double) _yDomain(NativeMermaidXYChartDiagram diagram) {
  final axis = diagram.yAxis;
  if (axis.min != null && axis.max != null) return (axis.min!, axis.max!);
  var min = double.infinity;
  var max = double.negativeInfinity;
  for (final series in diagram.series) {
    final visibleLength = diagram.xAxis.type == NativeMermaidXYAxisType.band
        ? math.min(series.values.length, diagram.xAxis.categories.length)
        : series.values.length;
    for (final value in series.values.take(visibleLength)) {
      min = math.min(min, value);
      max = math.max(max, value);
    }
  }
  if (!min.isFinite || !max.isFinite) return (0, 1);
  return (min, max);
}

Object? _dataX(
  NativeMermaidXYChartDiagram diagram,
  NativeMermaidXYChartSeries series,
  int index,
  (double, double) domain,
) {
  if (diagram.xAxis.type == NativeMermaidXYAxisType.band) {
    if (index >= diagram.xAxis.categories.length) return null;
    return diagram.xAxis.categories[index];
  }
  if (series.values.length == 1) return domain.$1;
  return domain.$1 +
      (domain.$2 - domain.$1) * index / (series.values.length - 1);
}

List<Object> _axisTicks(
  NativeMermaidXYChartAxis axis,
  (double, double) domain, {
  required bool reverse,
}) {
  if (axis.type == NativeMermaidXYAxisType.band) {
    return List<Object>.from(axis.categories);
  }
  final values = _linearTicks(domain.$1, domain.$2, 10);
  return (reverse ? values.reversed : values).cast<Object>().toList(
    growable: false,
  );
}

List<double> _linearTicks(double start, double stop, int count) {
  if (!start.isFinite || !stop.isFinite || count <= 0) return const [];
  final reverse = stop < start;
  if (reverse) {
    final swap = start;
    start = stop;
    stop = swap;
  }
  if (start == stop) return [start];
  final rawStep = (stop - start) / count;
  final power = (math.log(rawStep) / math.ln10).floor();
  final error = rawStep / math.pow(10, power);
  final factor = error >= math.sqrt(50)
      ? 10
      : error >= math.sqrt(10)
      ? 5
      : error >= math.sqrt(2)
      ? 2
      : 1;
  final step = factor * math.pow(10, power).toDouble();
  if (step <= 0 || !step.isFinite) return const [];
  final first = (start / step).ceil();
  final last = (stop / step).floor();
  if (last < first) return const [];
  final values = <double>[];
  for (var index = first; index <= last && values.length < 1000; index++) {
    final value = index * step;
    values.add(value == 0 ? 0 : value);
  }
  return reverse ? values.reversed.toList(growable: false) : values;
}

String _formatNumber(double value) {
  if (value == 0) return '0';
  if (value == value.roundToDouble()) return value.toInt().toString();
  return value.toString();
}

class _TextDimension {
  const _TextDimension(this.width, this.height);
  final double width;
  final double height;
}

_TextDimension _maxTextDimension(
  Iterable<String> values,
  double fontSize,
  String? fontFamily,
  double scale,
) {
  var width = 0.0;
  var height = 0.0;
  for (final text in values) {
    final painter = _makeTextPainter(text, fontSize, Colors.black, fontFamily)
      ..layout();
    width = math.max(width, painter.width * scale);
    // Mermaid's tspan getBoundingClientRect() reflects glyph bounds rather
    // than the TextPainter line box, so use the selected glyph box here.
    for (final box in painter.getBoxesForSelection(
      TextSelection(baseOffset: 0, extentOffset: text.length),
    )) {
      height = math.max(height, box.toRect().height * scale);
    }
    painter.dispose();
  }
  return _TextDimension(width, height);
}

TextPainter _makeTextPainter(
  String text,
  double fontSize,
  Color color,
  String? fontFamily,
) => TextPainter(
  text: TextSpan(
    text: text,
    style: TextStyle(
      color: color,
      fontFamily: fontFamily,
      fontSize: fontSize,
      fontWeight: FontWeight.w400,
      height: 1,
      letterSpacing: 0,
      fontVariations: [ui.FontVariation('opsz', fontSize)],
    ),
  ),
  textDirection: TextDirection.ltr,
  textScaler: TextScaler.noScaling,
  maxLines: 1,
);

class _AxisSpace {
  const _AxisSpace(this.width, this.height);
  final double width;
  final double height;
}

class _AxisState {
  _AxisState({
    required this.axis,
    required this.config,
    required this.position,
    required this.side,
    required this.domain,
    required this.ticks,
    required this.textColor,
    required this.fontFamily,
    required this.measurementScale,
  });

  final NativeMermaidXYChartAxis axis;
  final NativeMermaidXYChartAxisConfig config;
  final Axis position;
  final String side;
  final (double, double) domain;
  final List<Object> ticks;
  final Color textColor;
  final String? fontFamily;
  final double measurementScale;
  double outerPadding = 0;
  double _rangeStart = 0;
  double _rangeEnd = 0;
  double _titleTextHeight = 0;
  bool _showAxisLine = false;
  bool _showLabel = false;
  bool _showTick = false;
  bool _showTitle = false;
  _AxisSpace _space = const _AxisSpace(0, 0);
  NativeMermaidXYChartAxisLayout? _layout;

  NativeMermaidXYChartAxisLayout get layout => _layout!;
  double get tickDistance => ticks.isEmpty
      ? 0
      : (_scaleRangeEnd() - _scaleRangeStart()).abs() / ticks.length;

  _AxisSpace calculateSpace(Size available) {
    _showAxisLine = false;
    _showLabel = false;
    _showTick = false;
    _showTitle = false;
    outerPadding = 0;
    _titleTextHeight = 0;
    var availableWidth = available.width;
    var availableHeight = available.height;
    if (side == 'left') {
      if (config.showAxisLine && availableWidth > config.axisLineWidth) {
        availableWidth -= config.axisLineWidth;
        _showAxisLine = true;
      }
      if (config.showLabel) {
        final dimension = _maxTextDimension(
          ticks.map(_tickString),
          config.labelFontSize,
          fontFamily,
          measurementScale,
        );
        outerPadding = math.min(dimension.height / 2, .2 * available.height);
        final required = dimension.width + config.labelPadding * 2;
        if (required <= availableWidth) {
          availableWidth -= required;
          _showLabel = true;
        }
      }
      if (config.showTick && availableWidth >= config.tickLength) {
        availableWidth -= config.tickLength;
        _showTick = true;
      }
      if (config.showTitle && axis.title.isNotEmpty) {
        final dimension = _maxTextDimension(
          [axis.title],
          config.titleFontSize,
          fontFamily,
          measurementScale,
        );
        _titleTextHeight = dimension.height;
        final required = dimension.height + config.titlePadding * 2;
        if (required <= availableWidth) {
          availableWidth -= required;
          _showTitle = true;
        }
      }
      _space = _AxisSpace(available.width - availableWidth, available.height);
    } else {
      if (config.showAxisLine && availableHeight > config.axisLineWidth) {
        availableHeight -= config.axisLineWidth;
        _showAxisLine = true;
      }
      if (config.showLabel) {
        final dimension = _maxTextDimension(
          ticks.map(_tickString),
          config.labelFontSize,
          fontFamily,
          measurementScale,
        );
        outerPadding = math.min(dimension.width / 2, .2 * available.width);
        var required = dimension.height;
        if (side == 'bottom' && config.labelRotation != 0) {
          final angle = _normalizedRotation;
          required = math.max(
            required,
            math.sin(angle).abs() * dimension.width +
                math.cos(angle).abs() * dimension.height,
          );
        }
        required += config.labelPadding * 2;
        if (required <= availableHeight) {
          availableHeight -= required;
          _showLabel = true;
        }
      }
      if (config.showTick && availableHeight >= config.tickLength) {
        availableHeight -= config.tickLength;
        _showTick = true;
      }
      if (config.showTitle && axis.title.isNotEmpty) {
        final dimension = _maxTextDimension(
          [axis.title],
          config.titleFontSize,
          fontFamily,
          measurementScale,
        );
        _titleTextHeight = dimension.height;
        final required = dimension.height + config.titlePadding * 2;
        if (required <= availableHeight) {
          availableHeight -= required;
          _showTitle = true;
        }
      }
      _space = _AxisSpace(available.width, available.height - availableHeight);
    }
    return _space;
  }

  double get _normalizedRotation =>
      config.labelRotation >= -90 && config.labelRotation <= 90
      ? config.labelRotation * math.pi / 180
      : 0;

  void setRange((double, double) range) {
    _rangeStart = range.$1;
    _rangeEnd = range.$2;
  }

  void recalculateOuterPaddingForBars() {
    if (.7 * tickDistance > outerPadding * 2) {
      outerPadding = (.7 * tickDistance / 2).floorToDouble();
    }
  }

  double _scaleRangeStart() => _rangeStart + outerPadding;
  double _scaleRangeEnd() => _rangeEnd - outerPadding;

  double scaleValue(Object value) {
    final low = _scaleRangeStart();
    final high = _scaleRangeEnd();
    if (axis.type == NativeMermaidXYAxisType.band) {
      final index = axis.categories.indexOf(value.toString());
      if (index < 0) return low;
      final denominator = math.max(1, axis.categories.length - 1);
      return low + (high - low) * index / denominator;
    }
    final (minValue, maxValue) = domain;
    // Y-axis values are reversed only when they are placed at the left. A
    // horizontal chart's x axis is also left-positioned, matching Mermaid.
    final reverse = side == 'left';
    final domainStart = reverse ? maxValue : minValue;
    final domainEnd = reverse ? minValue : maxValue;
    if (domainStart == domainEnd) return (low + high) / 2;
    final number = value is num
        ? value.toDouble()
        : double.tryParse('$value') ?? domainStart;
    return low +
        (number - domainStart) / (domainEnd - domainStart) * (high - low);
  }

  NativeMermaidXYChartAxisLayout finalizeSpace(Rect bounds) {
    final range = (_rangeStart, _rangeEnd);
    final axisLabels = <NativeMermaidXYChartText>[];
    final strokes = <NativeMermaidXYChartStroke>[];
    final positions = <double>[];
    final labels = ticks.map(_tickString).toList(growable: false);
    final scaleValues = <double>[];
    for (final tick in ticks) {
      final value = axis.type == NativeMermaidXYAxisType.band
          ? tick
          : double.tryParse(_tickString(tick)) ?? 0.0;
      scaleValues.add(scaleValue(value));
    }
    positions.addAll(scaleValues);

    if (side == 'left') {
      if (_showAxisLine) {
        final x = bounds.right - config.axisLineWidth / 2;
        strokes.add(
          NativeMermaidXYChartStroke(
            Offset(x, bounds.top),
            Offset(x, bounds.bottom),
            textColor,
            config.axisLineWidth,
          ),
        );
      }
      if (_showLabel) {
        for (var index = 0; index < ticks.length; index++) {
          axisLabels.add(
            NativeMermaidXYChartText(
              text: labels[index],
              position: Offset(
                bounds.right -
                    config.labelPadding -
                    (_showTick ? config.tickLength : 0) -
                    (_showAxisLine ? config.axisLineWidth : 0),
                scaleValues[index],
              ),
              fontSize: config.labelFontSize,
              color: textColor,
              anchor: NativeMermaidXYTextAnchor.end,
              baseline: NativeMermaidXYTextBaseline.middle,
              role: 'axis-label',
            ),
          );
        }
      }
      if (_showTick) {
        final x = bounds.right - (_showAxisLine ? config.axisLineWidth : 0);
        for (final y in scaleValues) {
          strokes.add(
            NativeMermaidXYChartStroke(
              Offset(x, y),
              Offset(x - config.tickLength, y),
              textColor,
              config.tickWidth,
            ),
          );
        }
      }
      if (_showTitle) {
        axisLabels.add(
          NativeMermaidXYChartText(
            text: axis.title,
            position: Offset(
              bounds.left + config.titlePadding,
              bounds.center.dy,
            ),
            fontSize: config.titleFontSize,
            color: textColor,
            anchor: NativeMermaidXYTextAnchor.middle,
            baseline: NativeMermaidXYTextBaseline.middle,
            rotation: -math.pi / 2,
            role: 'axis-title',
          ),
        );
      }
    } else {
      final isTop = side == 'top';
      if (_showAxisLine) {
        final y = isTop
            ? bounds.bottom - config.axisLineWidth / 2
            : bounds.top + config.axisLineWidth / 2;
        strokes.add(
          NativeMermaidXYChartStroke(
            Offset(bounds.left, y),
            Offset(bounds.right, y),
            textColor,
            config.axisLineWidth,
          ),
        );
      }
      if (_showLabel) {
        final angle = isTop ? 0.0 : _normalizedRotation;
        final metrics = _maxTextDimension(
          labels,
          config.labelFontSize,
          fontFamily,
          measurementScale,
        );
        final xOffset = math.sin(angle) * metrics.height / 2;
        final yOffset = (math.sin(angle) * metrics.width / 2).abs();
        for (var index = 0; index < ticks.length; index++) {
          axisLabels.add(
            NativeMermaidXYChartText(
              text: labels[index],
              position: Offset(
                scaleValues[index] + xOffset,
                isTop
                    ? bounds.top +
                          (_showTitle
                              ? _titleTextHeight + config.titlePadding * 2
                              : 0) +
                          config.labelPadding
                    : bounds.top +
                          config.labelPadding +
                          (_showTick ? config.tickLength : 0) +
                          (_showAxisLine ? config.axisLineWidth : 0) +
                          yOffset,
              ),
              fontSize: config.labelFontSize,
              color: textColor,
              anchor: NativeMermaidXYTextAnchor.middle,
              baseline: NativeMermaidXYTextBaseline.top,
              rotation: angle,
              role: 'axis-label',
            ),
          );
        }
      }
      if (_showTick) {
        final y = isTop
            ? bounds.bottom - (_showAxisLine ? config.axisLineWidth : 0)
            : bounds.top + (_showAxisLine ? config.axisLineWidth : 0);
        for (final x in scaleValues) {
          strokes.add(
            NativeMermaidXYChartStroke(
              Offset(x, y),
              Offset(x, isTop ? y - config.tickLength : y + config.tickLength),
              textColor,
              config.tickWidth,
            ),
          );
        }
      }
      if (_showTitle) {
        axisLabels.add(
          NativeMermaidXYChartText(
            text: axis.title,
            position: isTop
                ? Offset(
                    bounds.left + bounds.width / 2,
                    bounds.top + config.titlePadding,
                  )
                : Offset(
                    (_rangeStart + _rangeEnd) / 2,
                    bounds.bottom - config.titlePadding - _titleTextHeight,
                  ),
            fontSize: config.titleFontSize,
            color: textColor,
            anchor: NativeMermaidXYTextAnchor.middle,
            baseline: NativeMermaidXYTextBaseline.top,
            role: 'axis-title',
          ),
        );
      }
    }

    _layout = NativeMermaidXYChartAxisLayout(
      position: position,
      bounds: bounds,
      range: range,
      tickPositions: positions,
      tickLabels: labels,
      labels: axisLabels,
      title: axisLabels.where((text) => text.role == 'axis-title').firstOrNull,
      strokes: strokes,
      outerPadding: outerPadding,
    );
    return _layout!;
  }
}

String _tickString(Object value) =>
    value is double ? _formatNumber(value) : '$value';

class NativeMermaidXYChart extends StatelessWidget {
  const NativeMermaidXYChart({
    super.key,
    required this.diagram,
    required this.dark,
  });

  final NativeMermaidXYChartDiagram diagram;
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
              : diagram.config.width;
          final layout = layoutNativeMermaidXYChart(
            diagram,
            width: width,
            dark: dark,
            fontFamily: fontFamily,
            measurementViewportWidth: MediaQuery.sizeOf(context).width,
          );
          return Center(
            child: CustomPaint(
              key: const ValueKey('native-mermaid-xy-chart-paint'),
              size: layout.size,
              painter: _NativeMermaidXYChartPainter(layout),
            ),
          );
        },
      ),
    );
  }
}

class _NativeMermaidXYChartPainter extends CustomPainter {
  const _NativeMermaidXYChartPainter(this.layout);
  final NativeMermaidXYChartLayout layout;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(layout.scale);
    canvas.drawRect(
      Offset.zero & layout.viewBoxSize,
      Paint()..color = layout.background,
    );
    if (layout.title != null) {
      _paintText(canvas, layout.title!, layout.fontFamily);
    }
    for (final item in layout.series) {
      if (item.series.type == NativeMermaidXYPlotType.bar) {
        for (final bar in item.bars) {
          canvas.drawRect(bar.rect, Paint()..color = bar.color);
        }
      } else if (item.points.isNotEmpty) {
        final path = Path()..moveTo(item.points.first.dx, item.points.first.dy);
        for (final point in item.points.skip(1)) {
          path.lineTo(point.dx, point.dy);
        }
        canvas.drawPath(
          path,
          Paint()
            ..color = item.color
            ..strokeWidth = 2
            ..style = PaintingStyle.stroke,
        );
      }
      for (final label in item.labels) {
        _paintText(canvas, label, layout.fontFamily);
      }
    }
    for (final item in layout.legend) {
      if (item.type == NativeMermaidXYPlotType.bar) {
        canvas.drawRect(item.marker, Paint()..color = item.color);
      } else {
        canvas.drawLine(
          item.marker.topLeft,
          item.marker.topRight,
          Paint()
            ..color = item.color
            ..strokeWidth = 2,
        );
      }
      _paintText(canvas, item.label, layout.fontFamily);
    }
    for (final stroke in [...layout.xAxis.strokes, ...layout.yAxis.strokes]) {
      canvas.drawLine(
        stroke.start,
        stroke.end,
        Paint()
          ..color = stroke.color
          ..strokeWidth = stroke.width,
      );
    }
    for (final label in [...layout.xAxis.labels, ...layout.yAxis.labels]) {
      _paintText(canvas, label, layout.fontFamily);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _NativeMermaidXYChartPainter oldDelegate) =>
      oldDelegate.layout != layout;
}

void _paintText(
  Canvas canvas,
  NativeMermaidXYChartText text,
  String? fontFamily,
) {
  final painter = _makeTextPainter(
    text.text,
    text.fontSize,
    text.color,
    fontFamily,
  )..layout();
  final x = switch (text.anchor) {
    NativeMermaidXYTextAnchor.start => 0.0,
    NativeMermaidXYTextAnchor.middle => -painter.width / 2,
    NativeMermaidXYTextAnchor.end => -painter.width,
  };
  final y = switch (text.baseline) {
    NativeMermaidXYTextBaseline.top => 0.0,
    NativeMermaidXYTextBaseline.middle => -painter.height / 2,
    NativeMermaidXYTextBaseline.alphabetic =>
      -painter.computeDistanceToActualBaseline(TextBaseline.alphabetic),
  };
  canvas.save();
  canvas.translate(text.position.dx, text.position.dy);
  if (text.rotation != 0) canvas.rotate(text.rotation);
  painter.paint(canvas, Offset(x, y));
  canvas.restore();
  painter.dispose();
}
