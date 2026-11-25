import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_app/src/connection/connection.dart';
import 'package:pirc_app/src/format.dart';
import 'package:pirc_app/src/settings/management_access.dart';

import 'support/harness.dart';

final _now = DateTime(2026, 11, 25, 11);
int _ms(Duration after) => _now.add(after).millisecondsSinceEpoch;

/// A Gateway that serves management requests the test decides.
class _Management {
  _Management() {
    gateway.json['POST /api/native-management/requests'] = (request) {
      created = request.json! as Map;
      return reply(201, {
        ..._request('pending', created!['capabilities'] as List),
        'verificationPath': '/?nativeManagement=req1',
      });
    };
    gateway.json['GET /api/native-management/requests/req1'] = (_) =>
        _request(status, created!['capabilities'] as List);
    gateway.json['POST /api/native-management/requests/req1/claim'] =
        (request) {
          claimedWith = (request.json! as Map)['verifier'] as String;
          return {
            'token': 'pirc_mgmt_secret',
            'expiresAt': _ms(const Duration(minutes: 15)),
            'serverNow': _ms(Duration.zero),
            'capabilities': created!['capabilities'],
          };
        };
    gateway.json['GET /api/devices'] = (_) => {
      'devices': [
        {
          'id': 'd1',
          'name': 'Old phone',
          'createdAt': 1,
          'lastUsedAt': _ms(const Duration(hours: -1)),
          'expiresAt': _ms(const Duration(days: 30)),
        },
      ],
    };
    gateway.json['DELETE /api/devices/d1'] = (_) => reply(204);
    gateway.json['POST /api/devices'] = (request) => reply(201, {
      'device': {
        'id': 'd2',
        'name': (request.json! as Map)['name'],
        'expiresAt': _ms(const Duration(days: 30)),
      },
      'token': 'pirc_dev_new',
    });
  }

  final gateway = FakeGateway();
  Map? created;
  String status = 'pending';
  String? claimedWith;

  Map<String, Object?> _request(String status, List capabilities) => {
    'id': 'req1',
    'status': status,
    'expiresAt': _ms(const Duration(minutes: 5)),
    'serverNow': _ms(Duration.zero),
    'deviceName': 'Pixel',
    'capabilities': capabilities,
    if (capabilities.contains('devices:pair'))
      'pairing': {'idleDays': 30, 'maxDays': 90},
  };
}

late ProviderContainer _container;

Future<_Management> _devices(WidgetTester tester) async {
  final m = _Management();
  _container = await pumpApp(
    tester,
    gateway: m.gateway,
    location: '/settings/devices',
    overrides: [
      clockProvider.overrideWithValue(() => _now),
      accessPollIntervalProvider.overrideWithValue(
        const Duration(milliseconds: 100),
      ),
    ],
  );
  return m;
}

Future<void> _approve(WidgetTester tester, _Management m) async {
  m.status = 'approved';
  await tester.pump(const Duration(milliseconds: 150));
  await tester.pumpAndSettle();
}

