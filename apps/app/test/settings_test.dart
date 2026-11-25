import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_app/src/connection/storage.dart';
import 'package:pirc_app/src/preferences.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/harness.dart';

Future<void> _open(WidgetTester tester, String label) async {
  await tester.tap(find.text(label));
  await tester.pumpAndSettle();
}

void main() {
  appTest('the settings list shows each page; Devices is native only', (
    tester,
  ) async {
    await pumpApp(tester, gateway: FakeGateway(), location: '/settings');
    for (final label in [
      'This device',
      'Account and this device',
      'Model providers and default model',
      'Memory',
      'Modes',
      'Notifications',
      'Calendar and agent access',
      'Devices',
      'General',
      'About',
    ]) {
      expect(find.text(label), findsOneWidget, reason: label);
    }
    expect(find.text('ana'), findsOneWidget, reason: 'the account name');
  });

  appTest('the Web build has no Devices row', (tester) async {
    await pumpApp(
      tester,
      gateway: FakeGateway(),
      web: true,
      saved: Saved.unpaired(),
      location: '/settings',
    );
    expect(find.text('Devices'), findsNothing);
  });

  appTest('general: language, appearance, text size and start tab', (
    tester,
  ) async {
    final container = await pumpApp(
      tester,
      gateway: FakeGateway(),
      location: '/settings/general',
    );
    await _open(tester, 'Dark');
    await tester.scrollUntilVisible(find.text('Larger'), 200);
    await _open(tester, 'Larger');
    await tester.scrollUntilVisible(find.text('Calendar'), 200);
    await tester.ensureVisible(find.text('Calendar'));
    await tester.pumpAndSettle();
    await _open(tester, 'Calendar');
    expect(container.read(themeModeProvider), ThemeMode.dark);
    expect(container.read(textScaleProvider), 1.3);
    expect(container.read(startTabProvider), '/calendar');
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(PrefKeys.startTab), '/calendar');
  });

  appTest('general: the time zone is the device\'s or a fixed offset', (
    tester,
  ) async {
    final container = await pumpApp(
      tester,
      gateway: FakeGateway(),
      location: '/settings/general',
    );
    expect(container.read(timeZoneProvider), isNull);
    await tester.scrollUntilVisible(find.byKey(const Key('time-zone')), 200);
    expect(find.textContaining("This device's (UTC"), findsOneWidget);
    await _open(tester, 'Time zone');
    await tester.tap(find.byKey(const Key('time-zone')));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('UTC+05:30'),
      200,
      scrollable: find.byType(Scrollable).last,
    );
    await _open(tester, 'UTC+05:30');
    expect(container.read(timeZoneProvider), '+05:30');
    expect(find.text('UTC+05:30'), findsOneWidget);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(PrefKeys.timeZone), '+05:30');
  });

  appTest('account: unpair asks, then removes the token and opens pairing', (
    tester,
  ) async {
    final saved = Saved(
      prefs: {
        PrefKeys.gatewayUrl: 'https://gateway.test/',
        '${PrefKeys.draftPrefix}s1': 'a draft',
      },
    );
    await pumpApp(
      tester,
      gateway: FakeGateway(),
      saved: saved,
      location: '/settings/account',
    );
    expect(find.text('https://gateway.test/'), findsOneWidget);
    await _open(tester, 'Unpair this device…');
    expect(find.text('Unpair this device?'), findsOneWidget);
    await _open(tester, 'Unpair');
    expect(saved.secrets.values.containsKey(deviceTokenKey), isFalse);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('${PrefKeys.draftPrefix}s1'), isNull);
    expect(find.text('Pair this device'), findsOneWidget);
  });

  appTest('about: app and Gateway versions, and licences', (tester) async {
    await pumpApp(tester, gateway: FakeGateway(), location: '/settings/about');
    expect(find.text('0.1.0'), findsOneWidget);
    expect(find.text('2.0.0-test'), findsOneWidget);
    await _open(tester, 'Licences');
    expect(find.byType(LicensePage), findsOneWidget);
  });
}
