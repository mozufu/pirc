import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:pirc_app/src/connection/storage.dart';
import 'package:pirc_app/src/work/composer/attachments.dart';
import 'package:pirc_client/pirc_client.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/harness.dart';
import 'support/session_fixture.dart';

const _binding = {
  'version': 1,
  'membership': {'revision': 3, 'legacyWorkspaceId': 'm3air:notes'},
  'execution': {
    'generation': 7,
    'workspaceId': 'm3air:notes',
    'nodeId': null,
    'modeId': 'default',
  },
};

const _models = [
  {'provider': 'anthropic', 'id': 'opus', 'name': 'Opus', 'reasoning': true},
  {'provider': 'local', 'id': 'small', 'name': 'Small', 'reasoning': false},
];

/// joined-mid-stream with a binding, a model and (optionally) a running run
/// with a queue; commands are accepted unless [commandReply] says otherwise.
class _Composer {
  _Composer({bool running = false, List<String> queue = const []}) {
    final snapshot = session.snapshot;
    (snapshot['session']! as Map)['binding'] = _binding;
    snapshot['agent'] = {
      'model': {'provider': 'anthropic', 'id': 'opus'},
      'thinkingLevel': 'medium',
    };
    if (running) snapshot['run'] = {'id': 'r1', 'status': 'running'};
    snapshot['queue'] = {'steering': queue, 'followUp': <String>[]};
    gateway = session.install();
    gateway.json['GET /api/models'] = (_) => {'models': _models};
    gateway.json['POST /api/sessions/s2/commands'] = (request) =>
        commandReply?.call(request) ??
        reply(202, {
          'command': {
            'id': (request.json! as Map)['commandId'],
            'sessionId': 's2',
            'status': 'accepted',
          },
        });
  }

  final session = FixtureSession('joined-mid-stream.json');
  late final FakeGateway gateway;
  Object? Function(ApiRequest request)? commandReply;

  List<Map> get payloads => [
    for (final request in gateway.sent('POST', '/api/sessions/s2/commands'))
      (request.json! as Map)['payload'] as Map,
  ];

  Map get lastBody =>
      gateway.sent('POST', '/api/sessions/s2/commands').last.json! as Map;
}

Future<_Composer> _open(
  WidgetTester tester, {
  bool running = false,
  List<String> queue = const [],
}) async {
  final composer = _Composer(running: running, queue: queue);
  await pumpApp(
    tester,
    gateway: composer.gateway,
    width: 1300,
    location: '/work?open=s2',
  );
  return composer;
}

Future<void> _type(WidgetTester tester, String text) async {
  await tester.enterText(find.byKey(const Key('composer-field')), text);
  await tester.pump();
}

Future<void> _send(WidgetTester tester) async {
  await tester.tap(find.byTooltip('Send'));
  await tester.pumpAndSettle();
}

String _fieldText(WidgetTester tester) => tester
    .widget<TextField>(find.byKey(const Key('composer-field')))
    .controller!
    .text;

