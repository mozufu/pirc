import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_app/src/calendar/calendar_data.dart';
import 'package:pirc_app/src/calendar/calendar_screen.dart';
import 'package:pirc_app/src/format.dart';

import 'support/harness.dart';
import 'support/session_fixture.dart';

/// Wednesday 25 November 2026, 11:00 local.
final _now = DateTime(2026, 11, 25, 11);
int _at(int day, int hour) =>
    DateTime(2026, 11, day, hour).millisecondsSinceEpoch;

Map<String, Object?> _event({bool recurring = false, int day = 25}) => {
  'id': 'event:e1:2026-11-${day}T14:00',
  'type': 'event',
  'sourceId': 'e1',
  'title': 'Dentist',
  'startAt': _at(day, 14),
  'endAt': _at(day, 15),
  'allDay': false,
  'timezone': '+08:00',
  'revision': 3,
  'originalStart': '2026-11-${day}T14:00',
  'event': {
    'id': 'e1',
    'title': 'Dentist',
    'start': '2026-11-${day}T14:00',
    'end': '2026-11-${day}T15:00',
    'timezone': '+08:00',
    'allDay': false,
    'recurrence': recurring ? {'frequency': 'weekly'} : null,
  },
};

final _allDay = {
  'id': 'event:e2:2026-11-26',
  'type': 'event',
  'sourceId': 'e2',
  'title': 'Holiday',
  'startAt': _at(26, 0),
  'endAt': _at(27, 0),
  'allDay': true,
  'startDate': '2026-11-26',
  'endDate': '2026-11-27',
  'revision': 1,
  'originalStart': '2026-11-26',
  'event': {'id': 'e2', 'title': 'Holiday', 'allDay': true},
};

Map<String, Object?> _task({String state = 'planned', bool missed = false}) => {
  'id': missed ? 'run:r1' : 'schedule:s1:${_at(25, 9)}',
  'type': 'schedule',
  'sourceId': 's1',
  'title': 'Check tests',
  'startAt': _at(25, 9),
  'endAt': _at(25, 9),
  'allDay': false,
  'state': missed ? 'missed' : state,
  'schedule': {'id': 's1', 'title': 'Check tests', 'cron': '0 9 * * *'},
  if (missed)
    'run': {
      'id': 'r1',
      'status': 'missed',
      'result': 'The gateway was not running at this time.',
    },
};

Map<String, Object?> _scheduleView({bool gone = false}) => {
  'schedule': {
    'id': 's1',
    'title': 'Check tests',
    'prompt': 'Run the tests',
    'cron': '0 9 * * *',
    'status': gone ? 'paused' : 'active',
    'workspaceId': gone ? 'old:ws' : 'laptop:pirc',
    'workspace': gone
        ? {
            'id': 'old:ws',
            'name': 'old:ws',
            'kind': null,
            'node': null,
            'online': false,
          }
        : {
            'id': 'laptop:pirc',
            'name': 'pirc',
            'mode': 'default',
            'available': true,
          },
  },
  'runs': <Object?>[],
};

Future<FakeGateway> _calendar(
  WidgetTester tester, {
  List<Map<String, Object?>>? items,
  String location = '/calendar',
  bool gone = false,
}) async {
  final g = FakeGateway();
  g.json['GET /api/calendar'] = (_) => {
    'items': items ?? [_event(), _allDay, _task()],
    'nextCursor': null,
  };
  g.json['GET /api/calendar/events/e1'] = (_) => {
    'event': {
      ...(_event(
            recurring:
                items?.first['event'] is Map &&
                ((items!.first['event'] as Map)['recurrence'] != null),
          )['event']!
          as Map),
      'revision': 3,
    },
  };
  g.json['GET /api/schedules'] = (_) => {'schedules': <Object?>[]};
  g.json['GET /api/schedules/s1'] = (_) => _scheduleView(gone: gone);
  g.json['GET /api/workspaces'] = (_) => {
    'workspaces': [
      {'id': 'laptop:pirc', 'hostId': 'h', 'displayName': 'pirc'},
    ],
  };
  g.routes.add((r) {
    if (r.path.startsWith('/api/calendar/events') ||
        r.path.startsWith('/api/schedules')) {
      return reply(r.method == 'DELETE' ? 204 : 200, {
        'event': {'id': 'e1'},
        'schedule': {'id': 's1'},
        'run': {'id': 'r1'},
      });
    }
    return null;
  });
  await pumpApp(
    tester,
    gateway: g,
    width: 1300,
    location: location,
    overrides: [clockProvider.overrideWithValue(() => _now)],
  );
  return g;
}

