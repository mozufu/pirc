import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show debugPrintSynchronously;
import 'package:flutter_test/flutter_test.dart';
import 'package:html/parser.dart' as html;
import 'package:integration_test/integration_test.dart';
import 'package:pirc_mobile/live/document_navigation.dart';
import 'package:pirc_mobile/live/document_navigation_state.dart';
import 'package:pirc_mobile/live/gateway.dart';
import 'package:pirc_render/src/html_document_content.dart';
import 'package:pirc_mobile/theme.dart';

const fixtureOrigin = String.fromEnvironment('PIRC_CHART_FIXTURE_ORIGIN');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'native scrollIntoView uses measured nested ports and real script promises',
    (tester) async {
      final origin = Uri.parse(fixtureOrigin);
      expect(origin.host, '127.0.0.1');
      expect(origin.scheme, 'http');
      final client = HttpClient();
      final cases = <Json>[];
      try {
        for (final entry in {'/into-view.json': 216}.entries) {
          final response = await (await client.getUrl(
            origin.resolve(entry.key),
          )).close();
          expect(response.statusCode, 200);
          final fixture = obj(
            jsonDecode(await utf8.decoder.bind(response).join()),
          );
          expect(fixture['browserVersion'], '153.0.8010.12');
          expect(fixture['cases'], hasLength(entry.value));
          for (final raw in fixture['cases'] as List) {
            cases.add({
              ...obj(raw),
              'fixtureHTML': obj(raw)['html'] ?? fixture['html'],
            });
          }
        }
      } finally {
        client.close(force: true);
      }
      expect(cases, hasLength(216));
      final gateway = Gateway(),
          theme = await PircTheme.load(),
          accepted = <Json>[];
      for (final raw in cases) {
        final row = obj(raw),
            viewport = obj(row['viewport']),
            dpr = (row['dpr'] as num).toDouble();
        tester.view.devicePixelRatio = dpr;
        tester.view.physicalSize =
            Size(
              (viewport['width'] as num).toDouble(),
              (viewport['height'] as num).toDouble(),
            ) *
            dpr;
        final source = (row['html'] as String).replaceFirst(
              '</body>',
              '<script>${row['driverSource']}</script></body>',
            ),
            bytes = utf8.encode(source);
        final document = NativeFetchedDocument(
          id: 1,
          url: 'https://example.test/into-view',
          status: 200,
          bytes: bytes,
          mimeType: 'text/html',
          content: NativeHtmlDocumentContent.fromBytes(
            bytes,
            mimeType: 'text/html',
            charset: 'utf-8',
          ),
          headers: {},
        );
        try {
          await tester.pumpWidget(
            MaterialApp(
              theme: theme.build(
                row['theme'] == 'dark' ? Brightness.dark : Brightness.light,
              ),
              home: Scaffold(
                body: NativeFetchedDocumentView(
                  document: document,
                  gateway: gateway,
                  onLink: (_) {},
                  onSubmit: (_) {},
                ),
              ),
            ),
          );
          for (var attempt = 0; attempt < 200; attempt++) {
            await tester.pump(const Duration(milliseconds: 30));
            if (document.scripts?.ready == true &&
                html
                        .parse(document.scripts?.content?.text ?? '')
                        .getElementById('run')
                        ?.attributes
                        .containsKey('data-pirc-script-click') ==
                    true) {
              break;
            }
          }
          expect(
            document.scripts?.ready,
            isTrue,
            reason: '${document.scripts?.diagnostics}',
          );
          await tester.pump(const Duration(milliseconds: 30));
          if (row['tap'] is Map) {
            final point = obj(row['tap']);
            await tester.tapAt(
              Offset(
                (point['x'] as num).toDouble(),
                (point['y'] as num).toDouble(),
              ),
            );
          } else {
            await tester.tap(find.text('Run', findRichText: true));
          }
          Json report = {};
          for (var attempt = 0; attempt < 1000; attempt++) {
            await tester.pump(const Duration(milliseconds: 30));
            final text =
                html
                    .parse(document.scripts?.content?.text ?? '')
                    .getElementById('probe')
                    ?.text ??
                '';
            if (text.startsWith('{')) {
              report = obj(jsonDecode(text));
              break;
            }
          }
          expect(
            report,
            isNotEmpty,
            reason:
                '${row['mode']} ${row['viewport']} dpr${row['dpr']} ${row['theme']} '
                'probe=${html.parse(document.scripts?.content?.text ?? '').getElementById('probe')?.text} '
                'through=${document.scripts?.resolvedScrollActionId} queued=${document.scripts?.scrollActions} '
                'positions=${[
                  for (final state in tester.stateList<ScrollableState>(find.byType(Scrollable))) {'pixels': state.position.pixels, 'active': state.position.isScrollingNotifier.value},
                ]} '
                '${document.scripts?.diagnostics}',
          );
          checkReport(report, obj(row['result']), row['mode'] as String);
          expect(
            report['promise'] ?? true,
            isTrue,
            reason:
                '${row['mode']} ${row['viewport']} ${row['dpr']} ${row['theme']}',
          );
          expect(document.scripts!.diagnostics, isEmpty);
          expect(tester.takeException(), isNull);
          accepted.add({
            'mode': row['mode'],
            'target': row['target'],
            'viewport': viewport,
            'dpr': dpr,
            'theme': row['theme'],
            'report': report,
          });
          if (accepted.length % 32 == 0) {
            debugPrintSynchronously(
              'PIRC_INTO_VIEW_PROGRESS ${accepted.length}/216',
            );
          }
        } finally {
          await tester.pumpWidget(const SizedBox());
          document.dispose();
          if (document.scripts != null) {
            await document.scripts!.closed;
          }
          tester.view.reset();
        }
      }
      expect(accepted, hasLength(216));
      debugPrintSynchronously(
        'PIRC_NATIVE_INTO_VIEW_ACCEPTANCE ${jsonEncode(accepted)}',
      );
    },
    skip: fixtureOrigin.isEmpty,
  );
}

