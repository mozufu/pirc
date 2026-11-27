@Tags(['golden'])
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_app/src/connection/pairing.dart';
import 'package:pirc_app/src/connection/pairing_v2.dart';
import 'package:pirc_app/src/format.dart';
import 'package:pirc_app/src/notifications/notification_open.dart';
import 'package:pirc_app/src/platform/links.dart';
import 'package:pirc_app/src/preferences.dart';
import 'package:pirc_client/pirc_client.dart';

import 'support/fonts.dart';
import 'support/harness.dart';
import 'support/session_fixture.dart';

/// M8 step 9: the screens M8 added, at the four widths in both themes.
/// Pairing v2 (address, waiting, approved, wrong code, denied, expired), the
/// Web approval page (pending, approved with the code, denied, expired), the
/// notification check and its five results. Settings → Notifications is
/// already covered by `screens_golden_test.dart`.
final _now = DateTime(2026, 11, 27, 9);
const _poll = Duration(seconds: 1);
const _options = ['Only the 3 failures', 'All of them', 'Report only'];

Future<void> _loadFonts(WidgetTester tester) =>
    tester.runAsync(loadGoldenFonts);

Future<void> _theme(
  WidgetTester tester,
  ProviderContainer container,
  ThemeMode mode, {
  bool settle = true,
}) async {
  container.read(themeModeProvider.notifier).select(mode);
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    await tester.pump();
  }
}

/// Drops the text-field focus, so a blinking caret is not in the image.
Future<void> _settle(WidgetTester tester) async {
  FocusManager.instance.primaryFocus?.unfocus();
  await tester.pumpAndSettle();
}

void _goldens(
  String name,
  Future<void> Function(WidgetTester tester, double width, ThemeMode mode)
  body, {
  bool capture = true,
}) {
  for (final width in goldenWidths) {
    for (final mode in [ThemeMode.light, ThemeMode.dark]) {
      appTest('$name ${width.toInt()} ${mode.name}', (tester) async {
        await body(tester, width, mode);
        if (capture) await _capture(tester, name, width, mode);
      });
    }
  }
}

Future<void> _capture(
  WidgetTester tester,
  String name,
  double width,
  ThemeMode mode,
) => expectLater(
  find.byType(MaterialApp),
  matchesGoldenFile('goldens/${name}_${width.toInt()}_${mode.name}.png'),
);

/// A Gateway with one pairing v2 request, `p1`.
class _Pairing {
  _Pairing({this.ttl = const Duration(minutes: 10)}) {
    gateway.json['POST /api/pairing/requests'] = (_) {
      return reply(201, {
        'id': 'p1',
        'expiresAt': _now.add(ttl).millisecondsSinceEpoch,
        'serverNow': _now.millisecondsSinceEpoch,
        'approvePath': '/?pair=p1',
      });
    };
    gateway.routes.add((request) {
      if (request.path != '/api/pairing/requests/p1/claim') return null;
      final body = request.json! as Map<String, Object?>;
      final code = body['code'] as String?;
      if (ended != null) return ended;
      if (code == null || status == 'pending') {
        return reply(202, {
          'status': status,
          'expiresAt': _now.add(ttl).millisecondsSinceEpoch,
          'serverNow': _now.millisecondsSinceEpoch,
        });
      }
      if (code != '123456') {
        return reply(403, {
          'error': {
            'code': 'invalid_code',
            'message': 'The confirmation code is wrong',
            'details': {'attemptsLeft': 4},
          },
        });
      }
      return reply(200, {
        'device': {
          'id': 'd1',
          'name': 'Android phone',
          'createdAt': _now.millisecondsSinceEpoch,
          'expiresAt': _now
              .add(const Duration(days: 30))
              .millisecondsSinceEpoch,
          'lastUsedAt': _now.millisecondsSinceEpoch,
          'idleExpiresAt': _now
              .add(const Duration(days: 7))
              .millisecondsSinceEpoch,
        },
        'token': 'pirc_dev_v2',
      });
    });
  }

