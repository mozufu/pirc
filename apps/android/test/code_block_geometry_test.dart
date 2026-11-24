import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_render/src/code_block.dart';
import 'live_test.dart' show theme;

void main() {
  testWidgets('empty code keeps pre padding without an artificial text line', (
    t,
  ) async {
    String? copied;
    t.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String;
        }
        return null;
      },
    );
    addTearDown(
      () => t.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    await t.pumpWidget(
      MaterialApp(
        theme: theme.build(Brightness.light),
        home: const Scaffold(
          body: NativeCodeBlock(source: '', language: 'text'),
        ),
      ),
    );
    final pre = find.descendant(
      of: find.byType(NativeCodeBlock),
      matching: find.byWidgetPredicate(
        (w) =>
            w is SingleChildScrollView && w.scrollDirection == Axis.horizontal,
      ),
    );
    expect(t.getSize(pre).height, 24);
    await t.tap(find.text('Copy'));
    await t.pump();
    expect(copied, '');
    expect(find.text('Copied'), findsOneWidget);
    await t.pump(const Duration(milliseconds: 1400));
    expect(find.text('Copy'), findsOneWidget);
  });
}
