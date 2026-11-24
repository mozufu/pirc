import '../render_l10n.dart';
import 'dart:convert';

import 'radar_model.dart';

/// Parses the bounded static subset of Mermaid 11.17.2 `radar-beta`.
///
/// Unknown statements and configuration keys are rejected so the caller can
/// keep the Mermaid source visible instead of silently dropping chart data.
NativeMermaidRadarDiagram parseNativeMermaidRadar(String source) {
  if (source.length > 50000) {
    throw FormatException(tr("Radar diagram exceeds 50000 characters"));
  }
  final lines = source
      .replaceAll('\r\n', '\n')
      .replaceAll('\r', '\n')
      .split('\n');
  if (lines.length > 1200) {
    throw FormatException(tr("Radar diagram exceeds 1200 lines"));
  }

  var config = const NativeMermaidRadarConfig();
  var options = const NativeMermaidRadarOptions();
  final axes = <NativeMermaidRadarAxis>[];
  final curves = <NativeMermaidRadarCurve>[];
  final axisNames = <String>{};
  final curveNames = <String>{};
  var sawHeader = false;
  var title = '';
  var accessibleTitle = '';
  var accessibleDescription = '';
  var titleSeen = false;

  for (var index = 0; index < lines.length; index++) {
    final lineNumber = index + 1;
    final original = lines[index];
    final trimmed = original.trim();
    if (trimmed.isEmpty ||
        trimmed.startsWith('```') ||
        trimmed.startsWith('~~~')) {
      continue;
    }
    if (trimmed.startsWith('%%{')) {
      config = _parseRadarInit(trimmed, config, source, lineNumber);
      continue;
    }
    if (trimmed.startsWith('%%')) continue;

    final statement = _stripInlineComment(trimmed).trim();
    if (statement.isEmpty) continue;
    if (!sawHeader) {
      if (statement != 'radar-beta') {
        throw FormatException(
          tr("Expected radar-beta header, found: {0}", [statement]),
          source,
          lineNumber,
        );
      }
      sawHeader = true;
      continue;
    }

    final titleMatch = RegExp(
      r'^title\s+(.+)$',
      caseSensitive: false,
    ).firstMatch(statement);
    if (titleMatch != null) {
      if (titleSeen) {
        throw FormatException(tr("Duplicate radar title"), source, lineNumber);
      }
      titleSeen = true;
      title = _decodeRadarTitle(titleMatch[1]!, source, lineNumber);
      continue;
    }

    final accTitleMatch = RegExp(
      r'^accTitle\s*:\s*(.*)$',
      caseSensitive: false,
    ).firstMatch(statement);
    if (accTitleMatch != null) {
      accessibleTitle = _decodeOptionalText(
        accTitleMatch[1]!,
        source,
        lineNumber,
      );
      continue;
    }
    final accDescriptionMatch = RegExp(
      r'^accDescr\s*:\s*(.*)$',
      caseSensitive: false,
    ).firstMatch(statement);
    if (accDescriptionMatch != null) {
      accessibleDescription = _decodeOptionalText(
        accDescriptionMatch[1]!,
        source,
        lineNumber,
      );
      continue;
    }
    if (RegExp(
      r'^accDescr\s*\{\s*$',
      caseSensitive: false,
    ).hasMatch(statement)) {
      final body = <String>[];
      var closed = false;
      while (++index < lines.length) {
        final row = lines[index];
        final close = row.indexOf('}');
        if (close >= 0) {
          body.add(row.substring(0, close));
          if (_stripInlineComment(row.substring(close + 1)).trim().isNotEmpty) {
            throw FormatException(
              tr("Unexpected text after accDescr block"),
              source,
              index + 1,
            );
          }
          closed = true;
          break;
        }
        body.add(row);
      }
      if (!closed) {
        throw FormatException(
          tr("Unclosed accDescr block"),
          source,
          lineNumber,
        );
      }
      accessibleDescription = body.join('\n').trim();
      continue;
    }

    final axisMatch = RegExp(
      r'^axis\s+([A-Za-z0-9_](?:[A-Za-z0-9_-]*[A-Za-z0-9_])?)(?:\s*\[\s*(.+?)\s*\])?\s*$',
      caseSensitive: false,
    ).firstMatch(statement);
    if (axisMatch != null) {
      final name = axisMatch[1]!;
      if (axes.length >= 24) {
        throw FormatException(
          tr("Radar supports at most 24 axes"),
          source,
          lineNumber,
        );
      }
      if (!axisNames.add(name)) {
        throw FormatException(
          tr("Duplicate radar axis: {0}", [name]),
          source,
          lineNumber,
        );
      }
      final rawLabel = axisMatch[2];
      axes.add(
        NativeMermaidRadarAxis(
          name: name,
          label: rawLabel == null
              ? name
              : _decodeRadarLabel(rawLabel, source, lineNumber),
        ),
      );
      continue;
    }

    final curveMatch = RegExp(
      r'^curve\s+([A-Za-z0-9_](?:[A-Za-z0-9_-]*[A-Za-z0-9_])?)(?:\s*\[\s*(.+?)\s*\])?\s*\{(.*)\}\s*$',
      caseSensitive: false,
    ).firstMatch(statement);
    if (curveMatch != null) {
      final name = curveMatch[1]!;
      if (curves.length >= 12) {
        throw FormatException(
          tr("Radar supports at most 12 curves"),
          source,
          lineNumber,
        );
      }
      if (!curveNames.add(name)) {
        throw FormatException(
          tr("Duplicate radar curve: {0}", [name]),
          source,
          lineNumber,
        );
      }
      final label = curveMatch[2] == null
          ? name
          : _decodeRadarLabel(curveMatch[2]!, source, lineNumber);
      final entries = _parseCurveEntries(
        curveMatch[3]!,
        axes,
        source,
        lineNumber,
      );
      curves.add(
        NativeMermaidRadarCurve(name: name, label: label, entries: entries),
      );
      continue;
    }

    final showLegendMatch = RegExp(
      r'^showLegend\s+(true|false)\s*$',
      caseSensitive: false,
    ).firstMatch(statement);
    if (showLegendMatch != null) {
      options = _copyRadarOptions(
        options,
        showLegend: showLegendMatch[1]!.toLowerCase() == 'true',
      );
      continue;
    }

    final ticksMatch = RegExp(
      r'^ticks\s+(?:0|[1-9]\d*)\s*$',
      caseSensitive: false,
    ).firstMatch(statement);
    if (ticksMatch != null) {
      final rawTicks = int.parse(statement.split(RegExp(r'\s+')).last);
      if (rawTicks > 100000) {
        throw FormatException(
          tr("Radar ticks exceed the supported source bound"),
          source,
          lineNumber,
        );
      }
      // Mermaid 11.17.2 clamps requests above 32 ticks in its DB.
      options = _copyRadarOptions(
        options,
        ticks: rawTicks.clamp(0, 32).toInt(),
      );
      continue;
    }

    final maxMatch = RegExp(
      r'^max\s+(\d+(?:\.\d+)?)\s*$',
      caseSensitive: false,
    ).firstMatch(statement);
    if (maxMatch != null) {
      options = _copyRadarOptions(
        options,
        max: _parseRadarNumber(maxMatch[1]!, source, lineNumber),
        setMax: true,
      );
      continue;
    }
    final minMatch = RegExp(
      r'^min\s+(\d+(?:\.\d+)?)\s*$',
      caseSensitive: false,
    ).firstMatch(statement);
    if (minMatch != null) {
      options = _copyRadarOptions(
        options,
        min: _parseRadarNumber(minMatch[1]!, source, lineNumber),
      );
      continue;
    }
    final graticuleMatch = RegExp(
      r'^graticule\s+(circle|polygon)\s*$',
      caseSensitive: false,
    ).firstMatch(statement);
    if (graticuleMatch != null) {
      options = _copyRadarOptions(
        options,
        graticule: graticuleMatch[1]!.toLowerCase() == 'polygon'
            ? NativeMermaidRadarGraticule.polygon
            : NativeMermaidRadarGraticule.circle,
      );
      continue;
    }

    throw FormatException(
      tr("Unsupported or invalid native radar statement: {0}", [statement]),
      source,
      lineNumber,
    );
  }

  if (!sawHeader) throw FormatException(tr("Expected radar-beta header"));
  if (axes.length < 3) {
    throw FormatException(tr("Radar requires at least three axes"));
  }
  if (curves.isEmpty) {
    throw FormatException(tr("Radar requires at least one curve"));
  }
  final maximum =
      options.max ??
      curves.expand((curve) => curve.entries).reduce((a, b) => a > b ? a : b);
  if (!options.min.isFinite || !maximum.isFinite || maximum <= options.min) {
    throw FormatException(tr("Radar max must be greater than min"));
  }
  return NativeMermaidRadarDiagram(
    title: title,
    accessibleTitle: accessibleTitle,
    accessibleDescription: accessibleDescription,
    axes: axes,
    curves: curves,
    options: options,
    config: config,
  );
}

