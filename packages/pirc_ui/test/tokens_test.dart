import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_ui/pirc_ui.dart';

import '../tool/generate_tokens.dart';

void main() {
  test('tokens.g.dart is generated from the current tokens.json', () {
    // Whitespace and the formatter's trailing commas do not count.
    String compact(String source) => source
        .replaceAll(RegExp(r'\s+'), '')
        .replaceAllMapped(RegExp(r',([)\]}])'), (m) => m[1]!);
    expect(
      compact(File('lib/src/tokens.g.dart').readAsStringSync()),
      compact(generateTokens(File(tokensPath).readAsStringSync())),
      reason: 'Run `dart run tool/generate_tokens.dart` in packages/pirc_ui.',
    );
  });

  test('light and dark define the same color names', () {
    expect(pircDarkColors.keys.toSet(), pircLightColors.keys.toSet());
    expect(pircLightColors['accent.default'], const Color(0xFF4B6BA6));
  });

  test('breakpoints are ordered', () {
    expect(PircBreakpoints.portrait, lessThan(PircBreakpoints.landscape));
    expect(PircBreakpoints.landscape, lessThan(PircBreakpoints.desktop));
  });

  for (final brightness in Brightness.values) {
    test('the $brightness theme carries the token extensions', () {
      final theme = PircTheme.of(brightness);
      expect(theme.brightness, brightness);
      final colors = theme.extension<PircColorTokens>()!;
      expect(theme.colorScheme.primary, colors['accent.default']);
      expect(theme.scaffoldBackgroundColor, colors['surface.page']);
      expect(colors.values.keys, contains('terminal.bg'));
      expect(theme.extension<PircElevationTokens>(), isNotNull);
      expect(identical(PircTheme.of(brightness), theme), isTrue);
    });
  }
}
