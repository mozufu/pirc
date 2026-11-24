import 'render_l10n.dart';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_math_fork/tex.dart' as math_tex;

/// Parses one CSS linear, radial or conic background gradient into a Flutter [Gradient].
///
/// Returns null when [value] is not a gradient function. Recognized gradient
/// syntax outside the supported subset throws [FormatException], so callers can
/// report that a background was not rendered instead of silently substituting
/// a different image. The returned gradient computes its geometry from the
/// paint rectangle supplied by Flutter, matching CSS's background positioning
/// area rather than assuming a fixed size at parse time.
Gradient? parseNativeHtmlBackgroundGradient(String value) {
  final input = value.trim();
  if (input.isEmpty) return null;

  final layers = _splitTopLevel(input, ',');
  final hasGradient = layers.any(_startsWithGradientFunction);
  if (!hasGradient) return null;
  if (layers.length != 1) {
    throw FormatException(
      tr(
        "Multiple background image layers containing gradients are unsupported.",
      ),
      value,
    );
  }

  final match = RegExp(
    r'^([a-z-]+)\s*\(',
    caseSensitive: false,
  ).firstMatch(input);
  if (match == null) {
    throw FormatException(tr("Malformed CSS gradient function."), value);
  }
  final name = match.group(1)!.toLowerCase();
  final repeating = name.startsWith('repeating-');
  final kind = repeating ? name.substring(10) : name;
  if (!const {
    'linear-gradient',
    'radial-gradient',
    'conic-gradient',
  }.contains(kind)) {
    throw FormatException(
      tr("Unsupported CSS gradient function: {0}.", [name]),
      value,
    );
  }

  final body = _extractFunctionBody(input, match.end - 1, value);
  final arguments = _splitTopLevel(body, ',');
  if (arguments.length < 2 ||
      arguments.any((argument) => argument.trim().isEmpty)) {
    throw FormatException(
      tr("A CSS gradient needs at least two color stops."),
      value,
    );
  }
  return switch (kind) {
    'linear-gradient' => _parseLinearGradient(
      arguments,
      value,
      repeating: repeating,
    ),
    'radial-gradient' => _parseRadialGradient(
      arguments,
      value,
      repeating: repeating,
    ),
    _ => _parseConicGradient(arguments, value, repeating: repeating),
  };
}

/// Recognizes the supported gradient function names before full validation.
bool isNativeHtmlBackgroundGradient(String value) =>
    _startsWithGradientFunction(value);

bool _startsWithGradientFunction(String value) => RegExp(
  r'^(?:repeating-)?(?:linear|radial|conic)-gradient\s*\(',
  caseSensitive: false,
).hasMatch(value.trim());

String _extractFunctionBody(
  String source,
  int openIndex,
  Object sourceForError,
) {
  var depth = 0;
  String? quote;
  var escaped = false;
  for (var i = openIndex; i < source.length; i++) {
    final character = source[i];
    if (quote != null) {
      if (escaped) {
        escaped = false;
      } else if (character == r'\') {
        escaped = true;
      } else if (character == quote) {
        quote = null;
      }
      continue;
    }
    if (character == '"' || character == "'") {
      quote = character;
    } else if (character == '(') {
      depth++;
    } else if (character == ')') {
      depth--;
      if (depth == 0) {
        if (source.substring(i + 1).trim().isNotEmpty) {
          throw FormatException(
            tr("Unexpected content after CSS gradient."),
            sourceForError,
          );
        }
        return source.substring(openIndex + 1, i);
      }
      if (depth < 0) break;
    }
  }
  throw FormatException(tr("Unclosed CSS gradient function."), sourceForError);
}

Gradient _parseLinearGradient(
  List<String> arguments,
  String source, {
  bool repeating = false,
}) {
  var firstStopIndex = 0;
  var direction = const _LinearDirection.angle(math.pi);
  final initial = arguments.first.trim();
  final header = _takeInterpolationMethod(initial, source);
  final parsedDirection = _parseLinearDirection(header);
  if (parsedDirection != null) {
    direction = parsedDirection;
    firstStopIndex = 1;
  } else if (RegExp(
    r'(?:^|\s)in\s+srgb\s*$',
    caseSensitive: false,
  ).hasMatch(initial)) {
    // `in srgb` without an explicit direction uses the CSS default direction.
    firstStopIndex = 1;
  }
  final stops = _parseColorStops(arguments.skip(firstStopIndex), source);
  if (stops.length < 2) {
    throw FormatException(
      tr("A CSS linear gradient needs at least two color stops."),
      source,
    );
  }
  return NativeHtmlLinearGradient._(direction, stops, repeating: repeating);
}

String _takeInterpolationMethod(String value, Object source) {
  final match = RegExp(
    r'(?:^|\s+)in\s+([a-z0-9-]+)\s*$',
    caseSensitive: false,
  ).firstMatch(value);
  if (match == null) return value;
  final method = match.group(1)!.toLowerCase();
  if (method != 'srgb') {
    throw FormatException(
      tr("Only the CSS sRGB gradient interpolation method is supported."),
      source,
    );
  }
  return value.substring(0, match.start).trim();
}

_LinearDirection? _parseLinearDirection(String value) {
  final input = value.trim().toLowerCase();
  if (input.startsWith('to ')) {
    final directions = input.substring(3).trim().split(RegExp(r'\s+'));
    if (directions.isEmpty || directions.length > 2) return null;
    var x = 0;
    var y = 0;
    for (final direction in directions) {
      switch (direction) {
        case 'left':
          if (x != 0) return null;
          x = -1;
        case 'right':
          if (x != 0) return null;
          x = 1;
        case 'top':
          if (y != 0) return null;
          y = -1;
        case 'bottom':
          if (y != 0) return null;
          y = 1;
        default:
          return null;
      }
    }
    if (x == 0 && y == 0) return null;
    if (x == 0) return _LinearDirection.angle(y < 0 ? 0 : math.pi);
    if (y == 0) {
      return _LinearDirection.angle(x > 0 ? math.pi / 2 : 3 * math.pi / 2);
    }
    return _LinearDirection.corner(x, y);
  }
  final match = RegExp(
    r'^([+-]?(?:\d+(?:\.\d*)?|\.\d+))(deg|grad|rad|turn)?$',
  ).firstMatch(input);
  if (match == null) return null;
  final number = double.parse(match.group(1)!);
  if (!number.isFinite) return null;
  final unit = match.group(2);
  if (unit == null && number != 0) return null;
  final radians = switch (unit) {
    'deg' => number * math.pi / 180,
    'grad' => number * math.pi / 200,
    'turn' => number * math.pi * 2,
    'rad' => number,
    _ => 0.0,
  };
  return _LinearDirection.angle(radians % (2 * math.pi));
}

