import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_widget_from_html_core/flutter_widget_from_html_core.dart';
import 'package:flutter_math_fork/flutter_math.dart';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html;
import 'package:pirc_render/src/code_block.dart';
import 'package:pirc_render/src/native_html.dart';
import 'package:pirc_render/src/native_markdown.dart';
import 'package:pirc_mobile/live/gateway.dart';
import 'live_test.dart' show theme;

final htmlFixture = obj(
  jsonDecode(File('../../fixtures/mobile-parity/html.json').readAsStringSync()),
);
final expected = rows(
  jsonDecode(
    File(
      '../../fixtures/mobile-parity/html-web-expected.json',
    ).readAsStringSync(),
  ),
);
Widget shell(
  String source, {
  ValueChanged<String>? onLink,
  bool streaming = false,
}) => MaterialApp(
  theme: theme.build(Brightness.light),
  home: Scaffold(
    body: SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: NativeMarkdown(
        source: source,
        onLink: onLink,
        streaming: streaming,
        imageBuilder: (uri, title, alt) =>
            Text('image:$uri', key: ValueKey(alt)),
      ),
    ),
  ),
);
// Compare DOM semantics independent of attribute ordering, layout whitespace and
// browser-only link target hooks. Code/text escaping and retained structure matter.
List<Object> structure(String source) {
  List<Object> nodes(Iterable<dom.Node> children) => [
    for (final n in children)
      if (n is dom.Text && n.text.trim().isNotEmpty)
        n.text.replaceAll(RegExp(r'\s+'), ' ').trim()
      else if (n is dom.Element)
        [
          n.localName,
          {
            for (final e in n.attributes.entries)
              if (!['target', 'rel', 'data-file-link'].contains('${e.key}'))
                '${e.key}': e.value,
          },
          nodes(n.nodes),
        ],
  ];
  return nodes(html.parseFragment(source).nodes);
}

Future<void> tapText(WidgetTester t, String label) async {
  final f = find
      .byWidgetPredicate(
        (w) => w is RichText && w.text.toPlainText().contains(label),
      )
      .first;
  await t.ensureVisible(f);
  await t.pumpAndSettle();
  final rich = t.widget<RichText>(f),
      render = t.renderObject<RenderParagraph>(f);
  final start = rich.text.toPlainText().indexOf(label);
  final box = render
      .getBoxesForSelection(
        TextSelection(baseOffset: start, extentOffset: start + 1),
      )
      .first
      .toRect();
  await t.tapAt(render.localToGlobal(box.center));
  await t.pumpAndSettle();
}

