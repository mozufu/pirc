import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart' as md;
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_render/src/html_buttons.dart';
import 'package:pirc_render/src/html_syntax.dart';
import 'package:pirc_render/src/native_html.dart';

import 'live_test.dart' show theme;

typedef _ScriptEvent =
    Future<bool> Function(
      String,
      String,
      List<Map<String, dynamic>>, {
      String? submitter,
    });

Widget _document(
  String source, {
  _ScriptEvent? onScriptEvent,
  Object? scriptDocument,
  Object? scriptSnapshot,
  ValueChanged<NativeHtmlLink>? onNavigate,
  ScrollController? scrollController,
}) => SingleChildScrollView(
  controller: scrollController,
  child: NativeHtmlDocument(
    nodes: [NativeHtmlRaw(source)],
    style: const TextStyle(fontSize: 16),
    styles: md.MarkdownStyleSheet(),
    builders: const {},
    markdownStyles: false,
    scriptDocument: scriptDocument,
    scriptSnapshot: scriptSnapshot,
    onScriptEvent: onScriptEvent,
    onNavigate: onNavigate,
  ),
);

Widget _page(
  String source, {
  _ScriptEvent? onScriptEvent,
  Object? scriptDocument,
  Object? scriptSnapshot,
  ValueChanged<NativeHtmlLink>? onNavigate,
}) => MaterialApp(
  theme: theme.build(Brightness.light),
  home: Scaffold(
    body: _document(
      source,
      onScriptEvent: onScriptEvent,
      scriptDocument: scriptDocument,
      scriptSnapshot: scriptSnapshot,
      onNavigate: onNavigate,
    ),
  ),
);

Finder _button(String label) => find.byWidgetPredicate(
  (widget) => widget is NativeHtmlButtonWidget && widget.button.label == label,
);

