import '../render_l10n.dart';
import 'dart:convert';

import 'quadrant_model.dart';

/// Parses the useful static subset of Mermaid 11.17.2's `quadrantChart`
/// grammar. Unknown directives and statements fail loudly so callers can
/// retain the source instead of displaying a chart with missing content.
NativeMermaidQuadrantDiagram parseNativeMermaidQuadrant(String source) {
  final lines = source
      .replaceAll('\r\n', '\n')
      .replaceAll('\r', '\n')
      .split('\n');
  final quadrants = List<String>.filled(4, '');
  final points = <NativeMermaidQuadrantPoint>[];
  final classes = <String, NativeMermaidQuadrantStyle>{};
  var config = const NativeMermaidQuadrantConfig();
  var title = '';
  var accessibleTitle = '';
  var accessibleDescription = '';
  var sawHeader = false;
  var xAxisLeft = '';
  var xAxisRight = '';
  var yAxisBottom = '';
  var yAxisTop = '';

  for (var i = 0; i < lines.length; i++) {
    final original = lines[i];
    final line = original.trim();
    if (line.isEmpty || line.startsWith('```')) continue;
    if (line.startsWith('%%{')) {
      config = _parseInitDirective(line, config, i + 1);
      continue;
    }
    if (line.startsWith('%%')) continue;

    final clean = _withoutInlineComment(line).trim();
    if (clean.isEmpty) continue;
    if (!sawHeader) {
      if (clean != 'quadrantChart') {
        throw FormatException(
          tr("Expected quadrantChart header, found: {0}", [clean]),
          source,
          i + 1,
        );
      }
      sawHeader = true;
      continue;
    }

    if (clean == 'quadrantChart') {
      throw FormatException(
        tr("Unexpected second quadrantChart header"),
        source,
        i + 1,
      );
    }

    final titleMatch = RegExp(
      r'^title\s+(.+)$',
      caseSensitive: false,
    ).firstMatch(clean);
    if (titleMatch != null) {
      title = _decodeText(titleMatch[1]!, line: i + 1);
      continue;
    }
    final accessibleTitleMatch = RegExp(
      r'^accTitle\s*:\s*(.*)$',
      caseSensitive: false,
    ).firstMatch(clean);
    if (accessibleTitleMatch != null) {
      accessibleTitle = _decodeText(accessibleTitleMatch[1]!, line: i + 1);
      continue;
    }
    final accessibleDescriptionMatch = RegExp(
      r'^accDescr\s*:\s*(.*)$',
      caseSensitive: false,
    ).firstMatch(clean);
    if (accessibleDescriptionMatch != null) {
      accessibleDescription = _decodeText(
        accessibleDescriptionMatch[1]!,
        line: i + 1,
      );
      continue;
    }
    if (RegExp(r'^accDescr\s*\{\s*$', caseSensitive: false).hasMatch(clean)) {
      final body = <String>[];
      var closed = false;
      while (++i < lines.length) {
        final row = lines[i];
        final close = row.indexOf('}');
        if (close >= 0) {
          body.add(row.substring(0, close));
          final trailing = _withoutInlineComment(
            row.substring(close + 1),
          ).trim();
          if (trailing.isNotEmpty) {
            throw FormatException(
              tr("Unexpected text after accDescr block"),
              source,
              i + 1,
            );
          }
          closed = true;
          break;
        }
        body.add(row);
      }
      if (!closed) {
        throw FormatException(tr("Unclosed accDescr block"), source, i + 1);
      }
      accessibleDescription = body
          .join('\n')
          .trim()
          .replaceAll(RegExp(r'\n\s+'), '\n');
      continue;
    }

    final axis = RegExp(
      r'^(x-axis|y-axis)\s+(.+)$',
      caseSensitive: false,
    ).firstMatch(clean);
    if (axis != null) {
      final pair = _splitAxisLabels(axis[2]!, line: i + 1);
      if (axis[1]!.toLowerCase() == 'x-axis') {
        xAxisLeft = pair.$1;
        xAxisRight = pair.$2;
      } else {
        yAxisBottom = pair.$1;
        yAxisTop = pair.$2;
      }
      continue;
    }

    final quadrant = RegExp(
      r'^quadrant-([1-4])\s*(.*)$',
      caseSensitive: false,
    ).firstMatch(clean);
    if (quadrant != null) {
      quadrants[int.parse(quadrant[1]!) - 1] = _decodeText(
        quadrant[2]!,
        line: i + 1,
        allowEmpty: true,
      );
      continue;
    }

    final classDef = RegExp(
      r'^classDef\s+([\w-]+)\s+(.+)$',
      caseSensitive: false,
    ).firstMatch(clean);
    if (classDef != null) {
      classes[classDef[1]!] = _parseStyles(classDef[2]!, line: i + 1);
      continue;
    }
    if (RegExp(r'^classDef\b', caseSensitive: false).hasMatch(clean)) {
      throw FormatException(
        tr("classDef needs a class name and supported styles"),
        source,
        i + 1,
      );
    }

    if (clean.contains(':') && clean.contains('[')) {
      points.add(_parsePoint(clean, lineNumber: i + 1));
      continue;
    }

    throw FormatException(
      tr("Unsupported or invalid native quadrant statement: {0}", [clean]),
      source,
      i + 1,
    );
  }

  if (!sawHeader) throw FormatException(tr("Expected quadrantChart header"));
  return NativeMermaidQuadrantDiagram(
    title: title.isEmpty ? null : title,
    xAxisLeftText: xAxisLeft,
    xAxisRightText: xAxisRight,
    yAxisBottomText: yAxisBottom,
    yAxisTopText: yAxisTop,
    quadrants: quadrants,
    points: points,
    classes: classes,
    config: config,
    accessibleTitle: accessibleTitle,
    accessibleDescription: accessibleDescription,
  );
}