NativeMermaidRadarOptions _copyRadarOptions(
  NativeMermaidRadarOptions previous, {
  bool? showLegend,
  int? ticks,
  double? max,
  bool setMax = false,
  double? min,
  NativeMermaidRadarGraticule? graticule,
}) => NativeMermaidRadarOptions(
  showLegend: showLegend ?? previous.showLegend,
  ticks: ticks ?? previous.ticks,
  max: setMax ? max : previous.max,
  min: min ?? previous.min,
  graticule: graticule ?? previous.graticule,
);

List<double> _parseCurveEntries(
  String sourceText,
  List<NativeMermaidRadarAxis> axes,
  String source,
  int line,
) {
  if (axes.length < 3) {
    throw FormatException(
      tr("Declare at least three axes before curves"),
      source,
      line,
    );
  }
  final rawEntries = sourceText
      .split(',')
      .map((entry) => entry.trim())
      .toList();
  if (rawEntries.isEmpty ||
      rawEntries.length > 24 ||
      rawEntries.any((e) => e.isEmpty)) {
    throw FormatException(
      tr("Radar curve must contain 1 to 24 values"),
      source,
      line,
    );
  }
  final named = rawEntries.any((entry) => entry.contains(':'));
  if (named && rawEntries.any((entry) => !entry.contains(':'))) {
    throw FormatException(
      tr("Do not mix named and positional radar values"),
      source,
      line,
    );
  }
  if (!named) {
    if (rawEntries.length != axes.length) {
      throw FormatException(
        tr("Radar curve has {0} values for {1} axes", [
          rawEntries.length,
          axes.length,
        ]),
        source,
        line,
      );
    }
    return rawEntries
        .map((entry) => _parseRadarNumber(entry, source, line))
        .toList(growable: false);
  }

  final byAxis = <String, double>{};
  for (final entry in rawEntries) {
    final separator = entry.indexOf(':');
    if (separator <= 0 || separator == entry.length - 1) {
      throw FormatException(
        tr("Invalid named radar value: {0}", [entry]),
        source,
        line,
      );
    }
    final axisName = entry.substring(0, separator).trim();
    if (!RegExp(
      r'^[A-Za-z0-9_](?:[A-Za-z0-9_-]*[A-Za-z0-9_])?$',
    ).hasMatch(axisName)) {
      throw FormatException(
        tr("Invalid radar axis reference: {0}", [axisName]),
        source,
        line,
      );
    }
    if (!axes.any((axis) => axis.name == axisName)) {
      throw FormatException(
        tr("Unknown radar axis reference: {0}", [axisName]),
        source,
        line,
      );
    }
    if (byAxis.containsKey(axisName)) {
      throw FormatException(
        tr("Duplicate radar axis value: {0}", [axisName]),
        source,
        line,
      );
    }
    byAxis[axisName] = _parseRadarNumber(
      entry.substring(separator + 1).trim(),
      source,
      line,
    );
  }
  final missing = axes
      .map((axis) => axis.name)
      .where((name) => !byAxis.containsKey(name));
  if (missing.isNotEmpty) {
    throw FormatException(
      tr("Missing radar axis value: {0}", [missing.first]),
      source,
      line,
    );
  }
  if (byAxis.length != axes.length) {
    throw FormatException(
      tr("Radar curve values do not match its axes"),
      source,
      line,
    );
  }
  return axes.map((axis) => byAxis[axis.name]!).toList(growable: false);
}