Future<void> _tap(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

void main() {
  test('view ranges: a 6-week month, a Sunday week, a day, 30 days', () {
    final day = DateTime(2026, 11, 25);
    final (mFrom, mTo) = viewRange(CalendarPosition(CalendarView.month, day));
    expect(mFrom, DateTime(2026, 11, 1));
    expect(mTo.difference(mFrom).inDays, 42);
    final (wFrom, _) = viewRange(CalendarPosition(CalendarView.week, day));
    expect(wFrom, DateTime(2026, 11, 22));
    final (lFrom, lTo) = viewRange(CalendarPosition(CalendarView.list, day));
    expect((lFrom, lTo.difference(lFrom).inDays), (day, 30));
    expect(zoneOffset(DateTime.utc(2026)), '+00:00');
  });

  appTest('the four views read the range and show items', (tester) async {
    final g = await _calendar(tester);
    final read = g.sent('GET', '/api/calendar').first;
    expect(
      read.query['from'],
      '${DateTime(2026, 11, 1).millisecondsSinceEpoch}',
    );
    expect(read.query['timezone'], zoneOffset(_now));
    // Month: marks by shape in the day cells.
    Finder marksOn(String day) => find.descendant(
      of: find.byKey(Key('day-$day')),
      matching: find.byType(CalendarMark),
    );
    expect(marksOn('2026-11-25'), findsNWidgets(2));
    expect(marksOn('2026-11-26'), findsOneWidget);
    // The selected day (today) lists its items under the legend.
    expect(find.text('Dentist'), findsOneWidget);
    expect(find.text('Check tests'), findsOneWidget);
    expect(find.textContaining('UTC'), findsOneWidget, reason: 'the time zone');
    await _tap(tester, find.text('Week'));
    expect(find.text('Dentist'), findsOneWidget);
    expect(find.text('Holiday'), findsOneWidget);
    await _tap(tester, find.text('Day'));
    expect(find.text('Dentist'), findsOneWidget);
    expect(find.text('Check tests'), findsOneWidget);
    await _tap(tester, find.text('List'));
    expect(find.text('Holiday'), findsOneWidget);
    // Tapping a day in the month opens that day.
    await _tap(tester, find.text('Month'));
    await _tap(tester, find.byKey(const Key('day-2026-11-26')));
    expect(find.text('Holiday'), findsOneWidget);
    expect(find.text('Dentist'), findsNothing);
  });

  appTest('a long press opens a draft; only Save creates the event', (
    tester,
  ) async {
    final g = await _calendar(tester);
    await tester.longPress(find.byKey(const Key('day-2026-11-27')));
    await tester.pumpAndSettle();
    expect(find.text('New event'), findsOneWidget);
    await _tap(tester, find.text('Cancel'));
    expect(g.sent('POST', '/api/calendar/events'), isEmpty);
    await tester.longPress(find.byKey(const Key('day-2026-11-27')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('event-title')), 'Lunch');
    await _tap(tester, find.text('Save'));
    final create = g.sent('POST', '/api/calendar/events').single.json! as Map;
    expect(create['idempotencyKey'], isNotEmpty);
    expect(create['event'], {
      'title': 'Lunch',
      'start': '2026-11-27T09:00',
      'end': '2026-11-27T10:00',
      'timezone': zoneOffset(_now),
      'allDay': false,
      'recurrence': null,
      'location': '',
      'description': '',
    });
  });

  appTest('editing a one-off event saves the series', (tester) async {
    final g = await _calendar(
      tester,
      location: '/calendar?open=event:e1:2026-11-25T14:00',
    );
    await _tap(tester, find.text('Edit'));
    await tester.enterText(
      find.byKey(const Key('event-title')),
      'Dentist (moved)',
    );
    await _tap(tester, find.text('Save'));
    final patch =
        g.sent('PATCH', '/api/calendar/events/e1').single.json! as Map;
    expect(patch['scope'], 'series');
    expect(patch['revision'], 3);
    expect((patch['event'] as Map)['title'], 'Dentist (moved)');
    expect(patch.containsKey('occurrence'), isFalse);
  });

  for (final (scope, label) in [
    ('occurrence', 'This one'),
    ('following', 'This and later ones'),
    ('series', 'The whole series'),
  ]) {
    appTest('a repeating event: edit and delete with scope $scope', (
      tester,
    ) async {
      final g = await _calendar(
        tester,
        items: [_event(recurring: true)],
        location: '/calendar?open=event:e1:2026-11-25T14:00',
      );
      await _tap(tester, find.text('Edit'));
      await _tap(tester, find.text('Save'));
      await _tap(tester, find.text(label));
      final patch =
          g.sent('PATCH', '/api/calendar/events/e1').single.json! as Map;
      expect(patch['scope'], scope);
      expect(
        patch['occurrence'],
        scope == 'series' ? null : '2026-11-25T14:00',
      );
      await _tap(tester, find.text('Delete'));
      await _tap(tester, find.text(label));
      final delete =
          g.sent('DELETE', '/api/calendar/events/e1').single.json! as Map;
      expect(delete['scope'], scope);
      expect(delete['revision'], 3);
    });
  }

  appTest('deleting a one-off event asks first', (tester) async {
    final g = await _calendar(
      tester,
      location: '/calendar?open=event:e1:2026-11-25T14:00',
    );
    await _tap(tester, find.text('Delete'));
    expect(find.text('Delete this event?'), findsOneWidget);
    await _tap(tester, find.widgetWithText(FilledButton, 'Delete'));
    expect(
      (g.sent('DELETE', '/api/calendar/events/e1').single.json!
          as Map)['scope'],
      'series',
    );
  });

  appTest('a missed run waits for a choice: run it now, or dismiss', (
    tester,
  ) async {
    final g = await _calendar(
      tester,
      items: [_task(missed: true)],
      location: '/calendar?open=run:r1',
    );
    expect(find.text('Missed'), findsWidgets);
    expect(
      g.requests.any((r) => r.path == '/api/schedules/s1/run'),
      isFalse,
      reason: 'never run again without a choice',
    );
    await _tap(tester, find.text('Run it now'));
    expect(g.sent('POST', '/api/schedules/s1/run').single.json, {
      'runId': 'r1',
    });
    await _tap(tester, find.text('Dismiss'));
    expect(g.sent('POST', '/api/schedules/s1/runs/r1/dismiss'), hasLength(1));
  });

  appTest('a task whose target is gone shows paused; Save waits for a new '
      'target', (tester) async {
    final g = await _calendar(
      tester,
      items: [_task()],
      location: '/calendar?open=schedule:s1:${_at(25, 9)}',
      gone: true,
    );
    expect(find.textContaining('its project is gone'), findsOneWidget);
    expect(find.text('Run now'), findsNothing);
    await _tap(tester, find.text('Edit task'));
    final save = tester.widget<FilledButton>(
      find.byKey(const Key('task-save')),
    );
    expect(save.onPressed, isNull);
    await _tap(tester, find.byKey(const Key('task-target')));
    await _tap(tester, find.text('pirc · laptop').last);
    await _tap(tester, find.byKey(const Key('task-save')));
    final patch = g.sent('PATCH', '/api/schedules/s1').single.json! as Map;
    expect(patch['workspaceId'], 'laptop:pirc');
    expect(patch['status'], 'active');
  });

  appTest('a new agent task', (tester) async {
    final g = await _calendar(tester);
    await _tap(tester, find.byTooltip('New'));
    await _tap(tester, find.text('New agent task'));
    await tester.enterText(find.byKey(const Key('task-prompt')), 'Run tests');
    await tester.pump();
    await _tap(tester, find.byKey(const Key('task-target')));
    await _tap(tester, find.text('pirc · laptop').last);
    await _tap(tester, find.byKey(const Key('task-save')));
    final create = g.sent('POST', '/api/schedules').single.json! as Map;
    expect(create['workspaceId'], 'laptop:pirc');
    expect(create['cron'], '0 9 * * *');
    expect(create['prompt'], 'Run tests');
  });

  appTest("an agent's calendar proposal is a question with the before and "
      'after text', (tester) async {
    final session = FixtureSession('joined-mid-stream.json');
    session.snapshot['interactions'] = [
      {
        'id': 'calendar:p1:1',
        'kind': 'confirm',
        'runnerEpoch': 0,
        'status': 'pending',
        'request': {
          'title': 'Save these event changes?',
          'message':
              'Current event: Dentist 14:00\nAfter approval: Dentist 16:00',
          'confirmLabel': 'Save',
          'cancelLabel': "Don't",
        },
      },
    ];
    final g = session.install();
    g.routes.add(
      (r) => r.path.endsWith('/answer')
          ? reply(200, {'status': 'answered'})
          : null,
    );
    await pumpApp(tester, gateway: g, location: '/work?open=s2');
    expect(find.text('Save these event changes?'), findsOneWidget);
    expect(
      find.textContaining('After approval: Dentist 16:00'),
      findsOneWidget,
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();
    final answer = g.requests.lastWhere((r) => r.path.endsWith('/answer'));
    expect((answer.json! as Map)['answer'], {'confirmed': true});
  });
}