Gradient _parseRadialGradient(
  List<String> arguments,
  String source, {
  bool repeating = false,
}) {
  var firstStopIndex = 0;
  var shape = NativeHtmlRadialShape.ellipse;
  var sizing = NativeHtmlRadialSizing.farthestCorner;
  _RadialPosition position = const _RadialPosition.center();
  List<_RadialRadius>? explicitRadii;

  final initial = arguments.first.trim();
  final header = _takeInterpolationMethod(initial, source);
  if (_looksLikeRadialHeader(header) ||
      RegExp(
        r'(?:^|\s)in\s+srgb\s*$',
        caseSensitive: false,
      ).hasMatch(initial)) {
    firstStopIndex = 1;
    final atMatches = RegExp(
      r'\bat\b',
      caseSensitive: false,
    ).allMatches(header);
    if (atMatches.length > 1) {
      throw FormatException(
        tr("A radial gradient can have only one position clause."),
        source,
      );
    }
    var sizeText = header;
    if (atMatches.isNotEmpty) {
      final at = atMatches.single;
      sizeText = header.substring(0, at.start).trim();
      final positionText = header.substring(at.end).trim();
      if (positionText.isEmpty) {
        throw FormatException(
          tr("A radial gradient position cannot be empty."),
          source,
        );
      }
      position = _parseRadialPosition(positionText, source);
    }

    final tokens = _splitWhitespaceTopLevel(sizeText);
    final dimensions = <_RadialRadius>[];
    var sawKeywordSize = false;
    var shapeDeclared = false;
    for (final token in tokens) {
      switch (token.toLowerCase()) {
        case 'circle':
          if (shapeDeclared) {
            throw FormatException('Duplicate radial gradient shape.', source);
          }
          shape = NativeHtmlRadialShape.circle;
          shapeDeclared = true;
        case 'ellipse':
          if (shapeDeclared) {
            throw FormatException('Duplicate radial gradient shape.', source);
          }
          shape = NativeHtmlRadialShape.ellipse;
          shapeDeclared = true;
        case 'closest-side':
          if (sawKeywordSize) {
            throw FormatException('Duplicate radial gradient size.', source);
          }
          sizing = NativeHtmlRadialSizing.closestSide;
          sawKeywordSize = true;
        case 'farthest-side':
          if (sawKeywordSize) {
            throw FormatException('Duplicate radial gradient size.', source);
          }
          sizing = NativeHtmlRadialSizing.farthestSide;
          sawKeywordSize = true;
        case 'closest-corner':
          if (sawKeywordSize) {
            throw FormatException('Duplicate radial gradient size.', source);
          }
          sizing = NativeHtmlRadialSizing.closestCorner;
          sawKeywordSize = true;
        case 'farthest-corner':
          if (sawKeywordSize) {
            throw FormatException('Duplicate radial gradient size.', source);
          }
          sizing = NativeHtmlRadialSizing.farthestCorner;
          sawKeywordSize = true;
        default:
          final radius = _parseRadialRadius(token);
          if (radius == null) {
            throw FormatException(
              tr("Unsupported radial gradient size: {0}.", [token]),
              source,
            );
          }
          dimensions.add(radius);
      }
    }
    if (sawKeywordSize && dimensions.isNotEmpty) {
      throw FormatException(
        tr("A radial gradient cannot combine a size keyword and radii."),
        source,
      );
    }
    if (sawKeywordSize) {
      // A keyword is valid for either circle or ellipse.
    } else if (dimensions.isNotEmpty) {
      if (dimensions.length == 1 && !shapeDeclared) {
        shape = NativeHtmlRadialShape.circle;
      }
      if (shape == NativeHtmlRadialShape.circle) {
        if (dimensions.length != 1 || dimensions.single.isPercent) {
          throw FormatException(
            tr("A circle radius must be one nonnegative length."),
            source,
          );
        }
        sizing = NativeHtmlRadialSizing.explicitCircle;
        explicitRadii = dimensions;
      } else if (shape == NativeHtmlRadialShape.ellipse) {
        if (dimensions.length != 2) {
          throw FormatException(
            tr("An ellipse needs two explicit radii."),
            source,
          );
        }
        sizing = NativeHtmlRadialSizing.explicitEllipse;
        explicitRadii = dimensions;
      }
    }
  }

  final stops = _parseColorStops(arguments.skip(firstStopIndex), source);
  if (stops.length < 2) {
    throw FormatException(
      tr("A CSS radial gradient needs at least two color stops."),
      source,
    );
  }
  return NativeHtmlRadialGradient._(
    shape,
    sizing,
    explicitRadii,
    position,
    stops,
    repeating: repeating,
  );
}

Gradient _parseConicGradient(
  List<String> arguments,
  String source, {
  bool repeating = false,
}) {
  var firstStop = 0;
  var angle = 0.0;
  var position = const _RadialPosition.center();
  final initial = arguments.first.trim();
  final header = _takeInterpolationMethod(initial, source);
  if (header.toLowerCase().startsWith('from ') ||
      header.toLowerCase().startsWith('at ') ||
      header.isEmpty) {
    firstStop = 1;
    final match = RegExp(
      r'^(?:from\s+(\S+))?(?:\s*at\s+(.+))?$',
      caseSensitive: false,
    ).firstMatch(header);
    if (match == null) {
      throw FormatException(tr("Unsupported conic gradient header."), source);
    }
    if (match[1] != null) {
      final parsed = _parseStopPosition(match[1]!, angular: true);
      if (parsed == null || match[1]!.endsWith('%')) {
        throw FormatException(tr("Conic from needs an angle."), source);
      }
      angle = parsed.amount / 100 * math.pi * 2;
    }
    if (match[2] != null) position = _parseRadialPosition(match[2]!, source);
  }
  final stops = _parseColorStops(
    arguments.skip(firstStop),
    source,
    angular: true,
  );
  if (stops.length < 2) {
    throw FormatException(tr("A conic gradient needs two stops."), source);
  }
  return NativeHtmlConicGradient._(
    angle,
    position,
    stops,
    repeating: repeating,
  );
}

