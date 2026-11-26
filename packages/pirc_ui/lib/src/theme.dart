import 'package:flutter/material.dart';

import 'token_types.dart';
import 'tokens.g.dart';

/// Semantic colors by token name (`surface.page`, `text.primary`, …) for the
/// current brightness. Widgets read colors only through this extension.
class PircColorTokens extends ThemeExtension<PircColorTokens> {
  const PircColorTokens(this.values);

  final Map<String, Color> values;

  Color operator [](String name) =>
      values[name] ?? (throw ArgumentError.value(name, 'color token'));

  static PircColorTokens of(BuildContext context) =>
      Theme.of(context).extension<PircColorTokens>()!;

  @override
  PircColorTokens copyWith({Map<String, Color>? values}) =>
      PircColorTokens(values ?? this.values);

  @override
  PircColorTokens lerp(covariant PircColorTokens? other, double t) =>
      other == null
      ? this
      : PircColorTokens({
          for (final key in values.keys)
            key: Color.lerp(values[key], other.values[key], t)!,
        });
}

/// Shadows for raised and floating surfaces; empty in dark mode where the
/// fill alone separates a surface (design rule: one separation per surface).
class PircElevationTokens extends ThemeExtension<PircElevationTokens> {
  const PircElevationTokens({
    required this.card,
    required this.float,
    required this.floatFocus,
    required this.pop,
  });

  final List<BoxShadow> card, float, floatFocus, pop;

  @override
  PircElevationTokens copyWith() => this;

  @override
  PircElevationTokens lerp(covariant PircElevationTokens? other, double t) =>
      t < 0.5 || other == null ? this : other;
}

/// Light and dark themes built from `docs/design/tokens.json`.
abstract final class PircTheme {
  static final _themes = <Brightness, ThemeData>{};

  /// Themes are cached: a stable identity avoids theme animations that would
  /// relayout every text block.
  static ThemeData of(Brightness brightness) =>
      _themes.putIfAbsent(brightness, () => _build(brightness));

  /// Color values for [brightness], including the terminal palette as
  /// `terminal.*`.
  static Map<String, Color> colors(Brightness brightness) => {
    ...(brightness == Brightness.dark ? pircDarkColors : pircLightColors),
    for (final MapEntry(:key, :value) in pircTerminalColors.entries)
      'terminal.$key': value,
  };

  static ThemeData _build(Brightness brightness) {
    final dark = brightness == Brightness.dark;
    final colors = PircColorTokens(PircTheme.colors(brightness));
    final scheme =
        ColorScheme.fromSeed(
          seedColor: colors['accent.default'],
          brightness: brightness,
        ).copyWith(
          primary: colors['accent.default'],
          onPrimary: colors['accent.on'],
          primaryContainer: colors['accent.soft'],
          onPrimaryContainer: colors['accent.onSoft'],
          surface: colors['surface.page'],
          onSurface: colors['text.primary'],
          onSurfaceVariant: colors['text.secondary'],
          surfaceContainerLowest: colors['surface.page'],
          surfaceContainerLow: colors['surface.sidebar'],
          surfaceContainer: colors['surface.layer'],
          surfaceContainerHigh: colors['surface.layer'],
          surfaceContainerHighest: colors['surface.subtle'],
          secondaryContainer: colors['surface.subtle'],
          onSecondaryContainer: colors['text.primary'],
          outline: colors['line.default'],
          outlineVariant: colors['line.hairline'],
          error: colors['status.danger'],
          errorContainer: colors['status.dangerSoft'],
          scrim: colors['scrim'],
        );
    TextStyle text(PircTypeSpec spec) => spec.style(
      color: spec.color == null ? colors['text.primary'] : colors[spec.color!],
    );
    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: scheme,
      scaffoldBackgroundColor: colors['surface.page'],
      dividerColor: colors['line.hairline'],
      extensions: [
        colors,
        PircElevationTokens(
          card: dark ? PircElevation.cardDark : PircElevation.cardLight,
          float: dark ? PircElevation.floatDark : PircElevation.floatLight,
          floatFocus: dark
              ? PircElevation.floatFocusDark
              : PircElevation.floatFocusLight,
          pop: dark ? PircElevation.popDark : PircElevation.popLight,
        ),
      ],
      textTheme: TextTheme(
        headlineSmall: text(PircType.display),
        titleLarge: text(PircType.titleSheet),
        titleMedium: text(PircType.titleCard),
        titleSmall: text(PircType.titleBar),
        bodyLarge: text(PircType.bodyReading),
        bodyMedium: text(PircType.row),
        bodySmall: text(PircType.secondary),
        labelLarge: text(PircType.button),
        labelMedium: text(PircType.labelSection),
        labelSmall: text(PircType.caption),
      ),
      materialTapTargetSize: MaterialTapTargetSize.padded,
      visualDensity: VisualDensity.standard,
      badgeTheme: BadgeThemeData(
        // Tab badges are yellow with white 10/700 text, 16 high (E).
        backgroundColor: colors['status.warning'],
        textColor: Colors.white,
        textStyle: const TextStyle(
          fontSize: 10,
          height: 1,
          fontWeight: FontWeight.w700,
        ),
        largeSize: 16,
      ),
      navigationBarTheme: NavigationBarThemeData(
        height: PircSize.tabBarHeight,
        backgroundColor: colors['surface.page'],
        indicatorColor: colors['accent.soft'],
        // `e-tab`: 11.5/14, 500; muted until chosen, then accent.
        labelTextStyle: WidgetStateProperty.resolveWith(
          (states) => TextStyle(
            fontSize: 11.5,
            height: 14 / 11.5,
            fontWeight: FontWeight.w500,
            color: states.contains(WidgetState.selected)
                ? colors['accent.pressed']
                : colors['text.muted'],
          ),
        ),
      ),
      navigationRailTheme: NavigationRailThemeData(
        backgroundColor: colors['surface.sidebar'],
        indicatorColor: colors['accent.soft'],
      ),
    );
  }
}