String _withoutInlineComment(String line) {
  var quoted = false;
  var escaped = false;
  for (var i = 0; i < line.length - 1; i++) {
    final char = line[i];
    if (escaped) {
      escaped = false;
      continue;
    }
    if (char == r'\' && quoted) {
      escaped = true;
      continue;
    }
    if (char == '"') quoted = !quoted;
    if (!quoted && line.startsWith('%%', i)) return line.substring(0, i);
  }
  return line;
}

String _decodeText(String text, {required int line, bool allowEmpty = false}) {
  final value = text.trim();
  if (value.isEmpty) {
    if (allowEmpty) return '';
    throw FormatException(tr("Expected non-empty label text"), null, line);
  }
  if (value.startsWith('"')) {
    try {
      final decoded = jsonDecode(value);
      if (decoded is String) return decoded;
    } on FormatException {
      // Give the caller the same focused parser error used for unsupported
      // Mermaid labels below.
    }
    throw FormatException(tr("Invalid quoted label text"), value, line);
  }
  if (value.contains('"') || value.contains('[') || value.contains(']')) {
    throw FormatException(tr("Unsupported label syntax"), value, line);
  }
  return value;
}

(String, String) _splitAxisLabels(String value, {required int line}) {
  final separator = RegExp(r'\s*--+>\s*').firstMatch(value);
  if (separator == null) return (_decodeText(value, line: line), '');
  final left = value.substring(0, separator.start).trim();
  final right = value.substring(separator.end).trim();
  if (left.isEmpty) {
    throw FormatException('An axis label is required before -->', value, line);
  }
  if (right.isEmpty) return ('${_decodeText(left, line: line)} ⟶ ', '');
  return (_decodeText(left, line: line), _decodeText(right, line: line));
}

