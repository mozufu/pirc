import 'package:flutter/painting.dart';

/// A CSS background-position value resolved against the image's positioning area.
class NativeBackgroundImagePosition {
  const NativeBackgroundImagePosition._(this._x, this._y);

  final _BackgroundPositionAxis _x;
  final _BackgroundPositionAxis _y;

  static NativeBackgroundImagePosition? tryParse(String source) {
    final trimmed = source.trim().toLowerCase();
    if (trimmed.isEmpty) return null;
    final tokens = trimmed.split(RegExp(r'\s+'));
    if (tokens.length > 4) return null;

    if (tokens.length == 1) {
      final value = _positionValue(tokens.single);
      if (value == null) return null;
      final axis = _sideAxis(tokens.single);
      return axis == _PositionAxis.vertical
          ? NativeBackgroundImagePosition._(_center, value)
          : NativeBackgroundImagePosition._(value, _center);
    }

    if (tokens.length == 2) {
      final firstAxis = _sideAxis(tokens[0]);
      final secondAxis = _sideAxis(tokens[1]);
      final first = _positionValue(tokens[0]);
      final second = _positionValue(tokens[1]);
      if (first == null || second == null) return null;

      if (firstAxis != null && secondAxis != null) {
        if (firstAxis == secondAxis) return null;
        return firstAxis == _PositionAxis.horizontal
            ? NativeBackgroundImagePosition._(first, second)
            : NativeBackgroundImagePosition._(second, first);
      }
      final firstNumeric = _parseLength(tokens[0]) != null;
      final secondNumeric = _parseLength(tokens[1]) != null;
      if ((secondNumeric && firstAxis == _PositionAxis.vertical) ||
          (firstNumeric && secondAxis == _PositionAxis.horizontal)) {
        return null;
      }
      if (!firstNumeric && !secondNumeric) {
        if (firstAxis == _PositionAxis.vertical ||
            secondAxis == _PositionAxis.horizontal) {
          return NativeBackgroundImagePosition._(second, first);
        }
      }
      return NativeBackgroundImagePosition._(first, second);
    }

    _BackgroundPositionAxis? x;
    _BackgroundPositionAxis? y;
    var centers = 0;
    void assign(_PositionAxis axis, _BackgroundPositionAxis value) {
      if (axis == _PositionAxis.horizontal) {
        if (x != null) throw const FormatException();
        x = value;
      } else {
        if (y != null) throw const FormatException();
        y = value;
      }
    }

    try {
      for (var i = 0; i < tokens.length; i++) {
        final token = tokens[i];
        final axis = _sideAxis(token);
        if (axis != null) {
          final side = _sideValue(token)!;
          if (i + 1 < tokens.length) {
            final offset = _parseLength(tokens[i + 1]);
            if (offset != null) {
              assign(
                axis,
                _BackgroundPositionAxis(
                  offset.value,
                  offset.percent,
                  side.fromEnd,
                ),
              );
              i++;
              continue;
            }
          }
          assign(axis, side);
          continue;
        }
        if (token == 'center') {
          centers++;
          continue;
        }
        // A length in a three- or four-value position must follow an edge.
        return null;
      }
      for (var i = 0; i < centers; i++) {
        if (x == null) {
          x = _center;
        } else if (y == null) {
          y = _center;
        } else {
          return null;
        }
      }
    } on FormatException {
      return null;
    }
    if (x == null || y == null) return null;
    return NativeBackgroundImagePosition._(x!, y!);
  }

  /// Returns the tile's top-left origin relative to the positioning box.
  Offset resolve(Size box, Size tile) => Offset(
    _x.resolve(box.width - tile.width),
    _y.resolve(box.height - tile.height),
  );

  @override
  bool operator ==(Object other) =>
      other is NativeBackgroundImagePosition &&
      _x == other._x &&
      _y == other._y;

  @override
  int get hashCode => Object.hash(_x, _y);
}

enum _PositionAxis { horizontal, vertical }

class _BackgroundPositionAxis {
  const _BackgroundPositionAxis(this.value, this.percent, this.fromEnd);

  final double value;
  final bool percent;
  final bool fromEnd;

  double resolve(double freeSpace) {
    final offset = percent ? freeSpace * value / 100 : value;
    return fromEnd ? freeSpace - offset : offset;
  }

  @override
  bool operator ==(Object other) =>
      other is _BackgroundPositionAxis &&
      value == other.value &&
      percent == other.percent &&
      fromEnd == other.fromEnd;

  @override
  int get hashCode => Object.hash(value, percent, fromEnd);
}

const _center = _BackgroundPositionAxis(50, true, false);

_PositionAxis? _sideAxis(String token) => switch (token) {
  'left' || 'right' => _PositionAxis.horizontal,
  'top' || 'bottom' => _PositionAxis.vertical,
  _ => null,
};

_BackgroundPositionAxis? _sideValue(String token) => switch (token) {
  'left' || 'top' => const _BackgroundPositionAxis(0, false, false),
  'right' || 'bottom' => const _BackgroundPositionAxis(0, false, true),
  _ => null,
};

_BackgroundPositionAxis? _positionValue(String token) {
  if (token == 'center') return _center;
  final axis = _sideAxis(token);
  if (axis != null) return _sideValue(token);
  final length = _parseLength(token);
  return length == null
      ? null
      : _BackgroundPositionAxis(length.value, length.percent, false);
}

({double value, bool percent})? _parseLength(String token) {
  final match = RegExp(
    r'^([+-]?(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+))(px|%)?$',
  ).firstMatch(token);
  if (match == null) return null;
  final value = double.tryParse(match[1]!);
  if (value == null || !value.isFinite) return null;
  final unit = match[2];
  if (unit == null && value != 0) return null;
  return (value: value, percent: unit == '%');
}
