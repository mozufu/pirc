import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:pirc_mobile/live/document_navigation.dart';
import 'package:pirc_mobile/live/document_navigation_state.dart';
import 'package:pirc_mobile/live/gateway.dart';
import 'package:pirc_render/src/html_controls.dart';
import 'package:pirc_render/src/html_document_content.dart';
import 'package:pirc_mobile/theme.dart';

const checkableClicksHtml = '''<!doctype html><html><body>
<input id="normal" type="checkbox" name="normal" aria-label="normal">
<input id="cancelled" type="checkbox" name="cancelled" aria-label="cancelled">
<input id="mutated" type="checkbox" name="mutated" aria-label="mutated">
<input id="radio-one" type="radio" name="radio-group" checked aria-label="radio-one">
<input id="radio-two" type="radio" name="radio-group" aria-label="radio-two">
<input id="radio-cancel-one" type="radio" name="cancel-group" checked aria-label="radio-cancel-one">
<input id="radio-cancel-two" type="radio" name="cancel-group" aria-label="radio-cancel-two">
<label id="label"><span id="label-target">Label child tap</span><input id="label-check" type="checkbox" name="label-check" aria-label="label-check"></label>
<input id="disabled" type="checkbox" name="disabled" disabled aria-label="disabled">
<input id="rapid" type="checkbox" name="rapid" aria-label="rapid">
<pre id="result"></pre>
<script>
const logs = {
 normal: [], cancelled: [], mutated: [], radioOne: [], radioTwo: [],
 cancelRadioOne: [], cancelRadioTwo: [], label: [], disabled: [], rapid: []
};
function render() {
 document.querySelector('#result').textContent =
   'normal=[' + logs.normal.join(',') + '] ' +
   'cancelled=[' + logs.cancelled.join(',') + '] ' +
   'mutated=[' + logs.mutated.join(',') + '] ' +
   'radio-one=[' + logs.radioOne.join(',') + '] ' +
   'radio-two=[' + logs.radioTwo.join(',') + '] ' +
   'cancel-radio-one=[' + logs.cancelRadioOne.join(',') + '] ' +
   'cancel-radio-two=[' + logs.cancelRadioTwo.join(',') + '] ' +
   'label=[' + logs.label.join(',') + '] ' +
   'disabled=[' + logs.disabled.join(',') + '] ' +
   'rapid=[' + logs.rapid.join(',') + ']';
}
function track(id, name) {
 const input = document.querySelector('#' + id);
 for (const type of ['click', 'input', 'change']) {
  input.addEventListener(type, event => {
   logs[name].push(type + ':' + String(event.currentTarget.checked));
   render();
  });
 }
}
track('normal', 'normal');
track('cancelled', 'cancelled');
document.querySelector('#cancelled').addEventListener('click', event => {
 event.preventDefault();
});
track('mutated', 'mutated');
document.querySelector('#mutated').addEventListener('click', event => {
 event.currentTarget.checked = false;
});
track('radio-one', 'radioOne');
track('radio-two', 'radioTwo');
track('radio-cancel-one', 'cancelRadioOne');
track('radio-cancel-two', 'cancelRadioTwo');
document.querySelector('#radio-cancel-two').addEventListener('click', event => {
 event.preventDefault();
});
track('label-check', 'label');
document.addEventListener('click', event => {
 if (event.target.id === 'label-target') {
  logs.label.push('click:span');
  render();
 }
});
track('disabled', 'disabled');
track('rapid', 'rapid');
render();
</script></body></html>''';

