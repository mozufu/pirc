import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:html/parser.dart' as html;
import 'package:pirc_render/src/html_date.dart';
import 'capture_fonts.dart';

Future<void> _loadCaptureFonts() async {
  await loadParityFonts();
  await (FontLoader('Date picker system')..addFont(
        File(
          '/System/Library/Fonts/SFNS.ttf',
        ).readAsBytes().then(ByteData.sublistView),
      ))
      .load();
  final pingFang =
      Directory('/System/Library/AssetsV2/com_apple_MobileAsset_Font7')
          .listSync(recursive: true)
          .whereType<File>()
          .firstWhere((file) => file.path.endsWith('/PingFang.ttc'));
  await (FontLoader(
    'Date picker CJK fallback',
  )..addFont(pingFang.readAsBytes().then(ByteData.sublistView))).load();
}

NativeHtmlDateDescriptor _control(NativeHtmlDateState state, String source) {
  final fragment = html.parseFragment(state.annotateHtml(source));
  return state.resolveControl(fragment.querySelector('#visit')!)!;
}

void main() {
  testWidgets('capture localized native calendar overlay', (tester) async {
    await tester.runAsync(_loadCaptureFonts);
    tester.platformDispatcher.localeTestValue = const Locale('zh', 'TW');
    addTearDown(tester.platformDispatcher.clearLocaleTestValue);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);

    const source =
        '<input id="visit" type="date" value="2024-06-15" '
        'min="2024-06-01" max="2024-06-30">';
    final directory = Directory('build/parity/native-date-picker-overlay');
    await tester.runAsync(() => directory.create(recursive: true));
    final captures = <Map<String, Object?>>[];

    for (final brightness in Brightness.values) {
      for (final scale in [1.0, 2.0]) {
        final id = '${brightness.name}-scale${scale.toInt()}';
        tester.view.physicalSize = const Size(390, 844);
        final state = NativeHtmlDateState.fromHtml(source);
        final control = _control(state, source);
        final boundary = GlobalKey();
        await tester.pumpWidget(
          RepaintBoundary(
            key: boundary,
            child: MaterialApp(
              debugShowCheckedModeBanner: false,
              locale: const Locale('en', 'US'),
              theme: ThemeData(
                brightness: brightness,
                useMaterial3: false,
                fontFamily: 'Date picker system',
                fontFamilyFallback: const ['Date picker CJK fallback'],
              ),
              home: Builder(
                builder: (context) => MediaQuery(
                  data: MediaQuery.of(
                    context,
                  ).copyWith(textScaler: TextScaler.linear(scale)),
                  child: Scaffold(
                    body: Align(
                      alignment: Alignment.topLeft,
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              'Picker and locale probe',
                              style: TextStyle(
                                fontFamily: 'Date picker system',
                                fontSize: 16 * scale,
                              ),
                            ),
                            const SizedBox(height: 4),
                            MediaQuery.withNoTextScaling(
                              child: NativeHtmlDateInput(
                                state: state,
                                control: control,
                                textStyle: TextStyle(
                                  fontFamily: 'Arial',
                                  fontFamilyFallback: const [
                                    'Date picker CJK fallback',
                                  ],
                                  fontSize: 13.333333333333334 * scale,
                                  color: brightness == Brightness.dark
                                      ? Colors.white
                                      : Colors.black,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final button = find.byKey(
          ValueKey('native-html-date-calendar-${control.key}'),
        );
        await tester.tap(button);
        await tester.pumpAndSettle();
        final popup = find.byKey(
          const ValueKey('native-html-date-calendar-popup'),
        );
        final popupRect = tester.getRect(popup);
        expect(popupRect.left, greaterThanOrEqualTo(0), reason: id);
        expect(popupRect.right, lessThanOrEqualTo(390), reason: id);
        expect(popupRect.top, greaterThanOrEqualTo(0), reason: id);
        expect(popupRect.bottom, lessThanOrEqualTo(844), reason: id);
        expect(find.text('2024年06月'), findsOneWidget, reason: id);
        await tester.runAsync(() async {
          final image = await tester
              .renderObject<RenderRepaintBoundary>(find.byKey(boundary))
              .toImage(pixelRatio: 1);
          try {
            final data = await image.toByteData(format: ui.ImageByteFormat.png);
            await File(
              '${directory.path}/$id.png',
            ).writeAsBytes(data!.buffer.asUint8List());
          } finally {
            image.dispose();
          }
        });
        captures.add({
          'id': id,
          'viewport': {'width': 390, 'height': 844, 'dpr': 1},
          'textScale': scale,
          'brightness': brightness.name,
          'hostLocale': 'zh-TW',
          'pageLocale': 'en-US',
          'controlRect': {
            'left': tester.getRect(button).left,
            'top': tester.getRect(button).top,
            'width': tester.getRect(button).width,
            'height': tester.getRect(button).height,
          },
          'popupRect': {
            'left': popupRect.left,
            'top': popupRect.top,
            'width': popupRect.width,
            'height': popupRect.height,
          },
        });
        await tester.pumpWidget(const SizedBox.shrink());
        state.dispose();
      }
    }
    await tester.runAsync(() async {
      await File('${directory.path}/capture.json').writeAsString(
        const JsonEncoder.withIndent('  ').convert({
          'hostLocale': 'zh-TW',
          'pageLocale': 'en-US',
          'captures': captures,
          'limits': [
            'Screenshots use host SFNS/Arial/PingFang comparison fonts.',
            'Flutter popup rendering is not evidence of Android system-font raster parity.',
          ],
        }),
      );
    });
  });
}
