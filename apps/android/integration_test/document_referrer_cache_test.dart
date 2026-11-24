import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrintSynchronously;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:html/parser.dart' as html;
import 'package:integration_test/integration_test.dart';
import 'package:pirc_mobile/live/document_navigation.dart';
import 'package:pirc_mobile/live/document_navigation_state.dart';
import 'package:pirc_mobile/live/document_referrer.dart';
import 'package:pirc_mobile/live/gateway.dart';
import 'package:pirc_render/src/html_form_submission.dart';
import 'package:pirc_mobile/theme.dart';

Future<void> _until(
  WidgetTester tester,
  bool Function() ready,
  String label,
) async {
  for (var i = 0; i < 400 && !ready(); i++) {
    await tester.pump(const Duration(milliseconds: 20));
  }
  expect(ready(), isTrue, reason: label);
  expect(tester.takeException(), isNull, reason: label);
}

Future<void> _tapLink(WidgetTester tester, String label) async {
  final finder = find.byWidgetPredicate(
    (widget) => widget is RichText && widget.text.toPlainText().trim() == label,
  );
  expect(finder, findsOneWidget);
  await tester.ensureVisible(finder);
  await tester.pump();
  final paragraph = tester.renderObject<RenderParagraph>(finder);
  final boxes = paragraph.getBoxesForSelection(
    TextSelection(baseOffset: 0, extentOffset: label.length),
  );
  await tester.tapAt(paragraph.localToGlobal(boxes.first.toRect().center));
  await tester.pump();
}

