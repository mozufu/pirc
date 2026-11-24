import 'dart:math' as math;
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

class _TransformLength {
  const _TransformLength(this.value, this.unit);
  final double value;
  final String unit;
  static _TransformLength? parse(String raw) {
    final m = RegExp(
      r'^([+-]?(?:\d*\.\d+|\d+\.?\d*)(?:e[+-]?\d+)?)(%|px|em|pt|pc|in|cm|mm|vw|vh|vmin|vmax)?$',
      caseSensitive: false,
    ).firstMatch(raw);
    if (m == null) return null;
    final n = double.tryParse(m[1]!);
    if (n == null || !n.isFinite || (m[2] == null && n != 0)) return null;
    return _TransformLength(n, m[2]?.toLowerCase() ?? 'px');
  }

  double resolve(double basis, double font, Size viewport) =>
      value *
      switch (unit) {
        '%' => basis / 100,
        'em' => font,
        'pt' => 96 / 72,
        'pc' => 16,
        'in' => 96,
        'cm' => 96 / 2.54,
        'mm' => 96 / 25.4,
        'vw' => viewport.width / 100,
        'vh' => viewport.height / 100,
        'vmin' => math.min(viewport.width, viewport.height) / 100,
        'vmax' => math.max(viewport.width, viewport.height) / 100,
        _ => 1,
      };
}

class _TransformOperation {
  const _TransformOperation(this.name, this.numbers, this.lengths);
  final String name;
  final List<double> numbers;
  final List<_TransformLength> lengths;
}

/// Finite CSS 2D functions. Paint/hit-test matrices use the laid-out border box;
/// transforms do not change its normal-flow allocation.
class NativeDocumentTransformSpec {
  NativeDocumentTransformSpec._(this._operations, this._originX, this._originY);
  final List<_TransformOperation> _operations;
  final _TransformLength _originX, _originY;
  static NativeDocumentTransformSpec? parse(String? text, {String? origin}) {
    if (text == null || text.trim().isEmpty || text.trim() == 'none') {
      return null;
    }
    final operations = <_TransformOperation>[],
        pattern = RegExp(r'([a-zA-Z]+)\(([^()]*)\)');
    var end = 0;
    for (final match in pattern.allMatches(text)) {
      if (text.substring(end, match.start).trim().isNotEmpty) return null;
      end = match.end;
      final name = match[1]!.toLowerCase(),
          args = match[2]!.split(',').map((s) => s.trim()).toList();
      final numbers = <double>[], lengths = <_TransformLength>[];
      if (const {'translate', 'translatex', 'translatey'}.contains(name)) {
        if (args.isEmpty || args.length > (name == 'translate' ? 2 : 1)) {
          return null;
        }
        for (final arg in args) {
          final n = _TransformLength.parse(arg);
          if (n == null) return null;
          lengths.add(n);
        }
      } else if (const {'scale', 'scalex', 'scaley', 'matrix'}.contains(name)) {
        if (name == 'matrix'
            ? args.length != 6
            : args.isEmpty || args.length > (name == 'scale' ? 2 : 1)) {
          return null;
        }
        for (final arg in args) {
          final n = double.tryParse(arg);
          if (n == null || !n.isFinite) return null;
          numbers.add(n);
        }
      } else if (const {'rotate', 'skew', 'skewx', 'skewy'}.contains(name)) {
        if (args.isEmpty || args.length > (name == 'skew' ? 2 : 1)) return null;
        for (final arg in args) {
          final m = RegExp(
            r'^([+-]?(?:\d*\.\d+|\d+\.?\d*)(?:e[+-]?\d+)?)(deg|rad|turn|grad)?$',
            caseSensitive: false,
          ).firstMatch(arg);
          if (m == null) return null;
          final n = double.tryParse(m[1]!);
          if (n == null || !n.isFinite || (m[2] == null && n != 0)) return null;
          numbers.add(
            n *
                switch (m[2]?.toLowerCase()) {
                  'deg' => math.pi / 180,
                  'turn' => 2 * math.pi,
                  'grad' => math.pi / 200,
                  _ => 1,
                },
          );
        }
      } else {
        return null;
      }
      operations.add(_TransformOperation(name, numbers, lengths));
      if (operations.length > 64) return null;
    }
    if (operations.isEmpty || text.substring(end).trim().isNotEmpty) {
      return null;
    }
    final point = _parseOrigin(origin);
    if (point == null) return null;
    return NativeDocumentTransformSpec._(
      List.unmodifiable(operations),
      point.$1,
      point.$2,
    );
  }

  static (_TransformLength, _TransformLength)? _parseOrigin(String? text) {
    final tokens = (text ?? '50% 50%').trim().toLowerCase().split(
      RegExp(r'\s+'),
    );
    if (tokens.isEmpty || tokens.length > 2) return null;
    var x = tokens[0], y = tokens.length == 1 ? 'center' : tokens[1];
    if (const {'top', 'bottom'}.contains(x) ||
        const {'left', 'right'}.contains(y)) {
      final old = x;
      x = y;
      y = old;
    }
    _TransformLength? point(String s, bool horizontal) => switch (s) {
      'center' => const _TransformLength(50, '%'),
      'left' => horizontal ? const _TransformLength(0, '%') : null,
      'right' => horizontal ? const _TransformLength(100, '%') : null,
      'top' => !horizontal ? const _TransformLength(0, '%') : null,
      'bottom' => !horizontal ? const _TransformLength(100, '%') : null,
      _ => _TransformLength.parse(s),
    };
    final ox = point(x, true), oy = point(y, false);
    if (ox == null || oy == null) return null;
    return (ox, oy);
  }