  final Duration poll = _poll;
  final Duration ttl;
  final gateway = FakeGateway();
  final links = FakeAppLinks();
  final saved = Saved.unpaired();
  String status = 'pending';
  ApiResponse? ended;

  Future<void> begin(WidgetTester tester) async {
    await tester.enterText(
      find.byKey(const Key('pairing-v2-address')),
      'https://gateway.test',
    );
    await tester.tap(find.byKey(const Key('pairing-v2-start')));
    await tester.pumpAndSettle();
  }

  Future<void> approve(WidgetTester tester) async {
    status = 'approved';
    await tester.pump(poll);
    await tester.pumpAndSettle();
  }

  Future<void> sendCode(WidgetTester tester, String code) async {
    await tester.enterText(find.byKey(const Key('pairing-v2-code')), code);
    await tester.tap(find.byKey(const Key('pairing-v2-claim')));
    await tester.pumpAndSettle();
  }
}

Future<ProviderContainer> _pumpPairing(
  WidgetTester tester,
  _Pairing pairing,
  double width,
  ThemeMode mode,
) async {
  await _loadFonts(tester);
  final container = await pumpApp(
    tester,
    gateway: pairing.gateway,
    saved: pairing.saved,
    width: width,
    height: goldenHeight(width),
    links: pairing.links,
    reduceMotion: true,
    overrides: [
      pairingV2EnabledProvider.overrideWithValue(true),
      pairingV2PollIntervalProvider.overrideWithValue(pairing.poll),
      clockProvider.overrideWithValue(() => _now),
    ],
  );
  await _theme(tester, container, mode);
  return container;
}

Map<String, Object?> _approvalView(String status, {String? code}) => {
  'id': 'p1',
  'status': status,
  'expiresAt': _now.add(const Duration(minutes: 10)).millisecondsSinceEpoch,
  'serverNow': _now.millisecondsSinceEpoch,
  'deviceName': 'Pixel 9',
  'platform': 'android',
  'pairing': {'idleDays': 7, 'maxDays': 30},
  'code': ?code,
};

FakeGateway _approvalGateway(Map<String, Object?> Function() current) {
  final gateway = FakeGateway();
  gateway.json['GET /api/pairing/approvals/p1'] = (_) => current();
  return gateway;
}

Future<ProviderContainer> _pumpApproval(
  WidgetTester tester,
  FakeGateway gateway,
  double width,
  ThemeMode mode,
) async {
  await _loadFonts(tester);
  final container = await pumpApp(
    tester,
    gateway: gateway,
    web: true,
    saved: Saved.unpaired(),
    location: '/?pair=p1',
    width: width,
    height: goldenHeight(width),
    reduceMotion: true,
    overrides: [clockProvider.overrideWithValue(() => _now)],
  );
  await _theme(tester, container, mode);
  return container;
}

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
    for (final option in _options) {'id': option, 'label': option},
  ],
  'expiresAt': _now.add(const Duration(minutes: 14)).millisecondsSinceEpoch,
  'controlHolder': null,
  'answeredBy': answeredBy,
};

ApiResponse _check(String state, {Map<String, Object?>? answeredBy}) =>
    reply(200, _compact(state, answeredBy: answeredBy));

/// s2 with question q1 pending; the compact route answers [read].
FakeGateway _checkGateway(
  FutureOr<ApiResponse> Function() read, {
  Map<String, Object?>? lease,
}) {
  final session = FixtureSession('joined-mid-stream.json')..lease = lease;
  (session.snapshot['session']! as Map<String, Object?>)['name'] =
      'Check nightly test';
  session.snapshot['history'] = [
    {
      'role': 'user',
      'content': 'Run the nightly tests and rerun only the failures.',
      'timestamp': 1200,
    },
    {
      'role': 'assistant',
      'content': [
        {
          'type': 'text',
          'text':
              '3 failures, all in `sync/reconnect.test.ts`; the assertions '
              'themselves pass.',
        },
      ],
      'stopReason': 'stop',
      'timestamp': 1300,
    },
  ];
  session.snapshot['interactions'] = [
    {
      'id': 'q1',
      'kind': 'select',
      'runnerEpoch': 1,
      'status': 'pending',
      'expiresAt': _now.add(const Duration(minutes: 14)).millisecondsSinceEpoch,
      'request': {'title': 'Run only the failed cases?', 'options': _options},
    },
  ];
  final gateway = session.install();
  session.gateway = gateway;
  gateway.routes.add(
    (request) =>
        request.method == 'GET' &&
            request.path == '/api/sessions/s2/interactions/q1'
        ? read()
        : null,
  );
  return gateway;
}

