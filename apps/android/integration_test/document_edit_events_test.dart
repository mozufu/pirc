import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:html/parser.dart' as html;
import 'package:integration_test/integration_test.dart';
import 'package:pirc_mobile/live/document_navigation.dart';
import 'package:pirc_mobile/live/document_navigation_state.dart';
import 'package:pirc_mobile/live/gateway.dart';
import 'package:pirc_render/src/html_document_content.dart';
import 'package:pirc_render/src/html_form_submission.dart';
import 'package:pirc_mobile/theme.dart';

const documentEditHtml = '''<!doctype html><html><body>
<input id="query" aria-label="Query">
<textarea id="notes" aria-label="Notes"></textarea>
<pre id="oracle" style="font-size:1px;line-height:1px;max-height:1px;overflow:hidden"></pre>
<script>
const oracle = document.querySelector('#oracle');
const rows = [];
function render() {
 oracle.textContent = JSON.stringify(rows);
}
function record(type, field, event) {
 const row = {
  type,
  field: field.id,
  activeElement: document.activeElement.id || null,
  value: field.value
 };
 if (type.startsWith('composition')) row.data = event.data ?? null;
 if (type === 'input') {
  row.data = event.data ?? null;
  row.inputType = event.inputType ?? null;
  row.isComposing = event.isComposing ?? null;
 }
 rows.push(row);
 render();
}
for (const field of [document.querySelector('#query'), document.querySelector('#notes')]) {
 for (const type of [
  'focus', 'focusin', 'blur', 'focusout', 'click',
  'compositionstart', 'compositionupdate', 'compositionend', 'input'
 ]) {
  field.addEventListener(type, event => record(type, field, event));
 }
}
render();
</script></body></html>''';

const enterFormsHtml = '''<!doctype html><html><body>
<form id="cancel-form" action="/cancel">
  <input id="cancel-input" name="value" aria-label="Cancel value">
  <button id="cancel-submit" type="submit">Cancel submit</button>
</form>
<form id="allow-form" action="/allow">
  <input id="allow-input" name="value" aria-label="Allowed value">
  <button id="allow-submit" type="submit">Allow submit</button>
</form>
<pre id="oracle" style="font-size:1px;line-height:1px;max-height:1px;overflow:hidden"></pre>
<script>
const oracle = document.querySelector('#oracle');
const rows = [];
function render() {
 oracle.textContent = JSON.stringify(rows);
}
function record(type, target, extra = {}) {
 rows.push({type, target, ...extra});
 render();
}
const cancelInput = document.querySelector('#cancel-input');
const allowInput = document.querySelector('#allow-input');
for (const field of [cancelInput, allowInput]) {
 field.addEventListener('keydown', event => {
  if (field.id === 'cancel-input' && event.key === 'Enter') {
   event.preventDefault();
  }
  if (field.id === 'allow-input' && event.key === 'Enter') {
   document.querySelector('#allow-form').action = '/updated-allow';
  }
  record('keydown', field.id, {
   key: event.key,
   code: event.code,
   ctrlKey: event.ctrlKey,
   shiftKey: event.shiftKey,
   altKey: event.altKey,
   metaKey: event.metaKey,
   isComposing: event.isComposing,
   defaultPrevented: event.defaultPrevented
  });
 });
 field.addEventListener('keyup', event => record('keyup', field.id, {
  key: event.key,
  code: event.code
 }));
 field.addEventListener('input', event => record('input', field.id, {
  value: field.value,
  data: event.data ?? null,
  inputType: event.inputType ?? null,
  isComposing: event.isComposing ?? null
 }));
}
document.querySelector('#cancel-form').addEventListener('submit', event => {
 event.preventDefault();
 record('submit', 'cancel-form', {
  defaultPrevented: event.defaultPrevented,
  value: cancelInput.value
 });
});
document.querySelector('#allow-form').addEventListener('submit', event => {
 record('submit', 'allow-form', {
  defaultPrevented: event.defaultPrevented,
  value: allowInput.value
 });
});
render();
</script></body></html>''';

