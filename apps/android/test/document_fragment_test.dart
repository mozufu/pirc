import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:html/parser.dart' as html;
import 'package:pirc_mobile/live/document_navigation.dart';
import 'package:pirc_mobile/live/document_navigation_state.dart';
import 'package:pirc_render/src/document_fragment.dart';
import 'package:pirc_render/src/html_form_submission.dart';
import 'document_navigation_widget_test.dart' show DocumentGateway, response;
import 'live_test.dart' show theme;

final fixture =
    jsonDecode(
          File(
            '../../packages/pirc_render/test/fixtures/parity/document-fragment-chromium153.json',
          ).readAsStringSync(),
        )
        as Map;
void main() {
  test(
    'fragment decoding preserves plus/BOM and tolerates malformed percent and UTF8 bytes',
    () {
      expect(decodeNativeDocumentFragment('a+b'), 'a+b');
      expect(decodeNativeDocumentFragment('%EF%BB%BFx'), '\ufeffx');
      expect(decodeNativeDocumentFragment('bad%ZZ'), 'bad%ZZ');
      expect(decodeNativeDocumentFragment('%FF'), '�');
    },
  );
  for (final row in fixture['cases'] as List) {
    testWidgets(
      'initial fragment URL ${row['mode']} ${row['viewport']['width']} dpr${row['dpr']} ${row['theme']}',
      (tester) async {
        final viewport = Size(
              (row['viewport']['width'] as num).toDouble(),
              (row['viewport']['height'] as num).toDouble(),
            ),
            dpr = (row['dpr'] as num).toDouble();
        tester.view.devicePixelRatio = dpr;
        tester.view.physicalSize = viewport * dpr;
        addTearDown(tester.view.reset);
        final url = '/fragment${row['hash']}',
            gateway = DocumentGateway()
              ..responses.add(response(url, row['html'] as String)),
            windows = NativeDocumentWindows(gateway),
            window = windows.target(
              'report',
              null,
              sourceUrl: 'https://gateway.example/',
            );
        addTearDown(windows.dispose);
        await window.load(
          NativeHtmlFormRequest(url: url, method: 'GET', target: ''),
          baseUrl: window.sourceUrl,
        );
        windows.select(window);
        await tester.pumpWidget(
          MaterialApp(
            theme: theme.build(
              row['theme'] == 'dark' ? Brightness.dark : Brightness.light,
            ),
            home: NativeDocumentWorkspace(windows: windows),
          ),
        );
        await tester.pumpAndSettle();
        expect(window.error, isNull);
        expect(
          window.currentDocument!.scroll.offset,
          closeTo((row['result']['initial']['root'] as num).toDouble(), 1 / 32),
        );
        expect(gateway.calls, hasLength(1));
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        await tester.pumpAndSettle();
      },
    );
    testWidgets(
      'native fragment activation ${row['mode']} ${row['viewport']['width']} dpr${row['dpr']} ${row['theme']}',
      (tester) async {
        final viewport = Size(
              (row['viewport']['width'] as num).toDouble(),
              (row['viewport']['height'] as num).toDouble(),
            ),
            dpr = (row['dpr'] as num).toDouble();
        tester.view.devicePixelRatio = dpr;
        tester.view.physicalSize = viewport * dpr;
        addTearDown(tester.view.reset);
        final gateway = DocumentGateway()
              ..responses.add(response('/fragment', row['html'] as String)),
            windows = NativeDocumentWindows(gateway),
            window = windows.target(
              'report',
              null,
              sourceUrl: 'https://gateway.example/',
            );
        addTearDown(windows.dispose);
        await window.load(
          const NativeHtmlFormRequest(
            url: '/fragment',
            method: 'GET',
            target: '',
          ),
          baseUrl: window.sourceUrl,
        );
        windows.select(window);
        final document = window.currentDocument!;
        await tester.pumpWidget(
          MaterialApp(
            theme: theme.build(
              row['theme'] == 'dark' ? Brightness.dark : Brightness.light,
            ),
            home: NativeDocumentWorkspace(windows: windows),
          ),
        );
        await tester.pumpAndSettle();
        final initialCount = window.history.length,
            before = row['result']['before'] as Map;
        document.scroll.jumpTo((before['root'] as num).toDouble());
        await tester.pumpAndSettle();
        final index = NativeDocumentFragmentIndex(
              row['html'] as String,
              'test',
            ),
            selection = index.select((row['hash'] as String).substring(1));
        final expectedTarget = row['result']['first']['target'];
        String? target;
        if (selection?.anchor != null) {
          for (final e
              in html
                  .parseFragment(index.annotatedHtml)
                  .querySelectorAll('[$nativeFragmentAttribute]')) {
            if (e.attributes[nativeFragmentAttribute] == selection!.anchor) {
              target = e.attributes['data-target'];
            }
          }
        }
        expect(
          target,
          expectedTarget,
          reason: 'independent browser target identity',
        );
        for (final phase in ['first', 'repeated']) {
          if (phase == 'repeated') {
            document.scroll.jumpTo(480);
            await tester.pumpAndSettle();
          }
          await tester.tap(find.text('Jump', findRichText: true));
          await tester.pumpAndSettle();
          final expected = row['result'][phase] as Map;
          expect(window.error, isNull);
          expect(window.currentDocument, same(document));
          expect(
            document.scroll.offset,
            closeTo((expected['root'] as num).toDouble(), 1 / 32),
            reason: phase,
          );
          expect(
            window.history.length,
            initialCount +
                (expected['length'] as int) -
                (before['length'] as int),
            reason: '$phase history entries',
          );
          final url = window.current!.url,
              hash = url.contains('#') ? url.substring(url.indexOf('#')) : '';
          expect(hash == '#' ? '' : hash, expected['hash']);
          expect(
            gateway.calls,
            hasLength(row['result']['requestCount'] as int),
          );
          expect(tester.takeException(), isNull);
        }
        await tester.pumpWidget(const SizedBox());
        await tester.pumpAndSettle();
      },
    );
  }
}
