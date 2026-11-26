import 'package:pirc_client/pirc_client.dart';
import 'package:test/test.dart';

import 'support/fakes.dart';

void main() {
  group('PushApi.update', () {
    test('sends only the given preferences with the revision', () async {
      final transport = FakeTransport(
        onSend: (_) async => reply(200, {
          'subscription': {'id': 'push 1', 'revision': 6},
        }),
      );
      final saved = await PushApi(ApiClient(transport)).update(
        'push 1',
        revision: 5,
        levels: {'done': 'off'},
        setQuietHours: true,
        quietHours: (start: '22:00', end: '07:00'),
        digestAt: '19:30',
      );
      expect(saved['revision'], 6);
      final request = transport.requests.single;
      expect(request.method, 'PATCH');
      expect(request.path, '/api/push/subscriptions/push%201');
      expect(request.json, {
        'revision': 5,
        'levels': {'done': 'off'},
        'quietHours': {'start': '22:00', 'end': '07:00'},
        'digestAt': '19:30',
      });
    });

    test('turns quiet hours off with null', () async {
      final transport = FakeTransport(
        onSend: (_) async => reply(200, {'subscription': <String, Object?>{}}),
      );
      await PushApi(
        ApiClient(transport),
      ).update('p', revision: 1, setQuietHours: true, lockScreen: 'full');
      expect(transport.requests.single.json, {
        'revision': 1,
        'quietHours': null,
        'lockScreen': 'full',
      });
    });

    test('a stale revision carries the current target', () async {
      final transport = FakeTransport(
        onSend: (_) async => reply(409, {
          'error': {
            'code': 'revision_mismatch',
            'message': 'Changed elsewhere',
            'details': {
              'subscription': {'id': 'p', 'revision': 9},
            },
          },
        }),
      );
      await expectLater(
        PushApi(
          ApiClient(transport),
        ).update('p', revision: 1, digestAt: '08:00'),
        throwsA(
          isA<ApiError>()
              .having((e) => e.status, 'status', 409)
              .having((e) => e.code, 'code', 'revision_mismatch')
              .having((e) => (e.details as Map)['subscription'], 'details', {
                'id': 'p',
                'revision': 9,
              }),
        ),
      );
    });
  });
}
