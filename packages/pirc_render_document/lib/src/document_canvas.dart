import 'package:pirc_render/src/render_l10n.dart';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:pirc_render/src/document_canvas_layout.dart';
import 'package:pirc_render/src/html_background_gradient.dart'
    show parseNativeCssColor;
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

/// A validated, immutable snapshot of a Canvas 2D document surface.
///
/// The JavaScript recorder sends drawing commands rather than a bitmap. This
/// decoder deliberately rejects commands and styles outside the native painter
/// subset so callers can report the limitation instead of showing a partial or
/// misleading rendering.
@immutable
class NativeDocumentCanvasSnapshot implements RenderCanvasSnapshot {
  const NativeDocumentCanvasSnapshot._({
    required this.id,
    required this.width,
    required this.height,
    required this.revision,
    required this.commands,
  });

  static const int maxDimension = NativeCanvasLimits.maxDimension;
  static const int maxPixels = NativeCanvasLimits.maxPixels;
  static const int maxCommands = 5000;
  static const int maxPathSegmentsPerPath = 5000;
  static const int maxPathSegments = 100000;

  final String id;
  @override
  final double width;
  @override
  final double height;
  final int revision;
  final List<NativeDocumentCanvasCommand> commands;

  factory NativeDocumentCanvasSnapshot.fromJson(Map<String, Object?> json) {
    final decoder = _NativeCanvasDecoder();
    final id = _readString(json['id'], 'snapshot.id');
    if (id.isEmpty) {
      throw const NativeDocumentCanvasException(
        'invalid-snapshot',
        'Canvas snapshot id cannot be empty.',
      );
    }
    final width = _readNumber(json['width'], 'snapshot.width');
    final height = _readNumber(json['height'], 'snapshot.height');
    if (width < 0 ||
        height < 0 ||
        width > maxDimension ||
        height > maxDimension ||
        width * height > maxPixels) {
      throw NativeDocumentCanvasException(
        'canvas-size-limit',
        'Canvas size ${width}x$height exceeds the native surface limit.',
      );
    }
    final revisionNumber = json['revision'];
    if (revisionNumber is! int || revisionNumber < 0) {
      throw const NativeDocumentCanvasException(
        'invalid-snapshot',
        'Canvas snapshot revision must be a non-negative integer.',
      );
    }
    final rawCommands = json['commands'];
    if (rawCommands is! List<Object?>) {
      throw const NativeDocumentCanvasException(
        'invalid-snapshot',
        'Canvas snapshot commands must be an array.',
      );
    }
    if (rawCommands.length > maxCommands) {
      throw NativeDocumentCanvasException(
        'canvas-command-limit',
        'Canvas snapshot has ${rawCommands.length} commands; the limit is $maxCommands.',
      );
    }
    final commands = <NativeDocumentCanvasCommand>[];
    for (var i = 0; i < rawCommands.length; i++) {
      commands.add(decoder.command(rawCommands[i], i));
    }
    decoder.validateDashWork(commands);
    return NativeDocumentCanvasSnapshot._(
      id: id,
      width: width,
      height: height,
      revision: revisionNumber,
      commands: List.unmodifiable(commands),
    );
  }
}

/// A user-visible decode error that can be translated into a document
/// diagnostic by the native HTML integration.
@immutable
class NativeDocumentCanvasException implements Exception {
  const NativeDocumentCanvasException(this.code, this.message);

  final String code;
  final String message;

  @override
  String toString() => 'NativeDocumentCanvasException($code): $message';
}

@immutable
class NativeDocumentCanvasCommand {
  const NativeDocumentCanvasCommand._({
    required this.op,
    required this.args,
    required this.state,
  });

  final String op;
  final List<Object?> args;
  final NativeDocumentCanvasState state;
}

@immutable
class NativeDocumentCanvasState {
  const NativeDocumentCanvasState._({
    required this.transform,
    required this.fillStyle,
    required this.strokeStyle,
    required this.globalAlpha,
    required this.blendMode,
    required this.lineWidth,
    required this.lineCap,
    required this.lineJoin,
    required this.miterLimit,
    required this.lineDash,
    required this.lineDashOffset,
    required this.imageSmoothingEnabled,
    required this.imageSmoothingQuality,
    required this.font,
    required this.textAlign,
    required this.textBaseline,
    required this.textBaselineOffset,
    required this.direction,
    required this.path,
    required this.clips,
  });

  final NativeDocumentCanvasTransform transform;
  final NativeDocumentCanvasStyle fillStyle;
  final NativeDocumentCanvasStyle strokeStyle;
  final double globalAlpha;
  final ui.BlendMode blendMode;
  final double lineWidth;
  final StrokeCap lineCap;
  final StrokeJoin lineJoin;
  final double miterLimit;
  final List<double> lineDash;
  final double lineDashOffset;
  final bool imageSmoothingEnabled;
  final ui.FilterQuality imageSmoothingQuality;
  final NativeDocumentCanvasFont font;
  final String textAlign;
  final String textBaseline;
  final double? textBaselineOffset;
  final TextDirection direction;
  final List<NativeDocumentCanvasPathSegment>? path;
  final List<NativeDocumentCanvasClip> clips;
}

@immutable
class NativeDocumentCanvasTransform {
  const NativeDocumentCanvasTransform._(this.values);

  /// The Canvas 2D affine matrix `[a, b, c, d, e, f]`.
  final List<double> values;

  Offset mapPoint(Offset point) {
    final m = values;
    return Offset(
      m[0] * point.dx + m[2] * point.dy + m[4],
      m[1] * point.dx + m[3] * point.dy + m[5],
    );
  }

  Float64List get matrix4 => _matrix4(values);

  NativeDocumentCanvasTransform? get inverse {
    final m = values;
    final determinant = m[0] * m[3] - m[1] * m[2];
    if (!determinant.isFinite || determinant.abs() < 1e-14) return null;
    final inverseDeterminant = 1 / determinant;
    final a = m[3] * inverseDeterminant;
    final b = -m[1] * inverseDeterminant;
    final c = -m[2] * inverseDeterminant;
    final d = m[0] * inverseDeterminant;
    final e = -(a * m[4] + c * m[5]);
    final f = -(b * m[4] + d * m[5]);
    if (![a, b, c, d, e, f].every((value) => value.isFinite)) return null;
    return NativeDocumentCanvasTransform._(
      List.unmodifiable([a, b, c, d, e, f]),
    );
  }

  NativeDocumentCanvasTransform compose(NativeDocumentCanvasTransform right) {
    final a = values;
    final b = right.values;
    return NativeDocumentCanvasTransform._(
      List.unmodifiable([
        a[0] * b[0] + a[2] * b[1],
        a[1] * b[0] + a[3] * b[1],
        a[0] * b[2] + a[2] * b[3],
        a[1] * b[2] + a[3] * b[3],
        a[0] * b[4] + a[2] * b[5] + a[4],
        a[1] * b[4] + a[3] * b[5] + a[5],
      ]),
    );
  }
}

@immutable
sealed class NativeDocumentCanvasStyle {
  const NativeDocumentCanvasStyle();
}

@immutable
class NativeDocumentCanvasColorStyle extends NativeDocumentCanvasStyle {
  const NativeDocumentCanvasColorStyle(this.color);

  final Color color;
}

@immutable
class NativeDocumentCanvasGradientStyle extends NativeDocumentCanvasStyle {
  const NativeDocumentCanvasGradientStyle._({
    required this.type,
    required this.args,
    required this.transform,
    required this.stops,
  });

  final String type;
  final List<double> args;
  final NativeDocumentCanvasTransform transform;
  final List<NativeDocumentCanvasColorStop> stops;
}

@immutable
class NativeDocumentCanvasColorStop {
  const NativeDocumentCanvasColorStop(this.offset, this.color);

  final double offset;
  final Color color;
}

@immutable
class NativeDocumentCanvasPathSegment {
  const NativeDocumentCanvasPathSegment._({
    required this.op,
    required this.args,
    required this.transform,
  });

  final String op;
  final List<Object?> args;
  final NativeDocumentCanvasTransform transform;
}

@immutable
class NativeDocumentCanvasClip {
  const NativeDocumentCanvasClip._({required this.path, required this.evenOdd});

  final List<NativeDocumentCanvasPathSegment> path;
  final bool evenOdd;
}

@immutable
class NativeDocumentCanvasFont {
  const NativeDocumentCanvasFont._({
    required this.source,
    required this.size,
    required this.family,
    required this.weight,
    required this.style,
  });

  final String source;
  final double size;
  final String? family;
  final FontWeight weight;
  final FontStyle style;

