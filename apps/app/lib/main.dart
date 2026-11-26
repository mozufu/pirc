import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pirc_render/pirc_render.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'src/app.dart';
import 'src/build_variant.dart';
import 'src/connection/storage.dart';

Future<void> main() async {
  resolveBuildVariant();
  WidgetsFlutterBinding.ensureInitialized();
  installRenderer();
  // Android 12+ reports AVIF support (M8 step 7); elsewhere this does nothing.
  await NativeRasterImages.loadCapabilities();
  final preferences = await SharedPreferences.getInstance();
  runApp(
    ProviderScope(
      // Lists read again on hints and offer "Try again"; no timed retries.
      retry: noRetry,
      overrides: [sharedPreferencesProvider.overrideWithValue(preferences)],
      child: const PircApp(),
    ),
  );
}
