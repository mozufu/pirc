import 'dart:convert';
import 'dart:io';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_render/src/native_markdown.dart';
import 'package:pirc_render/src/markdown_selection.dart';
import 'live_test.dart' show theme;

void main() {
  final fixture =
      jsonDecode(
            File(
              '../../fixtures/mobile-parity/markdown-selection.json',
            ).readAsStringSync(),
          )
          as Map;
  final web =
      jsonDecode(
            File(
              '../../fixtures/mobile-parity/markdown-selection-expected.json',
            ).readAsStringSync(),
          )
          as List;
  String? clipboard;
  setUp(() {
    clipboard = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'Clipboard.setData') {
            clipboard = (call.arguments as Map)['text'] as String;
          }
          return null;
        });
  });
  Widget shell(
    String source, {
    bool streaming = false,
    void Function(String)? onLink,
    bool ancestor = false,
  }) {
    final markdown = NativeMarkdown(
      source: source,
      streaming: streaming,
      onLink: onLink,
    );
    return MaterialApp(
      theme: theme.build(Brightness.light),
      home: Scaffold(
        body: Padding(
          padding: const EdgeInsets.all(20),
          child: ancestor ? SelectionArea(child: markdown) : markdown,
        ),
      ),
    );
  }

  Future<String?> copy(WidgetTester t, {bool all = true}) async {
    final state = t.state<SelectableRegionState>(find.byType(SelectableRegion));
    if (all) state.selectAll(SelectionChangedCause.keyboard);

    await t.pump();
    state.contextMenuButtonItems
        .firstWhere((item) => item.type == ContextMenuButtonType.copy)
        .onPressed!();
    await t.pump();
    return clipboard;
  }

  for (final id in (fixture['cases'] as List).map((c) => c['id'] as String)) {
    testWidgets('continuous native selection matches Chromium: $id', (t) async {
      final c =
          (fixture['cases'] as List).firstWhere((c) => c['id'] == id) as Map;
      await t.pumpWidget(shell(c['source'] as String));
      await t.pumpAndSettle();
      expect(
        await copy(t),
        (web.firstWhere((c) => c['id'] == id) as Map)['text'],
      );
      expect(find.byType(SelectionArea), findsOneWidget);
      expect(find.byType(SelectableText), findsNothing);
      expect(t.takeException(), isNull);
    });
  }
  final dragCase =
      (fixture['cases'] as List).firstWhere((c) => c['id'] == 'table-drag')
          as Map;
  for (final range in dragCase['ranges'] as List) {
    for (final reverse in [false, true]) {
      testWidgets('partial table selection ${range['id']} reverse=$reverse', (
        t,
      ) async {
        await t.pumpWidget(shell(dragCase['source'] as String));
        await t.pumpAndSettle();
        Offset point(Map spec) {
          if (spec['selector'] != null) {
            return t.getCenter(
              find.byWidgetPredicate(
                (w) =>
                    w is NativeSelectionGroup &&
                    w.tableCell == (row: 1, column: 1),
              ),
            );
          }
          final paragraph = t.renderObject<RenderParagraph>(
            find.byWidgetPredicate(
              (w) => w is RichText && w.text.toPlainText() == spec['text'],
            ),
          );
          return paragraph.localToGlobal(
            paragraph.getOffsetForCaret(
                  TextPosition(offset: spec['offset'] as int),
                  Rect.zero,
                ) +
                Offset(.1, paragraph.size.height / 2),
          );
        }

        final start = point(range[reverse ? 'to' : 'from'] as Map);
        final end = point(range[reverse ? 'from' : 'to'] as Map);
        final gesture = await t.startGesture(
          start,
          kind: PointerDeviceKind.mouse,
        );
        // Include intermediate pointer updates, as with a real drag through the
        // empty cell, rather than dispatching a synthetic select-all event.
        for (var i = 1; i <= 6; i++) {
          await gesture.moveTo(Offset.lerp(start, end, i / 6)!);
        }
        await gesture.up();
        await t.pumpAndSettle();
        final expected =
            (web.firstWhere((c) => c['id'] == 'table-drag')['ranges'] as List)
                .firstWhere((r) => r['id'] == range['id']);
        expect(
          await copy(t, all: false),
          expected[reverse ? 'reverse' : 'text'],
        );
        expect(t.takeException(), isNull);
      });
    }
  }
  testWidgets('table image span adds no placeholder text to copied content', (
    t,
  ) async {
    final markdown = NativeMarkdown(
      source: '| Chart |\n|---|\n| ![Chart](images/chart.svg) |',
      imageBuilder: (_, _, _) => Semantics(
        label: 'Chart alternative text',
        child: SizedBox(width: 40, height: 20),
      ),
    );
    final semantics = t.ensureSemantics();
    await t.pumpWidget(
      MaterialApp(
        theme: theme.build(Brightness.light),
        home: Scaffold(
          body: Padding(padding: const EdgeInsets.all(20), child: markdown),
        ),
      ),
    );
    await t.pumpAndSettle();
    final copied = await copy(t);
    expect(copied, 'Chart\n');
    expect(copied, isNot(contains('\uFFFC')));
    expect(find.bySemanticsLabel('Chart alternative text'), findsOneWidget);
    expect(t.takeException(), isNull);
    semantics.dispose();
  });
  testWidgets('text around multiple table images copies without placeholders', (
    t,
  ) async {
    final markdown = NativeMarkdown(
      source:
          '| Content |\n|---|\n| before ![first](images/first.png) middle ![second](images/second.png) after |',
      imageBuilder: (uri, _, _) => Semantics(
        label: uri.pathSegments.last,
        child: SizedBox(
          key: ValueKey(uri.pathSegments.last),
          width: 20,
          height: 10,
        ),
      ),
    );
    await t.pumpWidget(
      MaterialApp(
        theme: theme.build(Brightness.light),
        home: Scaffold(
          body: Padding(padding: const EdgeInsets.all(20), child: markdown),
        ),
      ),
    );
    await t.pumpAndSettle();
    final copied = await copy(t);
    expect(copied, 'Content\nbefore  middle  after');
    expect(copied, isNot(contains('\uFFFC')));
    expect(
      t.getSize(find.byKey(const ValueKey('first.png'))),
      const Size(20, 10),
    );
    expect(
      t.getSize(find.byKey(const ValueKey('second.png'))),
      const Size(20, 10),
    );
    expect(t.takeException(), isNull);
  });
  testWidgets('linked table image keeps its tap target', (t) async {
    final links = <String>[];
    final markdown = NativeMarkdown(
      source:
          '| Link |\n|---|\n| [![Chart](images/chart.svg)](https://example.test/chart) |',
      onLink: links.add,
      imageBuilder: (_, _, _) =>
          const SizedBox(key: ValueKey('table-image'), width: 40, height: 20),
    );
    await t.pumpWidget(
      MaterialApp(
        theme: theme.build(Brightness.light),
        home: Scaffold(
          body: Padding(padding: const EdgeInsets.all(20), child: markdown),
        ),
      ),
    );
    await t.pumpAndSettle();
    await t.tapAt(t.getCenter(find.byKey(const ValueKey('table-image'))));
    expect(links, ['https://example.test/chart']);
    expect(t.takeException(), isNull);
  });
  testWidgets('empty table cells do not merge different rows', (t) async {
    await t.pumpWidget(
      shell('| A | B |\n|---|---|\n| | value |\n| last | end |'),
    );
    await t.pumpAndSettle();
    expect(await copy(t), 'A\tB\nvalue\nlast\tend');
  });
  testWidgets(
    'mouse drag crosses prose, inline code and link without activation',
    (t) async {
      final links = <String>[];
      await t.pumpWidget(
        shell(
          'Before `inline code` after [link](https://example.test).',
          onLink: links.add,
        ),
      );
      await t.pumpAndSettle();
      Offset edge(String text, int offset) {
        final p = t.renderObject<RenderParagraph>(
          find.byWidgetPredicate(
            (w) => w is RichText && w.text.toPlainText() == text,
          ),
        );
        return p.localToGlobal(
          p.getOffsetForCaret(TextPosition(offset: offset), Rect.zero) +
              Offset(0, p.size.height / 2),
        );
      }

      final gesture = await t.startGesture(
        edge('Before ', 2),
        kind: PointerDeviceKind.mouse,
      );
      await gesture.moveTo(edge(' after link.', 11));
      await gesture.up();
      await t.pumpAndSettle();
      expect(await copy(t, all: false), 'fore inline code after link');
      expect(links, isEmpty);
      // A normal tap still follows the inline-code link after selection clears.
      await t.pumpWidget(
        shell('[`src/main.ts`](file:src/main.ts)', onLink: links.add),
      );
      await t.pumpAndSettle();
      await t.tap(find.text('src/main.ts'));
      await t.pumpAndSettle();
      expect(links, ['src/main.ts']);
    },
  );
  testWidgets(
    'reuses ancestor and includes a horizontally scrollable code block',
    (t) async {
      await t.pumpWidget(
        shell(
          'Before\n\n```dart\nfinal x = 1;\nprint(x);\n```\n\nAfter',
          ancestor: true,
        ),
      );
      await t.pumpAndSettle();
      expect(find.byType(SelectionArea), findsOneWidget);
      final text = await copy(t);
      expect(text, contains('Before\n\ndart\nCopy\nfinal x = 1;\nprint(x);'));
      expect(text, endsWith('After'));
      await t.tap(find.text('Copy'));
      await t.pumpAndSettle();
      expect(clipboard, 'final x = 1;\nprint(x);');
      await t.pump(const Duration(milliseconds: 1400));
    },
  );
  testWidgets('stable streamed chunks remain selected while tail changes', (
    t,
  ) async {
    await t.pumpWidget(shell('Stable `code`.\n\nTail', streaming: true));
    await t.pump(const Duration(milliseconds: 80));
    await t.pumpAndSettle();
    final region = t.state<SelectableRegionState>(
      find.byType(SelectableRegion),
    );
    region.selectAll(SelectionChangedCause.keyboard);
    await t.pump();
    await t.pumpWidget(
      shell('Stable `code`.\n\nTail expanded', streaming: true),
    );
    await t.pump(const Duration(milliseconds: 80));
    expect(await copy(t, all: false), startsWith('Stable code.'));
    await t.pumpWidget(const SizedBox());
    expect(t.takeException(), isNull);
  });
  testWidgets('selection survives an asynchronous inline image reflow', (
    t,
  ) async {
    const pngBase64 =
        'iVBORw0KGgoAAAANSUhEUgAAAEAAAAAgCAYAAACinX6EAAAAQUlEQVR42u3QMQEAAAQAMGW0UlM+erBjBRbZNZ+FAAECBAgQIECAAAECBAgQIECAAAECBAgQIECAAAECBAgQcN8Cap6pADGo7g8AAAAASUVORK5CYII=';
    final png = base64Decode(pngBase64);
    var imageDecoded = false;
    final revealImage = ValueNotifier<bool>(false);
    addTearDown(revealImage.dispose);
    final markdown = NativeMarkdown(
      source: 'Before ![chart](images/chart.png) after\n\nTail paragraph',
      imageBuilder: (_, _, _) => ValueListenableBuilder<bool>(
        valueListenable: revealImage,
        builder: (context, reveal, _) => Image.memory(
          png,
          frameBuilder: (context, child, frame, synchronous) {
            if (frame != null) imageDecoded = true;
            return reveal ? child : const SizedBox.shrink();
          },
        ),
      ),
    );
    await t.pumpWidget(
      MaterialApp(
        theme: theme.build(Brightness.light),
        home: Scaffold(
          body: Padding(padding: const EdgeInsets.all(20), child: markdown),
        ),
      ),
    );
    await t.pumpAndSettle();

    for (var turn = 0; turn < 20 && !imageDecoded; turn++) {
      await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 25)),
      );
      await t.pump();
    }
    await t.pumpAndSettle();
    expect(imageDecoded, isTrue);

    final region = t.state<SelectableRegionState>(
      find.byType(SelectableRegion),
    );
    region.selectAll(SelectionChangedCause.keyboard);
    await t.pump();
    expect(
      region.contextMenuButtonItems.map((item) => item.type),
      contains(ContextMenuButtonType.copy),
    );
    revealImage.value = true;
    await t.pumpAndSettle();
    expect(find.byType(RawImage), findsOneWidget);
    expect(t.getSize(find.byType(RawImage)), const Size(64, 32));
    final copied = await copy(t, all: false);
    expect(copied, contains('Before'));
    expect(copied, contains('after'));
    expect(copied, contains('Tail paragraph'));
    expect(copied, isNot(contains('\uFFFC')));
    expect(t.takeException(), isNull);
  });
}