NativeMermaidQuadrantPoint _parsePoint(String line, {required int lineNumber}) {
  final coordinate = RegExp(
    r':\s*\[\s*([^,\]]+)\s*,\s*([^\]]+)\s*\]\s*(.*)$',
  ).firstMatch(line);
  if (coordinate == null) {
    throw FormatException(
      tr("Invalid quadrant point; expected Label: [x, y]"),
      line,
      lineNumber,
    );
  }
  final prefix = line.substring(0, coordinate.start).trim();
  var labelSource = prefix;
  String? className;
  final classMatch = RegExp(r'^(.*):::\s*([\w-]+)$').firstMatch(prefix);
  if (classMatch != null) {
    labelSource = classMatch[1]!.trim();
    className = classMatch[2];
  }
  final label = _decodeText(labelSource, line: lineNumber);

  final x = _parseCoordinate(coordinate[1]!, line: lineNumber);
  final y = _parseCoordinate(coordinate[2]!, line: lineNumber);
  return NativeMermaidQuadrantPoint(
    label: label,
    x: x,
    y: y,
    className: className,
    style: coordinate[3]!.trim().isEmpty
        ? const NativeMermaidQuadrantStyle()
        : _parseStyles(coordinate[3]!, line: lineNumber),
  );
}

double _parseCoordinate(String source, {required int line}) {
  final value = source.trim();
  if (!RegExp(r'^(?:0(?:\.\d+)?|1)$').hasMatch(value)) {
    // Mermaid's pinned lexer only has tokens for `1` and `0` optionally
    // followed by a decimal fraction. Keep out-of-range values an explicit
    // lexer-style failure rather than silently clamping them.
    throw FormatException(
      tr("Lexical error on line {0}. Unrecognized text.", [line]),
      value,
      line,
    );
  }
  return double.parse(value);
}

NativeMermaidQuadrantStyle _parseStyles(String source, {required int line}) {
  int? radius;
  String? color;
  String? strokeColor;
  String? strokeWidth;
  for (final item in source.split(',')) {
    final split = item.indexOf(':');
    if (split <= 0 || split == item.length - 1) {
      throw FormatException(
        tr("Invalid quadrant point style: {0}", [item]),
        source,
        line,
      );
    }
    final key = item.substring(0, split).trim();
    final value = item.substring(split + 1).trim();
    switch (key) {
      case 'radius':
        if (!RegExp(r'^\d+$').hasMatch(value)) {
          throw FormatException(
            'radius style must be a non-negative integer',
            source,
            line,
          );
        }
        radius = int.parse(value);
      case 'color':
        _validateHexColor(value, key: key, line: line);
        color = value;
      case 'stroke-color':
        _validateHexColor(value, key: key, line: line);
        strokeColor = value;
      case 'stroke-width':
        if (!RegExp(r'^\d+px$').hasMatch(value)) {
          throw FormatException(
            'stroke-width style must be integer px, for example 2px',
            source,
            line,
          );
        }
        strokeWidth = value;
      default:
        throw FormatException(
          tr("Unsupported quadrant style property: {0}", [key]),
          source,
          line,
        );
    }
  }
  return NativeMermaidQuadrantStyle(
    radius: radius,
    color: color,
    strokeColor: strokeColor,
    strokeWidth: strokeWidth,
  );
}

void _validateHexColor(String value, {required String key, required int line}) {
  final hex = value.startsWith('#') ? value.substring(1) : value;
  if (!RegExp(r'^(?:[0-9a-fA-F]{3}|[0-9a-fA-F]{6})$').hasMatch(hex)) {
    throw FormatException(
      tr("{0} style must be a 3- or 6-digit hex color", [key]),
      value,
      line,
    );
  }
}

