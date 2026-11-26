import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_app/src/format.dart';

import 'support/harness.dart';

final _now = DateTime(2026, 11, 27, 9);

Map<String, Object?> _view(String status, {String? code}) => {
  'id': 'p1',
  'status': status,
  'expiresAt': _now.millisecondsSinceEpoch + 600000,
  'serverNow': _now.millisecondsSinceEpoch,
  'deviceName': 'Pixel 9',
  'platform': 'android',
  'pairing': {'idleDays': 7, 'maxDays': 30},
  'code': ?code,
};

/// The Web build's Gateway with one pairing request, `p1`.
FakeGateway _gateway(Map<String, Object?> Function() current) {
  final gateway = FakeGateway();
  gateway.json['GET /api/pairing/approvals/p1'] = (_) => current();
  return gateway;
}

Future<void> _open(WidgetTester tester, FakeGateway gateway) => pumpApp(
  tester,
  gateway: gateway,
  web: true,
  saved: Saved.unpaired(),
  location: '/?pair=p1',
  overrides: [clockProvider.overrideWithValue(() => _now)],
);

void main() {
  group('the pairing approval page (/?pair=)', () {
    appTest('shows the device, approves, then shows the code', (tester) async {
      final gateway = _gateway(() => _view('pending'));
      gateway.json['POST /api/pairing/approvals/p1/approve'] = (_) =>
          _view('approved', code: '042917');
      await _open(tester, gateway);
      expect(find.text('Pair Pixel 9?'), findsOneWidget);
      expect(find.text('Platform: android'), findsOneWidget);
      expect(
        find.text(
          'Each new device works for 7 days without use and at most 30 days.',
        ),
        findsOneWidget,
      );
      expect(find.byKey(const Key('pairing-approval-code')), findsNothing);

      await tester.tap(find.byKey(const Key('pairing-approval-approve')));
      await tester.pumpAndSettle();
      expect(
        gateway.sent('POST', '/api/pairing/approvals/p1/approve'),
        hasLength(1),
      );
      expect(find.text('Type this code in the app'), findsOneWidget);
      final code = tester.widget<SelectableText>(
        find.byKey(const Key('pairing-approval-code')),
      );
      expect(code.data, '042 917');
      expect(code.style!.fontSize, greaterThanOrEqualTo(40));
      expect(find.byKey(const Key('pairing-approval-approve')), findsNothing);
    });

    appTest('denies', (tester) async {
      final gateway = _gateway(() => _view('pending'));
      gateway.json['POST /api/pairing/approvals/p1/deny'] = (_) =>
          _view('denied');
      await _open(tester, gateway);
      await tester.tap(find.byKey(const Key('pairing-approval-deny')));
      await tester.pumpAndSettle();
      expect(find.text('Denied. The device was not paired.'), findsOneWidget);
      expect(find.byKey(const Key('pairing-approval-code')), findsNothing);
    });

    appTest('an expired request offers no decision', (tester) async {
      await _open(tester, _gateway(() => _view('expired')));
      expect(
        find.text('This request expired. Start again in the app.'),
        findsOneWidget,
      );
      expect(find.byKey(const Key('pairing-approval-approve')), findsNothing);
      expect(find.byKey(const Key('pairing-approval-deny')), findsNothing);
    });

    appTest('a reload after Approve shows the code again', (tester) async {
      await _open(tester, _gateway(() => _view('approved', code: '042917')));
      final code = tester.widget<SelectableText>(
        find.byKey(const Key('pairing-approval-code')),
      );
      expect(code.data, '042 917');
      expect(find.byKey(const Key('pairing-approval-approve')), findsNothing);
    });

    appTest('a request decided without a code shows it was decided', (
      tester,
    ) async {
      // Claimed, or approved by another user: no code is given.
      await _open(tester, _gateway(() => _view('claimed')));
      expect(find.text('This request was already decided.'), findsOneWidget);
      expect(find.byKey(const Key('pairing-approval-code')), findsNothing);
    });

    appTest('a decision made elsewhere (409) reads the request again', (
      tester,
    ) async {
      var status = 'pending';
      final gateway = _gateway(() => _view(status));
      gateway.json['POST /api/pairing/approvals/p1/approve'] = (_) {
        status = 'denied';
        return apiError(409, 'conflict');
      };
      await _open(tester, gateway);
      await tester.tap(find.byKey(const Key('pairing-approval-approve')));
      await tester.pumpAndSettle();
      expect(find.text('This request was already decided.'), findsOneWidget);
    });

    appTest('an unknown request says so', (tester) async {
      await _open(tester, FakeGateway());
      expect(
        find.text('This request does not exist or has expired.'),
        findsOneWidget,
      );
    });

    appTest('does not exist in the native builds', (tester) async {
      final gateway = _gateway(() => _view('pending'));
      await pumpApp(tester, gateway: gateway, location: '/?pair=p1');
      expect(find.text('Pair Pixel 9?'), findsNothing);
      expect(gateway.requests.any((r) => r.path.contains('p1')), isFalse);
    });
  });
}
