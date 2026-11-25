import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'src/app.dart';
import 'src/build_variant.dart';
import 'src/connection/storage.dart';

Future<void> main() async {
  resolveBuildVariant();
  WidgetsFlutterBinding.ensureInitialized();
  installRenderer();
  final preferences = await SharedPreferences.getInstance();
  runApp(
    ProviderScope(
      overrides: [sharedPreferencesProvider.overrideWithValue(preferences)],
      child: const PircApp(),
    ),
  );
}
