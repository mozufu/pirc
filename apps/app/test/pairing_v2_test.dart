import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_app/src/connection/connection.dart';
import 'package:pirc_app/src/connection/pairing.dart';
import 'package:pirc_app/src/connection/pairing_v2.dart';
import 'package:pirc_app/src/connection/storage.dart';
import 'package:pirc_app/src/format.dart';
import 'package:pirc_app/src/platform/links.dart';
import 'package:pirc_app/src/platform/scanner.dart';
import 'package:pirc_client/pirc_client.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/harness.dart';

const _link = 'pirc://pair?url=https%3A%2F%2Fgateway.test&token=new-token';
final _start = DateTime(2026, 11, 27, 9);
const _poll = Duration(seconds: 1);

/// A Gateway with one pairing v2 request, `p1`.
class _Pairing {
  _Pairing() {
    gateway.json['POST /api/pairing/requests'] = (request) {
      created.add(request);
      return createReply ??
          reply(201, {
            'id': 'p1',
            'expiresAt': _start.millisecondsSinceEpoch + ttl.inMilliseconds,
            'serverNow': _start.millisecondsSinceEpoch,
            'approvePath': approvePath,
          });
    };
    gateway.routes.add((request) async {
      if (request.path != '/api/pairing/requests/p1/claim') return null;
      claims.add(request);
      final body = request.json! as Map<String, Object?>;
      final code = body['code'] as String?;
      if (code != null) await hold?.future;
      if (ended != null) return ended!;
      if (code != null && codeReply != null) return codeReply!;
      if (code == null || status == 'pending') {
        return reply(202, {
          'status': status,
          'expiresAt': _start.millisecondsSinceEpoch + 600000,
          'serverNow': now.millisecondsSinceEpoch,
        });
      }
      if (code != '123456') {
        wrong++;
        if (wrong >= 5) {
          return apiError(410, 'pairing_ended');
        }
        return reply(403, {
          'error': {
            'code': 'invalid_code',
            'message': 'The confirmation code is wrong',
            'details': {'attemptsLeft': 5 - wrong},
          },
        });
      }
      return reply(200, {
        'device': {
          'id': 'd1',
          'name': 'Android phone',
          'createdAt': now.millisecondsSinceEpoch,
          'expiresAt': now.millisecondsSinceEpoch + 30 * 86400000,
          'lastUsedAt': now.millisecondsSinceEpoch,
          'idleExpiresAt': now.millisecondsSinceEpoch + 7 * 86400000,
        },
        'token': token,
      });
    });
  }

  final gateway = FakeGateway();
  final links = FakeAppLinks();
  final saved = Saved.unpaired();
  final created = <ApiRequest>[];
  final claims = <ApiRequest>[];
  DateTime now = _start;
  String status = 'pending';
  ApiResponse? createReply;
  ApiResponse? ended;

  /// Answers a claim with a code, before checking it.
  ApiResponse? codeReply;

  /// Holds a claim with a code until completed.
  Completer<void>? hold;
  String approvePath = '/?pair=p1';
  Duration ttl = const Duration(minutes: 10);
  String token = 'pirc_dev_v2';
  int wrong = 0;

  Future<ProviderContainer> pump(
    WidgetTester tester, {
    Scanner? scanner,
    SecretStore? secrets,
  }) => pumpApp(
    tester,
    gateway: gateway,
    saved: saved,
    width: 420,
    links: links,
    scanner: scanner,
    platformSecrets: secrets != null,
    overrides: [
      if (secrets != null) secretStoreProvider.overrideWithValue(secrets),
      pairingV2EnabledProvider.overrideWithValue(true),
      pairingV2PollIntervalProvider.overrideWithValue(_poll),
      clockProvider.overrideWithValue(() => now),
    ],
  );

  /// Gives the address and asks for a request.
  Future<void> begin(WidgetTester tester) async {
    await tester.enterText(
      find.byKey(const Key('pairing-v2-address')),
      'https://gateway.test',
    );
    await tester.tap(find.byKey(const Key('pairing-v2-start')));
    await tester.pumpAndSettle();
  }

  Future<void> approve(WidgetTester tester) async {
    status = 'approved';
    await tester.pump(_poll);
    await tester.pumpAndSettle();
  }

  Future<void> sendCode(WidgetTester tester, String code) async {
    await tester.enterText(find.byKey(const Key('pairing-v2-code')), code);
    await tester.tap(find.byKey(const Key('pairing-v2-claim')));
    await tester.pumpAndSettle();
  }
}

