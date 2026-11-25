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

  group('directory and sessions', () {
    test('nodes and workspaces are read', () async {
      final transport = FakeTransport(
        onSend: (request) async => switch (request.path) {
          '/api/nodes' => reply(200, {
            'nodes': [
              {
                'id': 'laptop',
                'role': 'worker',
                'modes': ['default'],
                'workspaces': [
                  {'id': 'pirc', 'displayName': 'pirc', 'available': false},
                ],
                'connectedAt': 1,
                'lastSeenAt': 2,
              },
            ],
          }),
          _ => reply(200, {
            'workspaces': [
              {
                'id': 'laptop:pirc',
                'hostId': 'h1',
                'displayName': 'pirc',
                'mode': 'default',
                'kind': 'directory',
                'deleting': true,
              },
            ],
          }),
        },
      );
      final directory = DirectoryApi(ApiClient(transport));
      final node = (await directory.nodes()).single;
      expect(node.id, 'laptop');
      expect(node.workspaces.single.available, isFalse);
      final workspace = (await directory.workspaces()).single;
      expect(workspace.nodeId, 'laptop');
      expect(workspace.kind, 'directory');
      expect(workspace.deleting, isTrue);
    });

    test('row actions send what the Gateway reads', () async {
      final transport = FakeTransport(
        onSend: (request) async => reply(200, {
          'session': {'id': 's/1', 'workspaceId': 'w', 'name': 'n'},
        }),
      );
      final sessions = SessionsApi(ApiClient(transport));
      await sessions.update('s/1', pinned: true);
      await sessions.update('s/1', name: 'New', settled: false);
      await sessions.delete('s/1');
      await sessions.markRead('s/1');
      expect(
        [for (final r in transport.requests) '${r.method} ${r.path}'],
        [
          'PATCH /api/sessions/s%2F1',
          'PATCH /api/sessions/s%2F1',
          'DELETE /api/sessions/s%2F1',
          'POST /api/sessions/s%2F1/read',
        ],
      );
      expect(transport.requests[0].json, {'pinned': true});
      expect(transport.requests[1].json, {'name': 'New', 'settled': false});
    });
  });

  test('pots, works and pending approvals are read', () async {
    final transport = FakeTransport(
      onSend: (request) async => switch (request.path) {
        '/api/pots' => reply(200, {
          'pots': [
            {
              'id': 'p1',
              'state': 'paused',
              'profile': {'name': 'Tester', 'avatarColor': 3},
            },
          ],
        }),
        '/api/pot-works' => reply(200, {
          'works': [
            {
              'id': 'w1',
              'potId': 'p1',
              'sessionId': 's1',
              'workspaceId': 'n:w',
              'title': 'Check',
              'state': 'open',
            },
          ],
        }),
        '/api/pot-works/w1/take-over' => reply(200, {
          'work': {'id': 'w1', 'potId': 'p1', 'state': 'taken_over'},
        }),
        _ => reply(200, {
          'approvals': [
            {
              'id': 'a1',
              'potId': 'p1',
              'workTitle': 'Compare',
              'workspaceId': 'n:w',
              'model': 'claude-opus',
              'state': 'pending',
            },
          ],
        }),
      },
    );
    final pots = PotsApi(ApiClient(transport));
    final pot = (await pots.pots()).single;
    expect((pot.name, pot.state, pot.avatarColor), ('Tester', 'paused', 3));
    final work = (await pots.works()).single;
    expect(work.open, isTrue);
    expect(work.sessionId, 's1');
    expect((await pots.takeOver('w1')).open, isFalse);
    final approval = (await pots.approvals(state: 'pending')).single;
    expect(approval.model, 'claude-opus');
    expect(transport.requests.last.query, {'state': 'pending'});
  });

  test('models, uploads and the first-send retry', () async {
    final transport = FakeTransport(
      onSend: (request) async => switch (request.path) {
        '/api/models' => reply(200, {
          'models': [
            {
              'provider': 'anthropic',
              'id': 'opus',
              'name': 'Opus',
              'reasoning': true,
            },
            {'provider': 'local', 'id': 'small'},
          ],
        }),
        '/api/sessions/s1/uploads' => reply(201, {
          'upload': {'id': 'u1', 'mimeType': 'image/png'},
        }),
        _ => reply(200, {
          'preparation': {'operationId': 'op1', 'state': 'sending'},
        }),
      },
    );
    final api = ApiClient(transport);
    final models = await ModelsApi(api).list();
    expect(models.first.reasoning, isTrue);
    expect(models.last.name, 'small');
    expect(models.last.reasoning, isFalse);
    final id = await SessionsApi(
      api,
    ).upload('s1', [1, 2], filename: 'a b.png', contentType: 'image/png');
    expect(id, 'u1');
    final upload = transport.requests[1];
    expect(upload.query, {'filename': 'a b.png'});
    expect(upload.contentType, 'image/png');
    expect(upload.bytes, [1, 2]);
    await FirstSendClient(api).retry(
      'op1',
      retryId: 'r1',
      previousCommandId: 'c1',
      lease: const ControlLease(clientId: 'me', generation: 3),
    );
    expect(
      transport.requests.last.path,
      '/api/conversation-submissions/op1/retry',
    );
    expect(transport.requests.last.json, {
      'retryId': 'r1',
      'previousCommandId': 'c1',
      'clientId': 'me',
      'generation': 3,
    });
  });
}
