import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart' as fm;
import 'package:pirc_render/src/native_html.dart';
import 'package:pirc_render/src/html_syntax.dart';
import 'package:pirc_render/src/html_text_fields.dart';
import 'package:pirc_mobile/live/document_navigation.dart';
import 'package:pirc_mobile/live/document_navigation_state.dart';
import 'package:pirc_render/src/html_form_submission.dart';
import 'document_navigation_widget_test.dart' show DocumentGateway, response;
import 'live_test.dart' show theme;
import 'native_html_test.dart' show tapText;

void main() {
  for (final head in [
    '<meta id="destination">',
    '<style id="destination">/* hidden target */</style>',
  ]) {
    testWidgets('full DOM fragment priority includes unrendered $head', (
      tester,
    ) async {
      final gateway = DocumentGateway()
            ..responses.add(
              response(
                '/full-dom',
                '<html><head>$head</head><body style="margin:0;height:3000px"><div style="height:1000px"></div><div id="destination" style="height:40px"></div><a href="#destination" style="position:fixed;top:20px;left:16px;display:block;width:100px;height:32px">Jump</a></body></html>',
              ),
            ),
          windows = NativeDocumentWindows(gateway),
          window = windows.target(
            'report',
            null,
            sourceUrl: 'https://gateway.example/',
          );
      addTearDown(windows.dispose);
      await window.load(
        const NativeHtmlFormRequest(
          url: '/full-dom',
          method: 'GET',
          target: '',
        ),
        baseUrl: window.sourceUrl,
      );
      windows.select(window);
      await tester.pumpWidget(
        MaterialApp(
          theme: theme.build(Brightness.light),
          home: NativeDocumentWorkspace(windows: windows),
        ),
      );
      await tester.pumpAndSettle();
      final document = window.currentDocument!;
      document.scroll.jumpTo(240);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Jump', findRichText: true));
      await tester.pumpAndSettle();
      expect(
        document.scroll.offset,
        240,
        reason: 'unrendered first ID wins over the rendered duplicate',
      );
      expect(document.viewport.lastFragmentDifference, isNull);
      expect(window.current!.url, endsWith('#destination'));
      expect(gateway.calls, hasLength(1));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    });
  }

  testWidgets(
    'a replaced viewport binds the same source without retaining a stale index',
    (tester) async {
      final first = NativeHtmlViewportController(),
          second = NativeHtmlViewportController(),
          scroll = ScrollController(),
          owner = Object();
      addTearDown(scroll.dispose);
      final nodes = [
        NativeHtmlRaw(
          '<div style="height:1200px"></div><div id="destination" style="height:40px"></div><div style="height:1000px"></div>',
        ),
      ];
      Widget page(NativeHtmlViewportController controller) => MaterialApp(
        theme: theme.build(Brightness.light),
        home: Scaffold(
          body: SingleChildScrollView(
            controller: scroll,
            child: NativeHtmlDocument(
              nodes: nodes,
              style: const TextStyle(fontSize: 16),
              styles: fm.MarkdownStyleSheet(),
              builders: const {},
              markdownStyles: false,
              viewport: controller,
              scriptDocument: owner,
            ),
          ),
        ),
      );
      await tester.pumpWidget(page(first));
      await tester.pumpAndSettle();
      expect(first.fragmentTarget('destination'), isNotNull);
      await tester.pumpWidget(page(second));
      await tester.pumpAndSettle();
      expect(first.fragmentTarget('destination'), isNull);
      expect(second.fragmentTarget('destination'), isNotNull);
      final reveal = second.scrollToAnchor('destination');
      await tester.pumpAndSettle();
      expect(await reveal, isTrue);
      expect(scroll.offset, 1200);
      await tester.pumpWidget(const SizedBox());
      expect(second.fragmentTarget('destination'), isNull);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'private anchor aliases preserve ID selectors, label association and form values',
    (tester) async {
      final gateway = DocumentGateway()
            ..responses.add(
              response(
                '/fragment',
                '<!doctype html><style>html,body{margin:0}#field{width:140px;height:28px;border:0;padding:0;box-sizing:border-box}</style><label id="caption" for="field">Focus field</label><input id="field" name="q" value="original">',
              ),
            ),
          windows = NativeDocumentWindows(gateway),
          window = windows.target(
            'report',
            null,
            sourceUrl: 'https://gateway.example/',
          );
      addTearDown(windows.dispose);
      await window.load(
        const NativeHtmlFormRequest(
          url: '/fragment',
          method: 'GET',
          target: '',
        ),
        baseUrl: window.sourceUrl,
      );
      windows.select(window);
      await tester.pumpWidget(
        MaterialApp(
          theme: theme.build(Brightness.light),
          home: NativeDocumentWorkspace(windows: windows),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        tester.getSize(find.byType(NativeHtmlTextFieldWidget)),
        const Size(140, 28),
      );
      await tapText(tester, 'Focus field');
      await tester.pumpAndSettle();
      final editor = tester.widget<EditableText>(find.byType(EditableText));
      expect(editor.focusNode.hasFocus, isTrue);
      expect(editor.controller.text, 'original');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    },
  );
  testWidgets('plain text documents keep their top fragment behavior', (
    tester,
  ) async {
    final gateway = DocumentGateway()
          ..responses.add(
            response(
              '/text',
              List.filled(160, 'line').join('\n'),
              mime: 'text/plain',
            ),
          ),
        windows = NativeDocumentWindows(gateway),
        window = windows.target(
          'report',
          null,
          sourceUrl: 'https://gateway.example/',
        );
    addTearDown(windows.dispose);
    await window.load(
      const NativeHtmlFormRequest(url: '/text', method: 'GET', target: ''),
      baseUrl: window.sourceUrl,
    );
    windows.select(window);
    await tester.pumpWidget(
      MaterialApp(
        theme: theme.build(Brightness.light),
        home: NativeDocumentWorkspace(windows: windows),
      ),
    );
    await tester.pumpAndSettle();
    final document = window.currentDocument!;
    document.scroll.jumpTo(480);
    await tester.pumpAndSettle();
    await window.load(
      const NativeHtmlFormRequest(url: '#%74op', method: 'GET', target: ''),
      baseUrl: window.current!.url,
      fragmentAllowed: true,
    );
    await tester.pumpAndSettle();
    expect(document.scroll.offset, 0);
    expect(gateway.calls, hasLength(1));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  });
}
