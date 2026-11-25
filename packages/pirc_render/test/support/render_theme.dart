import 'package:flutter/material.dart';
import 'package:pirc_render/pirc_render.dart';

/// A theme carrying every color name the renderer reads.
ThemeData renderTestTheme([Brightness brightness = Brightness.light]) {
  final dark = brightness == Brightness.dark;
  const names = [
    'accent.default',
    'border.default',
    'code.bg',
    'code.head',
    'code.text',
    'line.default',
    'line.hairline',
    'line.strong',
    'status.danger',
    'surface.subtle',
    'text.muted',
    'text.primary',
    'text.secondary',
    'web.bg',
    'web.line',
    'web.muted',
  ];
  return ThemeData(
    brightness: brightness,
    extensions: [
      RenderColors({
        for (final name in names)
          name: dark ? const Color(0xFFDDDDDD) : const Color(0xFF333333),
      }),
    ],
  );
}