bool _looksLikeRadialHeader(String value) {
  final input = value.trim().toLowerCase();
  if (input.isEmpty) return false;
  if (RegExp(r'(?:^|\s)in\s+srgb\s*$', caseSensitive: false).hasMatch(input)) {
    return true;
  }
  return RegExp(
    r'\b(?:at|circle|ellipse|closest-side|farthest-side|closest-corner|farthest-corner)\b',
  ).hasMatch(input);
}

_RadialRadius? _parseRadialRadius(String value) {
  final input = value.trim().toLowerCase();
  final match = RegExp(
    r'^([+-]?(?:\d+(?:\.\d*)?|\.\d+))(px|%)$',
  ).firstMatch(input);
  if (match == null) return null;
  final amount = double.parse(match.group(1)!);
  if (!amount.isFinite || amount < 0) return null;
  return _RadialRadius(amount, match.group(2) == '%');
}

_RadialPosition _parseRadialPosition(String value, Object source) {
  final tokens = _splitWhitespaceTopLevel(value);
  if (tokens.isEmpty || tokens.length > 2) {
    throw FormatException(
      tr("Only one- and two-value radial positions are supported."),
      source,
    );
  }
  if (tokens.length == 1) {
    final token = tokens.single.toLowerCase();
    if (token == 'center') return const _RadialPosition.center();
    if (token == 'left' ||
        token == 'right' ||
        _parsePositionLength(token) != null) {
      return _RadialPosition(x: token, y: 'center');
    }
    if (token == 'top' || token == 'bottom') {
      return _RadialPosition(x: 'center', y: token);
    }
    throw FormatException(
      tr("Unsupported radial gradient position: {0}.", [value]),
      source,
    );
  }

  var x = tokens[0].toLowerCase();
  var y = tokens[1].toLowerCase();
  if (_isVerticalKeyword(x) && _isHorizontalKeyword(y)) {
    final oldX = x;
    x = y;
    y = oldX;
  }
  if (!_isHorizontalPosition(x) || !_isVerticalPosition(y)) {
    throw FormatException(
      tr("Unsupported radial gradient position: {0}.", [value]),
      source,
    );
  }
  return _RadialPosition(x: x, y: y);
}

bool _isHorizontalPosition(String value) =>
    value == 'left' ||
    value == 'right' ||
    value == 'center' ||
    _parsePositionLength(value) != null;

bool _isVerticalPosition(String value) =>
    value == 'top' ||
    value == 'bottom' ||
    value == 'center' ||
    _parsePositionLength(value) != null;

bool _isHorizontalKeyword(String value) => value == 'left' || value == 'right';

bool _isVerticalKeyword(String value) => value == 'top' || value == 'bottom';

_PositionLength? _parsePositionLength(String value) {
  final match = RegExp(
    r'^([+-]?(?:\d+(?:\.\d*)?|\.\d+))(px|%)$',
  ).firstMatch(value);
  if (match == null) return null;
  final amount = double.parse(match.group(1)!);
  if (!amount.isFinite) return null;
  return _PositionLength(amount, match.group(2) == '%');
}

List<_GradientColorStop> _parseColorStops(
  Iterable<String> sourceStops,
  Object source, {
  bool angular = false,
}) {
  final stops = <_GradientColorStop>[];
  for (final sourceStop in sourceStops) {
    final tokens = _splitWhitespaceTopLevel(sourceStop.trim());
    if (tokens.isEmpty) {
      throw FormatException(tr("Empty CSS gradient color stop."), source);
    }
    final color = _parseCssColor(tokens.first);
    if (color == null) {
      throw FormatException(
        tr("Unsupported gradient color: {0}.", [tokens.first]),
        source,
      );
    }
    final positions = tokens.skip(1).toList();
    if (positions.length > 2) {
      throw FormatException(
        tr("A color stop can have at most two positions."),
        source,
      );
    }
    if (positions.isEmpty) {
      stops.add(_GradientColorStop(color, null));
      continue;
    }
    for (final position in positions) {
      final parsed = _parseStopPosition(position, angular: angular);
      if (parsed == null) {
        throw FormatException(
          tr("Unsupported color stop position: {0}.", [position]),
          source,
        );
      }
      stops.add(_GradientColorStop(color, parsed));
    }
  }
  return List.unmodifiable(stops);
}

_StopPosition? _parseStopPosition(String value, {bool angular = false}) {
  final input = value.trim().toLowerCase();
  if (angular && !input.endsWith('%')) {
    if (RegExp(
      r'^(?:[+-]?0(?:\.0*)?|[+-]?(?:\d+(?:\.\d*)?|\.\d+)(?:deg|grad|rad|turn))$',
    ).hasMatch(input)) {
      final degrees = _parseHue(input);
      if (degrees != null) {
        return _StopPosition(degrees / 3.6, _StopUnit.percent);
      }
    }
    return null;
  }
  final match = RegExp(
    r'^([+-]?(?:\d+(?:\.\d*)?|\.\d+))(px|%)$',
  ).firstMatch(input);
  if (match != null) {
    final amount = double.parse(match.group(1)!);
    if (!amount.isFinite) return null;
    return _StopPosition(
      amount,
      match.group(2) == 'px' ? _StopUnit.pixels : _StopUnit.percent,
    );
  }
  if (input == '0' || input == '+0' || input == '-0') {
    return const _StopPosition(0, _StopUnit.percent);
  }
  return null;
}

