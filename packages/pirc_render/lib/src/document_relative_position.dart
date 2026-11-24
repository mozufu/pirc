import 'package:flutter/widgets.dart';

const _relativeZeroLengthUnits = <String>{
  'px',
  'cm',
  'mm',
  'q',
  'in',
  'pt',
  'pc',
  'em',
  'rem',
  'ex',
  'rex',
  'cap',
  'rcap',
  'ch',
  'rch',
  'ic',
  'ric',
  'lh',
  'rlh',
  'vw',
  'vh',
  'vi',
  'vb',
  'vmin',
  'vmax',
  'svw',
  'svh',
  'svi',
  'svb',
  'svmin',
  'svmax',
  'lvw',
  'lvh',
  'lvi',
  'lvb',
  'lvmin',
  'lvmax',
  'dvw',
  'dvh',
  'dvi',
  'dvb',
  'dvmin',
  'dvmax',
  'cqw',
  'cqh',
  'cqi',
  'cqb',
  'cqmin',
  'cqmax',
};

class _NativeRelativeInset {
  const _NativeRelativeInset.auto()
    : value = 0,
      percentage = false,
      automatic = true;

  const _NativeRelativeInset.pixels(this.value)
    : percentage = false,
      automatic = false;

  const _NativeRelativeInset.percent(this.value)
    : percentage = true,
      automatic = false;

  final double value;
  final bool percentage;
  final bool automatic;

  double? resolve(double? basis) {
    if (automatic) return null;
    if (!percentage) return value;
    if (basis == null || !basis.isFinite || basis < 0) return null;
    final resolved = basis * value / 100;
    return resolved.isFinite ? resolved : null;
  }

  bool get isNoOp => automatic || value == 0;
}

const _nativeRelativeAuto = _NativeRelativeInset.auto();

/// Parsed physical insets for a CSS relatively positioned element.
///
/// Only the literal forms implemented by the native renderer are accepted:
/// signed px and percentage values, auto, and zero values in CSS length units.
/// Nonzero em/rem/vw/vh values require canonical lengths from the native cascade.
/// Percentages remain unresolved until the containing block's actual content
/// dimensions are available.
class NativeDocumentRelativePositionSpec {
  const NativeDocumentRelativePositionSpec._({
    required this._top,
    required this._right,
    required this._bottom,
    required this._left,
    required TextDirection direction,
  }) : _defaultDirection = direction;

  final _NativeRelativeInset _top;
  final _NativeRelativeInset _right;
  final _NativeRelativeInset _bottom;
  final _NativeRelativeInset _left;
  final TextDirection _defaultDirection;

  /// Parses a relative-position declaration map.
  ///
  /// A null result means the element is not relatively positioned or one of
  /// its effective insets is outside the supported physical px/percentage
  /// subset or lacks a reliable computed em/rem/vw/vh length. Zero logical
  /// insets are harmless and accepted; nonzero logical
  /// insets are rejected because their mapping depends on writing mode.
  static NativeDocumentRelativePositionSpec? parse(
    Map<String, String> styles, {
    TextDirection direction = TextDirection.ltr,
    Map<String, String> computedLengths = const {},
  }) {
    final declarations = <String, String>{
      for (final entry in styles.entries)
        entry.key.trim().toLowerCase(): entry.value,
    };
    if ((declarations['position'] ?? '').trim().toLowerCase() != 'relative') {
      return null;
    }

    final sides = <String, String>{
      'top': 'auto',
      'right': 'auto',
      'bottom': 'auto',
      'left': 'auto',
    };

    final shorthand = declarations['inset'];
    if (shorthand != null) {
      final tokens = _tokens(shorthand);
      if (tokens.isEmpty || tokens.length > 4) return null;
      final top = tokens[0];
      final right = tokens.length > 1 ? tokens[1] : top;
      final bottom = tokens.length > 2 ? tokens[2] : top;
      final left = tokens.length > 3 ? tokens[3] : right;
      sides
        ..['top'] = top
        ..['right'] = right
        ..['bottom'] = bottom
        ..['left'] = left;
    }

    for (final side in const ['top', 'right', 'bottom', 'left']) {
      final raw = declarations[side];
      if (raw == null) continue;
      sides[side] = raw;
    }
    final insets = <String, _NativeRelativeInset>{};
    for (final entry in sides.entries) {
      final parsed = _parseInset(
        entry.value,
        computedValue: computedLengths[entry.key],
      );
      if (parsed == null) return null;
      insets[entry.key] = parsed;
    }

    const logicalInsets = {
      'inset-inline',
      'inset-inline-start',
      'inset-inline-end',
      'inset-block',
      'inset-block-start',
      'inset-block-end',
    };
    for (final entry in declarations.entries) {
      final property = entry.key.trim().toLowerCase();
      if (!property.startsWith('inset-')) continue;
      if (!logicalInsets.contains(property) ||
          !_logicalInsetIsNoOp(entry.value)) {
        return null;
      }
    }

    return NativeDocumentRelativePositionSpec._(
      top: insets['top']!,
      right: insets['right']!,
      bottom: insets['bottom']!,
      left: insets['left']!,
      direction: direction,
    );
  }