NativeMermaidQuadrantConfig _parseInitDirective(
  String line,
  NativeMermaidQuadrantConfig previous,
  int lineNumber,
) {
  final match = RegExp(r'^%%\{\s*init\s*:\s*(\{.*\})\s*\}%%$').firstMatch(line);
  if (match == null) {
    throw FormatException(
      tr("Unsupported native Mermaid directive"),
      line,
      lineNumber,
    );
  }
  dynamic decoded;
  try {
    decoded = jsonDecode(match[1]!);
  } on FormatException {
    throw FormatException(
      tr("Quadrant init directive must contain JSON"),
      line,
      lineNumber,
    );
  }
  if (decoded is! Map<String, dynamic> ||
      decoded.keys.any((key) => key != 'quadrantChart')) {
    throw FormatException(
      tr("Only quadrantChart init options are supported"),
      line,
      lineNumber,
    );
  }
  final raw = decoded['quadrantChart'];
  if (raw is! Map<String, dynamic>) {
    throw FormatException(
      tr("quadrantChart init options must be an object"),
      line,
      lineNumber,
    );
  }
  const supported = <String>{
    'chartWidth',
    'chartHeight',
    'titlePadding',
    'titleFontSize',
    'quadrantPadding',
    'xAxisLabelPadding',
    'yAxisLabelPadding',
    'xAxisLabelFontSize',
    'yAxisLabelFontSize',
    'quadrantLabelFontSize',
    'quadrantTextTopPadding',
    'pointTextPadding',
    'pointLabelFontSize',
    'pointRadius',
    'xAxisPosition',
    'yAxisPosition',
    'quadrantInternalBorderStrokeWidth',
    'quadrantExternalBorderStrokeWidth',
    'showXAxis',
    'showYAxis',
    'showTitle',
  };
  final unsupported = raw.keys
      .where((key) => !supported.contains(key))
      .toList();
  if (unsupported.isNotEmpty) {
    throw FormatException(
      tr("Unsupported quadrantChart option: {0}", [unsupported.first]),
      line,
      lineNumber,
    );
  }

  double number(String key, double fallback) {
    final value = raw[key];
    if (value == null) return fallback;
    if (value is! num || !value.isFinite || value < 0) {
      throw FormatException(
        tr("{0} must be a finite non-negative number", [key]),
        line,
        lineNumber,
      );
    }
    return value.toDouble();
  }

  String position(String key, String fallback, Set<String> allowed) {
    final value = raw[key];
    if (value == null) return fallback;
    if (value is! String || !allowed.contains(value)) {
      throw FormatException(
        tr("{0} has an unsupported value", [key]),
        line,
        lineNumber,
      );
    }
    return value;
  }

  bool boolean(String key, bool fallback) {
    final value = raw[key];
    if (value == null) return fallback;
    if (value is! bool) {
      throw FormatException(
        tr("{0} must be a boolean", [key]),
        line,
        lineNumber,
      );
    }
    return value;
  }

  return NativeMermaidQuadrantConfig(
    chartWidth: number('chartWidth', previous.chartWidth),
    chartHeight: number('chartHeight', previous.chartHeight),
    titlePadding: number('titlePadding', previous.titlePadding),
    titleFontSize: number('titleFontSize', previous.titleFontSize),
    quadrantPadding: number('quadrantPadding', previous.quadrantPadding),
    xAxisLabelPadding: number('xAxisLabelPadding', previous.xAxisLabelPadding),
    yAxisLabelPadding: number('yAxisLabelPadding', previous.yAxisLabelPadding),
    xAxisLabelFontSize: number(
      'xAxisLabelFontSize',
      previous.xAxisLabelFontSize,
    ),
    yAxisLabelFontSize: number(
      'yAxisLabelFontSize',
      previous.yAxisLabelFontSize,
    ),
    quadrantLabelFontSize: number(
      'quadrantLabelFontSize',
      previous.quadrantLabelFontSize,
    ),
    quadrantTextTopPadding: number(
      'quadrantTextTopPadding',
      previous.quadrantTextTopPadding,
    ),
    pointTextPadding: number('pointTextPadding', previous.pointTextPadding),
    pointLabelFontSize: number(
      'pointLabelFontSize',
      previous.pointLabelFontSize,
    ),
    pointRadius: number('pointRadius', previous.pointRadius),
    xAxisPosition: position('xAxisPosition', previous.xAxisPosition, const {
      'top',
      'bottom',
    }),
    yAxisPosition: position('yAxisPosition', previous.yAxisPosition, const {
      'left',
      'right',
    }),
    quadrantInternalBorderStrokeWidth: number(
      'quadrantInternalBorderStrokeWidth',
      previous.quadrantInternalBorderStrokeWidth,
    ),
    quadrantExternalBorderStrokeWidth: number(
      'quadrantExternalBorderStrokeWidth',
      previous.quadrantExternalBorderStrokeWidth,
    ),
    showXAxis: boolean('showXAxis', previous.showXAxis),
    showYAxis: boolean('showYAxis', previous.showYAxis),
    showTitle: boolean('showTitle', previous.showTitle),
  );
}