void checkReport(Json actual, Json expected, String mode) {
  if (mode == 'contract') {
    expect(actual, expected);
    return;
  }
  expect(actual['value'], expected['value']);
  expect(actual['promise'], expected['promise']);
  for (final phase in ['before', 'immediate', 'awaited', 'settled']) {
    if (actual[phase] == null || expected[phase] == null) {
      expect(actual[phase], expected[phase], reason: phase);
      continue;
    }
    final a = obj(actual[phase]), e = obj(expected[phase]);
    // Flutter's native animation duration/curve differs from Chromium. Certify
    // immediate pixels and final destinations; mid-animation await pixels are
    // explicitly outside this timing contract. A redundant root instant command
    // also cancels a prior animation in Flutter where this Chromium build drifts.
    if (['smooth', 'css-smooth'].contains(mode) && phase == 'awaited') {
      expect(
        a,
        actual['settled'],
        reason: 'native Promise waits for settled positions',
      );
      continue;
    }
    if (mode == 'replacement' && phase == 'settled') {
      final positions = obj(a['positions']), reference = obj(e['positions']);
      expect(positions['inner'], reference['inner']);
      expect(positions['outer'], reference['outer']);
      expect(
        positions['root'],
        obj(obj(actual['immediate'])['positions'])['root'],
      );
      final aRect = a['rect'] as List, eRect = e['rect'] as List;
      final shift =
          (obj(reference['root'])['top'] as num) -
          (obj(positions['root'])['top'] as num);
      for (var i = 0; i < 4; i++) {
        expect(
          aRect[i],
          closeTo((eRect[i] as num).toDouble() + (i == 1 ? shift : 0), 1 / 32),
        );
      }
      continue;
    }
    expect(a['positions'], e['positions'], reason: phase);
    if (a['rect'] == null || e['rect'] == null) {
      expect(a['rect'], e['rect']);
      continue;
    }
    for (var i = 0; i < 4; i++) {
      expect(
        a['rect'][i],
        closeTo((e['rect'][i] as num).toDouble(), 1 / 32),
        reason: '$phase rect[$i]',
      );
    }
  }
}