  /// Resolves the visual displacement, leaving the element's flow size intact.
  ///
  /// Horizontal percentages use the containing block's content width.
  /// Vertical percentages use its definite content height; an unavailable
  /// percentage becomes auto. The direction is that of the containing block.
  Offset resolve({
    double? containingWidth,
    double? containingHeight,
    TextDirection? direction,
  }) {
    final left = _left.resolve(containingWidth);
    final right = _right.resolve(containingWidth);
    final top = _top.resolve(containingHeight);
    final bottom = _bottom.resolve(containingHeight);
    final resolvedDirection = direction ?? _defaultDirection;

    final dx = left != null && right != null
        ? resolvedDirection == TextDirection.ltr
              ? left
              : -right
        : left ?? (right == null ? 0 : -right);
    final dy = top != null && bottom != null
        ? top
        : top ?? (bottom == null ? 0 : -bottom);
    return Offset(dx, dy);
  }

  bool get isNoOp =>
      _top.isNoOp && _right.isNoOp && _bottom.isNoOp && _left.isNoOp;

  static List<String> _tokens(String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) return const [];
    return trimmed.split(RegExp(r'\s+'));
  }

  static bool _logicalInsetIsNoOp(String value) {
    final tokens = _tokens(value);
    if (tokens.isEmpty) return false;
    return tokens.every((token) {
      final parsed = _parseInset(token);
      return parsed?.isNoOp ?? false;
    });
  }

  static _NativeRelativeInset? _parseInset(
    String value, {
    String? computedValue,
  }) {
    final normalized = value.trim().toLowerCase();
    if (normalized == 'auto') return _nativeRelativeAuto;
    final match = RegExp(
      r'^([+-]?(?:\d+(?:\.\d*)?|\.\d+)(?:e[+-]?\d+)?)([a-z]+|%)?$',
      caseSensitive: false,
    ).firstMatch(normalized);
    if (match == null) return null;
    final number = double.tryParse(match.group(1)!);
    if (number == null || !number.isFinite) return null;
    final unit = match.group(2)?.toLowerCase();
    if (unit == 'px') return _NativeRelativeInset.pixels(number);
    if (unit == '%') return _NativeRelativeInset.percent(number);
    if (number == 0 &&
        (unit == null || _relativeZeroLengthUnits.contains(unit))) {
      return const _NativeRelativeInset.pixels(0);
    }
    if (const {'em', 'rem', 'vw', 'vh'}.contains(unit) &&
        computedValue != null) {
      // Use the cascade's reliable font/root-font/viewport result. Missing
      // bases must stay unsupported, never become guessed 16px/viewport values.
      final pixels = RegExp(
        r'^([+-]?(?:\d+(?:\.\d*)?|\.\d+)(?:e[+-]?\d+)?)px$',
        caseSensitive: false,
      ).firstMatch(computedValue.trim());
      final resolved = pixels == null
          ? null
          : double.tryParse(pixels.group(1)!);
      if (resolved == null || !resolved.isFinite) return null;
      return _NativeRelativeInset.pixels(resolved);
    }
    return null;
  }
}
