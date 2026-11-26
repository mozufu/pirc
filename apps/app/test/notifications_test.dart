import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:pirc_app/src/connection/connection.dart';
import 'package:pirc_app/src/connection/storage.dart';
import 'package:pirc_app/src/format.dart';
import 'package:pirc_app/src/notifications/notification_open.dart';
import 'package:pirc_app/src/platform/notifications.dart';
import 'package:pirc_app/src/platform/push.dart';
import 'package:pirc_app/src/router.dart';
import 'package:pirc_client/pirc_client.dart';

import 'support/harness.dart';
import 'support/session_fixture.dart';

final _now = DateTime(2026, 11, 25, 11);
const _options = ['Only the 3 failures', 'All of them', 'Report only'];

late ProviderContainer _container;

Uri _location() =>
    _container.read(routerProvider).routeInformationProvider.value.uri;

/// A tap on question q1 of s2 (epoch 1), with [choice] tapped.
String _tap({String? choice}) => jsonEncode({
  'type': 'question',
  'sessionId': 's2',
  'interactionId': 'q1',
  'epoch': '1',
  'choice': ?choice,
  'label': ?choice,
});

Map<String, Object?> _compact(
  String state, {
  Map<String, Object?>? answeredBy,
  String epoch = '1',
}) => {
  'id': 'q1',
  'state': state,
  'epoch': epoch,
  'question': {
    'kind': 'select',
    'title': 'Run only the failed cases?',
    'message': null,
  },
  'choices': [
    for (final o in _options) {'id': o, 'label': o},
  ],
  'expiresAt': _now.add(const Duration(minutes: 14)).millisecondsSinceEpoch,
  'controlHolder': null,
  'answeredBy': answeredBy,
};

ApiResponse _ok(
  String state, {
  Map<String, Object?>? answeredBy,
  String epoch = '1',
}) => reply(200, _compact(state, answeredBy: answeredBy, epoch: epoch));

/// s2 with question q1 pending; the compact route answers [compact].
Future<(FixtureSession, FakeNotifications)> _open(
  WidgetTester tester, {
  required FutureOr<ApiResponse> Function() compact,
  String? tap,
  Map<String, Object?>? lease,
  bool settle = true,
}) async {
  final s = FixtureSession('joined-mid-stream.json')
    ..lease = lease
    ..snapshot['interactions'] = [
      {
        'id': 'q1',
        'kind': 'select',
        'runnerEpoch': 1,
        'status': 'pending',
        'expiresAt': _now
            .add(const Duration(minutes: 14))
            .millisecondsSinceEpoch,
        'request': {'title': 'Run only the failed cases?', 'options': _options},
      },
    ];
  final gateway = s.install();
  s.gateway = gateway;
  gateway.routes.add(
    (request) =>
        request.method == 'GET' &&
            request.path == '/api/sessions/s2/interactions/q1'
        ? compact()
        : null,
  );
  gateway.routes.add(
    (request) => request.path.endsWith('/interactions/q1/answer')
        ? reply(200, {'ok': true})
        : null,
  );
  final notifications = FakeNotifications(initial: tap);
  _container = await pumpApp(
    tester,
    gateway: gateway,
    location: '/chat',
    saved: Saved(
      prefs: {
        PrefKeys.gatewayUrl: 'https://gateway.test/',
        PrefKeys.clientId: 'me',
      },
    ),
    notifications: notifications,
    settle: settle,
    overrides: [clockProvider.overrideWithValue(() => _now)],
  );
  return (s, notifications);
}

Iterable<ApiRequest> _answers(FixtureSession s) =>
    s.gateway!.sent('POST', '/api/sessions/s2/interactions/q1/answer');

