import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_widget_from_html_core/flutter_widget_from_html_core.dart';
import 'package:html/parser.dart' as html;
import 'package:html/dom.dart' as dom;
import 'package:pirc_render/src/html_text_fields.dart';
import 'package:pirc_render/src/native_markdown.dart';
import '../../test/live_test.dart' show theme;
import 'capture_fonts.dart';

void main() {
  final fixture =
      jsonDecode(
            File(
              '../../fixtures/mobile-parity/html-input-sizing.json',
            ).readAsStringSync(),
          )
          as Map;
  final web =
      jsonDecode(
            File(
              '../../fixtures/mobile-parity/html-input-sizing-expected.json',
            ).readAsStringSync(),
          )
          as Map;
  for (final brightness in Brightness.values) {
    for (final width in fixture['widths'] as List) {
      testWidgets('HTML input sizing ${brightness.name} $width', (
        tester,
      ) async {
        await tester.runAsync(loadParityFonts);
        tester.view.physicalSize = Size((width as num).toDouble(), 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final rows = <Map<String, Object?>>[];
        final reference =
            (web['themes'][brightness.name]['widths'] as List).singleWhere(
                  (r) => r['width'] == width,
                )['cases']
                as List;
        final base = theme.build(brightness);
        for (final item in fixture['cases'] as List) {
          await tester.pumpWidget(
            MaterialApp(
              theme: base.copyWith(
                textTheme: base.textTheme.apply(fontFamily: 'Arial'),
              ),
              home: Scaffold(
                body: SingleChildScrollView(
                  padding: const EdgeInsets.all(16),
                  child: NativeMarkdown(
                    key: ValueKey(item['id']),
                    source: item['source'] as String,
                    fontSize: 15,
                    lineHeight: 1.65,
                  ),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          final expected =
              (reference.singleWhere((r) => r['id'] == item['id'])
                      as Map)['controls']
                  as List;
          final documents = tester
              .widgetList<HtmlWidget>(find.byType(HtmlWidget))
              .map((w) => html.parseFragment(w.html))
              .toList();
          for (final control in expected) {
            final element = documents
                .map((d) => d.querySelector('#${control['id']}'))
                .whereType<dom.Element>()
                .first;
            final field = tester
                .widgetList<NativeHtmlTextFieldWidget>(
                  find.byType(NativeHtmlTextFieldWidget),
                )
                .singleWhere(
                  (w) => w.state.resolveControl(element)?.key == w.field.key,
                );
            expect(field.state.valueFor(field.field.key), control['value']);
            final painter = TextPainter(
              text: TextSpan(
                text: 'x',
                style: field.textStyle.copyWith(height: kTextHeightNone),
              ),
              textDirection: TextDirection.ltr,
            )..layout();
            final metrics = painter.computeLineMetrics().first;
            final fontMetrics = {
              'fontFamily': field.textStyle.fontFamily,
              'xAdvance': painter.width,
              'ascent': metrics.ascent,
              'unscaledAscent': metrics.unscaledAscent,
            };
            painter.dispose();
            final rect = tester.getRect(find.byWidget(field));
            final expectedBox = control['box'] as Map;
            rows.add({
              'case': item['id'],
              'id': control['id'],
              'value': field.state.valueFor(field.field.key),
              'fontMetrics': fontMetrics,
              'box': {
                'x': rect.left,
                'y': rect.top,
                'width': rect.width,
                'height': rect.height,
              },
              'delta': {
                'x': rect.left - (expectedBox['x'] as num),
                'y': rect.top - (expectedBox['y'] as num),
                'width': rect.width - (expectedBox['width'] as num),
                'height': rect.height - (expectedBox['height'] as num),
              },
            });
            // Native line metrics include leading absent from Blink's raw
            // font ascent. Keep the measured one-pixel residual explicit;
            // this assertion detects larger regressions, not visual acceptance.
            expect(
              (rect.width - (expectedBox['width'] as num)).abs(),
              lessThanOrEqualTo(1.01),
              reason: '${item['id']} ${control['id']} intrinsic width',
            );
          }
          expect(tester.takeException(), isNull);
        }
        await tester.runAsync(() async {
          final file = File(
            'build/parity/html-input-sizing-native-${brightness.name}-$width.json',
          );
          await file.parent.create(recursive: true);
          await file.writeAsString(
            const JsonEncoder.withIndent('  ').convert(rows),
          );
        });
      });
    }
  }
}
