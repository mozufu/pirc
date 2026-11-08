import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_mobile/live/environment_switch_card.dart';
import 'package:pirc_mobile/live/environment_transitions.dart';
import 'package:pirc_mobile/live/gateway.dart';
import 'live_test.dart' show FakeGateway, theme;

// C4 G1–G5, C1 operation authority, C2 evidence and C3 cancellation/readiness.

typedef Call = ({String method, String path, Json? body});

class Fake {
  Fake(this.route) {
    gateway.handler = (method, args) async {
      if (method != 'request') return null;
      final call = (
        method: '${args['method']}',
        path: '${args['path']}',
        body: args['body'] == null ? null : obj(args['body']),
      );
      log.add(call);
      return route(call);
    };
  }
  FutureOr<dynamic> Function(Call) route;
  final gateway = FakeGateway();
  final log = <Call>[];
  late final api = EnvironmentTransitionApi(gateway);
  List<Call> to(String part) =>
      log.where((c) => c.path.contains(part)).toList();
  List<Call> get posts => log.where((c) => c.method == 'POST').toList();
}

PlatformException http(int status, [String? code]) => PlatformException(
  code: 'HTTP_$status',
  message: code,
  details: {'status': status, 'code': code},
);

const base = '/api/sessions/s/environment-transitions';
Json binding(int generation, [String workspace = 'node:repo']) => {
  'version': 1,
  'execution': {'generation': generation, 'workspaceId': workspace},
};
Json env({
  String? active,
  String state = 'node_fenced',
  Json? extra,
  Json? last,
}) => {
  'version': 1,
  'binding': binding(1),
  'activeTransition': active == null
      ? null
      : {
          'operationId': active,
          'state': state,
          'targetWorkspaceId': 'node:target',
          'revocationConfirmed': false,
          'targetInstalled': false,
          ...?extra,
        },
  'lastFinishedTransition': last,
};
Json item(
  String kind,
  String reason, {
  bool inherited = false,
  int? generation = 2,
}) => {
  'kind': kind,
  'reason': reason,
  'acknowledgeable': true,
  'inherited': inherited,
  'generation': generation,
};
Json revocation({
  String status = 'unproven',
  String current = 'confirmed',
  String digest = 'd1',
  String evaluation = 'ev-01',
  List<Json>? items,
  int? total,
}) {
  final shown =
      items ?? [item('platform_containment', 'descendants_not_contained')];
  return {
    'status': status,
    'digest': digest,
    'evaluationId': evaluation,
    'itemsTotal': total ?? shown.length,
    'confirmsContainment': false,
    'items': shown,
    'currentGeneration': {'status': current, 'itemsTotal': 0},
  };
}

Json status(
  String state, {
  Json? progress,
  Json? authority,
  Json? cancellation,
  bool confirmed = false,
}) => {
  'transition': {
    'operationId': 'op1',
    'sessionId': 's',
    'state': state,
    'createdAt': 1,
    'revocationConfirmed': confirmed,
    'targetInstalled': state == 'installed',
  },
  'canConfirm': false,
  'progress': progress,
  'authority': authority,
  'cancellation': cancellation,
};
Json fenced({
  Json? rev,
  Json? authority,
  Json? cancellation,
  String fence = 'supervisor_drained',
}) => status(
  'node_fenced',
  progress: {
    'state': fence,
    'observedAt': 1700,
    'revocation': rev,
    'cancellation': cancellation,
    'installation': null,
  },
  authority: authority,
  cancellation: cancellation == null
      ? null
      : {'requestedAt': cancellation['requestedAt']},
);
Json installed(String? ready, {bool confirmed = true}) => status(
  'installed',
  confirmed: confirmed,
  progress: {
    'state': 'installed',
    'observedAt': 1800,
    'revocation': null,
    'installation': {
      'revocation': confirmed ? 'confirmed' : 'unproven',
      'environmentEvent': 'queued',
      'bindingCommitted': true,
      'policyValidated': true,
      'runtimeReady': ready,
    },
  },
);
Json authority(String state) => {
  'revision': 1,
  'deadlineAt': 2000000000000,
  'state': state,
  'reauthorizationRequired': state != 'active',
};
Json page(String id, List<Json> items, String? next, {int total = 3}) => {
  'evaluation': {
    'evaluationId': id,
    'digest': 'digest-$id',
    'status': 'unproven',
    'itemsTotal': total,
    'items': items,
    'next': next,
  },
};

