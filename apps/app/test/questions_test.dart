import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_app/src/connection/storage.dart';
import 'package:pirc_app/src/format.dart';
import 'package:pirc_app/src/work/questions.dart';

import 'support/harness.dart';
import 'support/session_fixture.dart';

final _now = DateTime(2026, 11, 25, 11);
int _in(Duration d) => _now.add(d).millisecondsSinceEpoch;

Map<String, Object?> _question(
  String id,
  String kind, {
  Map<String, Object?> request = const {},
  int? expiresAt,
  String status = 'pending',
  String? answeredBy,
  int? resolvedAt,
}) => {
  'id': id,
  'kind': kind,
  'runnerEpoch': 1,
  'status': status,
  'answeredBy': ?answeredBy,
  'resolvedAt': ?resolvedAt,
  'expiresAt': expiresAt ?? _in(const Duration(minutes: 14)),
  'request': {'title': 'Q $id', 'message': 'Why $id', ...request},
};

Future<FixtureSession> _open(
  WidgetTester tester,
  List<Map<String, Object?>> questions, {
  Map<String, Object?>? lease,
  Map<String, Object?>? agent,
  List<Map<String, Object?>>? clients,
}) async {
  final session = FixtureSession('joined-mid-stream.json')
    ..lease = lease
    ..snapshot['interactions'] = questions;
  if (agent != null) session.snapshot['agent'] = agent;
  final gateway = session.install();
  session.gateway = gateway;
  if (clients != null) {
    gateway.json['GET /api/clients'] = (_) => {'clients': clients};
  }
  gateway.routes.add((request) {
    if (request.path.contains('/interactions/') &&
        request.path.endsWith('/answer')) {
      return reply(200, {'ok': true});
    }
    return null;
  });
  await pumpApp(
    tester,
    gateway: gateway,
    location: '/work?open=s2',
    saved: Saved(
      prefs: {
        PrefKeys.gatewayUrl: 'https://gateway.test/',
        PrefKeys.clientId: 'me',
      },
    ),
    overrides: [clockProvider.overrideWithValue(() => _now)],
  );
  return session;
}

Map _answer(FixtureSession s, String id) =>
    s.gateway!.requests
            .lastWhere(
              (r) => r.path == '/api/sessions/s2/interactions/$id/answer',
            )
            .json!
        as Map;

