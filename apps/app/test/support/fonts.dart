import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

bool _loaded = false;

/// Loads real fonts for golden images (macOS only, tag `golden`): every
/// font the app bundles (the icon fonts) and the system San Francisco font
/// as the default family, with PingFang for Chinese.
Future<void> loadGoldenFonts() async {
  if (_loaded) return;
  _loaded = true;
  final manifest =
      jsonDecode(await rootBundle.loadString('FontManifest.json'))
          as List<Object?>;
  for (final family in manifest.cast<Map<String, Object?>>()) {
    final loader = FontLoader(family['family']! as String);
    for (final font
        in (family['fonts']! as List).cast<Map<String, Object?>>()) {
      loader.addFont(rootBundle.load(font['asset']! as String));
    }
    await loader.load();
  }
  Future<ByteData> system(String path) async =>
      ByteData.sublistView(await File(path).readAsBytes());
  for (final family in ['Roboto', '.SF UI Text', '.SF UI Display']) {
    await (FontLoader(
      family,
    )..addFont(system('/System/Library/Fonts/SFNS.ttf'))).load();
  }
}