String _status(WidgetTester tester) =>
    tester
        .widget<Text>(
          find.descendant(
            of: find.byKey(const Key('pairing-v2-status')),
            matching: find.byType(Text),
            matchRoot: true,
          ),
        )
        .data ??
    '';

void main() {
  group('pairing v2', () {
    appTest('is hidden unless PIRC_PAIRING_V2 is on', (tester) async {
      await pumpApp(tester, gateway: FakeGateway(), saved: Saved.unpaired());
      expect(find.text('Pair this device'), findsOneWidget);
      expect(find.text('Pair with a browser'), findsNothing);
      expect(find.byKey(const Key('pairing-v2-address')), findsNothing);
    });

    appTest('waits, is approved, and pairs with the code', (tester) async {
      final p = _Pairing();
      final container = await p.pump(tester);
      expect(find.text('Pair with a browser'), findsOneWidget);
      await p.begin(tester);

      // The request: the name, the platform and only the challenge.
      final create = p.created.single.json! as Map<String, Object?>;
      expect(create['deviceName'], 'Android phone');
      expect(create['platform'], 'android');
      final challenge = create['challenge']! as String;
      expect(challenge, matches(RegExp(r'^[0-9a-f]{64}$')));
      expect(
        create.keys,
        unorderedEquals(['deviceName', 'platform', 'challenge']),
      );
      // These routes get no Authorization header: no token store has one.
      final transport = p.gateway.configs.indexWhere(
        (c) => c.baseUri == Uri.parse('https://gateway.test/'),
      );
      expect(await p.gateway.tokens[transport]!.read(), isNull);

      expect(find.text('This device: Android phone'), findsOneWidget);
      expect(find.text('Open in a browser to approve'), findsOneWidget);
      expect(p.links.opened, [Uri.parse('https://gateway.test/?pair=p1')]);
      expect(find.text('https://gateway.test/?pair=p1'), findsOneWidget);
      expect(_status(tester), 'Waiting for the approval in the browser…');

      // Still pending on the next read.
      await tester.pump(_poll);
      await tester.pumpAndSettle();
      expect(_status(tester), 'Waiting for the approval in the browser…');
      await p.approve(tester);
      expect(
        _status(tester),
        'Approved. Type the 6-digit code that the browser shows.',
      );

      await p.sendCode(tester, '123456');
      final claim = p.claims.last.json! as Map<String, Object?>;
      expect(claim['code'], '123456');
      // The verifier is sent only in the claim, and matches the challenge.
      final verifier = claim['verifier']! as String;
      expect(sha256.convert(utf8.encode(verifier)).toString(), challenge);
      expect(jsonEncode(p.created.single.json), isNot(contains(verifier)));

      expect(p.saved.secrets.values[deviceTokenKey], 'pirc_dev_v2');
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(PrefKeys.gatewayUrl), 'https://gateway.test/');
      expect(find.text('Pair this device'), findsNothing);

      // Pairing again later starts from the address.
      await container.read(connectionProvider.notifier).unpair();
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('pairing-v2-start')), findsOneWidget);
    });

    appTest('a wrong code says how many tries are left; five end it', (
      tester,
    ) async {
      final p = _Pairing();
      await p.pump(tester);
      await p.begin(tester);
      await p.approve(tester);
      await p.sendCode(tester, '000000');
      expect(_status(tester), 'Wrong code. 4 tries left.');
      expect(p.saved.secrets.values, isEmpty);
      for (var i = 0; i < 3; i++) {
        await p.sendCode(tester, '000000');
      }
      expect(_status(tester), 'Wrong code. 1 try left.');
      await p.sendCode(tester, '000000');
      expect(
        _status(tester),
        'Too many wrong codes ended this request. Start again to make a new one.',
      );
      expect(find.byKey(const Key('pairing-v2-code')), findsNothing);
      expect(p.saved.secrets.values, isEmpty);

      await tester.tap(find.byKey(const Key('pairing-v2-restart')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('pairing-v2-address')), findsOneWidget);
      // The address was kept.
      expect(find.text('https://gateway.test'), findsOneWidget);
    });

    appTest('a request denied in the browser says so', (tester) async {
      final p = _Pairing();
      await p.pump(tester);
      await p.begin(tester);
      p.ended = apiError(410, 'pairing_ended');
      await tester.pump(_poll);
      await tester.pumpAndSettle();
      expect(
        _status(tester),
        'The request was denied in the browser. Start again to make a new one.',
      );
      expect(find.byKey(const Key('pairing-v2-code')), findsNothing);
      // No more reads after it ended.
      final reads = p.claims.length;
      await tester.pump(_poll * 3);
      expect(p.claims.length, reads);
      await tester.tap(find.byKey(const Key('pairing-v2-restart')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('pairing-v2-start')), findsOneWidget);
    });

    appTest('a request that was not approved in time expires', (tester) async {
      final p = _Pairing();
      await p.pump(tester);
      await p.begin(tester);
      expect(find.textContaining('The request ends at'), findsOneWidget);
      p.now = _start.add(const Duration(minutes: 10));
      await tester.pump(const Duration(minutes: 10));
      await tester.pumpAndSettle();
      expect(
        _status(tester),
        'The request expired. Start again to make a new one.',
      );
      expect(find.byKey(const Key('pairing-v2-restart')), findsOneWidget);
    });

    appTest('a request the Gateway forgot (404) has expired', (tester) async {
      final p = _Pairing();
      await p.pump(tester);
      await p.begin(tester);
      p.ended = apiError(404, 'not_found');
      await tester.pump(_poll);
      await tester.pumpAndSettle();
      expect(
        _status(tester),
        'The request expired. Start again to make a new one.',
      );
    });

    appTest('a full Gateway (429) and a wrong address say so', (tester) async {
      final p = _Pairing()..createReply = apiError(429, 'too_many_requests');
      await p.pump(tester);
      await tester.enterText(
        find.byKey(const Key('pairing-v2-address')),
        'gateway.test/api',
      );
      await tester.tap(find.byKey(const Key('pairing-v2-start')));
      await tester.pumpAndSettle();
      expect(
        find.text(
          'This is not a Gateway address, such as https://pirc.example.',
        ),
        findsOneWidget,
      );
      expect(p.created, isEmpty);
      await p.begin(tester);
      expect(
        _status(tester),
        'Too many pairing requests are open on the Gateway. Try again in a few minutes.',
      );
    });

    appTest('a browser that cannot open leaves the address to open', (
      tester,
    ) async {
      final p = _Pairing()..links.browserFails = true;
      await p.pump(tester);
      await p.begin(tester);
      expect(
        find.text(
          'The browser could not be opened. Open this address yourself:',
        ),
        findsOneWidget,
      );
      expect(find.text('https://gateway.test/?pair=p1'), findsOneWidget);
    });
  });

  group('pairing v2 edges', () {
    appTest('a full account (409) keeps the request open', (tester) async {
      final p = _Pairing()
        ..codeReply = apiError(409, 'conflict', 'Too many devices');
      await p.pump(tester);
      await p.begin(tester);
      await p.approve(tester);
      await p.sendCode(tester, '123456');
      expect(
        find.text(
          'This account already has 10 paired phones. Remove one in a browser, then send the code again.',
        ),
        findsOneWidget,
      );
      expect(find.byKey(const Key('pairing-v2-code')), findsOneWidget);
      // After a phone is removed, the same code pairs.
      p.codeReply = null;
      await p.sendCode(tester, '123456');
      expect(p.saved.secrets.values[deviceTokenKey], 'pirc_dev_v2');
    });

    appTest('a 409 after the request ended means it expired', (tester) async {
      final p = _Pairing()
        ..codeReply = apiError(409, 'conflict', 'Too many devices');
      await p.pump(tester);
      await p.begin(tester);
      await p.approve(tester);
      p.now = _start.add(const Duration(minutes: 11));
      await p.sendCode(tester, '123456');
      expect(
        _status(tester),
        'The request expired. Start again to make a new one.',
      );
    });

    appTest('a 410 after the request ended means it expired', (tester) async {
      final p = _Pairing();
      await p.pump(tester);
      await p.begin(tester);
      await p.approve(tester);
      p.now = _start.add(const Duration(minutes: 11));
      p.ended = apiError(410, 'pairing_ended');
      await p.sendCode(tester, '123456');
      expect(
        _status(tester),
        'The request expired. Start again to make a new one.',
      );
    });

    appTest('the end time does not throw away a claim on its way', (
      tester,
    ) async {
      // A short request, so its end comes before the claim's time limit.
      final p = _Pairing()
        ..hold = Completer<void>()
        ..ttl = const Duration(seconds: 20);
      await p.pump(tester);
      await p.begin(tester);
      await p.approve(tester);
      await tester.enterText(
        find.byKey(const Key('pairing-v2-code')),
        '123456',
      );
      await tester.tap(find.byKey(const Key('pairing-v2-claim')));
      await tester.pump();
      // The request's end comes while the claim waits for its answer.
      p.now = _start.add(const Duration(seconds: 20));
      await tester.pump(const Duration(seconds: 20));
      expect(_status(tester), 'Checking…');
      p.hold!.complete();
      await tester.pumpAndSettle();
      expect(p.saved.secrets.values[deviceTokenKey], 'pirc_dev_v2');
    });

    appTest('a claim answered after the end without a token expires', (
      tester,
    ) async {
      final p = _Pairing()
        ..hold = Completer<void>()
        ..ttl = const Duration(seconds: 20);
      await p.pump(tester);
      await p.begin(tester);
      await p.approve(tester);
      await tester.enterText(
        find.byKey(const Key('pairing-v2-code')),
        '000000',
      );
      await tester.tap(find.byKey(const Key('pairing-v2-claim')));
      await tester.pump();
      p.now = _start.add(const Duration(seconds: 20));
      await tester.pump(const Duration(seconds: 20));
      expect(_status(tester), 'Checking…');
      p.hold!.complete();
      await tester.pumpAndSettle();
      expect(
        _status(tester),
        'The request expired. Start again to make a new one.',
      );
    });

    appTest('a failed save ends in a state that can start again', (
      tester,
    ) async {
      final p = _Pairing();
      final secrets = _FailingSecrets();
      await p.pump(tester, secrets: secrets);
      await p.begin(tester);
      await p.approve(tester);
      await p.sendCode(tester, '123456');
      expect(_status(tester), 'Pairing failed. Start again.');
      await tester.tap(find.byKey(const Key('pairing-v2-restart')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('pairing-v2-start')), findsOneWidget);
    });

    appTest('a reply without a token is refused', (tester) async {
      final p = _Pairing()..token = '';
      await p.pump(tester);
      await p.begin(tester);
      await p.approve(tester);
      await p.sendCode(tester, '123456');
      expect(_status(tester), 'Pairing failed. Start again.');
      expect(p.saved.secrets.values, isEmpty);
    });

    for (final path in [
      '//evil.test/?pair=p1',
      'https://evil.test/?pair=p1',
      '?pair=p1',
      '/\\evil.test/',
    ]) {
      appTest('an approval path of another site ($path) is not opened', (
        tester,
      ) async {
        final p = _Pairing()..approvePath = path;
        await p.pump(tester);
        await p.begin(tester);
        expect(_status(tester), 'Pairing failed. Start again.');
        expect(p.links.opened, isEmpty);
        expect(find.textContaining('evil.test'), findsNothing);
      });
    }

    test('approval addresses stay on the Gateway', () {
      final gateway = Uri.parse('https://gateway.test/');
      expect(
        approveAddressFor(gateway, '/?pair=p1'),
        Uri.parse('https://gateway.test/?pair=p1'),
      );
      expect(approveAddressFor(gateway, '//evil.test/'), isNull);
      expect(approveAddressFor(gateway, 'https://gateway.test/'), isNull);
      expect(approveAddressFor(gateway, 'pair'), isNull);
    });
  });

  group('scanner', () {
    appTest('a scanned v1 link waits for Pair, as an opened one', (
      tester,
    ) async {
      final gateway = FakeGateway();
      final saved = Saved.unpaired();
      final scanner = FakeScanner([_link]);
      await pumpApp(tester, gateway: gateway, saved: saved, scanner: scanner);
      await tester.tap(find.byKey(const Key('pairing-scan')));
      await tester.pumpAndSettle();
      expect(scanner.scans, 1);
      // It fills the field and shows where it pairs; nothing is sent yet.
      expect(find.text(_link), findsOneWidget);
      expect(
        find.text(
          'A pairing link for gateway.test was scanned. Tap Pair to use it.',
        ),
        findsOneWidget,
      );
      expect(gateway.requests, isEmpty);
      expect(saved.secrets.values, isEmpty);
      await tester.tap(find.byKey(const Key('pairing-submit')));
      await tester.pumpAndSettle();
      expect(saved.secrets.values[deviceTokenKey], 'new-token');
      expect(find.text('Pair this device'), findsNothing);
    });

    appTest('a scanned address fills the pairing v2 address', (tester) async {
      final p = _Pairing();
      await p.pump(tester, scanner: FakeScanner(['https://other.test']));
      await tester.tap(find.byKey(const Key('pairing-scan')));
      await tester.pumpAndSettle();
      expect(find.text('https://other.test'), findsOneWidget);
      expect(p.created, isEmpty);
      expect(p.saved.secrets.values, isEmpty);
    });

    appTest('other codes, a closed scanner and failures', (tester) async {
      final gateway = FakeGateway();
      final saved = Saved.unpaired();
      final scanner = FakeScanner([
        'hello',
        // Without pairing v2 an address is not a pairing code.
        'https://gateway.test',
        null,
        const ScanFailure('SCAN_UNSUPPORTED'),
        const ScanFailure('SCAN_DOWNLOADING'),
        const ScanFailure('SCAN'),
      ]);
      await pumpApp(tester, gateway: gateway, saved: saved, scanner: scanner);
      Future<void> scan() async {
        await tester.tap(find.byKey(const Key('pairing-scan')));
        await tester.pumpAndSettle();
      }

      await scan();
      expect(find.text('This QR code is not a pairing link.'), findsOneWidget);
      await scan();
      expect(find.text('This QR code is not a pairing link.'), findsOneWidget);
      await scan();
      expect(find.text('This QR code is not a pairing link.'), findsNothing);
      await scan();
      expect(
        find.text('This device cannot scan QR codes. Paste the link instead.'),
        findsOneWidget,
      );
      await scan();
      expect(
        find.text(
          'The scanner is still being installed. Try again in a moment.',
        ),
        findsOneWidget,
      );
      await scan();
      expect(
        find.text(
          'The scanner could not be opened. Try again, or paste the link.',
        ),
        findsOneWidget,
      );
      expect(gateway.requests, isEmpty);
      expect(saved.secrets.values, isEmpty);
    });

    appTest('there is no scan button without the scanner', (tester) async {
      await pumpApp(tester, gateway: FakeGateway(), saved: Saved.unpaired());
      expect(find.byKey(const Key('pairing-scan')), findsNothing);
    });
  });

  group('pirc://pair links', () {
    appTest('the link that opened the app fills the page; Pair uses it', (
      tester,
    ) async {
      final gateway = FakeGateway();
      final saved = Saved.unpaired();
      await pumpApp(
        tester,
        gateway: gateway,
        saved: saved,
        links: FakeAppLinks(initial: _link),
      );
      expect(find.text(_link), findsOneWidget);
      expect(
        find.text(
          'A pairing link for gateway.test was opened. Tap Pair to use it.',
        ),
        findsOneWidget,
      );
      // Nothing is sent before the user taps Pair.
      expect(gateway.requests, isEmpty);
      expect(saved.secrets.values, isEmpty);
      await tester.tap(find.byKey(const Key('pairing-submit')));
      await tester.pumpAndSettle();
      expect(saved.secrets.values[deviceTokenKey], 'new-token');
    });

    appTest('a link while the app runs fills the page', (tester) async {
      final links = FakeAppLinks();
      final container = await pumpApp(
        tester,
        gateway: FakeGateway(),
        saved: Saved.unpaired(),
        links: links,
      );
      links.push(_link);
      await tester.pumpAndSettle();
      expect(find.text(_link), findsOneWidget);
      expect(container.read(pairLinkInboxProvider), isNull);
    });

    appTest('a paired app ignores a link', (tester) async {
      final links = FakeAppLinks();
      final saved = Saved();
      final container = await pumpApp(
        tester,
        gateway: FakeGateway(),
        saved: saved,
        links: links,
      );
      expect(container.read(connectionProvider).phase, ConnectionPhase.online);
      links.push(_link);
      await tester.pumpAndSettle();
      expect(container.read(pairLinkInboxProvider), isNull);
      expect(find.text('Pair this device'), findsNothing);
      expect(saved.secrets.values[deviceTokenKey], 'device-token');
    });
  });
}

/// A secret store whose writes fail, as a broken Keystore does.
class _FailingSecrets implements SecretStore {
  @override
  Future<String?> read(String key) async => null;

  @override
  Future<void> write(String key, String value) async =>
      throw PlatformException(code: 'CREDENTIALS');

  @override
  Future<void> delete(String key) async {}
}
