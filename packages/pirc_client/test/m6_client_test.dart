import 'package:pirc_client/pirc_client.dart';
import 'package:pirc_client/src/transport/policy.dart';
import 'package:test/test.dart';

import 'support/fakes.dart';

final _base = Uri.parse('https://gateway.test');

void main() {
  group('sessions', () {
    test('a schedule origin and the write lease are read', () {
      final session = Session.fromJson({
        'id': 's1',
        'workspaceId': 'n:w',
        'name': 'Nightly',
        'writeLease': true,
        'origin': {
          'kind': 'schedule',
          'scheduleId': 'sch1',
          'title': 'Check the tests',
          'dueAt': 1700,
        },
      });
      expect(session.writeLease, isTrue);
      expect(session.origin?.kind, 'schedule');
      expect(session.origin?.scheduleId, 'sch1');
      expect(session.origin?.title, 'Check the tests');
      expect(session.origin?.dueAt, 1700);
      expect(session.copyWith(name: 'x').origin, same(session.origin));
    });

    test('delegation origins are not mapped', () {
      final session = Session.fromJson({
        'id': 's1',
        'workspaceId': 'n:w',
        'name': 'x',
        'origin': {'kind': 'delegation', 'delegationId': 'd1', 'title': 't'},
      });
      expect(session.origin, isNull);
      expect(session.writeLease, isFalse);
    });
  });

  test('capabilities expose the pots feature', () {
    final capabilities = Capabilities.fromJson({
      'apiVersion': 2,
      'features': {
        'pots': {'supported': true, 'enabled': true, 'version': 1},
      },
    });
    expect(capabilities.pots.usable, isTrue);
    expect(Capabilities.fromJson({'apiVersion': 2}).pots.usable, isFalse);
  });

  test('every hint the gateway sends is classified', () {
    for (final type in [
      'pots_changed',
      'threads_changed',
      'approvals_changed',
      'activity_changed',
      'budget_requests_changed',
      'notifications_changed',
    ]) {
      expect(
        EventMessage.fromJson({'type': type}),
        isA<HintMessage>().having((hint) => hint.type, 'type', type),
        reason: type,
      );
    }
  });

  group('pot instructions', () {
    Map<String, Object?> raw({
      String type = 'pot-instruction',
      Object? details,
      String content =
          'Instruction from Tester, a pot coordinating this work for the '
          'user:\n\nRun the tests',
    }) => {
      'role': 'custom',
      'customType': type,
      'content': content,
      'details': ?details,
    };
    const details = {
      'potId': 'pot1',
      'potName': 'Tester',
      'workId': 'w1',
      'instructionId': 'i1',
    };

    test('the pot comes from details and the preamble is dropped', () {
      final message = piMessage(raw(details: details), now: () => 1)!;
      expect(message.systemKind, 'pot-instruction');
      expect(message.label, 'Tester');
      expect(message.content, 'Run the tests');
      expect(message.pot?.potId, 'pot1');
      expect(message.pot?.potName, 'Tester');
      expect(message.pot?.workId, 'w1');
      expect(message.pot?.instructionId, 'i1');
    });

    test('text that names a pot gives no provenance', () {
      final message = piMessage(
        raw(content: 'Instruction from Tester, a pot coordinating this'),
        now: () => 1,
      )!;
      expect(message.pot, isNull);
      expect(message.systemKind, isNot('pot-instruction'));
    });

    test('the old pots-dispatch type is an ordinary custom message', () {
      final message = piMessage(
        raw(type: 'pots-dispatch', details: details),
        now: () => 1,
      )!;
      expect(message.pot, isNull);
      expect(message.systemKind, isNot('pot-instruction'));
    });
  });

  test('environment_required and taken_over are typed', () {
    ApiError? map(String code) => errorFor(
      reply(409, {
        'error': {'code': code, 'message': 'm'},
      }),
    );
    expect(map('environment_required'), isA<EnvironmentRequired>());
    expect(map('taken_over'), isA<TakenOver>());
  });

  test('patch, put and delete send their verb and body', () async {
    final transport = FakeTransport(onSend: (_) async => reply(200, {}));
    final api = ApiClient(transport);
    await api.patch('/api/sessions/s1', {'name': 'n'});
    await api.put('/api/calendar/permissions', {'read': true});
    await api.delete('/api/sessions/s1', query: {'force': '1'});
    expect(transport.requests.map((r) => r.method), ['PATCH', 'PUT', 'DELETE']);
    expect(transport.requests[0].json, {'name': 'n'});
    expect(transport.requests[1].json, {'read': true});
    expect(transport.requests[2].query, {'force': '1'});
    expect(transport.requests.every((r) => r.isStateChanging), isTrue);
  });

  group('management grant', () {
    final config = TransportConfig(
      baseUri: _base,
      managementGrant: () => 'grant-1',
    );
    String? sent(String path) =>
        policyHeaders(ApiRequest.get(path), config)[managementHeader];

    test('is sent to the management routes', () {
      for (final path in [
        '/api/devices',
        '/api/devices/d1/revoke',
        '/api/providers',
        '/api/providers/openai',
        '/api/provider-auth/openai/start',
        '/api/%64evices',
      ]) {
        expect(sent(path), 'grant-1', reason: path);
      }
    });

    test('is never sent to another path', () {
      for (final path in [
        '/api/devicesx',
        '/api/providersx/y',
        '/api/provider-authx',
        '/api/sessions',
        '/api/capabilities',
        '/api/hints',
        '/api/events',
        '/api/sessions/s1/devices',
        '/devices',
        '/api',
        '/',
        '/api/%zz',
      ]) {
        expect(sent(path), isNull, reason: path);
      }
    });

    test('is not sent when there is none', () {
      final headers = policyHeaders(
        const ApiRequest.get('/api/devices'),
        TransportConfig(baseUri: _base, managementGrant: () => null),
      );
      expect(headers.containsKey(managementHeader), isFalse);
    });
  });
}