NativeFetchedDocument _document(String url, String source) {
  final bytes = Uint8List.fromList(utf8.encode(source));
  return NativeFetchedDocument(
    id: 1,
    url: url,
    status: 200,
    bytes: bytes,
    mimeType: 'text/html',
    headers: const {},
    content: NativeHtmlDocumentContent.fromBytes(
      bytes,
      mimeType: 'text/html',
      charset: 'utf-8',
    ),
  );
}

List<Map<String, dynamic>> _oracleRows(NativeFetchedDocument document) {
  final source = document.scripts?.content?.text;
  if (source == null) return const [];
  final encoded = html.parse(source).querySelector('#oracle')?.text.trim();
  if (encoded == null || encoded.isEmpty) return const [];
  return (jsonDecode(encoded) as List<dynamic>).cast<Map<String, dynamic>>();
}

Future<void> _until(
  WidgetTester tester,
  NativeFetchedDocument document,
  bool Function() predicate,
  String label,
) async {
  for (var i = 0; i < 200 && !predicate(); i++) {
    await tester.pump(const Duration(milliseconds: 25));
  }
  expect(
    predicate(),
    isTrue,
    reason: '$label: ${document.scripts?.diagnostics}',
  );
  expect(tester.takeException(), isNull, reason: label);
}

