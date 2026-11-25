import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/harness.dart';
import 'support/session_fixture.dart';

/// s2 opened by the pot "Tester", with one pot instruction in its history.
Future<FixtureSession> _open(
  WidgetTester tester, {
  String state = 'open',
  bool running = true,
}) async {
  final s = FixtureSession('joined-mid-stream.json');
  final history = s.snapshot['history']! as List;
  history.add({
    'role': 'custom',
    'customType': 'pot-instruction',
    'content':
        'Instruction from Tester, a pot coordinating this work for the '
        'user:\n\nAdd the iPad keyboard test',
    'details': {
      'potId': 'p-tester',
      'potName': 'Tester',
      'workId': 'w1',
      'instructionId': 'i1',
    },
    'timestamp': 1500,
  });
  if (running) s.snapshot['run'] = {'id': 'r1', 'status': 'running'};
  final gateway = s.install();
  s.gateway = gateway;
  gateway.json['GET /api/pots'] = (_) => {
    'pots': [
      {
        'id': 'p-tester',
        'state': 'active',
        'profile': {'name': 'Tester', 'avatarColor': 2},
      },
    ],
  };
  gateway.json['GET /api/pot-works'] = (_) => {
    'works': [
      {
        'id': 'w1',
        'potId': 'p-tester',
        'sessionId': 's2',
        'workspaceId': 'm3air:notes',
        'title': 'iPad tests',
        'state': state,
      },
    ],
  };
  await pumpApp(tester, gateway: gateway, location: '/work?open=s2');
  return s;
}

void main() {
  appTest('a pot instruction shows From and Not sent by you, from details', (
    tester,
  ) async {
    await _open(tester);
    expect(find.text('From Tester'), findsOneWidget);
    expect(find.text('Not sent by you'), findsOneWidget);
    expect(
      find.textContaining('Add the iPad keyboard test', findRichText: true),
      findsWidgets,
    );
    expect(
      find.textContaining('a pot coordinating', findRichText: true),
      findsNothing,
      reason: 'the preamble for the model is not shown',
    );
  });

  appTest('while the pot coordinates: the bar, and only Stop', (tester) async {
    await _open(tester);
    expect(find.textContaining('Tester coordinates this work'), findsOneWidget);
    final field = tester.widget<TextField>(
      find.byKey(const Key('composer-field')),
    );
    expect(field.enabled, isFalse);
    expect(field.decoration!.hintText, 'Take over to send messages');
    final stop = tester.widget<TextButton>(
      find.ancestor(
        of: find.text('Stop this work'),
        matching: find.byType(TextButton),
      ),
    );
    expect(stop.onPressed, isNotNull);
  });

  appTest('take over uses the work ID, then a plain banner shows', (
    tester,
  ) async {
    final s = await _open(tester);
    s.gateway!.json['POST /api/pot-works/w1/take-over'] = (_) {
      s.gateway!.json['GET /api/pot-works'] = (_) => {
        'works': [
          {
            'id': 'w1',
            'potId': 'p-tester',
            'sessionId': 's2',
            'workspaceId': 'm3air:notes',
            'title': 'iPad tests',
            'state': 'taken_over',
          },
        ],
      };
      return {
        'work': {'id': 'w1', 'potId': 'p-tester', 'state': 'taken_over'},
      };
    };
    await tester.tap(find.text('Take over'));
    await tester.pumpAndSettle();
    expect(
      s.gateway!.sent('POST', '/api/pot-works/w1/take-over'),
      hasLength(1),
    );
    expect(
      find.text('Tester sends no more instructions here.'),
      findsOneWidget,
    );
    expect(find.text('Take over'), findsNothing);
    expect(
      tester.widget<TextField>(find.byKey(const Key('composer-field'))).enabled,
      isTrue,
    );
  });

  appTest('409 taken_over from a second device counts as success', (
    tester,
  ) async {
    final s = await _open(tester);
    s.gateway!.json['POST /api/pot-works/w1/take-over'] = (_) =>
        apiError(409, 'taken_over', 'This work was already taken over');
    await tester.tap(find.text('Take over'));
    await tester.pumpAndSettle();
    expect(find.textContaining('did not work'), findsNothing);
    // It reads the works again.
    expect(s.gateway!.sent('GET', '/api/pot-works').length, greaterThan(1));
  });

  appTest('a pots_changed hint from another device ends the bar', (
    tester,
  ) async {
    final s = await _open(tester);
    s.gateway!.json['GET /api/pot-works'] = (_) => {
      'works': [
        {
          'id': 'w1',
          'potId': 'p-tester',
          'sessionId': 's2',
          'workspaceId': 'm3air:notes',
          'title': 'iPad tests',
          'state': 'taken_over',
        },
      ],
    };
    s.gateway!.socket('/api/hints')!.push({'type': 'pots_changed'});
    await tester.pumpAndSettle();
    expect(find.textContaining('coordinates this work'), findsNothing);
    expect(
      find.text('Tester sends no more instructions here.'),
      findsOneWidget,
    );
  });
}