Future<void> _tapText(WidgetTester t, String text) async {
  final finder = find.byWidgetPredicate(
    (widget) => widget is RichText && widget.text.toPlainText().contains(text),
    description: 'RichText containing "$text"',
  );
  expect(finder, findsOneWidget);
  await t.ensureVisible(finder);
  final paragraph = t.renderObject<RenderParagraph>(finder);
  final start = paragraph.text.toPlainText().indexOf(text);
  final boxes = paragraph.getBoxesForSelection(
    TextSelection(baseOffset: start, extentOffset: start + text.length),
  );
  expect(boxes, isNotEmpty);
  await t.tapAt(paragraph.localToGlobal(boxes.first.toRect().center));
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('native checkables match click activation and cancellation', (
    t,
  ) async {
    final gateway = Gateway();
    final theme = await PircTheme.load();
    final bytes = Uint8List.fromList(utf8.encode(checkableClicksHtml));
    final document = NativeFetchedDocument(
      id: 1,
      url: 'https://example.test/checkable-clicks',
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

    bool rendered(String value) => find
        .byWidgetPredicate(
          (widget) =>
              widget is RichText && widget.text.toPlainText().contains(value),
        )
        .evaluate()
        .isNotEmpty;

    Future<void> until(bool Function() ready, String label) async {
      for (var i = 0; i < 200 && !ready(); i++) {
        await t.pump(const Duration(milliseconds: 50));
      }
      expect(ready(), true, reason: '$label: ${document.scripts?.diagnostics}');
      expect(t.takeException(), isNull, reason: label);
    }

    Finder control(String name) => find.byWidgetPredicate(
      (widget) =>
          widget is NativeHtmlControlWidget && widget.control.label == name,
      description: 'NativeHtmlControlWidget named "$name"',
    );

    bool checked(String name) {
      final widget = t.widget<NativeHtmlControlWidget>(control(name));
      return widget.state.isChecked(widget.control.key);
    }

    Future<void> tapControl(String name) async {
      final finder = control(name);
      expect(finder, findsOneWidget);
      await t.ensureVisible(finder);
      await t.tap(finder);
    }

    try {
      await t.pumpWidget(
        MaterialApp(
          theme: theme.build(Brightness.light),
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
      await until(() => document.scripts?.ready == true, 'script ready');
      await t.pumpAndSettle();

      await tapControl('normal');
      await until(
        () => rendered('normal=[click:true,input:true,change:true]'),
        'checkbox click then input and change',
      );
      expect(checked('normal'), true);

      await tapControl('cancelled');
      await until(
        () => rendered('cancelled=[click:true]'),
        'prevented checkbox click has no input or change',
      );
      expect(checked('cancelled'), false);

      await tapControl('mutated');
      await until(
        () => rendered('mutated=[click:true,input:false,change:false]'),
        'click handler changes checkbox checkedness',
      );
      expect(checked('mutated'), false);

      await tapControl('radio-two');
      await until(
        () => rendered('radio-two=[click:true,input:true,change:true]'),
        'radio selection emits input and change',
      );
      expect(checked('radio-one'), false);
      expect(checked('radio-two'), true);
      await tapControl('radio-two');
      await until(
        () => rendered(
          'radio-two=[click:true,input:true,change:true,click:true]',
        ),
        'already selected radio emits click only',
      );

      await tapControl('radio-cancel-two');
      await until(
        () => rendered('cancel-radio-two=[click:true]'),
        'prevented radio click has no input or change',
      );
      expect(checked('radio-cancel-one'), true);
      expect(checked('radio-cancel-two'), false);

      await _tapText(t, 'Label child tap');
      await until(
        () => rendered('label=[click:span,click:true,input:true,change:true]'),
        'label child click activates input exactly once',
      );
      expect(checked('label-check'), true);

      await tapControl('disabled');
      await t.pump(const Duration(milliseconds: 100));
      expect(rendered('disabled=[]'), true);
      expect(checked('disabled'), false);

      final rapid = control('rapid');
      expect(rapid, findsOneWidget);
      await t.ensureVisible(rapid);
      await t.tap(rapid);
      await t.tap(rapid);
      await until(
        () => rendered(
          'rapid=[click:true,input:true,change:true,click:false,input:false,change:false]',
        ),
        'two rapid checkbox activations restore initial checkedness',
      );
      expect(checked('rapid'), false);
      expect(document.scripts!.diagnostics, isEmpty);
    } finally {
      await t.pumpWidget(const SizedBox());
      document.dispose();
    }
  });
}
