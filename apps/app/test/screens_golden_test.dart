@Tags(['golden'])
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_app/src/format.dart';
import 'package:pirc_app/src/preferences.dart';

import 'support/chat_fixtures.dart';
import 'support/fonts.dart';
import 'support/harness.dart';
import 'support/session_fixture.dart';
import 'support/work_fixtures.dart';

/// A work conversation opened by a pot, with a result and a question.
FakeGateway _conversation() {
  final s = FixtureSession('joined-mid-stream.json');
  final history = s.snapshot['history']! as List;
  history.addAll([
    {
      'role': 'custom',
      'customType': 'pot-instruction',
      'content': 'Add the iPad floating keyboard test.',
      'details': {'potId': 'p-tester', 'potName': 'Tester', 'workId': 'w1'},
      'timestamp': 1500,
    },
    {
      'role': 'assistant',
      'content': [
        {
          'type': 'text',
          'text':
              'Added `login_floating_keyboard_test.dart`.\n\n```pirc-artifact\n'
              '${jsonEncode({'id': 'r', 'version': 1, 'title': 'Test report', 'type': 'markdown', 'summary': '3 failures found', 'content': '# Report'})}'
              '\n```',
        },
      ],
      'stopReason': 'stop',
      'timestamp': 1600,
    },
  ]);
  s.snapshot['run'] = {'id': 'r1', 'status': 'waiting_input'};
  s.snapshot['interactions'] = [
    {
      'id': 'q1',
      'kind': 'select',
      'runnerEpoch': 1,
      'status': 'pending',
      'expiresAt': fixedNow
          .add(const Duration(minutes: 14))
          .millisecondsSinceEpoch,
      'request': {
        'title': 'Run only the failed cases?',
        'options': ['Only the 3 failures', 'All of them'],
      },
    },
  ];
  final gateway = WorkFixture().install(s.install());
  gateway.json['GET /api/pot-works'] = (_) => {
    'works': [
      {
        'id': 'w1',
        'potId': 'p-tester',
        'sessionId': 's2',
        'workspaceId': 'laptop:pirc',
        'title': 'iPad tests',
        'state': 'open',
      },
    ],
  };
  gateway.json['GET /api/sessions/s2/files'] = (_) => {
    'path': '',
    'entries': [
      {'name': 'lib', 'kind': 'dir'},
      {'name': 'pubspec.yaml', 'kind': 'file', 'size': 812},
    ],
  };
  return gateway;
}

/// November 2026 with an event, an all-day event and an agent task.
FakeGateway _calendar() {
  int at(int day, int hour) =>
      DateTime(2026, 11, day, hour).millisecondsSinceEpoch;
  final g = FakeGateway();
  g.json['GET /api/calendar'] = (_) => {
    'items': [
      {
        'id': 'event:e1:x',
        'type': 'event',
        'sourceId': 'e1',
        'title': 'Dentist',
        'startAt': at(25, 14),
        'endAt': at(25, 15),
        'allDay': false,
      },
      {
        'id': 'event:e2:x',
        'type': 'event',
        'sourceId': 'e2',
        'title': 'Holiday',
        'startAt': at(26, 0),
        'endAt': at(27, 0),
        'allDay': true,
        'startDate': '2026-11-26',
        'endDate': '2026-11-27',
      },
      {
        'id': 'run:r1',
        'type': 'schedule',
        'sourceId': 's1',
        'title': 'Check tests',
        'startAt': at(24, 9),
        'endAt': at(24, 9),
        'state': 'missed',
      },
    ],
    'nextCursor': null,
  };
  return g;
}

final _screens = <String, (String, FakeGateway Function(), Saved Function())>{
  'conversation': ('/work?open=s2', _conversation, Saved.new),
  'new_conversation': (
    '/work?open=new',
    () => WorkFixture().install(),
    Saved.new,
  ),
  'panels': ('/work?open=s2&side=panel:files', _conversation, Saved.new),
  'settings': ('/settings', FakeGateway.new, Saved.new),
  'settings_general': ('/settings/general', FakeGateway.new, Saved.new),
  'devices': ('/settings/devices', FakeGateway.new, Saved.new),
  'pairing': ('/chat', FakeGateway.new, Saved.unpaired),
  'calendar': ('/calendar', _calendar, Saved.new),
  'chat': ('/chat', () => ChatFixture().install(), Saved.new),
  'pot_conversation': (
    '/chat?open=pot:p-butler',
    () => ConversationFixture().install(),
    Saved.new,
  ),
};

void main() {
  for (final MapEntry(key: name, value: (location, gateway, saved))
      in _screens.entries) {
    for (final width in [375.0, 700.0, 1000.0, 1300.0]) {
      for (final mode in [ThemeMode.light, ThemeMode.dark]) {
        appTest('$name $width ${mode.name}', (tester) async {
          await tester.runAsync(loadGoldenFonts);
          final container = await pumpApp(
            tester,
            gateway: gateway(),
            saved: saved(),
            width: width,
            location: location,
            overrides: [clockProvider.overrideWithValue(() => fixedNow)],
            reduceMotion: true,
          );
          container.read(themeModeProvider.notifier).select(mode);
          await tester.pumpAndSettle();
          await expectLater(
            find.byType(MaterialApp),
            matchesGoldenFile(
              'goldens/${name}_${width.toInt()}_${mode.name}.png',
            ),
          );
        });
      }
    }
  }
}