  TextStyle asTextStyle(Color? color, {Paint? foreground}) => TextStyle(
    color: foreground == null ? color : null,
    foreground: foreground,
    fontSize: size,
    fontFamily: family,
    fontWeight: weight,
    fontStyle: style,
    textBaseline: TextBaseline.alphabetic,
    height: 1,
  );
}

/// A Flutter-native, command-backed Canvas 2D surface.
///
/// [width] and [height] are the CSS replaced-element dimensions. The snapshot
/// width and height remain the backing Canvas bitmap dimensions, so rendering
/// uses the same independent logical-coordinate scaling as a browser canvas.
class NativeDocumentCanvas extends StatelessWidget {
  const NativeDocumentCanvas({
    super.key,
    required this.snapshot,
    this.width,
    this.height,
    this.cssWidthSpecified = false,
    this.cssHeightSpecified = false,
    this.images = const {},
  });

  final NativeDocumentCanvasSnapshot snapshot;
  final double? width;
  final double? height;
  final bool cssWidthSpecified;
  final bool cssHeightSpecified;
  final Map<String, ui.Image> images;

  @override
  Widget build(BuildContext context) {
    RenderL10n.watch(context);
    return NativeDocumentCanvasLayout(
      intrinsicSize: Size(snapshot.width, snapshot.height),
      width: width,
      height: height,
      cssWidthSpecified: cssWidthSpecified,
      cssHeightSpecified: cssHeightSpecified,
      // Canvas frames repaint independently of surrounding HTML/text.
      child: RepaintBoundary(
        child: CustomPaint(
          size: Size(snapshot.width, snapshot.height),
          painter: NativeDocumentCanvasPainter(snapshot, images: images),
        ),
      ),
    );
  }
}

/// Paints a decoded snapshot directly to Flutter's canvas.
class NativeDocumentCanvasPainter extends CustomPainter {
  const NativeDocumentCanvasPainter(this.snapshot, {this.images = const {}});

  final NativeDocumentCanvasSnapshot snapshot;
  final Map<String, ui.Image> images;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty || snapshot.width <= 0 || snapshot.height <= 0) return;
    canvas.save();
    canvas.scale(size.width / snapshot.width, size.height / snapshot.height);

    // All document commands run inside an isolated surface. clearRect and
    // destination compositing can then affect preceding document commands
    // without erasing Flutter content painted behind this widget.
    canvas.saveLayer(
      Rect.fromLTWH(0, 0, snapshot.width, snapshot.height),
      Paint(),
    );
    canvas.clipRect(Rect.fromLTWH(0, 0, snapshot.width, snapshot.height));
    for (final command in snapshot.commands) {
      _paintCommand(
        canvas,
        command,
        Rect.fromLTWH(0, 0, snapshot.width, snapshot.height),
        images,
      );
    }
    canvas.restore();
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant NativeDocumentCanvasPainter oldDelegate) =>
      !identical(snapshot, oldDelegate.snapshot) ||
      !identical(images, oldDelegate.images);
}

class _NativeCanvasDecoder {
  int pathSegmentCount = 0;

  void validateDashWork(List<NativeDocumentCanvasCommand> commands) {
    const maxGeneratedDashSegments = 100000;
    var remainingBudget = maxGeneratedDashSegments;
    for (var index = 0; index < commands.length; index++) {
      final command = commands[index];
      if (command.op != 'stroke' && command.op != 'strokeRect') continue;
      final dash = command.state.lineDash;
      if (dash.isEmpty || dash.every((value) => value == 0)) continue;
      final pattern = dash.length.isOdd ? <double>[...dash, ...dash] : dash;
      final period = pattern.fold<double>(0, (sum, value) => sum + value);
      if (!period.isFinite || period <= 0) {
        _invalid(
          'commands[$index].state.lineDash',
          tr("The dash pattern period must be finite and greater than zero."),
        );
      }
      final smallestDash = pattern
          .where((value) => value > 0)
          .reduce((a, b) => a < b ? a : b);

      Path path;
      if (command.op == 'stroke') {
        final inverse = command.state.transform.inverse;
        if (inverse == null) continue;
        path = _buildPath(command.state.path!).transform(inverse.matrix4);
      } else {
        path = _rectPath(_canvasRect(command.args));
      }
      for (final metric in path.computeMetrics()) {
        final length = metric.length;
        if (!length.isFinite) {
          _invalid(
            'commands[$index].state.lineDash',
            tr("Dashed strokes with unbounded path lengths are unsupported."),
          );
        }
        if (length <= 0) continue;
        if (smallestDash < length * 1e-15) {
          _invalid(
            'commands[$index].state.lineDash',
            tr(
              "Dash lengths are too small relative to the path for safe native rendering.",
            ),
          );
        }
        final periodCount = length / period;
        if (!periodCount.isFinite ||
            periodCount > remainingBudget / pattern.length) {
          throw NativeDocumentCanvasException(
            'canvas-dash-limit',
            tr(
              "Dashed stroke at commands[{0}] exceeds the native generation budget of {1} segments.",
              [index, maxGeneratedDashSegments],
            ),
          );
        }
        final periods = periodCount.ceil();
        final work = periods * pattern.length + pattern.length * 2;
        if (work > remainingBudget) {
          throw NativeDocumentCanvasException(
            'canvas-dash-limit',
            tr(
              "Dashed stroke at commands[{0}] exceeds the native generation budget of {1} segments.",
              [index, maxGeneratedDashSegments],
            ),
          );
        }
        remainingBudget -= work;
      }
    }
  }

  NativeDocumentCanvasCommand command(Object? raw, int index) {
    final object = _readMap(raw, 'commands[$index]');
    final op = _readString(object['op'], 'commands[$index].op');
    final rawArgs = object['args'];
    if (rawArgs is! List<Object?>) {
      throw NativeDocumentCanvasException(
        'invalid-command',
        tr("commands[{0}].args must be an array.", [index]),
      );
    }
    final args = List<Object?>.unmodifiable(rawArgs);
    final rawState = _readMap(object['state'], 'commands[$index].state');
    final state = _state(rawState, index, op);
    _validateCommand(op, args, state, index);
    return NativeDocumentCanvasCommand._(op: op, args: args, state: state);
  }

