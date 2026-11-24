import 'package:flutter/material.dart';

import 'src/build_variant.dart';

void main() {
  resolveBuildVariant();
  runApp(const PircApp());
}

class PircApp extends StatelessWidget {
  const PircApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      title: 'pirc',
      home: Scaffold(body: Center(child: Text('pirc'))),
    );
  }
}
