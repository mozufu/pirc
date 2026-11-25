import 'package:pirc_client/pirc_client.dart';
import 'package:test/test.dart';

import 'support/fakes.dart';

void main() {
  group('clients', () {
    test('lists browsers and devices, most recent first', () async {
      final transport = FakeTransport(
        onSend: (request) async => reply(200, {
          'clients': [
            {
              'clientId': 'web-1',
              'name': 'Chrome on macOS',
              'kind': 'browser',
              'lastSeenAt': 1700,
            },
            {
              'clientId': 'app-1',
              'name': 'Pixel 9',
              'kind': 'device',
              'deviceId': 'd1',
              'lastSeenAt': 1600,
            },
          ],
        }),
      );
      final clients = await ClientsApi(ApiClient(transport)).list();
      final request = transport.requests.single;
      expect(request.method, 'GET');
      expect(request.path, '/api/clients');
      expect(clients, hasLength(2));
      expect(clients.first.clientId, 'web-1');
      expect(clients.first.name, 'Chrome on macOS');
      expect(clients.first.kind, 'browser');
      expect(clients.first.deviceId, isNull);
      expect(clients.first.isDevice, isFalse);
      expect(clients.first.lastSeenAt, 1700);
      expect(clients.last.clientId, 'app-1');
      expect(clients.last.name, 'Pixel 9');
      expect(clients.last.kind, 'device');
      expect(clients.last.deviceId, 'd1');
      expect(clients.last.isDevice, isTrue);
      expect(clients.last.lastSeenAt, 1600);
    });

    test('a rename is PUT /api/clients/:id with the name', () async {
      final transport = FakeTransport(
        onSend: (request) async => reply(200, {
          'client': {
            'clientId': 'web 1',
            'name': 'Office iMac',
            'kind': 'browser',
            'lastSeenAt': 1800,
          },
        }),
      );
      final client = await ClientsApi(
        ApiClient(transport),
      ).rename('web 1', 'Office iMac');
      final request = transport.requests.single;
      expect(request.method, 'PUT');
      expect(request.path, '/api/clients/web%201');
      expect(request.json, {'name': 'Office iMac'});
      expect(client.name, 'Office iMac');
      expect(client.clientId, 'web 1');
    });
  });

  group('this device', () {
    final device = {
      'id': 'd1',
      'name': 'Pixel 9',
      'createdAt': 1000,
      'expiresAt': 2000,
      'lastUsedAt': 1500,
    };

    test('reads GET /api/device', () async {
      final transport = FakeTransport(
        onSend: (request) async => reply(200, {'device': device}),
      );
      final read = await DeviceApi(ApiClient(transport)).read();
      expect(transport.requests.single.path, '/api/device');
      expect(read.id, 'd1');
      expect(read.name, 'Pixel 9');
      expect(read.createdAt, 1000);
      expect(read.expiresAt, 2000);
      expect(read.lastUsedAt, 1500);
    });

    test('renames with PATCH /api/device', () async {
      final transport = FakeTransport(
        onSend: (request) async => reply(200, {
          'device': {...device, 'name': 'Studio Pixel'},
        }),
      );
      final renamed = await DeviceApi(
        ApiClient(transport),
      ).rename('Studio Pixel');
      final request = transport.requests.single;
      expect(request.method, 'PATCH');
      expect(request.path, '/api/device');
      expect(request.json, {'name': 'Studio Pixel'});
      expect(renamed.name, 'Studio Pixel');
    });
  });
}