  NativeDocumentCanvasState _state(
    Map<String, Object?> source,
    int commandIndex,
    String op,
  ) {
    final prefix = 'commands[$commandIndex].state';
    final transform = _transform(source['transform'], '$prefix.transform');
    final fillStyle = _style(
      source['fillStyle'] ?? 'black',
      '$prefix.fillStyle',
    );
    final strokeStyle = _style(
      source['strokeStyle'] ?? 'black',
      '$prefix.strokeStyle',
    );
    final alpha = _optionalNumber(
      source['globalAlpha'],
      1,
      '$prefix.globalAlpha',
    );
    if (alpha < 0 || alpha > 1) {
      throw NativeDocumentCanvasException(
        'invalid-state',
        tr("{0}.globalAlpha must be in the range 0 to 1.", [prefix]),
      );
    }
    final blendMode = _blendMode(
      _optionalString(
        source['globalCompositeOperation'],
        'source-over',
        '$prefix.globalCompositeOperation',
      ),
      '$prefix.globalCompositeOperation',
    );
    final lineWidth = _optionalNumber(
      source['lineWidth'],
      1,
      '$prefix.lineWidth',
    );
    final miterLimit = _optionalNumber(
      source['miterLimit'],
      10,
      '$prefix.miterLimit',
    );
    if (lineWidth < 0 || miterLimit < 0) {
      throw NativeDocumentCanvasException(
        'invalid-state',
        tr("{0} line width and miter limit must be non-negative.", [prefix]),
      );
    }
    final lineDash = _numberList(
      source['lineDash'] ?? const <Object?>[],
      '$prefix.lineDash',
      maxLength: 256,
    );
    if (lineDash.any((value) => value < 0)) {
      throw NativeDocumentCanvasException(
        'invalid-state',
        tr("{0}.lineDash values must be non-negative.", [prefix]),
      );
    }
    final lineDashOffset = _optionalNumber(
      source['lineDashOffset'],
      0,
      '$prefix.lineDashOffset',
    );
    final imageSmoothingEnabled = _optionalBool(
      source['imageSmoothingEnabled'],
      true,
      '$prefix.imageSmoothingEnabled',
    );
    final imageSmoothingQualitySource = _optionalString(
      source['imageSmoothingQuality'],
      'low',
      '$prefix.imageSmoothingQuality',
    );
    final imageSmoothingQuality = switch (imageSmoothingQualitySource) {
      'low' => ui.FilterQuality.low,
      'medium' => ui.FilterQuality.medium,
      'high' => ui.FilterQuality.high,
      final value => throw NativeDocumentCanvasException(
        'invalid-state',
        tr(
          "{0}.imageSmoothingQuality must be low, medium, or high (got \"{1}\").",
          [prefix, value],
        ),
      ),
    };
    final lineCap = switch (_optionalString(
      source['lineCap'],
      'butt',
      '$prefix.lineCap',
    )) {
      'butt' => StrokeCap.butt,
      'round' => StrokeCap.round,
      'square' => StrokeCap.square,
      final value => throw NativeDocumentCanvasException(
        'unsupported-line-cap',
        tr("Unsupported Canvas line cap \"{0}\".", [value]),
      ),
    };
    final lineJoin = switch (_optionalString(
      source['lineJoin'],
      'miter',
      '$prefix.lineJoin',
    )) {
      'miter' => StrokeJoin.miter,
      'round' => StrokeJoin.round,
      'bevel' => StrokeJoin.bevel,
      final value => throw NativeDocumentCanvasException(
        'unsupported-line-join',
        tr("Unsupported Canvas line join \"{0}\".", [value]),
      ),
    };
    final fontSource = _optionalString(
      source['font'],
      '10px sans-serif',
      '$prefix.font',
    );
    final font = _font(fontSource, '$prefix.font');
    final textAlign = _optionalString(
      source['textAlign'],
      'start',
      '$prefix.textAlign',
    );
    if (!const {
      'left',
      'right',
      'center',
      'start',
      'end',
    }.contains(textAlign)) {
      throw NativeDocumentCanvasException(
        'unsupported-text-align',
        tr("Unsupported Canvas text alignment \"{0}\".", [textAlign]),
      );
    }
    final textBaseline = _optionalString(
      source['textBaseline'],
      'alphabetic',
      '$prefix.textBaseline',
    );
    if (!const {
      'top',
      'hanging',
      'middle',
      'alphabetic',
      'ideographic',
      'bottom',
    }.contains(textBaseline)) {
      throw NativeDocumentCanvasException(
        'unsupported-text-baseline',
        tr("Unsupported Canvas text baseline \"{0}\".", [textBaseline]),
      );
    }
    final textBaselineOffset = source.containsKey('textBaselineOffset')
        ? _readNumber(
            source['textBaselineOffset'],
            '$prefix.textBaselineOffset',
          )
        : null;
    final directionSource = _optionalString(
      source['direction'],
      'inherit',
      '$prefix.direction',
    );
    final direction = switch (directionSource) {
      'ltr' => TextDirection.ltr,
      'rtl' => TextDirection.rtl,
      'inherit' => TextDirection.ltr,
      final value => throw NativeDocumentCanvasException(
        'unsupported-text-direction',
        tr("Unsupported Canvas text direction \"{0}\".", [value]),
      ),
    };
    final path = source.containsKey('path')
        ? _path(source['path'], '$prefix.path')
        : null;
    final rawClips = source['clips'] ?? const <Object?>[];
    if (rawClips is! List<Object?> || rawClips.length > 32) {
      throw NativeDocumentCanvasException(
        'invalid-state',
        tr("{0}.clips must be an array containing at most 32 clips.", [prefix]),
      );
    }
    final clips = <NativeDocumentCanvasClip>[];
    for (var i = 0; i < rawClips.length; i++) {
      final clip = _readMap(rawClips[i], '$prefix.clips[$i]');
      final rule = _optionalString(
        clip['rule'],
        'nonzero',
        '$prefix.clips[$i].rule',
      );
      if (rule != 'nonzero' && rule != 'evenodd') {
        throw NativeDocumentCanvasException(
          'unsupported-fill-rule',
          tr("Unsupported Canvas clip fill rule \"{0}\".", [rule]),
        );
      }
      clips.add(
        NativeDocumentCanvasClip._(
          path: _path(clip['path'], '$prefix.clips[$i].path'),
          evenOdd: rule == 'evenodd',
        ),
      );
    }
    return NativeDocumentCanvasState._(
      transform: transform,
      fillStyle: fillStyle,
      strokeStyle: strokeStyle,
      globalAlpha: alpha,
      blendMode: blendMode,
      lineWidth: lineWidth,
      lineCap: lineCap,
      lineJoin: lineJoin,
      miterLimit: miterLimit,
      lineDash: List.unmodifiable(lineDash),
      lineDashOffset: lineDashOffset,
      imageSmoothingEnabled: imageSmoothingEnabled,
      imageSmoothingQuality: imageSmoothingQuality,
      font: font,
      textAlign: textAlign,
      textBaseline: textBaseline,
      textBaselineOffset: textBaselineOffset,
      direction: direction,
      path: path,
      clips: List.unmodifiable(clips),
    );
  }

  void _validateCommand(
    String op,
    List<Object?> args,
    NativeDocumentCanvasState state,
    int index,
  ) {
    final label = 'commands[$index]';
    switch (op) {
      case 'fillRect':
      case 'strokeRect':
      case 'clearRect':
        _requireNumericArgs(args, 4, '$label.args');
        break;
      case 'fill':
        if (args.length > 1) {
          _invalid('$label.args', 'fill accepts at most one fill rule.');
        }
        _validateRule(args.isEmpty ? 'nonzero' : args.single, '$label.args[0]');
        if (state.path == null) {
          _invalid('$label.state.path', 'fill requires a captured path.');
        }
        break;
      case 'stroke':
        if (args.isNotEmpty) {
          _invalid('$label.args', 'stroke takes no arguments.');
        }
        if (state.path == null) {
          _invalid('$label.state.path', 'stroke requires a captured path.');
        }
        break;
      case 'fillText':
      case 'strokeText':
        if (args.length < 3 || args.length > 4 || args[0] is! String) {
          _invalid('$label.args', '$op expects [text, x, y, maxWidth?].');
        }
        _readNumber(args[1], '$label.args[1]');
        _readNumber(args[2], '$label.args[2]');
        if (args.length == 4) {
          _readNumber(args[3], '$label.args[3]');
        }
        if ((args[0] as String).length > 16384) {
          _invalid('$label.args[0]', 'Text exceeds the 16384 character limit.');
        }
        break;
      case 'drawImage':
        if (args.length != 9 || args.first is! String) {
          _invalid(
            '$label.args',
            'drawImage expects [imageId, sx, sy, sw, sh, dx, dy, dw, dh].',
          );
        }
        final imageId = args.first as String;
        if (imageId.isEmpty || imageId.length > 256) {
          _invalid(
            '$label.args[0]',
            'Image handle must contain 1 to 256 characters.',
          );
        }
        final values = <double>[
          for (var argument = 1; argument < 9; argument++)
            _readNumber(args[argument], '$label.args[$argument]'),
        ];
        if (values[2] <= 0 ||
            values[3] <= 0 ||
            values[6] <= 0 ||
            values[7] <= 0) {
          _invalid(
            '$label.args',
            'drawImage source and destination dimensions must be positive.',
          );
        }
        break;
      default:
        throw NativeDocumentCanvasException(
          'unsupported-canvas-operation',
          tr("Canvas command \"{0}\" is not supported by the native painter.", [
            op,
          ]),
        );
    }
  }

