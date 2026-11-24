import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_render/src/native_markdown.dart';
import 'package:pirc_render/src/native_math_paragraph.dart';
import 'live_test.dart' show theme;
import '../tool/parity/capture_fonts.dart' show loadParityFonts;

void main() {
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
  final radicalOracle =
      jsonDecode(
            File(
              '../../fixtures/mobile-parity/radical-math-clipboard-expected.json',
            ).readAsStringSync(),
          )
          as Map;
  // These structural expressions were observed independently in real Chrome at
  // 390/light/1; no wider capture claim is made for this sixteen-case radical corpus.
  for (final expected in radicalOracle['cases'] as List) {
    testWidgets('Chrome radical whole-copy ${expected['id']}', (t) async {
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
  for (final brightness in Brightness.values) {
    testWidgets(
      'empty radical keeps visible geometry without hidden text and survives source replacement ${brightness.name}',
      (t) async {
        await t.runAsync(loadParityFonts);
        t.view.devicePixelRatio = 1;
        t.view.physicalSize = const Size(390, 1100);
        addTearDown(t.view.reset);
        for (final id in ['empty-square-root', 'sqrt-x']) {
          final input = (radicalOracle['cases'] as List).singleWhere(
            (value) => value['id'] == id,
          );
          await t.pumpWidget(
            MaterialApp(
              theme: theme.build(brightness),
              home: Scaffold(
                body: Padding(
                  padding: const EdgeInsets.all(16),
                  child: SelectableRegion(
                    selectionControls: materialTextSelectionHandleControls,
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
          if (id == 'empty-square-root') {
            final part = find.byType(NativeMathPart);
            expect(part, findsOneWidget);
            final size = t.getSize(part);
            expect(size.width, greaterThan(0));
            expect(size.height, greaterThan(0));
            expect(
              find.descendant(of: part, matching: find.byType(RichText)),
              findsNothing,
            );
          }
          final region = t.state<SelectableRegionState>(
            find.byType(SelectableRegion),
          );
          region.selectAll(SelectionChangedCause.keyboard);
          await t.pump();
          region.contextMenuButtonItems
              .singleWhere((item) => item.type == ContextMenuButtonType.copy)
              .onPressed!();
          await t.pump();
          expect(copied, input['actualClipboard']['textPlain']);
          expect(t.takeException(), isNull);
        }
        await t.pumpWidget(const SizedBox());
      },
    );
  }
}
