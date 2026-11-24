import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_mobile/live/app.dart';
import 'package:pirc_mobile/live/gateway.dart';
import 'package:pirc_mobile/live/permissions.dart';
import 'live_test.dart' show FakeGateway, theme;

class PermissionGateway extends FakeGateway {
  bool complete = false,
      notifications = false,
      overlay = false,
      deny = false,
      permanent = false,
      failFinish = false;
  @override
  dynamic normal(String method, Json args) {
    switch (method) {
      case 'boot':
        return {
          'origin': null,
          'clientId': 'phone',
          'onboardingComplete': complete,
        };
      case 'permissions':
        return {
          'notifications': notifications,
          'overlay': overlay,
          'notificationSettings': permanent,
        };
      case 'requestNotifications':
        if (!deny) notifications = true;
        return null;
      case 'requestOverlay':
        return null; // Only opens Settings; user decision comes later.
      case 'completeOnboarding':
        if (failFinish) {
          throw PlatformException(code: 'STORAGE', message: '無法儲存');
        }
        complete = true;
        return null;
      default:
        return super.normal(method, args);
    }
  }
}

Future<void> finishGuide(WidgetTester tester) async {
  final button = find.byKey(const Key('finish-onboarding'));
  await tester.scrollUntilVisible(
    button,
    300,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.pumpAndSettle();
  await tester.ensureVisible(button);
  await tester.pumpAndSettle();
  await tester.tap(button);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'first launch explains permissions without automatically requesting them; skip persists',
    (t) async {
      final g = PermissionGateway();
      await t.pumpWidget(
        MobileApp(theme: theme, controller: LiveController(g)),
      );
      await t.pumpAndSettle();
      expect(find.text('歡迎使用 pirc'), findsOneWidget);
      expect(g.calls.where((c) => c.$1.startsWith('request')), isEmpty);
      await finishGuide(t);
      expect(find.text('連接 pirc'), findsOneWidget);
      expect(g.complete, isTrue);
      await t.pumpWidget(const SizedBox());
      await t.pump();
      await t.pumpWidget(
        MobileApp(theme: theme, controller: LiveController(g)),
      );
      await t.pumpAndSettle();
      expect(find.byType(PermissionPage), findsNothing);
      await t.pumpWidget(const SizedBox());
      await t.pump();
      await g.stream.close();
    },
  );
  testWidgets('denial keeps notification disabled and does not block pairing', (
    t,
  ) async {
    final g = PermissionGateway()..deny = true;
    await t.pumpWidget(MobileApp(theme: theme, controller: LiveController(g)));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('permission-notifications')));
    await t.pumpAndSettle();
    expect(
      t
          .widget<Text>(
            find.byKey(const Key('permission-status-notifications')),
          )
          .data,
      '尚未開啟',
    );
    await finishGuide(t);
    expect(find.text('連接 pirc'), findsOneWidget);
    await t.pumpWidget(const SizedBox());
    await t.pump();
    await g.stream.close();
  });
  testWidgets(
    'opening overlay Settings is not permission; resume rechecks OS state',
    (t) async {
      final g = PermissionGateway();
      await t.pumpWidget(
        MaterialApp(
          theme: theme.build(Brightness.light),
          home: PermissionPage(gateway: g),
        ),
      );
      await t.pumpAndSettle();
      await t.ensureVisible(find.byKey(const Key('permission-overlay')));
      await t.tap(find.byKey(const Key('permission-overlay')));
      await t.pumpAndSettle();
      expect(
        t.widget<Text>(find.byKey(const Key('permission-status-overlay'))).data,
        '尚未開啟',
      );
      t.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      g.overlay = true;
      t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await t.pumpAndSettle();
      expect(
        t.widget<Text>(find.byKey(const Key('permission-status-overlay'))).data,
        '已開啟',
      );
      g.overlay = false;
      t.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await t.pumpAndSettle();
      expect(
        t.widget<Text>(find.byKey(const Key('permission-status-overlay'))).data,
        '尚未開啟',
      );
      await t.pumpWidget(const SizedBox());
      await g.stream.close();
    },
  );
  testWidgets('permanent denial directs user to system settings', (t) async {
    final g = PermissionGateway()..permanent = true;
    await t.pumpWidget(
      MaterialApp(
        theme: theme.build(Brightness.dark),
        home: PermissionPage(gateway: g),
      ),
    );
    await t.pumpAndSettle();
    expect(find.text('前往系統設定'), findsOneWidget);
    await t.pumpWidget(const SizedBox());
    await g.stream.close();
  });
  testWidgets('failed onboarding persistence cannot silently skip the guide', (
    t,
  ) async {
    final g = PermissionGateway()..failFinish = true;
    await t.pumpWidget(MobileApp(theme: theme, controller: LiveController(g)));
    await t.pumpAndSettle();
    await finishGuide(t);
    expect(find.byType(PermissionPage), findsOneWidget);
    expect(g.complete, isFalse);
    g.failFinish = false;
    await finishGuide(t);
    expect(find.text('連接 pirc'), findsOneWidget);
    await t.pumpWidget(const SizedBox());
    await t.pump();
    await g.stream.close();
  });
  for (final size in [
    const Size(390, 844),
    const Size(600, 900),
    const Size(1024, 768),
  ]) {
    for (final brightness in Brightness.values) {
      testWidgets('guide ${size.width} $brightness at 2x text remains usable', (
        t,
      ) async {
        t.view.devicePixelRatio = 1;
        t.view.physicalSize = size;
        t.platformDispatcher.textScaleFactorTestValue = 2;
        addTearDown(t.view.reset);
        addTearDown(t.platformDispatcher.clearTextScaleFactorTestValue);
        final g = PermissionGateway();
        var finished = false;
        await t.pumpWidget(
          MaterialApp(
            theme: theme.build(brightness),
            home: PermissionPage(
              gateway: g,
              onComplete: () async {
                finished = true;
              },
            ),
          ),
        );
        await t.pumpAndSettle();
        await finishGuide(t);
        expect(finished, isTrue);
        expect(t.takeException(), isNull);
        await t.pumpWidget(const SizedBox());
        await g.stream.close();
      });
    }
  }
}