/// Common CSS color parsing shared by backgrounds and native Canvas painting.
Color? parseNativeCssColor(String value) => _parseCssColor(value);

Color? _parseCssColor(String value) {
  final input = value.trim().toLowerCase();
  if (input == 'transparent') return const Color(0x00000000);
  final named = math_tex.colorByName[input];
  if (named != null) return named;

  if (input.startsWith('#')) {
    final hex = input.substring(1);
    if (!RegExp(
      r'^(?:[0-9a-f]{3}|[0-9a-f]{4}|[0-9a-f]{6}|[0-9a-f]{8})$',
    ).hasMatch(hex)) {
      return null;
    }
    final expanded = hex.length <= 4
        ? hex.split('').map((digit) => '$digit$digit').join()
        : hex;
    if (expanded.length == 6) {
      return Color(0xff000000 | int.parse(expanded, radix: 16));
    }
    final red = int.parse(expanded.substring(0, 2), radix: 16);
    final green = int.parse(expanded.substring(2, 4), radix: 16);
    final blue = int.parse(expanded.substring(4, 6), radix: 16);
    final alpha = int.parse(expanded.substring(6, 8), radix: 16);
    return Color.fromARGB(alpha, red, green, blue);
  }

  final rgb = RegExp(r'^(rgb|rgba)\((.*)\)$').firstMatch(input);
  if (rgb != null) return _parseRgb(rgb.group(2)!);
  final hsl = RegExp(r'^(hsl|hsla)\((.*)\)$').firstMatch(input);
  if (hsl != null) return _parseHsl(hsl.group(2)!);
  return null;
}

Color? _parseRgb(String body) {
  final slashParts = body.split('/');
  if (slashParts.length > 2) return null;
  final channels = slashParts.first.contains(',')
      ? slashParts.first.split(',').map((part) => part.trim()).toList()
      : slashParts.first.trim().split(RegExp(r'\s+'));
  String? alphaText = slashParts.length == 2 ? slashParts.last.trim() : null;
  if (channels.length == 4 && alphaText == null) {
    alphaText = channels.removeLast();
  }
  if (channels.length != 3 ||
      (slashParts.length == 2 && channels.length == 4)) {
    return null;
  }
  final red = _parseRgbComponent(channels[0]);
  final green = _parseRgbComponent(channels[1]);
  final blue = _parseRgbComponent(channels[2]);
  final alpha = alphaText == null ? 1.0 : _parseAlphaComponent(alphaText);
  if (red == null || green == null || blue == null || alpha == null) {
    return null;
  }
  return Color.from(
    alpha: alpha,
    red: red / 255,
    green: green / 255,
    blue: blue / 255,
    colorSpace: ui.ColorSpace.sRGB,
  );
}

double? _parseRgbComponent(String input) {
  final match = RegExp(
    r'^([+-]?(?:\d+(?:\.\d*)?|\.\d+))(%?)$',
  ).firstMatch(input);
  if (match == null) return null;
  final number = double.parse(match.group(1)!);
  if (!number.isFinite) return null;
  return match.group(2) == '%'
      ? (number * 2.55).clamp(0, 255)
      : number.clamp(0, 255);
}

double? _parseAlphaComponent(String input) {
  final match = RegExp(
    r'^([+-]?(?:\d+(?:\.\d*)?|\.\d+))(%?)$',
  ).firstMatch(input);
  if (match == null) return null;
  final number = double.parse(match.group(1)!);
  if (!number.isFinite) return null;
  return (match.group(2) == '%' ? number / 100 : number).clamp(0, 1);
}

Color? _parseHsl(String body) {
  final slashParts = body.split('/');
  if (slashParts.length > 2) return null;
  final channels = slashParts.first.contains(',')
      ? slashParts.first.split(',').map((part) => part.trim()).toList()
      : slashParts.first.trim().split(RegExp(r'\s+'));
  String? alphaText = slashParts.length == 2 ? slashParts.last.trim() : null;
  if (channels.length == 4 && alphaText == null) {
    alphaText = channels.removeLast();
  }
  if (channels.length != 3) return null;
  final hue = _parseHue(channels[0]);
  final saturation = _parsePercent(channels[1]);
  final lightness = _parsePercent(channels[2]);
  final alpha = alphaText == null ? 1.0 : _parseAlphaComponent(alphaText);
  if (hue == null || saturation == null || lightness == null || alpha == null) {
    return null;
  }
  final h = (hue % 360) / 360;
  final s = saturation / 100;
  final l = lightness / 100;
  final chroma = (1 - (2 * l - 1).abs()) * s;
  final x = chroma * (1 - ((h * 6) % 2 - 1).abs());
  final m = l - chroma / 2;
  final components = switch ((h * 6).floor()) {
    0 => (chroma, x, 0.0),
    1 => (x, chroma, 0.0),
    2 => (0.0, chroma, x),
    3 => (0.0, x, chroma),
    4 => (x, 0.0, chroma),
    _ => (chroma, 0.0, x),
  };
  return Color.from(
    alpha: alpha,
    red: components.$1 + m,
    green: components.$2 + m,
    blue: components.$3 + m,
    colorSpace: ui.ColorSpace.sRGB,
  );
}

double? _parseHue(String input) {
  final match = RegExp(
    r'^([+-]?(?:\d+(?:\.\d*)?|\.\d+))(deg|grad|rad|turn)?$',
  ).firstMatch(input);
  if (match == null) return null;
  final number = double.parse(match.group(1)!);
  if (!number.isFinite) return null;
  return switch (match.group(2)) {
    'grad' => number * 0.9,
    'rad' => number * 180 / math.pi,
    'turn' => number * 360,
    _ => number,
  };
}

double? _parsePercent(String input) {
  final match = RegExp(r'^([+-]?(?:\d+(?:\.\d*)?|\.\d+))%$').firstMatch(input);
  if (match == null) return null;
  final number = double.parse(match.group(1)!);
  return number.isFinite ? number.clamp(0, 100) : null;
}

