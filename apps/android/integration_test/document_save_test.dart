import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:pirc_mobile/live/document_navigation.dart';
import 'package:pirc_mobile/live/document_navigation_state.dart';
import 'package:pirc_mobile/live/gateway.dart';
import 'package:pirc_render/src/html_form_submission.dart';
import 'package:pirc_mobile/theme.dart';

class SaveObservingGateway extends Gateway {
  final firstSave = Completer<dynamic>();
  @override
  Future<dynamic> call(String method, [Json args = const {}]) async {
    final result = await super.call(method, args);
    if (method == 'saveDocument' && !firstSave.isCompleted) {
      firstSave.complete(result);
    }
    return result;
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'real Android saves exact document bytes and cancellation retains source',
    (t) async {
      expect(const bool.fromEnvironment('PIRC_DOCUMENTS'), isTrue);
      final g = SaveObservingGateway();
      await g.call('pair', {
        'link': const String.fromEnvironment('PIRC_PAIR_LINK'),
      });
      await g.call('completeOnboarding');
      final boot = obj(await g.call('boot'));
      final origin = boot['origin'] as String;
      final windows = NativeDocumentWindows(g);
      final w = windows.target('', null, sourceUrl: '$origin/source');
      Future<List<Json>> receipts() async {
        final r = obj(
          await g.call('document', {
            'url': '$origin/parity-documents/receipt',
            'method': 'GET',
            'pairingStamp': boot['pairingStamp'],
          }),
        );
        return rows(
          obj(jsonDecode(utf8.decode(r['bytes'] as Uint8List)))['requests'],
        );
      }

      try {
        expect(
          await w.load(
            const NativeHtmlFormRequest(
              url: '/parity-documents/download-source',
              method: 'GET',
              target: '',
            ),
            baseUrl: '$origin/',
          ),
          NativeDocumentLoadResult.committed,
        );
        final source = w.current;
        windows.select(w);
        await t.pumpWidget(
          MaterialApp(
            theme: (await PircTheme.load()).build(Brightness.light),
            home: NativeDocumentWorkspace(windows: windows, managed: true),
          ),
        );
        await t.pumpAndSettle();
        await t.enterText(find.byType(TextField), 'edited before save');
        final link = find
            .byWidgetPredicate(
              (widget) =>
                  widget is RichText &&
                  widget.text.toPlainText().contains('Save report'),
            )
            .first;
        final rich = t.widget<RichText>(link);
        final render = t.renderObject<RenderParagraph>(link);
        final start = rich.text.toPlainText().indexOf('Save report');
        final box = render
            .getBoxesForSelection(
              TextSelection(baseOffset: start, extentOffset: start + 1),
            )
            .first
            .toRect();
        debugPrint('DOCUMENT_SAVE:save-next');
        await t.tapAt(render.localToGlobal(box.center));
        await t.pump();
        final saved = obj(
          await g.firstSave.future.timeout(const Duration(seconds: 45)),
        );
        expect(saved['bytesWritten'], 7);
        expect(saved['name'], 'pirc-save-acceptance.bin');
        await t.pumpAndSettle();
        expect(w.current, same(source));
        expect(
          t.widget<TextField>(find.byType(TextField)).controller!.text,
          'edited before save',
        );
        expect(t.takeException(), isNull);
        debugPrint('DOCUMENT_SAVE:saved-source-retained');

        debugPrint('DOCUMENT_SAVE:cancel-next');
        final cancelled = w.load(
          const NativeHtmlFormRequest(
            url: '/parity-documents/download-file',
            method: 'POST',
            target: '',
            body: 'exact=body',
          ),
          baseUrl: '$origin/',
        );
        expect(
          await cancelled.timeout(const Duration(seconds: 45)),
          NativeDocumentLoadResult.retained,
        );
        await t.pumpAndSettle();
        expect(w.current, same(source));
        expect(w.history, hasLength(1));
        expect(
          t.widget<TextField>(find.byType(TextField)).controller!.text,
          'edited before save',
        );
        final downloads = (await receipts())
            .where((r) => r['path'] == '/parity-documents/download-file')
            .toList();
        expect(downloads.map((r) => r['method']), ['GET', 'POST']);
        expect(downloads.last['body'], 'exact=body');
        expect(t.takeException(), isNull);
        debugPrint('DOCUMENT_SAVE:accepted-save-cancel-no-post-replay');
      } finally {
        await t.pumpWidget(const SizedBox());
        windows.dispose();
        await g.call('unpair');
      }
    },
  );
}
