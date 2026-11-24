import '../render_l10n.dart';
import 'package:flutter/material.dart';

enum NativeMermaidXYAxisType { linear, band }

enum NativeMermaidXYPlotType { bar, line }

class NativeMermaidXYChartAxisConfig {
  const NativeMermaidXYChartAxisConfig({
    this.showLabel = true,
    this.labelFontSize = 14,
    this.labelPadding = 5,
    this.showTitle = true,
    this.titleFontSize = 16,
    this.titlePadding = 5,
    this.showTick = true,
    this.tickLength = 5,
    this.tickWidth = 2,
    this.showAxisLine = true,
    this.axisLineWidth = 2,
    this.labelRotation = 0,
  });

  final bool showLabel;
  final double labelFontSize;
  final double labelPadding;
  final bool showTitle;
  final double titleFontSize;
  final double titlePadding;
  final bool showTick;
  final double tickLength;
  final double tickWidth;
  final bool showAxisLine;
  final double axisLineWidth;
  final double labelRotation;
}

class NativeMermaidXYChartConfig {
  const NativeMermaidXYChartConfig({
    this.width = 700,
    this.height = 500,
    this.titleFontSize = 20,
    this.titlePadding = 10,
    this.showDataLabel = false,
    this.showDataLabelOutsideBar = false,
    this.showTitle = true,
    this.showLegend = true,
    this.legendFontSize = 14,
    this.legendPadding = 10,
    this.orientation = Axis.vertical,
    this.plotReservedSpacePercent = 50,
    this.xAxis = const NativeMermaidXYChartAxisConfig(),
    this.yAxis = const NativeMermaidXYChartAxisConfig(),
  });

  final double width;
  final double height;
  final double titleFontSize;
  final double titlePadding;
  final bool showDataLabel;
  final bool showDataLabelOutsideBar;
  final bool showTitle;
  final bool showLegend;
  final double legendFontSize;
  final double legendPadding;
  final Axis orientation;
  final double plotReservedSpacePercent;
  final NativeMermaidXYChartAxisConfig xAxis;
  final NativeMermaidXYChartAxisConfig yAxis;
}

class NativeMermaidXYChartAxis {
  NativeMermaidXYChartAxis({
    required this.type,
    required this.title,
    required this.explicitlySet,
    this.min,
    this.max,
    Iterable<String> categories = const [],
  }) : categories = List.unmodifiable(categories);

  final NativeMermaidXYAxisType type;
  final String title;
  final bool explicitlySet;
  final double? min;
  final double? max;
  final List<String> categories;
}

class NativeMermaidXYChartSeries {
  NativeMermaidXYChartSeries({
    required this.type,
    required this.title,
    required Iterable<double> values,
    Iterable<String?> pointLabels = const [],
  }) : values = List.unmodifiable(values),
       pointLabels = List.unmodifiable(pointLabels);

  final NativeMermaidXYPlotType type;
  final String title;
  final List<double> values;
  final List<String?> pointLabels;
}

/// Parsed subset of Mermaid 11.17.2 `xychart-beta` source.
///
/// This keeps data in source order. The chart layout stage derives x coordinates,
/// inferred y domains, palette colors and SVG user-unit geometry.
class NativeMermaidXYChartDiagram {
  NativeMermaidXYChartDiagram({
    required this.title,
    required this.xAxis,
    required this.yAxis,
    required Iterable<NativeMermaidXYChartSeries> series,
    this.config = const NativeMermaidXYChartConfig(),
    this.accessibleTitle = '',
    this.accessibleDescription = '',
  }) : series = List.unmodifiable(series);

  final String title;
  final NativeMermaidXYChartAxis xAxis;
  final NativeMermaidXYChartAxis yAxis;
  final List<NativeMermaidXYChartSeries> series;
  final NativeMermaidXYChartConfig config;
  final String accessibleTitle;
  final String accessibleDescription;

  String get semanticsLabel {
    final parts = <String>[tr("XY chart")];
    if (accessibleTitle.isNotEmpty) parts.add(accessibleTitle);
    if (accessibleDescription.isNotEmpty) parts.add(accessibleDescription);
    if (title.isNotEmpty) parts.add(title);
    if (xAxis.title.isNotEmpty) parts.add(tr("X axis: {0}", [xAxis.title]));
    if (yAxis.title.isNotEmpty) parts.add(tr("Y axis: {0}", [yAxis.title]));
    for (final item in series) {
      if (item.title.isNotEmpty) parts.add(tr("{0} series", [item.title]));
    }
    return parts.join('. ');
  }
}

class NativeMermaidXYChartPalette {
  const NativeMermaidXYChartPalette._();

  static const lightBackground = Color(0xFFFFFFFF);
  static const lightText = Color(0xFF0F1115);
  static const lightSeries = <Color>[
    Color(0xFFFFF4DD),
    Color(0xFFFFD8B1),
    Color(0xFFFFA07A),
    Color(0xFFECEFF1),
    Color(0xFFD6DBDF),
    Color(0xFFC3E0A8),
    Color(0xFFFFB6A4),
    Color(0xFFFFD74D),
    Color(0xFF738FA7),
    Color(0xFFFFFFF0),
  ];

  static const darkBackground = Color(0xFF333333);
  static const darkText = Color(0xFFE0DFDF);
  static const darkSeries = <Color>[
    Color(0xFF3498DB),
    Color(0xFF2ECC71),
    Color(0xFFE74C3C),
    Color(0xFFF1C40F),
    Color(0xFFBDC3C7),
    Color(0xFFFFFFFF),
    Color(0xFF34495E),
    Color(0xFF9B59B6),
    Color(0xFF1ABC9C),
    Color(0xFFE67E22),
  ];
}