List<String> _splitTopLevel(String input, String delimiter) {
  final pieces = <String>[];
  var start = 0;
  var depth = 0;
  String? quote;
  var escaped = false;
  for (var i = 0; i < input.length; i++) {
    final character = input[i];
    if (quote != null) {
      if (escaped) {
        escaped = false;
      } else if (character == r'\') {
        escaped = true;
      } else if (character == quote) {
        quote = null;
      }
      continue;
    }
    if (character == '"' || character == "'") {
      quote = character;
    } else if (character == '(') {
      depth++;
    } else if (character == ')') {
      depth--;
      if (depth < 0) {
        throw FormatException(tr("Unbalanced CSS function."), input);
      }
    } else if (character == delimiter && depth == 0) {
      pieces.add(input.substring(start, i).trim());
      start = i + 1;
    }
  }
  if (depth != 0 || quote != null) {
    throw FormatException(tr("Unbalanced CSS value."), input);
  }
  pieces.add(input.substring(start).trim());
  return pieces;
}

List<String> _splitWhitespaceTopLevel(String input) {
  final pieces = <String>[];
  var start = -1;
  var depth = 0;
  String? quote;
  var escaped = false;
  for (var i = 0; i < input.length; i++) {
    final character = input[i];
    if (quote != null) {
      if (escaped) {
        escaped = false;
      } else if (character == r'\') {
        escaped = true;
      } else if (character == quote) {
        quote = null;
      }
      continue;
    }
    if (character == '"' || character == "'") {
      quote = character;
      if (start < 0) start = i;
    } else if (character == '(') {
      depth++;
      if (start < 0) start = i;
    } else if (character == ')') {
      depth--;
    } else if (character.trim().isEmpty && depth == 0) {
      if (start >= 0) {
        pieces.add(input.substring(start, i));
        start = -1;
      }
    } else if (start < 0) {
      start = i;
    }
  }
  if (start >= 0) pieces.add(input.substring(start));
  return pieces;
}

class NativeHtmlLinearGradient extends Gradient {
  NativeHtmlLinearGradient._(
    this._direction,
    List<_GradientColorStop> stops, {
    this.repeating = false,
  }) : _colorStops = List.unmodifiable(stops),
       super(colors: List.unmodifiable(stops.map((stop) => stop.color)));

  /// CSS angle measured clockwise from upward for a square reference box.
  ///
  /// Corner directions vary with the actual box ratio; use
  /// [angleRadiansFor] when measuring those directions.
  double get angleRadians => angleRadiansFor(const Rect.fromLTWH(0, 0, 1, 1));

  double angleRadiansFor(Rect rect) => _direction.resolve(rect);

  final _LinearDirection _direction;
  final bool repeating;
  final List<_GradientColorStop> _colorStops;

  /// Returns CSS gradient-line endpoints for a given paint rectangle.
  NativeHtmlGradientLine lineFor(Rect rect) {
    final radians = _direction.resolve(rect);
    final axis = Offset(math.sin(radians), -math.cos(radians));
    final length = rect.width * axis.dx.abs() + rect.height * axis.dy.abs();
    final half = axis * (length / 2);
    return NativeHtmlGradientLine(
      rect.center - half,
      rect.center + half,
      length,
    );
  }

  /// Resolves percentage and pixel stops against the CSS gradient line length.
  List<double> resolveStopsFor(Rect rect) => _resolveStops(
    _colorStops,
    lineFor(rect).length,
    clip: !repeating,
  ).positions;

  @override
  Shader createShader(Rect rect, {TextDirection? textDirection}) {
    final line = lineFor(rect);
    final resolved = _resolveStops(_colorStops, line.length, clip: !repeating);
    if (!repeating) {
      final shaderStops = _samplePremultipliedStopCurves(resolved);
      return ui.Gradient.linear(
        line.start,
        line.end,
        shaderStops.colors,
        shaderStops.positions,
      );
    }
    final first = resolved.positions.first,
        period = resolved.positions.last - first;
    if (period <= 0) return _solidGradientShader(resolved.colors.last);
    final shaderStops = _samplePremultipliedStopCurves(
      _normalizedPeriod(resolved),
    );
    final axis = line.end - line.start;
    return ui.Gradient.linear(
      line.start + axis * first,
      line.start + axis * (first + period),
      shaderStops.colors,
      shaderStops.positions,
      ui.TileMode.repeated,
    );
  }

  @override
  Gradient scale(double factor) => NativeHtmlLinearGradient._(
    _direction,
    _withOpacity(_colorStops, factor),
    repeating: repeating,
  );

  @override
  Gradient withOpacity(double opacity) => NativeHtmlLinearGradient._(
    _direction,
    _withOpacity(_colorStops, opacity),
    repeating: repeating,
  );
}

class NativeHtmlRadialGradient extends Gradient {
  NativeHtmlRadialGradient._(
    this.shape,
    this.sizing,
    this._explicitRadii,
    this._position,
    List<_GradientColorStop> stops, {
    this.repeating = false,
  }) : _colorStops = List.unmodifiable(stops),
       super(colors: List.unmodifiable(stops.map((stop) => stop.color)));

  final NativeHtmlRadialShape shape;
  final bool repeating;
  final NativeHtmlRadialSizing sizing;
  final List<_RadialRadius>? _explicitRadii;
  final _RadialPosition _position;
  final List<_GradientColorStop> _colorStops;

