import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_app/src/work/conversation_screen.dart';
import 'package:pirc_app/src/work/timeline.dart';
import 'package:pirc_client/pirc_client.dart';

import 'support/harness.dart';

Map<String, Object?> _fixture(String name) =>
    jsonDecode(File('../../fixtures/timeline/$name').readAsStringSync())
        as Map<String, Object?>;

/// A Gateway serving one session from a timeline fixture, with a lease
/// holder the test sets.
class _Session {
  _Session(this.name) : fixture = _fixture(name) {
    snapshot = fixture['snapshot']! as Map<String, Object?>;
    id = (snapshot['session']! as Map)['id'] as String;
  }

  final String name;
  final Map<String, Object?> fixture;
  late Map<String, Object?> snapshot;
  late final String id;

  /// The lease the control route reports; null when nobody holds it.
  Map<String, Object?>? lease;
  int generation = 0;
  bool heartbeatLost = false;

  List<Object?> get events => fixture['events']! as List<Object?>;

  FakeGateway install([FakeGateway? into]) {
    final gateway = into ?? FakeGateway();
    final base = '/api/sessions/$id';
    gateway.json['GET /api/sessions'] = (_) => {
      'sessions': [snapshot['session']],
    };
    gateway.json['GET $base/snapshot'] = (_) => snapshot;
    gateway.json['GET $base/control'] = (_) => {'lease': lease};
    gateway.json['POST $base/control/acquire'] = (request) {
      final body = request.json! as Map;
      if (lease != null &&
          lease!['clientId'] != body['clientId'] &&
          body['force'] != true) {
        return apiError(409, 'lost_control', 'Another client has control');
      }
      lease = {
        'clientId': body['clientId'],
        'generation': ++generation,
        'expiresAt': 0,
      };
      return {'lease': lease};
    };
    gateway.json['POST $base/control/heartbeat'] = (request) => heartbeatLost
        ? apiError(409, 'lost_control', 'Another client has control')
        : {'lease': lease};
    gateway.json['POST $base/control/release'] = (_) => {'released': true};
    return gateway;
  }
}

Future<FakeGateway> _open(
  WidgetTester tester,
  _Session session, {
  double width = 1300,
}) async {
  final gateway = session.install();
  await pumpApp(
    tester,
    gateway: gateway,
    width: width,
    location: '/work?open=${session.id}',
  );
  return gateway;
}

FakeEventSocket _events(FakeGateway gateway) => gateway.socket('/api/events')!;

