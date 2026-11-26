import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_mobile/live/document_navigation.dart';
import 'package:pirc_mobile/live/document_navigation_state.dart';
import 'package:pirc_render/src/html_form_submission.dart';
import 'document_navigation_widget_test.dart' show DocumentGateway, response;
import 'live_test.dart' show theme;

void main() {
  final fixture =
      jsonDecode(
            File(
              '../../packages/pirc_render/test/fixtures/parity/document-fragment-chromium153.json',
            ).readAsStringSync(),
          )
          as Map;
  for (final row in (fixture['cases'] as List).where(
    (r) => r['mode'] == 'basic',
  )) {
    for (final scenario in [
      'remount',
      'replace-cancel',
      'click-during-reveal',
      'window-switch-cancel',
    ]) {
      testWidgets(
        'fragment lifecycle $scenario ${row['viewport']['width']} dpr${row['dpr']} ${row['theme']}',
        (tester) async {
          final dpr = (row['dpr'] as num).toDouble(),
              viewport = Size(
                (row['viewport']['width'] as num).toDouble(),
                (row['viewport']['height'] as num).toDouble(),
              );
          tester.view.devicePixelRatio = dpr;
          tester.view.physicalSize = viewport * dpr;
          addTearDown(tester.view.reset);
          final source = (row['html'] as String)
              .replaceFirst(
                '</head>',
                scenario == 'click-during-reveal'
                    ? '<style>html{scroll-behavior:smooth}</style></head>'
                    : '</head>',
              )
              .replaceFirst(
                '</body>',
                '<a href="#other" style="position:fixed;top:64px;left:16px">Other</a></body>',
              );
          final gateway = DocumentGateway()
                ..responses.add(response('/fragment', source)),
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
          NativeDocumentWindow? other;
          if (scenario == 'window-switch-cancel') {
            gateway.responses.add(response('/other', '<p>Other window</p>'));
            other = windows.target(
              'other',
              null,
              sourceUrl: 'https://gateway.example/',
            );
            await other.load(
              const NativeHtmlFormRequest(
                url: '/other',
                method: 'GET',
                target: '',
              ),
              baseUrl: other.sourceUrl,
            );
          }
          windows.select(window);
          final document = window.currentDocument!;
          Widget workspace() => MaterialApp(
            theme: theme.build(
              row['theme'] == 'dark' ? Brightness.dark : Brightness.light,
            ),
            home: NativeDocumentWorkspace(windows: windows),
          );
          Future<void> go(String fragment) => window
              .load(
                NativeHtmlFormRequest(url: fragment, method: 'GET', target: ''),
                baseUrl: window.current!.url,
                fragmentAllowed: true,
              )
              .then((_) {});
          await tester.pumpWidget(workspace());
          await tester.pumpAndSettle();
          document.scroll.jumpTo(240);
          await tester.pumpAndSettle();
          if (scenario == 'remount') {
            await go('#destination');
            await tester.pumpWidget(const SizedBox());
            await tester.pumpAndSettle();
            await tester.pumpWidget(workspace());
            await tester.pumpAndSettle();
            expect(document.scroll.offset, 1000);
            document.scroll.jumpTo(720);
            await tester.pumpAndSettle();
            await tester.pumpWidget(const SizedBox());
            await tester.pumpAndSettle();
            await tester.pumpWidget(workspace());
            await tester.pumpAndSettle();
            expect(document.scroll.offset, 720);
            window.setHistoryScrollRestoration(document, 'manual', 1);
            await go('#destination');
            await tester.pumpAndSettle();
            expect(document.scroll.offset, 1000);
            expect(window.history, hasLength(2));
          } else if (scenario == 'window-switch-cancel') {
            await go('#destination');
            WidgetsBinding.instance.addPostFrameCallback(
              (_) => windows.select(other!),
            );
            await tester.pumpAndSettle();
            expect(windows.active, same(other));
            expect(document.scroll.offset, 240);
            expect(
              window.hasPendingFragmentReveal,
              isFalse,
              reason: 'a newer window selection cancels pending navigation',
            );
            windows.select(window);
            await tester.pumpAndSettle();
            expect(
              document.scroll.offset,
              240,
              reason:
                  'returning preserves reading position rather than replaying canceled navigation',
            );
            expect(window.hasPendingFragmentReveal, isFalse);
          } else if (scenario == 'replace-cancel') {
            await go('#destination');
            WidgetsBinding.instance.addPostFrameCallback((_) {
              window.applyHistoryApiMutation(
                document: document,
                method: 'replaceState',
                revision: 1,
                url: 'https://gateway.example/fragment#other',
                stateGraph: {'version': 1, 'root': null, 'nodes': []},
              );
            });
            await tester.pumpAndSettle();
            expect(document.scroll.offset, 240);
            expect(window.current!.url, endsWith('#other'));
          } else {
            await tester.tap(find.text('Jump', findRichText: true));
            for (
              var i = 0;
              i < 12 && !document.scroll.position.isScrollingNotifier.value;
              i++
            ) {
              await tester.pump(const Duration(milliseconds: 5));
            }
            expect(
              document.scroll.position.isScrollingNotifier.value,
              isTrue,
              reason: 'exercise a real in-flight reveal',
            );
            await tester.tap(find.text('Other', findRichText: true));
            await tester.pumpAndSettle();
            expect(window.current!.url, endsWith('#other'));
            expect(window.history, hasLength(3));
          }
          expect(gateway.calls, hasLength(other == null ? 1 : 2));
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox());
          await tester.pumpAndSettle();
        },
      );
    }
  }
}