  /// Resolves the center and radii for the given CSS background box.
  NativeHtmlRadialGeometry geometryFor(Rect rect) {
    final center = _position.resolve(rect);
    final xNear = math.min(center.dx - rect.left, rect.right - center.dx);
    final xFar = math.max(center.dx - rect.left, rect.right - center.dx);
    final yNear = math.min(center.dy - rect.top, rect.bottom - center.dy);
    final yFar = math.max(center.dy - rect.top, rect.bottom - center.dy);
    final corners = <Offset>[
      Offset(rect.left, rect.top),
      Offset(rect.right, rect.top),
      Offset(rect.left, rect.bottom),
      Offset(rect.right, rect.bottom),
    ];
    final distances = corners
        .map((corner) => (corner - center).distance)
        .toList();

    double rx;
    double ry;
    if (_explicitRadii != null) {
      rx = _explicitRadii[0].resolve(rect.width, rect.shortestSide);
      if (shape == NativeHtmlRadialShape.circle) {
        ry = rx;
      } else {
        ry = _explicitRadii[1].resolve(rect.height, rect.shortestSide);
      }
    } else if (shape == NativeHtmlRadialShape.circle) {
      final radius = switch (sizing) {
        NativeHtmlRadialSizing.closestSide => math.min(
          math.min(xNear, xFar),
          math.min(yNear, yFar),
        ),
        NativeHtmlRadialSizing.farthestSide => math.max(
          math.max(xNear, xFar),
          math.max(yNear, yFar),
        ),
        NativeHtmlRadialSizing.closestCorner => distances.reduce(math.min),
        NativeHtmlRadialSizing.farthestCorner => distances.reduce(math.max),
        _ => math.max(xFar, yFar),
      };
      rx = radius;
      ry = radius;
    } else {
      switch (sizing) {
        case NativeHtmlRadialSizing.closestSide:
          rx = xNear;
          ry = yNear;
        case NativeHtmlRadialSizing.farthestSide:
          rx = xFar;
          ry = yFar;
        case NativeHtmlRadialSizing.closestCorner:
          var scale = double.infinity;
          for (final corner in corners) {
            final dx = (corner.dx - center.dx).abs();
            final dy = (corner.dy - center.dy).abs();
            final normalizedX = xNear == 0
                ? (dx == 0 ? 0.0 : double.infinity)
                : dx / xNear;
            final normalizedY = yNear == 0
                ? (dy == 0 ? 0.0 : double.infinity)
                : dy / yNear;
            scale = math.min(
              scale,
              math.sqrt(normalizedX * normalizedX + normalizedY * normalizedY),
            );
          }
          rx = xNear * scale;
          ry = yNear * scale;
        case NativeHtmlRadialSizing.farthestCorner:
          var scale = 0.0;
          for (final corner in corners) {
            final dx = (corner.dx - center.dx).abs();
            final dy = (corner.dy - center.dy).abs();
            final normalizedX = xFar == 0
                ? (dx == 0 ? 0.0 : double.infinity)
                : dx / xFar;
            final normalizedY = yFar == 0
                ? (dy == 0 ? 0.0 : double.infinity)
                : dy / yFar;
            scale = math.max(
              scale,
              math.sqrt(normalizedX * normalizedX + normalizedY * normalizedY),
            );
          }
          rx = xFar * scale;
          ry = yFar * scale;
        case NativeHtmlRadialSizing.explicitEllipse:
        case NativeHtmlRadialSizing.explicitCircle:
          rx = xFar;
          ry = yFar;
      }
    }
    if (!rx.isFinite || !ry.isFinite || rx < 0 || ry < 0) {
      throw FormatException(
        tr("Invalid radial gradient geometry for {0}.", [rect]),
      );
    }
    return NativeHtmlRadialGeometry(center, rx, ry);
  }

  /// CSS radial length stops are measured on the horizontal gradient ray.
  List<double> resolveStopsFor(Rect rect) => _resolveStops(
    _colorStops,
    geometryFor(rect).radiusX,
    clip: !repeating,
  ).positions;

  @override
  Shader createShader(Rect rect, {TextDirection? textDirection}) {
    final geometry = geometryFor(rect);
    final resolved = _resolveStops(
      _colorStops,
      geometry.radiusX,
      clip: !repeating,
    );
    if (repeating) {
      final period = resolved.positions.last - resolved.positions.first;
      if (period <= 0) return _solidGradientShader(resolved.colors.last);
      final phase = resolved.positions.first % period;
      final sampled = _samplePremultipliedStopCurves(
        _normalizedPeriod(resolved),
      );
      // The native two-circle shader maps (radius - phase) / period.
      // A nonzero local center avoids the native conical shader's zero-center
      // assertion; the matrix keeps the actual CSS center and elliptical radii.
      final matrix = Float64List(16)
        ..[0] = math.max(geometry.radiusX, .0001)
        ..[5] = math.max(geometry.radiusY, .0001)
        ..[10] = 1
        ..[12] = geometry.center.dx - math.max(geometry.radiusX, .0001)
        ..[13] = geometry.center.dy - math.max(geometry.radiusY, .0001)
        ..[15] = 1;
      return ui.Gradient.radial(
        const Offset(1, 1),
        phase + period,
        sampled.colors,
        sampled.positions,
        ui.TileMode.repeated,
        matrix,
        const Offset(1, 1),
        phase,
      );
    }
    final shaderStops = _samplePremultipliedStopCurves(resolved);
    if ((geometry.radiusX - geometry.radiusY).abs() < 0.0001) {
      return ui.Gradient.radial(
        geometry.center,
        math.max(geometry.radiusX, 0.0001),
        shaderStops.colors,
        shaderStops.positions,
        ui.TileMode.clamp,
      );
    }

    // A local matrix maps the unit circle into CSS's actual elliptical ending
    // shape while keeping the center attached to the background box.
    final matrix = Float64List(16)
      ..[0] = geometry.radiusX
      ..[5] = geometry.radiusY
      ..[10] = 1
      ..[12] = geometry.center.dx
      ..[13] = geometry.center.dy
      ..[15] = 1;
    return ui.Gradient.radial(
      Offset.zero,
      1,
      shaderStops.colors,
      shaderStops.positions,
      ui.TileMode.clamp,
      matrix,
    );
  }

  @override
  Gradient scale(double factor) => NativeHtmlRadialGradient._(
    shape,
    sizing,
    _explicitRadii,
    _position,
    _withOpacity(_colorStops, factor),
    repeating: repeating,
  );

  @override
  Gradient withOpacity(double opacity) => NativeHtmlRadialGradient._(
    shape,
    sizing,
    _explicitRadii,
    _position,
    _withOpacity(_colorStops, opacity),
    repeating: repeating,
  );
}

