import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:integration_test/integration_test.dart';
import 'package:flutter/foundation.dart' show debugPrintSynchronously;
import 'package:pirc_mobile/live/gateway.dart';
import 'package:pirc_render/src/html_document_urls.dart';
import 'package:pirc_mobile/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:html/parser.dart' as html;
import 'package:pirc_mobile/live/document_navigation.dart';
import 'package:pirc_mobile/live/document_navigation_state.dart';
import 'package:pirc_render/src/document_fragment.dart';
import 'package:pirc_render/src/html_form_submission.dart';

const fixtureOrigin = String.fromEnvironment('PIRC_CHART_FIXTURE_ORIGIN');
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'native fragment URL and repeated activation agree with Chromium',
    (tester) async {
      final origin = Uri.parse(fixtureOrigin);
      expect(origin.scheme, 'http');
      expect(origin.host, '127.0.0.1');
      final client = HttpClient();
      late Map fixture;
      try {
        final response = await (await client.getUrl(
          origin.resolve('/fragment.json'),
        )).close();
        expect(response.statusCode, 200);
        fixture = jsonDecode(await utf8.decoder.bind(response).join()) as Map;
      } finally {
        client.close(force: true);
      }
      expect(fixture['browserVersion'], '153.0.8010.12');
      expect(fixture['cases'], hasLength(152));
      final theme = await PircTheme.load(), accepted = <Map>[];
      for (final row in fixture['cases'] as List) {
        {
          final viewport = Size(
                (row['viewport']['width'] as num).toDouble(),
                (row['viewport']['height'] as num).toDouble(),
              ),
              dpr = (row['dpr'] as num).toDouble();
          tester.view.devicePixelRatio = dpr;
          tester.view.physicalSize = viewport * dpr;
          final gateway = DocumentGateway()
                ..responses.add(response('/fragment', row['html'] as String)),
              windows = NativeDocumentWindows(gateway),
              window = windows.target(
                'report',
                null,
                sourceUrl: 'https://gateway.example/',
              );
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
          accepted.add({
            'mode': row['mode'],
            'viewport': row['viewport'],
            'dpr': row['dpr'],
            'theme': row['theme'],
            'root': document.scroll.lastKnownOffset,
            'historyLength': window.history.length,
          });
          windows.dispose();
          tester.view.reset();
          if (accepted.length % 32 == 0) {
            debugPrintSynchronously(
              'PIRC_FRAGMENT_PROGRESS ${accepted.length}/152',
            );
          }
        }
      }
      expect(accepted, hasLength(152));
      debugPrintSynchronously(
        'PIRC_NATIVE_FRAGMENT_ACCEPTANCE ${jsonEncode(accepted)}',
      );
    },
    skip: fixtureOrigin.isEmpty,
  );
}

class DocumentGateway extends Gateway {
  final calls = <Json>[], responses = <Json>[];
  @override
  Future<dynamic> call(String method, [Json args = const {}]) async {
    if (method == 'boot') {
      return {'origin': 'https://gateway.example', 'pairingStamp': 'stamp'};
    }
    if (method == 'resolveDocumentUrl') {
      return resolveNativeDocumentUrl(
        args['reference'] as String,
        args['baseUrl'] as String,
      );
    }
    if (method == 'documentPrepareRequest') {
      return {
        'nativeCookieRequestKey':
            'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
      };
    }
    if (method == 'document') {
      calls.add(args);
      return responses.removeAt(0);
    }
    return {};
  }
}

Json response(String path, String body) => {
  'status': 200,
  'finalUrl': 'https://gateway.example$path',
  'finalMethod': 'GET',
  'mimeType': 'text/html',
  'charset': 'UTF-8',
  'bytes': Uint8List.fromList(utf8.encode(body)),
  'headersRelevant': <String, dynamic>{},
};
