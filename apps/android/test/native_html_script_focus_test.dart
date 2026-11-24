import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart' as md;
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_mobile/live/document_navigation_state.dart';
import 'package:pirc_mobile/live/gateway.dart';
import 'package:pirc_render/src/html_buttons.dart';
import 'package:flutter/services.dart';
import 'package:pirc_render/src/html_text_fields.dart';
import 'package:pirc_render/src/html_document_content.dart';
import 'package:pirc_render/src/native_html.dart';
import 'package:pirc_render/src/html_syntax.dart';

import 'live_test.dart' show theme;

typedef _DetailedEvent =
    Future<bool> Function(
      String,
      String,
      List<Map<String, dynamic>>,
      Map<String, dynamic>,
    );

typedef _ScriptEvent =
    Future<bool> Function(
      String,
      String,
      List<Map<String, dynamic>>, {
      String? submitter,
    });

typedef _DocumentHost = ({
  NativeDocumentWindows windows,
  NativeDocumentWindow window,
  NativeFetchedDocument document,
});

_DocumentHost _activeDocument(String source) {
  final bytes = Uint8List.fromList(utf8.encode(source));
  final document = NativeFetchedDocument(
    id: 1,
    url: 'https://focus.example/',
    status: 200,
    bytes: bytes,
    mimeType: 'text/html',
    content: NativeHtmlDocumentContent.fromBytes(
      bytes,
      mimeType: 'text/html',
      charset: 'utf-8',
    ),
    headers: const <String, dynamic>{},
  );
  final windows = NativeDocumentWindows(Gateway());
  final window = NativeDocumentWindow(
    windows,
    id: 1,
    name: 'focus-test',
    sourceUrl: document.url,
    canReturnToSource: false,
  );
  window
    ..history.add(NativeDocumentHistoryItem(document.url, document))
    ..index = 0;
  windows
    ..windows.add(window)
    ..activeId = window.id;
  return (windows: windows, window: window, document: document);
}

Widget _page(
  _DocumentHost host,
  String source, {
  List<Map<String, dynamic>> focusActions = const [],
  List<Map<String, dynamic>> Function(List<int>)? takeFocusActions,
  _DetailedEvent? onDetailedEvent,
  _ScriptEvent? onScriptEvent,
  ScrollController? scrollController,
  bool withHistory = false,
}) => MaterialApp(
  theme: theme.build(Brightness.light),
  home: NativeDocumentScope(
    windows: host.windows,
    window: host.window,
    documentUrl: host.document.url,
    child: Scaffold(
      body: SingleChildScrollView(
        controller: scrollController,
        child: NativeHtmlDocument(
          nodes: [NativeHtmlRaw(source)],
          style: const TextStyle(fontSize: 16),
          styles: md.MarkdownStyleSheet(),
          builders: const {},
          markdownStyles: false,
          scriptDocument: host.document,
          historyController: withHistory ? host.document.historyControls : null,
          scriptFocusActions: focusActions,
          takeScriptFocusActions: takeFocusActions,
          onScriptDetailedEvent: onDetailedEvent,
          onScriptEvent: onScriptEvent,
        ),
      ),
    ),
  ),
);

List<Map<String, dynamic>> _takeRenderedActions(
  List<int> sequences,
  List<Map<String, dynamic>> actions,
) => [
  for (final action in actions)
    if (sequences.contains(action['sequence'])) action,
];

