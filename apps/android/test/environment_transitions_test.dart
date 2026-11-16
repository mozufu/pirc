import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_mobile/live/environment_switch_card.dart';
import 'package:pirc_mobile/live/environment_transitions.dart';
import 'package:pirc_mobile/live/gateway.dart';
import 'live_test.dart' show FakeGateway, theme;

typedef Call = ({String method, String path, Json? body});

/// A scripted Gateway answering each request with [route].
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
  List<Call> to(String suffix) =>
      log.where((c) => c.path.endsWith(suffix)).toList();
  List<Call> get posts => log.where((c) => c.method == 'POST').toList();
}

PlatformException http(int status, [String? code]) => PlatformException(
  code: 'HTTP_$status',
  message: code,
  details: {'status': status, 'code': code},
);
final network = PlatformException(code: 'NETWORK', message: 'lost');

const base = '/api/sessions/s/environment-transitions';
Json binding(int generation, [String workspace = 'node:repo']) => {
  'version': 1,
  'membership': {'revision': 2, 'legacyWorkspaceId': 'node:repo'},
  'execution': {
    'generation': generation,
    'workspaceId': workspace,
    'nodeId': 'node',
    'modeId': 'directory',
  },
};
Json env({Json? b, String? active, String state = 'node_fenced'}) => {
  'version': 1,
  'sessionId': 's',
  'binding': b ?? binding(1),
  'activeTransition': active == null
      ? null
      : {
          'operationId': active,
          'state': state,
          'revocationConfirmed': false,
          'targetInstalled': false,
        },
};
Json preview(
  String op, {
  bool canConfirm = true,
  List<String> blockedBy = const [],
  bool stale = false,
}) => {
  'preview': {
    'operationId': op,
    'sessionId': 's',
    'targetWorkspaceId': 'node:target',
    'planHash': 'plan-$op',
    'plan': {},
    'createdAt': 1,
  },
  'state': stale ? 'stale' : 'preview',
  'canConfirm': canConfirm,
  'blockedBy': blockedBy,
  'nodeObservations': [
    {'nodeId': 'node', 'status': 'observed', 'acknowledgesRevocation': true},
  ],
  'resourcePreflight': {'status': 'observed', 'observationHash': 'obs-$op'},
};
Json item(String kind, String reason, {bool ack = true}) => {
  'kind': kind,
  'reason': reason,
  'acknowledgeable': ack,
};
Json progress({
  String fence = 'supervisor_drained',
  String? revocation,
  String digest = 'd1',
  List<Json> items = const [],
  int? total,
  String? installed,
}) => {
  'state': fence,
  'errorCode': null,
  'revocationConfirmed': false,
  'targetInstalled': fence == 'installed',
  'revocation': revocation == null
      ? null
      : {
          'status': revocation,
          'digest': digest,
          'itemsTotal': total ?? items.length,
          'confirmsContainment': false,
          'items': items,
        },
  'installation': installed == null
      ? null
      : {'revocation': installed, 'environmentEvent': 'queued'},
};
Json status(
  String state, {
  Json? p,
  bool confirmed = false,
  String op = 'op1',
  String? reconciliation,
  bool withProgress = true,
}) => {
  'transition': {
    'operationId': op,
    'sessionId': 's',
    'state': state,
    'createdAt': 1,
    'revocationConfirmed': confirmed,
    'targetInstalled': state == 'installed',
  },
  'canConfirm': false,
  if (withProgress) 'progress': p,
  'reconciliationState': ?reconciliation,
};

