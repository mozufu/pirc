import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:pirc_render/src/code_block.dart';
import 'package:pirc_mobile/theme.dart';
import 'package:pirc_render/src/markdown_syntax.dart';
import 'package:pirc_render/src/native_markdown.dart';
import 'package:pirc_render/src/native_math_paragraph.dart';
import 'package:pirc_render/src/native_tex_adapter.dart';
import 'package:pirc_mobile/live/app.dart';
import 'package:pirc_mobile/live/gateway.dart';
import 'live_test.dart' show theme, FakeGateway;

List<md.Node> parse(String source) => md.Document(
  extensionSet: md.ExtensionSet.gitHubFlavored,
  encodeHtml: false,
  blockSyntaxes: const [NativeMathBlockSyntax(), NativeFenceSyntax()],
  inlineSyntaxes: [NativeMathInlineSyntax()],
).parseLines(source.split('\n'));
List<md.Element> elements(List<md.Node> nodes, String tag) => [
  for (final node in nodes)
    if (node is md.Element) ...[
      if (node.tag == tag) node,
      ...elements(node.children ?? [], tag),
    ],
];

void main() {
  testWidgets(
    'GFM table fills the viewport, preserves formatting, links and escaped pipes',
    (t) async {
      t.view.devicePixelRatio = 1;
      t.view.physicalSize = const Size(390, 844);
      addTearDown(t.view.reset);
      String? href;
      await t.pumpWidget(
        MaterialApp(
          theme: theme.build(Brightness.light),
          home: Scaffold(
            body: Padding(
              padding: const EdgeInsets.all(16),
              child: NativeMarkdown(
                source:
                    r"| **Feature** | State |"
                    '\n'
                    r"|:---|---:|"
                    '\n'
                    r"| a\|b | [Open][ref] |"
                    '\n\n[ref]: https://example.com',
                onLink: (link) => href = link,
              ),
            ),
          ),
        ),
      );
      await t.pumpAndSettle();
      final table = find.byKey(const ValueKey('native-markdown-table'));
      expect(t.getSize(table).width, 358);
      expect(find.text('a|b'), findsOneWidget);
      final link = t.renderObject<RenderParagraph>(
        find.byWidgetPredicate(
          (w) => w is RichText && w.text.toPlainText() == 'Open',
        ),
      );
      final glyph = link
          .getBoxesForSelection(
            const TextSelection(baseOffset: 0, extentOffset: 1),
          )
          .first
          .toRect();
      await t.tapAt(link.localToGlobal(glyph.center));
      await t.pump(const Duration(milliseconds: 350));
      expect(href, 'https://example.com');
      expect(t.takeException(), isNull);
    },
  );

  testWidgets('plain table prose wraps inside a narrow cell unchanged', (
    t,
  ) async {
    t.view.physicalSize = const Size(390, 844);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final token = List.filled(20, 'unbreakable').join();
    String? copiedText;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'Clipboard.setData') {
            copiedText = (call.arguments as Map)['text'] as String;
          }
          return null;
        });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null);
    });
    await t.pumpWidget(
      MaterialApp(
        theme: theme.build(Brightness.light),
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 240,
              child: NativeMarkdown(source: '| Value |\n| --- |\n| $token |'),
            ),
          ),
        ),
      ),
    );
    await t.pumpAndSettle();

    final viewport = find.byKey(const ValueKey('native-markdown-table'));
    expect(t.getSize(viewport).width, 240);
    final table = t.renderObject<RenderTable>(find.byType(Table));
    expect(table.size.width, closeTo(238, .1));
    expect(table.row(1).first.size.height, greaterThan(100));
    final prose = t.renderObject<RenderParagraph>(
      find.byWidgetPredicate(
        (widget) => widget is RichText && widget.text.toPlainText() == token,
      ),
    );
    expect(prose.text.toPlainText(), token);
    expect(prose.size.height, greaterThan(100));
    final selection = t.state<SelectableRegionState>(
      find.byType(SelectableRegion),
    );
    selection.selectAll(SelectionChangedCause.keyboard);
    await t.pump();
    selection.contextMenuButtonItems
        .firstWhere((item) => item.type == ContextMenuButtonType.copy)
        .onPressed!();
    await t.pump();
    expect(copiedText, 'Value\n$token');
    expect(t.takeException(), isNull);
  });

  testWidgets('atomic no-break math remains horizontally scrollable', (
    t,
  ) async {
    t.view.physicalSize = const Size(390, 844);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final token = List.filled(20, 'unbreakable').join();
    final expression = '\\text{$token}';
    await t.pumpWidget(
      MaterialApp(
        theme: theme.build(Brightness.light),
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 240,
              child: NativeMarkdown(
                source: '| Value |\n| --- |\n| \$$expression\$ |',
              ),
            ),
          ),
        ),
      ),
    );
    await t.pumpAndSettle();

    final viewport = find.byKey(const ValueKey('native-markdown-table'));
    final table = t.renderObject<RenderTable>(find.byType(Table));
    expect(t.getSize(viewport).width, 240);
    expect(table.size.width, greaterThan(238));
    final horizontalScroll = find.descendant(
      of: viewport,
      matching: find.byWidgetPredicate(
        (widget) =>
            widget is SingleChildScrollView &&
            widget.scrollDirection == Axis.horizontal,
      ),
    );
    expect(horizontalScroll, findsOneWidget);
    final scrollable = find.descendant(
      of: horizontalScroll,
      matching: find.byType(Scrollable),
    );
    expect(
      t.state<ScrollableState>(scrollable).position.maxScrollExtent,
      greaterThan(0),
    );
    expect(t.takeException(), isNull);
  });

  test('web math fixtures preserve prices, escaped delimiters and code', () {
    final tree = parse(
      r'Area $\pi r^2$ costs $5 and $10.'
      '\n'
      r'`\(x\)` `$x$` \$y\$',
    );
    expect(elements(tree, 'pirc-math').map((e) => e.textContent), [r'\pi r^2']);
    expect(
      tree.map((e) => e.textContent).join(),
      contains(r'costs $5 and $10.'),
    );
    expect(elements(tree, 'code').map((e) => e.textContent), [
      r'\(x\)',
      r'$x$',
    ]);
  });
  test('web inline/display/fenced delimiters, nesting and unfinished code', () {
    final tree = parse(
      'Equation \\(x^2\\) and \$\$y\$\$.\n\n\$\$\n\\int_0^1 x\\,dx\n\$\$\n\n\\[z\\]\n\n```latex\n\\frac{1}{2}\n```\n\n- ```ts\n  const x = 1;\n  ```\n\n```py\nprint(1)',
    );
    expect(elements(tree, 'pirc-math').map((e) => e.textContent), ['x^2', 'y']);
    expect(elements(tree, 'pirc-math-block').map((e) => e.textContent), [
      r'\int_0^1 x\,dx',
      'z',
      r'\frac{1}{2}',
    ]);
    final blocks = elements(tree, 'pirc-code');
    expect(blocks.map((e) => e.attributes['language']), ['ts', 'py']);
    expect(blocks.map((e) => e.textContent), ['const x = 1;', 'print(1)']);
    expect(elements(parse('\$\$\nunfinished'), 'pirc-math-block'), isEmpty);
  });
  for (final brightness in Brightness.values) {
    test(
      'highlighted content is preserved and uses web keyword palette ($brightness)',
      () {
        final colors = theme.build(brightness).extension<PircColors>()!;
        final span = highlightCode('const x = 1;', 'ts', colors);
        expect(span.toPlainText(), 'const x = 1;');
        final styles = <Color?>[];
        void visit(InlineSpan s) {
          styles.add(s.style?.color);
          if (s is TextSpan) {
            for (final child in s.children ?? <InlineSpan>[]) {
              visit(child);
            }
          }
        }

        visit(span);
        expect(styles, contains(colors['web.hl-keyword']));
        expect(
          highlightCode('<unknown>', 'not-a-language', colors).toPlainText(),
          '<unknown>',
        );
      },
    );
    testWidgets(
      'native formulas, code copy and horizontal overflow ($brightness)',
      (t) async {
        t.view.devicePixelRatio = 1;
        t.view.physicalSize = const Size(390, 844);
        addTearDown(t.view.reset);
        String? copied;
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(SystemChannels.platform, (call) async {
              if (call.method == 'Clipboard.setData') {
                copied = call.arguments['text'] as String;
              }
              return null;
            });
        addTearDown(
          () => TestDefaultBinaryMessengerBinding
              .instance
              .defaultBinaryMessenger
              .setMockMethodCallHandler(SystemChannels.platform, null),
        );
        final code = 'const x = "${'long content ' * 20}";';
        await t.pumpWidget(
          MaterialApp(
            theme: theme.build(brightness),
            home: Scaffold(
              body: SingleChildScrollView(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: NativeMarkdown(
                    source:
                        '# Title\n\nArea \$\\pi r^2\$ costs \$5 and \$10.\n\n\$\$\n\\frac{1}{2}\n\$\$\n\n```ts\n$code\n```\n\n| A | B |\n|---|---|\n| verylong${'word' * 30} | value |',
                  ),
                ),
              ),
            ),
          ),
        );
        await t.pumpAndSettle();
        final inlineFormulas = t
            .widgetList<NativeMathParagraphContent>(
              find.byType(NativeMathParagraphContent),
            )
            .expand((content) => content.formulas)
            .toList(growable: false);
        final displaySources = t.widgetList<NativeMathTex>(
          find.byType(NativeMathTex),
        );
        final formulaSources = [
          ...inlineFormulas.map((formula) => formula.source.expression),
          ...displaySources.map((formula) => formula.expression),
        ];
        expect(formulaSources, hasLength(2));
        expect(formulaSources.toSet(), {r'\pi r^2', r'\frac{1}{2}'});
        expect(inlineFormulas.single.math.ast, isNotNull);
        expect(
          displaySources.single
              .resolve(t.element(find.byType(NativeMathTex)))
              .math
              .ast,
          isNotNull,
        );
        expect(find.byType(NativeCodeBlock), findsOneWidget);
        await t.tap(find.text('Copy'));
        await t.pumpAndSettle();
        expect(copied, code);
        expect(find.text('Copied'), findsOneWidget);
        await t.pump(const Duration(milliseconds: 1400));
        expect(find.text('Copy'), findsOneWidget);
        expect(t.takeException(), isNull);
      },
    );
  }
  testWidgets(
    'long assistant content stays inline instead of being replaced by a preview',
    (t) async {
      final g = FakeGateway();
      final c = LiveController(g);
      final content = 'START\n\n${'full message text ' * 100}\n\nEND';
      await t.pumpWidget(MobileApp(theme: theme, controller: c));
      await t.pumpAndSettle();
      await c.open('s');
      g.publish('s', text: content);
      await t.pumpAndSettle();
      expect(
        find.byWidgetPredicate(
          (w) => w is NativeMarkdown && w.source == content,
        ),
        findsOneWidget,
      );
      await t.pumpWidget(const SizedBox());
      await g.stream.close();
    },
  );
}
