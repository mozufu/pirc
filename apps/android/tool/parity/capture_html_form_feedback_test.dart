import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_render/src/html_buttons.dart';
import 'package:pirc_render/src/native_markdown.dart';
import '../../test/live_test.dart' show theme;
import 'capture_fonts.dart';

// Native diagnostic frames only: headless Chromium did not paint its validation
// bubble, so these images cannot establish browser popup visual parity.
void main() {
  for (final width in [390.0, 768.0]) {
    for (final brightness in Brightness.values) {
      for (final scale in [1.0, 2.0]) {
        testWidgets('native form feedback $width ${brightness.name} $scale', (
          t,
        ) async {
          await t.runAsync(loadParityFonts);
          t.binding.platformDispatcher.localeTestValue = const Locale(
            'en',
            'US',
          );
          addTearDown(t.binding.platformDispatcher.clearLocaleTestValue);
          t.view.devicePixelRatio = 1;
          t.view.physicalSize = Size(width, 844);
          addTearDown(t.view.resetPhysicalSize);
          addTearDown(t.view.resetDevicePixelRatio);
          final key = GlobalKey();
          final base = theme.build(brightness);
          await t.pumpWidget(
            RepaintBoundary(
              key: key,
              child: MaterialApp(
                debugShowCheckedModeBanner: false,
                theme: base.copyWith(
                  textTheme: base.textTheme.apply(fontFamily: 'Arial'),
                ),
                builder: (context, child) => MediaQuery(
                  data: MediaQuery.of(
                    context,
                  ).copyWith(textScaler: TextScaler.linear(scale)),
                  child: child!,
                ),
                home: Scaffold(
                  body: SingleChildScrollView(
                    padding: const EdgeInsets.all(16),
                    child: NativeMarkdown(
                      source:
                          '<form><p><label for="required-name">Name</label></p><input id="required-name" name="username" required><p><button>Send</button></p></form>',
                      onFormSubmit: (_) => fail('Invalid form must not submit'),
                    ),
                  ),
                ),
              ),
            ),
          );
          await t.pumpAndSettle();
          await t.tap(find.byType(NativeHtmlButtonWidget));
          await t.pumpAndSettle();
          expect(
            find.byKey(const ValueKey('native-html-validation-message')),
            findsOneWidget,
          );
          expect(t.takeException(), isNull);
          await t.runAsync(() async {
            final image =
                await (key.currentContext!.findRenderObject()
                        as RenderRepaintBoundary)
                    .toImage();
            try {
              final bytes = await image.toByteData(
                format: ui.ImageByteFormat.png,
              );
              final file = File(
                'build/parity/html-form-feedback-native-${brightness.name}-${width.toInt()}-${scale.toInt()}x.png',
              );
              await file.parent.create(recursive: true);
              await file.writeAsBytes(bytes!.buffer.asUint8List());
            } finally {
              image.dispose();
            }
          });
        });
      }
    }
  }
}
