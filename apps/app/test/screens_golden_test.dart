@Tags(['golden'])
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_app/src/format.dart';
import 'package:pirc_app/src/platform/notifications.dart';
import 'package:pirc_app/src/platform/push.dart';
import 'package:pirc_app/src/preferences.dart';
import 'package:pirc_app/src/work/work_data.dart';

import 'support/activity_fixtures.dart';
import 'support/chat_fixtures.dart';
import 'support/fonts.dart';
import 'support/harness.dart';
import 'support/me_fixtures.dart';
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

/// Settings → Notifications (C screenshots 11 and 30): this phone gets
/// notifications through ntfy, with the D20 levels.
FakeGateway _notifications() => FakeGateway()
  ..json['GET /api/push'] = (_) => {
    'publicKey': 'KEY',
    'subscriptions': [
      {
        'id': 'push-phone',
        'kind': 'unifiedpush',
        'name': 'Pixel 9',
        'host': 'ntfy.sh',
        'createdAt': 1,
        'lastSuccessAt': DateTime(2026, 11, 25, 8, 53).millisecondsSinceEpoch,
        'failing': false,
        'levels': {
          'needs_you': 'immediate',
          'done': 'digest',
          'progress': 'off',
          'calendar': 'immediate',
        },
        'quietHours': {'start': '23:00', 'end': '07:30'},
        'timeZone': 'Asia/Taipei',
        'lockScreen': 'title',
        'digestAt': '18:00',
        'revision': 4,
      },
    ],
  };

/// The drawer over Chat (E21): hosts with running work and the user row.
FakeGateway _drawer() =>
    ChatFixture().install(WorkFixture().install(MeFixture.e28().install()));

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
  'pot_profile': (
    '/chat?open=pot:p-butler&side=profile',
    () => PotProfileFixture().install(),
    Saved.new,
  ),
  'group_conversation': (
    '/chat?open=t-mobile',
    () => GroupFixture().install(),
    Saved.new,
  ),
  'me': ('/me', () => MeFixture.e28().install(), Saved.new),
  'activity': ('/activity', () => ActivityFixture().install(), Saved.new),
  'work_needs_you': ('/work', () => WorkFixture().install(), Saved.new),
  'work_pots': ('/work', () => WorkFixture().install(), Saved.new),
  'drawer': ('/chat', _drawer, Saved.new),
  'notifications': ('/settings/notifications', _notifications, Saved.new),
};

/// The Android push and notifications channels of a screen of [_screens];
/// the others have neither.
final _platforms = <String, (PushPlatform, NotificationsPlatform) Function()>{
  'notifications': () => (
    FakePush(
      current: const PushStatus(
        PushState.on,
        distributor: 'io.heckel.ntfy',
        subscriptionId: 'push-phone',
        timeZone: 'Asia/Taipei',
      ),
    ),
    FakeNotifications(granted: true, overlayAllowed: true)
      ..overlayWanted = true,
  ),
};

/// What to do on a screen of [_screens] before its image is taken. The
/// filters are set directly, so the chip row stays at its start as in E3
/// and E4.
final _actions =
    <String, Future<void> Function(WidgetTester, ProviderContainer)>{
      'work_needs_you': (tester, container) async => container
          .read(workFilterProvider.notifier)
          .select(WorkFilter.needsYou),
      'work_pots': (tester, container) async =>
          container.read(workFilterProvider.notifier).select(WorkFilter.pots),
      'drawer': (tester, container) async =>
          tester.tap(find.byTooltip('Open the menu')),
    };

void main() {
  for (final MapEntry(key: name, value: (location, gateway, saved))
      in _screens.entries) {
    for (final width in goldenWidths) {
      for (final mode in [ThemeMode.light, ThemeMode.dark]) {
        appTest('$name ${width.toInt()} ${mode.name}', (tester) async {
          await tester.runAsync(loadGoldenFonts);
          final platforms = _platforms[name]?.call();
          final container = await pumpApp(
            tester,
            gateway: gateway(),
            saved: saved(),
            width: width,
            height: goldenHeight(width),
            location: location,
            overrides: [clockProvider.overrideWithValue(() => fixedNow)],
            reduceMotion: true,
            push: platforms?.$1,
            notifications: platforms?.$2,
          );
          container.read(themeModeProvider.notifier).select(mode);
          await tester.pumpAndSettle();
          await _actions[name]?.call(tester, container);
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
