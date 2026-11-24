import 'dart:convert';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:pirc_mobile/live/document_navigation.dart';
import 'package:pirc_mobile/live/document_navigation_state.dart';
import 'package:pirc_mobile/live/gateway.dart';
import 'package:pirc_render/src/document_canvas.dart';
import 'package:pirc_render/src/html_buttons.dart';
import 'package:pirc_render/src/html_document_content.dart';
import 'package:pirc_mobile/theme.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'Android JS Canvas paints and redraws natively with unchanged DOM',
    (t) async {
      final theme = await PircTheme.load();
      final bytes = Uint8List.fromList(
        utf8.encode('''<!doctype html><html><body style="margin:0">
<canvas id="chart" width="120" height="60" style="width:240px;height:120px"></canvas>
<button id="next" type="button">Redraw chart</button>
<input value="initial">
<script>
const canvas = document.querySelector('#chart');
const ctx = canvas.getContext('2d');
ctx.fillStyle = '#ff0000'; ctx.fillRect(0,0,120,60);
document.querySelector('#next').onclick = () => {
  ctx.clearRect(0,0,120,60);
  ctx.fillStyle = '#0000ff'; ctx.fillRect(0,0,120,60);
  setTimeout(() => {ctx.fillStyle = '#00ff00';ctx.fillRect(0,0,120,60);}, 500);
};
</script></body></html>'''),
      );
      final document = NativeFetchedDocument(
        id: 1,
        url: 'https://example.test/chart',
        status: 200,
        bytes: bytes,
        mimeType: 'text/html',
        headers: {},
        content: NativeHtmlDocumentContent.fromBytes(
          bytes,
          mimeType: 'text/html',
          charset: 'utf-8',
        ),
      );
      final boundary = GlobalKey();
      Future<void> until(bool Function() predicate) async {
        for (var i = 0; i < 150 && !predicate(); i++) {
          await t.pump(const Duration(milliseconds: 25));
        }
        expect(predicate(), true, reason: '${document.scripts?.diagnostics}');
        expect(t.takeException(), isNull);
      }

      Future<List<int>> pixel() async {
        final render =
            boundary.currentContext!.findRenderObject()!
                as RenderRepaintBoundary;
        final image = await render.toImage(pixelRatio: 1);
        final data = (await image.toByteData(
          format: ui.ImageByteFormat.rawRgba,
        ))!;
        final origin =
            t.getTopLeft(find.byType(NativeDocumentCanvas)) -
            t.getTopLeft(find.byKey(boundary));
        final offset =
            ((origin.dy + 20).round() * image.width +
                (origin.dx + 20).round()) *
            4;
        final result = data.buffer.asUint8List().sublist(offset, offset + 4);
        image.dispose();
        return result;
      }

      try {
        await t.pumpWidget(
          MaterialApp(
            theme: theme.build(Brightness.light),
            home: Scaffold(
              body: RepaintBoundary(
                key: boundary,
                child: NativeFetchedDocumentView(
                  document: document,
                  gateway: Gateway(),
                  onLink: (_) {},
                  onSubmit: (_) {},
                ),
              ),
            ),
          ),
        );
        await until(
          () =>
              document.scripts?.ready == true &&
              find.byType(NativeDocumentCanvas).evaluate().isNotEmpty,
        );
        await t.pumpAndSettle();
        expect(document.scripts!.diagnostics, isEmpty);
        expect(
          t.getSize(find.byType(NativeDocumentCanvas)),
          const Size(240, 120),
        );
        expect(await pixel(), [255, 0, 0, 255]);
        await t.enterText(find.byType(TextField), 'retained draft');
        final revision = document.scripts!.canvases.values.single.revision;
        await t.tap(
          find.byWidgetPredicate(
            (w) =>
                w is NativeHtmlButtonWidget && w.button.label == 'Redraw chart',
          ),
        );
        await until(
          () => document.scripts!.canvases.values.single.revision > revision,
        );
        final afterClick = document.scripts!.canvases.values.single.revision;
        final afterClickContent = document.scripts!.content;
        await until(
          () => document.scripts!.canvases.values.single.revision > afterClick,
        );
        await t.pumpAndSettle();
        expect(await pixel(), [0, 255, 0, 255]);
        // User input synchronizes its value attribute once during dispatch. The
        // timer redraw itself must not depend on another DOM mutation.
        expect(
          document.scripts!.content!.bodyInnerHtml,
          contains('retained draft'),
        );
        expect(document.scripts!.content, same(afterClickContent));
        expect(
          t.widget<TextField>(find.byType(TextField)).controller!.text,
          'retained draft',
        );
        expect(document.scripts!.diagnostics, isEmpty);
      } finally {
        await t.pumpWidget(const SizedBox());
        document.dispose();
        await t.pumpAndSettle();
      }
    },
  );
}