void main() {
  group('a tapped question (C § 6.2)', () {
    appTest('shows only the check while it reads, with no buttons', (
      tester,
    ) async {
      final read = Completer<ApiResponse>();
      await _open(
        tester,
        compact: () => read.future,
        tap: _tap(choice: 'All of them'),
        settle: false,
      );
      // Not settled: the spinner turns until the read answers.
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(_location().path, notificationCheckPath);
      expect(
        find.text('Reconnecting and checking the latest state'),
        findsOneWidget,
      );
      expect(find.byType(FilledButton), findsNothing);
      expect(find.byType(TextButton), findsNothing);
      read.complete(reply(200, _compact('expired')));
      await tester.pumpAndSettle();
    });

    appTest('still open: the conversation and the sheet, with the tapped '
        'answer preselected; only Send answer sends', (tester) async {
      final (s, _) = await _open(
        tester,
        compact: () => _ok('pending'),
        tap: _tap(choice: 'All of them'),
      );
      expect(_location().queryParameters['open'], 's2');
      expect(find.text('Confirm your answer'), findsOneWidget);
      expect(
        find.textContaining('the question is still open, control on this'),
        findsOneWidget,
      );
      Finder picked(String option) => find.descendant(
        of: find.byKey(Key('answer-choice-$option')),
        matching: find.byIcon(LucideIcons.circleDot),
      );
      expect(picked('All of them'), findsOneWidget);
      expect(picked('Only the 3 failures'), findsNothing);
      // Nothing was sent by the tap or the check.
      expect(_answers(s), isEmpty);
      await tester.tap(find.byKey(const Key('send-answer')));
      await tester.pumpAndSettle();
      final sent = _answers(s).single.json! as Map;
      expect(sent['clientId'], 'me');
      expect(sent['answer'], {'value': 'All of them'});
      expect(find.text('Confirm your answer'), findsNothing);
    });

    appTest('still open: changing the choice sends the new one', (
      tester,
    ) async {
      final (s, _) = await _open(
        tester,
        compact: () => _ok('pending'),
        tap: _tap(choice: 'All of them'),
      );
      await tester.tap(find.byKey(const Key('answer-choice-Report only')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('send-answer')));
      await tester.pumpAndSettle();
      expect((_answers(s).single.json! as Map)['answer'], {
        'value': 'Report only',
      });
    });

    appTest('"Answer…" opens the sheet with nothing preselected', (
      tester,
    ) async {
      final (s, _) = await _open(
        tester,
        compact: () => _ok('pending'),
        tap: _tap(),
      );
      expect(find.text('Confirm your answer'), findsOneWidget);
      final send = tester.widget<FilledButton>(
        find.byKey(const Key('send-answer')),
      );
      expect(send.onPressed, isNull);
      expect(_answers(s), isEmpty);
    });

    appTest('already answered: by whom and when, nothing to send', (
      tester,
    ) async {
      final (s, _) = await _open(
        tester,
        compact: () => _ok(
          'answered',
          answeredBy: {
            'deviceName': 'iPad',
            'at': DateTime(2026, 11, 25, 8, 51).millisecondsSinceEpoch,
          },
        ),
        tap: _tap(choice: 'All of them'),
      );
      expect(find.text('This was already handled'), findsOneWidget);
      expect(find.text('Answered on iPad · 08:51'), findsOneWidget);
      expect(find.text('Send answer'), findsNothing);
      await tester.tap(find.text('Open conversation'));
      await tester.pumpAndSettle();
      expect(_location().queryParameters['open'], 's2');
      expect(find.text('Confirm your answer'), findsNothing);
      expect(_answers(s), isEmpty);
    });

    appTest('expired: it can no longer be answered', (tester) async {
      await _open(
        tester,
        compact: () => _ok('expired'),
        tap: _tap(choice: 'All of them'),
      );
      expect(find.text('This question expired'), findsOneWidget);
      expect(find.text('Send answer'), findsNothing);
    });

    appTest('another runner epoch, or a question gone, counts as expired', (
      tester,
    ) async {
      await _open(
        tester,
        compact: () => _ok('pending', epoch: '2'),
        tap: _tap(choice: 'All of them'),
      );
      expect(find.text('This question expired'), findsOneWidget);
    });

    appTest('controlled on another device: Take control before sending', (
      tester,
    ) async {
      final (s, _) = await _open(
        tester,
        compact: () => _ok('pending'),
        tap: _tap(choice: 'All of them'),
        lease: {
          'clientId': 'mac',
          'generation': 3,
          'expiresAt': _now
              .add(const Duration(minutes: 5))
              .millisecondsSinceEpoch,
          'holder': {'name': 'MacBook', 'kind': 'browser'},
        },
      );
      expect(
        find.text('Controlled by MacBook. Take control to send.'),
        findsOneWidget,
      );
      FilledButton send() =>
          tester.widget<FilledButton>(find.byKey(const Key('send-answer')));
      expect(send().onPressed, isNull);
      await tester.tap(find.text('Take control'));
      await tester.pumpAndSettle();
      final acquire = s.gateway!
          .sent('POST', '/api/sessions/s2/control/acquire')
          .last;
      expect((acquire.json! as Map)['force'], true);
      expect(send().onPressed, isNotNull);
      expect(_answers(s), isEmpty);
      await tester.tap(find.byKey(const Key('send-answer')));
      await tester.pumpAndSettle();
      expect((_answers(s).single.json! as Map)['answer'], {
        'value': 'All of them',
      });
    });

    appTest('offline: the choice is kept and only Retry is offered', (
      tester,
    ) async {
      var offline = true;
      final (s, _) = await _open(
        tester,
        compact: () => offline
            ? throw const TransportException('offline')
            : _ok('pending'),
        tap: _tap(choice: 'All of them'),
      );
      expect(find.text('Could not check the latest state'), findsOneWidget);
      expect(find.text('Your choice is kept: All of them'), findsOneWidget);
      expect(find.byType(FilledButton), findsOneWidget);
      expect(find.text('Try again'), findsOneWidget);
      expect(find.text('Open conversation'), findsNothing);
      offline = false;
      await tester.tap(find.text('Try again'));
      await tester.pumpAndSettle();
      expect(find.text('Confirm your answer'), findsOneWidget);
      await tester.tap(find.byKey(const Key('send-answer')));
      await tester.pumpAndSettle();
      expect((_answers(s).single.json! as Map)['answer'], {
        'value': 'All of them',
      });
    });

    appTest('a tap while the app runs is followed too', (tester) async {
      final (_, notifications) = await _open(
        tester,
        compact: () => _ok('expired'),
      );
      expect(_location().path, '/chat');
      notifications.tap(_tap());
      await tester.pumpAndSettle();
      expect(find.text('This question expired'), findsOneWidget);
    });
  });

  group('other targets', () {
    test('each target has its location (pot pushes: default E)', () {
      String? at(Map<String, Object?> target) =>
          NotificationOpen.parse(jsonEncode(target))?.location;
      expect(at({'type': 'approval', 'approvalId': 'a1'}), '/work?approval=a1');
      expect(
        at({'type': 'budget', 'budgetRequestId': 'b1'}),
        '/chat?budget=b1',
      );
      expect(
        at({'type': 'thread', 'potId': 'p1', 'threadId': 't1'}),
        '/chat?open=t1',
      );
      expect(
        at({'type': 'activityNotification', 'activityNotificationId': 'n1'}),
        '/activity?notification=n1',
      );
      expect(at({'type': 'activity'}), '/activity');
      expect(at({'type': 'session', 'sessionId': 's9'}), '/work?open=s9');
      expect(
        at({
          'type': 'run',
          'scheduleId': 'sch',
          'runId': 'r1',
          'action': 'skip',
        }),
        '/calendar?open=run%3Ar1&action=skip',
      );
      expect(
        at({
          'type': 'run',
          'scheduleId': 'sch',
          'runId': 'r1',
          'action': 'view',
        }),
        '/calendar?open=run%3Ar1',
      );
      expect(
        at({'type': 'calendar', 'eventId': 'e1', 'occurrenceStart': '100'}),
        '/calendar?open=event%3Ae1%3A100',
      );
      expect(at({'type': 'settings'}), '/settings/notifications');
      expect(
        at({
          'type': 'question',
          'sessionId': 's 1',
          'interactionId': 'q1',
          'epoch': '3',
          'choice': 'c1',
        }),
        '/notification?session=s+1&interaction=q1&epoch=3&choice=c1',
      );
      // Anything else is not followed.
      expect(at({'type': 'approval'}), isNull);
      expect(at({'type': 'question', 'sessionId': 's1'}), isNull);
      expect(at({'type': 'app'}), isNull);
      expect(NotificationOpen.parse('not json'), isNull);
    });

    for (final (name, target, location) in [
      (
        'a model approval opens its sheet',
        {'type': 'approval', 'approvalId': 'a1'},
        '/work',
      ),
      (
        'a budget request opens its sheet',
        {'type': 'budget', 'budgetRequestId': 'b1'},
        '/chat',
      ),
      (
        'a pot thread opens the thread',
        {'type': 'thread', 'potId': 'p1', 'threadId': 't1'},
        '/chat?open=t1',
      ),
      (
        'an observation notification opens the Activity tab',
        {'type': 'activityNotification', 'activityNotificationId': 'n1'},
        '/activity?notification=n1',
      ),
      ('the summary opens the Activity tab', {'type': 'activity'}, '/activity'),
    ]) {
      appTest(name, (tester) async {
        final gateway = FakeGateway();
        gateway.routes.add((request) => reply(200, const {}));
        final notifications = FakeNotifications(initial: jsonEncode(target));
        _container = await pumpApp(
          tester,
          gateway: gateway,
          location: '/calendar',
          notifications: notifications,
        );
        // The decision sheets take their parameter out of the location.
        expect(_location().toString(), location);
        if (target['type'] == 'approval' || target['type'] == 'budget') {
          final requested = gateway.requests.map((r) => r.path).toSet();
          expect(
            requested,
            contains(
              target['type'] == 'approval'
                  ? '/api/model-approvals/a1'
                  : '/api/budget-requests/b1',
            ),
          );
        }
      });
    }
  });

  group('the background client target', () {
    appTest('is given when online and forgotten before the token on unpair', (
      tester,
    ) async {
      final saved = Saved(
        prefs: {
          PrefKeys.gatewayUrl: 'https://gateway.test/',
          PrefKeys.clientId: 'me',
        },
      );
      final push = _RecordingPush(saved.secrets);
      final container = await pumpApp(
        tester,
        gateway: FakeGateway(),
        saved: saved,
        push: push,
      );
      expect(push.gateway, Uri.parse('https://gateway.test/'));
      expect(push.clientId, 'me');
      await container.read(connectionProvider.notifier).unpair();
      await tester.pumpAndSettle();
      expect(push.calls, contains('forget'));
      expect(push.gateway, isNull);
      // The Gateway could still be told: the token was there at forget.
      expect(push.tokenAtForget, 'device-token');
      expect(saved.secrets.values[deviceTokenKey], isNull);
    });
  });
}

/// Records whether the token was still stored when push was forgotten.
class _RecordingPush extends FakePush {
  _RecordingPush(this.secrets);

  final MemorySecretStore secrets;
  String? tokenAtForget;

  @override
  Future<void> forget({bool atGateway = true}) async {
    tokenAtForget = secrets.values[deviceTokenKey];
    await super.forget(atGateway: atGateway);
  }
}