void main() {
  for (final name in [
    'streaming-turn.json',
    'joined-mid-stream.json',
    'ptc-operations.json',
  ]) {
    appTest('$name replays into the screen', (tester) async {
      final session = _Session(name);
      final gateway = await _open(tester, session);
      final socket = _events(gateway);
      final watermark = session.snapshot['watermark']! as Map;
      expect(socket.target.queryParameters, {
        'sessionId': session.id,
        'cursor': '${watermark['epoch']}:${watermark['sequence']}',
      });
      // The client's reducer (checked against the web client in
      // pirc_client) up to the first event that needs a new snapshot.
      var state = snapshotState(session.snapshot);
      Object? trigger;
      for (final event in session.events) {
        final next = reduceEvent(state, normalizeEvent(event));
        if (next.needsSnapshot) {
          trigger = event;
          break;
        }
        state = next;
        socket.push(event);
      }
      await tester.pumpAndSettle();
      final timeline = tester.widget<WorkTimeline>(find.byType(WorkTimeline));
      expect(
        [for (final m in timeline.messages) (m.role, m.content)],
        [for (final m in state.messages) (m.role, m.content)],
      );
      final user = state.messages.firstWhere((m) => m.role == 'user');
      expect(
        find.textContaining(user.content, findRichText: true),
        findsWidgets,
      );
      if (trigger == null) {
        // ptc-operations: every event applies; the end state is the web's.
        final expected =
            (session.fixture['expected']! as Map)['afterEvents']! as Map;
        expect(
          [for (final m in timeline.messages) m.content],
          [
            for (final m in (expected['messages']! as List).cast<Map>())
              m['content'] ?? '',
          ],
        );
      } else {
        final path = '/api/sessions/${session.id}/snapshot';
        final before = gateway.sent('GET', path).length;
        socket.push(trigger);
        await tester.pumpAndSettle();
        expect(gateway.sent('GET', path).length, before + 1);
      }
    });
  }

  appTest('tool steps fold into a run card with failures marked', (
    tester,
  ) async {
    final session = _Session('ptc-operations.json');
    final gateway = await _open(tester, session);
    for (final event in session.events) {
      _events(gateway).push(event);
    }
    await tester.pumpAndSettle();
    expect(find.byType(RunCard), findsWidgets);
    expect(find.textContaining('tool step'), findsWidgets);
  });

  appTest('a reset loads a new snapshot and resumes from its watermark', (
    tester,
  ) async {
    final session = _Session('joined-mid-stream.json');
    final gateway = await _open(tester, session);
    final snapshots = gateway.sent('GET', '/api/sessions/s2/snapshot').length;
    _events(gateway).push({
      'type': 'reset',
      'reason': 'cursor_expired',
      'watermark': {'epoch': 1, 'sequence': 4},
    });
    await tester.pumpAndSettle();
    expect(
      gateway.sent('GET', '/api/sessions/s2/snapshot').length,
      snapshots + 1,
    );
    expect(_events(gateway).target.queryParameters['cursor'], '1:4');
  });

  appTest('a dropped socket reconnects from the last event', (tester) async {
    final session = _Session('joined-mid-stream.json');
    final gateway = await _open(tester, session);
    final first = _events(gateway);
    first.push(session.events.first);
    await tester.pump();
    first.serverClose(1006);
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();
    final again = _events(gateway);
    expect(again, isNot(same(first)));
    expect(again.target.queryParameters['cursor'], '1:5');
  });

  appTest('an event from another epoch loads a new snapshot', (tester) async {
    final session = _Session('joined-mid-stream.json');
    final gateway = await _open(tester, session);
    final snapshots = gateway.sent('GET', '/api/sessions/s2/snapshot').length;
    _events(gateway).push({
      'sessionId': 's2',
      'epoch': 9,
      'sequence': 1,
      'type': 'pi_event',
      'timestamp': 1,
      'data': {'type': 'agent_start'},
    });
    await tester.pumpAndSettle();
    expect(
      gateway.sent('GET', '/api/sessions/s2/snapshot').length,
      greaterThan(snapshots),
    );
  });

  group('control', () {
    appTest('a free lease is taken on open', (tester) async {
      final session = _Session('joined-mid-stream.json');
      final gateway = await _open(tester, session);
      expect(
        gateway.sent('POST', '/api/sessions/s2/control/acquire'),
        hasLength(1),
      );
      expect(find.byType(ControlBar), findsNothing);
    });

    appTest('another holder makes it read-only; Take control forces', (
      tester,
    ) async {
      final session = _Session('joined-mid-stream.json')
        ..lease = {'clientId': 'other-phone', 'generation': 4};
      final gateway = await _open(tester, session);
      expect(find.text('Controlled by another device'), findsOneWidget);
      expect(gateway.sent('POST', '/api/sessions/s2/control/acquire'), isEmpty);
      await tester.tap(find.text('Take control'));
      await tester.pumpAndSettle();
      final acquire = gateway.sent('POST', '/api/sessions/s2/control/acquire');
      expect((acquire.single.json! as Map)['force'], isTrue);
      expect(find.byType(ControlBar), findsNothing);
    });

    appTest('losing the lease on a heartbeat shows the bar', (tester) async {
      final session = _Session('joined-mid-stream.json');
      final gateway = await _open(tester, session);
      expect(find.byType(ControlBar), findsNothing);
      session
        ..heartbeatLost = true
        ..lease = {'clientId': 'other-phone', 'generation': 9};
      await tester.pump(const Duration(seconds: 10));
      await tester.pumpAndSettle();
      expect(
        gateway.sent('POST', '/api/sessions/s2/control/heartbeat'),
        hasLength(1),
      );
      expect(find.text('Controlled by another device'), findsOneWidget);
    });

    appTest('closing the conversation releases the lease', (tester) async {
      final session = _Session('joined-mid-stream.json');
      final gateway = await _open(tester, session, width: 375);
      await tester.tap(find.byTooltip('Back'));
      await tester.pumpAndSettle();
      expect(
        gateway.sent('POST', '/api/sessions/s2/control/release'),
        hasLength(1),
      );
      expect(_events(gateway).closedByClient, isTrue);
    });
  });

  appTest('a deleted session says so', (tester) async {
    final session = _Session('joined-mid-stream.json');
    final gateway = await _open(tester, session);
    _events(gateway).push({
      'sessionId': 's2',
      'epoch': 1,
      'sequence': 5,
      'type': 'session_deleted',
      'timestamp': 1,
    });
    await tester.pumpAndSettle();
    expect(find.text('This work was deleted.'), findsOneWidget);
  });

  appTest('the top bar shows the project and the host; no back at 1300', (
    tester,
  ) async {
    final session = _Session('joined-mid-stream.json');
    final gateway = session.install()
      ..json['GET /api/workspaces'] = (_) => {
        'workspaces': [
          {
            'id': (session.snapshot['session']! as Map)['workspaceId'],
            'hostId': 'h',
            'displayName': 'pirc mobile',
          },
        ],
      };
    await pumpApp(tester, gateway: gateway, location: '/work?open=s2');
    expect(find.textContaining('pirc mobile'), findsWidgets);
    expect(
      find.descendant(
        of: find.byType(ConversationScreen),
        matching: find.byTooltip('Back'),
      ),
      findsNothing,
    );
  });
}