  List<NativeDocumentCanvasPathSegment> _path(Object? raw, String path) {
    if (raw is! List<Object?>) {
      _invalid(path, tr("Path must be an array of captured path segments."));
    }
    if (raw.length > NativeDocumentCanvasSnapshot.maxPathSegmentsPerPath ||
        pathSegmentCount + raw.length >
            NativeDocumentCanvasSnapshot.maxPathSegments) {
      _invalid(path, tr("Canvas snapshot exceeds a path segment limit."));
    }
    pathSegmentCount += raw.length;
    final segments = <NativeDocumentCanvasPathSegment>[];
    for (var i = 0; i < raw.length; i++) {
      final source = _readMap(raw[i], '$path[$i]');
      final op = _readString(source['op'], '$path[$i].op');
      final rawArgs = source['args'];
      if (rawArgs is! List<Object?>) {
        _invalid(
          '$path[$i].args',
          tr("Path segment arguments must be an array."),
        );
      }
      final args = List<Object?>.unmodifiable(rawArgs);
      final transform = _transform(source['transform'], '$path[$i].transform');
      final expectedLength = switch (op) {
        'moveTo' || 'lineTo' || 'move' || 'line' => const {2},
        'rect' => const {4},
        'closePath' || 'close' => const {0},
        'quadraticCurveTo' || 'quadratic' => const {4},
        'bezierCurveTo' || 'cubic' => const {6},
        'arc' => const {5, 6},
        'ellipse' => const {7, 8},
        _ => null,
      };
      if (expectedLength == null) {
        throw NativeDocumentCanvasException(
          'unsupported-canvas-path-operation',
          tr("Canvas path operation \"{0}\" is not supported.", [op]),
        );
      }
      if (!expectedLength.contains(args.length)) {
        _invalid(
          '$path[$i].args',
          tr("Invalid argument count for path operation \"{0}\".", [op]),
        );
      }
      for (
        var argumentIndex = 0;
        argumentIndex < args.length;
        argumentIndex++
      ) {
        final value = args[argumentIndex];
        if ((op == 'arc' && argumentIndex == 5) ||
            (op == 'ellipse' && argumentIndex == 7)) {
          if (value is! bool) {
            _invalid(
              '$path[$i].args[$argumentIndex]',
              tr("The anticlockwise argument must be boolean."),
            );
          }
        } else {
          _readNumber(value, '$path[$i].args[$argumentIndex]');
        }
      }
      if ((op == 'arc' && _numberAt(args, 2) < 0) ||
          (op == 'ellipse' &&
              (_numberAt(args, 2) < 0 || _numberAt(args, 3) < 0))) {
        _invalid('$path[$i].args', tr("Arc radii must be non-negative."));
      }
      segments.add(
        NativeDocumentCanvasPathSegment._(
          op: op,
          args: args,
          transform: transform,
        ),
      );
    }
    return List.unmodifiable(segments);
  }

  NativeDocumentCanvasTransform _transform(Object? raw, String path) {
    final values = _numberList(raw, path, expectedLength: 6);
    if (values.any((value) => value.abs() > 1e9)) {
      _invalid(
        path,
        tr("Transform values exceed the native coordinate limit."),
      );
    }
    return NativeDocumentCanvasTransform._(List.unmodifiable(values));
  }

  NativeDocumentCanvasStyle _style(Object? raw, String path) {
    if (raw is String) {
      return NativeDocumentCanvasColorStyle(_color(raw, path));
    }
    final source = _readMap(raw, path);
    final type = _readString(source['type'], '$path.type');
    if (type != 'linear' && type != 'radial') {
      throw NativeDocumentCanvasException(
        'unsupported-canvas-style',
        tr("Canvas paint style \"{0}\" is not supported.", [type]),
      );
    }
    final args = _numberList(
      source['args'],
      '$path.args',
      expectedLength: type == 'linear' ? 4 : 6,
    );
    if (type == 'radial' && (args[2] < 0 || args[5] < 0)) {
      _invalid('$path.args', tr("Radial gradient radii must be non-negative."));
    }
    final transform = _transform(source['transform'], '$path.transform');
    final rawStops = source['stops'];
    if (rawStops is! List<Object?> || rawStops.length > 1024) {
      _invalid(
        '$path.stops',
        tr("A gradient must contain at most 1024 color stops."),
      );
    }
    final stops = <NativeDocumentCanvasColorStop>[];
    for (var i = 0; i < rawStops.length; i++) {
      final stop = _readMap(rawStops[i], '$path.stops[$i]');
      final offset = _readNumber(stop['offset'], '$path.stops[$i].offset');
      if (offset < 0 || offset > 1) {
        _invalid(
          '$path.stops[$i].offset',
          tr("Gradient offsets must be in the range 0 to 1."),
        );
      }
      stops.add(
        NativeDocumentCanvasColorStop(
          offset,
          _color(
            _readString(stop['color'], '$path.stops[$i].color'),
            '$path.stops[$i].color',
          ),
        ),
      );
    }
    stops.sort((a, b) => a.offset.compareTo(b.offset));
    return NativeDocumentCanvasGradientStyle._(
      type: type,
      args: List.unmodifiable(args),
      transform: transform,
      stops: List.unmodifiable(stops),
    );
  }

  NativeDocumentCanvasFont _font(String source, String path) {
    final match = RegExp(
      r'(?:(italic|oblique)\s+)?(?:(bold|bolder|lighter|[1-9]00)\s+)?([0-9]*\.?[0-9]+)(px|pt|pc|in|cm|mm|q|em|rem)(?:/[^\s]+)?\s+(.+)$',
      caseSensitive: false,
    ).firstMatch(source.trim());
    if (match == null) {
      throw NativeDocumentCanvasException(
        'unsupported-canvas-font',
        tr("Canvas font \"{0}\" cannot be parsed by the native text painter.", [
          source,
        ]),
      );
    }
    final prefix = source.trim().substring(0, match.start).trim().toLowerCase();
    if (prefix
        .split(RegExp(r'\s+'))
        .any((token) => token.isNotEmpty && token != 'normal')) {
      throw NativeDocumentCanvasException(
        'unsupported-canvas-font',
        tr(
          "Canvas font \"{0}\" uses a font feature outside the native text subset.",
          [source],
        ),
      );
    }
    final style = switch (match.group(1)?.toLowerCase()) {
      'italic' || 'oblique' => FontStyle.italic,
      _ => FontStyle.normal,
    };
    final weight = switch (match.group(2)?.toLowerCase()) {
      'bold' || 'bolder' => FontWeight.w700,
      'lighter' => FontWeight.w300,
      '100' => FontWeight.w100,
      '200' => FontWeight.w200,
      '300' => FontWeight.w300,
      '400' || null => FontWeight.w400,
      '500' => FontWeight.w500,
      '600' => FontWeight.w600,
      '700' => FontWeight.w700,
      '800' => FontWeight.w800,
      '900' => FontWeight.w900,
      final value => throw NativeDocumentCanvasException(
        'unsupported-canvas-font',
        tr("Canvas font weight \"{0}\" is unsupported.", [value]),
      ),
    };
    final number = double.parse(match.group(3)!);
    final size = switch (match.group(4)!.toLowerCase()) {
      'px' => number,
      'pt' => number * 96 / 72,
      'pc' => number * 16,
      'in' => number * 96,
      'cm' => number * 96 / 2.54,
      'mm' => number * 96 / 25.4,
      'q' => number * 96 / 101.6,
      'em' || 'rem' => number * 16,
      _ => number,
    };
    if (!size.isFinite || size <= 0 || size > 4096) {
      throw NativeDocumentCanvasException(
        'unsupported-canvas-font',
        tr("Canvas font size in \"{0}\" is outside the supported range.", [
          source,
        ]),
      );
    }
    final families = _splitFontFamilies(match.group(5)!);
    if (families.isEmpty) {
      throw NativeDocumentCanvasException(
        'unsupported-canvas-font',
        tr("Canvas font \"{0}\" has no font family.", [source]),
      );
    }
    final familyText = families.first.trim();
    final family =
        familyText.length >= 2 &&
            (familyText.startsWith('"') && familyText.endsWith('"') ||
                familyText.startsWith("'") && familyText.endsWith("'"))
        ? familyText.substring(1, familyText.length - 1)
        : familyText;
    final normalizedFamily = family.toLowerCase();
    final flutterFamily = switch (normalizedFamily) {
      'sans-serif' || 'system-ui' || 'ui-sans-serif' => null,
      'serif' || 'monospace' || 'cursive' || 'fantasy' => normalizedFamily,
      _ => family,
    };
    return NativeDocumentCanvasFont._(
      source: source,
      size: size,
      family: flutterFamily,
      weight: weight,
      style: style,
    );
  }

  Color _color(String value, String path) {
    final text = value.trim();
    final lower = text.toLowerCase();
    if (lower == 'transparent') return const Color(0x00000000);
    final named = _namedCanvasColors[lower];
    if (named != null) return Color(named);
    final parsed = parseNativeCssColor(text);
    if (parsed != null) return parsed;
    throw NativeDocumentCanvasException(
      'unsupported-canvas-color',
      tr(
        "Canvas color \"{0}\" at {1} is not supported by the native color parser.",
        [value, path],
      ),
    );
  }

