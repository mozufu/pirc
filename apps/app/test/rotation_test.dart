import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart';
import 'package:pirc_app/src/connection/connection.dart';
import 'package:pirc_app/src/connection/rotation.dart';
import 'package:pirc_app/src/connection/storage.dart';
import 'package:pirc_app/src/format.dart';
import 'package:pirc_client/pirc_client.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/harness.dart';

final _now = DateTime(2026, 11, 27, 9);
const _day = Duration(days: 1);

Map<String, Object?> _device({
  required Duration max,
  Duration idle = const Duration(days: 7),
}) => {
  'id': 'd1',
  'name': 'Pixel 9',
  'createdAt': _now.subtract(const Duration(days: 10)).millisecondsSinceEpoch,
  'lastUsedAt': _now.millisecondsSinceEpoch,
  'expiresAt': _now.add(max).millisecondsSinceEpoch,
  'idleExpiresAt': _now.add(idle).millisecondsSinceEpoch,
};

/// The secret store, whose writes can be held to see what is sent meanwhile.
class _Secrets implements SecretStore {
  final inner = MemorySecretStore({deviceTokenKey: 'device-token'});
  Completer<void>? hold;

  @override
  Future<String?> read(String key) => inner.read(key);

  @override
  Future<void> write(String key, String value) async {
    await hold?.future;
    await inner.write(key, value);
  }

  @override
  Future<void> delete(String key) => inner.delete(key);
}

class _Rotation {
  _Rotation({required Duration max, Duration idle = const Duration(days: 7)}) {
    device = _device(max: max, idle: idle);
    gateway.json['GET /api/device'] = (_) => {'device': device};
    gateway.routes.add((request) async {
      if (request.method != 'POST' || request.path != '/api/device/rotate') {
        return null;
      }
      rotations++;
      // The token the transport holds when the request goes out.
      sentWith.add(await gateway.tokens.last!.read());
      final answer = await rotate(rotations);
      if (answer.ok) device = _device(max: const Duration(days: 30));
      return answer;
    });
  }

  final gateway = FakeGateway();
  final secrets = _Secrets();
  late Map<String, Object?> device;
  int rotations = 0;
  DateTime now = _now;
  final sentWith = <String?>[];
  FutureOr<ApiResponse> Function(int call) rotate = (_) => reply(200, {
    'device': _device(max: const Duration(days: 30)),
    'token': 'pirc_dev_rotated',
  });

  Future<ProviderContainer> pump(
    WidgetTester tester, {
    String? location,
    double width = 1300,
    Map<String, Object>? prefs,
  }) => pumpApp(
    tester,
    gateway: gateway,
    location: location,
    width: width,
    saved: prefs == null ? null : Saved(prefs: prefs),
    platformSecrets: true,
    overrides: [
      secretStoreProvider.overrideWithValue(secrets),
      clockProvider.overrideWithValue(() => now),
      rotationRetryDelayProvider.overrideWithValue(const Duration(seconds: 1)),
    ],
  );

  Future<String?> sending() async => gateway.tokens.last!.read();
}

/// The app goes to the background and comes back, through each state.
void _background(WidgetTester tester) {
  for (final state in [
    AppLifecycleState.inactive,
    AppLifecycleState.hidden,
    AppLifecycleState.paused,
  ]) {
    tester.binding.handleAppLifecycleStateChanged(state);
  }
}

void _foreground(WidgetTester tester) {
  for (final state in [
    AppLifecycleState.hidden,
    AppLifecycleState.inactive,
    AppLifecycleState.resumed,
  ]) {
    tester.binding.handleAppLifecycleStateChanged(state);
  }
}

String _warning(DateTime ends) =>
    'Pairing ends on ${DateFormat.yMMMd('en').format(ends)}. '
    'Open pirc on this phone before then, or pair again.';