double _parseRadarNumber(String raw, String source, int line) {
  final value = raw.trim();
  if (!RegExp(r'^(?:0|[1-9]\d*)(?:\.\d+)?$').hasMatch(value)) {
    throw FormatException(
      tr("Invalid non-negative radar number: {0}", [value]),
      source,
      line,
    );
  }
  final parsed = double.parse(value);
  if (!parsed.isFinite || parsed > 1000000000) {
    throw FormatException(
      tr("Radar number exceeds the supported source bound"),
      source,
      line,
    );
  }
  return parsed;
}

String _decodeRadarLabel(String raw, String source, int line) {
  final value = raw.trim();
  if (value.length < 2 ||
      !((value.startsWith('"') && value.endsWith('"')) ||
          (value.startsWith("'") && value.endsWith("'")))) {
    throw FormatException(
      tr("Radar labels must be quoted strings"),
      source,
      line,
    );
  }
  try {
    if (value.startsWith('"')) {
      final decoded = jsonDecode(value);
      if (decoded is String) return decoded;
    } else {
      final body = value.substring(1, value.length - 1);
      final out = StringBuffer();
      for (var i = 0; i < body.length; i++) {
        final char = body[i];
        if (char != r'\' || i + 1 >= body.length) {
          out.write(char);
          continue;
        }
        final escaped = body[++i];
        out.write(switch (escaped) {
          'n' => '\n',
          'r' => '\r',
          't' => '\t',
          'b' => '\b',
          'f' => '\f',
          _ => escaped,
        });
      }
      return out.toString();
    }
  } on FormatException {
    // Report the focused radar label error below.
  }
  throw FormatException(tr("Invalid radar label"), source, line);
}

