import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'src/app.dart';
import 'src/build_variant.dart';

void main() {
  resolveBuildVariant();
  WidgetsFlutterBinding.ensureInitialized();
  installRenderer();
  runApp(const ProviderScope(child: PircApp()));
}
