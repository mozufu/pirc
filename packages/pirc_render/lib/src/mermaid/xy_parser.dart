import '../render_l10n.dart';
import 'dart:convert';

import 'package:flutter/material.dart';

import 'xy_model.dart';

/// Parses Mermaid 11.17.2's static `xychart-beta` grammar subset.
///
/// Unsupported syntax throws [FormatException] so callers can keep the source
/// visible instead of silently dropping chart data or configuration.
NativeMermaidXYChartDiagram parseNativeMermaidXYChart(String source) {
  final lines = source
      .replaceAll('\r\n', '\n')
      .replaceAll('\r', '\n')
      .split('\n');
  var config = const NativeMermaidXYChartConfig();
  var sawHeader = false;
  var sawXAxis = false;
  var sawYAxis = false;
  var title = '';
  var accessibleTitle = '';
  var accessibleDescription = '';
  var xAxis = NativeMermaidXYChartAxis(
    type: NativeMermaidXYAxisType.band,
    title: '',
    explicitlySet: false,
  );
  var yAxis = NativeMermaidXYChartAxis(
    type: NativeMermaidXYAxisType.linear,
    title: '',
    explicitlySet: false,
  );
  final series = <NativeMermaidXYChartSeries>[];

  for (var index = 0; index < lines.length; index++) {
    final original = lines[index];
    final line = original.trim();
    if (line.isEmpty || line.startsWith('~~~') || line.startsWith('```')) {
      continue;
    }
    if (line.startsWith('%%{')) {
      config = _parseInit(line, config, source, index + 1);
      continue;
    }
    if (line.startsWith('%%')) continue;
    final statement = _stripInlineComment(line).trim();
    if (statement.isEmpty) continue;

    if (!sawHeader) {
      final header = RegExp(
        r'^(?:xychart-beta|xychart)(?:\s+(horizontal|vertical))?\s*$',
        caseSensitive: false,
      ).firstMatch(statement);
      if (header == null) {
        throw FormatException(
          tr("Expected xychart-beta header, found: {0}", [statement]),
          source,
          index + 1,
        );
      }
      final orientation = header[1]?.toLowerCase();
      config = _copyConfig(
        config,
        orientation: orientation == 'horizontal'
            ? Axis.horizontal
            : Axis.vertical,
      );
      sawHeader = true;
      continue;
    }

    final titleMatch = RegExp(
      r'^title\s+(.+)$',
      caseSensitive: false,
    ).firstMatch(statement);
    if (titleMatch != null) {
      title = _decodeText(titleMatch[1]!, source, index + 1);
      continue;
    }
    final accTitleMatch = RegExp(
      r'^accTitle\s*:\s*(.*)$',
      caseSensitive: false,
    ).firstMatch(statement);
    if (accTitleMatch != null) {
      accessibleTitle = _decodeText(
        accTitleMatch[1]!,
        source,
        index + 1,
        allowEmpty: true,
      );
      continue;
    }
    final accDescriptionMatch = RegExp(
      r'^accDescr\s*:\s*(.*)$',
      caseSensitive: false,
    ).firstMatch(statement);
    if (accDescriptionMatch != null) {
      accessibleDescription = _decodeText(
        accDescriptionMatch[1]!,
        source,
        index + 1,
        allowEmpty: true,
      );
      continue;
    }
    if (RegExp(
      r'^accDescr\s*\{\s*$',
      caseSensitive: false,
    ).hasMatch(statement)) {
      final linesInDescription = <String>[];
      var closed = false;
      while (++index < lines.length) {
        final row = lines[index];
        final close = row.indexOf('}');
        if (close >= 0) {
          linesInDescription.add(row.substring(0, close));
          if (row.substring(close + 1).trim().isNotEmpty) {
            throw FormatException(
              tr("Unexpected text after accDescr block"),
              source,
              index + 1,
            );
          }
          closed = true;
          break;
        }
        linesInDescription.add(row);
      }
      if (!closed) {
        throw FormatException(tr("Unclosed accDescr block"), source, index + 1);
      }
      accessibleDescription = linesInDescription.join('\n').trim();
      continue;
    }

    final xAxisMatch = RegExp(
      r'^x-axis\b(.*)$',
      caseSensitive: false,
    ).firstMatch(statement);
    if (xAxisMatch != null) {
      if (sawXAxis) {
        throw FormatException(
          tr("Duplicate x-axis declaration"),
          source,
          index + 1,
        );
      }
      xAxis = _parseAxis(
        xAxisMatch[1]!,
        isXAxis: true,
        source: source,
        line: index + 1,
      );
      sawXAxis = true;
      continue;
    }
    final yAxisMatch = RegExp(
      r'^y-axis\b(.*)$',
      caseSensitive: false,
    ).firstMatch(statement);
    if (yAxisMatch != null) {
      if (sawYAxis) {
        throw FormatException(
          tr("Duplicate y-axis declaration"),
          source,
          index + 1,
        );
      }
      yAxis = _parseAxis(
        yAxisMatch[1]!,
        isXAxis: false,
        source: source,
        line: index + 1,
      );
      sawYAxis = true;
      continue;
    }

    final plotMatch = RegExp(
      r'^(bar|line)\b(.*)$',
      caseSensitive: false,
    ).firstMatch(statement);
    if (plotMatch != null) {
      final parsed = _parsePlotData(
        plotMatch[2]!,
        source: source,
        line: index + 1,
      );
      series.add(
        NativeMermaidXYChartSeries(
          type: plotMatch[1]!.toLowerCase() == 'bar'
              ? NativeMermaidXYPlotType.bar
              : NativeMermaidXYPlotType.line,
          title: parsed.$1,
          values: parsed.$2,
          pointLabels: plotMatch[1]!.toLowerCase() == 'line'
              ? parsed.$3 ?? const <String?>[]
              : const <String?>[],
        ),
      );
      continue;
    }

    throw FormatException(
      tr("Unsupported or invalid native XY chart statement: {0}", [statement]),
      source,
      index + 1,
    );
  }

  if (!sawHeader) throw FormatException(tr("Expected xychart-beta header"));
  if (series.isEmpty) {
    throw FormatException(
      tr("No Plot to render, please provide a plot with some data"),
    );
  }
  if (xAxis.type == NativeMermaidXYAxisType.band &&
      xAxis.explicitlySet &&
      xAxis.categories.isEmpty) {
    throw FormatException(
      tr("A categorical x-axis needs at least one category"),
    );
  }
  if (xAxis.type == NativeMermaidXYAxisType.band) {
    for (final plot in series) {
      if (plot.values.length < xAxis.categories.length) {
        throw FormatException(
          tr(
            "Native XY chart does not support a series shorter than its category axis",
          ),
        );
      }
    }
  }

  if (!xAxis.explicitlySet) {
    final length = series
        .map((plot) => plot.values.length)
        .fold<int>(1, (a, b) => a > b ? a : b);
    xAxis = NativeMermaidXYChartAxis(
      type: NativeMermaidXYAxisType.linear,
      title: xAxis.title,
      explicitlySet: false,
      min: 1,
      max: length.toDouble(),
    );
  }
  if (yAxis.min == null || yAxis.max == null) {
    var minimum = double.infinity;
    var maximum = double.negativeInfinity;
    for (final plot in series) {
      final length = xAxis.type == NativeMermaidXYAxisType.band
          ? xAxis.categories.length
          : plot.values.length;
      for (final value in plot.values.take(length)) {
        minimum = value < minimum ? value : minimum;
        maximum = value > maximum ? value : maximum;
      }
    }
    yAxis = NativeMermaidXYChartAxis(
      type: NativeMermaidXYAxisType.linear,
      title: yAxis.title,
      explicitlySet: false,
      min: minimum.isFinite ? minimum : 0,
      max: maximum.isFinite ? maximum : 1,
    );
  }

  return NativeMermaidXYChartDiagram(
    title: title,
    xAxis: xAxis,
    yAxis: yAxis,
    series: series,
    config: config,
    accessibleTitle: accessibleTitle,
    accessibleDescription: accessibleDescription,
  );
}

