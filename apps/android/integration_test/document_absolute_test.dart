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
import 'package:pirc_render/src/native_html.dart';
import 'package:pirc_mobile/theme.dart';

const fixtureOrigin = String.fromEnvironment('PIRC_CHART_FIXTURE_ORIGIN');
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'native positioned documents retain flow, clicks and style updates',
    (tester) async {
      final uri = Uri.parse(fixtureOrigin);
      expect(uri.host, '127.0.0.1');
      expect(uri.scheme, 'http');
      final client = HttpClient();
      late Json fixture;
      try {
        final response = await (await client.getUrl(
          uri.resolve('/absolute.json'),
        )).close();
        expect(response.statusCode, 200);
        fixture = obj(jsonDecode(await utf8.decoder.bind(response).join()));
      } finally {
        client.close(force: true);
      }
      final g = Gateway(), theme = await PircTheme.load();
      final accepted = <Json>[];
      final cases = (fixture['cases'] as List).where(
        (r) => const {
          'left_top',
          'percent',
          'viewport',
          'nested_host',
          'absolute_canvas',
          'overlap_z',
        }.contains(r['name']),
      );
      expect(cases.length, 48);
      for (final raw in cases) {
        final row = obj(raw);
        final width = (row['width'] as num).toDouble(),
            dpr = (row['dpr'] as num).toDouble(),
            height = width == 390 ? 844.0 : 1024.0;
        tester.view.devicePixelRatio = dpr;
        tester.view.physicalSize = Size(width * dpr, height * dpr);
        final ids = obj(row['observed']).keys.toList();
        final script =
            '''<pre id="status">WAIT</pre><script>
    var phase='initial',clicks=[];
    function report(){var boxes={};${jsonEncode(ids)}.forEach(function(id){var r=document.getElementById(id).getBoundingClientRect();boxes[id]={x:r.x,y:r.y,width:r.width,height:r.height};});document.getElementById('status').textContent=JSON.stringify({phase:phase,clicks:clicks,boxes:boxes});}
    Array.from(document.querySelectorAll('#abs,#one,#two,#abs2')).forEach(function(e){e.addEventListener('click',function(){clicks.push(e.id);phase='updated';e.style.left='41px';e.style.right='auto';e.style.top='45px';e.style.bottom='auto';e.style.width='80px';e.style.height='55px';requestAnimationFrame(report);});});
    requestAnimationFrame(report);
   </script>''';
        final source = (row['html'] as String).replaceFirst(
          '</body>',
          '$script</body>',
        );
        final bytes = utf8.encode(source);
        final document = NativeFetchedDocument(
          id: 1,
          url: 'https://example.test/absolute',
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
                  gateway: g,
                  onLink: (_) {},
                  onSubmit: (_) {},
                ),
              ),
            ),
          );
          Future<Json> ready(String phase) async {
            for (var i = 0; i < 200; i++) {
              await tester.pump(const Duration(milliseconds: 30));
              final text =
                  html
                      .parse(document.scripts?.content?.text ?? '')
                      .getElementById('status')
                      ?.text ??
                  '';
              if (text.startsWith('{')) {
                final state = obj(jsonDecode(text));
                if (state['phase'] == phase) return state;
              }
            }
            fail('${row['name']} $phase ${document.scripts?.diagnostics}');
          }

          final initial = await ready('initial'),
              actual = obj(initial['boxes']),
              expected = obj(row['observed']);
          var maxDelta = 0.0;
          for (final id in ids) {
            for (final axis in ['x', 'y', 'width', 'height']) {
              final delta =
                  ((obj(actual[id])[axis] as num) -
                          (obj(expected[id])[axis] as num))
                      .abs()
                      .toDouble();
              if (delta > maxDelta) maxDelta = delta;
              expect(
                delta,
                lessThanOrEqualTo(row['name'] == 'percent' ? 1 / 64 : .01),
                reason: '${row['name']} $id.$axis',
              );
            }
          }
          final sample = obj((row['pixels'] as List).first);
          final target = sample['hit'] as String;
          final origin = tester.getTopLeft(find.byType(NativeHtmlDocument));
          await tester.tapAt(
            origin +
                Offset(
                  (sample['x'] as num).toDouble(),
                  (sample['y'] as num).toDouble(),
                ),
          );
          final updated = await ready('updated');
          expect(updated['clicks'], [target]);
          final updatedBoxes = obj(updated['boxes']),
              box = obj(updatedBoxes[target]);
          final parent = row['name'] == 'nested_host'
              ? obj(updatedBoxes['inner'])
              : row['name'] == 'viewport'
              ? <String, dynamic>{'x': 0, 'y': 0}
              : obj(updatedBoxes['host']);
          final border = row['name'] == 'nested_host'
              ? 2
              : row['name'] == 'viewport'
              ? 0
              : 4;
          expect(box['x'], closeTo((parent['x'] as num) + border + 41, .01));
          expect(box['y'], closeTo((parent['y'] as num) + border + 45, .01));
          expect(box['width'], 80);
          expect(box['height'], 55);
          for (final id in ['one', 'two', 'after']) {
            expect(
              updatedBoxes[id],
              actual[id],
              reason: '${row['name']} update must not change $id flow',
            );
          }
          expect(document.scripts!.diagnostics, isEmpty);
          expect(tester.takeException(), isNull);
          accepted.add({
            'name': row['name'],
            'width': width,
            'dpr': dpr,
            'theme': row['theme'],
            'maxGeometryDelta': maxDelta,
            'initial': initial,
            'updated': updated,
          });
          debugPrintSynchronously(
            'PIRC_ABSOLUTE_PROGRESS ${accepted.length}/48',
          );
        } finally {
          await tester.pumpWidget(const SizedBox.shrink());
          document.dispose();
          if (document.scripts != null) await document.scripts!.closed;
          tester.view.reset();
        }
      }
      expect(accepted, hasLength(48));
      debugPrintSynchronously(
        'PIRC_NATIVE_ABSOLUTE_ACCEPTANCE ${jsonEncode(accepted)}',
      );
    },
    skip: fixtureOrigin.isEmpty,
  );
}
