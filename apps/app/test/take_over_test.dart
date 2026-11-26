import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_app/src/router.dart';
import 'package:pirc_app/src/work/work_data.dart';
import 'package:pirc_ui/pirc_ui.dart';

import 'support/harness.dart';
import 'support/session_fixture.dart';

late ProviderContainer _container;

Uri _location() =>
    _container.read(routerProvider).routeInformationProvider.value.uri;

/// s2 opened by the pot "Tester", with one pot instruction in its history.
/// Without [potKnown] the pot is missing from `GET /api/pots`.
Future<FixtureSession> _open(
  WidgetTester tester, {
  String state = 'open',
  bool running = true,
  bool potKnown = true,
  String location = '/work?open=s2',
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
      if (potKnown)
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
  _container = await pumpApp(tester, gateway: gateway, location: location);
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

  appTest('an Opened by pots row opens the work with the pot bar', (
    tester,
  ) async {
    await _open(tester, location: '/work');
    final chips = find.byType(FilterChips<WorkFilter>);
    final chip = find.descendant(
      of: chips,
      matching: find.text('Opened by pots'),
    );
    await tester.dragUntilVisible(chip, chips, const Offset(-80, 0));
    await tester.ensureVisible(chip);
    await tester.pumpAndSettle();
    await tester.tap(chip);
    await tester.pumpAndSettle();
    expect(find.textContaining('take it over'), findsOneWidget);
    final row = find.textContaining('From Tester', findRichText: true);
    expect(row, findsOneWidget);
    await tester.tap(row);
    await tester.pumpAndSettle();
    expect(_location().queryParameters['open'], 's2');
    expect(find.textContaining('Tester coordinates this work'), findsOneWidget);
    expect(find.byKey(const Key('pot-bar-avatar')), findsOneWidget);
  });

  appTest('the pot bar links back to the pot conversation', (tester) async {
    await _open(tester);
    await tester.tap(find.byKey(const Key('pot-bar-avatar')));
    await tester.pumpAndSettle();
    expect(_location().toString(), '/chat?open=pot%3Ap-tester');
  });

  appTest('after a take-over the banner still links back to the pot', (
    tester,
  ) async {
    await _open(tester, state: 'taken_over');
    await tester.tap(find.text('Tester sends no more instructions here.'));
    await tester.pumpAndSettle();
    expect(_location().toString(), '/chat?open=pot%3Ap-tester');
  });

  appTest('an unknown pot gives the bar no avatar and no link', (tester) async {
    await _open(tester, potKnown: false);
    expect(find.byKey(const Key('pot-bar-avatar')), findsNothing);
    await tester.tap(find.textContaining('coordinates this work'));
    await tester.pumpAndSettle();
    expect(_location().queryParameters['open'], 's2');
    expect(find.textContaining('coordinates this work'), findsOneWidget);
  });
}