void main() {
  testWidgets(
    'script focus targets the native editor and suppresses focus echoes',
    (tester) async {
      const source =
          '<input data-pirc-script-id="pirc-1"><input data-pirc-script-id="pirc-2">';
      final host = _activeDocument(source);
      final events = <String>[];
      final details = <Map<String, dynamic>>[];
      Future<bool> detailed(
        String id,
        String type,
        List<Map<String, dynamic>> controls,
        Map<String, dynamic> data,
      ) async {
        events.add('$id:$type');
        details.add({'id': id, 'type': type, ...data});
        return false;
      }

      await tester.pumpWidget(_page(host, source, onDetailedEvent: detailed));
      await tester.pumpAndSettle();
      final editors = tester.widgetList<EditableText>(
        find.byType(EditableText),
      );
      expect(editors, hasLength(2));

      await tester.tap(find.byType(EditableText).first);
      await tester.pump();
      await tester.enterText(find.byType(EditableText).first, 'pending');
      await tester.pump();
      events.clear();
      details.clear();

      final action = <String, dynamic>{
        'kind': 'focus',
        'controlId': 'pirc-2',
        'preventScroll': true,
        'actionOrder': 1,
        'sequence': 1,
      };
      await tester.pumpWidget(
        _page(
          host,
          source,
          focusActions: [action],
          takeFocusActions: (sequences) =>
              _takeRenderedActions(sequences, [action]),
          onDetailedEvent: detailed,
        ),
      );
      await tester.pump();

      final focusedEditors = tester.widgetList<EditableText>(
        find.byType(EditableText),
      );
      expect(focusedEditors.last.focusNode.hasPrimaryFocus, isTrue);
      expect(events, isEmpty);
      expect(details, isEmpty);

      await tester.enterText(find.byType(EditableText).last, 'real input');
      await tester.pump();
      expect(events, contains('pirc-2:input'));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      host.windows.dispose();
    },
  );

  testWidgets('a reentrant final blur clears an earlier native focus', (
    tester,
  ) async {
    const source =
        '<input data-pirc-script-id="pirc-1"><input data-pirc-script-id="pirc-2">';
    final host = _activeDocument(source);
    await tester.pumpWidget(_page(host, source));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(EditableText).first);
    await tester.pump();
    expect(
      tester
          .widgetList<EditableText>(find.byType(EditableText))
          .first
          .focusNode
          .hasPrimaryFocus,
      isTrue,
    );

    final focus = <String, dynamic>{
      'kind': 'focus',
      'controlId': 'pirc-2',
      'preventScroll': true,
      'actionOrder': 1,
      'sequence': 1,
    };
    final blur = <String, dynamic>{
      'kind': 'blur',
      'controlId': 'pirc-2',
      'preventScroll': true,
      'actionOrder': 2,
      'sequence': 2,
    };
    await tester.pumpWidget(
      _page(
        host,
        source,
        focusActions: [focus, blur],
        takeFocusActions: (sequences) =>
            _takeRenderedActions(sequences, [focus, blur]),
      ),
    );
    await tester.pump();
    expect(
      tester
          .widgetList<EditableText>(find.byType(EditableText))
          .every((editor) => !editor.focusNode.hasFocus),
      isTrue,
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    host.windows.dispose();
  });

  testWidgets('native tap dispatches focus before the script click', (
    tester,
  ) async {
    const source =
        '<input data-pirc-script-id="pirc-1"><button type="button" data-pirc-script-id="pirc-2">Run</button>';
    final host = _activeDocument(source);
    final events = <String>[];
    final details = <Map<String, dynamic>>[];

    await tester.pumpWidget(
      _page(
        host,
        source,
        onDetailedEvent: (id, type, controls, data) async {
          events.add('$id:$type');
          details.add({'id': id, 'type': type, ...data});
          return false;
        },
        onScriptEvent: (id, type, controls, {submitter}) async {
          events.add('$id:$type');
          return false;
        },
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byType(EditableText));
    await tester.pump();
    await tester.enterText(find.byType(EditableText), 'changed');
    await tester.pump();
    events.clear();
    details.clear();

    final button = find.byWidgetPredicate(
      (widget) =>
          widget is NativeHtmlButtonWidget && widget.button.label == 'Run',
    );
    await tester.tap(button);
    await tester.pumpAndSettle();

    expect(events.first, 'pirc-1:change');
    expect(
      details.firstWhere((event) => event['type'] == 'change')['focusLeaving'],
      isTrue,
    );
    expect(
      events.indexOf('pirc-1:blur'),
      lessThan(events.indexOf('pirc-2:focus')),
    );
    expect(
      events.indexOf('pirc-2:focusin'),
      lessThan(events.indexOf('pirc-2:click')),
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    host.windows.dispose();
  });

  testWidgets('script focus supports negative tabindex without tab traversal', (
    tester,
  ) async {
    const source =
        '<div tabindex="-1" data-pirc-script-id="pirc-3">Programmatic target</div>';
    final host = _activeDocument(source);
    final action = <String, dynamic>{
      'kind': 'focus',
      'controlId': 'pirc-3',
      'preventScroll': true,
      'actionOrder': 1,
      'sequence': 1,
    };
    await tester.pumpWidget(
      _page(
        host,
        source,
        focusActions: [action],
        takeFocusActions: (sequences) =>
            _takeRenderedActions(sequences, [action]),
      ),
    );
    await tester.pump();

    final focus = tester
        .widgetList<Focus>(find.byType(Focus))
        .singleWhere(
          (widget) =>
              widget.focusNode?.debugLabel == 'HTML script focus pirc-3',
        );
    expect(focus.focusNode!.hasPrimaryFocus, isTrue);
    expect(focus.focusNode!.skipTraversal, isTrue);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    host.windows.dispose();
  });

  testWidgets('retired window cannot consume its painted focus action', (
    tester,
  ) async {
    const source = '<input data-pirc-script-id="pirc-4">';
    final host = _activeDocument(source);
    final replacementBytes = Uint8List.fromList(utf8.encode('<p>next</p>'));
    final replacement = NativeFetchedDocument(
      id: 2,
      url: 'https://focus.example/next',
      status: 200,
      bytes: replacementBytes,
      mimeType: 'text/html',
      content: NativeHtmlDocumentContent.fromBytes(
        replacementBytes,
        mimeType: 'text/html',
        charset: 'utf-8',
      ),
      headers: const <String, dynamic>{},
    );
    host.window.history.add(
      NativeDocumentHistoryItem(replacement.url, replacement),
    );
    var taken = false;
    final action = <String, dynamic>{
      'kind': 'focus',
      'controlId': 'pirc-4',
      'preventScroll': true,
      'actionOrder': 1,
      'sequence': 1,
    };
    tester.binding.addPostFrameCallback((_) {
      host.window.index = 1;
    });

    await tester.pumpWidget(
      _page(
        host,
        source,
        focusActions: [action],
        takeFocusActions: (sequences) {
          taken = true;
          return _takeRenderedActions(sequences, [action]);
        },
      ),
    );
    await tester.pump();

    expect(taken, isFalse);
    expect(
      tester.widget<EditableText>(find.byType(EditableText)).focusNode.hasFocus,
      isFalse,
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    host.windows.dispose();
  });

  testWidgets(
    'inline anchor focus node is mounted and programmatically focusable',
    (tester) async {
      const source =
          '<a href="/next" data-pirc-script-id="pirc-5">Inline link</a>';
      final host = _activeDocument(source);
      final action = <String, dynamic>{
        'kind': 'focus',
        'controlId': 'pirc-5',
        'preventScroll': true,
        'actionOrder': 1,
        'sequence': 1,
      };
      await tester.pumpWidget(
        _page(
          host,
          source,
          focusActions: [action],
          takeFocusActions: (sequences) =>
              _takeRenderedActions(sequences, [action]),
        ),
      );
      await tester.pump();

      expect(
        find.byWidgetPredicate(
          (widget) =>
              widget is RichText &&
              widget.text.toPlainText().contains('Inline link'),
        ),
        findsOneWidget,
      );
      final focus = tester
          .widgetList<Focus>(find.byType(Focus))
          .singleWhere(
            (widget) =>
                widget.focusNode?.debugLabel == 'HTML script focus pirc-5',
          );
      expect(focus.focusNode!.context, isNotNull);
      expect(focus.focusNode!.hasPrimaryFocus, isTrue);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      host.windows.dispose();
    },
  );

  testWidgets(
    'preventScroll preserves page offset while false reveals the target',
    (tester) async {
      final source =
          '${List.generate(80, (index) => '<p>Before $index</p>').join()}<input data-pirc-script-id="pirc-6">';
      final host = _activeDocument(source);
      final scroll = ScrollController();
      final preventScroll = <String, dynamic>{
        'kind': 'focus',
        'controlId': 'pirc-6',
        'preventScroll': true,
        'actionOrder': 1,
        'sequence': 1,
      };
      await tester.pumpWidget(
        _page(
          host,
          source,
          scrollController: scroll,
          focusActions: [preventScroll],
          takeFocusActions: (sequences) =>
              _takeRenderedActions(sequences, [preventScroll]),
        ),
      );
      await tester.pumpAndSettle();
      expect(scroll.hasClients, isTrue);
      expect(scroll.offset, 0);

      final revealTarget = <String, dynamic>{
        'kind': 'focus',
        'controlId': 'pirc-6',
        'preventScroll': false,
        'actionOrder': 2,
        'sequence': 2,
      };
      await tester.pumpWidget(
        _page(
          host,
          source,
          scrollController: scroll,
          focusActions: [preventScroll, revealTarget],
          takeFocusActions: (sequences) =>
              _takeRenderedActions(sequences, [preventScroll, revealTarget]),
        ),
      );
      await tester.pumpAndSettle();
      expect(scroll.offset, greaterThan(0));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      scroll.dispose();
      host.windows.dispose();
    },
  );
  testWidgets('focused button survives an unrelated same-document DOM update', (
    tester,
  ) async {
    const source =
        '<button type="button" data-pirc-script-id="pirc-7">Stable button</button><p>before</p>';
    final host = _activeDocument(source);
    final events = <String>[];
    Future<bool> detailed(
      String id,
      String type,
      List<Map<String, dynamic>> controls,
      Map<String, dynamic> data,
    ) async {
      events.add('$id:$type');
      return false;
    }

    final action = <String, dynamic>{
      'kind': 'focus',
      'controlId': 'pirc-7',
      'preventScroll': true,
      'actionOrder': 1,
      'sequence': 1,
    };
    await tester.pumpWidget(
      _page(
        host,
        source,
        focusActions: [action],
        takeFocusActions: (sequences) =>
            _takeRenderedActions(sequences, [action]),
        onDetailedEvent: detailed,
      ),
    );
    await tester.pumpAndSettle();
    final original = FocusManager.instance.primaryFocus;
    expect(original?.debugLabel, 'Stable button');
    events.clear();
    await tester.pumpWidget(
      _page(
        host,
        source.replaceFirst('before', 'after'),
        onDetailedEvent: detailed,
      ),
    );
    await tester.pumpAndSettle();
    expect(FocusManager.instance.primaryFocus, same(original));
    expect(original?.hasPrimaryFocus, isTrue);
    expect(events, isEmpty);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    host.windows.dispose();
  });
  testWidgets(
    'each common native control receives script focus without echoes',
    (tester) async {
      const types = [
        'text',
        'textarea',
        'select',
        'button',
        'checkbox',
        'radio',
        'range',
        'date',
        'file',
        'link',
        'tabindex',
      ];
      final source = <String>[];
      for (var index = 0; index < types.length; index++) {
        final type = types[index];
        final id = 'pirc-${100 + index}';
        final attrs = 'data-pirc-script-id="$id" aria-label="Focus $type"';
        source.add(switch (type) {
          'textarea' => '<textarea $attrs></textarea>',
          'select' => '<select $attrs><option>one</option></select>',
          'button' => '<button type="button" $attrs>Focus button</button>',
          'link' => '<a href="#dest" $attrs>Focus link</a>',
          'tabindex' => '<div tabindex="-1" $attrs>Focus tabindex</div>',
          _ => '<input type="$type" $attrs>',
        });
      }
      final markup = source.join('<br>');
      final host = _activeDocument(markup);
      final events = <String>[];
      Future<bool> detailed(
        String id,
        String type,
        List<Map<String, dynamic>> controls,
        Map<String, dynamic> data,
      ) async {
        events.add('$id:$type');
        return false;
      }

      for (var index = 0; index < types.length; index++) {
        final type = types[index];
        final id = 'pirc-${100 + index}';
        final action = <String, dynamic>{
          'kind': 'focus',
          'controlId': id,
          'preventScroll': true,
          'actionOrder': index + 1,
          'sequence': index + 1,
        };
        await tester.pumpWidget(
          _page(
            host,
            markup,
            focusActions: [action],
            takeFocusActions: (sequences) =>
                _takeRenderedActions(sequences, [action]),
            onDetailedEvent: detailed,
          ),
        );
        await tester.pumpAndSettle();
        final primary = FocusManager.instance.primaryFocus;
        expect(primary?.hasPrimaryFocus, isTrue, reason: type);
        final label = primary?.debugLabel;
        if (type == 'link' || type == 'tabindex') {
          expect(label, 'HTML script focus $id', reason: type);
        } else if (type == 'date') {
          expect(
            label?.startsWith('Focus date '),
            isTrue,
            reason: 'date segment: $label',
          );
        } else {
          expect(label, 'Focus $type', reason: type);
        }
        expect(
          events,
          isEmpty,
          reason: '$type must not duplicate JS focus events',
        );
        expect(tester.takeException(), isNull, reason: type);
      }
      await tester.pumpWidget(const SizedBox.shrink());
      host.windows.dispose();
    },
  );
  testWidgets(
    'text editor inside the first disabled fieldset legend lays out and focuses',
    (tester) async {
      for (final multiline in [false, true]) {
        final tag = multiline ? 'textarea' : 'input';
        final editor =
            '<$tag data-pirc-script-id="pirc-40" aria-label="Legend editor" style="width:180px;padding:4px">${multiline ? '</textarea>' : ''}';
        final source =
            '<fieldset disabled><legend>Caption $editor</legend><input aria-label="disabled body"></fieldset>';
        final host = _activeDocument(source);
        final action = <String, dynamic>{
          'kind': 'focus',
          'controlId': 'pirc-40',
          'preventScroll': true,
          'actionOrder': 1,
          'sequence': 1,
        };
        await tester.pumpWidget(
          _page(
            host,
            source,
            focusActions: [action],
            takeFocusActions: (sequences) =>
                _takeRenderedActions(sequences, [action]),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(FocusManager.instance.primaryFocus?.debugLabel, 'Legend editor');
        expect(FocusManager.instance.primaryFocus?.hasPrimaryFocus, isTrue);
        await tester.pumpWidget(const SizedBox.shrink());
        host.windows.dispose();
      }
    },
  );

  testWidgets(
    'restoring unchanged history bookkeeping preserves pending Enter',
    (tester) async {
      const source = '<input data-pirc-script-id="pirc-1" value="original">';
      final host = _activeDocument(source);
      await tester.pumpWidget(_page(host, source, withHistory: true));
      await tester.pumpAndSettle();
      final field = tester.widget<NativeHtmlTextFieldWidget>(
        find.byType(NativeHtmlTextFieldWidget),
      );
      final state = field.state;
      final focus = state.focusNodeFor(field.field.key);
      focus.requestFocus();
      await tester.pump();
      await tester.enterText(find.byType(TextField), 'edited');
      final saved = host.document.historyControls.capture()!;
      var submitted = 0;
      state.onSubmit = (_) => submitted++;
      var response = Completer<bool>();
      state.onUserKeyEvent = (_, type, data) =>
          type == 'keydown' ? response.future : Future.value(false);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      host.document.historyControls.restore(saved);
      response.complete(false);
      await tester.pump();
      expect(
        submitted,
        1,
        reason: 'unchanged carried history is not a new edit',
      );

      response = Completer<bool>();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.enterText(find.byType(TextField), 'new edit');
      host.document.historyControls.restore(saved);
      response.complete(false);
      await tester.pump();
      expect(
        submitted,
        1,
        reason: 'a newer real edit still invalidates pending Enter',
      );
      await tester.pumpWidget(const SizedBox());
      host.windows.dispose();
    },
  );
}
