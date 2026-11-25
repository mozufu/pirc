import 'package:pirc_client/pirc_client.dart';
import 'package:test/test.dart';

import 'support/fakes.dart';

Map<String, Object?> _document(int version) => {
  'apiVersion': version,
  'server': {'version': '2.0.0'},
  'features': {
    'firstSend': {'supported': true, 'enabled': true, 'version': 2},
  },
};

void main() {
  test('connect reads the capability document first', () async {
    final requests = <ApiRequest>[];
    final api = ApiClient(
      FakeTransport(
        onSend: (request) async {
          requests.add(request);
          return reply(200, _document(2));
        },
      ),
    );
    final capabilities = await api.connect();
    expect(requests.single.path, '/api/capabilities');
    expect(capabilities.apiVersion, apiVersion);
  });

  test('connect refuses a Gateway with another API version', () async {
    final api = ApiClient(
      FakeTransport(onSend: (_) async => reply(200, _document(3))),
    );
    await expectLater(api.connect(), throwsA(isA<ClientUpgradeRequired>()));
  });

  test('a 426 from the Gateway is an upgrade request', () async {
    final api = ApiClient(
      FakeTransport(
        onSend: (_) async => reply(426, {
          'error': {
            'code': 'client_upgrade_required',
            'message': 'This version of the app is out of date.',
          },
        }),
      ),
    );
    await expectLater(api.connect(), throwsA(isA<ClientUpgradeRequired>()));
  });
}