NativeMermaidXYChartAxis _parseAxis(
  String sourceText, {
  required bool isXAxis,
  required String source,
  required int line,
}) {
  final leading = sourceText.trimLeft();
  final decoded = _takeOptionalQuotedText(leading, source, line);
  final title = decoded.$1;
  final rest = decoded.$2.trim();
  if (isXAxis && rest.startsWith('[')) {
    final categories = _parseCategoryList(rest, source, line);
    return NativeMermaidXYChartAxis(
      type: NativeMermaidXYAxisType.band,
      title: title,
      explicitlySet: true,
      categories: categories,
    );
  }
  final range = RegExp(
    r'^([+-]?(?:\d+(?:\.\d*)?|\.\d+))\s*-->\s*([+-]?(?:\d+(?:\.\d*)?|\.\d+))\s*$',
  ).firstMatch(rest);
  if (range != null) {
    final min = _parseFiniteNumber(range[1]!, source, line);
    final max = _parseFiniteNumber(range[2]!, source, line);
    return NativeMermaidXYChartAxis(
      type: NativeMermaidXYAxisType.linear,
      title: title,
      explicitlySet: true,
      min: min,
      max: max,
    );
  }
  if (rest.isEmpty) {
    return NativeMermaidXYChartAxis(
      type: NativeMermaidXYAxisType.linear,
      title: title,
      explicitlySet: false,
    );
  }
  throw FormatException(
    tr("{0} accepts a title, numeric range, or x-axis categories", [
      isXAxis ? 'x-axis' : 'y-axis',
    ]),
    source,
    line,
  );
}