Finder _field(int index) => find.byType(TextField).at(index);

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'native document text controls preserve focus and report each edit once',
    (t) async {
      final theme = await PircTheme.load();
      final document = _document(
        'https://example.test/document-edit-events',
        documentEditHtml,
      );

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
        await _until(
          t,
          document,
          () => document.scripts?.ready == true,
          'document script ready',
        );
        expect(document.scripts!.diagnostics, isEmpty);
        expect(find.byType(TextField), findsNWidgets(2));

        final queryFinder = _field(0);
        final notesFinder = _field(1);
        final query = t.widget<TextField>(queryFinder);
        final controller = query.controller!;
        final focus = query.focusNode!;

        await t.ensureVisible(queryFinder);
        await t.tap(queryFinder);
        await _until(
          t,
          document,
          () => _oracleRows(
            document,
          ).any((row) => row['type'] == 'click' && row['field'] == 'query'),
          'query receives a real tap',
        );
        expect(focus.hasFocus, isTrue);
        final queryLifecycle = _oracleRows(document)
            .where((row) => row['field'] == 'query')
            .map((row) => row['type'])
            .toList();
        final queryFocusIndex = queryLifecycle.indexOf('focus');
        final queryFocusinIndex = queryLifecycle.indexOf('focusin');
        final queryClickIndex = queryLifecycle.indexOf('click');
        expect(queryFocusIndex, greaterThanOrEqualTo(0));
        expect(queryFocusinIndex, greaterThan(queryFocusIndex));
        expect(queryClickIndex, greaterThan(queryFocusinIndex));

        await t.ensureVisible(notesFinder);
        await t.tap(notesFinder);
        await _until(
          t,
          document,
          () => _oracleRows(
            document,
          ).any((row) => row['type'] == 'click' && row['field'] == 'notes'),
          'textarea receives a real tap',
        );
        expect(focus.hasFocus, isFalse);
        expect(t.widget<TextField>(notesFinder).focusNode!.hasFocus, isTrue);
        final lifecycle = _oracleRows(document);
        final queryBlurLifecycle = lifecycle
            .where((row) => row['field'] == 'query')
            .map((row) => row['type'])
            .toList();
        expect(queryBlurLifecycle.indexOf('blur'), greaterThanOrEqualTo(0));
        expect(
          queryBlurLifecycle.indexOf('focusout'),
          greaterThan(queryBlurLifecycle.indexOf('blur')),
        );
        final notesLifecycle = lifecycle
            .where((row) => row['field'] == 'notes')
            .map((row) => row['type'])
            .toList();
        final notesFocusIndex = notesLifecycle.indexOf('focus');
        final notesFocusinIndex = notesLifecycle.indexOf('focusin');
        final notesClickIndex = notesLifecycle.indexOf('click');
        expect(notesFocusIndex, greaterThanOrEqualTo(0));
        expect(notesFocusinIndex, greaterThan(notesFocusIndex));
        expect(notesClickIndex, greaterThan(notesFocusinIndex));

        await t.ensureVisible(queryFinder);
        await t.tap(queryFinder);
        await _until(t, document, () => focus.hasFocus, 'query refocuses');
        expect(
          identical(t.widget<TextField>(queryFinder).controller, controller),
          isTrue,
        );
        expect(
          identical(t.widget<TextField>(queryFinder).focusNode, focus),
          isTrue,
        );

        t.testTextInput.updateEditingValue(
          const TextEditingValue(
            text: 'a',
            selection: TextSelection.collapsed(offset: 1),
          ),
        );
        await _until(
          t,
          document,
          () =>
              _oracleRows(document)
                  .where(
                    (row) => row['type'] == 'input' && row['field'] == 'query',
                  )
                  .length ==
              1,
          'plain edit dispatches one input',
        );
        expect(controller.text, 'a');
        expect(focus.hasFocus, isTrue);
        expect(
          identical(t.widget<TextField>(queryFinder).controller, controller),
          isTrue,
        );

        t.testTextInput.updateEditingValue(
          const TextEditingValue(
            text: 'a漢',
            selection: TextSelection.collapsed(offset: 2),
            composing: TextRange(start: 1, end: 2),
          ),
        );
        await _until(
          t,
          document,
          () =>
              _oracleRows(document)
                  .where(
                    (row) => row['type'] == 'input' && row['field'] == 'query',
                  )
                  .length ==
              2,
          'composing edit dispatches one input',
        );
        final inputs = _oracleRows(document)
            .where((row) => row['type'] == 'input' && row['field'] == 'query')
            .toList();
        expect(inputs[0]['value'], 'a');
        expect(inputs[0]['data'], 'a');
        expect(inputs[0]['inputType'], 'insertText');
        expect(inputs[0]['isComposing'], false);
        expect(inputs[1]['value'], 'a漢');
        expect(inputs[1]['data'], '漢');
        expect(inputs[1]['inputType'], 'insertCompositionText');
        expect(inputs[1]['isComposing'], true);
        expect(controller.value.composing, const TextRange(start: 1, end: 2));
        expect(focus.hasFocus, isTrue);
        expect(
          identical(t.widget<TextField>(queryFinder).controller, controller),
          isTrue,
        );

        t.testTextInput.updateEditingValue(
          const TextEditingValue(
            text: 'a漢',
            selection: TextSelection.collapsed(offset: 2),
          ),
        );
        await _until(
          t,
          document,
          () => _oracleRows(document).any(
            (row) => row['type'] == 'compositionend' && row['field'] == 'query',
          ),
          'same-text IME commit ends composition',
        );
        expect(controller.value.composing.isCollapsed, isTrue);
        expect(
          _oracleRows(
            document,
          ).where((row) => row['type'] == 'input' && row['field'] == 'query'),
          hasLength(2),
          reason:
              'A range-only composition commit does not invent another input event.',
        );
        expect(focus.hasFocus, isTrue);
        expect(
          identical(t.widget<TextField>(queryFinder).controller, controller),
          isTrue,
        );
        expect(document.scripts!.diagnostics, isEmpty);
      } finally {
        await t.pumpWidget(const SizedBox());
        document.dispose();
      }
    },
  );

  testWidgets(
    'Enter honors keydown cancellation and updated form action after DOM mutation',
    (t) async {
      final theme = await PircTheme.load();
      final document = _document(
        'https://example.test/enter-form-events',
        enterFormsHtml,
      );
      final submissions = <NativeHtmlFormSubmission>[];

      try {
        await t.pumpWidget(
          MaterialApp(
            theme: theme.build(Brightness.light),
            home: Scaffold(
              body: NativeFetchedDocumentView(
                document: document,
                gateway: Gateway(),
                onLink: (_) {},
                onSubmit: submissions.add,
              ),
            ),
          ),
        );
        await _until(
          t,
          document,
          () => document.scripts?.ready == true,
          'document script ready',
        );
        expect(document.scripts!.diagnostics, isEmpty);

        final cancelFinder = _field(0);
        final cancelField = t.widget<TextField>(cancelFinder);
        final cancelController = cancelField.controller!;
        final cancelFocus = cancelField.focusNode!;
        await t.ensureVisible(cancelFinder);
        await t.tap(cancelFinder);
        t.testTextInput.updateEditingValue(
          const TextEditingValue(
            text: 'blocked',
            selection: TextSelection.collapsed(offset: 7),
          ),
        );
        await _until(
          t,
          document,
          () => cancelController.text == 'blocked',
          'canceled form field accepts native text input',
        );
        expect(
          identical(
            t.widget<TextField>(cancelFinder).controller,
            cancelController,
          ),
          isTrue,
        );
        expect(cancelFocus.hasFocus, isTrue);

        await t.sendKeyEvent(LogicalKeyboardKey.enter);
        await _until(
          t,
          document,
          () => _oracleRows(document).any(
            (row) =>
                row['type'] == 'keydown' &&
                row['target'] == 'cancel-input' &&
                row['key'] == 'Enter',
          ),
          'keydown handler prevents Enter after updating the DOM',
        );
        expect(submissions, isEmpty);
        expect(cancelFocus.hasFocus, isTrue);
        expect(
          identical(
            t.widget<TextField>(cancelFinder).controller,
            cancelController,
          ),
          isTrue,
        );
        final cancelRows = _oracleRows(document);
        expect(
          cancelRows.where(
            (row) => row['type'] == 'submit' && row['target'] == 'cancel-form',
          ),
          isEmpty,
          reason:
              'Prevented Enter dispatches neither submit nor native onSubmit.',
        );
        final cancelEnter = cancelRows.singleWhere(
          (row) =>
              row['type'] == 'keydown' &&
              row['target'] == 'cancel-input' &&
              row['key'] == 'Enter',
        );
        expect(cancelEnter['code'], 'Enter');
        expect(cancelEnter['ctrlKey'], isFalse);
        expect(cancelEnter['shiftKey'], isFalse);
        expect(cancelEnter['defaultPrevented'], isTrue);

        final allowFinder = _field(1);
        final allowField = t.widget<TextField>(allowFinder);
        final allowController = allowField.controller!;
        final allowFocus = allowField.focusNode!;
        await t.ensureVisible(allowFinder);
        await t.tap(allowFinder);
        t.testTextInput.updateEditingValue(
          const TextEditingValue(
            text: 'allowed',
            selection: TextSelection.collapsed(offset: 7),
          ),
        );
        await _until(
          t,
          document,
          () => allowController.text == 'allowed',
          'allowed form field accepts native text input',
        );
        expect(allowFocus.hasFocus, isTrue);
        expect(
          identical(
            t.widget<TextField>(allowFinder).controller,
            allowController,
          ),
          isTrue,
        );

        await t.sendKeyEvent(LogicalKeyboardKey.enter);
        await _until(
          t,
          document,
          () =>
              submissions.length == 1 &&
              _oracleRows(document).any(
                (row) =>
                    row['type'] == 'submit' && row['target'] == 'allow-form',
              ),
          'allowed Enter reaches native onSubmit after the keydown mutation',
        );

        final allowRows = _oracleRows(document);
        final allowKeydownIndex = allowRows.indexWhere(
          (row) =>
              row['type'] == 'keydown' &&
              row['target'] == 'allow-input' &&
              row['key'] == 'Enter',
        );
        final allowSubmitIndex = allowRows.indexWhere(
          (row) => row['type'] == 'submit' && row['target'] == 'allow-form',
        );
        expect(allowKeydownIndex, greaterThanOrEqualTo(0));
        expect(allowSubmitIndex, greaterThan(allowKeydownIndex));
        expect(allowRows[allowKeydownIndex]['defaultPrevented'], isFalse);
        expect(allowRows[allowSubmitIndex]['defaultPrevented'], isFalse);
        expect(allowController.text, 'allowed');
        expect(allowFocus.hasFocus, isTrue);
        expect(
          identical(
            t.widget<TextField>(allowFinder).controller,
            allowController,
          ),
          isTrue,
        );
        expect(submissions.single.action, '/updated-allow');
        expect(
          submissions.single.entries.map((entry) => [entry.name, entry.value]),
          contains(equals(['value', 'allowed'])),
        );
        expect(document.scripts!.diagnostics, isEmpty);
      } finally {
        await t.pumpWidget(const SizedBox());
        document.dispose();
      }
    },
  );
}