void main() {
  test('the challenge is the hex SHA-256 of a 43-character verifier', () {
    final verifier = ManagementAccess.newVerifier();
    expect(verifier, hasLength(43));
    expect(RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(verifier), isTrue);
    expect(
      ManagementAccess.challengeFor('abc'),
      'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
    );
  });

  appTest('the whole grant flow: request, browser address, claim, use', (
    tester,
  ) async {
    final m = await _devices(tester);
    // No grant: the devices list asks for access first.
    expect(find.text('Old phone'), findsNothing);
    await tester.tap(find.text('Ask for access').first);
    await tester.pumpAndSettle();
    expect(m.created!['capabilities'], ['devices:read', 'devices:revoke']);
    final challenge = m.created!['challenge'] as String;
    expect(
      find.text('https://gateway.test/?nativeManagement=req1'),
      findsOneWidget,
    );
    await _approve(tester, m);
    expect(ManagementAccess.challengeFor(m.claimedWith!), challenge);
    expect(find.text('Old phone'), findsOneWidget);
    // The grant rides only on management routes, from memory.
    final list = m.gateway.configs.last;
    expect(list.managementGrant!(), 'pirc_mgmt_secret');
  });

  appTest('a revoke needs devices:revoke and asks first', (tester) async {
    final m = await _devices(tester);
    await tester.tap(find.text('Ask for access').first);
    await tester.pumpAndSettle();
    await _approve(tester, m);
    await tester.tap(find.text('Remove'));
    await tester.pumpAndSettle();
    expect(find.text('Remove Old phone?'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Remove'));
    await tester.pumpAndSettle();
    expect(m.gateway.sent('DELETE', '/api/devices/d1'), hasLength(1));
  });

  appTest('pairing a device without devices:pair asks for it; with it, the '
      'link and QR code show once', (tester) async {
    final m = await _devices(tester);
    expect(find.text('Pair a new device'), findsNothing);
    await tester.tap(find.text('Ask for access').last);
    await tester.pumpAndSettle();
    expect(m.created!['capabilities'], ['devices:pair', 'devices:read']);
    await _approve(tester, m);
    await tester.tap(find.text('Pair a new device'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('device-name')), 'Tablet');
    await tester.tap(find.text('Pair'));
    await tester.pumpAndSettle();
    expect(find.text('Tablet is ready'), findsOneWidget);
    final link = tester
        .widget<SelectableText>(find.byKey(const Key('pair-link')))
        .data!;
    final parsed = Uri.parse(link);
    expect(parsed.queryParameters['token'], 'pirc_dev_new');
    expect(parsed.queryParameters['url'], 'https://gateway.test');
  });

  appTest('a denied request says so and grants nothing', (tester) async {
    final m = await _devices(tester);
    await tester.tap(find.text('Ask for access').first);
    await tester.pumpAndSettle();
    m.status = 'denied';
    await tester.pump(const Duration(milliseconds: 150));
    await tester.pumpAndSettle();
    expect(find.text('The request was denied.').evaluate(), isNotEmpty);
    expect(m.claimedWith, isNull);
  });

  appTest('the grant is dropped when it expires', (tester) async {
    final m = await _devices(tester);
    await tester.tap(find.text('Ask for access').first);
    await tester.pumpAndSettle();
    await _approve(tester, m);
    final config = m.gateway.configs.last;
    expect(config.managementGrant!(), isNotNull);
    await tester.pump(const Duration(minutes: 16));
    await tester.pumpAndSettle();
    expect(config.managementGrant!(), isNull);
    expect(find.text('Old phone'), findsNothing);
  });

  group('the approval screen (Web build)', () {
    for (final capabilities in [
      ['providers'],
      ['devices:read', 'devices:revoke'],
      ['devices:pair'],
    ]) {
      appTest('shows ${capabilities.join(' and ')} and approves', (
        tester,
      ) async {
        final m = _Management()..created = {'capabilities': capabilities};
        m.gateway.json['POST /api/native-management/requests/req1/approve'] =
            (_) => m._request('approved', capabilities);
        await pumpApp(
          tester,
          gateway: m.gateway,
          web: true,
          saved: Saved.unpaired(),
          location: '/?nativeManagement=req1',
        );
        expect(find.text('Pixel asks for access'), findsOneWidget);
        const words = {
          'providers': 'Change model providers and their credentials',
          'devices:read': 'See the list of paired devices',
          'devices:revoke': 'Remove paired devices',
          'devices:pair': 'Pair new devices that can use this Gateway',
        };
        for (final c in capabilities) {
          expect(find.text(words[c]!), findsOneWidget);
        }
        expect(
          find.text(
            'Each new device works for 30 days without use and at most 90 days.',
          ),
          capabilities.contains('devices:pair') ? findsOneWidget : findsNothing,
        );
        await tester.tap(find.text('Approve'));
        await tester.pumpAndSettle();
        expect(find.text('Approved. Go back to the app.'), findsOneWidget);
      });
    }

    appTest('deny', (tester) async {
      final m = _Management()
        ..created = {
          'capabilities': ['providers'],
        };
      m.gateway.json['POST /api/native-management/requests/req1/deny'] = (_) =>
          m._request('denied', const ['providers']);
      await pumpApp(
        tester,
        gateway: m.gateway,
        web: true,
        saved: Saved.unpaired(),
        location: '/?nativeManagement=req1',
      );
      await tester.tap(find.text('Deny'));
      await tester.pumpAndSettle();
      expect(find.text('Denied.'), findsOneWidget);
    });

    appTest('does not exist in the native builds', (tester) async {
      final m = _Management()
        ..created = {
          'capabilities': ['providers'],
        };
      await pumpApp(
        tester,
        gateway: m.gateway,
        location: '/?nativeManagement=req1',
      );
      expect(find.text('Pixel asks for access'), findsNothing);
      expect(m.gateway.requests.any((r) => r.path.contains('req1')), isFalse);
    });
  });

  appTest('unpairing drops the grant', (tester) async {
    final m = await _devices(tester);
    await tester.tap(find.text('Ask for access').first);
    await tester.pumpAndSettle();
    await _approve(tester, m);
    expect(_container.read(managementGrantProvider), 'pirc_mgmt_secret');
    await _container.read(connectionProvider.notifier).unpair();
    await tester.pumpAndSettle();
    expect(_container.read(managementGrantProvider), isNull);
    expect(_container.read(managementAccessProvider).phase, AccessPhase.none);
  });
}
