import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_render/src/html_date.dart';
import 'package:pirc_render/src/html_file.dart';
import 'package:pirc_render/src/html_form_feedback.dart';
import 'package:pirc_render/src/html_form_validation.dart';
import 'package:pirc_render/src/html_syntax.dart';
import 'package:pirc_render/src/native_html.dart';
import '../../test/live_test.dart' show theme;
import 'capture_fonts.dart';

void main() {
  testWidgets('capture actual date/file document matrix', (tester) async {
    await tester.runAsync(() async {
      await loadParityFonts();
      await (FontLoader('Date/file reference')..addFont(
            File(
              '/System/Library/Fonts/SFNS.ttf',
            ).readAsBytes().then(ByteData.sublistView),
          ))
          .load();
      await (FontLoader('sans-serif')..addFont(
            File(
              '/System/Library/Fonts/Supplemental/Arial.ttf',
            ).readAsBytes().then(ByteData.sublistView),
          ))
          .load();
      final pingFang =
          Directory('/System/Library/AssetsV2/com_apple_MobileAsset_Font7')
              .listSync(recursive: true)
              .whereType<File>()
              .firstWhere((file) => file.path.endsWith('/PingFang.ttc'));
      await (FontLoader(
        'Date/file fallback',
      )..addFont(pingFang.readAsBytes().then(ByteData.sublistView))).load();
    });
    Map<String, dynamic> read(String name) =>
        jsonDecode(
              File(
                '../../fixtures/mobile-parity/$name.json',
              ).readAsStringSync(),
            )
            as Map<String, dynamic>;
    final fixture = read('html-form-date-file');
    final expected = read('html-form-date-file-expected');
    final references = ((expected['matrix'] as Map)['cases'] as List)
        .cast<Map>();
    final directory = Directory('build/parity/html-form-date-file-native')
      ..createSync(recursive: true);
    tester.platformDispatcher.localeTestValue = const Locale('zh', 'TW');
    addTearDown(tester.platformDispatcher.clearLocaleTestValue);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    final cases = <Map>[];
    for (final mode in fixture['modes'] as List) {
      for (final width in fixture['widths'] as List) {
        for (final brightness in Brightness.values) {
          for (final scale in [1.0, 2.0]) {
            final id = '$mode-$width-${brightness.name}-scale${scale.toInt()}';
            final web = references.singleWhere((row) => row['id'] == id);
            tester.view.physicalSize = Size(
              (width as num).toDouble(),
              (fixture['height'] as num).toDouble(),
            );
            final raw = mode == 'rawDocument';
            final boundary = GlobalKey();
            final baseTheme = theme.build(brightness);
            final themed = baseTheme.copyWith(
              textTheme: baseTheme.textTheme.apply(
                fontFamily: 'Date/file reference',
              ),
            );
            await tester.pumpWidget(
              RepaintBoundary(
                key: boundary,
                child: MaterialApp(
                  debugShowCheckedModeBanner: false,
                  locale: const Locale('en', 'US'),
                  theme: themed,
                  builder: (context, child) => MediaQuery(
                    data: MediaQuery.of(context).copyWith(
                      textScaler: raw
                          ? TextScaler.noScaling
                          : TextScaler.linear(scale),
                    ),
                    child: child!,
                  ),
                  home: Scaffold(
                    body: SingleChildScrollView(
                      child: NativeHtmlDocument(
                        key: ValueKey(id),
                        nodes: [NativeHtmlRaw(fixture['markup'] as String)],
                        style: TextStyle(
                          fontSize: raw ? 16 * scale : 16,
                          fontFamily: raw ? 'Times' : 'Date/file reference',
                          fontFamilyFallback: const ['Date/file fallback'],
                        ),
                        styles: MarkdownStyleSheet.fromTheme(themed),
                        builders: const {},
                        markdownStyles: !raw,
                        // Match the harness's CSS font zoom without copying oracle geometry.
                        authorStylesBuilder: raw
                            ? (element) =>
                                  const {
                                    'input',
                                    'button',
                                    'select',
                                  }.contains(element.localName)
                                  ? {
                                      'font-size':
                                          '${13.333333333333334 * scale}px',
                                    }
                                  : null
                            : null,
                        filePicker: (_) async => null,
                      ),
                    ),
                  ),
                ),
              ),
            );
            await tester.pumpAndSettle();
            final forms = tester
                .widget<NativeHtmlFormFeedback>(
                  find.byType(NativeHtmlFormFeedback),
                )
                .forms;
            final controls = <String, Object?>{};
            for (final group in ['dates', 'files']) {
              final selectors =
                  fixture[group == 'dates' ? 'dateControls' : 'fileControls']
                      as Map;
              final states = web[group] as Map;
              for (final entry in selectors.entries) {
                final state = states[entry.key] as Map?;
                if (state == null) continue;
                final controlId = (entry.value as String).substring(1);
                final result = forms.validityForId(controlId)!;
                final flags = (state['validity'] as Map)['flags'] as Map;
                expect(
                  result.willValidate,
                  state['willValidate'],
                  reason: '$id $controlId',
                );
                expect(result.valid, flags['valid'], reason: '$id $controlId');
                for (final flag in HtmlValidityFlag.values) {
                  expect(
                    result.has(flag),
                    flags[flag.name],
                    reason: '$id $controlId ${flag.name}',
                  );
                }
                final finder = find.byWidgetPredicate(
                  (widget) => group == 'dates'
                      ? widget is NativeHtmlDateInput &&
                            widget.control.name == state['name']
                      : widget is NativeHtmlFileInputWidget &&
                            widget.control.name == state['name'],
                );
                expect(finder, findsOneWidget, reason: '$id $controlId');
                final rect = tester.getRect(finder);
                final reference = state['rect'] as Map;
                final value = group == 'dates'
                    ? tester
                          .widget<NativeHtmlDateInput>(finder)
                          .state
                          .valueFor(
                            tester
                                .widget<NativeHtmlDateInput>(finder)
                                .control
                                .key,
                          )
                    : '';
                expect(value, state['value'], reason: '$id $controlId value');
                controls[controlId] = {
                  'value': value,
                  'willValidate': result.willValidate,
                  'valid': result.valid,
                  'flags': result.flags.map((flag) => flag.name).toList(),
                  'rect': {
                    'left': rect.left,
                    'top': rect.top,
                    'width': rect.width,
                    'height': rect.height,
                  },
                  'webRect': reference,
                  'widthDelta': rect.width - (reference['width'] as num),
                  'heightDelta': rect.height - (reference['height'] as num),
                };
              }
            }
            expect(tester.takeException(), isNull, reason: id);
            await tester.runAsync(() async {
              final image = await tester
                  .renderObject<RenderRepaintBoundary>(find.byKey(boundary))
                  .toImage(pixelRatio: 1);
              try {
                final data = await image.toByteData(
                  format: ui.ImageByteFormat.png,
                );
                File(
                  '${directory.path}/$id.png',
                ).writeAsBytesSync(data!.buffer.asUint8List());
              } finally {
                image.dispose();
              }
            });
            cases.add({'id': id, 'controls': controls});
            File('${directory.path}/capture.json').writeAsStringSync(
              const JsonEncoder.withIndent('  ').convert({
                'webRevision': fixture['webRevision'],
                'cases': cases,
                'complete': false,
              }),
            );
          }
        }
      }
    }
    File('${directory.path}/capture.json').writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert({
        'webRevision': fixture['webRevision'],
        'complete': true,
        'cases': cases,
        'comparisonFonts': {
          'markdown': '/System/Library/Fonts/SFNS.ttf',
          'rawControls': '/System/Library/Fonts/Supplemental/Arial.ttf',
        },
        'limits': [
          'Host fonts do not prove Android raster parity.',
          'Viewport screenshots accompany below-fold control rectangles.',
          'Control body geometry excludes OS chooser and Material calendar popup.',
        ],
      }),
    );
  });
}
