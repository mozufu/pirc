import 'package:pirc_client/pirc_client.dart';
import 'package:test/test.dart';

import 'support/fakes.dart';

void main() {
  final device = {
    'id': 'd1',
    'name': 'Pixel 9',
    'createdAt': 1000,
    'expiresAt': 9000,
    'lastUsedAt': 1500,
    'idleExpiresAt': 5000,
  };

  group('pairing v2', () {
    test('create sends the name, the platform and the challenge', () async {
      final transport = FakeTransport(
        onSend: (request) async => reply(201, {
          'id': 'p1',
          'expiresAt': 700,
          'serverNow': 100,
          'approvePath': '/?pair=p1',
        }),
      );
      final created = await PairingApi(ApiClient(transport)).create(
        deviceName: 'Pixel 9',
        platform: 'android',
        challenge: 'ab' * 32,
      );
      final request = transport.requests.single;
      expect(request.method, 'POST');
      expect(request.path, '/api/pairing/requests');
      expect(request.json, {
        'deviceName': 'Pixel 9',
        'platform': 'android',
        'challenge': 'ab' * 32,
      });
      expect(created.id, 'p1');
      expect(created.approvePath, '/?pair=p1');
      expect(created.expiresAt - created.serverNow, 600);
    });

    test('a claim tells waiting (202) from paired (200)', () async {
      var status = 202;
      final transport = FakeTransport(
        onSend: (request) async => status == 202
            ? reply(202, {
                'status': 'approved',
                'expiresAt': 700,
                'serverNow': 100,
              })
            : reply(200, {'device': device, 'token': 'pirc_dev_new'}),
      );
      final pairing = PairingApi(ApiClient(transport));
      final waiting = await pairing.claim('p 1', verifier: 'v');
      expect(waiting, isA<PairingWaiting>());
      expect((waiting as PairingWaiting).approved, isTrue);
      expect(transport.requests.last.path, '/api/pairing/requests/p%201/claim');
      // No code: the field is left out, not sent as null.
      expect(transport.requests.last.json, {'verifier': 'v'});

      status = 200;
      final claimed = await pairing.claim('p 1', verifier: 'v', code: '123456');
      expect(transport.requests.last.json, {'verifier': 'v', 'code': '123456'});
      claimed as PairingClaimed;
      expect(claimed.token, 'pirc_dev_new');
      expect(claimed.device.expiresAt, 9000);
      expect(claimed.device.idleExpiresAt, 5000);
      expect(claimed.device.effectiveExpiresAt, 5000);
    });

    test('a wrong code gives the attempts left', () async {
      final transport = FakeTransport(
        onSend: (request) async => reply(403, {
          'error': {
            'code': 'invalid_code',
            'message': 'The confirmation code is wrong',
            'details': {'attemptsLeft': 3},
          },
        }),
      );
      final error = await PairingApi(ApiClient(transport))
          .claim('p1', verifier: 'v', code: '000000')
          .then<Object?>((_) => null, onError: (Object e) => e);
      expect(error, isA<ApiError>());
      expect((error as ApiError).status, 403);
      expect(PairingApi.attemptsLeft(error), 3);
      expect(
        PairingApi.attemptsLeft(const ApiError(410, 'pairing_ended', 'm')),
        isNull,
      );
    });

    test('the approval routes read, approve and deny', () async {
      final transport = FakeTransport(
        onSend: (request) async => reply(200, {
          'id': 'p1',
          'status': request.path.endsWith('approve') ? 'approved' : 'pending',
          'expiresAt': 700,
          'serverNow': 100,
          'deviceName': 'Pixel 9',
          'platform': 'android',
          'pairing': {'idleDays': 7, 'maxDays': 30},
          if (request.path.endsWith('approve')) 'code': '042917',
        }),
      );
      final pairing = PairingApi(ApiClient(transport));
      final view = await pairing.view('p1');
      expect(transport.requests.last.method, 'GET');
      expect(transport.requests.last.path, '/api/pairing/approvals/p1');
      expect(view.code, isNull);
      expect(view.platform, 'android');
      expect(view.idleDays, 7);
      expect(view.maxDays, 30);
      final approved = await pairing.approve('p1');
      expect(transport.requests.last.path, '/api/pairing/approvals/p1/approve');
      expect(approved.code, '042917');
      await pairing.deny('p1');
      expect(transport.requests.last.path, '/api/pairing/approvals/p1/deny');
    });
  });

  group('rotation', () {
    test(
      'POST /api/device/rotate returns the device and the new token',
      () async {
        final transport = FakeTransport(
          onSend: (request) async =>
              reply(200, {'device': device, 'token': 'pirc_dev_rotated'}),
        );
        final (record, token) = await DeviceApi(ApiClient(transport)).rotate();
        expect(transport.requests.single.method, 'POST');
        expect(transport.requests.single.path, '/api/device/rotate');
        expect(token, 'pirc_dev_rotated');
        expect(record.id, 'd1');
      },
    );

    test('a reply without a token is an error, not an empty token', () async {
      final transport = FakeTransport(
        onSend: (request) async => reply(200, {'device': device}),
      );
      await expectLater(
        DeviceApi(ApiClient(transport)).rotate(),
        throwsA(isA<ApiError>()),
      );
    });

    test('the effective expiry is the earlier window', () {
      expect(DeviceSummary.fromJson(device).effectiveExpiresAt, 5000);
      expect(
        DeviceSummary.fromJson({
          ...device,
          'idleExpiresAt': 12000,
        }).effectiveExpiresAt,
        9000,
      );
      expect(
        DeviceSummary.fromJson(
          {...device}..remove('idleExpiresAt'),
        ).effectiveExpiresAt,
        9000,
      );
    });
  });
}
