import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_render/src/markdown_stream.dart';
import 'package:pirc_render/src/native_markdown.dart';
import 'live_test.dart' show theme;

final streamTheme = theme.build(Brightness.light);
Widget shell(String source, {bool streaming = true}) => MaterialApp(
  theme: streamTheme,
  home: Scaffold(
    body: SingleChildScrollView(
      child: NativeMarkdown(source: source, streaming: streaming),
    ),
  ),
);
List<String> rendered(WidgetTester t) => t
    .widgetList<MarkdownBody>(find.byWidgetPredicate((w) => w is MarkdownBody))
    .map((w) => w.data)
    .toList();
void main() {
  testWidgets('cursor is native, suppressed in code, removed at completion', (
    t,
  ) async {
    await t.pumpWidget(shell('streaming **answer**'));
    expect(
      find.byKey(const ValueKey('markdown-stream-cursor')),
      findsOneWidget,
    );
    await t.pumpWidget(shell('```dart\nprint(1)'));
    await t.pump(const Duration(milliseconds: 80));
    expect(find.byKey(const ValueKey('markdown-stream-cursor')), findsNothing);
    await t.pumpWidget(const SizedBox());
  });
  test('native boundaries compared to actual pinned web lexer', () {
    final f =
        jsonDecode(
              File(
                '../../fixtures/mobile-parity/streaming.json',
              ).readAsStringSync(),
            )
            as Map;
    for (final c in f['cases'] as List) {
      expect(
        nativeStableBlockEnd(c['source'] as String, c['from'] as int),
        c['end'],
        reason: c['source'] as String,
      );
    }
  });
  test('matches pinned web boundary cases, preserving nested blocks', () {
    final cases = <String, int>{
      '# Title\n\npara one\n\n- a\n- b\n\nlast': 28,
      '```ts\nx\n\ny\n```\n\nafter': 16,
      '| a | b |\n|---|---|\n| 1 | 2 |\n\ntext': 31,
      '\$\$\nx\n\ny\n\$\$\n\nz': 12,
      '> q\n\n> r\n\nz': 10,
      'just a paragraph': 0,
      '1. a\n\n2. b\n\n3. c': 0,
      '```ts\nopen\n\nstill': 0,
      'a\r\n\r\nb': 0,
      'heading\n---\n\nafter': 13,
      '- item\n  - nested\n\nlast': 19,
    };
    for (final e in cases.entries) {
      expect(nativeStableBlockEnd(e.key), e.value, reason: e.key);
    }
    expect(nativeStableBlockEnd('one\n\ntwo\n\nthree', 5), 10);
  });
  test('HTML chunks are cached only after their native DOM scope closes', () {
    const prefix = 'ready\n\n';
    for (final raw in [
      '<details open>\n<summary title="a > b">Notes</summary>\n\nfirst\n\nsecond',
      '<div>\n\nfirst\n\nsecond',
      '<table>\n\n<tr><td>first\n\nsecond',
    ]) {
      expect(nativeStableBlockEnd('$prefix$raw'), prefix.length, reason: raw);
    }
    for (final complete in [
      '<details><summary>Notes</summary>\n\nfirst\n\n</details>',
      '<div title="a > b"><img src="image.png"><br>body</div>',
      'text <span>first</span>',
      'text <span title="a > b">implicitly closed by the paragraph',
      '`<div>`',
      r'\<div>',
      '```html\n<div>\n```',
      r'$<div>$',
    ]) {
      final source = '$prefix$complete\n\ntail';
      expect(
        nativeStableBlockEnd(source),
        source.length - 'tail'.length,
        reason: source,
      );
    }
  });
  testWidgets('coalesces deltas; retains completed chunk element until final', (
    t,
  ) async {
    await t.pumpWidget(shell('one\n\ntwo'));
    expect(rendered(t), ['one\n\n', 'two']);
    final element = t.element(
      find.byWidgetPredicate((w) => w is MarkdownBody).first,
    );
    final child = t.widget(
      find
          .descendant(
            of: find.byWidgetPredicate((w) => w is MarkdownBody).first,
            matching: find.byType(Text),
          )
          .first,
    );
    await t.pumpWidget(shell('one\n\ntwo three'));
    expect(rendered(t).last, 'two');
    await t.pump(const Duration(milliseconds: 79));
    expect(rendered(t).last, 'two');
    await t.pump(const Duration(milliseconds: 1));
    expect(rendered(t).last, 'two three');
    expect(
      identical(
        element,
        t.element(find.byWidgetPredicate((w) => w is MarkdownBody).first),
      ),
      true,
    );
    expect(
      identical(
        child,
        t.widget(
          find
              .descendant(
                of: find.byWidgetPredicate((w) => w is MarkdownBody).first,
                matching: find.byType(Text),
              )
              .first,
        ),
      ),
      true,
      reason: 'Stable children are not parsed/built again.',
    );
    await t.pumpWidget(shell('one\n\ntwo three', streaming: false));
    expect(rendered(t), ['one\n\ntwo three']);
    await t.pumpWidget(const SizedBox());
  });
  testWidgets('replacement resets chunks; references resolve as one document', (
    t,
  ) async {
    await t.pumpWidget(shell('old\n\nanswer'));
    await t.pumpWidget(shell('new\n\nreply'));
    await t.pump(const Duration(milliseconds: 80));
    expect(rendered(t), ['new\n\n', 'reply']);
    const source = '[link][ref]\n\nsecond\n\n[ref]: https://example.test';
    await t.pumpWidget(shell(source));
    await t.pump(const Duration(milliseconds: 80));
    await t.pumpWidget(shell(source, streaming: false));
    expect(rendered(t), [source]);
    await t.pumpWidget(const SizedBox());
  });
  testWidgets(
    'latest final text flushes immediately and style changes invalidate cached blocks',
    (t) async {
      await t.pumpWidget(shell('stable\n\ntail'));
      await t.pumpWidget(shell('stable\n\ntail updated'));
      expect(rendered(t).last, 'tail');
      await t.pumpWidget(shell('stable\n\ntail final', streaming: false));
      expect(rendered(t), ['stable\n\ntail final']);
      await t.pumpWidget(
        MaterialApp(
          theme: streamTheme,
          home: const Scaffold(
            body: NativeMarkdown(
              source: 'stable\n\ntail',
              streaming: true,
              fontSize: 20,
            ),
          ),
        ),
      );
      expect(
        t
            .widget<MarkdownBody>(
              find.byWidgetPredicate((w) => w is MarkdownBody).first,
            )
            .styleSheet!
            .p!
            .fontSize,
        20,
      );
      await t.pumpWidget(
        MaterialApp(
          theme: streamTheme,
          home: const Scaffold(
            body: NativeMarkdown(
              source: 'stable\n\ntail',
              streaming: true,
              fontSize: 24,
            ),
          ),
        ),
      );
      expect(
        t
            .widget<MarkdownBody>(
              find.byWidgetPredicate((w) => w is MarkdownBody).first,
            )
            .styleSheet!
            .p!
            .fontSize,
        24,
      );
      await t.pumpWidget(const SizedBox());
    },
  );
  testWidgets('cursor preserves text and follows final list item', (t) async {
    await t.pumpWidget(shell('- first\n- second **bold**'));
    expect(
      find.byKey(const ValueKey('markdown-stream-cursor')),
      findsOneWidget,
    );
    final texts = t
        .widgetList<Text>(find.byType(Text))
        .map((w) => w.textSpan?.toPlainText() ?? w.data ?? '')
        .join();
    expect(texts, contains('second bold'));
    await t.pumpWidget(shell('| A | B |\n|---|---|\n| 1 | 2 |'));
    await t.pump(const Duration(milliseconds: 80));
    expect(find.byKey(const ValueKey('markdown-stream-cursor')), findsNothing);
    await t.pumpWidget(const SizedBox());
  });
  testWidgets('open fences and loose lists stay whole while streaming', (
    t,
  ) async {
    const source = '1. a\n\n2. b\n\n3. c';
    await t.pumpWidget(shell(source));
    expect(rendered(t), [source]);
    await t.pumpWidget(shell('```dart\nfinal a = 1;\n\nstill code'));
    await t.pump(const Duration(milliseconds: 80));
    expect(rendered(t), ['```dart\nfinal a = 1;\n\nstill code']);
    expect(t.takeException(), isNull);
    await t.pumpWidget(const SizedBox());
  });
}
