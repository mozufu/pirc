import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_app/src/work/environment/environment_controller.dart';

import 'support/harness.dart';
import 'support/session_fixture.dart';

const _base = '/api/sessions/s2';
const _binding = {
  'version': 1,
  'membership': {'revision': 3, 'legacyWorkspaceId': 'laptop:pirc'},
  'execution': {
    'generation': 7,
    'workspaceId': 'laptop:pirc',
    'nodeId': 'laptop',
    'modeId': 'default',
  },
};

Map<String, Object?> _status(
  String state, {
  Map<String, Object?>? progress,
  Map<String, Object?>? authority,
  String? reconciliation,
}) => {
  'transition': {'operationId': 'op1', 'sessionId': 's2', 'state': state},
  'progress': progress,
  'authority': authority,
  'reconciliationState': ?reconciliation,
};

/// s2 with an environment the test steers.
class _Env {
  _Env({this.lease}) {
    session.lease = lease;
    gateway = session.install();
    session.gateway = gateway;
    gateway.json['GET /api/workspaces'] = (_) => {
      'workspaces': [
        {'id': 'laptop:pirc', 'hostId': 'h', 'displayName': 'pirc'},
        {'id': 'laptop:pirc-wt', 'hostId': 'h', 'displayName': 'pirc worktree'},
      ],
    };
    gateway.json['GET $_base/environment'] = (_) => {
      'binding': _binding,
      'activeTransition': active,
    };
    gateway.json['GET $_base/grants'] = (_) => {
      'grantsEnabled': true,
      'effectiveAccess': {
        'grants': [
          {
            'grantId': 'g1',
            'path': '/data',
            'access': 'read',
            'effective': 'read',
          },
        ],
      },
    };
    gateway.json['POST $_base/environment-transitions/previews'] = (r) {
      previewBody = (r.json! as Map).cast();
      return {
        'preview': {
          'operationId': previewBody!['operationId'],
          'planHash': 'a' * 64,
          'targetWorkspaceId': 'laptop:pirc-wt',
        },
        'canConfirm': canConfirm,
        'blockedBy': canConfirm ? <String>[] : ['source_has_pending_work'],
        'resourcePreflight': {'status': 'observed', 'observationHash': 'obs1'},
      };
    };
    gateway.routes.add((r) {
      if (r.path.endsWith('/confirm')) {
        active = {'operationId': 'op1', 'state': 'accepted'};
        return reply(200, statusReply);
      }
      if (r.path == '$_base/environment-transitions/op1/advance' ||
          r.path == '$_base/environment-transitions/receipts/op1') {
        return reply(200, statusReply);
      }
      if (r.path == '$_base/environment-transitions/op1/reauthorize') {
        return apiError(409, 'plan_changed', 'The plan changed');
      }
      if (r.path == '$_base/environment-transitions/op1/acknowledge') {
        statusReply = _status(
          'node_fenced',
          progress: {'state': 'supervisor_drained'},
        );
        return reply(200, statusReply);
      }
      return null;
    });
  }

  final Map<String, Object?>? lease;
  final session = FixtureSession('joined-mid-stream.json');
  late final FakeGateway gateway;
  Map<String, Object?>? active;
  Map<String, Object?>? previewBody;
  bool canConfirm = true;
  Map<String, Object?> statusReply = _status(
    'accepted',
    progress: {'state': 'stopping'},
  );
}

Future<_Env> _open(WidgetTester tester, {_Env? env}) async {
  final e = env ?? _Env();
  await pumpApp(
    tester,
    gateway: e.gateway,
    location: '/work?open=s2',
    overrides: [
      transitionBackoffProvider.overrideWithValue(const [
        Duration(milliseconds: 100),
      ]),
    ],
  );
  return e;
}

Future<void> _startSwitch(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('environment-line')));
  await tester.pumpAndSettle();
  await tester.tap(find.text('Switch host…'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('pirc worktree · laptop'));
  await tester.pumpAndSettle();
}