  ui.BlendMode _blendMode(String source, String path) {
    final mode = switch (source) {
      'source-over' => ui.BlendMode.srcOver,
      'source-in' => ui.BlendMode.srcIn,
      'source-out' => ui.BlendMode.srcOut,
      'source-atop' => ui.BlendMode.srcATop,
      'destination-over' => ui.BlendMode.dstOver,
      'destination-in' => ui.BlendMode.dstIn,
      'destination-out' => ui.BlendMode.dstOut,
      'destination-atop' => ui.BlendMode.dstATop,
      'lighter' => ui.BlendMode.plus,
      'copy' => ui.BlendMode.src,
      'xor' => ui.BlendMode.xor,
      'multiply' => ui.BlendMode.multiply,
      'screen' => ui.BlendMode.screen,
      'overlay' => ui.BlendMode.overlay,
      'darken' => ui.BlendMode.darken,
      'lighten' => ui.BlendMode.lighten,
      'color-dodge' => ui.BlendMode.colorDodge,
      'color-burn' => ui.BlendMode.colorBurn,
      'hard-light' => ui.BlendMode.hardLight,
      'soft-light' => ui.BlendMode.softLight,
      'difference' => ui.BlendMode.difference,
      'exclusion' => ui.BlendMode.exclusion,
      'hue' => ui.BlendMode.hue,
      'saturation' => ui.BlendMode.saturation,
      'color' => ui.BlendMode.color,
      'luminosity' => ui.BlendMode.luminosity,
      final value => throw NativeDocumentCanvasException(
        'unsupported-canvas-composite-operation',
        tr("Canvas composite operation \"{0}\" at {1} is unsupported.", [
          value,
          path,
        ]),
      ),
    };
    return mode;
  }
}

void _paintCommand(
  Canvas canvas,
  NativeDocumentCanvasCommand command,
  Rect surfaceBounds,
  Map<String, ui.Image> images,
) {
  final state = command.state;
  canvas.save();
  for (final clip in state.clips) {
    final path = _buildPath(clip.path);
    path.fillType = clip.evenOdd ? PathFillType.evenOdd : PathFillType.nonZero;
    canvas.clipPath(path, doAntiAlias: true);
  }
  final fullExtentComposite =
      command.op != 'clearRect' &&
      _requiresFullExtentComposite(state.blendMode);
  if (fullExtentComposite) {
    canvas.saveLayer(surfaceBounds, Paint()..blendMode = state.blendMode);
  }
  canvas.transform(state.transform.matrix4);
  final drawState = fullExtentComposite
      ? _withBlendMode(state, ui.BlendMode.srcOver)
      : state;
  switch (command.op) {
    case 'fillRect':
      final rect = _canvasRect(command.args);
      canvas.drawRect(
        rect,
        _paintForStyle(drawState.fillStyle, drawState, stroke: false),
      );
      break;
    case 'strokeRect':
      final rect = _canvasRect(command.args);
      if (drawState.lineWidth > 0) {
        final path = _rectPath(rect);
        final dashed = _dashPath(
          path,
          drawState.lineDash,
          drawState.lineDashOffset,
        );
        canvas.drawPath(
          dashed,
          _paintForStyle(drawState.strokeStyle, drawState, stroke: true),
        );
      }
      break;
    case 'clearRect':
      canvas.drawRect(
        _canvasRect(command.args),
        Paint()..blendMode = ui.BlendMode.clear,
      );
      break;
    case 'fill':
    case 'stroke':
      final devicePath = _buildPath(state.path!);
      final evenOdd =
          command.op == 'fill' &&
          command.args.isNotEmpty &&
          command.args.single == 'evenodd';
      devicePath.fillType = evenOdd
          ? PathFillType.evenOdd
          : PathFillType.nonZero;
      final inverse = state.transform.inverse;
      // A singular current transform collapses a path draw to no visible area.
      if (inverse != null) {
        var localPath = devicePath.transform(inverse.matrix4);
        if (command.op == 'stroke') {
          if (drawState.lineWidth <= 0) break;
          localPath = _dashPath(
            localPath,
            drawState.lineDash,
            drawState.lineDashOffset,
          );
          canvas.drawPath(
            localPath,
            _paintForStyle(drawState.strokeStyle, drawState, stroke: true),
          );
        } else {
          canvas.drawPath(
            localPath,
            _paintForStyle(drawState.fillStyle, drawState, stroke: false),
          );
        }
      }
      break;
    case 'fillText':
    case 'strokeText':
      _paintText(
        canvas,
        NativeDocumentCanvasCommand._(
          op: command.op,
          args: command.args,
          state: drawState,
        ),
      );
      break;
    case 'drawImage':
      if (drawState.globalAlpha <= 0) break;
      final imageId = command.args[0] as String;
      final image = images[imageId];
      if (image == null) {
        throw NativeDocumentCanvasException(
          'missing-canvas-image',
          'Canvas image handle "$imageId" is not available to the native painter.',
        );
      }
      final source = Rect.fromLTWH(
        _argNumber(command.args, 1),
        _argNumber(command.args, 2),
        _argNumber(command.args, 3),
        _argNumber(command.args, 4),
      );
      final destination = Rect.fromLTWH(
        _argNumber(command.args, 5),
        _argNumber(command.args, 6),
        _argNumber(command.args, 7),
        _argNumber(command.args, 8),
      );
      final quality = drawState.imageSmoothingEnabled
          ? drawState.imageSmoothingQuality
          : ui.FilterQuality.none;
      final paint = Paint()
        ..blendMode = drawState.blendMode
        ..filterQuality = quality
        ..color = Color.fromRGBO(255, 255, 255, drawState.globalAlpha);
      canvas.drawImageRect(image, source, destination, paint);
      break;
  }
  if (fullExtentComposite) canvas.restore();
  canvas.restore();
}

NativeDocumentCanvasState _withBlendMode(
  NativeDocumentCanvasState state,
  ui.BlendMode blendMode,
) => NativeDocumentCanvasState._(
  transform: state.transform,
  fillStyle: state.fillStyle,
  strokeStyle: state.strokeStyle,
  globalAlpha: state.globalAlpha,
  blendMode: blendMode,
  lineWidth: state.lineWidth,
  lineCap: state.lineCap,
  lineJoin: state.lineJoin,
  miterLimit: state.miterLimit,
  lineDash: state.lineDash,
  lineDashOffset: state.lineDashOffset,
  imageSmoothingEnabled: state.imageSmoothingEnabled,
  imageSmoothingQuality: state.imageSmoothingQuality,
  font: state.font,
  textAlign: state.textAlign,
  textBaseline: state.textBaseline,
  textBaselineOffset: state.textBaselineOffset,
  direction: state.direction,
  path: state.path,
  clips: state.clips,
);

bool _requiresFullExtentComposite(ui.BlendMode mode) =>
    mode == ui.BlendMode.src ||
    mode == ui.BlendMode.srcIn ||
    mode == ui.BlendMode.srcOut ||
    mode == ui.BlendMode.dstIn ||
    mode == ui.BlendMode.dstATop;

Rect _canvasRect(List<Object?> args) {
  final x = _argNumber(args, 0);
  final y = _argNumber(args, 1);
  final x2 = x + _argNumber(args, 2);
  final y2 = y + _argNumber(args, 3);
  return Rect.fromLTRB(
    math.min(x, x2),
    math.min(y, y2),
    math.max(x, x2),
    math.max(y, y2),
  );
}

Path _rectPath(Rect rect) => Path()
  ..moveTo(rect.left, rect.top)
  ..lineTo(rect.right, rect.top)
  ..lineTo(rect.right, rect.bottom)
  ..lineTo(rect.left, rect.bottom)
  ..close();

Paint _paintForStyle(
  NativeDocumentCanvasStyle style,
  NativeDocumentCanvasState state, {
  required bool stroke,
}) {
  final paint = Paint()
    ..blendMode = state.blendMode
    ..style = stroke ? PaintingStyle.stroke : PaintingStyle.fill
    ..strokeWidth = state.lineWidth
    ..strokeCap = state.lineCap
    ..strokeJoin = state.lineJoin
    ..strokeMiterLimit = state.miterLimit
    ..isAntiAlias = true;
  switch (style) {
    case NativeDocumentCanvasColorStyle(:final color):
      paint.color = _multiplyAlpha(color, state.globalAlpha);
      break;
    case NativeDocumentCanvasGradientStyle():
      // Opacity is folded into each stop below; using translucent white here
      // would multiply shader alpha for a second time in the engine.
      if (style.stops.isEmpty) {
        paint.color = const Color(0x00000000);
      } else if (style.stops.length == 1) {
        paint.color = _multiplyAlpha(
          style.stops.single.color,
          state.globalAlpha,
        );
      } else {
        paint.color = const Color(0xffffffff);
        paint.shader = _gradientShader(style, state);
      }
      break;
  }
  return paint;
}

