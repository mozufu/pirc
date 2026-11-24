import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart' as md;
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_render/src/html_buttons.dart';
import 'package:pirc_render/src/html_controls.dart';
import 'package:pirc_render/src/html_form_submission.dart';
import 'package:pirc_render/src/html_select.dart';
import 'package:pirc_render/src/html_syntax.dart';
import 'package:pirc_render/src/native_html.dart';

import 'live_test.dart' show theme;

Widget _page(
  String source, {
  ValueChanged<NativeHtmlFormSubmission>? onFormSubmit,
  Future<bool> Function(String, List<Map<String, dynamic>>)? onScriptClick,
  Future<bool> Function(
    String,
    String,
    List<Map<String, dynamic>>, {
    String? submitter,
  })?
  onScriptEvent,
  Object? scriptDocument,
}) => MaterialApp(
  theme: theme.build(Brightness.light),
  home: Scaffold(
    body: SingleChildScrollView(
      child: NativeHtmlDocument(
        nodes: [NativeHtmlRaw(source)],
        style: const TextStyle(fontSize: 16),
        styles: md.MarkdownStyleSheet(),
        builders: const {},
        markdownStyles: false,
        onFormSubmit: onFormSubmit,
        onScriptClick: onScriptClick,
        onScriptEvent: onScriptEvent,
        scriptDocument: scriptDocument,
      ),
    ),
  ),
);

Finder _button(String label) => find.byWidgetPredicate(
  (widget) => widget is NativeHtmlButtonWidget && widget.button.label == label,
);