void main() {
  appTest('the sheet shows the host and folders with their rights', (
    tester,
  ) async {
    await _open(tester);
    await tester.tap(find.byKey(const Key('environment-line')));
    await tester.pumpAndSettle();
    expect(find.text('/data'), findsOneWidget);
    expect(find.text('Read'), findsOneWidget);
    expect(find.text('Switch host…'), findsOneWidget);
  });

  appTest('a preview sends the binding; Cancel changes nothing', (
    tester,
  ) async {
    final e = await _open(tester);
    await _startSwitch(tester);
    expect(e.previewBody!['targetWorkspaceId'], 'laptop:pirc-wt');
    expect(e.previewBody!['expectedBinding'], _binding);
    expect(e.previewBody!['operationId'], startsWith('switch-'));
    expect(find.text('Switch to pirc worktree?'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(e.gateway.requests.any((r) => r.path.endsWith('/confirm')), isFalse);
  });

  appTest('a blocked preview says why and cannot be confirmed', (tester) async {
    final e = _Env()..canConfirm = false;
    await _open(tester, env: e);
    await _startSwitch(tester);
    expect(find.text('• Work is still running here.'), findsOneWidget);
    final confirm = tester.widget<FilledButton>(
      find.byKey(const Key('confirm-switch')),
    );
    expect(confirm.onPressed, isNull);
  });

  appTest('confirm sends the plan and observation with the lease; the banner '
      'shows the steps and the composer waits', (tester) async {
    final e = await _open(tester);
    await _startSwitch(tester);
    await tester.tap(find.byKey(const Key('confirm-switch')));
    await tester.pumpAndSettle();
    final confirm = e.gateway.requests.firstWhere(
      (r) => r.path.endsWith('/confirm'),
    );
    expect(confirm.json, {
      'planHash': 'a' * 64,
      'observationHash': 'obs1',
      'clientId': isNotEmpty,
      'generation': 1,
    });
    expect(find.byKey(const Key('environment-banner')), findsOneWidget);
    expect(find.text('Stopping work on the current host'), findsOneWidget);
    final field = tester.widget<TextField>(
      find.byKey(const Key('composer-field')),
    );
    expect(field.decoration!.hintText, 'Switching hosts. Your draft is kept.');
    // While applying, the controlling device advances it.
    e.statusReply = _status('installed');
    await tester.pump(const Duration(milliseconds: 150));
    await tester.pumpAndSettle();
    expect(find.text('Switched'), findsOneWidget);
    expect(
      e.gateway.requests.any((r) => r.path.endsWith('/op1/advance')),
      isTrue,
    );
  });

  appTest(
    'unproven revocation asks to continue; acknowledge sends the digest',
    (tester) async {
      final e = _Env()
        ..active = {'operationId': 'op1', 'state': 'node_fenced'}
        ..statusReply = _status(
          'node_fenced',
          progress: {
            'state': 'blocked',
            'revocation': {
              'status': 'unproven',
              'digest': 'd1',
              'evaluationId': 'ev-01',
            },
          },
        );
      await _open(tester, env: e);
      expect(
        find.textContaining('could not be proven removed'),
        findsOneWidget,
      );
      await tester.tap(find.text('Continue anyway'));
      await tester.pumpAndSettle();
      final ack = e.gateway.requests.firstWhere(
        (r) => r.path.endsWith('/acknowledge'),
      );
      expect((ack.json! as Map)['digest'], 'd1');
      expect((ack.json! as Map)['evaluationId'], 'ev-01');
    },
  );

  appTest('plan_changed on renewing says to preview again', (tester) async {
    final e = _Env()
      ..active = {'operationId': 'op1', 'state': 'node_fenced'}
      ..statusReply = _status(
        'node_fenced',
        authority: {'state': 'expired', 'reauthorizationRequired': true},
      );
    await _open(tester, env: e);
    await tester.tap(find.text('Renew permission'));
    await tester.pumpAndSettle();
    expect(
      find.text('The plan changed. Preview the switch again.'),
      findsOneWidget,
    );
  });

  appTest('an offline source: nothing starts on the target before it confirms', (
    tester,
  ) async {
    final e = _Env()
      ..active = {'operationId': 'op1', 'state': 'accepted'}
      ..statusReply = _status(
        'accepted',
        progress: {
          'stage': 'outcome_unknown',
          'waitReason': 'node_unavailable',
        },
        reconciliation: 'node_unavailable',
      );
    await _open(tester, env: e);
    expect(
      find.text(
        'The current host is offline. Nothing starts on the new host before it confirms.',
      ),
      findsOneWidget,
    );
  });

  appTest('a second device reads the receipt and sees the result', (
    tester,
  ) async {
    final e = _Env(lease: {'clientId': 'other-phone', 'generation': 2})
      ..active = {'operationId': 'op1', 'state': 'accepted'}
      ..statusReply = _status('installed');
    await _open(tester, env: e);
    expect(
      e.gateway.requests.any(
        (r) => r.path == '$_base/environment-transitions/receipts/op1',
      ),
      isTrue,
    );
    expect(
      e.gateway.requests.any((r) => r.path.endsWith('/advance')),
      isFalse,
      reason: 'only the controlling device advances',
    );
    expect(find.text('Switched'), findsOneWidget);
    expect(find.text('Cancel the switch'), findsNothing);
  });
}
