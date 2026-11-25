import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_app/src/work/conversation_screen.dart';
import 'package:pirc_app/src/work/timeline.dart';
import 'package:pirc_client/pirc_client.dart';

import 'support/harness.dart';
import 'support/session_fixture.dart';

Future<FakeGateway> _open(
  WidgetTester tester,
  FixtureSession session, {
  double width = 1300,
  double height = 900,
}) async {
  final gateway = session.install();
  await pumpApp(
    tester,
    gateway: gateway,
    width: width,
    height: height,
    location: '/work?open=${session.id}',
  );
  return gateway;
}

FakeEventSocket _events(FakeGateway gateway) => gateway.socket('/api/events')!;

void main() {
  _retrySnapshotTests();
  for (final name in [
    'streaming-turn.json',
    'joined-mid-stream.json',
    'ptc-operations.json',
  ]) {
    appTest('$name replays into the screen', (tester) async {
      final session = FixtureSession(name);
      final gateway = await _open(tester, session, height: 3000);
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
    final session = FixtureSession('ptc-operations.json');
    final gateway = await _open(tester, session);
    for (final event in session.events) {
      _events(gateway).push(event);
    }
    await tester.pumpAndSettle();
    expect(find.byType(RunCard), findsWidgets);
    expect(find.textContaining('tool step'), findsWidgets);
  });

  appTest('images in a message and in a tool result are shown', (tester) async {
    // A 1×1 PNG.
    const png =
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==';
    final session = FixtureSession('joined-mid-stream.json');
    (session.snapshot['history']! as List).addAll([
      {
        'role': 'user',
        'content': [
          {'type': 'text', 'text': 'What is in this picture?'},
          {'type': 'image', 'mimeType': 'image/png', 'data': png},
        ],
        'timestamp': 1500,
      },
      {
        'role': 'assistant',
        'content': [
          {
            'type': 'toolCall',
            'id': 'shot',
            'name': 'browser',
            'arguments': {'action': 'screenshot'},
          },
        ],
        'stopReason': 'toolUse',
        'timestamp': 1600,
      },
      {
        'role': 'toolResult',
        'toolCallId': 'shot',
        'toolName': 'browser',
        'content': [
          {'type': 'image', 'mimeType': 'image/png', 'data': png},
          {'type': 'image', 'mimeType': 'image/png', 'data': '%%%'},
        ],
        'timestamp': 1700,
      },
    ]);
    await _open(tester, session, height: 3000);
    await tester.pumpAndSettle();
    final images = find.descendant(
      of: find.byType(InlineImages),
      matching: find.byWidgetPredicate(
        (w) => w is Image && w.image is MemoryImage,
      ),
    );
    // The user's image, and the tool's while its steps are folded.
    expect(images, findsNWidgets(2));
    expect(find.text('This image cannot be shown.'), findsOneWidget);
    await tester.ensureVisible(images.last);
    await tester.pumpAndSettle();
    await tester.tap(images.last);
    await tester.pumpAndSettle();
    expect(find.byType(InteractiveViewer), findsOneWidget);
  });

  appTest('a reset loads a new snapshot and resumes from its watermark', (
    tester,
  ) async {
    final session = FixtureSession('joined-mid-stream.json');
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
    final session = FixtureSession('joined-mid-stream.json');
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
    final session = FixtureSession('joined-mid-stream.json');
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
      final session = FixtureSession('joined-mid-stream.json');
      final gateway = await _open(tester, session);
      expect(
        gateway.sent('POST', '/api/sessions/s2/control/acquire'),
        hasLength(1),
      );
    });

    appTest('another holder keeps the composer usable', (tester) async {
      final session = FixtureSession('joined-mid-stream.json')
        ..lease = {'clientId': 'other-phone', 'generation': 4};
      final gateway = await _open(tester, session);
      final field = tester.widget<TextField>(
        find.byKey(const Key('composer-field')),
      );
      expect(field.enabled, isTrue);
      expect(find.text('Take control'), findsNothing);
      expect(gateway.sent('POST', '/api/sessions/s2/control/acquire'), isEmpty);
    });

    appTest('a control_changed event gives the new holder notice', (
      tester,
    ) async {
      final session = FixtureSession('joined-mid-stream.json');
      final gateway = await _open(tester, session);
      _events(gateway).push({
        'sessionId': 's2',
        'epoch': 1,
        'sequence': 99,
        'type': 'control_changed',
        'timestamp': 1,
        'data': {
          'clientId': 'other-phone',
          'holder': {'name': 'Pixel 9', 'kind': 'device', 'lastActionAt': 1700},
        },
      });
      await tester.pumpAndSettle();
      expect(find.text('Continued on Pixel 9'), findsOneWidget);
      final field = tester.widget<TextField>(
        find.byKey(const Key('composer-field')),
      );
      expect(field.enabled, isTrue);
    });

    appTest('a control_changed event without a holder resolves its name', (
      tester,
    ) async {
      final session = FixtureSession('joined-mid-stream.json');
      final gateway = await _open(tester, session);
      gateway.json['GET /api/clients'] = (_) => {
        'clients': [
          {
            'clientId': 'other-phone',
            'name': 'Office iMac',
            'kind': 'browser',
            'lastSeenAt': 2,
          },
        ],
      };
      _events(gateway).push({
        'sessionId': 's2',
        'epoch': 1,
        'sequence': 99,
        'type': 'control_changed',
        'timestamp': 1,
        'data': {'clientId': 'other-phone', 'holder': null},
      });
      await tester.pumpAndSettle();
      expect(gateway.sent('GET', '/api/clients'), hasLength(1));
      expect(find.text('Continued on Office iMac'), findsOneWidget);
    });

    appTest('releasing control clears the notice', (tester) async {
      final session = FixtureSession('joined-mid-stream.json');
      final gateway = await _open(tester, session);
      final socket = _events(gateway);
      socket.push({
        'sessionId': 's2',
        'epoch': 1,
        'sequence': 98,
        'type': 'control_changed',
        'timestamp': 1,
        'data': {
          'clientId': 'other-phone',
          'holder': {'name': 'Pixel 9', 'kind': 'device', 'lastActionAt': 1},
        },
      });
      await tester.pumpAndSettle();
      expect(find.text('Continued on Pixel 9'), findsOneWidget);
      socket.push({
        'sessionId': 's2',
        'epoch': 1,
        'sequence': 99,
        'type': 'control_changed',
        'timestamp': 1,
        'data': {'clientId': null, 'holder': null},
      });
      await tester.pumpAndSettle();
      expect(find.text('Continued on Pixel 9'), findsNothing);
    });

    appTest('losing the lease on a heartbeat keeps the composer usable', (
      tester,
    ) async {
      final session = FixtureSession('joined-mid-stream.json');
      final gateway = await _open(tester, session);
      session
        ..heartbeatLost = true
        ..lease = {'clientId': 'other-phone', 'generation': 9};
      await tester.pump(const Duration(seconds: 10));
      await tester.pumpAndSettle();
      expect(
        gateway.sent('POST', '/api/sessions/s2/control/heartbeat'),
        hasLength(1),
      );
      final field = tester.widget<TextField>(
        find.byKey(const Key('composer-field')),
      );
      expect(field.enabled, isTrue);
    });

    appTest('closing the conversation releases the lease', (tester) async {
      final session = FixtureSession('joined-mid-stream.json');
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
    final session = FixtureSession('joined-mid-stream.json');
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
    final session = FixtureSession('joined-mid-stream.json');
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

void _retrySnapshotTests() {
  appTest('a first snapshot that failed opens the session on Try again', (
    tester,
  ) async {
    final session = FixtureSession('joined-mid-stream.json');
    final gateway = session.install();
    var failing = true;
    gateway.json['GET /api/sessions/${session.id}/snapshot'] = (_) => failing
        ? apiError(503, 'node_offline', 'The node is offline')
        : session.snapshot;
    await pumpApp(
      tester,
      gateway: gateway,
      width: 1300,
      height: 900,
      location: '/work?open=${session.id}',
    );
    expect(gateway.socket('/api/events'), isNull);
    failing = false;
    await tester.tap(find.text('Try again'));
    await tester.pumpAndSettle();
    expect(gateway.socket('/api/events'), isNotNull);
  });
}
