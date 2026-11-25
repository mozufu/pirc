import 'dart:async';
import 'dart:convert';

import 'package:fake_async/fake_async.dart';
import 'package:pirc_client/pirc_client.dart';
import 'package:test/test.dart';

import 'support/fakes.dart';

const _lease = ControlLease(clientId: 'client-1', generation: 4);

Map<String, Object?> _command(String id, String status) => {
  'id': id,
  'sessionId': 's1',
  'payloadHash': 'h',
  'payload': {'type': 'prompt', 'message': 'hi'},
  'status': status,
  'result': null,
  'error': null,
};

Map<String, Object?> _body(ApiRequest request) =>
    jsonDecode(jsonEncode(request.json)) as Map<String, Object?>;

String _route(ApiRequest request) => '${request.method} ${request.path}';

void main() {
  group('command sender', () {
    late FakeTransport transport;
    late CommandSender sender;
    var ids = 0;

    setUp(() {
      ids = 0;
      transport = FakeTransport();
      sender = CommandSender(ApiClient(transport), newId: () => 'cmd-${++ids}');
    });

    test('attaches expectedBinding, client and generation', () async {
      transport.onSend = (request) async => reply(202, {
        'command': _command('cmd-x', 'accepted'),
        'duplicate': false,
      });
      final outcome = await sender.send(
        sessionId: 's1',
        payload: CommandPayload.prompt('hi'),
        lease: _lease,
        binding: binding,
        commandId: 'cmd-x',
      );
      expect(outcome, isA<CommandAccepted>());
      final request = transport.requests.single;
      expect(_route(request), 'POST /api/sessions/s1/commands');
      expect(_body(request), {
        'commandId': 'cmd-x',
        'clientId': 'client-1',
        'generation': 4,
        'expectedBinding': binding.toJson(),
        'payload': {'message': 'hi', 'type': 'prompt'},
      });
    });

    test('stop and stop_transition carry no expectedBinding', () async {
      transport.onSend = (request) async => reply(202, {
        'command': _command('c', 'accepted'),
        'duplicate': false,
      });
      for (final payload in [
        CommandPayload.stop(),
        CommandPayload.stopTransition('op', 'hash'),
      ]) {
        await sender.send(
          sessionId: 's1',
          payload: payload,
          lease: _lease,
          binding: binding,
        );
        expect(
          _body(transport.requests.last).containsKey('expectedBinding'),
          isFalse,
        );
      }
    });

    test('a bound command without a binding is never sent', () async {
      expect(
        () => sender.send(
          sessionId: 's1',
          payload: CommandPayload.steer('x'),
          lease: _lease,
        ),
        throwsArgumentError,
      );
      expect(transport.requests, isEmpty);
    });

    test('a timeout is uncertain and resolved only through the receipt', () {
      fakeAsync((async) {
        final never = Completer<ApiResponse>();
        transport.onSend = (request) => request.method == 'POST'
            ? never.future
            : Future.value(
                reply(200, {'command': _command('cmd-1', 'accepted')}),
              );
        CommandOutcome? outcome;
        unawaited(
          sender
              .send(
                sessionId: 's1',
                payload: CommandPayload.prompt('hi'),
                lease: _lease,
                binding: binding,
              )
              .then((value) => outcome = value),
        );
        async.elapse(const Duration(seconds: 19));
        expect(outcome, isNull);
        async.elapse(const Duration(seconds: 1));
        expect(outcome, isA<CommandUncertain>());
        expect((outcome! as CommandUncertain).cause, isA<RequestTimeout>());
        expect(sender.uncertain, {'cmd-1'});

        // The same command is never sent again while uncertain.
        expect(
          () => sender.send(
            sessionId: 's1',
            payload: CommandPayload.prompt('hi'),
            lease: _lease,
            binding: binding,
            commandId: 'cmd-1',
          ),
          throwsStateError,
        );

        CommandOutcome? resolved;
        unawaited(sender.resolve('s1', 'cmd-1').then((v) => resolved = v));
        async.flushMicrotasks();
        expect(resolved, isA<CommandAccepted>());
        expect(sender.uncertain, isEmpty);
        expect(transport.requests.map(_route), [
          'POST /api/sessions/s1/commands',
          'GET /api/sessions/s1/commands/cmd-1',
        ]);
      });
    });

    test('a dropped connection is uncertain', () async {
      transport.onSend = (_) async =>
          throw const TransportException('connection reset');
      final outcome = await sender.send(
        sessionId: 's1',
        payload: CommandPayload.prompt('hi'),
        lease: _lease,
        binding: binding,
      );
      expect(outcome, isA<CommandUncertain>());
      expect(transport.requests, hasLength(1));
    });

    test(
      '503 outcome_unknown stays uncertain until the receipt knows',
      () async {
        var receipt = 'outcome_unknown';
        transport.onSend = (request) async => request.method == 'POST'
            ? reply(503, {
                'command': _command('cmd-1', 'outcome_unknown'),
                'duplicate': false,
              })
            : reply(200, {'command': _command('cmd-1', receipt)});
        expect(
          await sender.send(
            sessionId: 's1',
            payload: CommandPayload.prompt('hi'),
            lease: _lease,
            binding: binding,
          ),
          isA<CommandUncertain>(),
        );
        expect(await sender.resolve('s1', 'cmd-1'), isA<CommandUncertain>());
        expect(sender.uncertain, {'cmd-1'});
        receipt = 'rejected';
        expect(await sender.resolve('s1', 'cmd-1'), isA<CommandRejected>());
        expect(sender.uncertain, isEmpty);
        expect(
          transport.requests.where((r) => r.method == 'POST'),
          hasLength(1),
        );
      },
    );

    test('a proxy 5xx without a gateway body is uncertain', () async {
      transport.onSend = (_) async => reply(502);
      expect(
        await sender.send(
          sessionId: 's1',
          payload: CommandPayload.prompt('hi'),
          lease: _lease,
          binding: binding,
        ),
        isA<CommandUncertain>(),
      );
    });

    test('a receipt the gateway does not know means not received', () async {
      transport.onSend = (_) async => reply(404, {
        'error': {'code': 'not_found', 'message': 'gone'},
      });
      expect(await sender.resolve('s1', 'cmd-9'), isA<CommandNotReceived>());
    });

    test('a repeated command ID is a duplicate', () async {
      transport.onSend = (_) async => reply(200, {
        'command': _command('cmd-1', 'accepted'),
        'duplicate': true,
      });
      final outcome = await sender.send(
        sessionId: 's1',
        payload: CommandPayload.prompt('hi'),
        lease: _lease,
        binding: binding,
        commandId: 'cmd-1',
      );
      expect(outcome, isA<CommandDuplicate>());
      expect(
        (outcome as CommandDuplicate).command.status,
        CommandStatus.accepted,
      );
    });

    test('503 with a rejected receipt is rejected', () async {
      transport.onSend = (_) async => reply(503, {
        'command': _command('cmd-1', 'rejected'),
        'duplicate': false,
      });
      expect(
        await sender.send(
          sessionId: 's1',
          payload: CommandPayload.prompt('hi'),
          lease: _lease,
          binding: binding,
        ),
        isA<CommandRejected>(),
      );
    });

    test('gateway refusals are typed errors, not uncertain', () async {
      transport.onSend = (_) async => reply(409, {
        'error': {
          'code': 'stale_environment',
          'message': 'moved',
          'details': {'binding': binding.toJson()},
        },
      });
      await expectLater(
        sender.send(
          sessionId: 's1',
          payload: CommandPayload.prompt('hi'),
          lease: _lease,
          binding: binding,
        ),
        throwsA(isA<StaleEnvironment>()),
      );
      transport.onSend = (_) async => reply(503, {
        'error': {'code': 'node_offline', 'message': 'Node is offline'},
      });
      await expectLater(
        sender.send(
          sessionId: 's1',
          payload: CommandPayload.prompt('hi'),
          lease: _lease,
          binding: binding,
        ),
        throwsA(isA<ApiError>().having((e) => e.code, 'code', 'node_offline')),
      );
      expect(sender.uncertain, isEmpty);
    });

    test('generated command IDs are random and URL-safe', () {
      final a = randomId(), b = randomId();
      expect(a, isNot(b));
      expect(a, matches(RegExp(r'^[A-Za-z0-9_-]{22}$')));
    });
  });

  group('control lease', () {
    test(
      'heartbeat every 10 s visible, 15 s hidden; stops on lost_control',
      () {
        fakeAsync((async) {
          final beats = <Duration>[];
          var lost = false;
          final transport = FakeTransport(
            onSend: (request) async {
              beats.add(async.elapsed);
              if (lost) {
                return reply(409, {
                  'error': {'code': 'lost_control', 'message': 'taken'},
                });
              }
              return reply(200, {
                'lease': {
                  'clientId': 'client-1',
                  'generation': 4,
                  'expiresAt': 1,
                  'expired': false,
                },
              });
            },
          );
          LostControl? lostError;
          final heartbeat = LeaseHeartbeat(
            ControlLeaseClient(ApiClient(transport)),
            's1',
            _lease,
            onLost: (error) => lostError = error,
          )..start();
          async.elapse(const Duration(seconds: 20));
          expect(beats, const [Duration(seconds: 10), Duration(seconds: 20)]);
          heartbeat.visible = false;
          async.elapse(const Duration(seconds: 30));
          expect(beats.sublist(2), const [
            Duration(seconds: 35),
            Duration(seconds: 50),
          ]);
          final body = _body(transport.requests.first);
          expect(
            _route(transport.requests.first),
            'POST /api/sessions/s1/control/heartbeat',
          );
          expect(body, {'clientId': 'client-1', 'generation': 4});

          lost = true;
          async.elapse(const Duration(seconds: 15));
          expect(lostError, isNotNull);
          expect(heartbeat.running, isFalse);
          final count = beats.length;
          async.elapse(const Duration(minutes: 1));
          expect(beats, hasLength(count));
        });
      },
    );
  });

  group('first send', () {
    Map<String, Object?> preparation(String state) => {
      'preparation': {
        'operationId': 'op-1',
        'sessionId': 's-new',
        'workspaceId': 'w',
        'state': state,
      },
    };

    test('prepare → accept → materialize → acquire → dispatch', () async {
      final transport = FakeTransport(
        onSend: (request) async => request.path.endsWith('/acquire')
            ? reply(200, {
                'lease': {'clientId': 'client-1', 'generation': 1},
              })
            : reply(200, preparation('admitted')),
      );
      final outcome = await FirstSendClient(ApiClient(transport)).send(
        operationId: 'op-1',
        submission: const Submission(workspaceId: 'w', message: 'hello'),
        clientId: 'client-1',
      );
      expect(outcome, isA<FirstSendDispatched>());
      expect(transport.requests.map(_route), [
        'POST /api/conversation-submissions/prepare',
        'POST /api/conversation-submissions/op-1/accept',
        'POST /api/conversation-submissions/op-1/materialize',
        'POST /api/sessions/s-new/control/acquire',
        'POST /api/conversation-submissions/op-1/dispatch',
      ]);
      expect(_body(transport.requests.first), {
        'operationId': 'op-1',
        'submission': {'workspaceId': 'w', 'message': 'hello'},
      });
      expect(_body(transport.requests.last), {
        'clientId': 'client-1',
        'generation': 1,
      });
    });

    test('a dispatch without a reply is uncertain and not re-sent', () async {
      final transport = FakeTransport(
        onSend: (request) async {
          if (request.path.endsWith('/dispatch')) {
            throw const TransportException('connection reset');
          }
          return request.path.endsWith('/acquire')
              ? reply(200, {
                  'lease': {'clientId': 'client-1', 'generation': 1},
                })
              : reply(200, preparation('ready'));
        },
      );
      final client = FirstSendClient(ApiClient(transport));
      final outcome = await client.send(
        operationId: 'op-1',
        submission: const Submission(workspaceId: 'w', message: 'hello'),
        clientId: 'client-1',
      );
      expect(outcome, isA<FirstSendUncertain>());
      expect(
        transport.requests.where((r) => r.path.endsWith('/dispatch')),
        hasLength(1),
      );
      await client.receipt('op-1');
      expect(
        _route(transport.requests.last),
        'GET /api/conversation-submissions/op-1/receipt',
      );
      expect(
        transport.requests.where((r) => r.path.contains('/commands')),
        isEmpty,
      );
    });
  });
}
