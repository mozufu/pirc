import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'connection/storage.dart';

/// The interface language: null follows the system, otherwise `en` or
/// `zh-TW`. Language belongs to this client, independently of the Gateway.
final languageProvider = NotifierProvider<LanguageNotifier, String?>(
  LanguageNotifier.new,
);

class LanguageNotifier extends Notifier<String?> {
  @override
  String? build() =>
      _valid(ref.read(sharedPreferencesProvider).getString(PrefKeys.language));

  static String? _valid(String? language) =>
      language == 'en' || language == 'zh-TW' ? language : null;

  void select(String? language) {
    state = _valid(language);
    final prefs = ref.read(sharedPreferencesProvider);
    if (state == null) {
      prefs.remove(PrefKeys.language);
    } else {
      prefs.setString(PrefKeys.language, state!);
    }
  }
}

/// Light, dark or the system's appearance.
final themeModeProvider = NotifierProvider<ThemeModeNotifier, ThemeMode>(
  ThemeModeNotifier.new,
);

class ThemeModeNotifier extends Notifier<ThemeMode> {
  @override
  ThemeMode build() {
    final saved = ref
        .read(sharedPreferencesProvider)
        .getString(PrefKeys.appearance);
    return ThemeMode.values.firstWhere(
      (mode) => mode.name == saved,
      orElse: () => ThemeMode.system,
    );
  }

  void select(ThemeMode mode) {
    state = mode;
    ref
        .read(sharedPreferencesProvider)
        .setString(PrefKeys.appearance, mode.name);
  }
}

/// The text sizes the general settings offer, as a factor of the system size.
const textScales = [0.9, 1.0, 1.15, 1.3];

final textScaleProvider = NotifierProvider<TextScaleNotifier, double>(
  TextScaleNotifier.new,
);

class TextScaleNotifier extends Notifier<double> {
  @override
  double build() {
    final saved = ref
        .read(sharedPreferencesProvider)
        .getDouble(PrefKeys.textScale);
    return textScales.contains(saved) ? saved! : 1.0;
  }

  void select(double scale) {
    if (!textScales.contains(scale)) return;
    state = scale;
    ref.read(sharedPreferencesProvider).setDouble(PrefKeys.textScale, scale);
  }
}

/// The tab the app opens on, by path (`/chat`, `/work`, …).
final startTabProvider = NotifierProvider<StartTabNotifier, String>(
  StartTabNotifier.new,
);

const startTabs = ['/chat', '/work', '/activity', '/calendar'];

class StartTabNotifier extends Notifier<String> {
  @override
  String build() {
    final saved = ref
        .read(sharedPreferencesProvider)
        .getString(PrefKeys.startTab);
    return startTabs.contains(saved) ? saved! : '/chat';
  }

  void select(String path) {
    if (!startTabs.contains(path)) return;
    state = path;
    ref.read(sharedPreferencesProvider).setString(PrefKeys.startTab, path);
  }
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