  // CSSOM serializes matrix components with six significant digits. The
  // origin is reported separately and is not folded into the matrix value.
  static String _cssNumber(double value) {
    if (value == 0) return '0';
    var parts = value.toStringAsPrecision(6).toLowerCase().split('e');
    var mantissa = parts[0];
    if (mantissa.contains('.')) {
      mantissa = mantissa
          .replaceFirst(RegExp(r'0+$'), '')
          .replaceFirst(RegExp(r'\.$'), '');
    }
    if (parts.length == 1) return mantissa;
    final exponent = int.parse(parts[1]);
    return '${mantissa}e${exponent >= 0 ? '+' : ''}$exponent';
  }

  static String? computedOrigin(
    String? text, {
    Size? size,
    double fontSize = 16,
    Size viewport = Size.zero,
  }) {
    final point = _parseOrigin(text);
    if (point == null) return null;
    String? component(_TransformLength length, double? basis) {
      if (length.unit == '%' && basis == null) {
        return '${_cssNumber(length.value)}%';
      }
      final value = length.resolve(basis ?? 0, fontSize, viewport);
      return value.isFinite ? '${_cssNumber(value)}px' : null;
    }

    final x = component(point.$1, size?.width),
        y = component(point.$2, size?.height);
    return x == null || y == null ? null : '$x $y';
  }

  String? computedMatrix(
    Size size, {
    double fontSize = 16,
    Size viewport = Size.zero,
  }) {
    final m = resolve(
      size,
      fontSize: fontSize,
      viewport: viewport,
      includeOrigin: false,
    ).storage;
    final components = [m[0], m[1], m[4], m[5], m[12], m[13]];
    if (components.any((value) => !value.isFinite)) return null;
    return 'matrix(${components.map(_cssNumber).join(', ')})';
  }

  Matrix4 resolve(
    Size size, {
    double fontSize = 16,
    Size viewport = Size.zero,
    Offset borderOffset = Offset.zero,
    bool includeOrigin = true,
  }) {
    final origin = !includeOrigin
        ? Offset.zero
        : borderOffset +
              Offset(
                _originX.resolve(size.width, fontSize, viewport),
                _originY.resolve(size.height, fontSize, viewport),
              );
    final result = Matrix4.translationValues(origin.dx, origin.dy, 0);
    for (final op in _operations) {
      final n = op.numbers, l = op.lengths;
      final next = Matrix4.identity();
      switch (op.name) {
        case 'translate':
          next.translateByDouble(
            l[0].resolve(size.width, fontSize, viewport),
            l.length > 1 ? l[1].resolve(size.height, fontSize, viewport) : 0,
            0,
            1,
          );
        case 'translatex':
          next.translateByDouble(
            l[0].resolve(size.width, fontSize, viewport),
            0,
            0,
            1,
          );
        case 'translatey':
          next.translateByDouble(
            0,
            l[0].resolve(size.height, fontSize, viewport),
            0,
            1,
          );
        case 'scale':
          next.scaleByDouble(n[0], n.length > 1 ? n[1] : n[0], 1, 1);
        case 'scalex':
          next.scaleByDouble(n[0], 1, 1, 1);
        case 'scaley':
          next.scaleByDouble(1, n[0], 1, 1);
        case 'rotate':
          next.rotateZ(n[0]);
        case 'skew':
          next.setEntry(0, 1, math.tan(n[0]));
          next.setEntry(1, 0, n.length > 1 ? math.tan(n[1]) : 0);
        case 'skewx':
          next.setEntry(0, 1, math.tan(n[0]));
        case 'skewy':
          next.setEntry(1, 0, math.tan(n[0]));
        case 'matrix':
          next.setEntry(0, 0, n[0]);
          next.setEntry(1, 0, n[1]);
          next.setEntry(0, 1, n[2]);
          next.setEntry(1, 1, n[3]);
          next.setEntry(0, 3, n[4]);
          next.setEntry(1, 3, n[5]);
      }
      result.multiply(next);
    }
    return result..translateByDouble(-origin.dx, -origin.dy, 0, 1);
  }
}

class NativeDocumentTransform extends SingleChildRenderObjectWidget {
  const NativeDocumentTransform({
    super.key,
    required this.spec,
    required this.viewport,
    required this.fontSize,
    this.boxGeometry,
    required super.child,
  });
  final NativeDocumentTransformSpec spec;
  final Size viewport;
  final double fontSize;
  final ({RenderBox surface, Size size})? Function(RenderBox)? boxGeometry;
  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderDocumentTransform(this);
  @override
  void updateRenderObject(
    BuildContext context,
    covariant RenderTransform renderObject,
  ) => (renderObject as _RenderDocumentTransform).update(this);
}

/// CSSOM offset coordinates ignore this CSS paint transform, including singular
/// matrices. Other framework transforms still require explicit measurement.
bool nativeDocumentIsCssTransform(RenderObject object) =>
    object is _RenderDocumentTransform;

class _RenderDocumentTransform extends RenderTransform {
  _RenderDocumentTransform(this.config) : super(transform: Matrix4.identity());
  NativeDocumentTransform config;
  void update(NativeDocumentTransform value) {
    config = value;
    markNeedsLayout();
  }

  @override
  void performLayout() {
    super.performLayout();
    final c = child;
    if (c == null) return;
    final geometry = config.boxGeometry?.call(c);
    final surface = geometry?.surface ?? c;
    final offset = MatrixUtils.transformPoint(
      surface.getTransformTo(c),
      Offset.zero,
    );
    transform = config.spec.resolve(
      geometry?.size ?? c.size,
      fontSize: config.fontSize,
      viewport: config.viewport,
      borderOffset: offset,
    );
  }
}
