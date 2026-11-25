import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
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
}) => {
  'id': id,
  'kind': kind,
  'runnerEpoch': 1,
  'status': 'pending',
  'expiresAt': expiresAt ?? _in(const Duration(minutes: 14)),
  'request': {'title': 'Q $id', 'message': 'Why $id', ...request},
};

Future<FixtureSession> _open(
  WidgetTester tester,
  List<Map<String, Object?>> questions, {
  Map<String, Object?>? lease,
  Map<String, Object?>? agent,
}) async {
  final session = FixtureSession('joined-mid-stream.json')
    ..lease = lease
    ..snapshot['interactions'] = questions;
  if (agent != null) session.snapshot['agent'] = agent;
  final gateway = session.install();
  session.gateway = gateway;
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
    expect(body['clientId'], isNotEmpty);
    expect(body['generation'], 1);
    // Answered: one summary line until the snapshot drops it.
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

  appTest('control on another device disables Send and offers Take control', (
    tester,
  ) async {
    final s = await _open(
      tester,
      [_question('q7', 'confirm')],
      lease: {'clientId': 'other-phone', 'generation': 4},
    );
    final yes = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Yes'),
    );
    expect(yes.onPressed, isNull);
    final card = find.byType(QuestionCard);
    await tester.tap(
      find.descendant(of: card, matching: find.text('Take control')),
    );
    await tester.pumpAndSettle();
    expect(s.lease!['clientId'], isNot('other-phone'));
    final enabled = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Yes'),
    );
    expect(enabled.onPressed, isNotNull);
  });

  appTest('a relayed question needs no lease', (tester) async {
    final s = await _open(
      tester,
      [_question('relay.d1.q', 'confirm')],
      lease: {'clientId': 'other-phone', 'generation': 4},
    );
    await tester.tap(find.text('Yes'));
    await tester.pumpAndSettle();
    expect(_answer(s, 'relay.d1.q'), {
      'answer': {'confirmed': true},
    });
  });

  appTest('two devices: an answer from the other one shows as handled '
      'elsewhere', (tester) async {
    final s = await _open(tester, [_question('q8', 'confirm')]);
    // The other device answers: the snapshot no longer lists it.
    s.snapshot['interactions'] = <Object?>[];
    s.gateway!.socket('/api/events')!.push({
      'sessionId': 's2',
      'epoch': 1,
      'sequence': 5,
      'type': 'interaction_answered',
      'timestamp': 1,
      'data': {'interactionId': 'q8'},
    });
    await tester.pumpAndSettle();
    expect(find.byType(QuestionCard), findsNothing);
    expect(find.text('Q q8 · handled on another device'), findsOneWidget);
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