(String, List<double>, List<String?>?) _parsePlotData(
  String sourceText, {
  required String source,
  required int line,
}) {
  final open = sourceText.indexOf('[');
  final close = sourceText.lastIndexOf(']');
  if (open < 0 ||
      close < open ||
      sourceText.substring(close + 1).trim().isNotEmpty) {
    throw FormatException(
      tr("A bar or line plot requires a bracketed data list"),
      source,
      line,
    );
  }
  final title = _decodeText(
    sourceText.substring(0, open),
    source,
    line,
    allowEmpty: true,
  );
  final data = sourceText.substring(open + 1, close);
  final values = <double>[];
  final labels = <String?>[];
  for (final item in _splitCommaSeparated(data, source, line)) {
    if (item.trim().isEmpty) {
      throw FormatException(
        tr("An XY chart data list cannot contain an empty value"),
        source,
        line,
      );
    }
    final match = RegExp(
      r'^\s*([+-]?(?:\d+(?:\.\d*)?|\.\d+))(?:\s+(.+?))?\s*$',
    ).firstMatch(item);
    if (match == null) {
      throw FormatException(
        tr("Invalid XY chart datum: {0}", [item.trim()]),
        source,
        line,
      );
    }
    values.add(_parseFiniteNumber(match[1]!, source, line));
    final labelText = match[2]?.trim();
    labels.add(labelText == null ? null : _decodeText(labelText, source, line));
  }
  if (values.isEmpty) {
    throw FormatException(
      tr("XY chart data list cannot be empty"),
      source,
      line,
    );
  }
  final anyLabel = labels.any((label) => label != null && label.isNotEmpty);
  return (title, values, anyLabel ? labels : null);
}

List<String> _parseCategoryList(String sourceText, String source, int line) {
  if (!sourceText.endsWith(']')) {
    throw FormatException(
      tr("An x-axis category list must end with ]"),
      source,
      line,
    );
  }
  final contents = sourceText.substring(1, sourceText.length - 1);
  final categories = _splitCommaSeparated(
    contents,
    source,
    line,
  ).map((value) => _decodeText(value, source, line)).toList(growable: false);
  if (categories.any((value) => value.isEmpty)) {
    throw FormatException(
      tr("x-axis categories cannot be empty"),
      source,
      line,
    );
  }
  return categories;
}

(String, String) _takeOptionalQuotedText(
  String value,
  String source,
  int line,
) {
  final trimmed = value.trimLeft();
  if (!trimmed.startsWith('"')) return ('', trimmed);
  var escaped = false;
  for (var i = 1; i < trimmed.length; i++) {
    final char = trimmed[i];
    if (escaped) {
      escaped = false;
    } else if (char == r'\') {
      escaped = true;
    } else if (char == '"') {
      final literal = trimmed.substring(0, i + 1);
      final decoded = _decodeText(literal, source, line);
      return (decoded, trimmed.substring(i + 1));
    }
  }
  throw FormatException(tr("Unclosed quoted text"), source, line);
}

