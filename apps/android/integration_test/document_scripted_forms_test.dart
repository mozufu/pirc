import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:html/parser.dart' as html;
import 'package:integration_test/integration_test.dart';
import 'package:pirc_mobile/live/document_navigation.dart';
import 'package:pirc_mobile/live/document_navigation_state.dart';
import 'package:pirc_mobile/live/gateway.dart';
import 'package:pirc_render/src/html_buttons.dart';
import 'package:pirc_render/src/html_document_content.dart';
import 'package:pirc_render/src/html_form_submission.dart';
import 'package:pirc_mobile/theme.dart';

const scriptedFormsHtml = '''<!doctype html><html><body>
<iframe name="default-sink" hidden></iframe><iframe name="submit-sink" hidden></iframe>
<form id="direct-form" action="/programmatic" method="post" target="default-sink">
  <input id="direct-value" name="value" value="initial" required>
  <input id="direct-empty" name="empty" value="" required>
</form>
<p id="direct-events">invalid=0,submit=0</p><p id="direct-result">idle</p>
<button id="run-direct" type="button">Run form.submit()</button>

<form id="sync-form" action="/sync" method="get" target="default-sink">
  <input id="sync-value" name="value" value="sync" required>
</form>
<p id="sync-order">idle</p><button id="run-sync" type="button">Run requestSubmit()</button>

<form id="invalid-form" action="/invalid" method="get" target="default-sink">
  <input id="invalid-value" name="value" value="" required>
</form>
<p id="invalid-result">idle</p><button id="run-invalid" type="button">Run invalid requestSubmit</button>

<form id="cancel-form" action="/cancel" method="get" target="default-sink">
  <input name="value" value="cancelled">
</form>
<p id="cancel-result">idle</p><button id="run-cancel" type="button">Run cancelled requestSubmit</button>

<form id="novalidate-form" action="/novalidate" method="get" target="default-sink" novalidate>
  <input id="novalidate-value" name="value" value="" required>
</form>
<p id="novalidate-result">idle</p><button id="run-novalidate" type="button">Run novalidate requestSubmit</button>

<form id="override-form" action="/base" method="get" enctype="application/x-www-form-urlencoded" target="default-sink">
  <input id="override-value" name="payload" value="" required>
  <button id="override-submit" type="submit" name="intent" value="launch" formnovalidate formaction="/override" formmethod="post" formenctype="text/plain" formtarget="submit-sink">Override submitter</button>
</form>
<p id="override-result">submitter=none; clicks=0</p><button id="run-override" type="button">Run submitter requestSubmit</button>

<form id="error-form" action="/errors" method="get" target="default-sink"></form>
<form id="foreign-form"></form>
<button id="not-submit" type="button" form="error-form">Not a submitter</button>
<button id="foreign-submit" type="submit" form="foreign-form">Foreign submitter</button>
<p id="error-result">idle</p><button id="run-errors" type="button">Check requestSubmit errors</button>

<form id="double-form" action="/double" method="post" target="default-sink">
  <input id="double-value" name="value" value="initial">
</form>
<button id="run-double" type="button">Run two same-form submits</button>

<form id="button-submit-form" action="/button-submit" method="post" target="default-sink">
  <input name="value" value="submit">
  <button id="button-submit" type="submit">Submit from onclick</button>
</form>
<form id="button-request-form" action="/button-request" method="post" target="default-sink">
  <input name="value" value="request">
  <button id="button-request" type="submit">requestSubmit from onclick</button>
</form>
<p id="button-submit-result">idle</p>
<script>
const directForm = document.querySelector('#direct-form');
const directValue = document.querySelector('#direct-value');
let directInvalid = 0;
let directSubmit = 0;
function renderDirect() {
 document.querySelector('#direct-events').textContent =
   'invalid=' + directInvalid + ',submit=' + directSubmit;
}
document.querySelector('#direct-empty').addEventListener('invalid', () => {
 directInvalid++;
 renderDirect();
});
directForm.addEventListener('submit', () => {
 directSubmit++;
 renderDirect();
});
function runDirect() {
 directValue.value = 'captured-at-call';
 directForm.submit();
 directValue.value = 'after-call';
 document.querySelector('#direct-result').textContent = directValue.value;
}

const syncForm = document.querySelector('#sync-form');
let syncOrder = [];
function renderSync() {
 document.querySelector('#sync-order').textContent = syncOrder.join(',');
}
syncForm.addEventListener('submit', () => {
 syncOrder.push('submit');
 renderSync();
});
function runSync() {
 syncOrder = ['before'];
 renderSync();
 syncForm.requestSubmit();
 syncOrder.push('after');
 renderSync();
}

const invalidForm = document.querySelector('#invalid-form');
const invalidValue = document.querySelector('#invalid-value');
let invalidEvents = [];
function renderInvalid() {
 document.querySelector('#invalid-result').textContent = invalidEvents.join(',');
}
invalidValue.addEventListener('invalid', () => {
 invalidEvents.push('invalid');
 renderInvalid();
});
invalidForm.addEventListener('submit', () => {
 invalidEvents.push('submit');
 renderInvalid();
});
function runInvalid() {
 invalidEvents = [];
 invalidForm.requestSubmit();
 renderInvalid();
}

const cancelForm = document.querySelector('#cancel-form');
let cancelEvents = [];
cancelForm.addEventListener('submit', event => {
 cancelEvents.push('submit');
 event.preventDefault();
 document.querySelector('#cancel-result').textContent = cancelEvents.join(',');
});
function runCancel() {
 cancelEvents = [];
 cancelForm.requestSubmit();
 document.querySelector('#cancel-result').textContent = cancelEvents.join(',');
}

const novalidateForm = document.querySelector('#novalidate-form');
novalidateForm.addEventListener('submit', () => {
 document.querySelector('#novalidate-result').textContent = 'submit';
});
function runNovalidate() {
 novalidateForm.requestSubmit();
}

const overrideForm = document.querySelector('#override-form');
const overrideSubmitter = document.querySelector('#override-submit');
let overrideClicks = 0;
overrideSubmitter.addEventListener('click', () => {
 overrideClicks++;
});
overrideForm.addEventListener('submit', event => {
 document.querySelector('#override-result').textContent =
   'submitter=' + event.submitter.id + '; clicks=' + overrideClicks;
});
function runOverride() {
 overrideForm.requestSubmit(overrideSubmitter);
}

function runErrors() {
 const errors = [];
 const form = document.querySelector('#error-form');
 try {
  form.requestSubmit(document.querySelector('#not-submit'));
 } catch (error) {
  errors.push(error.name);
 }
 try {
  form.requestSubmit(document.querySelector('#foreign-submit'));
 } catch (error) {
  errors.push(error.name);
 }
 document.querySelector('#error-result').textContent = errors.join(',');
}

function runDouble() {
 const form = document.querySelector('#double-form');
 const field = document.querySelector('#double-value');
 field.value = 'first';
 form.submit();
 field.value = 'last';
 form.submit();
}

document.querySelector('#button-submit').onclick = () => {
 document.querySelector('#button-submit-form').submit();
};
document.querySelector('#button-request').onclick = event => {
 document.querySelector('#button-request-form').requestSubmit(event.currentTarget);
};
document.querySelector('#run-direct').addEventListener('click', runDirect);
document.querySelector('#run-sync').addEventListener('click', runSync);
document.querySelector('#run-invalid').addEventListener('click', runInvalid);
document.querySelector('#run-cancel').addEventListener('click', runCancel);
document.querySelector('#run-novalidate').addEventListener('click', runNovalidate);
document.querySelector('#run-override').addEventListener('click', runOverride);
document.querySelector('#run-errors').addEventListener('click', runErrors);
document.querySelector('#run-double').addEventListener('click', runDouble);
</script></body></html>''';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('programmatic form methods preserve browser submit semantics', (
    t,
  ) async {
    final gateway = Gateway();
    final theme = await PircTheme.load();
    final bytes = Uint8List.fromList(utf8.encode(scriptedFormsHtml));
    final document = NativeFetchedDocument(
      id: 1,
      url: 'https://example.test/scripted-forms',
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
    bool visible(String text) =>
        find.text(text, findRichText: true).evaluate().isNotEmpty;
    Future<void> until(bool Function() ready, String label) async {
      for (var i = 0; i < 200 && !ready(); i++) {
        await t.pump(const Duration(milliseconds: 50));
      }
      expect(ready(), true, reason: '$label: ${document.scripts?.diagnostics}');
      expect(t.takeException(), isNull, reason: label);
    }

    Finder button(String label) => find.byWidgetPredicate(
      (widget) =>
          widget is NativeHtmlButtonWidget && widget.button.label == label,
    );

    Future<void> tapButton(String label) async {
      final finder = button(label);
      expect(finder, findsOneWidget, reason: 'button: $label');
      await t.ensureVisible(finder);
      await t.tap(finder);
      await t.pumpAndSettle();
    }

    List<List<String>> entries(NativeHtmlFormSubmission submission) => [
      for (final entry in submission.entries) [entry.name, entry.value],
    ];

    int countFor(String action) =>
        submissions.where((submission) => submission.action == action).length;

    Future<void> untilCount(int expected, String label) =>
        until(() => submissions.length == expected, label);

    try {
      await t.pumpWidget(
        MaterialApp(
          theme: theme.build(Brightness.light),
          home: Scaffold(
            body: NativeFetchedDocumentView(
              document: document,
              gateway: gateway,
              onLink: (_) {},
              onSubmit: submissions.add,
            ),
          ),
        ),
      );
      await until(() => document.scripts?.ready == true, 'script ready');
      await t.pumpAndSettle();

      await tapButton('Run form.submit()');
      await untilCount(1, 'form.submit bypasses validation and captures');
      final direct = submissions[0];
      expect(direct.action, '/programmatic');
      expect(direct.method.toLowerCase(), 'post');
      expect(entries(direct), [
        ['value', 'captured-at-call'],
        ['empty', ''],
      ]);
      expect(visible('after-call'), true);
      expect(visible('invalid=0,submit=0'), true);

      await tapButton('Run requestSubmit()');
      await untilCount(2, 'requestSubmit emits submit and sends');
      expect(visible('before,submit,after'), true);
      expect(submissions[1].action, '/sync');
      expect(entries(submissions[1]), [
        ['value', 'sync'],
      ]);

      await tapButton('Run invalid requestSubmit');
      await until(() => visible('invalid'), 'required control fires invalid');
      expect(submissions, hasLength(2));
      expect(
        html
            .parse(document.scripts!.content!.text)
            .querySelector('#invalid-result')!
            .text,
        'invalid',
      );

      await tapButton('Run cancelled requestSubmit');
      await until(() => visible('submit'), 'cancelled submit event');
      expect(submissions, hasLength(2));

      await tapButton('Run novalidate requestSubmit');
      await untilCount(3, 'novalidate form submits despite required empty');
      expect(submissions[2].action, '/novalidate');
      expect(entries(submissions[2]), [
        ['value', ''],
      ]);

      await tapButton('Run submitter requestSubmit');
      await untilCount(4, 'formnovalidate submitter overrides form');
      final override = submissions[3];
      expect(override.action, '/override');
      expect(override.method.toLowerCase(), 'post');
      expect(override.enctype, 'text/plain');
      expect(override.target, 'submit-sink');
      expect(override.targetSpecified, true);
      expect(override.submitterId, 'override-submit');
      expect(entries(override), [
        ['payload', ''],
        ['intent', 'launch'],
      ]);
      expect(visible('submitter=override-submit; clicks=0'), true);

      await tapButton('Check requestSubmit errors');
      await until(
        () => visible('TypeError,NotFoundError'),
        'requestSubmit validates submitter arguments',
      );
      expect(submissions, hasLength(4));

      await tapButton('Run two same-form submits');
      await untilCount(5, 'same-form submissions keep the last request');
      expect(countFor('/double'), 1);
      expect(entries(submissions[4]), [
        ['value', 'last'],
      ]);

      await tapButton('Submit from onclick');
      await untilCount(6, 'submit button onclick form.submit');
      await t.pump(const Duration(milliseconds: 150));
      expect(countFor('/button-submit'), 1);

      await tapButton('requestSubmit from onclick');
      await untilCount(7, 'submit button onclick requestSubmit');
      await t.pump(const Duration(milliseconds: 150));
      expect(countFor('/button-request'), 1);
      expect(entries(submissions[5]), [
        ['value', 'submit'],
      ]);
      expect(entries(submissions[6]), [
        ['value', 'request'],
      ]);
      expect(document.scripts!.diagnostics, isEmpty);
    } finally {
      await t.pumpWidget(const SizedBox());
      document.dispose();
    }
  });
}