String _page(String title, {String links = ''}) =>
    '<!doctype html><html><body><h1>$title</h1>$links'
    '<pre id="probe">READY</pre><script>document.getElementById("probe").textContent='
    'JSON.stringify({url:location.href,referrer:document.referrer});</script></body></html>';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'real native response cache keeps referrer per navigation on fresh, 304 and Vary',
    (tester) async {
      final gateway = Gateway();
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final origin = 'http://127.0.0.1:${server.port}';
      final token = 'pirc_dev_${List.filled(43, 'A').join()}';
      final receipts = <Map<String, Object?>>[];
      final errors = <String>[];
      final listener = server.listen((request) async {
        try {
          await request.drain<void>();
          if (request.headers.value('authorization') != 'Bearer $token') {
            errors.add(
              'Missing synthetic pairing authorization for ${request.uri}',
            );
          }
          if (request.uri.path == '/api/sessions') {
            request.response.headers.contentType = ContentType.json;
            request.response.write('{"sessions":[]}');
          } else {
            final mode = request.uri.queryParameters['mode']!;
            receipts.add({
              'url': '$origin${request.uri}',
              'referer': request.headers.value('referer'),
              'ifNoneMatch': request.headers.value('if-none-match'),
            });
            request.response.headers.contentType = ContentType(
              'text',
              'html',
              charset: 'utf-8',
            );
            if (request.uri.path == '/target') {
              request.response.headers.set('ETag', '"target-v1"');
              request.response.headers.set(
                'Cache-Control',
                mode == '304' ? 'no-cache' : 'max-age=3600',
              );
              if (mode.startsWith('vary')) {
                request.response.headers.set('Vary', 'Referer');
              }
              if (mode == '304' &&
                  request.headers.value('if-none-match') == '"target-v1"') {
                request.response.statusCode = HttpStatus.notModified;
              } else {
                request.response.write(_page('Cached target'));
              }
            } else if (request.uri.path == '/a' || request.uri.path == '/b') {
              request.response.headers.set('Cache-Control', 'no-store');
              final policy = mode == 'vary-origin'
                  ? ' referrerpolicy="origin"'
                  : '';
              request.response.write(
                _page(
                  'Source ${request.uri.path} generation ${receipts.length}',
                  links:
                      '<p><a href="/target?mode=$mode"$policy>Open target</a></p>'
                      '<p><a href="/b?mode=$mode">Other source</a></p>'
                      '<p><a href="#two">Other fragment</a></p>',
                ),
              );
            } else {
              errors.add('Unexpected fixture URI ${request.uri}');
              request.response.statusCode = HttpStatus.notFound;
            }
          }
          await request.response.close();
        } catch (error) {
          errors.add('$error');
          try {
            await request.response.close();
          } catch (_) {}
        }
      });
      final theme = await PircTheme.load();
      try {
        await gateway.call('pair', {
          'link': Uri(
            scheme: 'pirc',
            host: 'pair',
            queryParameters: {'url': origin, 'token': token},
          ).toString(),
        });
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(390, 844);
        for (final mode in [
          'fresh',
          '304',
          'vary-full',
          'vary-origin',
          'history-fragments',
        ]) {
          final initialUrl =
              '$origin/a?mode=$mode${mode == 'history-fragments' ? '#one' : ''}';
          final windows = NativeDocumentWindows(gateway);
          final window = windows.target('', null, sourceUrl: initialUrl);
          final start = receipts.length;
          try {
            expect(
              await window.load(
                NativeHtmlFormRequest(
                  url: initialUrl,
                  method: 'GET',
                  target: '',
                ),
                baseUrl: origin,
                referrer: const NativeDocumentReferrer('', 'no-referrer'),
              ),
              NativeDocumentLoadResult.committed,
            );
            windows.select(window);
            await tester.pumpWidget(
              MaterialApp(
                theme: theme.build(Brightness.dark),
                home: NativeDocumentWorkspace(windows: windows),
              ),
            );
            await _until(
              tester,
              () => window.currentDocument?.scripts?.ready == true,
              '$mode initial source',
            );
            if (mode == 'history-fragments') {
              final initialDocument = window.currentDocument!;
              final secondFragment = '$origin/a?mode=$mode#two';
              await _tapLink(tester, 'Other fragment');
              await _until(
                tester,
                () => window.current?.url == secondFragment,
                'same-document fragment navigation',
              );
              expect(window.currentDocument, same(initialDocument));
              await _tapLink(tester, 'Open target');
              await _until(
                tester,
                () =>
                    window.current?.url == '$origin/target?mode=$mode' &&
                    window.currentDocument?.scripts?.ready == true,
                'leave no-store fragment group',
              );
              await tester.tap(find.byTooltip('返回'));
              await _until(
                tester,
                () =>
                    window.current?.url == secondFragment &&
                    window.currentDocument?.scripts?.ready == true &&
                    !identical(window.currentDocument, initialDocument),
                'refetch fragment group',
              );
              final fresh = window.currentDocument!;
              expect(fresh.content.text, isNot(initialDocument.content.text));
              await tester.tap(find.byTooltip('返回'));
              await _until(
                tester,
                () =>
                    window.current?.url == initialUrl &&
                    window.currentDocument?.scripts?.ready == true,
                'earlier fragment restores fresh document',
              );
              expect(window.currentDocument, same(fresh));
              expect(window.currentDocument!.referrer, '');
              await tester.tap(find.byTooltip('下一頁'));
              await _until(
                tester,
                () => window.current?.url == secondFragment,
                'forward fragment keeps fresh document',
              );
              expect(window.currentDocument, same(fresh));
              final actual = receipts.skip(start).toList();
              expect(
                actual.where(
                  (r) => Uri.parse(r['url']! as String).path == '/a',
                ),
                hasLength(2),
              );
              expect(
                actual.where(
                  (r) => Uri.parse(r['url']! as String).path == '/target',
                ),
                hasLength(1),
              );
              expect(errors, isEmpty);
              debugPrintSynchronously(
                'DOCUMENT_REFERRER_HISTORY_FRAGMENTS ${jsonEncode({'http': actual, 'initialBody': initialDocument.content.text, 'freshBody': fresh.content.text, 'currentUrl': window.current!.url, 'referrer': fresh.referrer, 'sameFreshDocument': identical(window.currentDocument, fresh)})}',
              );
              continue;
            }
            await _tapLink(tester, 'Open target');
            await _until(
              tester,
              () =>
                  window.current?.url == '$origin/target?mode=$mode' &&
                  window.currentDocument?.scripts?.ready == true,
              '$mode first target',
            );
            final first = window.currentDocument!;
            expect(
              first.referrer,
              mode == 'vary-origin' ? '$origin/' : '$origin/a?mode=$mode',
            );
            await tester.tap(find.byTooltip('返回'));
            await _until(
              tester,
              () => window.current?.url == '$origin/a?mode=$mode',
              '$mode back to source',
            );
            await _tapLink(tester, 'Other source');
            await _until(
              tester,
              () =>
                  window.current?.url == '$origin/b?mode=$mode' &&
                  window.currentDocument?.scripts?.ready == true,
              '$mode second source',
            );
            await _tapLink(tester, 'Open target');
            await _until(
              tester,
              () =>
                  window.current?.url == '$origin/target?mode=$mode' &&
                  window.currentDocument?.scripts?.ready == true &&
                  !identical(window.currentDocument, first),
              '$mode second target',
            );
            final expectedReferrer = mode == 'vary-origin'
                ? '$origin/'
                : '$origin/b?mode=$mode';
            expect(window.currentDocument!.referrer, expectedReferrer);
            final source = window.currentDocument!.scripts!.content!.text;
            final probe =
                jsonDecode(html.parse(source).querySelector('#probe')!.text)
                    as Map;
            expect(probe['referrer'], expectedReferrer);
            final targetRequests = receipts
                .skip(start)
                .where(
                  (item) => Uri.parse(item['url']! as String).path == '/target',
                )
                .toList();
            final expectedCount = ['fresh', 'vary-origin'].contains(mode)
                ? 1
                : 2;
            expect(targetRequests, hasLength(expectedCount));
            if (mode == '304') {
              expect(targetRequests.last['ifNoneMatch'], '"target-v1"');
            }
            if (mode == 'vary-full') {
              expect(targetRequests.last['ifNoneMatch'], isNull);
            }
            expect(errors, isEmpty);
            debugPrintSynchronously(
              'DOCUMENT_REFERRER_CACHE ${jsonEncode({'mode': mode, 'http': receipts.skip(start).toList(), 'nativeReferrer': window.currentDocument!.referrer, 'javascriptObservation': probe, 'targetRequests': targetRequests.length})}',
            );
          } finally {
            final documents = window.history
                .map((entry) => entry.document)
                .whereType<NativeFetchedDocument>()
                .toSet();
            await tester.pumpWidget(const SizedBox());
            windows.dispose();
            await Future.wait(
              documents
                  .map((document) => document.scripts?.closed)
                  .whereType<Future<void>>(),
            );
          }
        }
      } finally {
        await gateway.call('unpair');
        await listener.cancel();
        await server.close(force: true);
        tester.view.reset();
      }
    },
    timeout: const Timeout(Duration(minutes: 4)),
  );
}