String _decodeText(
  String value,
  String source,
  int line, {
  bool allowEmpty = false,
}) {
  final text = value.trim();
  if (text.isEmpty) {
    if (allowEmpty) return '';
    throw FormatException(tr("Expected non-empty text"), source, line);
  }
  if (text.startsWith('"')) {
    try {
      final decoded = jsonDecode(text);
      if (decoded is String) return decoded.trim();
    } on FormatException {
      // Report one stable parser error below.
    }
    throw FormatException(tr("Invalid quoted text"), source, line);
  }
  if (text.contains('"') || text.contains('[') || text.contains(']')) {
    throw FormatException(
      tr("Unsupported XY chart label syntax"),
      source,
      line,
    );
  }
  return text;
}

List<String> _splitCommaSeparated(String value, String source, int line) {
  final result = <String>[];
  var start = 0;
  var insideQuote = false;
  var escaped = false;
  for (var index = 0; index < value.length; index++) {
    final char = value[index];
    if (escaped) {
      escaped = false;
    } else if (insideQuote && char == r'\') {
      escaped = true;
    } else if (char == '"') {
      insideQuote = !insideQuote;
    } else if (char == ',' && !insideQuote) {
      result.add(value.substring(start, index));
      start = index + 1;
    }
  }
  if (insideQuote) {
    throw FormatException(tr("Unclosed quote in XY chart list"), source, line);
  }
  result.add(value.substring(start));
  return result;
}

double _parseFiniteNumber(String value, String source, int line) {
  final number = double.tryParse(value);
  if (number == null || !number.isFinite) {
    throw FormatException(
      tr("Expected a finite numeric value, found: {0}", [value]),
      source,
      line,
    );
  }
  return number;
}

String _stripInlineComment(String value) {
  var inQuote = false;
  var escaped = false;
  for (var index = 0; index < value.length - 1; index++) {
    final char = value[index];
    if (escaped) {
      escaped = false;
    } else if (inQuote && char == r'\') {
      escaped = true;
    } else if (char == '"') {
      inQuote = !inQuote;
    } else if (!inQuote && value.startsWith('%%', index)) {
      return value.substring(0, index);
    }
  }
  return value;
}

NativeMermaidXYChartConfig _parseInit(
  String line,
  NativeMermaidXYChartConfig current,
  String source,
  int lineNumber,
) {
  final colon = line.indexOf(':');
  final terminator = line.lastIndexOf('}%%');
  if (colon < 0 || terminator <= colon) {
    throw FormatException(
      tr("Invalid XY chart init directive"),
      source,
      lineNumber,
    );
  }
  final decoded = jsonDecode(line.substring(colon + 1, terminator).trim());
  if (decoded is! Map<String, dynamic>) {
    throw FormatException(
      tr("XY chart init directive must contain an object"),
      source,
      lineNumber,
    );
  }
  final xy = decoded['xyChart'];
  if (xy == null) return current;
  if (xy is! Map<String, dynamic>) {
    throw FormatException(
      tr("xyChart init configuration must be an object"),
      source,
      lineNumber,
    );
  }
  final xAxis = _parseAxisConfig(
    xy['xAxis'],
    current.xAxis,
    source,
    lineNumber,
  );
  final yAxis = _parseAxisConfig(
    xy['yAxis'],
    current.yAxis,
    source,
    lineNumber,
  );
  return NativeMermaidXYChartConfig(
    width: _configNumber(xy, 'width', current.width, source, lineNumber),
    height: _configNumber(xy, 'height', current.height, source, lineNumber),
    titleFontSize: _configNumber(
      xy,
      'titleFontSize',
      current.titleFontSize,
      source,
      lineNumber,
    ),
    titlePadding: _configNumber(
      xy,
      'titlePadding',
      current.titlePadding,
      source,
      lineNumber,
    ),
    showDataLabel: _configBool(
      xy,
      'showDataLabel',
      current.showDataLabel,
      source,
      lineNumber,
    ),
    showDataLabelOutsideBar: _configBool(
      xy,
      'showDataLabelOutsideBar',
      current.showDataLabelOutsideBar,
      source,
      lineNumber,
    ),
    showTitle: _configBool(
      xy,
      'showTitle',
      current.showTitle,
      source,
      lineNumber,
    ),
    showLegend: _configBool(
      xy,
      'showLegend',
      current.showLegend,
      source,
      lineNumber,
    ),
    legendFontSize: _configNumber(
      xy,
      'legendFontSize',
      current.legendFontSize,
      source,
      lineNumber,
    ),
    legendPadding: _configNumber(
      xy,
      'legendPadding',
      current.legendPadding,
      source,
      lineNumber,
    ),
    orientation: current.orientation,
    plotReservedSpacePercent: _configNumber(
      xy,
      'plotReservedSpacePercent',
      current.plotReservedSpacePercent,
      source,
      lineNumber,
    ),
    xAxis: xAxis,
    yAxis: yAxis,
  );
}

