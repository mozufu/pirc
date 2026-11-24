import 'package:flutter/material.dart';

// Mermaid 11.17.2 base/dark cScale and cScaleInv palettes, with Pirc's
// pinned initialization colors. Shared diagram palettes retain source values.
Color mermaidClassicSectionColor(int index, bool dark) {
  if (dark) {
    const values = [
      0xff1f2020,
      0xff0b0000,
      0xff4d1037,
      0xff3f5258,
      0xff4f2f1b,
      0xff6e0a0a,
      0xff3b0048,
      0xff995a01,
      0xff154706,
      0xff161722,
      0xff00296f,
      0xff01629c,
    ];
    return Color(values[index % values.length]);
  }
  const hues = [
    218.8235294118,
    210.0,
    210.0,
    248.8235294118,
    278.8235294118,
    308.8235294118,
    338.8235294118,
    8.8235294118,
    68.8235294118,
    128.8235294118,
    158.8235294118,
    188.8235294118,
  ];
  final saturation = index == 1
      ? 16.6666666667
      : index == 2
      ? 20.0
      : 89.4736842105;
  final lightness = index == 1
      ? 70.2941176471
      : index == 2
      ? 73.0392156863
      : index == 8
      ? 75.0
      : 71.2745098039;
  return HSLColor.fromAHSL(
    1,
    hues[index % 12],
    saturation / 100,
    lightness / 100,
  ).toColor();
}

Color mermaidClassicInverseColor(int index, bool dark) {
  if (dark) {
    const values = [
      0xffe0dfdf,
      0xfff4ffff,
      0xffb2efc8,
      0xffc0ada7,
      0xffb0d0e4,
      0xff91f5f5,
      0xffc4ffb7,
      0xff66a5fe,
      0xffeab8f9,
      0xffe9e8dd,
      0xffffd690,
      0xfffe9d63,
    ];
    return Color(values[index % 12]);
  }
  const rgb = [
    (139, 93, 8),
    (88, 76, 63),
    (82, 69, 55),
    (120, 139, 8),
    (54, 139, 8),
    (8, 139, 27),
    (8, 139, 93),
    (8, 120, 139),
    (23, 7, 121),
    (139, 8, 120),
    (139, 8, 54),
    (139, 27, 8),
  ];
  final value = rgb[index % 12];
  return Color.fromARGB(255, value.$1, value.$2, value.$3);
}