TransitionLease? held = const TransitionLease('phone', 4);
final bindings = <Json>[];
final waits = <Duration>[];
final flows = <EnvironmentTransitionFlow>[];
var serial = 0;
EnvironmentTransitionFlow flow(Fake fake) {
  final f = EnvironmentTransitionFlow(
    api: fake.api,
    session: 's',
    lease: () => held,
    onBinding: bindings.add,
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

/// A Gateway that previews, confirms and then answers advances in turn.
Fake switching(List<Object> advances, {Json? preview_}) {
  var next = 0;
  return Fake((c) {
    if (c.path.endsWith('/environment')) return env();
    if (c.path.endsWith('/previews')) return preview_ ?? preview('op1');
    if (c.path.endsWith('/confirm')) return status('node_fenced');
    if (c.path.endsWith('/advance')) {
      final value = advances[next < advances.length ? next++ : next - 1];
      if (value is Exception) throw value;
      return value;
    }
    throw StateError('unexpected ${c.path}');
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    held = const TransitionLease('phone', 4);
    bindings.clear();
    waits.clear();
    serial = 0;
  });
  tearDown(() {
    for (final f in flows) {
      f.dispose();
    }
    flows.clear();
  });

  group('api', () {
    test('every call uses the contract path and exact body', () async {
      final fake = Fake(
        (c) => c.path.contains('previews') && c.method == 'GET'
            ? preview('op1')
            : c.path.endsWith('/environment')
            ? env()
            : c.path.endsWith('/previews')
            ? preview('op1')
            : status('node_fenced'),
      );
      const lease = TransitionLease('phone', 4);
      await fake.api.environment('s');
      await fake.api.preview(
        's',
        operationId: 'op1',
        targetWorkspaceId: 'node:target',
        expectedBinding: binding(1),
      );
      await fake.api.readPreview('s', 'op1');
      await fake.api.confirm(
        's',
        'op1',
        planHash: 'p',
        observationHash: 'o',
        lease: lease,
      );
      await fake.api.status('s', 'op1');
      await fake.api.advance('s', 'op1', lease);
      await fake.api.acknowledge('s', 'op1', digest: 'd', lease: lease);
      await fake.api.cancel('s', 'op1', lease);
      expect(
        [for (final c in fake.log) '${c.method} ${c.path}'],
        [
          'GET /api/sessions/s/environment',
          'POST $base/previews',
          'GET $base/previews/op1',
          'POST $base/previews/op1/confirm',
          'GET $base/receipts/op1',
          'POST $base/op1/advance',
          'POST $base/op1/acknowledge',
          'POST $base/op1/cancel',
        ],
      );
      final bodies = [for (final c in fake.log) c.body];
      expect(bodies[1], {
        'operationId': 'op1',
        'targetWorkspaceId': 'node:target',
        'expectedBinding': binding(1),
      });
      expect(bodies[3], {
        'planHash': 'p',
        'observationHash': 'o',
        'clientId': 'phone',
        'generation': 4,
      });
      expect(bodies[5], {'clientId': 'phone', 'generation': 4});
      expect(bodies[6], {'digest': 'd', 'clientId': 'phone', 'generation': 4});
      expect(bodies[7], {'clientId': 'phone', 'generation': 4});
    });

    test('operation IDs are fresh and in the allowed alphabet', () {
      final ids = {for (var i = 0; i < 20; i++) newTransitionOperationId()};
      expect(ids.length, 20);
      for (final id in ids) {
        expect(RegExp(r'^[A-Za-z0-9_-]{1,100}$').hasMatch(id), true);
      }
    });
  });

  group('status mapping', () {
    final cases = <(Json, EnvironmentSwitchStatus, bool)>[
      (status('accepted'), EnvironmentSwitchStatus.accepted, false),
      (
        status('outcome_unknown'),
        EnvironmentSwitchStatus.outcomeUnknown,
        false,
      ),
      (status('node_fenced'), EnvironmentSwitchStatus.draining, true),
      (
        status('node_fenced', p: progress(fence: 'stopping')),
        EnvironmentSwitchStatus.draining,
        true,
      ),
      (
        status('node_fenced', p: progress(revocation: 'pending')),
        EnvironmentSwitchStatus.draining,
        true,
      ),
      (
        status(
          'node_fenced',
          p: progress(fence: 'blocked', revocation: 'blocked'),
        ),
        EnvironmentSwitchStatus.revocationBlocked,
        false,
      ),
      (
        status('node_fenced', p: progress(revocation: 'blocked')),
        EnvironmentSwitchStatus.revocationBlocked,
        false,
      ),
      (
        status('node_fenced', p: progress(revocation: 'unproven')),
        EnvironmentSwitchStatus.unproven,
        false,
      ),
      (
        status('node_fenced', p: progress(revocation: 'confirmed')),
        EnvironmentSwitchStatus.installing,
        false,
      ),
      (
        status('installed', confirmed: true),
        EnvironmentSwitchStatus.installedConfirmed,
        false,
      ),
      (
        status('installed'),
        EnvironmentSwitchStatus.installedUnconfirmed,
        false,
      ),
      (status('released'), EnvironmentSwitchStatus.released, false),
      (status('deleted'), EnvironmentSwitchStatus.deleted, false),
      (status('paused'), EnvironmentSwitchStatus.unrecognized, false),
    ];
    for (final (raw, expected, polls) in cases) {
      final value = TransitionStatus(raw);
      test(
        '${value.state} ${value.revocation?.status ?? value.fenceState ?? ''}'
        ' → ${expected.name}',
        () {
          expect(transitionStatusFor(value), expected);
          expect(transitionNeedsPolling(value), polls);
        },
      );
    }

    test('results say exactly what was confirmed', () async {
      for (final (raw, text) in [
        (
          status('installed', confirmed: true),
          'Switched; revocation confirmed.',
        ),
        (status('installed'), 'Switched; revocation not fully confirmed.'),
        (status('released'), 'Cancelled; original workspace kept.'),
      ]) {
        final fake = Fake(
          (c) => c.path.endsWith('/environment') ? env(active: 'op1') : raw,
        );
        final f = flow(fake);
        await f.load();
        await settle();
        expect(environmentSwitchMessage(f), text);
        expect(f.actions, {EnvironmentSwitchAction.dismiss});
      }
    });
  });

  group('preview', () {
    test('switching off on this Gateway is the disabled state', () async {
      final fake = Fake(
        (c) => c.path.endsWith('/environment')
            ? env()
            : preview(
                'op1',
                canConfirm: false,
                blockedBy: ['coordinator_not_available'],
              ),
      );
      final f = flow(fake);
      await f.load();
      await f.startPreview('node:target');
      expect(f.status, EnvironmentSwitchStatus.disabled);
      expect(f.actions, {EnvironmentSwitchAction.dismiss});
      await f.confirm();
      expect(fake.to('/confirm'), isEmpty);
      expect(environmentSwitchMessage(f), contains('not enabled'));

      // A confirm refused by the gate is the same state.
      final gated = switching([]);
      gated.route = (c) {
        if (c.path.endsWith('/environment')) return env();
        if (c.path.endsWith('/previews')) return preview('op1');
        throw http(409, 'transition_coordinator_unavailable');
      };
      final g = flow(gated);
      await g.load();
      await g.startPreview('node:target');
      await g.confirm();
      expect(g.status, EnvironmentSwitchStatus.disabled);
      expect(gated.to('/advance'), isEmpty);
    });

    test('blockers are shown and Confirm is not offered', () async {
      final fake = Fake(
        (c) => c.path.endsWith('/environment')
            ? env()
            : preview(
                'op1',
                canConfirm: false,
                blockedBy: ['source_has_pending_work', 'resource_unavailable'],
              ),
      );
      final f = flow(fake);
      await f.load();
      await f.startPreview('node:target');
      expect(f.status, EnvironmentSwitchStatus.previewBlocked);
      expect(f.actions, isNot(contains(EnvironmentSwitchAction.confirm)));
      expect(f.preview!.blockedBy.map(transitionReasonText), [
        'The conversation still has pending work.',
        'A source or target resource is unavailable.',
      ]);
      await f.refreshPreview();
      expect(fake.log.last.path, '$base/previews/op1');
    });

    test(
      'each review gets a fresh operation ID with the shown binding',
      () async {
        final fake = Fake(
          (c) => c.path.endsWith('/environment')
              ? env(b: binding(3))
              : preview('${c.body?['operationId'] ?? 'x'}'),
        );
        final f = flow(fake);
        await f.load();
        expect(bindings.single, binding(3));
        await f.startPreview('node:target');
        expect(f.status, EnvironmentSwitchStatus.readyToConfirm);
        expect(f.actions, contains(EnvironmentSwitchAction.confirm));
        await f.startPreview('node:target');
        expect(fake.to('/previews').map((c) => c.body!['operationId']), [
          'op1',
          'op2',
        ]);
        expect(fake.to('/previews').first.body!['expectedBinding'], binding(3));
      },
    );

    test('a stale preview needs a new review', () async {
      final fake = Fake(
        (c) => c.path.endsWith('/environment')
            ? env()
            : preview('op1', stale: true, canConfirm: false),
      );
      final f = flow(fake);
      await f.load();
      await f.startPreview('node:target');
      expect(f.status, EnvironmentSwitchStatus.reviewStale);
      expect(f.actions, contains(EnvironmentSwitchAction.preview));
      await f.perform(EnvironmentSwitchAction.preview);
      expect(fake.to('/previews').last.body!['operationId'], 'op2');
    });

    test('stale_environment refreshes the binding first', () async {
      var reads = 0;
      final fake = Fake((c) {
        if (c.path.endsWith('/environment')) {
          return env(b: binding(++reads == 1 ? 1 : 2));
        }
        throw http(409, 'stale_environment');
      });
      final f = flow(fake);
      await f.load();
      await f.startPreview('node:target');
      expect(f.status, EnvironmentSwitchStatus.reviewStale);
      expect(bindings, [binding(1), binding(2)]);
      expect(f.binding, binding(2));
    });

    test('a lost preview reply reads it; 404 re-sends the same ID', () async {
      var posts = 0;
      final fake = Fake((c) {
        if (c.path.endsWith('/environment')) return env();
        if (c.method == 'POST') {
          if (++posts == 1) throw http(504, 'node_timeout');
          return preview('op1');
        }
        throw http(404, 'preview_not_found');
      });
      final f = flow(fake);
      await f.load();
      await f.startPreview('node:target');
      expect(f.status, EnvironmentSwitchStatus.previewNotSaved);
      expect(fake.log.last.path, '$base/previews/op1');
      await f.refreshPreview();
      expect(fake.posts.length, 2);
      expect(fake.posts[1].body, fake.posts[0].body);
      expect(f.status, EnvironmentSwitchStatus.readyToConfirm);
    });
  });

  group('confirm and progress', () {
    test('confirm, then advance polls with backoff until installed', () async {
      var envReads = 0;
      final fake = switching([
        status('node_fenced'),
        status('node_fenced', p: progress(fence: 'stopping')),
        status('node_fenced', p: progress(revocation: 'pending')),
        status(
          'installed',
          confirmed: true,
          p: progress(fence: 'installed', installed: 'confirmed'),
        ),
      ]);
      final old = fake.route;
      fake.route = (c) => c.path.endsWith('/environment')
          ? env(
              b: binding(
                ++envReads == 1 ? 1 : 2,
                envReads == 1 ? 'node:repo' : 'node:target',
              ),
            )
          : old(c);
      final f = flow(fake);
      await f.load();
      await f.startPreview('node:target');
      await f.confirm();
      await settle();
      expect(fake.to('/confirm').single.body, {
        'planHash': 'plan-op1',
        'observationHash': 'obs-op1',
        'clientId': 'phone',
        'generation': 4,
      });
      expect(fake.to('/advance').length, 4);
      expect(waits, const [
        Duration(seconds: 1),
        Duration(seconds: 2),
        Duration(seconds: 4),
      ]);
      expect(f.status, EnvironmentSwitchStatus.installedConfirmed);
      // The binding moved: the new one is adopted for later commands.
      expect(bindings.last, binding(2, 'node:target'));
      expect(fake.to('/confirm').length, 1);
    });

    test('backoff is capped while the Node stays unavailable', () async {
      final fake = switching([
        for (var i = 0; i < 8; i++)
          status('node_fenced', reconciliation: 'node_unavailable'),
        status('node_fenced', p: progress(revocation: 'confirmed')),
      ]);
      final f = flow(fake);
      await f.load();
      await f.startPreview('node:target');
      await f.confirm();
      await settle();
      expect(waits.last, const Duration(seconds: 30));
      expect(waits.length, 8);
      expect(f.status, EnvironmentSwitchStatus.installing);
    });

    test('node_unavailable is reported while pending', () async {
      final fake = Fake(
        (c) => c.path.endsWith('/environment')
            ? env(active: 'op1')
            : status(
                'node_fenced',
                p: progress(revocation: 'blocked'),
                reconciliation: 'node_unavailable',
              ),
      );
      final f = flow(fake);
      await f.load();
      expect(f.status, EnvironmentSwitchStatus.revocationBlocked);
      expect(
        environmentSwitchMessage(f),
        contains('The Node is unavailable; the switch stays pending.'),
      );
    });

    test('transition_review_changed asks for a new review', () async {
      final fake = Fake((c) {
        if (c.path.endsWith('/environment')) return env();
        if (c.path.endsWith('/previews')) return preview('op1');
        throw http(409, 'transition_review_changed');
      });
      final f = flow(fake);
      await f.load();
      await f.startPreview('node:target');
      await f.confirm();
      expect(f.status, EnvironmentSwitchStatus.reviewStale);
      expect(f.errorCode, 'transition_review_changed');
      expect(f.actions, contains(EnvironmentSwitchAction.preview));
      expect(fake.to('/advance'), isEmpty);
    });

    test(
      'a lost confirm reads the receipt; 404 keeps the same review',
      () async {
        var confirms = 0;
        final fake = Fake((c) {
          if (c.path.endsWith('/environment')) return env();
          if (c.path.endsWith('/previews')) return preview('op1');
          if (c.path.endsWith('/confirm')) {
            if (++confirms == 1) throw network;
            return status('node_fenced', p: progress(revocation: 'confirmed'));
          }
          if (c.path.endsWith('/receipts/op1')) throw http(404, 'receipt_not_found');
          return status('installed', confirmed: true);
        });
        final f = flow(fake);
        await f.load();
        await f.startPreview('node:target');
        await f.confirm();
        expect(fake.to('/receipts/op1').length, 1);
        expect(f.status, EnvironmentSwitchStatus.readyToConfirm);
        await f.confirm();
        await settle();
        expect(fake.to('/confirm')[1].body, fake.to('/confirm')[0].body);
        expect(f.status, EnvironmentSwitchStatus.installedConfirmed);
      },
    );

    test('a lost confirm that was accepted continues by advance', () async {
      final fake = Fake((c) {
        if (c.path.endsWith('/environment')) return env();
        if (c.path.endsWith('/previews')) return preview('op1');
        if (c.path.endsWith('/confirm')) throw http(503, 'node_offline');
        if (c.path.endsWith('/receipts/op1')) {
          return status('node_fenced', withProgress: false);
        }
        return status('installed', confirmed: true);
      });
      final f = flow(fake);
      await f.load();
      await f.startPreview('node:target');
      await f.confirm();
      await settle();
      expect(fake.to('/confirm').length, 1);
      expect(fake.to('/advance').length, 1);
      expect(f.status, EnvironmentSwitchStatus.installedConfirmed);
    });

    test('Node refusals pass through by code', () async {
      for (final code in [
        'revocation_unconfirmed',
        'transition_not_unproven',
        'transition_not_drained',
        'transition_draining',
        'transition_released',
        'transition_target_unreviewed',
        'stale_transition_target',
        'lost_control',
      ]) {
        final fake = Fake(
          (c) => c.path.endsWith('/environment')
              ? env(active: 'op1')
              : throw http(409, code),
        );
        final f = flow(fake);
        await f.load();
        expect(f.status, EnvironmentSwitchStatus.failed, reason: code);
        expect(f.errorCode, code);
        expect(environmentSwitchMessage(f), isNot(code), reason: code);
        expect(f.actions, contains(EnvironmentSwitchAction.refresh));
        expect(fake.posts.length, 1, reason: code);
      }
    });

    test('5xx step failures are ambiguous and only read again', () async {
      for (final code in [
        'transition_step_failed',
        'invalid_transition_receipt',
      ]) {
        var n = 0;
        final fake = Fake((c) {
          if (c.path.endsWith('/environment')) return env(active: 'op1');
          if (++n == 1) {
            return status('node_fenced', p: progress(revocation: 'unproven'));
          }
          throw http(502, code);
        });
        final f = flow(fake);
        await f.load();
        await f.refresh();
        expect(f.status, EnvironmentSwitchStatus.unproven, reason: code);
        expect(f.errorCode, code);
        expect(
          environmentSwitchMessage(f),
          contains(transitionReasonText(code)),
        );
        expect(fake.to('/acknowledge'), isEmpty);
      }
    });

    test(
      'restart discovery adopts activeTransition without local state',
      () async {
        final fake = Fake(
          (c) => c.path.endsWith('/environment')
              ? env(active: 'remote-op', state: 'outcome_unknown')
              : status(
                  'node_fenced',
                  op: 'remote-op',
                  p: progress(
                    revocation: 'unproven',
                    items: [
                      item('platform_containment', 'descendants_not_contained'),
                    ],
                  ),
                ),
        );
        final f = flow(fake);
        await f.load();
        expect(f.operationId, 'remote-op');
        expect(fake.log.last.path, '$base/remote-op/advance');
        expect(f.status, EnvironmentSwitchStatus.unproven);

        // Without control the receipt GET is read instead, and nothing mutates.
        held = null;
        final reader = Fake(
          (c) => c.path.endsWith('/environment')
              ? env(active: 'remote-op')
              : status('node_fenced', op: 'remote-op', withProgress: false),
        );
        final r = flow(reader);
        await r.load();
        expect(reader.log.last.path, '$base/receipts/remote-op');
        expect(reader.posts, isEmpty);
        expect(r.status, EnvironmentSwitchStatus.draining);
        expect(r.actions, {EnvironmentSwitchAction.refresh});
      },
    );
  });

  group('unproven revocation', () {
    Json unproven(String digest, List<Json> items, {int? total}) => status(
      'node_fenced',
      p: progress(
        revocation: 'unproven',
        digest: digest,
        items: items,
        total: total,
      ),
    );

    test('items in plain language; acknowledge sends the shown digest', () async {
      final fake = Fake((c) {
        if (c.path.endsWith('/environment')) return env(active: 'op1');
        if (c.path.endsWith('/acknowledge')) {
          return status(
            'installed',
            p: progress(fence: 'installed', installed: 'unproven'),
          );
        }
        return unproven('d1', [
          item('platform_containment', 'descendants_not_contained'),
          item('host_terminal', 'host_effects_may_survive'),
        ], total: 120);
      });
      final f = flow(fake);
      await f.load();
      expect(f.status, EnvironmentSwitchStatus.unproven);
      final revocation = f.transition!.revocation!;
      expect(revocation.itemsTotal, 120);
      expect(revocation.items.map(revocationItemText), [
        'Agent processes on this host: child processes cannot be proven stopped',
        'Host-management terminal: detached host work may survive',
      ]);
      expect(environmentSwitchMessage(f), contains('120 items'));
      expect(f.actions, {
        EnvironmentSwitchAction.refresh,
        EnvironmentSwitchAction.acknowledge,
        EnvironmentSwitchAction.cancel,
      });
      expect(fake.to('/acknowledge'), isEmpty);
      await f.acknowledge();
      expect(fake.to('/acknowledge').single.body, {
        'digest': 'd1',
        'clientId': 'phone',
        'generation': 4,
      });
      expect(f.status, EnvironmentSwitchStatus.installedUnconfirmed);
    });

    test('a changed digest re-reads and never auto-acknowledges', () async {
      var reads = 0;
      final fake = Fake((c) {
        if (c.path.endsWith('/environment')) return env(active: 'op1');
        if (c.path.endsWith('/acknowledge')) {
          throw http(409, 'revocation_digest_changed');
        }
        return ++reads == 1
            ? unproven('d1', [
                item('legacy_history', 'launches_before_journals'),
              ])
            : unproven('d2', [
                item('legacy_history', 'launches_before_journals'),
                item('host_command', 'host_effects_may_survive'),
              ]);
      });
      final f = flow(fake);
      await f.load();
      await f.acknowledge();
      await settle();
      expect(fake.to('/acknowledge').length, 1);
      expect(f.status, EnvironmentSwitchStatus.unproven);
      expect(f.transition!.revocation!.digest, 'd2');
      expect(f.transition!.revocation!.items.length, 2);
      expect(f.errorCode, 'revocation_digest_changed');
      expect(environmentSwitchMessage(f), contains('items changed'));
      await f.acknowledge();
      expect(fake.to('/acknowledge').last.body!['digest'], 'd2');
    });

    test('blocked shows items and offers no acknowledgement', () async {
      final fake = Fake(
        (c) => c.path.endsWith('/environment')
            ? env(active: 'op1')
            : status(
                'node_fenced',
                p: progress(
                  revocation: 'blocked',
                  items: [item('browser', 'unresolved', ack: false)],
                ),
              ),
      );
      final f = flow(fake);
      await f.load();
      expect(f.status, EnvironmentSwitchStatus.revocationBlocked);
      expect(
        revocationItemText(f.transition!.revocation!.items.single),
        'Browser session: still unresolved',
      );
      expect(f.actions, {
        EnvironmentSwitchAction.refresh,
        EnvironmentSwitchAction.cancel,
      });
      await f.acknowledge();
      expect(fake.to('/acknowledge'), isEmpty);
    });

    test('an ambiguous acknowledgement is resolved by advance', () async {
      var reads = 0;
      final fake = Fake((c) {
        if (c.path.endsWith('/environment')) return env(active: 'op1');
        if (c.path.endsWith('/acknowledge')) throw http(504, 'node_timeout');
        return ++reads == 1
            ? unproven('d1', [item('legacy_history', 'untracked_launch')])
            : status('installed');
      });
      final f = flow(fake);
      await f.load();
      await f.acknowledge();
      expect(fake.to('/acknowledge').length, 1);
      expect(fake.to('/advance').length, 2);
      expect(f.status, EnvironmentSwitchStatus.installedUnconfirmed);
    });
  });

  group('cancel', () {
    test('before the fence closes the intent; after it releases', () async {
      for (final state in ['accepted', 'node_fenced']) {
        final fake = Fake((c) {
          if (c.path.endsWith('/environment')) {
            return env(active: 'op1', state: state);
          }
          if (c.path.endsWith('/cancel')) return status('released');
          return status(
            state,
            p: state == 'node_fenced' ? progress(revocation: 'unproven') : null,
          );
        });
        final f = flow(fake);
        await f.load();
        expect(f.actions, contains(EnvironmentSwitchAction.cancel));
        await f.cancel();
        expect(fake.to('/cancel').single.body, {
          'clientId': 'phone',
          'generation': 4,
        });
        expect(f.status, EnvironmentSwitchStatus.released);
        expect(
          environmentSwitchMessage(f),
          'Cancelled; original workspace kept.',
        );
      }
    });

    test('transition_installed means too late', () async {
      var reads = 0;
      final fake = Fake((c) {
        if (c.path.endsWith('/environment')) return env(active: 'op1');
        if (c.path.endsWith('/cancel')) throw http(409, 'transition_installed');
        return ++reads == 1
            ? status('node_fenced', p: progress(revocation: 'confirmed'))
            : status('installed', confirmed: true);
      });
      final f = flow(fake);
      await f.load();
      await f.cancel();
      expect(f.status, EnvironmentSwitchStatus.installedConfirmed);
      expect(f.errorCode, 'transition_installed');
      expect(environmentSwitchMessage(f), contains('switching back is a new'));
      expect(f.actions, isNot(contains(EnvironmentSwitchAction.cancel)));
    });

    test('no cancel after installation; lost_control is a refusal', () async {
      final fake = Fake((c) {
        if (c.path.endsWith('/environment')) return env(active: 'op1');
        if (c.path.endsWith('/cancel')) throw http(409, 'lost_control');
        return status('node_fenced', p: progress(revocation: 'unproven'));
      });
      final f = flow(fake);
      await f.load();
      await f.cancel();
      expect(f.status, EnvironmentSwitchStatus.failed);
      expect(environmentSwitchMessage(f), contains('Take control'));
      final done = Fake(
        (c) => c.path.endsWith('/environment')
            ? env(active: 'op1')
            : status('installed'),
      );
      final g = flow(done);
      await g.load();
      await g.cancel();
      expect(done.to('/cancel'), isEmpty);
    });

    test('an unknown cancel outcome reads the status', () async {
      var reads = 0;
      final fake = Fake((c) {
        if (c.path.endsWith('/environment')) return env(active: 'op1');
        if (c.path.endsWith('/cancel')) {
          throw http(409, 'transition_outcome_unknown');
        }
        return ++reads == 1
            ? status('outcome_unknown')
            : status('node_fenced', p: progress(revocation: 'unproven'));
      });
      final f = flow(fake);
      await f.load();
      expect(f.status, EnvironmentSwitchStatus.outcomeUnknown);
      await f.cancel();
      expect(fake.to('/cancel').length, 1);
      expect(f.status, EnvironmentSwitchStatus.unproven);
      expect(f.errorCode, 'transition_outcome_unknown');
    });
  });

  group('cancelling a switch whose Node outcome is unknown', () {
    Json voidStatus(String state, {Json? p}) => {
      ...status(state == 'voided' ? 'released' : 'outcome_unknown', p: p),
      'cancellation': {
        'requestedAt': 5,
        'void': {
          'state': state,
          'requestedAt': 5,
          'answeredAt': state == 'voided' ? 9 : null,
          'nodeId': 'node',
        },
      },
    };

    test('offers Cancel and shows the hint the Gateway recorded', () async {
      final fake = Fake((c) {
        if (c.path.endsWith('/environment')) {
          return env(active: 'op1', state: 'outcome_unknown');
        }
        return status(
          'outcome_unknown',
          p: {
            'stage': 'outcome_unknown',
            'waitReason': 'receipt_unavailable',
            'safeActions': ['cancel'],
          },
        );
      });
      final f = flow(fake);
      await f.load();
      expect(f.status, EnvironmentSwitchStatus.outcomeUnknown);
      expect(f.actions, contains(EnvironmentSwitchAction.cancel));
      expect(
        environmentSwitchMessage(f),
        'The Node has not confirmed this switch (the Node has no record of this switch yet). You can cancel it.',
      );
    });

    test(
      'waits for the Node while the void is pending, then reports nothing changed',
      () async {
        var cancelled = false, reads = 0;
        final fake = Fake((c) {
          if (c.path.endsWith('/environment')) {
            return env(active: 'op1', state: 'outcome_unknown');
          }
          if (c.path.endsWith('/cancel')) {
            cancelled = true;
            return {
              ...voidStatus('pending'),
              'reconciliationState': 'node_unavailable',
            };
          }
          if (!cancelled) return status('outcome_unknown');
          return ++reads < 2 ? voidStatus('pending') : voidStatus('voided');
        });
        final f = flow(fake);
        await f.load();
        await f.cancel();
        expect(fake.to('/cancel').single.body, {
          'clientId': 'phone',
          'generation': 4,
        });
        expect(f.status, EnvironmentSwitchStatus.cancelPending);
        expect(
          environmentSwitchMessage(f),
          startsWith(
            'Cancelling: waiting for the Node to confirm this switch never started.',
          ),
        );
        // Nothing but a status check while it waits: the conversation stays locked.
        expect(f.actions, {EnvironmentSwitchAction.refresh});
        await settle();
        expect(f.status, EnvironmentSwitchStatus.released);
        expect(
          environmentSwitchMessage(f),
          'Switch cancelled — nothing was changed on the Node.',
        );
        // The binding was only read, never changed.
      expect(
        bindings.map((b) => obj(b['execution'])['workspaceId']).toSet(),
        {'node:repo'},
      );
      },
    );

    test('a release that is not from a void keeps the ordinary text', () async {
      final fake = Fake((c) {
        if (c.path.endsWith('/environment')) {
          return env(active: 'op1', state: 'released');
        }
        return status('released');
      });
      final f = flow(fake);
      await f.load();
      expect(f.status, EnvironmentSwitchStatus.released);
      expect(
        environmentSwitchMessage(f),
        'Cancelled; original workspace kept.',
      );
    });

    test(
      'a Node that cannot void changes nothing and says it must be upgraded',
      () async {
        final fake = Fake((c) {
          if (c.path.endsWith('/environment')) {
            return env(active: 'op1', state: 'outcome_unknown');
          }
          if (c.path.endsWith('/cancel')) {
            throw http(409, 'transition_void_unsupported');
          }
          return status('outcome_unknown');
        });
        final f = flow(fake);
        await f.load();
        await f.cancel();
        expect(f.status, EnvironmentSwitchStatus.outcomeUnknown);
        expect(f.errorCode, 'transition_void_unsupported');
        expect(
          environmentSwitchMessage(f),
          contains(
            'The Node must be upgraded before a switch whose outcome is unknown can be cancelled.',
          ),
        );
        // The user may ask again once the Node is upgraded.
        expect(f.actions, contains(EnvironmentSwitchAction.cancel));
      },
    );
  });

  group('binding after a switch', () {
    test('a stale command refreshes the binding and is not resent', () async {
      final g = FakeGateway();
      var commands = 0;
      g.handler = (method, args) async {
        if (method == 'command') {
          commands++;
          throw PlatformException(
            code: 'HTTP_409',
            details: {'code': 'stale_environment'},
          );
        }
        if (method == 'request' && '${args['path']}'.endsWith('/environment')) {
          return env(b: binding(2, 'node:target'));
        }
        return g.normal(method, args);
      };
      final live = LiveController(g)
        ..sessionId = 's'
        ..connection = 'live'
        ..control = {'held': true, 'generation': 3}
        ..state = {
          'session': {
            'id': 's',
            'workspaceId': 'node:repo',
            'binding': binding(1),
          },
        };
      addTearDown(live.dispose);
      expect(
        await live.sendCommand({'type': 'prompt', 'message': 'hi'}),
        false,
      );
      await settle();
      expect(commands, 1);
      expect(obj(live.state['session'])['binding'], binding(2, 'node:target'));
      expect(live.unknownCommand, false);
      g.handler = (method, args) async {
        if (method == 'command') {
          commands++;
          expect(args['expectedBinding'], binding(2, 'node:target'));
          return {'status': 'accepted'};
        }
        return g.normal(method, args);
      };
      expect(await live.sendCommand({'type': 'prompt', 'message': 'hi'}), true);
      expect(commands, 2);
    });

    test('adoptBinding ignores another conversation', () {
      final live = LiveController(FakeGateway())
        ..sessionId = 's'
        ..state = {
          'session': {'id': 's', 'binding': binding(1)},
        };
      addTearDown(live.dispose);
      live.adoptBinding('other', binding(5));
      expect(obj(live.state['session'])['binding'], binding(1));
      live.adoptBinding('s', binding(5));
      expect(obj(live.state['session'])['binding'], binding(5));
    });
  });

  testWidgets('card shows unproven items and the explicit action', (t) async {
    final fake = Fake(
      (c) => c.path.endsWith('/environment')
          ? env(active: 'op1')
          : status(
              'node_fenced',
              p: progress(
                revocation: 'unproven',
                items: [
                  item('platform_containment', 'descendants_not_contained'),
                ],
              ),
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
        home: Scaffold(body: EnvironmentSwitchCard(controller: live)),
      ),
    );
    await t.pumpAndSettle();
    expect(
      find.text(
        '• Agent processes on this host: child processes cannot be proven stopped',
      ),
      findsOneWidget,
    );
    expect(find.text('Acknowledge all 1 items and switch'), findsOneWidget);
    expect(fake.to('/acknowledge'), isEmpty);
    await t.pumpWidget(const SizedBox());
    live.dispose();
  });
}