void main() {
  testWidgets('a marked label child still activates its checkbox once', (
    tester,
  ) async {
    const source =
        '<label for="check" data-pirc-script-id="label" data-pirc-script-click="true"><span data-pirc-script-id="child" data-pirc-script-click="true">Toggle choice</span></label><input id="check" type="checkbox" data-pirc-script-id="check">';
    final events = <String>[];
    await tester.pumpWidget(
      _page(
        source,
        scriptDocument: Object(),
        onScriptEvent: (id, type, controls, {submitter}) async {
          events.add('$id:$type');
          if (type == 'change') {
            expect(controls, contains({'id': 'check', 'checked': true}));
          }
          return false;
        },
      ),
    );
    await tester.pumpAndSettle();
    final text = find
        .byWidgetPredicate(
          (w) =>
              w is RichText && w.text.toPlainText().contains('Toggle choice'),
        )
        .first;
    final paragraph = tester.renderObject<RenderParagraph>(text);
    final start = paragraph.text.toPlainText().indexOf('Toggle choice');
    final boxes = paragraph.getBoxesForSelection(
      TextSelection(baseOffset: start, extentOffset: start + 1),
    );
    await tester.tapAt(paragraph.localToGlobal(boxes.first.toRect().center));
    await tester.pumpAndSettle();
    expect(events, ['child:click', 'check:input', 'check:change']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('nested marked elements dispatch once to the tapped target', (
    tester,
  ) async {
    const source = '''
<div data-pirc-script-id="outer" data-pirc-script-click="true">
  <p data-pirc-script-id="paragraph" data-pirc-script-click="true">
    <span data-pirc-script-id="target" data-pirc-script-click>Nested target</span>
  </p>
</div>
''';
    final events = <String>[];

    await tester.pumpWidget(
      _page(
        source,
        scriptDocument: Object(),
        onScriptEvent: (id, type, controls, {submitter}) async {
          events.add('$id:$type');
          return false;
        },
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Nested target', findRichText: true));
    await tester.pumpAndSettle();

    expect(events, ['target:click']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('anchor click dispatches before navigation and can be canceled', (
    tester,
  ) async {
    const source =
        '<a href="/destination" data-pirc-script-id="link"><span>Cancel link</span></a>';
    final events = <String>[];
    final navigations = <NativeHtmlLink>[];

    await tester.pumpWidget(
      _page(
        source,
        scriptDocument: Object(),
        onScriptEvent: (id, type, controls, {submitter}) async {
          events.add('$id:$type');
          return true;
        },
        onNavigate: navigations.add,
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Cancel link', findRichText: true));
    await tester.pumpAndSettle();

    expect(events, ['link:click']);
    expect(navigations, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('anchor default action uses attributes from the updated snapshot', (
    tester,
  ) async {
    var source =
        '<a href="/old" target="_self" data-pirc-script-id="link">Update route</a>';
    var snapshot = Object();
    final document = Object();
    final events = <String>[];
    final navigations = <NativeHtmlLink>[];

    await tester.pumpWidget(
      MaterialApp(
        theme: theme.build(Brightness.light),
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) => _document(
              source,
              scriptDocument: document,
              scriptSnapshot: snapshot,
              onNavigate: navigations.add,
              onScriptEvent: (id, type, controls, {submitter}) async {
                events.add('$id:$type');
                setState(() {
                  source =
                      '<a href="/updated" target="_blank" download="report.txt" data-pirc-script-id="link">Update route</a>';
                  snapshot = Object();
                });
                return false;
              },
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Update route', findRichText: true));
    await tester.pumpAndSettle();

    expect(events, ['link:click']);
    expect(navigations, hasLength(1));
    expect(navigations.single.href, '/updated');
    expect(navigations.single.target, '_blank');
    expect(navigations.single.download, 'report.txt');
    expect(navigations.single.targetSpecified, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('ordinary anchor dispatches once and navigates once', (
    tester,
  ) async {
    const source =
        '<a href="/ordinary" data-pirc-script-id="ordinary">Ordinary route</a>';
    final events = <String>[];
    final navigations = <NativeHtmlLink>[];

    await tester.pumpWidget(
      _page(
        source,
        scriptDocument: Object(),
        onScriptEvent: (id, type, controls, {submitter}) async {
          events.add('$id:$type');
          return false;
        },
        onNavigate: navigations.add,
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Ordinary route', findRichText: true));
    await tester.pumpAndSettle();

    expect(events, ['ordinary:click']);
    expect(navigations, hasLength(1));
    expect(navigations.single.href, '/ordinary');
    expect(tester.takeException(), isNull);
  });

  testWidgets('unmarked reading text does not dispatch click events', (
    tester,
  ) async {
    const source = '<p data-pirc-script-id="read-only">Text for reading</p>';
    final events = <String>[];

    await tester.pumpWidget(
      _page(
        source,
        scriptDocument: Object(),
        onScriptEvent: (id, type, controls, {submitter}) async {
          events.add('$id:$type');
          return false;
        },
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Text for reading', findRichText: true));
    await tester.pumpAndSettle();

    expect(events, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'pending link click does not navigate after document replacement',
    (tester) async {
      const source =
          '<a href="/stale" data-pirc-script-id="link">Pending route</a>';
      final pending = Completer<bool>();
      final events = <String>[];
      final navigations = <NativeHtmlLink>[];
      var document = Object();
      late VoidCallback replaceDocument;

      await tester.pumpWidget(
        MaterialApp(
          theme: theme.build(Brightness.light),
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, setState) {
                replaceDocument = () => setState(() => document = Object());
                return _document(
                  source,
                  scriptDocument: document,
                  onNavigate: navigations.add,
                  onScriptEvent: (id, type, controls, {submitter}) {
                    events.add('$id:$type');
                    return pending.future;
                  },
                );
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Pending route', findRichText: true));
      await tester.pump();
      expect(events, ['link:click']);

      replaceDocument();
      await tester.pump();
      pending.complete(false);
      await tester.pumpAndSettle();

      expect(navigations, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('native button click is not also handled by generic marker', (
    tester,
  ) async {
    const source =
        '<button type="button" data-pirc-script-id="button" data-pirc-script-click="true">Run</button>';
    final events = <String>[];

    await tester.pumpWidget(
      _page(
        source,
        scriptDocument: Object(),
        onScriptEvent: (id, type, controls, {submitter}) async {
          events.add('$id:$type');
          return false;
        },
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(_button('Run'));
    await tester.pumpAndSettle();

    expect(events, ['button:click']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('vertical drag in marked scroll content scrolls without click', (
    tester,
  ) async {
    final source = StringBuffer(
      '<div data-pirc-script-id="scroll" data-pirc-script-click="true">'
      '<p>Drag from here</p>',
    );
    for (var i = 0; i < 24; i++) {
      source.write('<p>Scroll row $i</p>');
    }
    source.write('</div>');
    final events = <String>[];
    final scrollController = ScrollController();

    await tester.pumpWidget(
      MaterialApp(
        theme: theme.build(Brightness.light),
        home: Scaffold(
          body: SizedBox(
            height: 140,
            child: _document(
              source.toString(),
              scriptDocument: Object(),
              scrollController: scrollController,
              onScriptEvent: (id, type, controls, {submitter}) async {
                events.add('$id:$type');
                return false;
              },
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.drag(
      find.text('Drag from here', findRichText: true),
      const Offset(0, -220),
    );
    await tester.pumpAndSettle();

    expect(scrollController.offset, greaterThan(0));
    expect(events, isEmpty);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    scrollController.dispose();
  });
}