ui.Shader _gradientShader(
  NativeDocumentCanvasGradientStyle style,
  NativeDocumentCanvasState state,
) {
  final stops = style.stops;
  final colors = stops
      .map((stop) => _multiplyAlpha(stop.color, state.globalAlpha))
      .toList(growable: false);
  final positions = stops.map((stop) => stop.offset).toList(growable: false);
  // Chrome ignores the CTM captured when a CanvasGradient is created, but
  // applies the CTM active at draw time to the gradient and geometry together.
  // Omitting a shader matrix lets Flutter's current Canvas transform do that.
  if (style.type == 'linear') {
    final a = style.args;
    return ui.Gradient.linear(
      Offset(a[0], a[1]),
      Offset(a[2], a[3]),
      colors,
      positions,
      ui.TileMode.clamp,
    );
  }
  final a = style.args;
  final firstCenter = Offset(a[0], a[1]);
  final firstRadius = a[2];
  final secondCenter = Offset(a[3], a[4]);
  final secondRadius = a[5];
  if (firstRadius <= secondRadius) {
    return ui.Gradient.radial(
      secondCenter,
      secondRadius,
      colors,
      positions,
      ui.TileMode.clamp,
      null,
      firstCenter,
      firstRadius,
    );
  }
  final reversedColors = colors.reversed.toList(growable: false);
  final reversedPositions = positions.reversed
      .map((position) => 1 - position)
      .toList(growable: false);
  return ui.Gradient.radial(
    firstCenter,
    firstRadius,
    reversedColors,
    reversedPositions,
    ui.TileMode.clamp,
    null,
    secondCenter,
    secondRadius,
  );
}

void _paintText(Canvas canvas, NativeDocumentCanvasCommand command) {
  final state = command.state;
  final text = (command.args[0] as String).replaceAll(
    RegExp(r'[\t\n\v\f\r]'),
    ' ',
  );
  final x = _argNumber(command.args, 1);
  final y = _argNumber(command.args, 2);
  final maxWidth = command.args.length == 4
      ? _argNumber(command.args, 3)
      : double.infinity;
  if (text.isEmpty || maxWidth <= 0 || state.globalAlpha <= 0) return;
  final stroke = command.op == 'strokeText';
  if (stroke && state.lineWidth <= 0) return;
  final style = stroke ? state.strokeStyle : state.fillStyle;
  final baseColor = switch (style) {
    NativeDocumentCanvasColorStyle(:final color) => _multiplyAlpha(
      color,
      state.globalAlpha,
    ),
    NativeDocumentCanvasGradientStyle() => const Color(
      0xffffffff,
    ).withValues(alpha: state.globalAlpha),
  };
  Paint? foreground;
  if (style is NativeDocumentCanvasGradientStyle) {
    foreground = _paintForStyle(style, state, stroke: stroke);
  } else if (stroke || state.blendMode != ui.BlendMode.srcOver) {
    foreground = Paint()
      ..color = baseColor
      ..style = stroke ? PaintingStyle.stroke : PaintingStyle.fill
      ..strokeWidth = state.lineWidth
      ..strokeCap = state.lineCap
      ..strokeJoin = state.lineJoin
      ..strokeMiterLimit = state.miterLimit
      ..blendMode = state.blendMode
      ..isAntiAlias = true;
  }
  final textStyle = state.font.asTextStyle(
    foreground == null ? baseColor : null,
    foreground: foreground,
  );
  final painter = TextPainter(
    text: TextSpan(text: text, style: textStyle),
    textDirection: state.direction,
    textAlign: TextAlign.left,
    textScaler: TextScaler.noScaling,
    maxLines: 1,
  )..layout();
  final lineMetrics = painter.computeLineMetrics();
  if (lineMetrics.isEmpty) {
    painter.dispose();
    return;
  }
  final width = painter.width;
  final effectiveAlign = switch (state.textAlign) {
    'start' => state.direction == TextDirection.ltr ? 'left' : 'right',
    'end' => state.direction == TextDirection.ltr ? 'right' : 'left',
    final value => value,
  };
  final left = switch (effectiveAlign) {
    'center' => x - width / 2,
    'right' => x - width,
    _ => x,
  };
  final metrics = lineMetrics.first;
  final legacyBaseline = state.textBaselineOffset == null
      ? switch (state.textBaseline) {
          'top' => metrics.baseline - metrics.ascent,
          'hanging' => metrics.baseline - metrics.ascent * .8,
          'middle' => metrics.baseline - (metrics.ascent - metrics.descent) / 2,
          'ideographic' => metrics.baseline + metrics.descent * .5,
          'bottom' => metrics.baseline + metrics.descent,
          _ => metrics.baseline,
        }
      : null;
  final textTop = state.textBaselineOffset == null
      ? y - legacyBaseline!
      : y + state.textBaselineOffset! - metrics.baseline;
  final horizontalScale = maxWidth.isFinite && width > maxWidth && width > 0
      ? maxWidth / width
      : 1.0;
  final drawLeft = horizontalScale == 1
      ? left
      : switch (effectiveAlign) {
          'center' => x - maxWidth / 2,
          'right' => x - maxWidth,
          _ => x,
        };
  canvas.save();
  if (horizontalScale != 1) {
    canvas.translate(drawLeft, 0);
    canvas.scale(horizontalScale, 1);
    painter.paint(canvas, Offset(0, textTop));
  } else {
    painter.paint(canvas, Offset(drawLeft, textTop));
  }
  canvas.restore();
  painter.dispose();
}

Path _buildPath(List<NativeDocumentCanvasPathSegment> segments) {
  final path = Path();
  Offset? current;
  Offset? subpathStart;
  for (final segment in segments) {
    final args = segment.args;
    final transform = segment.transform;
    Offset point(double x, double y) => transform.mapPoint(Offset(x, y));
    switch (segment.op) {
      case 'moveTo':
      case 'move':
        current = point(_argNumber(args, 0), _argNumber(args, 1));
        subpathStart = current;
        path.moveTo(current.dx, current.dy);
      case 'lineTo':
      case 'line':
        final next = point(_argNumber(args, 0), _argNumber(args, 1));
        if (current == null) {
          path.moveTo(next.dx, next.dy);
          subpathStart = next;
        } else {
          path.lineTo(next.dx, next.dy);
        }
        current = next;
      case 'rect':
        final x = _argNumber(args, 0);
        final y = _argNumber(args, 1);
        final w = _argNumber(args, 2);
        final h = _argNumber(args, 3);
        final p0 = point(x, y);
        final p1 = point(x + w, y);
        final p2 = point(x + w, y + h);
        final p3 = point(x, y + h);
        path
          ..moveTo(p0.dx, p0.dy)
          ..lineTo(p1.dx, p1.dy)
          ..lineTo(p2.dx, p2.dy)
          ..lineTo(p3.dx, p3.dy)
          ..close();
        current = p0;
        subpathStart = p0;
      case 'closePath':
      case 'close':
        if (current != null && subpathStart != null) {
          path.close();
          current = subpathStart;
        }
      case 'quadraticCurveTo':
      case 'quadratic':
        final control = point(_argNumber(args, 0), _argNumber(args, 1));
        final end = point(_argNumber(args, 2), _argNumber(args, 3));
        if (current == null) {
          path.moveTo(control.dx, control.dy);
          subpathStart = control;
          current = control;
        }
        path.quadraticBezierTo(control.dx, control.dy, end.dx, end.dy);
        current = end;
      case 'bezierCurveTo':
      case 'cubic':
        final firstControl = point(_argNumber(args, 0), _argNumber(args, 1));
        final secondControl = point(_argNumber(args, 2), _argNumber(args, 3));
        final end = point(_argNumber(args, 4), _argNumber(args, 5));
        if (current == null) {
          path.moveTo(firstControl.dx, firstControl.dy);
          subpathStart = firstControl;
          current = firstControl;
        }
        path.cubicTo(
          firstControl.dx,
          firstControl.dy,
          secondControl.dx,
          secondControl.dy,
          end.dx,
          end.dy,
        );
        current = end;
      case 'arc':
        final x = _argNumber(args, 0);
        final y = _argNumber(args, 1);
        final radius = _argNumber(args, 2);
        final start = _argNumber(args, 3);
        final end = _argNumber(args, 4);
        final anticlockwise = args.length == 6 && args[5] == true;
        final startPoint = point(
          x + radius * math.cos(start),
          y + radius * math.sin(start),
        );
        if (current == null) {
          path.moveTo(startPoint.dx, startPoint.dy);
          subpathStart = startPoint;
        } else if ((current - startPoint).distanceSquared > 1e-18) {
          path.lineTo(startPoint.dx, startPoint.dy);
        }
        current = _appendArc(
          path,
          transform,
          centerX: x,
          centerY: y,
          radiusX: radius,
          radiusY: radius,
          rotation: 0,
          start: start,
          end: end,
          anticlockwise: anticlockwise,
        );
      case 'ellipse':
        final x = _argNumber(args, 0);
        final y = _argNumber(args, 1);
        final radiusX = _argNumber(args, 2);
        final radiusY = _argNumber(args, 3);
        final rotation = _argNumber(args, 4);
        final start = _argNumber(args, 5);
        final end = _argNumber(args, 6);
        final anticlockwise = args.length == 8 && args[7] == true;
        final startPoint = _ellipsePoint(
          x,
          y,
          radiusX,
          radiusY,
          rotation,
          start,
        );
        final deviceStart = transform.mapPoint(startPoint);
        if (current == null) {
          path.moveTo(deviceStart.dx, deviceStart.dy);
          subpathStart = deviceStart;
        } else if ((current - deviceStart).distanceSquared > 1e-18) {
          path.lineTo(deviceStart.dx, deviceStart.dy);
        }
        current = _appendArc(
          path,
          transform,
          centerX: x,
          centerY: y,
          radiusX: radiusX,
          radiusY: radiusY,
          rotation: rotation,
          start: start,
          end: end,
          anticlockwise: anticlockwise,
        );
    }
  }
  return path;
}

