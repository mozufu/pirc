import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_mobile/bridge.dart';
import 'package:pirc_mobile/demo.dart';
import 'package:pirc_mobile/theme.dart';

void main() {
  final theme = PircTheme(
    jsonDecode(File('assets/design-tokens.json').readAsStringSync())
        as Map<String, dynamic>,
  );
  var version = 1;
  var savedDraft = '';
  setUp(() {
    version = 1;
    savedDraft = '';
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(MobileBridge.channel, (call) async {
          switch (call.method) {
            case 'read':
              return <String, Object?>{
                'revision': 1,
                'status': 'pending',
                'latestVersion': version,
                'draft': savedDraft,
              };
            case 'saveDraft':
              savedDraft = call.arguments as String;
              return null;
            case 'newVersion':
              version++;
              return null;
            default:
              return null;
          }
        });
  });
  tearDown(
    () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(MobileBridge.channel, null),
  );

  testWidgets(
    'resize preserves draft, right pane and reading position; update is explicit',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1024, 900);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(PircApp(theme: theme));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('draft')), '保留這段草稿');
      await tester.pump(const Duration(milliseconds: 300));
      await tester.ensureVisible(find.byKey(const Key('open-artifact')));
      await tester.tap(find.byKey(const Key('open-artifact')));
      await tester.pumpAndSettle();
      expect(find.text('實作筆記 · v1'), findsOneWidget);
      final reader = find.byKey(const Key('artifact-reader'));
      await tester.drag(reader, const Offset(0, -250));
      await tester.pumpAndSettle();
      final oldOffset = tester.widget<ListView>(reader).controller!.offset;
      expect(oldOffset, greaterThan(0));
      await tester.tap(find.byKey(const Key('close-artifact')));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const Key('open-artifact')));
      await tester.tap(find.byKey(const Key('open-artifact')));
      await tester.pumpAndSettle();
      expect(tester.widget<ListView>(reader).controller!.offset, oldOffset);
      tester.view.physicalSize = const Size(390, 844);
      await tester.pumpAndSettle();
      expect(tester.takeException(), null);
      expect(find.text('實作筆記 · v1'), findsOneWidget);
      expect(tester.widget<ListView>(reader).controller!.offset, oldOffset);
      version = 2;
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(find.text('實作筆記 · v1'), findsOneWidget);
      expect(find.text('已有 v2，目前內容保留'), findsOneWidget);
      await tester.tap(find.byKey(const Key('switch-version')));
      await tester.pumpAndSettle();
      expect(find.text('實作筆記 · v2'), findsOneWidget);
      expect(tester.widget<ListView>(reader).controller!.offset, 0);
      await tester.tap(find.byKey(const Key('close-artifact')));
      await tester.pumpAndSettle();
      expect(find.text('保留這段草稿'), findsOneWidget);
      expect(savedDraft, '保留這段草稿');
      await tester.pumpWidget(const SizedBox());
    },
  );

  for (final width in [390.0, 507.0, 768.0, 1024.0]) {
    testWidgets('$width wide at 2x text scale with keyboard has no overflow', (
      tester,
    ) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = Size(width, 900);
      tester.view.viewInsets = const FakeViewPadding(bottom: 300);
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.view.reset);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await tester.pumpWidget(PircApp(theme: theme));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('draft')), '中文輸入測試');
      await tester.pump(const Duration(milliseconds: 300));
      expect(
        tester.getRect(find.byKey(const Key('draft'))).bottom,
        lessThanOrEqualTo(600),
      );
      expect(tester.takeException(), null);
      await tester.pumpWidget(const SizedBox());
    });
  }
}