void main() {
  testWidgets(
    'submit event validates first and carries submitter with current values',
    (t) async {
      const source =
          '<form data-pirc-script-id="form" action="/send"><input name="q" required data-pirc-script-id="q"><button data-pirc-script-id="send">Send</button></form>';
      final events = <String>[];
      List<Map<String, dynamic>>? submittedControls;
      final submissions = <NativeHtmlFormSubmission>[];
      await t.pumpWidget(
        _page(
          source,
          scriptDocument: Object(),
          onFormSubmit: submissions.add,
          onScriptEvent: (id, type, controls, {submitter}) async {
            events.add('$type:$id:$submitter');
            if (type == 'submit') {
              submittedControls = controls;
              return true;
            }
            return false;
          },
        ),
      );
      await t.pumpAndSettle();
      await t.tap(_button('Send'));
      await t.pumpAndSettle();
      expect(events.where((e) => e.startsWith('submit:')), isEmpty);
      await t.enterText(find.byType(EditableText), 'filled');
      await t.tap(_button('Send'));
      await t.pumpAndSettle();
      expect(events.where((e) => e.startsWith('submit:')), [
        'submit:form:send',
      ]);
      expect(
        submittedControls,
        contains(equals({'id': 'q', 'value': 'filled'})),
      );
      expect(submissions, isEmpty);
      expect(t.takeException(), isNull);
    },
  );
  testWidgets('pending general click cannot submit a replacement document', (
    t,
  ) async {
    const source =
        '<form data-pirc-script-id="form"><button data-pirc-script-id="send">Send</button></form>';
    final pending = Completer<bool>();
    final submissions = <NativeHtmlFormSubmission>[];
    await t.pumpWidget(
      _page(
        source,
        scriptDocument: Object(),
        onFormSubmit: submissions.add,
        onScriptEvent: (id, type, controls, {submitter}) => pending.future,
      ),
    );
    await t.pumpAndSettle();
    await t.tap(_button('Send'));
    await t.pump();
    await t.pumpWidget(
      _page(
        source,
        scriptDocument: Object(),
        onFormSubmit: submissions.add,
        onScriptEvent: (id, type, controls, {submitter}) async => false,
      ),
    );
    pending.complete(false);
    await t.pumpAndSettle();
    expect(submissions, isEmpty);
    expect(t.takeException(), isNull);
  });

  testWidgets(
    'script button receives current controls and can prevent submit',
    (tester) async {
      const source = '''
<form action="/send" method="get">
  <input name="message" value="before" data-pirc-script-id="message">
  <input type="checkbox" name="enabled" data-pirc-script-id="enabled">
  <select name="choice" data-pirc-script-id="choice">
    <option value="first">First</option>
    <option value="second">Second</option>
  </select>
  <button type="submit" data-pirc-script-id="submit">Run</button>
</form>
''';
      String? clickedId;
      List<Map<String, dynamic>>? clickedControls;
      final submissions = <NativeHtmlFormSubmission>[];

      await tester.pumpWidget(
        _page(
          source,
          onFormSubmit: submissions.add,
          onScriptClick: (id, controls) async {
            clickedId = id;
            clickedControls = controls;
            return true;
          },
        ),
      );
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(EditableText), 'edited');
      await tester.tap(find.byType(NativeHtmlControlWidget));
      final select = tester.widget<NativeHtmlSelectWidget>(
        find.byType(NativeHtmlSelectWidget),
      );
      select.state.select(select.control.key, 1);
      await tester.pump();

      await tester.tap(_button('Run'));
      await tester.pumpAndSettle();

      expect(clickedId, 'submit');
      expect(clickedControls, [
        {'id': 'message', 'value': 'edited'},
        {'id': 'enabled', 'checked': true},
        {
          'id': 'choice',
          'selectedValues': ['second'],
        },
      ]);
      expect(submissions, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('script callback false allows submit after same-source rebuild', (
    tester,
  ) async {
    const source = '''
<form action="/send" method="get">
  <input name="q" value="kept">
  <button type="submit" data-pirc-script-id="submit">Send</button>
</form>
''';
    final result = Completer<bool>();
    Future<bool> waitForResult(
      String id,
      List<Map<String, dynamic>> controls,
    ) => result.future;
    final submissions = <NativeHtmlFormSubmission>[];
    final submit = submissions.add;

    await tester.pumpWidget(
      _page(
        source,
        onFormSubmit: submit,
        onScriptClick: (id, controls) => waitForResult(id, controls),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(_button('Send'));
    await tester.pump();

    // A runtime notification can rebuild the document with a fresh node list
    // while keeping the same source and mounted native control state.
    await tester.pumpWidget(
      _page(
        source,
        onFormSubmit: submit,
        onScriptClick: (id, controls) => waitForResult(id, controls),
      ),
    );
    result.complete(false);
    await tester.pumpAndSettle();

    expect(submissions, hasLength(1));
    expect(submissions.single.action, '/send');
    expect(submissions.single.entries.map((entry) => entry.value), ['kept']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('source replacement suppresses an old pending default action', (
    tester,
  ) async {
    const oldSource = '''
<form action="/old"><button type="submit" data-pirc-script-id="submit">Old</button></form>
''';
    const newSource =
        '<form action="/new"><button type="submit">New</button></form>';
    final result = Completer<bool>();
    Future<bool> onClick(String id, List<Map<String, dynamic>> controls) =>
        result.future;
    final submissions = <NativeHtmlFormSubmission>[];

    await tester.pumpWidget(
      _page(oldSource, onFormSubmit: submissions.add, onScriptClick: onClick),
    );
    await tester.pumpAndSettle();
    await tester.tap(_button('Old'));
    await tester.pump();

    await tester.pumpWidget(
      _page(newSource, onFormSubmit: submissions.add, onScriptClick: onClick),
    );
    await tester.pumpAndSettle();
    result.complete(false);
    await tester.pumpAndSettle();

    expect(submissions, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('unhooked marked submit button keeps its native default', (
    tester,
  ) async {
    const source = '''
<form action="/send" method="get">
  <input name="q" value="before">
  <button type="submit" data-pirc-script-id="submit">Send</button>
</form>
''';
    final submissions = <NativeHtmlFormSubmission>[];

    await tester.pumpWidget(_page(source, onFormSubmit: submissions.add));
    await tester.pumpAndSettle();
    await tester.tap(_button('Send'));
    await tester.pumpAndSettle();

    expect(submissions, hasLength(1));
    expect(submissions.single.action, '/send');
    expect(submissions.single.entries.map((entry) => entry.value), ['before']);
    expect(tester.takeException(), isNull);
  });
}