Offset _appendArc(
  Path path,
  NativeDocumentCanvasTransform transform, {
  required double centerX,
  required double centerY,
  required double radiusX,
  required double radiusY,
  required double rotation,
  required double start,
  required double end,
  required bool anticlockwise,
}) {
  final sweep = _normalizedSweep(start, end, anticlockwise);
  if (sweep == 0 || radiusX == 0 || radiusY == 0) {
    return transform.mapPoint(
      _ellipsePoint(
        centerX,
        centerY,
        radiusX,
        radiusY,
        rotation,
        start + sweep,
      ),
    );
  }
  final pieces = (sweep.abs() / (math.pi / 2)).ceil();
  final pieceSweep = sweep / pieces;
  final cosine = math.cos(rotation);
  final sine = math.sin(rotation);
  Offset ellipsePoint(double angle) => transform.mapPoint(
    _ellipsePoint(centerX, centerY, radiusX, radiusY, rotation, angle),
  );
  Offset ellipseDerivative(double angle) {
    final localX = -radiusX * math.sin(angle);
    final localY = radiusY * math.cos(angle);
    return Offset(
      cosine * localX - sine * localY,
      sine * localX + cosine * localY,
    );
  }

  for (var i = 0; i < pieces; i++) {
    final firstAngle = start + pieceSweep * i;
    final lastAngle = firstAngle + pieceSweep;
    final factor = 4 / 3 * math.tan((lastAngle - firstAngle) / 4);
    final last = ellipsePoint(lastAngle);
    final firstDerivative = ellipseDerivative(firstAngle);
    final lastDerivative = ellipseDerivative(lastAngle);
    final control1 = transform.mapPoint(
      _ellipsePoint(centerX, centerY, radiusX, radiusY, rotation, firstAngle) +
          firstDerivative * factor,
    );
    final control2 = transform.mapPoint(
      _ellipsePoint(centerX, centerY, radiusX, radiusY, rotation, lastAngle) -
          lastDerivative * factor,
    );
    path.cubicTo(
      control1.dx,
      control1.dy,
      control2.dx,
      control2.dy,
      last.dx,
      last.dy,
    );
  }
  return ellipsePoint(start + sweep);
}

Offset _ellipsePoint(
  double centerX,
  double centerY,
  double radiusX,
  double radiusY,
  double rotation,
  double angle,
) {
  final cosine = math.cos(rotation);
  final sine = math.sin(rotation);
  final x = radiusX * math.cos(angle);
  final y = radiusY * math.sin(angle);
  return Offset(
    centerX + cosine * x - sine * y,
    centerY + sine * x + cosine * y,
  );
}

double _normalizedSweep(double start, double end, bool anticlockwise) {
  var sweep = end - start;
  const turn = math.pi * 2;
  if (anticlockwise) {
    if (sweep <= -turn || sweep >= turn) return -turn;
    if (sweep > 0) sweep = sweep % turn - turn;
  } else {
    if (sweep >= turn || sweep <= -turn) return turn;
    if (sweep < 0) sweep = sweep % turn + turn;
  }
  return sweep;
}

Path _dashPath(Path path, List<double> rawDash, double offset) {
  if (rawDash.isEmpty || rawDash.every((value) => value == 0)) return path;
  final pattern = rawDash.length.isOdd
      ? <double>[...rawDash, ...rawDash]
      : rawDash;
  final total = pattern.fold<double>(0, (sum, item) => sum + item);
  if (total <= 0 || !total.isFinite) return path;
  final dashed = Path()..fillType = path.fillType;
  for (final metric in path.computeMetrics()) {
    // Canvas restarts the dash pattern at each subpath.
    var phase = offset % total;
    if (phase < 0) phase += total;
    var patternIndex = 0;
    var zeroSkipCount = 0;
    while (pattern[patternIndex] == 0 || phase >= pattern[patternIndex]) {
      if (pattern[patternIndex] > 0) phase -= pattern[patternIndex];
      patternIndex = (patternIndex + 1) % pattern.length;
      zeroSkipCount++;
      if (zeroSkipCount > pattern.length) break;
    }
    var remaining = pattern[patternIndex] - phase;
    var drawSegment = patternIndex.isEven;
    var distance = 0.0;
    while (distance < metric.length) {
      while (remaining <= 0) {
        patternIndex = (patternIndex + 1) % pattern.length;
        remaining = pattern[patternIndex];
        drawSegment = patternIndex.isEven;
      }
      final next = math.min(metric.length, distance + remaining);
      if (next <= distance) {
        // Floating point subtraction can leave a positive residue too small
        // to move the pen. Treat it as consumed and advance so painting cannot
        // stall on an unrepresentable dash fragment.
        var skips = 0;
        do {
          patternIndex = (patternIndex + 1) % pattern.length;
          remaining = pattern[patternIndex];
          drawSegment = patternIndex.isEven;
          skips++;
        } while (remaining <= 0 && skips <= pattern.length);
        continue;
      }
      if (drawSegment && next > distance) {
        dashed.addPath(metric.extractPath(distance, next), Offset.zero);
      }
      remaining -= next - distance;
      distance = next;
      if (remaining <= 0) {
        var skips = 0;
        do {
          patternIndex = (patternIndex + 1) % pattern.length;
          remaining = pattern[patternIndex];
          drawSegment = patternIndex.isEven;
          skips++;
        } while (remaining <= 0 && skips <= pattern.length);
      }
    }
  }
  return dashed;
}

void _validateRule(Object? raw, String path) {
  if (raw != 'nonzero' && raw != 'evenodd') {
    throw NativeDocumentCanvasException(
      'unsupported-fill-rule',
      tr("Unsupported Canvas fill rule \"{0}\" at {1}.", [raw, path]),
    );
  }
}

void _requireNumericArgs(List<Object?> args, int count, String path) {
  if (args.length != count) {
    throw NativeDocumentCanvasException(
      'invalid-command',
      tr("{0} must contain exactly {1} numbers.", [path, count]),
    );
  }
  for (var i = 0; i < args.length; i++) {
    _readNumber(args[i], '$path[$i]');
  }
}

double _argNumber(List<Object?> args, int index) =>
    (args[index] as num).toDouble();

double _numberAt(List<Object?> args, int index) =>
    (args[index] as num).toDouble();

Color _multiplyAlpha(Color color, double alpha) =>
    color.withValues(alpha: color.a * alpha);

Float64List _matrix4(List<double> affine) => Float64List.fromList([
  affine[0],
  affine[1],
  0,
  0,
  affine[2],
  affine[3],
  0,
  0,
  0,
  0,
  1,
  0,
  affine[4],
  affine[5],
  0,
  1,
]);

