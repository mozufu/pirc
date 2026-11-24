import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:pirc_mobile/live/document_navigation.dart';
import 'package:pirc_mobile/live/document_navigation_state.dart';
import 'package:pirc_mobile/live/gateway.dart';
import 'package:pirc_mobile/theme.dart';
import 'package:pirc_render/src/html_buttons.dart';
import 'package:pirc_render/src/html_document_content.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'Android isolated JS paints DOM and handles native Flutter buttons',
    (t) async {
      final g = Gateway();
      final theme = await PircTheme.load();
      final capability = obj(await g.call('documentScriptCapabilities'));
      expect(capability['supported'], true, reason: '$capability');
      const owner = 'integration-isolation';
      final id = obj(
        await g.call('documentScriptOpen', {
          'owner': owner,
          'documentUrl': 'https://example.test/demo',
        }),
      )['id'];
      Future<dynamic> evaluate(String source, {String identity = owner}) =>
          g.call('documentScriptEvaluate', {
            'id': id,
            'owner': identity,
            'source': source,
          });
      expect(
        obj(await evaluate('globalThis.counter = 8; "ready"'))['value'],
        'ready',
      );
      expect(obj(await evaluate('String(++counter)'))['value'], '9');
      await expectLater(
        evaluate('"wrong"', identity: 'wrong-owner'),
        throwsA(isA<PlatformException>()),
      );
      await expectLater(
        evaluate('while(true){}'),
        throwsA(
          isA<PlatformException>().having(
            (e) => e.code,
            'code',
            'SCRIPT_TIMEOUT',
          ),
        ),
      );
      await expectLater(
        evaluate('"retired"'),
        throwsA(isA<PlatformException>()),
      );
      final bytes = Uint8List.fromList(
        utf8.encode('''<!doctype html><html><body>
      <h1>Native script test</h1><div id="items"></div>
      <input id="name" value="初始"><button id="increment" type="button">Add item</button>
      <p id="result">Count 0</p><button type="button" onclick="document.querySelector('#name').value='Script reset'">Reset field</button>
      <script>
      let count = 0;
      const items = document.querySelector('#items');
      ['Alpha','Beta','Gamma'].forEach(name => {const p=document.createElement('p');p.textContent=name;items.appendChild(p);});
      document.querySelector('#increment').addEventListener('click', () => {
        document.querySelector('#result').textContent = 'Count ' + (++count) + ': ' + document.querySelector('#name').value;
      });
      </script></body></html>'''),
      );
      final document = NativeFetchedDocument(
        id: 1,
        url: 'https://example.test/demo',
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
        await t.pumpWidget(
          MaterialApp(
            theme: theme.build(Brightness.light),
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
        for (var i = 0; i < 100 && document.scripts?.ready != true; i++) {
          await t.pump(const Duration(milliseconds: 100));
        }
        expect(
          document.scripts?.ready,
          true,
          reason: '${document.scripts?.diagnostics}',
        );
        await t.pumpAndSettle();
        expect(find.text('Alpha', findRichText: true), findsOneWidget);
        expect(find.text('Gamma', findRichText: true), findsOneWidget);
        debugPrint(
          'SCRIPT_BUTTONS:${t.widgetList<NativeHtmlButtonWidget>(find.byType(NativeHtmlButtonWidget)).map((w) => w.button.label).toList()}',
        );
        await t.enterText(find.byType(TextField), 'Flutter 原生');
        await t.tap(
          find.byWidgetPredicate(
            (w) => w is NativeHtmlButtonWidget && w.button.label == 'Add item',
          ),
        );
        for (
          var i = 0;
          i < 100 &&
              !document.scripts!.content!.text.contains('Count 1: Flutter 原生');
          i++
        ) {
          await t.pump(const Duration(milliseconds: 100));
        }
        await t.pumpAndSettle();
        expect(
          find.text('Count 1: Flutter 原生', findRichText: true),
          findsOneWidget,
        );
        await t.tap(
          find.byWidgetPredicate(
            (w) => w is NativeHtmlButtonWidget && w.button.label == 'Add item',
          ),
        );
        for (
          var i = 0;
          i < 100 &&
              !document.scripts!.content!.text.contains('Count 2: Flutter 原生');
          i++
        ) {
          await t.pump(const Duration(milliseconds: 100));
        }
        await t.pumpAndSettle();
        expect(
          find.text('Count 2: Flutter 原生', findRichText: true),
          findsOneWidget,
        );
        await t.tap(
          find.byWidgetPredicate(
            (w) =>
                w is NativeHtmlButtonWidget && w.button.label == 'Reset field',
          ),
        );
        for (
          var i = 0;
          i < 100 &&
              !document.scripts!.content!.text.contains('value="Script reset"');
          i++
        ) {
          await t.pump(const Duration(milliseconds: 100));
        }
        await t.pumpAndSettle();
        expect(
          t.widget<TextField>(find.byType(TextField)).controller!.text,
          'Script reset',
        );
        expect(t.takeException(), isNull);
      } finally {
        await t.pumpWidget(const SizedBox());
        document.dispose();
      }
    },
  );
}
