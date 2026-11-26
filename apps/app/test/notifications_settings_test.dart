import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_app/src/format.dart';
import 'package:pirc_app/src/platform/notifications.dart';
import 'package:pirc_app/src/platform/push.dart';
import 'package:pirc_client/pirc_client.dart';

import 'support/harness.dart';

final _now = DateTime(2026, 11, 25, 9);

Map<String, Object?> _phone({
  int revision = 4,
  Map<String, String>? levels,
  Object? quietHours,
  String lockScreen = 'title',
  String digestAt = '18:00',
}) => {
  'id': 'push-phone',
  'kind': 'unifiedpush',
  'name': 'Pixel 9',
  'host': 'ntfy.sh',
  'createdAt': 1,
  'lastSuccessAt': DateTime(2026, 11, 25, 8, 53).millisecondsSinceEpoch,
  'failing': false,
  'levels':
      levels ??
      {
        'needs_you': 'immediate',
        'done': 'digest',
        'progress': 'off',
        'calendar': 'immediate',
      },
  'quietHours': quietHours,
  'timeZone': 'Asia/Taipei',
  'lockScreen': lockScreen,
  'digestAt': digestAt,
  'revision': revision,
};

/// The Gateway with this phone's target; PATCH answers with [patch].
FakeGateway _gateway({
  Object? Function(ApiRequest request)? patch,
  List<Map<String, Object?>>? targets,
}) {
  final gateway = FakeGateway();
  gateway.json['GET /api/push'] = (_) => {
    'publicKey': 'KEY',
    'subscriptions': targets ?? [_phone()],
  };
  gateway.json['PATCH /api/push/subscriptions/push-phone'] =
      patch ??
      (request) {
        final body = request.json! as Map;
        final current = _phone();
        return {
          'subscription': {
            ...current,
            for (final MapEntry(:key, :value) in body.entries)
              if (key != 'revision' && key != 'levels') '$key': value,
            'levels': {
              ...current['levels']! as Map,
              ...(body['levels'] as Map? ?? const {}),
            },
            'revision': (body['revision'] as int) + 1,
          },
        };
      };
  gateway.json['POST /api/push/test'] = (_) => {'delivered': 1};
  return gateway;
}

Future<FakeGateway> _open(
  WidgetTester tester, {
  FakeGateway? gateway,
  FakePush? push,
  FakeNotifications? notifications,
}) async {
  final g = gateway ?? _gateway();
  await pumpApp(
    tester,
    gateway: g,
    location: '/settings/notifications',
    height: 2400,
    push:
        push ??
        FakePush(
          current: const PushStatus(
            PushState.on,
            distributor: 'io.heckel.ntfy',
            subscriptionId: 'push-phone',
            timeZone: 'Asia/Taipei',
          ),
        ),
    notifications: notifications ?? FakeNotifications(),
    overrides: [clockProvider.overrideWithValue(() => _now)],
  );
  return g;
}

Future<void> _pick(WidgetTester tester, String dropdown, String item) async {
  await tester.tap(find.byKey(Key(dropdown)));
  await tester.pumpAndSettle();
  await tester.tap(find.text(item).last);
  await tester.pumpAndSettle();
}

Map _patch(FakeGateway g, [int index = 0]) =>
    g.sent('PATCH', '/api/push/subscriptions/push-phone').elementAt(index).json!
        as Map;

String? _dropdownValue(WidgetTester tester, String key) =>
    tester.widget<DropdownButton<String>>(find.byKey(Key(key))).value;

