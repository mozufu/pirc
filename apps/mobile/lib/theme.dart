import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class PircColors extends ThemeExtension<PircColors> {
  const PircColors(this.values);
  final Map<String, Color> values;
  Color operator [](String key) => values[key]!;
  @override
  PircColors copyWith({Map<String, Color>? values}) =>
      PircColors(values ?? this.values);
  @override
  PircColors lerp(covariant PircColors? other, double t) => other == null
      ? this
      : PircColors({
          for (final key in values.keys)
            key: Color.lerp(values[key], other.values[key], t)!,
        });
}

class PircTheme {
  PircTheme(this.tokens);
  final Map<String, dynamic> tokens;
  static Future<PircTheme> load() async => PircTheme(
    jsonDecode(await rootBundle.loadString('assets/design-tokens.json'))
        as Map<String, dynamic>,
  );
  ThemeData build(Brightness brightness) {
    final raw =
        tokens['color'][brightness == Brightness.dark ? 'dark' : 'light']
            as Map<String, dynamic>;
    final colors = PircColors({
      ...raw.map((key, value) => MapEntry(key, parse(value as String))),
      for (final e
          in (tokens['color']['terminal'] as Map<String, dynamic>).entries)
        if (!e.key.startsWith(r'$'))
          'terminal.${e.key}': parse(e.value as String),
    });
    final scheme =
        ColorScheme.fromSeed(
          seedColor: colors['accent.default'],
          brightness: brightness,
        ).copyWith(
          primary: colors['accent.default'],
          surface: colors['surface.page'],
          onSurface: colors['text.primary'],
          onSurfaceVariant: colors['text.secondary'],
          onPrimary: colors['accent.on'],
          primaryContainer: colors['accent.soft'],
          onPrimaryContainer: colors['accent.onSoft'],
          secondaryContainer: colors['surface.subtle'],
          onSecondaryContainer: colors['text.primary'],
          surfaceContainerHighest: colors['surface.subtle'],
          surfaceContainerHigh: colors['surface.layer'],
          surfaceContainer: colors['surface.layer'],
          surfaceContainerLow: colors['surface.sidebar'],
          outline: colors['line.default'],
          outlineVariant: colors['line.hairline'],
          error: colors['status.danger'],
          errorContainer: colors['status.dangerSoft'],
        );
    final fontFamily = ThemeData(
      brightness: brightness,
    ).textTheme.bodyMedium!.fontFamily;
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: colors['surface.page'],
      extensions: [colors],
      textTheme: TextTheme(
        headlineSmall: TextStyle(
          fontFamily: fontFamily,
          fontSize: 24,
          height: 32 / 24,
          fontWeight: FontWeight.w600,
          color: colors['text.primary'],
        ),
        titleLarge: TextStyle(
          fontFamily: fontFamily,
          fontSize: 20,
          height: 28 / 20,
          fontWeight: FontWeight.w600,
          color: colors['text.primary'],
        ),
        titleMedium: TextStyle(
          fontFamily: fontFamily,
          fontSize: 16,
          height: 22 / 16,
          fontWeight: FontWeight.w600,
          color: colors['text.primary'],
        ),
        bodyLarge: TextStyle(
          fontFamily: fontFamily,
          fontSize: 16,
          height: 28 / 16,
          color: colors['text.primary'],
        ),
        bodyMedium: TextStyle(
          fontFamily: fontFamily,
          fontSize: 15,
          height: 22 / 15,
          color: colors['text.primary'],
        ),
        bodySmall: TextStyle(
          fontFamily: fontFamily,
          fontSize: 13,
          height: 18 / 13,
          color: colors['text.secondary'],
        ),
        labelLarge: TextStyle(
          fontFamily: fontFamily,
          fontSize: 15,
          height: 20 / 15,
          fontWeight: FontWeight.w500,
          color: colors['text.primary'],
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: colors['surface.layer'],
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: colors['surface.layer'],
        surfaceTintColor: Colors.transparent,
        modalBarrierColor: colors['scrim'],
        showDragHandle: true,
        dragHandleColor: colors['line.strong'],
        dragHandleSize: const Size(36, 5),
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
        ),
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: colors['surface.layer'],
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: colors['text.primary'],
        contentTextStyle: TextStyle(
          fontFamily: fontFamily,
          color: colors['surface.page'],
          fontSize: 14,
          height: 20 / 14,
        ),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        insetPadding: const EdgeInsets.fromLTRB(16, 8, 16, 120),
      ),
      dividerTheme: DividerThemeData(
        color: colors['line.hairline'],
        thickness: 1,
      ),
      listTileTheme: ListTileThemeData(
        iconColor: colors['text.secondary'],
        selectedTileColor: colors['fill.active'],
        titleTextStyle: TextStyle(
          fontFamily: fontFamily,
          fontSize: 15,
          height: 22 / 15,
          color: colors['text.primary'],
        ),
        subtitleTextStyle: TextStyle(
          fontFamily: fontFamily,
          fontSize: 13,
          height: 18 / 13,
          color: colors['text.muted'],
        ),
      ),
      appBarTheme: AppBarTheme(
        centerTitle: true,
        titleTextStyle: TextStyle(
          fontFamily: fontFamily,
          fontSize: 16,
          height: 22 / 16,
          fontWeight: FontWeight.w600,
          color: colors['text.primary'],
        ),
        elevation: 0,
        backgroundColor: colors['surface.page'],
        surfaceTintColor: Colors.transparent,
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(48, 48),
          backgroundColor: colors['accent.default'],
          foregroundColor: colors['accent.on'],
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(minimumSize: const Size(48, 48)),
      ),
      inputDecorationTheme: const InputDecorationTheme(
        border: InputBorder.none,
      ),
    );
  }

  static Color parse(String value) {
    if (value.startsWith('#')) {
      return Color(int.parse('ff${value.substring(1)}', radix: 16));
    }
    final parts = value
        .substring(5, value.length - 1)
        .split(',')
        .map(double.parse)
        .toList();
    return Color.fromRGBO(
      parts[0].toInt(),
      parts[1].toInt(),
      parts[2].toInt(),
      parts[3],
    );
  }
}