String _notificationLocation({String? choice}) => Uri(
  path: notificationCheckPath,
  queryParameters: {
    'session': 's2',
    'interaction': 'q1',
    'epoch': '1',
    'choice': ?choice,
    'label': ?choice,
  },
).toString();

Future<ProviderContainer> _pumpCheck(
  WidgetTester tester,
  FakeGateway gateway,
  double width,
  ThemeMode mode, {
  String? choice = 'All of them',
  bool settle = true,
}) async {
  await _loadFonts(tester);
  final container = await pumpApp(
    tester,
    gateway: gateway,
    saved: Saved(),
    location: _notificationLocation(choice: choice),
    width: width,
    height: goldenHeight(width),
    reduceMotion: true,
    settle: settle,
    overrides: [clockProvider.overrideWithValue(() => _now)],
  );
  await _theme(tester, container, mode, settle: settle);
  return container;
}

Future<void> _expectCheckText(WidgetTester tester, String text) async {
  expect(find.text(text), findsOneWidget);
}

void main() {
  _goldens('pairing_v2_address', (tester, width, mode) async {
    final pairing = _Pairing();
    await _pumpPairing(tester, pairing, width, mode);
    await tester.enterText(
      find.byKey(const Key('pairing-v2-address')),
      'https://gateway.test',
    );
    await _settle(tester);
  });

  _goldens('pairing_v2_waiting', (tester, width, mode) async {
    final pairing = _Pairing();
    await _pumpPairing(tester, pairing, width, mode);
    await pairing.begin(tester);
    await _expectCheckText(tester, 'Waiting for the approval in the browser…');
  });

  _goldens('pairing_v2_approved', (tester, width, mode) async {
    final pairing = _Pairing();
    await _pumpPairing(tester, pairing, width, mode);
    await pairing.begin(tester);
    await pairing.approve(tester);
    await _expectCheckText(
      tester,
      'Approved. Type the 6-digit code that the browser shows.',
    );
  });

  _goldens('pairing_v2_wrong_code', (tester, width, mode) async {
    final pairing = _Pairing();
    await _pumpPairing(tester, pairing, width, mode);
    await pairing.begin(tester);
    await pairing.approve(tester);
    await pairing.sendCode(tester, '000000');
    await _expectCheckText(tester, 'Wrong code. 4 tries left.');
    await _settle(tester);
  });

  _goldens('pairing_v2_denied', (tester, width, mode) async {
    final pairing = _Pairing();
    await _pumpPairing(tester, pairing, width, mode);
    await pairing.begin(tester);
    pairing.ended = apiError(410, 'pairing_ended');
    await tester.pump(_poll);
    await tester.pumpAndSettle();
    await _expectCheckText(
      tester,
      'The request was denied in the browser. Start again to make a new one.',
    );
  });

  _goldens('pairing_v2_expired', (tester, width, mode) async {
    final pairing = _Pairing(ttl: const Duration(seconds: 5));
    await _pumpPairing(tester, pairing, width, mode);
    await pairing.begin(tester);
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    await _expectCheckText(
      tester,
      'The request expired. Start again to make a new one.',
    );
  });

  _goldens('pairing_approval_pending', (tester, width, mode) async {
    await _pumpApproval(
      tester,
      _approvalGateway(() => _approvalView('pending')),
      width,
      mode,
    );
    expect(find.text('Pair Pixel 9?'), findsOneWidget);
  });

  _goldens('pairing_approval_approved', (tester, width, mode) async {
    final gateway = _approvalGateway(() => _approvalView('pending'));
    gateway.json['POST /api/pairing/approvals/p1/approve'] = (_) =>
        _approvalView('approved', code: '042917');
    await _pumpApproval(tester, gateway, width, mode);
    await tester.tap(find.byKey(const Key('pairing-approval-approve')));
    await tester.pumpAndSettle();
    expect(find.text('Type this code in the app'), findsOneWidget);
  });

  _goldens('pairing_approval_denied', (tester, width, mode) async {
    final gateway = _approvalGateway(() => _approvalView('pending'));
    gateway.json['POST /api/pairing/approvals/p1/deny'] = (_) =>
        _approvalView('denied');
    await _pumpApproval(tester, gateway, width, mode);
    await tester.tap(find.byKey(const Key('pairing-approval-deny')));
    await tester.pumpAndSettle();
    expect(find.text('Denied. The device was not paired.'), findsOneWidget);
  });

  _goldens('pairing_approval_expired', (tester, width, mode) async {
    await _pumpApproval(
      tester,
      _approvalGateway(() => _approvalView('expired')),
      width,
      mode,
    );
    expect(
      find.text('This request expired. Start again in the app.'),
      findsOneWidget,
    );
  });

  _goldens('notification_checking', (tester, width, mode) async {
    final read = Completer<ApiResponse>();
    await _pumpCheck(
      tester,
      _checkGateway(() => read.future),
      width,
      mode,
      choice: null,
      settle: false,
    );
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(
      find.text('Reconnecting and checking the latest state'),
      findsOneWidget,
    );
    // The check is still reading; take the image, then let it end so its
    // time limit is not a pending timer when the test closes.
    await _capture(tester, 'notification_checking', width, mode);
    read.complete(reply(200, _compact('expired')));
    await tester.pumpAndSettle();
  }, capture: false);

  _goldens('notification_still_open', (tester, width, mode) async {
    await _pumpCheck(
      tester,
      _checkGateway(() => _check('pending')),
      width,
      mode,
    );
    expect(find.text('Confirm your answer'), findsOneWidget);
    expect(
      find.textContaining('the question is still open, control on this'),
      findsOneWidget,
    );
  });

  _goldens('notification_answered', (tester, width, mode) async {
    await _pumpCheck(
      tester,
      _checkGateway(
        () => _check(
          'answered',
          answeredBy: {
            'deviceName': 'iPad',
            'at': DateTime(2026, 11, 27, 8, 51).millisecondsSinceEpoch,
          },
        ),
      ),
      width,
      mode,
    );
    await _expectCheckText(tester, 'This was already handled');
    await _expectCheckText(tester, 'Answered on iPad · 08:51');
  });

  _goldens('notification_expired', (tester, width, mode) async {
    await _pumpCheck(
      tester,
      _checkGateway(() => _check('expired')),
      width,
      mode,
    );
    await _expectCheckText(tester, 'This question expired');
    await _expectCheckText(tester, 'It can no longer be answered.');
  });

  _goldens('notification_controlled', (tester, width, mode) async {
    await _pumpCheck(
      tester,
      _checkGateway(
        () => _check('pending'),
        lease: {
          'clientId': 'mac',
          'generation': 3,
          'expiresAt': _now
              .add(const Duration(minutes: 5))
              .millisecondsSinceEpoch,
          'holder': {'name': 'MacBook', 'kind': 'browser'},
        },
      ),
      width,
      mode,
    );
    await _expectCheckText(
      tester,
      'Controlled by MacBook. Take control to send.',
    );
  });

  _goldens('notification_offline', (tester, width, mode) async {
    await _pumpCheck(
      tester,
      _checkGateway(() => throw const TransportException('offline')),
      width,
      mode,
    );
    await _expectCheckText(tester, 'Could not check the latest state');
    await _expectCheckText(tester, 'Your choice is kept: All of them');
    await _expectCheckText(tester, 'Try again');
  });
}
