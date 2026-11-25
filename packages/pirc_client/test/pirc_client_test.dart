import 'dart:convert';

import 'package:pirc_client/pirc_client.dart';
import 'package:pirc_client/src/transport/policy.dart';
import 'package:pirc_client/src/transport/sha1.dart';
import 'package:test/test.dart';

import 'support/fakes.dart';

void main() {
  test('client header names the app and the API version', () {
    expect(clientHeaderValue(), 'pirc-app/2');
  });

  group('request policy', () {
    final config = TransportConfig(baseUri: _base);

    test('every request names the client; only non-GET is state-changing', () {
      final get = policyHeaders(const ApiRequest.get('/api/x'), config);
      expect(get[clientHeader], 'pirc-app/2');
      expect(get.containsKey(requestHeader), isFalse);
      for (final method in ['POST', 'PUT', 'DELETE', 'PATCH']) {
        final headers = policyHeaders(ApiRequest(method, '/api/x'), config);
        expect(headers[requestHeader], '1', reason: method);
        expect(headers[clientHeader], 'pirc-app/2', reason: method);
      }
    });

    test('the account header is URI-encoded', () {
      final headers = policyHeaders(
        const ApiRequest.get('/api/x'),
        TransportConfig(baseUri: _base, account: () => 'ana maría@x'),
      );
      expect(headers[accountHeader], 'ana%20mar%C3%ADa%40x');
    });

    test('the browser event socket carries the client in the query', () {
      final target = Uri(
        path: '/api/events',
        queryParameters: {'sessionId': 's1', 'cursor': '2:10'},
      );
      final web = eventSocketUri(_base, target, clientQuery: true);
      expect(web.scheme, 'wss');
      expect(web.host, 'gateway.test');
      expect(web.query, contains('client=pirc-app%2F2'));
      expect(web.queryParameters['cursor'], '2:10');
      final io = eventSocketUri(Uri.parse('http://127.0.0.1:8080'), target);
      expect(io.scheme, 'ws');
      expect(io.queryParameters.containsKey('client'), isFalse);
    });
  });

  group('error mapping', () {
    ApiError? map(int status, [String? code, Object? details]) => errorFor(
      reply(
        status,
        code == null
            ? null
            : {
                'error': {'code': code, 'message': 'm', 'details': ?details},
              },
      ),
    );

    test('typed errors', () {
      expect(map(200), isNull);
      expect(map(426, 'client_upgrade_required'), isA<ClientUpgradeRequired>());
      expect(map(415, 'request_shape_required'), isA<RequestShapeRequired>());
      expect(map(401, 'unauthenticated'), isA<PairingRequired>());
      expect(map(401), isA<PairingRequired>());
      expect(map(409, 'lost_control'), isA<LostControl>());
      expect(map(409, 'account_changed'), isA<AccountChanged>());
      final stale = map(409, 'stale_environment', {
        'binding': binding.toJson(),
      });
      expect(stale, isA<StaleEnvironment>());
      expect((stale! as StaleEnvironment).binding, binding);
      final other = map(503, 'node_offline')!;
      expect(other.runtimeType, ApiError);
      expect((other.status, other.code), (503, 'node_offline'));
      expect(map(302)!.code, 'redirect_refused');
      expect(map(502)!.code, 'http_502');
    });
  });

  group('models', () {
    test('expectedBinding serializes exactly the gateway fields', () {
      final parsed = ExpectedBinding.fromJson({
        ...binding.toJson(),
        'extra': true,
      });
      expect(parsed, binding);
      expect(jsonDecode(jsonEncode(parsed.toJson())), {
        'version': 1,
        'membership': {'revision': 3, 'legacyWorkspaceId': 'm5pro:pirc'},
        'execution': {
          'generation': 7,
          'workspaceId': 'm5pro:pirc',
          'nodeId': null,
          'modeId': 'default',
        },
      });
      expect(parsed.isValidFor('m5pro:pirc'), isTrue);
      expect(parsed.isValidFor('other'), isFalse);
    });

    test('cursors parse, compare and print', () {
      expect(Cursor.tryParse('2:10'), const Cursor(2, 10));
      expect(Cursor.tryParse('2:x'), isNull);
      expect(Cursor.tryParse('2'), isNull);
      expect(const Cursor(2, 10) <= const Cursor(2, 11), isTrue);
      expect(const Cursor(3, 0).compareTo(const Cursor(2, 99)), 1);
      expect(const Cursor(2, 10).toString(), '2:10');
    });

    test('event frames are classified', () {
      expect(
        EventMessage.fromJson({
          'sessionId': 's1',
          'epoch': 2,
          'sequence': 11,
          'type': 'pi_event',
          'timestamp': 5,
        }),
        isA<SessionEvent>().having(
          (e) => e.cursor,
          'cursor',
          const Cursor(2, 11),
        ),
      );
      expect(
        EventMessage.fromJson({
          'type': 'reset',
          'reason': 'backpressure',
          'watermark': {'epoch': 2, 'sequence': 40},
        }),
        isA<ResetMessage>().having(
          (e) => e.watermark,
          'watermark',
          const Cursor(2, 40),
        ),
      );
      expect(
        EventMessage.fromJson({'type': 'sessions_changed'}),
        isA<HintMessage>(),
      );
    });

    test('tolerant parsing of capabilities, commands and preparations', () {
      final capabilities = Capabilities.fromJson({
        'apiVersion': 2,
        'server': {'version': '2.0.0'},
        'account': {'user': 'ana'},
        'features': {
          'firstSend': {
            'supported': true,
            'enabled': true,
            'version': 2,
            'attachmentRetentionDays': 7,
          },
        },
        'future': 1,
      });
      expect(capabilities.apiVersion, 2);
      expect(capabilities.accountUser, 'ana');
      expect(capabilities.firstSend.usable, isTrue);
      expect(capabilities.firstSend.extra['attachmentRetentionDays'], 7);
      expect(capabilities.environmentSwitching.usable, isFalse);

      final command = Command.fromJson({
        'id': 'c1',
        'sessionId': 's1',
        'status': 'outcome_unknown',
        'new': 'x',
      });
      expect(command.status, CommandStatus.outcomeUnknown);
      expect(
        Command.fromJson({'status': 'later'}).status,
        CommandStatus.unknown,
      );

      final preparation = Preparation.fromJson({
        'operationId': 'op',
        'state': 'admitted',
        'messageAdmission': {'outcome': 'accepted', 'attemptNumber': 0},
      });
      expect(preparation.messageAdmission!.outcome, 'accepted');
      expect(
        ErrorBody.fromJson({
          'error': {'code': 'x', 'message': 'y'},
        })!.code,
        'x',
      );
    });
  });

  test('sha1 matches the RFC 6455 handshake example', () {
    final accept = base64Encode(
      sha1(
        ascii.encode(
          'dGhlIHNhbXBsZSBub25jZQ==258EAFA5-E914-47DA-95CA-C5AB0DC85B11',
        ),
      ),
    );
    expect(accept, 's3pPLMBiTxaQ9kYGzzhZRbK+xOo=');
  });
}

final _base = Uri.parse('https://gateway.test');
