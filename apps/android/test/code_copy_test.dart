import 'dart:async';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_render/src/code_block.dart';
import 'package:pirc_mobile/theme.dart';
import 'live_test.dart' show theme;

Widget shell(String source, [Brightness brightness = Brightness.light]) =>
    MaterialApp(
      theme: theme.build(brightness),
      home: Scaffold(
        body: NativeCodeBlock(source: source, language: 'text'),
      ),
    );

void main() {
  testWidgets(
    'copy feedback expires at 1400ms and repeated clicks retain web timing',
    (t) async {
      t.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async => null,
      );
      addTearDown(
        () => t.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      await t.pumpWidget(shell('source'));
      await t.tap(find.text('Copy'));
      await t.pump();
      await t.pump(const Duration(milliseconds: 1000));
      await t.tap(find.text('Copied'));
      await t.pump();
      await t.pump(const Duration(milliseconds: 399));
      expect(find.text('Copied'), findsOneWidget);
      await t.pump(const Duration(milliseconds: 1));
      expect(find.text('Copy'), findsOneWidget);
      await t.pump(const Duration(milliseconds: 1000));
    },
  );

  testWidgets('old clipboard completion cannot mark replacement code copied', (
    t,
  ) async {
    final pending = Completer<void>();
    String? written;
    t.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          written = (call.arguments as Map)['text'] as String;
          await pending.future;
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
    await t.pumpWidget(shell('old'));
    await t.tap(find.text('Copy'));
    await t.pump();
    expect(written, 'old');
    await t.pumpWidget(shell('new'));
    pending.complete();
    await t.pump();
    expect(find.text('Copy'), findsOneWidget);
    expect(find.text('Copied'), findsNothing);
    await t.tap(find.text('Copy'));
    await t.pump();
    expect(written, 'new');
    expect(find.text('Copied'), findsOneWidget);
    await t.pumpWidget(const SizedBox.shrink());
    await t.pump(const Duration(seconds: 2));
    expect(t.takeException(), isNull);
  });

  for (final brightness in Brightness.values) {
    testWidgets('copy hover uses web colors in $brightness', (t) async {
      await t.pumpWidget(shell('source', brightness));
      final colors = theme.build(brightness).extension<PircColors>()!;
      final mouse = await t.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: Offset.zero);
      await mouse.moveTo(t.getCenter(find.byType(TextButton)));
      await t.pumpAndSettle();
      final material = t.widget<Material>(
        find.descendant(
          of: find.byType(TextButton),
          matching: find.byType(Material),
        ),
      );
      expect(material.color, colors['web.bg-hover']);
      final label = t.element(find.text('Copy'));
      expect(DefaultTextStyle.of(label).style.color, colors['text.primary']);
      await mouse.moveTo(Offset.zero);
      await t.pumpAndSettle();
      expect(DefaultTextStyle.of(label).style.color, colors['text.muted']);
      await mouse.removePointer();
    });
  }
}