List<String> _splitFontFamilies(String source) {
  final families = <String>[];
  var quote = '';
  var start = 0;
  for (var i = 0; i < source.length; i++) {
    final char = source[i];
    if (quote.isNotEmpty) {
      if (char == quote && (i == 0 || source[i - 1] != r'\')) quote = '';
    } else if (char == '"' || char == "'") {
      quote = char;
    } else if (char == ',') {
      families.add(source.substring(start, i).trim());
      start = i + 1;
    }
  }
  families.add(source.substring(start).trim());
  return families.where((family) => family.isNotEmpty).toList(growable: false);
}

Map<String, Object?> _readMap(Object? value, String path) {
  if (value is! Map) {
    throw NativeDocumentCanvasException(
      'invalid-snapshot',
      tr("{0} must be an object.", [path]),
    );
  }
  final result = <String, Object?>{};
  for (final entry in value.entries) {
    if (entry.key is! String) {
      throw NativeDocumentCanvasException(
        'invalid-snapshot',
        tr("{0} has a non-string object key.", [path]),
      );
    }
    result[entry.key as String] = entry.value;
  }
  return result;
}

String _readString(Object? value, String path) {
  if (value is String) return value;
  throw NativeDocumentCanvasException(
    'invalid-snapshot',
    tr("{0} must be a string.", [path]),
  );
}

String _optionalString(Object? value, String fallback, [String? path]) =>
    value == null ? fallback : _readString(value, path ?? 'value');

bool _optionalBool(Object? value, bool fallback, String path) {
  if (value == null) return fallback;
  if (value is bool) return value;
  throw NativeDocumentCanvasException(
    'invalid-state',
    tr("{0} must be a boolean.", [path]),
  );
}

double _readNumber(Object? value, String path) {
  if (value is! num) {
    throw NativeDocumentCanvasException(
      'invalid-snapshot',
      tr("{0} must be a finite number.", [path]),
    );
  }
  final result = value.toDouble();
  if (!result.isFinite || result.abs() > 1e9) {
    throw NativeDocumentCanvasException(
      'invalid-snapshot',
      tr("{0} is outside the finite coordinate limit.", [path]),
    );
  }
  return result;
}

double _optionalNumber(Object? value, double fallback, String path) =>
    value == null ? fallback : _readNumber(value, path);

List<double> _numberList(
  Object? raw,
  String path, {
  int? expectedLength,
  int? maxLength,
}) {
  if (raw is! List<Object?>) {
    throw NativeDocumentCanvasException(
      'invalid-snapshot',
      tr("{0} must be a number array.", [path]),
    );
  }
  if ((expectedLength != null && raw.length != expectedLength) ||
      (maxLength != null && raw.length > maxLength)) {
    throw NativeDocumentCanvasException(
      'invalid-snapshot',
      tr("{0} has an invalid number of items.", [path]),
    );
  }
  return List.generate(
    raw.length,
    (index) => _readNumber(raw[index], '$path[$index]'),
    growable: false,
  );
}

Never _invalid(String path, String message) =>
    throw NativeDocumentCanvasException('invalid-snapshot', '$path: $message');

const _namedCanvasColors = <String, int>{
  'aliceblue': 0xfff0f8ff,
  'antiquewhite': 0xfffaebd7,
  'aqua': 0xff00ffff,
  'aquamarine': 0xff7fffd4,
  'azure': 0xfff0ffff,
  'beige': 0xfff5f5dc,
  'bisque': 0xffffe4c4,
  'black': 0xff000000,
  'blanchedalmond': 0xffffebcd,
  'blue': 0xff0000ff,
  'blueviolet': 0xff8a2be2,
  'brown': 0xffa52a2a,
  'burlywood': 0xffdeb887,
  'cadetblue': 0xff5f9ea0,
  'chartreuse': 0xff7fff00,
  'chocolate': 0xffd2691e,
  'coral': 0xffff7f50,
  'cornflowerblue': 0xff6495ed,
  'cornsilk': 0xfffff8dc,
  'crimson': 0xffdc143c,
  'cyan': 0xff00ffff,
  'darkblue': 0xff00008b,
  'darkcyan': 0xff008b8b,
  'darkgoldenrod': 0xffb8860b,
  'darkgray': 0xffa9a9a9,
  'darkgreen': 0xff006400,
  'darkgrey': 0xffa9a9a9,
  'darkkhaki': 0xffbdb76b,
  'darkmagenta': 0xff8b008b,
  'darkolivegreen': 0xff556b2f,
  'darkorange': 0xffff8c00,
  'darkorchid': 0xff9932cc,
  'darkred': 0xff8b0000,
  'darksalmon': 0xffe9967a,
  'darkseagreen': 0xff8fbc8f,
  'darkslateblue': 0xff483d8b,
  'darkslategray': 0xff2f4f4f,
  'darkslategrey': 0xff2f4f4f,
  'darkturquoise': 0xff00ced1,
  'darkviolet': 0xff9400d3,
  'deeppink': 0xffff1493,
  'deepskyblue': 0xff00bfff,
  'dimgray': 0xff696969,
  'dimgrey': 0xff696969,
  'dodgerblue': 0xff1e90ff,
  'firebrick': 0xffb22222,
  'floralwhite': 0xfffffaf0,
  'forestgreen': 0xff228b22,
  'fuchsia': 0xffff00ff,
  'gainsboro': 0xffdcdcdc,
  'ghostwhite': 0xfff8f8ff,
  'gold': 0xffffd700,
  'goldenrod': 0xffdaa520,
  'gray': 0xff808080,
  'green': 0xff008000,
  'greenyellow': 0xffadff2f,
  'grey': 0xff808080,
  'honeydew': 0xfff0fff0,
  'hotpink': 0xffff69b4,
  'indianred': 0xffcd5c5c,
  'indigo': 0xff4b0082,
  'ivory': 0xfffffff0,
  'khaki': 0xfff0e68c,
  'lavender': 0xffe6e6fa,
  'lavenderblush': 0xfffff0f5,
  'lawngreen': 0xff7cfc00,
  'lemonchiffon': 0xfffffacd,
  'lightblue': 0xffadd8e6,
  'lightcoral': 0xfff08080,
  'lightcyan': 0xffe0ffff,
  'lightgoldenrodyellow': 0xfffafad2,
  'lightgray': 0xffd3d3d3,
  'lightgreen': 0xff90ee90,
  'lightgrey': 0xffd3d3d3,
  'lightpink': 0xffffb6c1,
  'lightsalmon': 0xffffa07a,
  'lightseagreen': 0xff20b2aa,
  'lightskyblue': 0xff87cefa,
  'lightslategray': 0xff778899,
  'lightslategrey': 0xff778899,
  'lightsteelblue': 0xffb0c4de,
  'lightyellow': 0xffffffe0,
  'lime': 0xff00ff00,
  'limegreen': 0xff32cd32,
  'linen': 0xfffaf0e6,
  'magenta': 0xffff00ff,
  'maroon': 0xff800000,
  'mediumaquamarine': 0xff66cdaa,
  'mediumblue': 0xff0000cd,
  'mediumorchid': 0xffba55d3,
  'mediumpurple': 0xff9370db,
  'mediumseagreen': 0xff3cb371,
  'mediumslateblue': 0xff7b68ee,
  'mediumspringgreen': 0xff00fa9a,
  'mediumturquoise': 0xff48d1cc,
  'mediumvioletred': 0xffc71585,
  'midnightblue': 0xff191970,
  'mintcream': 0xfff5fffa,
  'mistyrose': 0xffffe4e1,
  'moccasin': 0xffffe4b5,
  'navajowhite': 0xffffdead,
  'navy': 0xff000080,
  'oldlace': 0xfffdf5e6,
  'olive': 0xff808000,
  'olivedrab': 0xff6b8e23,
  'orange': 0xffffa500,
  'orangered': 0xffff4500,
  'orchid': 0xffda70d6,
  'palegoldenrod': 0xffeee8aa,
  'palegreen': 0xff98fb98,
  'paleturquoise': 0xffafeeee,
  'palevioletred': 0xffdb7093,
  'papayawhip': 0xffffefd5,
  'peachpuff': 0xffffdab9,
  'peru': 0xffcd853f,
  'pink': 0xffffc0cb,
  'plum': 0xffdda0dd,
  'powderblue': 0xffb0e0e6,
  'purple': 0xff800080,
  'rebeccapurple': 0xff663399,
  'red': 0xffff0000,
  'rosybrown': 0xffbc8f8f,
  'royalblue': 0xff4169e1,
  'saddlebrown': 0xff8b4513,
  'salmon': 0xfffa8072,
  'sandybrown': 0xfff4a460,
  'seagreen': 0xff2e8b57,
  'seashell': 0xfffff5ee,
  'sienna': 0xffa0522d,
  'silver': 0xffc0c0c0,
  'skyblue': 0xff87ceeb,
  'slateblue': 0xff6a5acd,
  'slategray': 0xff708090,
  'slategrey': 0xff708090,
  'snow': 0xfffffafa,
  'springgreen': 0xff00ff7f,
  'steelblue': 0xff4682b4,
  'tan': 0xffd2b48c,
  'teal': 0xff008080,
  'thistle': 0xffd8bfd8,
  'tomato': 0xffff6347,
  'turquoise': 0xff40e0d0,
  'violet': 0xffee82ee,
  'wheat': 0xfff5deb3,
  'white': 0xffffffff,
  'whitesmoke': 0xfff5f5f5,
  'yellow': 0xffffff00,
  'yellowgreen': 0xff9acd32,
};
