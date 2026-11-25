import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_app/src/connection/storage.dart';
import 'package:pirc_app/src/router.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/harness.dart';
import 'support/session_fixture.dart';

Map<String, Object?> _device(String name) => {
  'id': 'd1',
  'name': name,
  'createdAt': 1000,
  'expiresAt': 2000,
  'lastUsedAt': 1500,
};

String _field(WidgetTester tester) => tester
    .widget<TextField>(find.byKey(const Key('this-device-name')))
    .controller!
    .text;

void main() {
  appTest('a paired app reads its device and renames it', (tester) async {
    var name = 'Pixel 9';
    final gateway = FakeGateway();
    gateway.json['GET /api/device'] = (_) => {'device': _device(name)};
    gateway.json['PATCH /api/device'] = (request) {
      name = (request.json! as Map)['name'] as String;
      return {'device': _device(name)};
    };
    await pumpApp(tester, gateway: gateway, location: '/settings/device');
    expect(find.text('This device'), findsOneWidget);
    expect(_field(tester), 'Pixel 9');
    await tester.enterText(
      find.byKey(const Key('this-device-name')),
      '  Studio Pixel  ',
    );
    await tester.tap(find.byKey(const Key('this-device-save')));
    await tester.pumpAndSettle();
    expect(gateway.sent('PATCH', '/api/device').single.json, {
      'name': 'Studio Pixel',
    });
    expect(_field(tester), 'Studio Pixel');
    expect(find.text('Device name saved.'), findsOneWidget);
  });

  appTest('a paired app refuses an empty name', (tester) async {
    final gateway = FakeGateway();
    gateway.json['GET /api/device'] = (_) => {'device': _device('Pixel 9')};
    await pumpApp(tester, gateway: gateway, location: '/settings/device');
    await tester.enterText(find.byKey(const Key('this-device-name')), '   ');
    await tester.tap(find.byKey(const Key('this-device-save')));
    await tester.pumpAndSettle();
    expect(gateway.sent('PATCH', '/api/device'), isEmpty);
    expect(find.text('A name must be 1 to 60 characters.'), findsOneWidget);
  });

  appTest('the Web build stores a name, renames its client, and sends it with '
      'the next acquire', (tester) async {
    final session = FixtureSession('joined-mid-stream.json');
    final gateway = session.install();
    gateway.json['PUT /api/clients/web-1'] = (request) => {
      'client': {
        'clientId': 'web-1',
        'name': (request.json! as Map)['name'],
        'kind': 'browser',
        'lastSeenAt': 1700,
      },
    };
    final container = await pumpApp(
      tester,
      gateway: gateway,
      web: true,
      saved: Saved(
        prefs: {
          PrefKeys.gatewayUrl: 'https://gateway.test/',
          PrefKeys.clientId: 'web-1',
        },
      ),
      location: '/settings/device',
    );
    await tester.enterText(
      find.byKey(const Key('this-device-name')),
      ' Office iMac ',
    );
    await tester.tap(find.byKey(const Key('this-device-save')));
    await tester.pumpAndSettle();
    expect(gateway.sent('PUT', '/api/clients/web-1').single.json, {
      'name': 'Office iMac',
    });
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(PrefKeys.clientName), 'Office iMac');

    container.read(routerProvider).go('/work?open=s2');
    await tester.pumpAndSettle();
    final acquire = gateway.sent('POST', '/api/sessions/s2/control/acquire');
    expect(acquire, hasLength(1));
    expect((acquire.single.json! as Map)['clientName'], 'Office iMac');
  });

  appTest('the Web build accepts an empty name and sends no rename', (
    tester,
  ) async {
    final gateway = FakeGateway();
    await pumpApp(
      tester,
      gateway: gateway,
      web: true,
      saved: Saved(
        prefs: {
          PrefKeys.gatewayUrl: 'https://gateway.test/',
          PrefKeys.clientId: 'web-1',
          PrefKeys.clientName: 'Old name',
        },
      ),
      location: '/settings/device',
    );
    expect(_field(tester), 'Old name');
    await tester.enterText(find.byKey(const Key('this-device-name')), '  ');
    await tester.tap(find.byKey(const Key('this-device-save')));
    await tester.pumpAndSettle();
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(PrefKeys.clientName), isNull);
    expect(gateway.sent('PUT', '/api/clients/web-1'), isEmpty);
  });

  appTest('the Web build refuses a name over 60 characters', (tester) async {
    final gateway = FakeGateway();
    await pumpApp(
      tester,
      gateway: gateway,
      web: true,
      saved: Saved(
        prefs: {
          PrefKeys.gatewayUrl: 'https://gateway.test/',
          PrefKeys.clientId: 'web-1',
        },
      ),
      location: '/settings/device',
    );
    await tester.enterText(find.byKey(const Key('this-device-name')), 'x' * 61);
    await tester.tap(find.byKey(const Key('this-device-save')));
    await tester.pumpAndSettle();
    expect(gateway.sent('PUT', '/api/clients/web-1'), isEmpty);
    expect(find.text('A name must be 1 to 60 characters.'), findsOneWidget);
  });
}