void main() {
  appTest('select: one option', (tester) async {
    final s = await _open(tester, [
      _question(
        'q1',
        'select',
        request: {
          'options': ['Only the 3 failures', 'All of them'],
        },
      ),
    ]);
    expect(find.text('Q q1'), findsOneWidget);
    await tester.tap(find.text('Only the 3 failures'));
    await tester.pump();
    await tester.tap(find.byKey(const Key('send-answer-q1')));
    await tester.pumpAndSettle();
    final body = _answer(s, 'q1');
    expect(body['answer'], {'value': 'Only the 3 failures'});
    expect(body['clientId'], 'me');
    expect(body.containsKey('generation'), isFalse);
    // Answered: one summary line until the snapshot reports its end.
    expect(find.text('Q q1 · Only the 3 failures'), findsOneWidget);
  });

  appTest('select: several options', (tester) async {
    final s = await _open(tester, [
      _question(
        'q2',
        'select',
        request: {
          'multiple': true,
          'options': ['a', 'b', 'c'],
        },
      ),
    ]);
    await tester.tap(find.text('a'));
    await tester.tap(find.text('c'));
    await tester.pump();
    await tester.tap(find.byKey(const Key('send-answer-q2')));
    await tester.pumpAndSettle();
    expect(_answer(s, 'q2')['answer'], {
      'value': 'a, c',
      'values': ['a', 'c'],
    });
  });

  appTest('confirm: yes and no labels', (tester) async {
    final s = await _open(tester, [
      _question(
        'q3',
        'confirm',
        request: {'confirmLabel': 'Delete', 'cancelLabel': 'Keep'},
      ),
    ]);
    await tester.tap(find.text('Keep'));
    await tester.pumpAndSettle();
    expect(_answer(s, 'q3')['answer'], {'confirmed': false});
  });

  appTest('input and editor send their text; skip cancels', (tester) async {
    final s = await _open(tester, [
      _question('q4', 'input', request: {'placeholder': 'Branch name'}),
      _question('q5', 'editor', request: {'prefill': 'line 1'}),
    ]);
    await tester.enterText(find.byKey(const Key('answer-q4')), 'fix/login');
    await tester.pump();
    await tester.tap(find.byKey(const Key('send-answer-q4')));
    await tester.pumpAndSettle();
    expect(_answer(s, 'q4')['answer'], {'value': 'fix/login'});
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('answer-q5')))
          .controller!
          .text,
      'line 1',
    );
    final skip = find.descendant(
      of: find.byKey(const ValueKey('q-q5')),
      matching: find.text('Skip'),
    );
    await tester.ensureVisible(skip);
    await tester.pumpAndSettle();
    await tester.tap(skip);
    await tester.pumpAndSettle();
    expect(_answer(s, 'q5')['answer'], {'cancelled': true});
  });

  appTest('an expired question has no buttons', (tester) async {
    await _open(tester, [
      _question('q6', 'confirm', expiresAt: _in(const Duration(minutes: -1))),
    ]);
    expect(find.text('Expired'), findsOneWidget);
    expect(find.text('Yes'), findsNothing);
    expect(find.text('No'), findsNothing);
  });

  appTest('any device may answer without holding control', (tester) async {
    final s = await _open(
      tester,
      [_question('q7', 'confirm')],
      lease: {'clientId': 'other-phone', 'generation': 4},
    );
    expect(find.text('Take control'), findsNothing);
    final yes = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Yes'),
    );
    expect(yes.onPressed, isNotNull);
    await tester.tap(find.text('Yes'));
    await tester.pumpAndSettle();
    final body = _answer(s, 'q7');
    expect(body['clientId'], 'me');
    expect(body['answer'], {'confirmed': true});
    expect(body.containsKey('generation'), isFalse);
    expect(
      s.gateway!.sent('POST', '/api/sessions/s2/control/acquire'),
      isEmpty,
    );
  });

  appTest('an answer refused by a lost pairing is not shown as answered', (
    tester,
  ) async {
    final s = await _open(tester, [_question('q9', 'confirm')]);
    s.gateway!.json['POST /api/sessions/s2/interactions/q9/answer'] = (_) =>
        apiError(401, 'unauthorized', 'Pair this device again');
    await tester.tap(find.text('Yes'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Q q9 · '), findsNothing);
  });

  appTest('a second answer is refused and shows how the question ended', (
    tester,
  ) async {
    final s = await _open(
      tester,
      [_question('q8', 'confirm')],
      clients: [
        {
          'clientId': 'other-phone',
          'name': 'Pixel 9',
          'kind': 'device',
          'lastSeenAt': 1,
        },
      ],
    );
    s.snapshot['interactions'] = [
      _question(
        'q8',
        'confirm',
        status: 'answered',
        answeredBy: 'other-phone',
        resolvedAt: _in(const Duration(minutes: 2)),
      ),
    ];
    s.gateway!.json['POST /api/sessions/s2/interactions/q8/answer'] = (_) =>
        apiError(409, 'stale_interaction', 'Interaction was already answered');
    await tester.tap(find.text('Yes'));
    await tester.pumpAndSettle();
    expect(find.byType(QuestionCard), findsNothing);
    expect(find.text('Answered on Pixel 9 · 11:02'), findsOneWidget);
    expect(find.textContaining('already answered'), findsNothing);
  });

  appTest('an interaction_answered event carries the end state', (
    tester,
  ) async {
    final s = await _open(
      tester,
      [_question('qe', 'confirm')],
      clients: [
        {
          'clientId': 'other-phone',
          'name': 'Pixel 9',
          'kind': 'device',
          'lastSeenAt': 1,
        },
      ],
    );
    s.gateway!.socket('/api/events')!.push({
      'sessionId': 's2',
      'epoch': 1,
      'sequence': 5,
      'type': 'interaction_answered',
      'timestamp': 1,
      'data': {
        'interactionId': 'qe',
        'interactionEpoch': 1,
        'status': 'answered',
        'answeredBy': 'other-phone',
        'resolvedAt': _in(const Duration(minutes: 2)),
      },
    });
    await tester.pumpAndSettle();
    expect(find.byType(QuestionCard), findsNothing);
    expect(find.text('Answered on Pixel 9 · 11:02'), findsOneWidget);
  });

  appTest('every end state comes from the backend', (tester) async {
    await _open(
      tester,
      [
        _question(
          'qa',
          'confirm',
          status: 'answered',
          answeredBy: 'other-phone',
          resolvedAt: _in(const Duration(minutes: 2)),
        ),
        _question(
          'qm',
          'confirm',
          status: 'answered',
          answeredBy: 'me',
          resolvedAt: _in(const Duration(minutes: 1)),
        ),
        _question(
          'qc',
          'confirm',
          status: 'cancelled',
          resolvedAt: _in(Duration.zero),
        ),
        _question(
          'qe',
          'confirm',
          status: 'expired',
          resolvedAt: _in(Duration.zero),
        ),
        _question(
          'qs',
          'confirm',
          status: 'stale',
          resolvedAt: _in(Duration.zero),
        ),
      ],
      clients: [
        {
          'clientId': 'other-phone',
          'name': 'Pixel 9',
          'kind': 'device',
          'lastSeenAt': 1,
        },
      ],
    );
    await tester.pumpAndSettle();
    expect(find.text('Answered on Pixel 9 · 11:02'), findsOneWidget);
    expect(find.text('Q qm · Answered'), findsOneWidget);
    expect(find.text('Withdrawn'), findsOneWidget);
    expect(find.text('Expired'), findsOneWidget);
    expect(find.text('Ended when the session restarted'), findsOneWidget);
  });

  appTest('a disappearance without a status is only a neutral fallback', (
    tester,
  ) async {
    final s = await _open(tester, [
      _question('qn', 'confirm')..remove('status'),
    ]);
    s.snapshot['interactions'] = <Object?>[];
    s.gateway!.socket('/api/events')!.push({
      'sessionId': 's2',
      'epoch': 1,
      'sequence': 5,
      'type': 'interaction_answered',
      'timestamp': 1,
      'data': {'interactionId': 'qn'},
    });
    await tester.pumpAndSettle();
    expect(find.byType(QuestionCard), findsNothing);
    expect(find.text('Q qn · ended'), findsOneWidget);
  });

  appTest('the approval mode control sends set_approval_mode; full access '
      'asks first', (tester) async {
    final s = await _open(tester, const [], agent: {'approvalMode': 'auto'});
    s.snapshot['session'] = {
      ...(s.snapshot['session']! as Map).cast<String, Object?>(),
      'binding': {
        'version': 1,
        'membership': {'revision': 1, 'legacyWorkspaceId': 'm3air:notes'},
        'execution': {
          'generation': 1,
          'workspaceId': 'm3air:notes',
          'nodeId': null,
          'modeId': 'default',
        },
      },
    };
    s.gateway!.json['POST /api/sessions/s2/commands'] = (request) =>
        reply(202, {
          'command': {
            'id': (request.json! as Map)['commandId'],
            'sessionId': 's2',
            'status': 'accepted',
          },
        });
    // Load the snapshot with the binding.
    s.gateway!.socket('/api/events')!.push({
      'type': 'reset',
      'reason': 'cursor_expired',
      'watermark': {'epoch': 1, 'sequence': 4},
    });
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Approval mode'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Full access'));
    await tester.pumpAndSettle();
    expect(find.textContaining('without asking'), findsOneWidget);
    await tester.tap(find.text('Allow full access'));
    await tester.pumpAndSettle();
    final command = s.gateway!.sent('POST', '/api/sessions/s2/commands').single;
    expect((command.json! as Map)['payload'], {
      'type': 'set_approval_mode',
      'mode': 'full-access',
    });
  });
}