NativeMermaidXYChartAxisConfig _parseAxisConfig(
  Object? raw,
  NativeMermaidXYChartAxisConfig current,
  String source,
  int line,
) {
  if (raw == null) return current;
  if (raw is! Map<String, dynamic>) {
    throw FormatException(
      tr("XY chart axis config must be an object"),
      source,
      line,
    );
  }
  return NativeMermaidXYChartAxisConfig(
    showLabel: _configBool(raw, 'showLabel', current.showLabel, source, line),
    labelFontSize: _configNumber(
      raw,
      'labelFontSize',
      current.labelFontSize,
      source,
      line,
    ),
    labelPadding: _configNumber(
      raw,
      'labelPadding',
      current.labelPadding,
      source,
      line,
    ),
    showTitle: _configBool(raw, 'showTitle', current.showTitle, source, line),
    titleFontSize: _configNumber(
      raw,
      'titleFontSize',
      current.titleFontSize,
      source,
      line,
    ),
    titlePadding: _configNumber(
      raw,
      'titlePadding',
      current.titlePadding,
      source,
      line,
    ),
    showTick: _configBool(raw, 'showTick', current.showTick, source, line),
    tickLength: _configNumber(
      raw,
      'tickLength',
      current.tickLength,
      source,
      line,
    ),
    tickWidth: _configNumber(raw, 'tickWidth', current.tickWidth, source, line),
    showAxisLine: _configBool(
      raw,
      'showAxisLine',
      current.showAxisLine,
      source,
      line,
    ),
    axisLineWidth: _configNumber(
      raw,
      'axisLineWidth',
      current.axisLineWidth,
      source,
      line,
    ),
    labelRotation: _configNumber(
      raw,
      'labelRotation',
      current.labelRotation,
      source,
      line,
    ),
  );
}

double _configNumber(
  Map<String, dynamic> values,
  String key,
  double fallback,
  String source,
  int line,
) {
  final value = values[key];
  if (value == null) return fallback;
  if (value is! num || !value.toDouble().isFinite) {
    throw FormatException(
      tr("XY chart config {0} must be a finite number", [key]),
      source,
      line,
    );
  }
  return value.toDouble();
}

bool _configBool(
  Map<String, dynamic> values,
  String key,
  bool fallback,
  String source,
  int line,
) {
  final value = values[key];
  if (value == null) return fallback;
  if (value is! bool) {
    throw FormatException(
      tr("XY chart config {0} must be a boolean", [key]),
      source,
      line,
    );
  }
  return value;
}

NativeMermaidXYChartConfig _copyConfig(
  NativeMermaidXYChartConfig source, {
  required Axis orientation,
}) => NativeMermaidXYChartConfig(
  width: source.width,
  height: source.height,
  titleFontSize: source.titleFontSize,
  titlePadding: source.titlePadding,
  showDataLabel: source.showDataLabel,
  showDataLabelOutsideBar: source.showDataLabelOutsideBar,
  showTitle: source.showTitle,
  showLegend: source.showLegend,
  legendFontSize: source.legendFontSize,
  legendPadding: source.legendPadding,
  orientation: orientation,
  plotReservedSpacePercent: source.plotReservedSpacePercent,
  xAxis: source.xAxis,
  yAxis: source.yAxis,
);
