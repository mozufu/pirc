import 'package:flutter/painting.dart';

/// One role of the type scale (`docs/design/tokens.json` → `typography`).
class PircTypeSpec {
  const PircTypeSpec({
    required this.size,
    this.lineHeight,
    this.weight = 400,
    this.letterSpacing,
    this.color,
  });

  final double size;
  final double? lineHeight;
  final int weight;
  final double? letterSpacing;

  /// A color token name such as `text.muted`, resolved by the theme.
  final String? color;

  TextStyle style({Color? color, String? fontFamily}) => TextStyle(
    fontFamily: fontFamily,
    fontSize: size,
    height: lineHeight == null ? null : lineHeight! / size,
    fontWeight: FontWeight.values[(weight ~/ 100 - 1).clamp(0, 8)],
    letterSpacing: letterSpacing,
    color: color,
  );
}