void main() {
  test('raw submitter action keeps URL policy while target remains a name', () {
    const source =
        '<form><button formaction="javascript:alert(1)" '
        'formtarget="named:window" formmethod="post" formenctype="text/plain">'
        'Send</button></form>';
    final raw = html
        .parseFragment(sanitizeNativeHtml(source, markdownPolicy: false))
        .querySelector('button')!;
    expect(raw.attributes.containsKey('formaction'), isFalse);
    expect(raw.attributes['formtarget'], 'named:window');
    expect(raw.attributes['formmethod'], 'post');
    expect(raw.attributes['formenctype'], 'text/plain');
    final markdown = html
        .parseFragment(sanitizeNativeHtml(source))
        .querySelector('button')!;
    for (final name in [
      'formaction',
      'formtarget',
      'formmethod',
      'formenctype',
    ]) {
      expect(markdown.attributes.containsKey(name), isFalse);
    }
  });

  for (final item in rows(
    htmlFixture['cases'],
  ).where((c) => c['id'] != 'mixed')) {
    testWidgets('native HTML DOM matches pinned web ${item['id']}', (t) async {
      await t.pumpWidget(shell('${item['source']}'));
      await t.pumpAndSettle();
      expect(find.byType(HtmlWidget), findsOneWidget);
      final actual = t.widget<HtmlWidget>(find.byType(HtmlWidget)).html;
      expect(
        structure(actual),
        structure(
          '${expected.singleWhere((e) => e['id'] == item['id'])['html']}',
        ),
      );
      expect(t.takeException(), isNull);
      await t.pumpWidget(const SizedBox());
    });
  }
  test(
    'native tag and URI policy removes active URLs and forbidden contents',
    () {
      final clean = sanitizeNativeHtml(
        '<p onclick="alert(1)"><a href="jav&#x09;ascript:bad">inert</a><img src="file:///private/test.png"><script>secret</script><iframe>secret</iframe><unknown>kept</unknown></p>',
      );
      expect(clean, '<p><a>inert</a><img>kept</p>');
      expect(
        sanitizeNativeHtml(
          '<img src="data:image/png;base64,AA==" alt="a > b">',
        ),
        contains('data:image/png'),
      );
      expect(
        sanitizeNativeHtml('<a href="file:///project/main.dart">source</a>'),
        contains('href="/project/main.dart"'),
      );
    },
  );
  testWidgets(
    'escaped HTML and code remain literal without entering HTML path',
    (t) async {
      await t.pumpWidget(shell(r'\<b>literal\</b> and `<i>code</i>`'));
      await t.pumpAndSettle();
      expect(find.byType(HtmlWidget), findsNothing);
      expect(
        find.textContaining('<b>literal</b>', findRichText: true),
        findsWidgets,
      );
    },
  );
  testWidgets('details toggle preserves content and nested Markdown', (
    t,
  ) async {
    await t.pumpWidget(
      shell(
        '${rows(htmlFixture['cases']).singleWhere((e) => e['id'] == 'details')['source']}',
      ),
    );
    await t.pumpAndSettle();
    expect(
      find.textContaining('Markdown inside', findRichText: true),
      findsWidgets,
    );
    final summary = find.textContaining('Closed notes', findRichText: true);
    expect(summary, findsOneWidget);
    await t.tap(summary);
    await t.pumpAndSettle();
    expect(
      find.text('Hidden until opened.', findRichText: true).hitTestable(),
      findsOneWidget,
    );
    await t.tap(summary);
    await t.pumpAndSettle();
    expect(
      find.text('Hidden until opened.', findRichText: true).hitTestable(),
      findsNothing,
    );
  });
  testWidgets('mixed HTML retains native code copy, math and table widgets', (
    t,
  ) async {
    String? copied;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'Clipboard.setData') {
            copied = call.arguments['text'] as String;
          }
          return null;
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null),
    );
    await t.pumpWidget(
      shell(
        '${rows(htmlFixture['cases']).singleWhere((e) => e['id'] == 'mixed')['source']}',
      ),
    );
    await t.pumpAndSettle();
    expect(find.byType(NativeCodeBlock), findsOneWidget);
    expect(find.byType(Math), findsOneWidget);
    expect(find.byKey(const ValueKey('native-markdown-table')), findsOneWidget);
    expect(
      find.byType(NativeTaskCheckbox),
      findsOneWidget,
      reason: t.widget<HtmlWidget>(find.byType(HtmlWidget)).html,
    );
    expect(
      find.text('NOT VISIBLE', findRichText: true).hitTestable(),
      findsNothing,
    );
    await t.tap(find.text('Copy'));
    await t.pumpAndSettle();
    expect(copied, 'final ready = true;');
    await t.pump(const Duration(milliseconds: 1400));
    expect(t.takeException(), isNull);
  });
  testWidgets(
    'HTML links use the existing dispatcher and scripts cannot dispatch',
    (t) async {
      String? link;
      await t.pumpWidget(
        shell(
          '<p><a href="file:///project/main.dart:12">Source</a> <a href="javascript:bad">Inert</a></p>',
          onLink: (v) => link = v,
        ),
      );
      await t.pumpAndSettle();
      await tapText(t, 'Source');
      expect(link, '/project/main.dart:12');
      link = null;
      await tapText(t, 'Inert');
      expect(link, isNull);
    },
  );
  testWidgets('HTML image schemes cannot reach filesystem loaders', (t) async {
    final requested = <Uri>[];
    await t.pumpWidget(
      MaterialApp(
        theme: theme.build(Brightness.light),
        home: Scaffold(
          body: NativeMarkdown(
            source:
                '<p style="background-image:url(file:///private/secret)"><img src="file:///private/secret" alt="local"><img src="asset:test" alt="asset"><img src="/api/preview/image" alt="remote"></p>',
            imageBuilder: (uri, title, alt) {
              requested.add(uri);
              return Text(alt ?? '');
            },
          ),
        ),
      ),
    );
    await t.pumpAndSettle();
    expect(requested, [Uri.parse('/api/preview/image')]);
    expect(t.takeException(), isNull);
  });
  testWidgets('streamed HTML containers keep Markdown children scoped', (
    t,
  ) async {
    const first =
        '<details open>\n<summary>Stream</summary>\n\n**First** paragraph.\n\n';
    await t.pumpWidget(shell(first, streaming: true));
    await t.pump(const Duration(milliseconds: 90));
    await t.pumpWidget(
      shell(
        '${first}Second paragraph.\n\n</details>\n\nOutside.',
        streaming: true,
      ),
    );
    await t.pump(const Duration(milliseconds: 90));
    expect(find.byType(HtmlWidget), findsOneWidget);
    final document = html.parseFragment(
      t.widget<HtmlWidget>(find.byType(HtmlWidget)).html,
    );
    expect(
      document.querySelector('details')!.text,
      contains('Second paragraph.'),
    );
    expect(
      document.querySelector('details')!.text,
      isNot(contains('Outside.')),
    );
    await t.pumpWidget(const SizedBox());
  });
}
