import 'package:flutter/material.dart';
import 'theme.dart';
import 'live/app.dart';
import 'live/gateway.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final theme = await PircTheme.load();
  runApp(MobileApp(theme: theme, controller: LiveController(Gateway())));
}
