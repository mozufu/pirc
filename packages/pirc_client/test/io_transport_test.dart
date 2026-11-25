// Safety regressions for the dart:io adapter against loopback servers:
// credentials, redirects, request shapes, client headers and error mapping.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:pirc_client/pirc_client.dart';
import 'package:pirc_client/src/transport/io_transport.dart';
import 'package:test/test.dart';

const _token = 'pirc_dev_secret';

/// A loopback server that records each request's headers.
class _Server {
  _Server._(this._server) {
    _server.listen(_handle);
  }

  static Future<_Server> start() async =>
      _Server._(await HttpServer.bind(InternetAddress.loopbackIPv4, 0));

  final HttpServer _server;
  final requests = <({String method, String path, HttpHeaders headers})>[];
  FutureOr<void> Function(HttpRequest request)? handler;

  Uri get uri => Uri.parse('http://127.0.0.1:${_server.port}');

  Future<void> _handle(HttpRequest request) async {
    requests.add((
      method: request.method,
      path: request.uri.path,
      headers: request.headers,
    ));
    if (request.method != 'GET') await request.drain<void>();
    final handle = handler;
    if (handle != null) return handle(request);
    request.response
      ..headers.contentType = ContentType.json
      ..write(jsonEncode({'ok': true}));
    await request.response.close();
  }

  Future<void> close() => _server.close(force: true);
}

Future<void> _error(
  HttpRequest request,
  int status,
  Map<String, Object?> error,
) {
  request.response
    ..statusCode = status
    ..headers.contentType = ContentType.json
    ..write(jsonEncode({'error': error}));
  return request.response.close();
}

void main() {
  late _Server server;
  late _Server other;
  late IoTransport transport;

  setUp(() async {
    server = await _Server.start();
    other = await _Server.start();
    transport = IoTransport(
      TransportConfig(baseUri: server.uri, account: () => 'ana@example'),
      tokens: const StaticTokenStore(_token),
    );
  });

  tearDown(() async {
    transport.close();
    await server.close();
    await other.close();
  });

  test(
    'GET carries the bearer token and client header, no request marker',
    () async {
      final response = await transport.send(
        const ApiRequest.get('/api/capabilities', query: {'a': 'b c'}),
      );
      expect(response.status, 200);
      final seen = server.requests.single;
      expect(seen.headers.value('authorization'), 'Bearer $_token');
      expect(seen.headers.value('x-pirc-client'), 'pirc-app/2');
      expect(seen.headers.value('x-pirc-request'), isNull);
      expect(seen.headers.value('x-pirc-account'), 'ana%40example');
    },
  );

  test('POST, PUT and DELETE carry X-Pirc-Request: 1', () async {
    await transport.send(const ApiRequest.post('/api/x', json: {'a': 1}));
    await transport.send(const ApiRequest.putBytes('/api/x', [1, 2, 3]));
    await transport.send(const ApiRequest.delete('/api/x'));
    expect(server.requests.map((r) => r.method), ['POST', 'PUT', 'DELETE']);
    for (final seen in server.requests) {
      expect(seen.headers['x-pirc-request'], ['1'], reason: seen.method);
      expect(seen.headers.value('x-pirc-client'), 'pirc-app/2');
    }
  });

  test(
    'a redirect to another origin is not followed; the token stays home',
    () async {
      server.handler = (request) {
        request.response
          ..statusCode = HttpStatus.found
          ..headers.set('location', other.uri.resolve('/steal').toString());
        return request.response.close();
      };
      final response = await transport.send(const ApiRequest.get('/api/x'));
      expect(response.status, HttpStatus.found);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(other.requests, isEmpty);

      final api = ApiClient(transport);
      await expectLater(
        api.get('/api/x'),
        throwsA(
          isA<ApiError>().having((e) => e.code, 'code', 'redirect_refused'),
        ),
      );
      await expectLater(api.post('/api/x', {'a': 1}), throwsA(isA<ApiError>()));
      expect(other.requests, isEmpty);
    },
  );

  test('error replies map to typed exceptions', () async {
    final api = ApiClient(transport);
    Future<void> expectMapped(
      int status,
      String code,
      Matcher matcher, [
      Object? details,
    ]) async {
      server.handler = (request) => _error(request, status, {
        'code': code,
        'message': 'nope',
        'details': ?details,
      });
      await expectLater(api.post('/api/x'), throwsA(matcher));
    }

    await expectMapped(
      426,
      'client_upgrade_required',
      isA<ClientUpgradeRequired>(),
    );
    await expectMapped(
      415,
      'request_shape_required',
      isA<RequestShapeRequired>(),
    );
    await expectMapped(401, 'unauthenticated', isA<PairingRequired>());
    await expectMapped(409, 'lost_control', isA<LostControl>());
    await expectMapped(409, 'account_changed', isA<AccountChanged>());
    await expectMapped(
      409,
      'stale_environment',
      isA<StaleEnvironment>().having(
        (e) => e.binding?.execution.generation,
        'generation',
        8,
      ),
      {
        'binding': {
          'version': 1,
          'membership': {'revision': 1, 'legacyWorkspaceId': 'w'},
          'execution': {
            'generation': 8,
            'workspaceId': 'w',
            'nodeId': 'n',
            'modeId': 'm',
          },
        },
      },
    );
    await expectMapped(
      400,
      'invalid_input',
      isA<ApiError>()
          .having((e) => e.status, 'status', 400)
          .having((e) => e.code, 'code', 'invalid_input'),
    );
  });

  test('no reply surfaces as TransportException', () async {
    final dead = IoTransport(
      TransportConfig(baseUri: other.uri),
      tokens: const StaticTokenStore(_token),
    );
    await other.close();
    await expectLater(
      dead.send(const ApiRequest.get('/api/x')),
      throwsA(isA<TransportException>()),
    );
    dead.close();
  });

  group('event socket', () {
    test('the upgrade carries the client header and the token', () async {
      server.handler = (request) async {
        final socket = await WebSocketTransformer.upgrade(request);
        socket.add(jsonEncode({'type': 'sessions_changed'}));
        await socket.close(4404, 'gone');
      };
      final socket = await transport.connectEvents(
        Uri(path: '/api/events', queryParameters: {'sessionId': 's1'}),
      );
      expect(await socket.messages.toList(), [
        {'type': 'sessions_changed'},
      ]);
      expect(socket.closeCode, 4404);
      final seen = server.requests.single;
      expect(seen.path, '/api/events');
      expect(seen.headers.value('x-pirc-client'), 'pirc-app/2');
      expect(seen.headers.value('authorization'), 'Bearer $_token');
      expect(seen.headers.value('x-pirc-request'), isNull);
    });

    test('an upgrade redirect is not followed', () async {
      server.handler = (request) {
        request.response
          ..statusCode = HttpStatus.temporaryRedirect
          ..headers.set(
            'location',
            other.uri.resolve('/api/events').toString(),
          );
        return request.response.close();
      };
      await expectLater(
        transport.connectEvents(Uri(path: '/api/events')),
        throwsA(
          isA<EventSocketRefused>().having((e) => e.status, 'status', 307),
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(other.requests, isEmpty);
    });

    test('a refused upgrade reports its status', () async {
      server.handler = (request) =>
          _error(request, 401, {'code': 'unauthenticated', 'message': 'no'});
      await expectLater(
        transport.connectEvents(Uri(path: '/api/events')),
        throwsA(
          isA<EventSocketRefused>().having((e) => e.status, 'status', 401),
        ),
      );
    });
  });
}
