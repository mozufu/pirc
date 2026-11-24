import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_render/src/native_markdown.dart';
import 'live_test.dart' show theme;

void main() {
  testWidgets(
    'select-all preserves prose order across wrapped Math placeholders',
    (t) async {
      String? copied;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (call) async {
            if (call.method == 'Clipboard.setData') {
              copied = (call.arguments as Map)['text'] as String;
            }
            return null;
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(SystemChannels.platform, null),
      );
      t.view.physicalSize = const Size(390, 900);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      await t.pumpWidget(
        MaterialApp(
          theme: theme.build(Brightness.light),
          home: Builder(
            builder: (context) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: const TextScaler.linear(2)),
              child: const Scaffold(
                body: Padding(
                  padding: EdgeInsets.all(16),
                  child: NativeMarkdown(
                    source: r'Before $a+b$ after the formula.',
                    fontSize: 15,
                    lineHeight: 1.65,
                  ),
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
          .firstWhere((item) => item.type == ContextMenuButtonType.copy)
          .onPressed!();
      await t.pump();
      // Formula selection itself has its own parity gate. Here neither prose
      // fragment may move across the formula when one wraps onto another line.
      final oracle =
          jsonDecode(
                File(
                  '../../fixtures/mobile-parity/inline-math-clipboard-expected.json',
                ).readAsStringSync(),
              )
              as Map;
      final configuration = (oracle['configurations'] as List).singleWhere(
        (row) => row['id'] == '390-light-2',
      );
      final expected = (configuration['cases'] as List).singleWhere(
        (row) => row['id'] == 'inline-before-after',
      );
      expect(copied, expected['actualClipboard']['textPlain']);
      expect(copied, startsWith('Before '));
      expect(copied, endsWith(' after the formula.'));
      expect(t.takeException(), isNull);
    },
  );
}
