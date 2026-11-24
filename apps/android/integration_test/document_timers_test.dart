import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:pirc_mobile/live/document_navigation.dart';
import 'package:pirc_mobile/live/document_navigation_state.dart';
import 'package:pirc_mobile/live/gateway.dart';
import 'package:pirc_render/src/html_buttons.dart';
import 'package:pirc_render/src/html_document_content.dart';
import 'package:pirc_mobile/theme.dart';

const timersHtml = '''<!doctype html><html><body>
<p id="timeout">Timeout waiting</p><p id="interval">Interval 0</p>
<p id="frames">Frames 0</p><p id="microtask">Microtask waiting</p>
<p id="canceled">Canceled work stayed canceled</p>
<input id="entry" value="Initial"><button id="start" type="button">Start delayed update</button>
<p id="result">No delayed result</p><p id="clock">Clock waiting</p>
<script>
const started = performance.now();
setTimeout((word) => { document.querySelector('#timeout').textContent = 'Timeout ' + word; }, 30, 'done');
let count = 0;
const interval = setInterval(() => {
 document.querySelector('#interval').textContent = 'Interval ' + (++count);
 if (count === 3) clearInterval(interval);
}, 25);
let frames = 0, previous = -1;
function animate(timestamp) {
 if (timestamp < previous) throw new Error('Frame timestamp moved backwards');
 previous = timestamp;
 document.querySelector('#frames').textContent = 'Frames ' + (++frames);
 if (frames < 3) requestAnimationFrame(animate);
 else document.querySelector('#clock').textContent = performance.now() >= started ? 'Clock monotonic' : 'Clock invalid';
}
requestAnimationFrame(animate);
const canceledTimer = setTimeout(() => { document.querySelector('#canceled').textContent = 'Bad timer'; }, 10);
clearInterval(canceledTimer);
const canceledFrame = requestAnimationFrame(() => { document.querySelector('#canceled').textContent = 'Bad frame'; });
cancelAnimationFrame(canceledFrame);
Promise.resolve().then(() => {
 document.querySelector('#microtask').textContent = 'Microtask ready';
 setTimeout(() => { document.querySelector('#microtask').textContent = 'Microtask timer done'; }, 40);
});
document.querySelector('#start').onclick = () => {
 Promise.resolve().then(() => {
  document.querySelector('#result').textContent = 'Promise update';
  setTimeout(() => { document.querySelector('#result').textContent = 'Delayed: ' + document.querySelector('#entry').value; }, 120);
 });
};
</script></body></html>''';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'Android timers frames and microtasks update the native document',
    (t) async {
      final theme = await PircTheme.load();
      final bytes = Uint8List.fromList(utf8.encode(timersHtml));
      final document = NativeFetchedDocument(
        id: 1,
        url: 'https://example.test/timers',
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
      bool visible(String text) =>
          find.text(text, findRichText: true).evaluate().isNotEmpty;
      Future<void> until(bool Function() condition, String label) async {
        for (var i = 0; i < 200 && !condition(); i++) {
          await t.pump(const Duration(milliseconds: 25));
        }
        expect(
          condition(),
          true,
          reason: '$label: ${document.scripts?.diagnostics}',
        );
        expect(t.takeException(), isNull, reason: label);
      }

      try {
        await t.pumpWidget(
          MaterialApp(
            theme: theme.build(Brightness.light),
            home: Scaffold(
              body: NativeFetchedDocumentView(
                document: document,
                gateway: Gateway(),
                onLink: (_) {},
                onSubmit: (_) {},
              ),
            ),
          ),
        );
        await until(
          () =>
              visible('Timeout done') &&
              visible('Interval 3') &&
              visible('Frames 3') &&
              visible('Microtask timer done'),
          'startup callbacks',
        );
        expect(visible('Clock monotonic'), true);
        expect(visible('Canceled work stayed canceled'), true);
        await t.enterText(find.byType(TextField), '原生輸入');
        await t.pump(const Duration(milliseconds: 50));
        final button = find.byWidgetPredicate(
          (w) =>
              w is NativeHtmlButtonWidget &&
              w.button.label == 'Start delayed update',
        );
        await t.ensureVisible(button);
        await t.tap(button);
        await until(
          () => visible('Delayed: 原生輸入'),
          'delayed event reads current input',
        );
        expect(document.scripts!.diagnostics, isEmpty);
        await t.pump(const Duration(milliseconds: 200));
        expect(visible('Interval 3'), true);
        expect(visible('Frames 3'), true);
      } finally {
        await t.pumpWidget(const SizedBox());
        document.dispose();
      }
    },
  );
}