TransitionLease? held = const TransitionLease('phone', 4);
final flows = <EnvironmentTransitionFlow>[];
final waits = <Duration>[];
EnvironmentTransitionFlow flow(Fake fake) {
  var serial = 0;
  final f = EnvironmentTransitionFlow(
    api: fake.api,
    session: 's',
    lease: () => held,
    newId: () => 'op${++serial}',
    wait: (d) {
      waits.add(d);
      return Future<void>.delayed(Duration.zero);
    },
  );
  flows.add(f);
  return f;
}

Future<void> settle() => pumpEventQueue(times: 200);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    held = const TransitionLease('phone', 4);
    waits.clear();
  });
  tearDown(() {
    for (final f in flows) {
      f.dispose();
    }
    flows.clear();
  });

  group('read model (C4 G1–G5)', () {
    test('without control the receipt GET is the full read model', () async {
      held = null;
      final fake = Fake(
        (c) => c.path.endsWith('/environment')
            ? env(active: 'op1')
            : fenced(rev: revocation(), authority: authority('active')),
      );
      final f = flow(fake);
      await f.load();
      expect(fake.log.last.path, '$base/receipts/op1');
      expect(fake.posts, isEmpty);
      expect(f.status, EnvironmentSwitchStatus.unproven);
      expect(f.transition!.observedAt, 1700);
      expect(f.transition!.authority!.state, 'active');
      expect(f.shownItems.single.kind, 'platform_containment');
      expect(f.actions, {EnvironmentSwitchAction.refresh});
      expect(f.targetWorkspaceId, 'node:target');
    });

    test('the last finished switch is discoverable after reload', () async {
      final fake = Fake(
        (c) => env(
          last: {
            'operationId': 'old',
            'state': 'installed',
            'createdAt': 5,
            'targetWorkspaceId': 'node:target',
            'targetInstalled': true,
            'revocationConfirmed': false,
          },
        ),
      );
      final f = flow(fake);
      await f.load();
      expect(f.status, EnvironmentSwitchStatus.idle);
      expect(f.lastFinished!.operationId, 'old');
      expect(f.lastFinished!.targetWorkspaceId, 'node:target');
      expect(
        lastFinishedText(f.lastFinished!),
        'Last switch: switched; revocation not fully confirmed.',
      );
      expect(
        lastFinishedText(
          TransitionSummary({'state': 'released', 'targetInstalled': false}),
        ),
        'Last switch: cancelled; original workspace kept.',
      );
    });

    test('a bare Node fence offers only read-only reconciliation', () async {
      var cleared = false;
      final fake = Fake((c) {
        if (c.path.endsWith('/environment')) {
          return cleared
              ? env()
              : env(
                  active: 'bare',
                  state: 'reconciliation_required',
                  extra: {
                    'recoveryReason': 'no_gateway_acceptance',
                    'safeActions': ['reconcile'],
                  },
                );
        }
        if (c.path.endsWith('/previews/bare/reconcile')) {
          cleared = true;
          return {'transition': {}};
        }
        throw StateError('unexpected ${c.path}');
      });
      final f = flow(fake);
      await f.load();
      expect(f.status, EnvironmentSwitchStatus.reconciliationRequired);
      expect(f.operationId, 'bare');
      expect(f.actions, {EnvironmentSwitchAction.reconcile});
      expect(environmentSwitchMessage(f), contains('never accepted'));
      // Not consent: nothing advances, acknowledges or cancels it.
      await f.cancel();
      await f.acknowledge();
      await f.refresh();
      expect(fake.posts, isEmpty);
      expect(fake.to('/receipts/'), isEmpty);
      await f.reconcile();
      expect(fake.posts.single.path, '$base/previews/bare/reconcile');
      expect(fake.posts.single.body, isNull);
      expect(f.status, EnvironmentSwitchStatus.idle);
    });

    test('history pages newest first and follows next', () async {
      final fake = Fake((c) {
        final uri = Uri.parse('https://x${c.path}');
        expect(uri.path, base);
        return switch (uri.queryParameters['cursor']) {
          null => {
            'transitions': {
              'version': 1,
              'items': [
                {'operationId': 'b', 'state': 'node_fenced', 'createdAt': 2},
              ],
              'next': '2.b',
            },
          },
          '2.b' => {
            'transitions': {
              'version': 1,
              'items': [
                {
                  'operationId': 'a',
                  'state': 'installed',
                  'createdAt': 1,
                  'targetInstalled': true,
                  'revocationConfirmed': true,
                },
              ],
              'next': null,
            },
          },
          _ => throw StateError('cursor'),
        };
      });
      final f = flow(fake);
      await f.loadHistory(limit: 1);
      expect(fake.log.single.path, '$base?limit=1');
      expect(f.historyNext, '2.b');
      await f.loadHistory(more: true, limit: 1);
      expect(fake.log.last.path, '$base?cursor=2.b&limit=1');
      expect(f.history.map((h) => h.operationId), ['b', 'a']);
      expect(f.history.last.revocationConfirmed, true);
      expect(f.historyNext, isNull);
      await f.loadHistory(more: true);
      expect(fake.log.length, 2);
    });

    test('an acceptance that needs review offers only cancel', () async {
      final fake = Fake((c) {
        if (c.path.endsWith('/environment')) {
          return env(active: 'op1', state: 'accepted');
        }
        if (c.path.endsWith('/cancel')) return status('released');
        return status(
          'accepted',
          progress: {
            'stage': 'review_required',
            'waitReason': 'lost_control',
            'safeActions': ['cancel'],
            'revocationConfirmed': false,
            'targetInstalled': false,
          },
        );
      });
      final f = flow(fake);
      await f.load();
      expect(f.status, EnvironmentSwitchStatus.reviewRequired);
      expect(f.transition!.waitReason, 'lost_control');
      expect(f.actions, {
        EnvironmentSwitchAction.refresh,
        EnvironmentSwitchAction.cancel,
      });
      expect(environmentSwitchMessage(f), contains('Take control'));
      await f.cancel();
      expect(f.status, EnvironmentSwitchStatus.released);
    });

    test('only the specific 404 codes mean "not stored"', () async {
      for (final code in [
        'preview_not_found',
        'acceptance_not_found',
        'receipt_not_found',
        'conversation_not_found',
      ]) {
        expect(transitionNotStored(http(404, code)), true, reason: code);
        expect(transitionReasonText(code), isNot(code));
      }
      expect(transitionNotStored(http(404, 'not_found')), false);
      expect(transitionNotStored(http(409, 'receipt_not_found')), false);

      // A generic 404 after a lost confirm is a refusal, not "not accepted".
      var confirms = 0;
      final fake = Fake((c) {
        if (c.path.endsWith('/environment')) return env();
        if (c.path.endsWith('/previews')) {
          return {
            'preview': {
              'operationId': 'op1',
              'targetWorkspaceId': 'node:target',
              'planHash': 'p',
            },
            'state': 'preview',
            'canConfirm': true,
            'blockedBy': [],
            'resourcePreflight': {'status': 'observed', 'observationHash': 'o'},
          };
        }
        if (c.path.endsWith('/confirm')) {
          confirms++;
          throw http(504, 'node_timeout');
        }
        throw http(404, 'not_found');
      });
      final f = flow(fake);
      await f.load();
      await f.startPreview('node:target');
      await f.confirm();
      expect(f.status, EnvironmentSwitchStatus.failed);
      expect(f.actions, isNot(contains(EnvironmentSwitchAction.confirm)));
      expect(confirms, 1);
    });
  });

  group('operation authority (C1)', () {
    test('the preview shows the finite authority before Confirm', () {
      final available = TransitionPreview({
        'operationAuthority': {'available': true, 'durationSeconds': 1800},
      });
      expect(available.operationAuthorityAvailable, true);
      expect(available.operationAuthoritySeconds, 1800);
      expect(
        operationAuthorityPreviewText(available),
        'After you confirm, the Gateway may finish this switch without this device for 30 minutes.',
      );
      expect(
        operationAuthorityPreviewText(
          TransitionPreview({
            'operationAuthority': {'available': true, 'durationSeconds': 7200},
          }),
        ),
        contains('2 hours'),
      );
      expect(
        operationAuthorityPreviewText(
          TransitionPreview({
            'operationAuthority': {'available': false, 'durationSeconds': null},
          }),
        ),
        'This switch continues only while a device holds control.',
      );
      expect(transitionDurationText(45), '45 seconds');
    });

    test('every non-active authority requires reauthorization', () {
      for (final state in ['expired', 'revoked', 'clock_uncertain']) {
        final value = TransitionStatus(
          fenced(
            rev: revocation(status: 'confirmed'),
            authority: authority(state),
          ),
        );
        expect(
          transitionStatusFor(value),
          EnvironmentSwitchStatus.reauthorizationRequired,
          reason: state,
        );
        expect(transitionNeedsPolling(value), false);
        expect(
          operationAuthorityText(value.authority!),
          contains('reauthorize'),
        );
      }
      final active = TransitionStatus(
        fenced(
          rev: revocation(status: 'confirmed'),
          authority: authority('active'),
        ),
      );
      expect(transitionStatusFor(active), EnvironmentSwitchStatus.installing);
      expect(
        operationAuthorityText(active.authority!),
        contains('valid until'),
      );
    });

    test(
      'expiry → reauthorize by the current controller → installed',
      () async {
        final fake = Fake((c) {
          if (c.path.endsWith('/environment')) return env(active: 'op1');
          if (c.path.endsWith('/reauthorize')) return installed('not_started');
          return fenced(
            rev: revocation(status: 'confirmed'),
            authority: authority('expired'),
          );
        });
        final f = flow(fake);
        await f.load();
        expect(f.status, EnvironmentSwitchStatus.reauthorizationRequired);
        expect(
          f.actions,
          containsAll([
            EnvironmentSwitchAction.reauthorize,
            EnvironmentSwitchAction.refresh,
            EnvironmentSwitchAction.cancel,
          ]),
        );
        expect(environmentSwitchMessage(f), contains('expired'));
        await f.reauthorize();
        expect(fake.to('/reauthorize').single.body, {
          'clientId': 'phone',
          'generation': 4,
        });
        expect(fake.to('/reauthorize').single.path, '$base/op1/reauthorize');
        expect(f.status, EnvironmentSwitchStatus.installedConfirmed);

        // Without control nothing is offered or sent.
        held = null;
        final reader = Fake(
          (c) => c.path.endsWith('/environment')
              ? env(active: 'op1')
              : fenced(authority: authority('revoked')),
        );
        final r = flow(reader);
        await r.load();
        expect(r.actions, {EnvironmentSwitchAction.refresh});
        await r.reauthorize();
        expect(reader.posts, isEmpty);
      },
    );

    test('plan_changed explains that a new switch is needed', () async {
      final fake = Fake((c) {
        if (c.path.endsWith('/environment')) return env(active: 'op1');
        if (c.path.endsWith('/reauthorize')) throw http(409, 'plan_changed');
        return fenced(authority: authority('expired'));
      });
      final f = flow(fake);
      await f.load();
      await f.reauthorize();
      expect(f.status, EnvironmentSwitchStatus.failed);
      expect(
        environmentSwitchMessage(f),
        'The reviewed environment changed. Cancel this switch and review a new one.',
      );
      expect(f.actions, contains(EnvironmentSwitchAction.cancel));
    });

    test('authority refusals pass through and re-read the status', () async {
      for (final code in [
        'operation_authority_missing',
        'operation_authority_superseded',
        'operation_authority_revoked',
        'operation_authority_expired',
        'operation_authority_clock_uncertain',
        'operation_authority_revision',
        'operation_authority_unavailable',
      ]) {
        final fake = Fake((c) {
          if (c.path.endsWith('/environment')) return env(active: 'op1');
          if (c.path.endsWith('/reauthorize')) throw http(409, code);
          return fenced(authority: authority('expired'));
        });
        final f = flow(fake);
        await f.load();
        await f.reauthorize();
        expect(f.errorCode, code);
        expect(transitionReasonText(code), isNot(code));
        expect(
          environmentSwitchMessage(f),
          contains(transitionReasonText(code)),
        );
        expect(fake.to('/reauthorize').length, 1, reason: code);
      }
    });

    test('an ambiguous reauthorization is resolved by reading', () async {
      var reads = 0;
      final fake = Fake((c) {
        if (c.path.endsWith('/environment')) return env(active: 'op1');
        if (c.path.endsWith('/reauthorize')) {
          throw http(502, 'transition_step_failed');
        }
        return ++reads == 1
            ? fenced(authority: authority('expired'))
            : installed('ready');
      });
      final f = flow(fake);
      await f.load();
      await f.reauthorize();
      expect(fake.to('/reauthorize').length, 1);
      expect(fake.to('/advance').length, 2);
      expect(f.status, EnvironmentSwitchStatus.installedConfirmed);
    });
  });

  group('evidence (C2)', () {
    test('both reports and inherited labels are shown', () async {
      final fake = Fake(
        (c) => c.path.endsWith('/environment')
            ? env(active: 'op1')
            : fenced(
                rev: revocation(
                  items: [
                    item(
                      'host_terminal',
                      'host_effects_may_survive',
                      inherited: true,
                      generation: 1,
                    ),
                    item(
                      'legacy_history',
                      'launches_before_journals',
                      inherited: true,
                      generation: null,
                    ),
                  ],
                ),
              ),
      );
      final f = flow(fake);
      await f.load();
      final rev = f.transition!.revocation!;
      expect(rev.evaluationId, 'ev-01');
      expect(rev.currentGenerationStatus, 'confirmed');
      expect(rev.currentGenerationItemsTotal, 0);
      expect(
        revocationReportText(rev),
        'Current environment: confirmed. Including earlier environments: not fully proven.',
      );
      expect(environmentSwitchMessage(f), contains('Current environment'));
      expect(f.shownItems.map(revocationItemText), [
        'Host-management terminal: detached host work may survive (inherited from environment 1)',
        'Earlier history: started before complete tracking existed (inherited from earlier history)',
      ]);
      expect(
        revocationItemText(RevocationItem(item('terminal', 'unresolved'))),
        'Terminal: still unresolved',
      );
    });

    test('pages the stable snapshot and acknowledges all N items', () async {
      final fake = Fake((c) {
        if (c.path.endsWith('/environment')) return env(active: 'op1');
        if (c.path.contains('/evaluations/ev-01')) {
          return c.path.contains('cursor=50')
              ? page(
                  'ev-01',
                  [item('host_command', 'host_effects_may_survive')],
                  null,
                  total: 121,
                )
              : page(
                  'ev-01',
                  [item('platform_containment', 'descendants_not_contained')],
                  '50',
                  total: 121,
                );
        }
        if (c.path.endsWith('/acknowledge')) {
          return installed('ready', confirmed: false);
        }
        return fenced(rev: revocation(total: 121));
      });
      final f = flow(fake);
      await f.load();
      expect(f.actions, contains(EnvironmentSwitchAction.moreItems));
      expect(acknowledgeLabel(f), 'Acknowledge all 121 items and switch');
      await f.loadMoreItems(limit: 50);
      expect(fake.log.last.path, '$base/op1/evaluations/ev-01?limit=50');
      await f.perform(EnvironmentSwitchAction.moreItems);
      expect(fake.log.last.path, '$base/op1/evaluations/ev-01?cursor=50');
      expect(f.shownItems.length, 2);
      expect(f.moreItemsAvailable, false);
      expect(f.actions, isNot(contains(EnvironmentSwitchAction.moreItems)));
      expect(fake.posts.where((c) => !c.path.endsWith('/advance')), isEmpty);
      await f.acknowledge();
      expect(fake.to('/acknowledge').single.body, {
        'digest': 'd1',
        'evaluationId': 'ev-01',
        'clientId': 'phone',
        'generation': 4,
      });
      expect(f.status, EnvironmentSwitchStatus.installedUnconfirmed);
    });

    test('a digest change while paging restarts on the new evaluation', () async {
      var reads = 0;
      final fake = Fake((c) {
        if (c.path.endsWith('/environment')) return env(active: 'op1');
        if (c.path.contains('/evaluations/')) {
          final id = c.path.contains('ev-01') ? 'ev-01' : 'ev-02';
          return page(id, [
            item('host_command', 'host_effects_may_survive'),
          ], 'next-$id');
        }
        if (c.path.endsWith('/acknowledge')) {
          throw http(409, 'revocation_digest_changed');
        }
        return ++reads == 1
            ? fenced(rev: revocation(total: 3))
            : fenced(
                rev: revocation(digest: 'd2', evaluation: 'ev-02', total: 4),
              );
      });
      final f = flow(fake);
      await f.load();
      await f.loadMoreItems();
      expect(f.pagedEvaluationId, 'ev-01');
      expect(f.evaluationNext, 'next-ev-01');
      await f.acknowledge();
      // Re-read: the new evaluation replaces the pages; never auto-acknowledged.
      expect(fake.to('/acknowledge').length, 1);
      expect(f.transition!.revocation!.evaluationId, 'ev-02');
      expect(f.pagedEvaluationId, isNull);
      expect(f.evaluationItems, isEmpty);
      expect(f.errorCode, 'revocation_digest_changed');
      expect(acknowledgeLabel(f), 'Acknowledge all 4 items and switch');
      await f.loadMoreItems();
      expect(fake.log.last.path, '$base/op1/evaluations/ev-02');
      await f.acknowledge();
      expect(fake.to('/acknowledge').last.body!['evaluationId'], 'ev-02');
      expect(fake.to('/acknowledge').last.body!['digest'], 'd2');
    });

    test('a missing snapshot re-reads the current evaluation', () async {
      var reads = 0;
      final fake = Fake((c) {
        if (c.path.endsWith('/environment')) return env(active: 'op1');
        if (c.path.contains('/evaluations/')) {
          throw http(404, 'evaluation_not_found');
        }
        return ++reads == 1
            ? fenced(rev: revocation(total: 3))
            : fenced(rev: revocation(evaluation: 'ev-02', total: 3));
      });
      final f = flow(fake);
      await f.load();
      await f.loadMoreItems();
      expect(f.errorCode, 'evaluation_not_found');
      expect(f.transition!.revocation!.evaluationId, 'ev-02');
      expect(fake.posts.where((c) => !c.path.endsWith('/advance')), isEmpty);
    });

    test('an older Node without evaluationId sends only the digest', () async {
      final fake = Fake((c) {
        if (c.path.endsWith('/environment')) return env(active: 'op1');
        if (c.path.endsWith('/acknowledge')) return installed('ready');
        final rev = revocation()..remove('evaluationId');
        return fenced(rev: rev);
      });
      final f = flow(fake);
      await f.load();
      expect(f.moreItemsAvailable, false);
      await f.acknowledge();
      expect(fake.to('/acknowledge').single.body, {
        'digest': 'd1',
        'clientId': 'phone',
        'generation': 4,
      });
    });
  });

  group('cancellation and readiness (C3)', () {
    for (final (reason, text) in [
      ('drain_active', 'Cancellation pending: work is still stopping.'),
      (
        'resources_unresolved',
        'Cancellation pending: some resources are unresolved.',
      ),
      (
        'original_binding_invalid',
        'Cancellation pending: the original workspace is no longer valid.',
      ),
    ]) {
      test(
        'pending cancellation ($reason) keeps polling to the result',
        () async {
          var reads = 0;
          final pending = fenced(
            rev: revocation(),
            cancellation: {'requestedAt': 9, 'pendingReason': reason},
          );
          final fake = Fake((c) {
            if (c.path.endsWith('/environment')) return env(active: 'op1');
            if (c.path.endsWith('/cancel')) return pending;
            return ++reads == 1
                ? fenced(rev: revocation())
                : reads < 4
                ? pending
                : status('released');
          });
          final f = flow(fake);
          await f.load();
          await f.cancel();
          expect(f.status, EnvironmentSwitchStatus.cancelPending);
          expect(f.transition!.cancellationRequestedAt, 9);
          expect(f.transition!.cancellationPendingReason, reason);
          expect(environmentSwitchMessage(f), startsWith(text));
          // Never offer install-bound actions after a cancellation request.
          expect(f.actions, {EnvironmentSwitchAction.refresh});
          await f.acknowledge();
          await settle();
          expect(fake.to('/acknowledge'), isEmpty);
          expect(f.status, EnvironmentSwitchStatus.released);
          expect(waits.length, greaterThanOrEqualTo(3));
          waits.clear();
        },
      );
    }

    test('a cancellation request without a Node reason still waits', () {
      final value = TransitionStatus(
        status('node_fenced', cancellation: {'requestedAt': 3}),
      );
      expect(transitionStatusFor(value), EnvironmentSwitchStatus.cancelPending);
      expect(transitionNeedsPolling(value), true);
      expect(cancellationReasonText(null), 'waiting for the Node');
    });

    test('transition_cancel_requested passes through and re-reads', () async {
      var reads = 0;
      final fake = Fake((c) {
        if (c.path.endsWith('/environment')) return env(active: 'op1');
        if (c.path.endsWith('/cancel')) {
          throw http(409, 'transition_cancel_requested');
        }
        return ++reads == 1 ? fenced(rev: revocation()) : status('released');
      });
      final f = flow(fake);
      await f.load();
      await f.cancel();
      expect(f.errorCode, 'transition_cancel_requested');
      expect(f.status, EnvironmentSwitchStatus.released);
      expect(
        transitionReasonText('transition_cancel_requested'),
        contains('will not be installed'),
      );
    });

    test(
      'readiness: not started → failed → ready, refreshed by advance',
      () async {
        var ready = 'not_started';
        final fake = Fake(
          (c) => c.path.endsWith('/environment')
              ? env(active: 'op1')
              : installed(ready),
        );
        final f = flow(fake);
        await f.load();
        expect(f.transition!.bindingCommitted, true);
        expect(f.transition!.policyValidated, true);
        expect(
          environmentSwitchMessage(f),
          'Switched; execution not started. Revocation confirmed.',
        );
        expect(f.actions, {
          EnvironmentSwitchAction.refresh,
          EnvironmentSwitchAction.dismiss,
        });
        ready = 'failed';
        await f.refresh();
        expect(fake.log.last.path, '$base/op1/advance');
        expect(
          environmentSwitchMessage(f),
          'Switched; execution failed to start. Revocation confirmed.',
        );
        ready = 'unknown';
        await f.refresh();
        expect(environmentSwitchMessage(f), contains('readiness unknown'));
        ready = 'ready';
        await f.refresh();
        expect(environmentSwitchMessage(f), 'Switched; revocation confirmed.');
        expect(f.actions, {EnvironmentSwitchAction.dismiss});
        // A switch never becomes cancellable once installed.
        expect(f.actions, isNot(contains(EnvironmentSwitchAction.cancel)));
      },
    );

    test('an unconfirmed install keeps its qualifier with readiness', () {
      final f =
          EnvironmentTransitionFlow(
              api: EnvironmentTransitionApi(FakeGateway()),
              session: 's',
              lease: () => null,
            )
            ..transition = TransitionStatus(
              installed('not_started', confirmed: false),
            )
            ..status = EnvironmentSwitchStatus.installedUnconfirmed;
      flows.add(f);
      expect(
        environmentSwitchMessage(f),
        'Switched; execution not started. Revocation not fully confirmed.',
      );
    });
  });

  testWidgets('card shows reauthorization and inherited items', (t) async {
    final fake = Fake(
      (c) => c.path.endsWith('/environment')
          ? env(active: 'op1')
          : fenced(
              rev: revocation(
                items: [
                  item(
                    'host_command',
                    'host_effects_may_survive',
                    inherited: true,
                    generation: 1,
                  ),
                ],
                total: 7,
              ),
              authority: authority('expired'),
            ),
    );
    final live = LiveController(fake.gateway)
      ..sessionId = 's'
      ..clientId = 'phone'
      ..control = {'held': true, 'generation': 4}
      ..state = {
        'session': {
          'id': 's',
          'workspaceId': 'node:repo',
          'binding': binding(1),
        },
      };
    await t.pumpWidget(
      MaterialApp(
        theme: theme.build(Brightness.light),
        home: Scaffold(
          body: SingleChildScrollView(
            child: EnvironmentSwitchCard(controller: live),
          ),
        ),
      ),
    );
    await t.pumpAndSettle();
    expect(find.text('Reauthorize'), findsOneWidget);
    expect(find.text('Acknowledge all 7 items and switch'), findsOneWidget);
    expect(find.text('Showing 1 of 7 items'), findsOneWidget);
    expect(
      find.text(
        '• Host-management command: detached host work may survive (inherited from environment 1)',
      ),
      findsOneWidget,
    );
    expect(fake.posts.where((c) => !c.path.endsWith('/advance')), isEmpty);
    await t.pumpWidget(const SizedBox());
    live.dispose();
  });
}
