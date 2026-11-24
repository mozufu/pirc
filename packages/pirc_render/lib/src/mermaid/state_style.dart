import 'dart:ui';

/// CSS colors supported by the native state painter. Returning null lets the
/// parser reject unsupported values before declaring the diagram rendered.
Color? parseNativeMermaidStateColor(String? input) {
  if (input == null) return null;
  final value = input.trim().toLowerCase();
  const named = {
    'black': 0xff000000,
    'white': 0xffffffff,
    'red': 0xffff0000,
    'green': 0xff008000,
    'blue': 0xff0000ff,
    'yellow': 0xffffff00,
    'gray': 0xff808080,
    'grey': 0xff808080,
    'orange': 0xffffa500,
    'silver': 0xffc0c0c0,
    'maroon': 0xff800000,
    'purple': 0xff800080,
    'fuchsia': 0xffff00ff,
    'lime': 0xff00ff00,
    'olive': 0xff808000,
    'navy': 0xff000080,
    'teal': 0xff008080,
    'aqua': 0xff00ffff,
    'transparent': 0x00000000,
  };
  if (named.containsKey(value)) return Color(named[value]!);
  if (RegExp(
    r'^#(?:[a-f0-9]{3}|[a-f0-9]{4}|[a-f0-9]{6}|[a-f0-9]{8})$',
  ).hasMatch(value)) {
    var hex = value.substring(1);
    if (hex.length == 3 || hex.length == 4) {
      hex = hex.split('').map((c) => c + c).join();
    }
    final number = int.parse(hex, radix: 16);
    return hex.length == 6
        ? Color(0xff000000 | number)
        : Color(((number & 255) << 24) | (number >> 8));
  }
  final function = RegExp(r'^(rgb|rgba)\(([^)]+)\)$').firstMatch(value);
  if (function == null) return null;
  final body = function.group(2)!;
  final List<String> parts;
  if (body.contains(',')) {
    parts = body.split(',').map((v) => v.trim()).toList();
    if (parts.length != (function.group(1) == 'rgba' ? 4 : 3)) return null;
  } else {
    final slash = body.split('/');
    if (slash.length > 2) return null;
    parts = slash[0].trim().split(RegExp(r'\s+'));
    if (parts.length != 3) return null;
    if (slash.length == 2) parts.add(slash[1].trim());
  }
  double? component(String source, double percentScale) {
    if (!RegExp(r'^[+-]?(?:\d+(?:\.\d*)?|\.\d+)%?$').hasMatch(source)) {
      return null;
    }
    final percent = source.endsWith('%');
    final number = double.tryParse(
      percent ? source.substring(0, source.length - 1) : source,
    );
    if (number == null || !number.isFinite) return null;
    return percent ? number * percentScale : number;
  }

  final channels = parts.take(3).map((s) => component(s, 2.55)).toList();
  final alpha = parts.length == 4 ? component(parts[3], .01) : 1.0;
  if (channels.any((c) => c == null) || alpha == null) return null;
  return Color.fromRGBO(
    channels[0]!.round().clamp(0, 255),
    channels[1]!.round().clamp(0, 255),
    channels[2]!.round().clamp(0, 255),
    alpha.clamp(0, 1),
  );
}
