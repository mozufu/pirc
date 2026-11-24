import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_render/src/native_markdown.dart';
import 'live_test.dart' show theme;
import '../tool/parity/capture_fonts.dart' show loadParityFonts;

void main() {
  final source =
      jsonDecode(
            File(
              '../../fixtures/mobile-parity/inline-math-paragraph.json',
            ).readAsStringSync(),
          )
          as Map;
  final oracle =
      jsonDecode(
            File(
              '../../fixtures/mobile-parity/inline-math-clipboard-expected.json',
            ).readAsStringSync(),
          )
          as Map;
  final ids = {
    'inline-before-after',
    'heading-inline-math',
    'inline-html-span-atomic',
    'inline-cjk-prose',
    'inline-rich-text-neighbors',
    'inline-adjacent-formulas',
    'inline-hard-break',
    'inline-tall-fraction-scripts',
  };
  String? copied;
  setUp(() {
    copied = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'Clipboard.setData') {
            copied = call.arguments['text'];
          }
          return null;
        });
  });
  tearDown(
    () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null),
  );
  final linearOracle =
      jsonDecode(
            File(
              '../../fixtures/mobile-parity/linear-math-clipboard-expected.json',
            ).readAsStringSync(),
          )
          as Map;
  // These extra expressions were observed independently in real Chrome at
  // 390/light/1; no wider capture claim is made for this nine-case corpus.
  for (final expected in linearOracle['cases'] as List) {
    testWidgets('Chrome symbols/numbers ${expected['id']}', (t) async {
      await t.runAsync(loadParityFonts);
      t.view.devicePixelRatio = 1;
      t.view.physicalSize = const Size(390, 1100);
      addTearDown(t.view.reset);
      await t.pumpWidget(
        MaterialApp(
          theme: theme.build(Brightness.light),
          home: Scaffold(
            body: Padding(
              padding: const EdgeInsets.all(16),
              child: SelectableRegion(
                selectionControls: materialTextSelectionHandleControls,
                contextMenuBuilder: (context, state) =>
                    AdaptiveTextSelectionToolbar.selectableRegion(
                      selectableRegionState: state,
                    ),
                child: NativeMarkdown(
                  source: expected['source'],
                  fontSize: 15,
                  lineHeight: 1.65,
                ),
              ),
            ),
          ),
        ),
      );
      await t.pumpAndSettle();
      final region = t.state<SelectableRegionState>(
        find.byType(SelectableRegion),
      );
      region.selectAll(SelectionChangedCause.keyboard);
      await t.pump();
      region.contextMenuButtonItems
          .singleWhere((item) => item.type == ContextMenuButtonType.copy)
          .onPressed!();
      await t.pump();
      expect(copied, expected['actualClipboard']['textPlain']);
      expect(t.takeException(), isNull);
      await t.pumpWidget(const SizedBox());
    });
  }
  for (final configuration in oracle['configurations'] as List) {
    for (final expected in configuration['cases'] as List) {
      if (!ids.contains(expected['id'])) continue;
      testWidgets('Chrome whole-copy ${configuration['id']}/${expected['id']}', (
        t,
      ) async {
        await t.runAsync(loadParityFonts);
        final viewport = configuration['viewport'] as Map;
        t.view.devicePixelRatio = 1;
        t.view.physicalSize = Size(
          (viewport['width'] as num).toDouble(),
          (viewport['height'] as num).toDouble(),
        );
        addTearDown(t.view.reset);
        final input = (source['cases'] as List).singleWhere(
          (row) => row['id'] == expected['id'],
        );
        final brightness = configuration['theme'] == 'dark'
            ? Brightness.dark
            : Brightness.light;
        await t.pumpWidget(
          MaterialApp(
            theme: theme.build(brightness),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(
                textScaler: TextScaler.linear(
                  (configuration['textScale'] as num).toDouble(),
                ),
              ),
              child: child!,
            ),
            home: Scaffold(
              body: Padding(
                padding: const EdgeInsets.all(16),
                child: SelectableRegion(
                  selectionControls: materialTextSelectionHandleControls,
                  contextMenuBuilder: (context, state) =>
                      AdaptiveTextSelectionToolbar.selectableRegion(
                        selectableRegionState: state,
                      ),
                  child: NativeMarkdown(
                    source: input['source'],
                    fontSize: 15,
                    lineHeight: 1.65,
                  ),
                ),
              ),
            ),
          ),
        );
        await t.pumpAndSettle();
        final region = t.state<SelectableRegionState>(
          find.byType(SelectableRegion),
        );
        region.selectAll(SelectionChangedCause.keyboard);
        await t.pump();
        region.contextMenuButtonItems
            .singleWhere((item) => item.type == ContextMenuButtonType.copy)
            .onPressed!();
        await t.pump();
        expect(
          copied,
          expected['actualClipboard']['textPlain'],
          reason:
              'Actual Chrome keyboard/clipboard observation, not Selection.toString().',
        );
        expect(t.takeException(), isNull);
        await t.pumpWidget(const SizedBox());
      });
    }
  }
}
