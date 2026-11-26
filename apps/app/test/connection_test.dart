import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_app/src/calendar/calendar_screen.dart';
import 'package:pirc_app/src/connection/connection.dart';
import 'package:pirc_app/src/connection/hints.dart';
import 'package:pirc_app/src/connection/pairing.dart';
import 'package:pirc_app/src/connection/storage.dart';
import 'package:pirc_app/src/preferences.dart';
import 'package:pirc_client/pirc_client.dart';
import 'package:pirc_ui/pirc_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/harness.dart';

const _link = 'pirc://pair?url=https%3A%2F%2Fgateway.test&token=new-token';

Future<void> _pairWith(WidgetTester tester, String link) async {
  await tester.enterText(find.byKey(const Key('pairing-link')), link);
  await tester.tap(find.text('Pair'));
  await tester.pumpAndSettle();
}

void main() {
  group('pairing links', () {
    test('a v1 link gives the origin and the token', () {
      final link = PairingLink.parse(_link)!;
      expect(link.gateway, Uri.parse('https://gateway.test/'));
      expect(link.token, 'new-token');
    });

    test('anything else is refused', () {
      for (final text in [
        '',
        'https://gateway.test',
        'pirc://pair?url=https%3A%2F%2Fgateway.test',
        'pirc://pair?token=t',
        'pirc://other?url=https%3A%2F%2Fgateway.test&token=t',
        'pirc://pair?url=ftp%3A%2F%2Fgateway.test&token=t',
        'pirc://pair?url=https%3A%2F%2Fgateway.test%2Fapi&token=t',
        'pirc://pair?url=https%3A%2F%2Fu%3Ap%40gateway.test&token=t',
      ]) {
        expect(PairingLink.parse(text), isNull, reason: text);
      }
    });
  });

  testWidgets('an unpaired device opens the pairing page', (tester) async {
    await pumpApp(tester, gateway: FakeGateway(), saved: Saved.unpaired());
    expect(find.text('Pair this device'), findsOneWidget);
  });

  testWidgets('a valid link is checked, then saved, then connects', (
    tester,
  ) async {
    final gateway = FakeGateway();
    final saved = Saved.unpaired();
    final container = await pumpApp(tester, gateway: gateway, saved: saved);
    await _pairWith(tester, _link);
    expect(saved.secrets.values[deviceTokenKey], 'new-token');
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(PrefKeys.gatewayUrl), 'https://gateway.test/');
    expect(container.read(connectionProvider).phase, ConnectionPhase.online);
    expect(find.text('Pair this device'), findsNothing);
    // The token was checked with connect() before it was saved.
    expect(gateway.configs.first.baseUri, Uri.parse('https://gateway.test/'));
    expect(await gateway.tokens.first!.read(), 'new-token');
  });

  testWidgets('a wrong link says so and saves nothing', (tester) async {
    final saved = Saved.unpaired();
    final gateway = FakeGateway();
    await pumpApp(tester, gateway: gateway, saved: saved);
    await _pairWith(tester, 'https://gateway.test/pair');
    expect(find.text('This is not a pairing link.'), findsOneWidget);
    expect(saved.secrets.values, isEmpty);
    expect(gateway.requests, isEmpty);
  });

  testWidgets('a refused token (401) is not saved', (tester) async {
    final saved = Saved.unpaired();
    await pumpApp(
      tester,
      gateway: _Refusing(401, 'unauthenticated'),
      saved: saved,
    );
    await _pairWith(tester, _link);
    expect(
      find.text('The Gateway did not accept this link. Create a new one.'),
      findsOneWidget,
    );
    expect(saved.secrets.values, isEmpty);
  });

  testWidgets('a Gateway that refuses this build (426) says to update', (
    tester,
  ) async {
    final saved = Saved.unpaired();
    await pumpApp(
      tester,
      gateway: _Refusing(426, 'client_upgrade_required'),
      saved: saved,
    );
    await _pairWith(tester, _link);
    expect(
      find.text('This app is too old for the Gateway. Update the app.'),
      findsOneWidget,
    );
    expect(saved.secrets.values, isEmpty);
  });

  testWidgets('close code 4401 on the hint socket removes the token', (
    tester,
  ) async {
    final gateway = FakeGateway();
    final saved = Saved();
    final container = await pumpApp(tester, gateway: gateway, saved: saved);
    expect(container.read(connectionProvider).phase, ConnectionPhase.online);
    gateway.socket('/api/hints')!.serverClose(4401);
    await tester.pumpAndSettle();
    expect(saved.secrets.values.containsKey(deviceTokenKey), isFalse);
    expect(container.read(connectionProvider).phase, ConnectionPhase.unpaired);
    expect(find.text('Pair this device'), findsOneWidget);
  });

  testWidgets('a 401 on an ordinary read removes the token and pairs again', (
    tester,
  ) async {
    final gateway = FakeGateway();
    gateway.json['GET /api/sessions'] = (_) => apiError(401, 'unauthenticated');
    final saved = Saved();
    final container = await pumpApp(tester, gateway: gateway, saved: saved);
    await tester.pumpAndSettle();
    expect(gateway.sent('GET', '/api/sessions'), isNotEmpty);
    expect(saved.secrets.values.containsKey(deviceTokenKey), isFalse);
    expect(container.read(connectionProvider).phase, ConnectionPhase.unpaired);
    expect(find.text('Pair this device'), findsOneWidget);
  });

  testWidgets('a 426 on an ordinary read shows the update page', (
    tester,
  ) async {
    final gateway = FakeGateway();
    gateway.json['GET /api/sessions'] = (_) =>
        apiError(426, 'client_upgrade_required');
    final saved = Saved();
    final container = await pumpApp(tester, gateway: gateway, saved: saved);
    await tester.pumpAndSettle();
    expect(
      container.read(connectionProvider).phase,
      ConnectionPhase.upgradeRequired,
    );
    expect(find.text('Update the app'), findsOneWidget);
    // The token stays: only the build is too old.
    expect(saved.secrets.values.containsKey(deviceTokenKey), isTrue);
  });

  testWidgets('a 426 at start shows the blocking update page', (tester) async {
    await pumpApp(tester, gateway: _Refusing(426, 'client_upgrade_required'));
    expect(find.text('Update the app'), findsOneWidget);
  });

  testWidgets('the Web build has no pairing page and no token', (tester) async {
    final gateway = FakeGateway();
    final container = await pumpApp(
      tester,
      gateway: gateway,
      saved: Saved.unpaired(),
      web: true,
    );
    expect(container.read(connectionProvider).phase, ConnectionPhase.online);
    expect(gateway.tokens.single, isNull);
    expect(find.text('Pair this device'), findsNothing);
  });

  testWidgets('an unreachable Gateway shows the offline bar and retries', (
    tester,
  ) async {
    final gateway = FakeGateway()..sendError = const TransportException('down');
    final container = await pumpApp(
      tester,
      gateway: gateway,
      location: '/work',
      settle: false,
    );
    await tester.pump();
    await tester.pump();
    expect(container.read(connectionProvider).phase, ConnectionPhase.offline);
    expect(
      find.text('Offline. What you see may be out of date.'),
      findsOneWidget,
    );
    gateway.sendError = null;
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();
    expect(container.read(connectionProvider).phase, ConnectionPhase.online);
    expect(
      find.text('Offline. What you see may be out of date.'),
      findsNothing,
    );
  });

  testWidgets('the hint socket reconnecting shows the bar; hints bump lists', (
    tester,
  ) async {
    final gateway = FakeGateway();
    final container = await pumpApp(tester, gateway: gateway);
    final hints = gateway.socket('/api/hints')!;
    expect(hints.target.queryParameters.keys.toSet(), appHintKinds);
    expect(
      appHintKinds,
      containsAll([
        'threads',
        'activity',
        'budgetRequests',
        'notifications',
        'causalRoots',
      ]),
    );
    final before = container.read(hintRevisionsProvider);
    expect(before['sessions_changed'], 1, reason: 'the open reads everything');
    hints.push({'type': 'sessions_changed'});
    await tester.pump();
    expect(container.read(hintRevisionsProvider)['sessions_changed'], 2);
    expect(container.read(hintRevisionsProvider)['pots_changed'], 1);
    hints.push({'type': 'threads_changed'});
    await tester.pump();
    expect(container.read(hintRevisionsProvider)['threads_changed'], 2);
    hints.serverClose(1006);
    await tester.pump();
    // The bar, and the Chat tab's title line.
    expect(
      find.descendant(
        of: find.byType(ConnectionBanner),
        matching: find.text('Reconnecting…'),
      ),
      findsOneWidget,
    );
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();
    expect(find.text('Reconnecting…'), findsNothing);
    expect(container.read(hintRevisionsProvider)['pots_changed'], 2);
  });

  testWidgets(
    'language, appearance, text size and start tab survive a restart',
    (tester) async {
      final gateway = FakeGateway();
      final container = await pumpApp(tester, gateway: gateway);
      container.read(languageProvider.notifier).select('zh-TW');
      container.read(themeModeProvider.notifier).select(ThemeMode.dark);
      container.read(textScaleProvider.notifier).select(1.15);
      container.read(startTabProvider.notifier).select('/calendar');
      final prefs = await SharedPreferences.getInstance();
      final values = {for (final key in prefs.getKeys()) key: prefs.get(key)!};
      await tester.pumpWidget(const SizedBox());
      final again = await pumpApp(
        tester,
        gateway: gateway,
        saved: Saved(prefs: values),
      );
      expect(again.read(languageProvider), 'zh-TW');
      expect(again.read(themeModeProvider), ThemeMode.dark);
      expect(again.read(textScaleProvider), 1.15);
      expect(
        find.byType(CalendarScreen),
        findsOneWidget,
        reason: 'opens on Calendar',
      );
      expect(find.text('月'), findsOneWidget, reason: 'in Chinese');
    },
  );
}

/// Refuses every request except the hint socket.
class _Refusing extends FakeGateway {
  _Refusing(this.status, this.code);
  final int status;
  final String code;

  @override
  Future<ApiResponse> answer(ApiRequest request) async {
    requests.add(request);
    return apiError(status, code);
  }
}
