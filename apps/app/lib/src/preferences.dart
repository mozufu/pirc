import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// The interface language: null follows the system, otherwise `en` or
/// `zh-TW`. Language belongs to this client, independently of the Gateway.
final languageProvider = NotifierProvider<LanguageNotifier, String?>(
  LanguageNotifier.new,
);

class LanguageNotifier extends Notifier<String?> {
  @override
  String? build() => null;

  void select(String? language) =>
      state = language == 'en' || language == 'zh-TW' ? language : null;
}

/// Light, dark or the system's appearance.
final themeModeProvider = NotifierProvider<ThemeModeNotifier, ThemeMode>(
  ThemeModeNotifier.new,
);

class ThemeModeNotifier extends Notifier<ThemeMode> {
  @override
  ThemeMode build() => ThemeMode.system;

  void select(ThemeMode mode) => state = mode;
}

/// The locale for [language]; null lets Flutter match the system locale.
Locale? localeFor(String? language) => switch (language) {
  'en' => const Locale('en'),
  'zh-TW' => const Locale('zh', 'TW'),
  _ => null,
};

/// The client language for a resolved [locale]: any Chinese locale uses the
/// Traditional Chinese catalog, everything else English.
String languageOf(Locale locale) =>
    locale.languageCode == 'zh' ? 'zh-TW' : 'en';