void main() {
  group('commands', () {
    appTest('an idle session gets a prompt with the binding', (tester) async {
      final c = await _open(tester);
      await _type(tester, 'Hello there');
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('${PrefKeys.draftPrefix}s2'), 'Hello there');
      await _send(tester);
      expect(c.payloads.single, {'type': 'prompt', 'message': 'Hello there'});
      expect(c.lastBody['expectedBinding'], _binding);
      expect((c.lastBody['clientId'] as String), isNotEmpty);
      expect(_fieldText(tester), '');
      expect(prefs.getString('${PrefKeys.draftPrefix}s2'), isNull);
    });

    appTest('while a run is active: steer, queue and stop', (tester) async {
      final c = await _open(tester, running: true);
      expect(find.text('Stop this work'), findsOneWidget);
      await _type(tester, 'Also check B');
      await _send(tester);
      await tester.tap(find.text('Queue'));
      await tester.pump();
      await _type(tester, 'Then C');
      await _send(tester);
      await tester.tap(find.text('Stop this work'));
      await tester.pumpAndSettle();
      expect(
        [for (final p in c.payloads) p['type']],
        ['steer', 'follow_up', 'stop'],
      );
      final stop = c.gateway.sent('POST', '/api/sessions/s2/commands').last;
      expect((stop.json! as Map).containsKey('expectedBinding'), isFalse);
    });

    appTest('stop returns the cleared queue text to the draft', (tester) async {
      await _open(tester, running: true, queue: ['first', 'second']);
      await _type(tester, 'draft');
      await tester.tap(find.text('Stop this work'));
      await tester.pumpAndSettle();
      expect(_fieldText(tester), 'draft\n\nfirst\n\nsecond');
    });

    appTest('the model sheet sends set_model and set_thinking', (tester) async {
      final c = await _open(tester);
      await tester.tap(find.byKey(const Key('model-button')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Model'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Small'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('model-button')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Thinking'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('High'));
      await tester.pumpAndSettle();
      expect(c.payloads, [
        {'type': 'set_model', 'provider': 'local', 'modelId': 'small'},
        {'type': 'set_thinking', 'level': 'high'},
      ]);
    });

    appTest('a model without thinking disables the Thinking row', (
      tester,
    ) async {
      final c = _Composer();
      c.session.snapshot['agent'] = {
        'model': {'provider': 'local', 'id': 'small'},
      };
      await pumpApp(tester, gateway: c.gateway, location: '/work?open=s2');
      await tester.tap(find.byKey(const Key('model-button')));
      await tester.pumpAndSettle();
      final row = tester.widget<ListTile>(
        find.ancestor(
          of: find.text('Thinking'),
          matching: find.byType(ListTile),
        ),
      );
      expect(row.enabled, isFalse);
      expect(find.text('This model has no thinking levels'), findsOneWidget);
    });
  });

  appTest('a refused upload keeps the draft and sends nothing', (tester) async {
    final c = _Composer();
    c.gateway.json['POST /api/sessions/s2/uploads'] = (_) =>
        apiError(413, 'payload_too_large', 'Upload exceeds configured limit');
    await pumpApp(
      tester,
      gateway: c.gateway,
      location: '/work?open=s2',
      overrides: [
        filePickerProvider.overrideWithValue(
          () async => [
            PendingAttachment(
              id: 'a1',
              name: 'big.png',
              mimeType: 'image/png',
              bytes: Uint8List(4),
            ),
          ],
        ),
      ],
    );
    await tester.tap(find.byTooltip('Attach files'));
    await tester.pumpAndSettle();
    await _type(tester, 'See this');
    await _send(tester);
    expect(find.text('Upload exceeds configured limit'), findsOneWidget);
    expect(_fieldText(tester), 'See this');
    expect(find.text('big.png'), findsOneWidget);
    expect(c.payloads, isEmpty);
  });

  appTest('a stale binding keeps the draft and loads a new snapshot', (
    tester,
  ) async {
    final c = await _open(tester);
    c.commandReply = (_) => apiError(409, 'stale_environment', 'moved');
    final snapshots = c.gateway.sent('GET', '/api/sessions/s2/snapshot').length;
    await _type(tester, 'Keep me');
    await _send(tester);
    expect(_fieldText(tester), 'Keep me');
    expect(
      c.gateway.sent('GET', '/api/sessions/s2/snapshot').length,
      snapshots + 1,
    );
    expect(
      find.text("The work's environment changed. Your draft is kept."),
      findsOneWidget,
    );
  });

  group('an uncertain command', () {
    Future<(_Composer, String)> uncertain(WidgetTester tester) async {
      final c = await _open(tester);
      c.commandReply = (_) => throw const TransportException('dropped');
      await _type(tester, 'Maybe sent');
      await _send(tester);
      final id = c.lastBody['commandId'] as String;
      expect(find.text('Not sure it arrived'), findsOneWidget);
      expect(_fieldText(tester), '', reason: 'never sent again by accident');
      final send = tester.widget<IconButton>(
        find
            .ancestor(
              of: find.byTooltip('Send'),
              matching: find.byType(IconButton),
            )
            .first,
      );
      expect(send.onPressed, isNull);
      return (c, id);
    }

    appTest('is never resent; Check status settles it', (tester) async {
      final (c, id) = await uncertain(tester);
      c.gateway.json['GET /api/sessions/s2/commands/$id'] = (_) => {
        'command': {'id': id, 'sessionId': 's2', 'status': 'accepted'},
      };
      await tester.tap(find.text('Check status'));
      await tester.pumpAndSettle();
      expect(find.text('Not sure it arrived'), findsNothing);
      expect(c.payloads, hasLength(1));
      expect(_fieldText(tester), '');
    });

    appTest('one that never arrived returns to the draft', (tester) async {
      final (c, id) = await uncertain(tester);
      c.gateway.json['GET /api/sessions/s2/commands/$id'] = (_) =>
          apiError(404, 'not_found');
      await tester.tap(find.text('Check status'));
      await tester.pumpAndSettle();
      expect(_fieldText(tester), 'Maybe sent');
      expect(c.payloads, hasLength(1));
    });
  });

  group('first send', () {
    /// A Gateway with one project on an online host and one offline.
    FakeGateway gateway({
      Object? Function(ApiRequest request)? dispatch,
      Object? Function(ApiRequest request)? prepare,
    }) {
      final g = FakeGateway();
      g.json['GET /api/sessions'] = (_) => {'sessions': <Object?>[]};
      g.json['GET /api/nodes'] = (_) => {
        'nodes': [
          {'id': 'laptop', 'workspaces': <Object?>[]},
        ],
      };
      g.json['GET /api/workspaces'] = (_) => {
        'workspaces': [
          {'id': 'laptop:pirc', 'hostId': 'h', 'displayName': 'pirc'},
          {'id': 'nas:photos', 'hostId': 'h2', 'displayName': 'Photos'},
        ],
      };
      g.json['GET /api/models'] = (_) => {'models': _models};
      g.json['POST /api/sessions/new-s/control/acquire'] = (_) => {
        'lease': {'clientId': 'me', 'generation': 1},
      };
      Map<String, Object?> preparation(String op, String state, [Map? extra]) =>
          {
            'preparation': {
              'operationId': op,
              'state': state,
              'sessionId': 'new-s',
              'workspaceId': 'laptop:pirc',
              ...?extra,
            },
          };
      g.routes.add((request) {
        final match = RegExp(
          r'^/api/conversation-submissions/(?:([^/]+)/)?([a-z/-]+)$',
        ).firstMatch(request.path);
        if (match == null) return null;
        final op =
            match[1] ??
            ((request.json as Map?)?['operationId'] as String?) ??
            '';
        final Object? value = switch (match[2]) {
          'prepare' => prepare?.call(request) ?? preparation(op, 'preparing'),
          'accept' => preparation(op, 'accepted'),
          'materialize' => preparation(op, 'ready'),
          'dispatch' => dispatch?.call(request) ?? preparation(op, 'admitted'),
          'receipt' => preparation(op, 'admitted'),
          'retry' => preparation(op, 'admitted'),
          _ => null,
        };
        if (value == null) return null;
        return value is ApiResponse ? value : reply(200, value);
      });
      return g;
    }

    Future<void> compose(WidgetTester tester, FakeGateway g) async {
      await pumpApp(tester, gateway: g, width: 1300, location: '/work');
      await tester.tap(find.byTooltip('New conversation'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('workspace-row')));
      await tester.pumpAndSettle();
      // The offline host is listed with its reason and cannot be picked.
      expect(find.text('nas · offline'), findsOneWidget);
      final photos = tester.widget<ListTile>(
        find.ancestor(of: find.text('Photos'), matching: find.byType(ListTile)),
      );
      expect(photos.enabled, isFalse);
      await tester.tap(find.text('pirc').last);
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('new-conversation-field')),
        'Start here',
      );
      await tester.pump();
      await tester.tap(find.byTooltip('Send'));
      await tester.pumpAndSettle();
    }

    String location(WidgetTester tester) => GoRouterHelper.locationOf(tester);

    appTest('admitted: the conversation opens', (tester) async {
      final g = gateway();
      await compose(tester, g);
      final prepare = g.requests.firstWhere((r) => r.path.endsWith('/prepare'));
      expect(
        ((prepare.json! as Map)['submission'] as Map)['message'],
        'Start here',
      );
      expect(g.requests.any((r) => r.path.endsWith('/dispatch')), isTrue);
      expect(location(tester), '/work?open=new-s');
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(PrefKeys.firstSendJournal), isNull);
    });

    appTest('uncertain: Check status reads the receipt, never resends', (
      tester,
    ) async {
      final g = gateway(
        dispatch: (_) => throw const TransportException('dropped'),
      );
      await compose(tester, g);
      expect(find.text('Not sure it arrived'), findsOneWidget);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(PrefKeys.firstSendJournal), isNotNull);
      await tester.tap(find.text('Check status'));
      await tester.pumpAndSettle();
      expect(
        g.requests.where((r) => r.path.endsWith('/dispatch')),
        hasLength(1),
      );
      expect(g.requests.any((r) => r.path.endsWith('/receipt')), isTrue);
      expect(location(tester), '/work?open=new-s');
    });

    appTest('refused: Send again is a separate retry', (tester) async {
      final g = gateway(
        dispatch: (request) => {
          'preparation': {
            'operationId': request.path.split('/')[3],
            'state': 'admission_failed',
            'sessionId': 'new-s',
            'messageAdmission': {'commandId': 'c1', 'retryEligible': true},
          },
        },
      );
      await compose(tester, g);
      expect(find.text('The first message was refused.'), findsOneWidget);
      expect(g.requests.any((r) => r.path.endsWith('/retry')), isFalse);
      await tester.tap(find.text('Send again'));
      await tester.pumpAndSettle();
      final retry = g.requests.firstWhere((r) => r.path.endsWith('/retry'));
      expect((retry.json! as Map)['previousCommandId'], 'c1');
      expect(location(tester), '/work?open=new-s');
    });

    appTest('a failure before the send says it was not sent', (tester) async {
      final g = gateway(
        prepare: (_) => apiError(503, 'node_offline', 'The host is offline'),
      );
      await compose(tester, g);
      expect(find.text('Not sent.'), findsOneWidget);
      expect(find.text('The host is offline'), findsOneWidget);
    });

    appTest('a restart with an open operation checks it', (tester) async {
      final g = gateway();
      await pumpApp(
        tester,
        gateway: g,
        width: 1300,
        location: '/work?open=new',
        saved: Saved(
          prefs: {
            PrefKeys.gatewayUrl: 'https://gateway.test/',
            PrefKeys.firstSendJournal: jsonEncode({
              'operationId': 'op-open',
              'workspaceId': 'laptop:pirc',
              'message': 'Before the restart',
            }),
          },
        ),
      );
      expect(
        g.requests.any(
          (r) => r.path == '/api/conversation-submissions/op-open/receipt',
        ),
        isTrue,
      );
      expect(g.requests.any((r) => r.path.endsWith('/dispatch')), isFalse);
      expect(location(tester), '/work?open=new-s');
    });
  });
}

/// The router's current location.
abstract final class GoRouterHelper {
  static String locationOf(WidgetTester tester) {
    final context = tester.element(find.byType(Navigator).first);
    return GoRouter.of(context).routeInformationProvider.value.uri.toString();
  }
}
