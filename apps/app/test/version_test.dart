import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_app/src/settings/settings_widgets.dart';

void main() {
  test('appVersion matches pubspec.yaml', () {
    final line = File(
      'pubspec.yaml',
    ).readAsLinesSync().firstWhere((line) => line.startsWith('version:'));
    final version = line.split(':').last.trim().split('+').first;
    expect(appVersion, version);
  });
}