void main() {
  appTest('more than 23 days left: no rotation', (tester) async {
    final r = _Rotation(max: const Duration(days: 24));
    await r.pump(tester);
    expect(r.gateway.sent('GET', '/api/device'), hasLength(1));
    expect(r.rotations, 0);
  });

  appTest('less than 23 days left: rotates once and saves before use', (
    tester,
  ) async {
    final r = _Rotation(max: const Duration(days: 22));
    r.secrets.hold = Completer<void>();
    final container = await r.pump(tester);
    expect(r.rotations, 1);
    expect(r.sentWith.single, 'device-token');
    // The reply arrived, but the write has not finished: the new token is
    // not sent yet.
    expect(await r.sending(), 'device-token');
    expect(await r.secrets.inner.read(deviceTokenKey), 'device-token');
    // A foreground while it runs joins it.
    final again = container.read(deviceLifetimeProvider.notifier).check();
    r.secrets.hold!.complete();
    await tester.pumpAndSettle();
    await again;
    expect(r.rotations, 1);
    expect(await r.secrets.inner.read(deviceTokenKey), 'pirc_dev_rotated');
    expect(await r.sending(), 'pirc_dev_rotated');

    // Back in the foreground: the new window has 30 days, so it stays.
    _background(tester);
    _foreground(tester);
    await tester.pumpAndSettle();
    expect(r.gateway.sent('GET', '/api/device'), hasLength(2));
    expect(r.rotations, 1);
    expect(find.byKey(const Key('pairing-end-warning')), findsNothing);
  });

  appTest('sockets of the old token closing (4401) keep the new token', (
    tester,
  ) async {
    final r = _Rotation(max: const Duration(days: 22));
    final container = await r.pump(tester);
    expect(await r.secrets.inner.read(deviceTokenKey), 'pirc_dev_rotated');
    final old = r.gateway.socket('/api/hints')!;
    // The Gateway ends the old token once the new one is used.
    old.serverClose(4401);
    await tester.pumpAndSettle();
    expect(container.read(connectionProvider).phase, ConnectionPhase.online);
    expect(await r.secrets.inner.read(deviceTokenKey), 'pirc_dev_rotated');
    expect(r.gateway.socket('/api/hints'), isNot(same(old)));
    expect(await r.gateway.tokens.last!.read(), 'pirc_dev_rotated');
    expect(find.text('Pair this device'), findsNothing);

    // A refusal of the new token itself still ends the pairing.
    r.gateway.socket('/api/hints')!.serverClose(4401);
    await tester.pumpAndSettle();
    expect(container.read(connectionProvider).phase, ConnectionPhase.unpaired);
    expect(r.secrets.inner.values.containsKey(deviceTokenKey), isFalse);
  });

  appTest('a 401 for a request sent with the old token keeps the new one', (
    tester,
  ) async {
    final r = _Rotation(max: const Duration(days: 22));
    final container = await r.pump(tester);
    container
        .read(connectionProvider.notifier)
        .report(const PairingRequired('old token'));
    await tester.pumpAndSettle();
    expect(container.read(connectionProvider).phase, ConnectionPhase.online);
    expect(await r.secrets.inner.read(deviceTokenKey), 'pirc_dev_rotated');
  });

  appTest('coming to the foreground rotates when it is time', (tester) async {
    final r = _Rotation(max: const Duration(days: 24));
    await r.pump(tester);
    expect(r.rotations, 0);
    r.device = _device(max: const Duration(days: 20));
    _background(tester);
    _foreground(tester);
    await tester.pumpAndSettle();
    expect(r.rotations, 1);
    expect(await r.sending(), 'pirc_dev_rotated');
  });

  appTest('a lost reply is asked again with the old token', (tester) async {
    final r = _Rotation(max: const Duration(days: 22));
    r.rotate = (call) => call == 1
        ? throw const TransportException('connection reset')
        : reply(200, {
            'device': _device(max: const Duration(days: 30)),
            'token': 'pirc_dev_second',
          });
    await r.pump(tester);
    expect(r.rotations, 1);
    // The old token stays and is still sent.
    expect(await r.secrets.inner.read(deviceTokenKey), 'device-token');
    expect(await r.sending(), 'device-token');
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    expect(r.rotations, 2);
    expect(r.sentWith, ['device-token', 'device-token']);
    // The token of the last good reply is kept.
    expect(await r.secrets.inner.read(deviceTokenKey), 'pirc_dev_second');
    expect(await r.sending(), 'pirc_dev_second');
  });

  group('a rotation whose outcome is unknown', () {
    appTest('survives a failed retry and a restart, then saves the token', (
      tester,
    ) async {
      final r = _Rotation(max: const Duration(days: 22));
      r.rotate = (call) {
        // The Gateway rotated, so the record shows the new windows, but no
        // reply arrives: not the first time, not on the retry, not after
        // the restart.
        r.device = _device(max: const Duration(days: 30));
        if (call <= 3) throw const TransportException('connection reset');
        return reply(200, {
          'device': _device(max: const Duration(days: 30)),
          'token': 'pirc_dev_fourth',
        });
      };
      await r.pump(tester);
      expect(r.rotations, 1);
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();
      expect(r.rotations, 2);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getInt(PrefKeys.rotationUnknownSince), isNotNull);
      expect(await r.secrets.inner.read(deviceTokenKey), 'device-token');

      // The app stops and starts again; the record says 30 days, but the
      // outcome is unknown, so it asks again with the old token.
      final kept = {for (final key in prefs.getKeys()) key: prefs.get(key)!};
      await disposeApp(tester);
      await r.pump(tester, prefs: kept);
      await tester.pumpAndSettle();
      expect(r.rotations, 3);
      expect(r.sentWith.last, 'device-token');
      // A retry while it is still unknown, on the timer, now succeeds.
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();
      expect(r.rotations, 4);
      expect(r.sentWith.last, 'device-token');
      expect(await r.secrets.inner.read(deviceTokenKey), 'pirc_dev_fourth');
      expect(await r.sending(), 'pirc_dev_fourth');
      final after = await SharedPreferences.getInstance();
      expect(after.getInt(PrefKeys.rotationUnknownSince), isNull);
    });

    appTest('a 5xx reply is an unknown outcome and is asked again', (
      tester,
    ) async {
      final r = _Rotation(max: const Duration(days: 22));
      r.rotate = (call) {
        if (call == 1) {
          r.device = _device(max: const Duration(days: 30));
          return apiError(502, 'bad_gateway');
        }
        return reply(200, {
          'device': _device(max: const Duration(days: 30)),
          'token': 'pirc_dev_rotated',
        });
      };
      await r.pump(tester);
      expect(r.rotations, 1);
      expect(await r.secrets.inner.read(deviceTokenKey), 'device-token');
      // Coming back to the foreground asks again, whatever the record says.
      _background(tester);
      _foreground(tester);
      await tester.pumpAndSettle();
      expect(r.rotations, 2);
      expect(r.sentWith, ['device-token', 'device-token']);
      expect(await r.secrets.inner.read(deviceTokenKey), 'pirc_dev_rotated');
    });

    appTest('a restart while the first rotation has no reply asks again', (
      tester,
    ) async {
      final r = _Rotation(max: const Duration(days: 22));
      final pending = Completer<void>();
      r.rotate = (call) async {
        if (call == 1) {
          // The Gateway rotates; the process dies before the reply.
          r.device = _device(max: const Duration(days: 30));
          await pending.future;
        }
        return reply(200, {
          'device': _device(max: const Duration(days: 30)),
          'token': 'pirc_dev_second',
        });
      };
      await r.pump(tester);
      expect(r.rotations, 1);
      final prefs = await SharedPreferences.getInstance();
      // Kept before the request went out.
      expect(prefs.getInt(PrefKeys.rotationUnknownSince), isNotNull);
      final kept = {for (final key in prefs.getKeys()) key: prefs.get(key)!};
      await disposeApp(tester);

      await r.pump(tester, prefs: kept);
      await tester.pumpAndSettle();
      expect(r.rotations, 2);
      expect(r.sentWith, ['device-token', 'device-token']);
      expect(await r.secrets.inner.read(deviceTokenKey), 'pirc_dev_second');
      final after = await SharedPreferences.getInstance();
      expect(after.getInt(PrefKeys.rotationUnknownSince), isNull);
      // The first app's request ends; nothing listens to it any more.
      pending.complete();
      await tester.pumpAndSettle();
      expect(await r.secrets.inner.read(deviceTokenKey), 'pirc_dev_second');
    });

    appTest('a record that still needs rotation ends the unknown outcome', (
      tester,
    ) async {
      final r = _Rotation(max: const Duration(days: 22));
      r.rotate = (call) => call == 1
          // Never reached the Gateway: the record stays at 22 days.
          ? throw const TransportException('offline')
          : reply(200, {
              'device': _device(max: const Duration(days: 30)),
              'token': 'pirc_dev_rotated',
            });
      await r.pump(tester);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getInt(PrefKeys.rotationUnknownSince), isNotNull);
      _background(tester);
      _foreground(tester);
      await tester.pumpAndSettle();
      expect(r.rotations, 2);
      expect(await r.secrets.inner.read(deviceTokenKey), 'pirc_dev_rotated');
      expect(prefs.getInt(PrefKeys.rotationUnknownSince), isNull);
    });

    appTest('after the grace only a connect or a foreground asks again', (
      tester,
    ) async {
      final r = _Rotation(max: const Duration(days: 22));
      r.rotate = (_) {
        r.device = _device(max: const Duration(days: 30));
        return apiError(503, 'unavailable');
      };
      await r.pump(tester);
      expect(r.rotations, 1);
      // During the grace the timer asks again.
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();
      expect(r.rotations, 2);
      // Past it, no timer: the Gateway is not asked every 30 seconds.
      r.now = _now.add(rotationGrace);
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();
      final asked = r.rotations;
      await tester.pump(const Duration(minutes: 2));
      await tester.pumpAndSettle();
      expect(r.rotations, asked);
      // The outcome is still unknown, so the next foreground asks again
      // although the record shows 30 days.
      _background(tester);
      _foreground(tester);
      await tester.pumpAndSettle();
      expect(r.rotations, asked + 1);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getInt(PrefKeys.rotationUnknownSince), isNotNull);
    });

    appTest('a known refusal is not asked again', (tester) async {
      final r = _Rotation(max: const Duration(days: 22))
        ..rotate = (_) => apiError(403, 'forbidden');
      await r.pump(tester);
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
      expect(r.rotations, 1);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getInt(PrefKeys.rotationUnknownSince), isNull);
    });
  });

  group('the warning', () {
    appTest('shows in Settings and the drawer once rotation failed', (
      tester,
    ) async {
      final r = _Rotation(max: const Duration(days: 2))
        ..rotate = (_) => apiError(403, 'forbidden');
      await r.pump(tester, location: '/settings/device');
      expect(r.rotations, 1);
      expect(await r.secrets.inner.read(deviceTokenKey), 'device-token');
      expect(
        find.text(_warning(_now.add(const Duration(days: 2)))),
        findsOneWidget,
      );
    });

    appTest('shows in the drawer user row', (tester) async {
      final r = _Rotation(max: const Duration(days: 2))
        ..rotate = (_) => apiError(403, 'forbidden');
      await r.pump(tester, width: 375, location: '/work');
      await tester.tap(find.byTooltip('Open the menu'));
      await tester.pumpAndSettle();
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('drawer-me')),
          matching: find.text(_warning(_now.add(const Duration(days: 2)))),
        ),
        findsOneWidget,
      );
    });

    appTest('uses the earlier of the idle and the maximum window', (
      tester,
    ) async {
      final r = _Rotation(max: const Duration(days: 10), idle: _day)
        ..rotate = (_) => throw const TransportException('offline');
      await r.pump(tester, location: '/settings/device');
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();
      expect(r.rotations, 2);
      expect(find.text(_warning(_now.add(_day))), findsOneWidget);
    });

    appTest('stays hidden with more than 3 days left', (tester) async {
      final r = _Rotation(max: const Duration(days: 4))
        ..rotate = (_) => apiError(403, 'forbidden');
      await r.pump(tester, location: '/settings/device');
      expect(r.rotations, 1);
      expect(find.byKey(const Key('pairing-end-warning')), findsNothing);
    });
  });

  group('an expired token', () {
    appTest('goes to pairing and says the settings are kept', (tester) async {
      final gateway = FakeGateway();
      gateway.json['GET /api/sessions'] = (_) =>
          apiError(401, 'unauthenticated');
      final saved = Saved();
      final container = await pumpApp(tester, gateway: gateway, saved: saved);
      expect(
        container.read(connectionProvider).phase,
        ConnectionPhase.unpaired,
      );
      expect(
        find.text('Pairing expired; your settings are kept.'),
        findsOneWidget,
      );
      expect(saved.secrets.values.containsKey(deviceTokenKey), isFalse);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(PrefKeys.gatewayUrl), 'https://gateway.test/');
    });

    appTest('unpairing by hand does not say it expired', (tester) async {
      final container = await pumpApp(tester, gateway: FakeGateway());
      await container.read(connectionProvider.notifier).unpair();
      await tester.pumpAndSettle();
      expect(find.text('Pair this device'), findsOneWidget);
      expect(
        find.text('Pairing expired; your settings are kept.'),
        findsNothing,
      );
    });

    appTest('pairing again starts from Pair, not Paired', (tester) async {
      final container = await pumpApp(
        tester,
        gateway: FakeGateway(),
        saved: Saved.unpaired(),
      );
      await tester.enterText(
        find.byKey(const Key('pairing-link')),
        'pirc://pair?url=https%3A%2F%2Fgateway.test&token=new-token',
      );
      await tester.tap(find.text('Pair'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('pairing-submit')), findsNothing);
      await container.read(connectionProvider.notifier).unpair();
      await tester.pumpAndSettle();
      final submit = find.byKey(const Key('pairing-submit'));
      expect(
        find.descendant(of: submit, matching: find.text('Pair')),
        findsOneWidget,
      );
      expect(find.text('Paired'), findsNothing);
    });

    appTest('a first start has no such note', (tester) async {
      await pumpApp(tester, gateway: FakeGateway(), saved: Saved.unpaired());
      expect(
        find.text('Pairing expired; your settings are kept.'),
        findsNothing,
      );
    });
  });
}