void main() {
  appTest('shows this phone, its distributor and its preferences', (
    tester,
  ) async {
    await _open(tester);
    expect(find.text('This phone gets notifications'), findsOneWidget);
    expect(
      find.text('UnifiedPush · ntfy · last delivered 08:53'),
      findsOneWidget,
    );
    expect(
      tester.widget<SwitchListTile>(find.byKey(const Key('push-switch'))).value,
      isTrue,
    );
    for (final name in [
      'Needs you',
      'Done',
      'Progress',
      'Calendar reminders',
    ]) {
      expect(find.text(name), findsOneWidget);
    }
    expect(_dropdownValue(tester, 'level-needs_you'), 'immediate');
    expect(_dropdownValue(tester, 'level-done'), 'digest');
    expect(_dropdownValue(tester, 'level-progress'), 'off');
    expect(find.text('18:00'), findsOneWidget);
    expect(_dropdownValue(tester, 'lock-screen'), 'title');
    expect(find.text('Times are in Asia/Taipei.'), findsOneWidget);
    // "Title only" depends on Android's own lock screen setting; it says so.
    expect(
      find.textContaining('hides sensitive notification content'),
      findsOneWidget,
    );
    expect(find.text('This phone'), findsOneWidget);
  });

  appTest('a change is saved with the revision, the next with the new one', (
    tester,
  ) async {
    final g = await _open(tester);
    await _pick(tester, 'level-done', 'Off');
    expect(_patch(g), {
      'revision': 4,
      'levels': {'done': 'off'},
    });
    expect(_dropdownValue(tester, 'level-done'), 'off');
    await _pick(tester, 'lock-screen', 'Everything');
    expect(_patch(g, 1), {'revision': 5, 'lockScreen': 'full'});
    expect(_dropdownValue(tester, 'lock-screen'), 'full');
  });

  appTest('quiet hours turn on with a default, may cross midnight, and off', (
    tester,
  ) async {
    final g = await _open(tester);
    await tester.tap(find.byKey(const Key('quiet-hours')));
    await tester.pumpAndSettle();
    expect(_patch(g), {
      'revision': 4,
      'quietHours': {'start': '22:00', 'end': '07:00'},
    });
    expect(find.text('22:00'), findsOneWidget);
    expect(find.text('07:00'), findsOneWidget);
    await tester.tap(find.byKey(const Key('quiet-hours')));
    await tester.pumpAndSettle();
    expect(_patch(g, 1), {'revision': 5, 'quietHours': null});
    expect(find.text('22:00'), findsNothing);
  });

  appTest('a conflict shows the current values and says so', (tester) async {
    final g = _gateway(
      patch: (_) => apiError409({
        'subscription': _phone(
          revision: 9,
          levels: {
            'needs_you': 'digest',
            'done': 'immediate',
            'progress': 'off',
            'calendar': 'off',
          },
          lockScreen: 'hidden',
        ),
      }),
    );
    await _open(tester, gateway: g);
    await _pick(tester, 'level-done', 'Off');
    expect(_patch(g)['revision'], 4);
    expect(
      find.textContaining('These settings were changed elsewhere.'),
      findsOneWidget,
    );
    // The values now at the Gateway, not the change that was refused.
    expect(_dropdownValue(tester, 'level-done'), 'immediate');
    expect(_dropdownValue(tester, 'level-needs_you'), 'digest');
    expect(_dropdownValue(tester, 'lock-screen'), 'hidden');
    // The next change is made at the current revision.
    g.json['PATCH /api/push/subscriptions/push-phone'] = (_) => {
      'subscription': _phone(revision: 10),
    };
    await _pick(tester, 'level-calendar', 'At once');
    expect(_patch(g, 1)['revision'], 9);
    expect(
      find.textContaining('These settings were changed elsewhere.'),
      findsNothing,
    );
  });

  appTest('turning push on uses the only distributor and asks permission', (
    tester,
  ) async {
    final push = FakePush();
    final notifications = FakeNotifications();
    await _open(
      tester,
      gateway: _gateway(targets: const []),
      push: push,
      notifications: notifications,
    );
    expect(find.text('This phone gets no notifications'), findsOneWidget);
    expect(find.text('ntfy'), findsOneWidget);
    expect(find.text('Needs you'), findsNothing);
    await tester.tap(find.byKey(const Key('push-switch')));
    await tester.pumpAndSettle();
    expect(notifications.asked, 1);
    expect(push.calls, ['configure', 'enable io.heckel.ntfy']);
    expect(find.text('This phone gets notifications'), findsOneWidget);
    await tester.tap(find.byKey(const Key('push-switch')));
    await tester.pumpAndSettle();
    expect(push.calls.last, 'disable');
  });

  appTest('with no distributor it says how to get one and push stays off', (
    tester,
  ) async {
    final push = FakePush(installed: const []);
    await _open(
      tester,
      gateway: _gateway(targets: const []),
      push: push,
    );
    expect(find.textContaining('such as ntfy'), findsOneWidget);
    final toggle = tester.widget<SwitchListTile>(
      find.byKey(const Key('push-switch')),
    );
    expect(toggle.value, isFalse);
    expect(toggle.onChanged, isNull);
  });

  appTest('with several distributors one is chosen first', (tester) async {
    final push = FakePush(
      installed: const [
        PushDistributor('io.heckel.ntfy', 'ntfy'),
        PushDistributor('org.unifiedpush.distributor.nextpush', 'NextPush'),
      ],
    );
    await _open(
      tester,
      gateway: _gateway(targets: const []),
      push: push,
    );
    await tester.tap(find.byKey(const Key('push-switch')));
    await tester.pumpAndSettle();
    expect(push.calls, ['configure']);
    await _pick(tester, 'push-distributor', 'NextPush');
    await tester.tap(find.byKey(const Key('push-switch')));
    await tester.pumpAndSettle();
    expect(push.calls.last, 'enable org.unifiedpush.distributor.nextpush');
  });

  appTest('the permission is asked from this page', (tester) async {
    final notifications = FakeNotifications();
    await _open(tester, notifications: notifications);
    expect(notifications.asked, 0);
    expect(
      find.text('Android does not let pirc show notifications'),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const Key('ask-permission')));
    await tester.pumpAndSettle();
    expect(notifications.asked, 1);
    expect(find.text('pirc may show notifications'), findsOneWidget);
    await tester.tap(find.text('Open system notification settings'));
    expect(notifications.settingsOpened, 1);
  });

  appTest('the overlay switch shows off until "Display over other apps"', (
    tester,
  ) async {
    final notifications = FakeNotifications();
    await _open(tester, notifications: notifications);
    SwitchListTile overlay() =>
        tester.widget(find.byKey(const Key('overlay-switch')));
    expect(overlay().value, isFalse);
    await tester.tap(find.byKey(const Key('overlay-switch')));
    await tester.pumpAndSettle();
    // The system page opened; still off until it is granted.
    expect(notifications.overlayPages, 1);
    expect(overlay().value, isFalse);
    expect(find.textContaining('Off until'), findsOneWidget);
    notifications.overlayAllowed = true;
    notifications.resume();
    await tester.pumpAndSettle();
    expect(overlay().value, isTrue);
    await tester.tap(find.byKey(const Key('overlay-switch')));
    await tester.pumpAndSettle();
    expect(overlay().value, isFalse);
    expect(notifications.overlayWanted, isFalse);
  });

  appTest('Send test asks the Gateway', (tester) async {
    final g = await _open(tester);
    await tester.tap(find.byKey(const Key('send-test')));
    await tester.pumpAndSettle();
    expect(g.sent('POST', '/api/push/test'), hasLength(1));
    expect(find.text('Sent to 1 targets.'), findsOneWidget);
  });

  appTest('without Android push the targets are listed as before', (
    tester,
  ) async {
    final g = _gateway();
    await pumpApp(tester, gateway: g, location: '/settings/notifications');
    expect(find.text('Pixel 9'), findsOneWidget);
    expect(find.text('Send a test'), findsOneWidget);
    expect(find.byKey(const Key('push-switch')), findsNothing);
    expect(find.text('Needs you'), findsNothing);
  });
}

ApiResponse apiError409(Map<String, Object?> details) => reply(409, {
  'error': {
    'code': 'revision_mismatch',
    'message': 'Changed elsewhere',
    'details': details,
  },
});