class NativeHtmlConicGradient extends Gradient {
  NativeHtmlConicGradient._(
    this.angleRadians,
    this._position,
    List<_GradientColorStop> stops, {
    this.repeating = false,
  }) : _colorStops = List.unmodifiable(stops),
       super(colors: List.unmodifiable(stops.map((stop) => stop.color)));
  final double angleRadians;
  final bool repeating;
  final _RadialPosition _position;
  final List<_GradientColorStop> _colorStops;
  Offset centerFor(Rect rect) => _position.resolve(rect);
  List<double> resolveStopsFor(Rect rect) =>
      _resolveStops(_colorStops, 1, clip: !repeating).positions;
  @override
  Shader createShader(Rect rect, {TextDirection? textDirection}) {
    final center = centerFor(rect);
    final resolved = _resolveStops(_colorStops, 1, clip: !repeating);
    var begin = 0.0, end = 1.0;
    var stops = resolved;
    if (repeating) {
      final period = resolved.positions.last - resolved.positions.first;
      if (period <= 0) return _solidGradientShader(resolved.colors.last);
      begin = resolved.positions.first % period;
      end = begin + period;
      stops = _normalizedPeriod(resolved);
    }
    final sampled = _samplePremultipliedStopCurves(stops);
    final rotation = angleRadians - math.pi / 2;
    final matrix = Float64List(16)
      ..[0] = math.cos(rotation)
      ..[1] = math.sin(rotation)
      ..[4] = -math.sin(rotation)
      ..[5] = math.cos(rotation)
      ..[10] = 1
      ..[12] = center.dx
      ..[13] = center.dy
      ..[15] = 1;
    return ui.Gradient.sweep(
      Offset.zero,
      sampled.colors,
      sampled.positions,
      repeating ? ui.TileMode.repeated : ui.TileMode.clamp,
      begin * math.pi * 2,
      end * math.pi * 2,
      matrix,
    );
  }

  @override
  Gradient scale(double factor) => NativeHtmlConicGradient._(
    angleRadians,
    _position,
    _withOpacity(_colorStops, factor),
    repeating: repeating,
  );
  @override
  Gradient withOpacity(double opacity) => NativeHtmlConicGradient._(
    angleRadians,
    _position,
    _withOpacity(_colorStops, opacity),
    repeating: repeating,
  );
}

Shader _solidGradientShader(Color color) =>
    ui.Gradient.linear(Offset.zero, const Offset(1, 0), [color, color]);
_ResolvedColorStops _normalizedPeriod(_ResolvedColorStops resolved) {
  final first = resolved.positions.first,
      period = resolved.positions.last - first;
  return _ResolvedColorStops(
    resolved.colors,
    resolved.positions.map((p) => (p - first) / period).toList(),
  );
}

@immutable
class NativeHtmlGradientLine {
  const NativeHtmlGradientLine(this.start, this.end, this.length);

  final Offset start;
  final Offset end;
  final double length;
}

@immutable
class NativeHtmlRadialGeometry {
  const NativeHtmlRadialGeometry(this.center, this.radiusX, this.radiusY);

  final Offset center;
  final double radiusX;
  final double radiusY;
}

List<_GradientColorStop> _withOpacity(
  List<_GradientColorStop> stops,
  double factor,
) => stops
    .map(
      (stop) => _GradientColorStop(
        stop.color.withValues(alpha: (stop.color.a * factor).clamp(0, 1)),
        stop.position,
      ),
    )
    .toList(growable: false);

_ResolvedColorStops _resolveStops(
  List<_GradientColorStop> rawStops,
  double lineLength, {
  bool clip = true,
}) {
  final length = math.max(lineLength, 0.0001);
  final positions = rawStops.map((stop) {
    final position = stop.position;
    if (position == null) return null;
    return position.unit == _StopUnit.pixels
        ? position.amount / length
        : position.amount / 100;
  }).toList();
  positions[0] ??= 0;
  positions[positions.length - 1] ??= 1;

  var priorSpecified = positions[0]!;
  for (var i = 1; i < positions.length; i++) {
    final current = positions[i];
    if (current == null) continue;
    if (current < priorSpecified) positions[i] = priorSpecified;
    priorSpecified = positions[i]!;
  }
  var previous = 0;
  while (previous < positions.length - 1) {
    var next = previous + 1;
    while (next < positions.length && positions[next] == null) {
      next++;
    }
    if (next >= positions.length) break;
    final start = positions[previous]!;
    final end = positions[next]!;
    final steps = next - previous;
    for (var index = previous + 1; index < next; index++) {
      positions[index] = start + (end - start) * (index - previous) / steps;
    }
    previous = next;
  }
  for (var i = 1; i < positions.length; i++) {
    if (positions[i]! < positions[i - 1]!) positions[i] = positions[i - 1];
  }

  final resolvedPositions = positions.cast<double>();
  final resolvedColors = rawStops.map((stop) => stop.color).toList();
  final resolved = _ResolvedColorStops(resolvedColors, resolvedPositions);
  return clip ? _clipResolvedStops(resolved) : resolved;
}

_ResolvedColorStops _clipResolvedStops(_ResolvedColorStops resolved) {
  final resolvedPositions = resolved.positions,
      resolvedColors = resolved.colors;
  final first = resolvedPositions.first;
  final last = resolvedPositions.last;
  if (last < 0) {
    final color = resolvedColors.last;
    return _ResolvedColorStops([color, color], const [0, 1]);
  }
  if (first > 1) {
    final color = resolvedColors.first;
    return _ResolvedColorStops([color, color], const [0, 1]);
  }
  if (first >= 0 && last <= 1) {
    return _ResolvedColorStops(resolvedColors, resolvedPositions);
  }

  final clippedColors = <Color>[];
  final clippedPositions = <double>[];
  if (first < 0) {
    clippedColors.add(
      _samplePremultiplied(resolvedColors, resolvedPositions, 0),
    );
    clippedPositions.add(0);
  }
  for (var i = 0; i < resolvedPositions.length; i++) {
    final stop = resolvedPositions[i];
    if (stop >= 0 && stop <= 1) {
      clippedColors.add(resolvedColors[i]);
      clippedPositions.add(stop);
    }
  }
  if (last > 1) {
    clippedColors.add(
      _samplePremultiplied(resolvedColors, resolvedPositions, 1),
    );
    clippedPositions.add(1);
  }
  if (clippedColors.isEmpty) {
    final color = first < 0
        ? _samplePremultiplied(resolvedColors, resolvedPositions, 0)
        : _samplePremultiplied(resolvedColors, resolvedPositions, 1);
    return _ResolvedColorStops([color, color], const [0, 1]);
  }
  if (clippedColors.length == 1) {
    return _ResolvedColorStops(
      [clippedColors.single, clippedColors.single],
      const [0, 1],
    );
  }
  return _ResolvedColorStops(clippedColors, clippedPositions);
}

