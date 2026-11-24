import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart' as md;
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_render/src/html_controls.dart';
import 'package:pirc_render/src/html_syntax.dart';
import 'package:pirc_render/src/native_html.dart';

import 'live_test.dart' show theme;

Widget _page(
  String source, {
  Future<bool> Function(String, List<Map<String, dynamic>>)?
  onScriptControlClick,
  Future<bool> Function(
    String,
    String,
    List<Map<String, dynamic>>, {
    String? submitter,
  })?
  onScriptEvent,
  Object? scriptDocument,
  Object? scriptSnapshot,
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
        onScriptControlClick: onScriptControlClick,
        onScriptEvent: onScriptEvent,
        scriptDocument: scriptDocument,
        scriptSnapshot: scriptSnapshot,
      ),
    ),
  ),
);

Finder _control(String scriptId) => find.byWidgetPredicate(
  (widget) =>
      widget is NativeHtmlControlWidget && widget.control.scriptId == scriptId,
  description: 'NativeHtmlControlWidget with script id "$scriptId"',
);

bool _isChecked(WidgetTester tester, String scriptId) {
  final widget = tester.widget<NativeHtmlControlWidget>(_control(scriptId));
  return widget.state.isChecked(widget.control.key);
}

List<Map<String, dynamic>> _copyControls(List<Map<String, dynamic>> controls) =>
    [for (final control in controls) Map<String, dynamic>.of(control)];

void main() {
  testWidgets(
    'ready checkable click hook owns activation and sends no checked snapshot',
    (tester) async {
      const source = '''
<input id="check" type="checkbox" name="enabled" data-pirc-script-id="check">
<input id="query" type="text" value="before" data-pirc-script-id="query">
''';
      final clickIds = <String>[];
      final clickPayloads = <List<Map<String, dynamic>>>[];
      final eventCalls = <String>[];
      final eventPayloads = <List<Map<String, dynamic>>>[];

      await tester.pumpWidget(
        _page(
          source,
          scriptDocument: Object(),
          onScriptControlClick: (id, controls) async {
            clickIds.add(id);
            clickPayloads.add(_copyControls(controls));
            return true;
          },
          onScriptEvent: (id, type, controls, {submitter}) async {
            eventCalls.add('$id:$type');
            eventPayloads.add(_copyControls(controls));
            return false;
          },
        ),
      );
      await tester.pumpAndSettle();
      expect(_control('check'), findsOneWidget);
      expect(_isChecked(tester, 'check'), false);

      await tester.tap(_control('check'));
      await tester.tap(_control('check'));
      await tester.pumpAndSettle();

      expect(clickIds, ['check', 'check']);
      expect(clickPayloads, [
        [
          {'id': 'query', 'value': 'before'},
        ],
        [
          {'id': 'query', 'value': 'before'},
        ],
      ]);
      expect(_isChecked(tester, 'check'), false);
      expect(eventCalls, isEmpty, reason: 'The click hook owns input/change.');

      await tester.enterText(find.byType(EditableText), 'edited');
      await tester.pumpAndSettle();
      expect(eventCalls, contains('query:input'));
      expect(
        eventPayloads,
        contains(
          equals([
            {'id': 'query', 'value': 'edited'},
          ]),
        ),
      );
      for (final payload in [...clickPayloads, ...eventPayloads]) {
        for (final control in payload) {
          expect(control.containsKey('checked'), false);
        }
      }
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('removing an unavailable script hook restores native events', (
    tester,
  ) async {
    const source =
        '<input id="check" type="checkbox" name="enabled" data-pirc-script-id="check">';
    final events = <String>[];
    final document = Object();
    await tester.pumpWidget(
      _page(
        source,
        scriptDocument: document,
        onScriptControlClick: (_, _) async => true,
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(_control('check'));
    expect(_isChecked(tester, 'check'), false);

    await tester.pumpWidget(
      _page(
        source,
        scriptDocument: document,
        onScriptEvent: (id, type, controls, {submitter}) async {
          events.add('$id:$type');
          return false;
        },
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(_control('check'));
    await tester.pumpAndSettle();

    expect(events, ['check:input', 'check:change']);
    expect(_isChecked(tester, 'check'), true);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a new script snapshot supplies checkable display state', (
    tester,
  ) async {
    const before =
        '<input id="check" type="checkbox" data-pirc-script-id="check">';
    const after =
        '<input id="check" type="checkbox" checked data-pirc-script-id="check">';
    final scriptDocument = Object();
    final callbackIds = <String>[];
    Future<bool> onClick(String id, List<Map<String, dynamic>> controls) async {
      callbackIds.add(id);
      return true;
    }

    await tester.pumpWidget(
      _page(
        before,
        scriptDocument: scriptDocument,
        scriptSnapshot: Object(),
        onScriptControlClick: onClick,
      ),
    );
    await tester.pumpAndSettle();
    expect(_isChecked(tester, 'check'), false);

    await tester.tap(_control('check'));
    await tester.pumpAndSettle();
    expect(callbackIds, ['check']);
    expect(_isChecked(tester, 'check'), false);

    await tester.pumpWidget(
      _page(
        after,
        scriptDocument: scriptDocument,
        scriptSnapshot: Object(),
        onScriptControlClick: onClick,
      ),
    );
    await tester.pumpAndSettle();
    expect(_isChecked(tester, 'check'), true);
    expect(tester.takeException(), isNull);
  });
}
