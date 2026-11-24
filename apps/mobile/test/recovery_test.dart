import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_mobile/live/app.dart';
import 'package:pirc_mobile/live/gateway.dart';
import 'package:pirc_mobile/live/common.dart';
import 'live_test.dart' show FakeGateway, theme;
import 'permissions_test.dart' show PermissionGateway;

void main() {
  testWidgets(
    'scanner success pairs through native bridge; cancellation does not pair',
    (t) async {
      final g = PermissionGateway()..complete = true;
      String? scanned;
      g.handler = (m, a) async {
        if (m == 'scan') return scanned;
        if (m == 'pair') {
          return {'origin': 'https://gateway.example', 'clientId': 'phone'};
        }
        return g.normal(m, a);
      };
      final c = LiveController(g);
      await t.pumpWidget(MobileApp(theme: theme, controller: c));
      await t.pumpAndSettle();
      await t.tap(find.text('掃描 QR code'));
      await t.pumpAndSettle();
      expect(g.calls.where((x) => x.$1 == 'pair'), isEmpty);
      scanned = 'test-link-from-scanner';
      await t.tap(find.text('掃描 QR code'));
      await t.pumpAndSettle();
      expect(g.calls.where((x) => x.$1 == 'pair').single.$2['link'], scanned);
      expect(find.text('今天想處理什麼？'), findsOneWidget);
      await t.pumpWidget(const SizedBox());
      await g.stream.close();
    },
  );
  testWidgets('scanner exception is readable and floating in both themes', (
    t,
  ) async {
    for (final brightness in Brightness.values) {
      final g = PermissionGateway()..complete = true;
      g.handler = (m, a) async {
        if (m == 'scan') {
          throw PlatformException(
            code: 'SCAN',
            message: "java.lang.Object.getClass() on a null object reference",
          );
        }
        return g.normal(m, a);
      };
      final c = LiveController(g);
      await t.pumpWidget(
        MaterialApp(
          theme: theme.build(brightness),
          home: PairingScreen(controller: c),
        ),
      );
      await t.tap(find.text('掃描 QR code'));
      await t.pumpAndSettle();
      expect(find.textContaining('java.lang'), findsNothing);
      expect(find.text('暫時無法開啟掃描器，請重試或貼上配對連結。'), findsOneWidget);
      final context = t.element(find.byType(PairingScreen));
      expect(
        Theme.of(context).snackBarTheme.backgroundColor,
        palette(context)['text.primary'],
      );
      expect(
        t.widget<SnackBar>(find.byType(SnackBar)).behavior,
        SnackBarBehavior.floating,
      );
      await t.pumpWidget(const SizedBox());
      await t.pump();
      c.dispose();
      await g.stream.close();
    }
  });
  testWidgets('home model selection returns to the root of the same sheet', (
    t,
  ) async {
    final g = FakeGateway();
    final c = LiveController(g);
    await t.pumpWidget(MobileApp(theme: theme, controller: c));
    await t.pumpAndSettle();
    await t.tap(find.text('預設模型'));
    await t.pumpAndSettle();
    expect(find.text('模型與思考'), findsOneWidget);
    await t.tap(find.text('模型'));
    await t.pumpAndSettle();
    await t.tap(find.text('模型一'));
    await t.pumpAndSettle();
    expect(find.text('模型與思考'), findsOneWidget);
    expect(find.text('思考強度'), findsOneWidget);
    expect(g.calls.where((x) => x.$1 == 'command'), isEmpty);
    await t.pumpWidget(const SizedBox());
    await g.stream.close();
  });
}