// Flutter's native gradient interpolation mixes unpremultiplied RGB channels.
// CSS gradients interpolate premultiplied colors, which is visible at edges
// such as transparent red fading into opaque blue. Subdivide only segments
// whose alpha changes, sampling the CSS curve into a compact shader stop list.
_ResolvedColorStops _samplePremultipliedStopCurves(_ResolvedColorStops input) {
  if (input.colors.length < 2) return input;
  final colors = <Color>[input.colors.first];
  final positions = <double>[input.positions.first];
  const subdivisions = 64;

  for (var index = 0; index < input.colors.length - 1; index++) {
    final startColor = input.colors[index];
    final endColor = input.colors[index + 1];
    final startPosition = input.positions[index];
    final endPosition = input.positions[index + 1];
    if (endPosition > startPosition &&
        (startColor.a - endColor.a).abs() > 0.000001) {
      for (var step = 1; step < subdivisions; step++) {
        final t = step / subdivisions;
        colors.add(_interpolatePremultiplied(startColor, endColor, t));
        positions.add(startPosition + (endPosition - startPosition) * t);
      }
    }
    colors.add(endColor);
    positions.add(endPosition);
  }
  return _ResolvedColorStops(colors, positions);
}

Color _interpolatePremultiplied(Color first, Color second, double t) {
  final alpha = first.a + (second.a - first.a) * t;
  if (alpha <= 0) return const Color(0x00000000);
  double channel(double a, double b) =>
      (a * first.a + (b * second.a - a * first.a) * t) / alpha;
  return Color.from(
    alpha: alpha,
    red: channel(first.r, second.r).clamp(0, 1),
    green: channel(first.g, second.g).clamp(0, 1),
    blue: channel(first.b, second.b).clamp(0, 1),
    colorSpace: ui.ColorSpace.sRGB,
  );
}

Color _samplePremultiplied(
  List<Color> colors,
  List<double> stops,
  double position,
) {
  if (position <= stops.first) return colors.first;
  if (position >= stops.last) return colors.last;
  var index = 0;
  for (var i = 0; i < stops.length; i++) {
    if (stops[i] <= position) index = i;
  }
  final start = stops[index];
  final end = stops[index + 1];
  if (end <= start) return colors[index + 1];
  final t = (position - start) / (end - start);
  final a = colors[index];
  final b = colors[index + 1];
  final alpha = a.a + (b.a - a.a) * t;
  if (alpha <= 0) return const Color(0x00000000);
  double channel(double x, double y) =>
      (x * a.a + (y * b.a - x * a.a) * t) / alpha;
  return Color.from(
    alpha: alpha,
    red: channel(a.r, b.r),
    green: channel(a.g, b.g),
    blue: channel(a.b, b.b),
    colorSpace: ui.ColorSpace.sRGB,
  );
}

class _GradientColorStop {
  const _GradientColorStop(this.color, this.position);

  final Color color;
  final _StopPosition? position;
}

class _LinearDirection {
  const _LinearDirection.angle(this.fixedAngle) : cornerX = 0, cornerY = 0;
  const _LinearDirection.corner(this.cornerX, this.cornerY) : fixedAngle = null;

  final double? fixedAngle;
  final int cornerX;
  final int cornerY;

  double resolve(Rect rect) {
    final fixed = fixedAngle;
    if (fixed != null) return fixed;
    final cornerAngle = math.atan2(rect.height, rect.width);
    if (cornerX > 0 && cornerY < 0) return cornerAngle;
    if (cornerX > 0 && cornerY > 0) return math.pi - cornerAngle;
    if (cornerX < 0 && cornerY > 0) return math.pi + cornerAngle;
    return 2 * math.pi - cornerAngle;
  }
}

class _ResolvedColorStops {
  const _ResolvedColorStops(this.colors, this.positions);

  final List<Color> colors;
  final List<double> positions;
}

class _StopPosition {
  const _StopPosition(this.amount, this.unit);

  final double amount;
  final _StopUnit unit;
}

enum _StopUnit { percent, pixels }

enum NativeHtmlRadialShape { circle, ellipse }

enum NativeHtmlRadialSizing {
  closestSide,
  farthestSide,
  closestCorner,
  farthestCorner,
  explicitCircle,
  explicitEllipse,
}

class _RadialRadius {
  const _RadialRadius(this.amount, this.isPercent);

  final double amount;
  final bool isPercent;

  double resolve(double dimension, double shortestSide) =>
      isPercent ? amount * dimension / 100 : amount;
}

class _PositionLength {
  const _PositionLength(this.amount, this.isPercent);

  final double amount;
  final bool isPercent;

  double resolve(double dimension) =>
      isPercent ? amount * dimension / 100 : amount;
}

class _RadialPosition {
  const _RadialPosition({required this.x, required this.y});
  const _RadialPosition.center() : x = 'center', y = 'center';

  final String x;
  final String y;

  Offset resolve(Rect rect) => Offset(
    _axisPosition(x, rect.left, rect.width, 'left', 'right'),
    _axisPosition(y, rect.top, rect.height, 'top', 'bottom'),
  );

  double _axisPosition(
    String value,
    double start,
    double extent,
    String low,
    String high,
  ) {
    if (value == low) return start;
    if (value == high) return start + extent;
    if (value == 'center') return start + extent / 2;
    final parsed = _parsePositionLength(value);
    if (parsed == null) {
      throw FormatException(tr("Unsupported radial position: {0}.", [value]));
    }
    return start + parsed.resolve(extent);
  }
}