String _decodeRadarTitle(String raw, String source, int line) {
  final value = raw.trim();
  if (value.isEmpty) {
    throw FormatException(tr("Radar title cannot be empty"), source, line);
  }
  if (value.startsWith('"') || value.startsWith("'")) {
    return _decodeRadarLabel(value, source, line);
  }
  return value;
}

String _decodeOptionalText(String raw, String source, int line) {
  final value = raw.trim();
  if (value.isEmpty) return '';
  if (value.startsWith('"') || value.startsWith("'")) {
    return _decodeRadarLabel(value, source, line);
  }
  return value;
}

String _stripInlineComment(String line) {
  var quote = '';
  var escaped = false;
  for (var i = 0; i + 1 < line.length; i++) {
    final char = line[i];
    if (escaped) {
      escaped = false;
      continue;
    }
    if (char == r'\' && quote.isNotEmpty) {
      escaped = true;
      continue;
    }
    if ((char == '"' || char == "'") && (quote.isEmpty || quote == char)) {
      quote = quote.isEmpty ? char : '';
      continue;
    }
    if (quote.isEmpty && line.startsWith('%%', i)) return line.substring(0, i);
  }
  return line;
}

NativeMermaidRadarConfig _parseRadarInit(
  String line,
  NativeMermaidRadarConfig previous,
  String source,
  int lineNumber,
) {
  final match = RegExp(r'^%%\{\s*init\s*:\s*(\{.*\})\s*\}%%$').firstMatch(line);
  if (match == null) {
    throw FormatException(
      tr("Unsupported native Mermaid radar directive"),
      source,
      lineNumber,
    );
  }
  dynamic decoded;
  try {
    decoded = jsonDecode(match[1]!);
  } on FormatException {
    throw FormatException(
      tr("Radar init directive must contain JSON"),
      source,
      lineNumber,
    );
  }
  if (decoded is! Map<String, dynamic> ||
      decoded.keys.any((key) => key != 'radar')) {
    throw FormatException(
      tr("Only radar init options are supported"),
      source,
      lineNumber,
    );
  }
  final raw = decoded['radar'];
  if (raw is! Map<String, dynamic>) {
    throw FormatException(
      tr("radar init options must be an object"),
      source,
      lineNumber,
    );
  }
  const supported = <String>{
    'width',
    'height',
    'marginTop',
    'marginRight',
    'marginBottom',
    'marginLeft',
    'axisScaleFactor',
    'axisLabelFactor',
    'curveTension',
    'useMaxWidth',
  };
  final unknown = raw.keys.where((key) => !supported.contains(key)).toList();
  if (unknown.isNotEmpty) {
    throw FormatException(
      tr("Unsupported radar init option: {0}", [unknown.first]),
      source,
      lineNumber,
    );
  }

  double number(String key, double fallback, {bool positive = false}) {
    final value = raw[key];
    if (value == null) return fallback;
    if (value is! num ||
        !value.isFinite ||
        value < 0 ||
        (positive && value == 0) ||
        value > 10000) {
      throw FormatException(
        tr("{0} must be a finite supported number", [key]),
        source,
        lineNumber,
      );
    }
    return value.toDouble();
  }

  final useMaxWidth = raw['useMaxWidth'];
  if (useMaxWidth != null && useMaxWidth is! bool) {
    throw FormatException(
      tr("useMaxWidth must be a boolean"),
      source,
      lineNumber,
    );
  }
  return NativeMermaidRadarConfig(
    width: number('width', previous.width, positive: true),
    height: number('height', previous.height, positive: true),
    marginTop: number('marginTop', previous.marginTop),
    marginRight: number('marginRight', previous.marginRight),
    marginBottom: number('marginBottom', previous.marginBottom),
    marginLeft: number('marginLeft', previous.marginLeft),
    axisScaleFactor: number('axisScaleFactor', previous.axisScaleFactor),
    axisLabelFactor: number('axisLabelFactor', previous.axisLabelFactor),
    curveTension: number('curveTension', previous.curveTension),
    useMaxWidth: useMaxWidth as bool? ?? previous.useMaxWidth,
  );
}
