import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:pirc_mobile/live/document_navigation.dart';
import 'package:pirc_mobile/live/document_navigation_state.dart';
import 'package:pirc_mobile/live/gateway.dart';
import 'package:pirc_render/src/html_buttons.dart';
import 'package:pirc_render/src/html_controls.dart';
import 'package:pirc_render/src/html_document_content.dart';
import 'package:pirc_render/src/html_form_submission.dart';
import 'package:pirc_mobile/theme.dart';

const formEventsHtml = '''<!doctype html><html><body>
<form id="form" action="/original">
<label for="query">Query</label><input id="query" name="query" required>
<label><input id="enabled" type="checkbox">Enabled</label>
<button id="preview" type="submit">Preview</button>
<button id="send" type="submit" name="intent" value="send">Send</button>
</form>
<p id="echo">Waiting</p><p id="committed">No change</p><p id="submitted">No submit</p>
<script>
const form = document.querySelector('#form');
const field = document.querySelector('#query');
form.addEventListener('input', event => {
 document.querySelector('#echo').textContent = 'Input: ' + field.value + ' / ' + document.querySelector('#enabled').checked;
});
form.addEventListener('change', event => {
 document.querySelector('#committed').textContent = 'Changed: ' + event.target.id;
});
form.addEventListener('submit', event => {
 if (event.submitter.id === 'preview') {
  event.preventDefault();
  document.querySelector('#submitted').textContent = 'Preview: ' + field.value;
 } else {
  field.value = 'server:' + field.value;
  form.setAttribute('action', '/changed');
 }
});
</script></body></html>''';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'real Android input change and submit events keep native editing alive',
    (t) async {
      final g = Gateway(), theme = await PircTheme.load();
      final bytes = Uint8List.fromList(utf8.encode(formEventsHtml));
      final document = NativeFetchedDocument(
        id: 1,
        url: 'https://example.test/form',
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
      final submissions = <NativeHtmlFormSubmission>[];
      Future<void> until(bool Function() ready, String label) async {
        for (var i = 0; i < 150 && !ready(); i++) {
          await t.pump(const Duration(milliseconds: 50));
        }
        expect(
          ready(),
          true,
          reason: '$label: ${document.scripts?.diagnostics}',
        );
        expect(t.takeException(), isNull, reason: label);
      }

      Finder button(String label) => find.byWidgetPredicate(
        (w) => w is NativeHtmlButtonWidget && w.button.label == label,
      );
      Future<void> tapButton(String label) async {
        await t.ensureVisible(button(label));
        await t.tap(button(label));
        await t.pump(const Duration(milliseconds: 100));
      }

      try {
        await t.pumpWidget(
          MaterialApp(
            theme: theme.build(Brightness.light),
            home: Scaffold(
              body: NativeFetchedDocumentView(
                document: document,
                gateway: g,
                onLink: (_) {},
                onSubmit: submissions.add,
              ),
            ),
          ),
        );
        await until(() => document.scripts?.ready == true, 'script ready');
        await t.pumpAndSettle();
        await tapButton('Preview');
        await t.pumpAndSettle();
        expect(find.text('No submit', findRichText: true), findsOneWidget);
        final field = t.widget<TextField>(find.byType(TextField)),
            controller = field.controller!,
            focus = field.focusNode!;
        await t.enterText(find.byType(TextField), 'ab');
        await until(
          () => find
              .text('Input: ab / false', findRichText: true)
              .evaluate()
              .isNotEmpty,
          'first input',
        );
        expect(
          identical(
            t.widget<TextField>(find.byType(TextField)).controller,
            controller,
          ),
          true,
        );
        expect(focus.hasFocus, true);
        t.testTextInput.updateEditingValue(
          const TextEditingValue(
            text: 'ab漢',
            selection: TextSelection.collapsed(offset: 3),
            composing: TextRange(start: 2, end: 3),
          ),
        );
        await until(
          () => find
              .text('Input: ab漢 / false', findRichText: true)
              .evaluate()
              .isNotEmpty,
          'composing input',
        );
        expect(controller.value.composing, const TextRange(start: 2, end: 3));
        expect(focus.hasFocus, true);
        t.testTextInput.updateEditingValue(
          const TextEditingValue(
            text: 'ab漢',
            selection: TextSelection.collapsed(offset: 3),
          ),
        );
        focus.unfocus();
        await until(
          () => find
              .text('Changed: query', findRichText: true)
              .evaluate()
              .isNotEmpty,
          'blur change',
        );
        final check = find.byType(NativeHtmlControlWidget);
        await t.ensureVisible(check);
        await t.tap(check);
        await until(
          () => find
              .text('Input: ab漢 / true', findRichText: true)
              .evaluate()
              .isNotEmpty,
          'checkbox input',
        );
        await until(
          () => find
              .text('Changed: enabled', findRichText: true)
              .evaluate()
              .isNotEmpty,
          'checkbox change',
        );
        await tapButton('Preview');
        await until(
          () => find
              .text('Preview: ab漢', findRichText: true)
              .evaluate()
              .isNotEmpty,
          'prevented submit',
        );
        expect(submissions, isEmpty);
        await tapButton('Send');
        await until(() => submissions.length == 1, 'default submit');
        expect(submissions.single.action, '/changed');
        expect(
          submissions.single.entries.map((e) => [e.name, e.value]),
          contains(equals(['query', 'server:ab漢'])),
        );
        expect(
          submissions.single.entries.map((e) => [e.name, e.value]),
          contains(equals(['intent', 'send'])),
        );
      } finally {
        await t.pumpWidget(const SizedBox());
        document.dispose();
      }
    },
  );
}
