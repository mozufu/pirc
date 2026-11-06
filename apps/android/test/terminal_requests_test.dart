import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_mobile/live/gateway.dart';
import 'package:pirc_mobile/live/terminal_requests.dart';
import 'package:pirc_mobile/live/terminal_pane.dart';
import 'package:pirc_mobile/live/terminal_state.dart';
import 'live_test.dart' show FakeGateway, theme;

typedef Call = ({String method, String path, Json? body});

/// A scripted Gateway: each request is answered by [route], recorded in [log].
class Node {
  Node(this.route) {
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
  late final api = TerminalRequestApi(gateway);
  List<Call> get posts => log.where((c) => c.method == 'POST').toList();
  List<Call> reads(String key) =>
      log.where((c) => c.method == 'GET' && c.path.contains(key)).toList();
}

PlatformException http(int status, [String? code]) => PlatformException(
  code: 'HTTP_$status',
  message: code,
  details: {'status': status, 'code': code},
);
final network = PlatformException(code: 'NETWORK', message: 'Connection lost');

Json caps({
  bool enabled = true,
  int? isolated = 1,
  int? host = 1,
  int? work = 2,
}) => {
  'terminalCapabilities': {
    'version': 1,
    'enabled': enabled,
    'isolatedTerminalVersion': ?isolated,
    'hostTerminalReviewVersion': ?host,
    'workTerminalRequestVersion': ?work,
  },
};
Json tty(String id, [String path = 'isolated_work']) => {
  'id': id,
  'executionPath': path,
  'title': 'bash',
  'cols': 80,
  'rows': 24,
  'exited': false,
};
Json work(
  String id,
  String state, {
  String? error,
  Json? terminal,
  int? acknowledgedAt,
}) => {
  'workRequest': {
    'version': 1,
    'requestId': id,
    'state': state,
    'errorCode': error,
    'terminalId': terminal?['id'],
    'acknowledgedAt': acknowledgedAt,
  },
  'terminal': terminal,
};
const warning =
    "Runs with the Node account's host permissions. Detached jobs and external effects may survive closing this terminal and keep workspace switching blocked.";
Json host(
  String id,
  String state, {
  String? error,
  Json? terminal,
  int? acknowledgedAt,
}) => {
  'hostManagement': {
    'version': 1,
    'requestId': id,
    'id': 'host_terminal_$id',
    'reviewHash': 'hash-$id',
    'review': {
      'version': 1,
      'executionPath': 'host_management',
      'workspaceId': 'w',
      'cwd': '/work/w',
      'shell': '/bin/zsh',
      'cols': 80,
      'rows': 24,
      'runnerEpoch': 3,
      'warning': warning,
    },
    'expiresAt': 1000,
    'state': state,
    'errorCode': error,
    'terminalId': terminal?['id'],
    'acknowledgedAt': acknowledgedAt,
  },
  'terminal': terminal,
};

bool isCaps(Call c) => c.path.endsWith('?capabilities=1');
bool isWorkPost(Call c) =>
    c.method == 'POST' && c.body?['executionPath'] == 'isolated_work';

var lease = 7;
var cols = 80;
TerminalIntent? intent() => TerminalIntent(
  sessionId: 's',
  clientId: 'phone',
  generation: lease,
  cols: cols,
);
final opened = <Json>[];
final trackers = <TerminalRequestTracker>[];
var serial = 0;
TerminalRequestTracker tracker(Node node, {String Function()? newId}) {
  final flow = TerminalRequestTracker(
    api: node.api,
    session: 's',
    current: intent,
    onLive: opened.add,
    newId: newId ?? () => 'req-${++serial}',
    // Yield to the event loop so polling cannot starve the test.
    wait: (_) => Future<void>.delayed(Duration.zero),
  );
  trackers.add(flow);
  return flow;
}

Future<void> settle() => pumpEventQueue(times: 200);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    lease = 7;
    cols = 80;
    serial = 0;
    opened.clear();
  });
  tearDown(() {
    for (final flow in trackers) {
      flow.dispose();
    }
    trackers.clear();
  });

  group('capabilities', () {
    test('versions decide the path; missing fields mean 0', () {
      TerminalCapabilities parse(Json data) => TerminalCapabilities.parse(data);
      // An older Node ignores the query and answers its terminal list.
      final old = parse({'terminals': []});
      expect(old.known, false);
      expect(old.availability, TerminalAvailability.needsUpdate);
      expect(
        parse(caps(work: null)).availability,
        TerminalAvailability.needsUpdate,
      );
      final v1 = parse(caps(work: 1));
      expect(v1.availability, TerminalAvailability.needsUpdate);
      expect(v1.offersIsolated, false);
      expect(v1.offersHostManagement, false);
      expect(
        parse(caps(enabled: false)).availability,
        TerminalAvailability.disabled,
      );
      expect(parse(caps(enabled: false)).offersHostManagement, false);
      final isolated = parse(caps());
      expect(isolated.offersIsolated, true);
      expect(isolated.offersHostManagement, false);
      final mac = parse(caps(isolated: 0));
      expect(mac.availability, TerminalAvailability.isolationUnavailable);
      expect(mac.offersIsolated, false);
      expect(mac.offersHostManagement, true);
      final missing = parse(caps(isolated: null, host: null));
      expect(missing.availability, TerminalAvailability.isolationUnavailable);
      expect(missing.offersHostManagement, false);
      expect(parse(caps(work: 3)).offersIsolated, true);
    });

    test('reads the capability query of the session', () async {
      final node = Node((_) => caps());
      final value = await node.api.capabilities('a b');
      expect(value.offersIsolated, true);
      expect(
        node.log.single.path,
        '/api/sessions/a%20b/terminals?capabilities=1',
      );
      expect(node.log.single.method, 'GET');
    });
  });

  group('result states', () {
    // Every row of the contract's state table, with its client actions.
    final mac = TerminalCapabilities.parse(caps(isolated: 0));
    const a = TerminalRequestAction.values;
    TerminalRequestAction act(String name) =>
        a.firstWhere((v) => v.name == name);
    final rows = <(Json, TerminalRequestStatus, Set<String>)>[
      (
        host('h', 'review'),
        TerminalRequestStatus.review,
        {'confirm', 'refresh', 'dismiss'},
      ),
      (
        host('h', 'stale'),
        TerminalRequestStatus.stale,
        {'startOver', 'dismiss'},
      ),
      (
        host('h', 'expired'),
        TerminalRequestStatus.expired,
        {'startOver', 'dismiss'},
      ),
      (work('w', 'preparing'), TerminalRequestStatus.preparing, {'refresh'}),
      (
        work('w', 'launching', terminal: tty('t')),
        TerminalRequestStatus.live,
        {'attach'},
      ),
      (
        work('w', 'running', terminal: tty('t')),
        TerminalRequestStatus.live,
        {'attach'},
      ),
      (
        host('h', 'running', terminal: tty('t', 'host_management')),
        TerminalRequestStatus.live,
        {'attach'},
      ),
      (
        work('w', 'running'),
        TerminalRequestStatus.outcomeUnknown,
        {'refresh', 'dismiss'},
      ),
      (
        work('w', 'not_started', error: 'isolated_terminal_unavailable'),
        TerminalRequestStatus.notStarted,
        {'startOver', 'hostManagement', 'dismiss'},
      ),
      (
        host('h', 'not_started', error: 'runner_unavailable'),
        TerminalRequestStatus.notStarted,
        {'startOver', 'dismiss'},
      ),
      (
        work('w', 'outcome_unknown', error: 'terminal_start_unconfirmed'),
        TerminalRequestStatus.outcomeUnknown,
        {'refresh', 'dismiss'},
      ),
      (work('w', 'settled'), TerminalRequestStatus.settled, {'dismiss'}),
      (
        host('h', 'unconfirmed'),
        TerminalRequestStatus.unconfirmed,
        {'dismiss'},
      ),
      (
        work('w', 'paused'),
        TerminalRequestStatus.unrecognized,
        {'refresh', 'dismiss'},
      ),
    ];
    for (final (data, status, actions) in rows) {
      final result = TerminalRequestResult.parse(data);
      test('${result.kind.name} ${result.state} → ${status.name}', () {
        final entry = TerminalRequestEntry(
          result.kind,
          result.requestId,
          intent(),
        )..result = result;
        entry.status = terminalStatusFor(result.phase);
        expect(entry.status, status);
        expect(
          terminalRequestActions(entry, current: intent(), capabilities: mac),
          {for (final name in actions) act(name)},
        );
        // No state offers a force-clear or an automatic new request.
        expect(terminalRequestMessage(entry), isNotEmpty);
      });
    }

    test('result shapes match across work and host', () {
      final w = TerminalRequestResult.parse(
        work('w1', 'not_started', error: 'runner_unavailable'),
      );
      expect(w.kind, TerminalRequestKind.work);
      expect(w.version, 1);
      expect(w.requestId, 'w1');
      expect(w.errorCode, 'runner_unavailable');
      expect(w.terminalId, isNull);
      final h = TerminalRequestResult.parse(
        host('h1', 'running', terminal: tty('t9', 'host_management')),
      );
      expect(h.kind, TerminalRequestKind.host);
      expect(h.reviewId, 'host_terminal_h1');
      expect(h.reviewHash, 'hash-h1');
      expect(h.expiresAt, 1000);
      expect(h.terminalId, 't9');
      expect(h.terminal!['id'], 't9');
      expect(h.review!.shell, '/bin/zsh');
      expect(h.review!.cwd, '/work/w');
      expect((h.review!.cols, h.review!.rows), (80, 24));
      expect(h.review!.warning, warning);
      expect(
        () => TerminalRequestResult.parse({'terminal': null}),
        throwsFormatException,
      );
    });

    test('path labels: untagged legacy terminals stay unlabeled', () {
      expect(terminalPathLabel(tty('a')), 'isolated');
      expect(terminalPathLabel(tty('a', 'host_management')), 'host management');
      expect(terminalPathLabel({'id': 'legacy'}), isNull);
    });
  });

  group('isolated work requests', () {
    test('request IDs are fresh UUIDs in the allowed alphabet', () {
      final ids = {for (var i = 0; i < 50; i++) newTerminalRequestId()};
      expect(ids.length, 50);
      for (final id in ids) {
        expect(RegExp(r'^[A-Za-z0-9_-]{1,128}$').hasMatch(id), true);
      }
      expect(newTerminalRequestId(Random(1)), newTerminalRequestId(Random(1)));
    });

    test('201 finished: exact body, capability read first, attaches', () async {
      final node = Node(
        (c) => isCaps(c)
            ? caps()
            : work('${c.body!['requestId']}', 'running', terminal: tty('t1')),
      );
      final flow = tracker(node);
      final entry = await flow.openWork();
      expect(node.log.first.path, endsWith('?capabilities=1'));
      expect(node.posts.single.path, '/api/sessions/s/terminals');
      expect(node.posts.single.body, {
        'clientId': 'phone',
        'generation': 7,
        'cols': 80,
        'rows': 24,
        'executionPath': 'isolated_work',
        'requestId': 'req-1',
      });
      expect(entry!.status, TerminalRequestStatus.live);
      expect(opened.single['id'], 't1');
      // A second user action is a new ID.
      await flow.openWork();
      expect(node.posts.map((c) => c.body!['requestId']), ['req-1', 'req-2']);
      expect(opened.length, 2);
    });

    test(
      '202 preparing polls GET until running, without another POST',
      () async {
        var polls = 0;
        final node = Node((c) {
          if (isCaps(c)) return caps();
          if (c.method == 'POST') return work('req-1', 'preparing');
          return ++polls < 3
              ? work('req-1', 'preparing')
              : work('req-1', 'running', terminal: tty('t2'));
        });
        final flow = tracker(node);
        final entry = await flow.openWork();
        await settle();
        expect(entry!.status, TerminalRequestStatus.live);
        expect(node.posts.length, 1);
        expect(node.reads('workRequestId=req-1').length, 3);
        expect(opened.single['id'], 't2');
      },
    );

    test('202 preparing can end as a known no-start without retry', () async {
      final node = Node((c) {
        if (isCaps(c)) return caps();
        if (c.method == 'POST') return work('req-1', 'preparing');
        return work(
          'req-1',
          'not_started',
          error: 'isolated_terminal_unavailable',
        );
      });
      final flow = tracker(node);
      final entry = await flow.openWork();
      await settle();
      expect(entry!.status, TerminalRequestStatus.notStarted);
      expect(entry.errorCode, 'isolated_terminal_unavailable');
      // The Node still says isolated: no host-management offer, no switch.
      expect(flow.actions(entry), {
        TerminalRequestAction.startOver,
        TerminalRequestAction.dismiss,
      });
      expect(node.posts.length, 1);
      expect(
        terminalRequestMessage(entry),
        contains('isolated_terminal_unavailable'),
      );
      // Try again is a new action with a new ID.
      node.route = (c) => isCaps(c)
          ? caps()
          : work('req-2', c.method == 'POST' ? 'preparing' : 'settled');
      final next = await flow.startOver(entry);
      expect(next!.requestId, 'req-2');
      expect(flow.entries, isNot(contains(entry)));
      expect(node.posts.last.body!['requestId'], 'req-2');
    });

    test('a failed poll stops polling and leaves refresh', () async {
      var fail = true;
      final node = Node((c) {
        if (isCaps(c)) return caps();
        if (c.method == 'POST') return work('req-1', 'preparing');
        if (fail) throw http(504, 'node_timeout');
        return work('req-1', 'running', terminal: tty('t'));
      });
      final flow = tracker(node);
      final entry = await flow.openWork();
      await settle();
      expect(entry!.status, TerminalRequestStatus.preparing);
      expect(entry.error, isNotNull);
      expect(node.reads('workRequestId').length, 1);
      expect(flow.actions(entry), {TerminalRequestAction.refresh});
      fail = false;
      await flow.refresh(entry);
      expect(entry.status, TerminalRequestStatus.live);
      expect(node.posts.length, 1);
    });

    test('409 conflict: no new request; GET shows the original', () async {
      final node = Node((c) {
        if (isCaps(c)) return caps();
        if (c.method == 'POST') {
          throw http(409, 'work_terminal_request_conflict');
        }
        return work('req-1', 'running', terminal: tty('t'));
      });
      final flow = tracker(node);
      final entry = await flow.openWork();
      expect(entry!.status, TerminalRequestStatus.conflict);
      expect(flow.actions(entry), {
        TerminalRequestAction.refresh,
        TerminalRequestAction.dismiss,
      });
      expect(node.reads('workRequestId'), isEmpty);
      await flow.resubmit(entry);
      expect(node.posts.length, 1);
      await flow.refresh(entry);
      expect(entry.status, TerminalRequestStatus.live);
      expect(node.posts.length, 1);
    });

    test('other 4xx refusals admit nothing; Try again is a new ID', () async {
      final node = Node((c) {
        if (isCaps(c)) return caps();
        throw http(409, 'conflict');
      });
      final flow = tracker(node);
      final entry = await flow.openWork();
      expect(entry!.status, TerminalRequestStatus.rejected);
      expect(node.reads('workRequestId'), isEmpty);
      expect(flow.actions(entry), {
        TerminalRequestAction.startOver,
        TerminalRequestAction.dismiss,
      });
    });

    test('504 then 404 allows re-POSTing the same ID and intent', () async {
      var posted = 0;
      final node = Node((c) {
        if (isCaps(c)) return caps();
        if (c.method == 'POST') {
          if (++posted == 1) throw http(504, 'node_timeout');
          return work('req-1', 'running', terminal: tty('t'));
        }
        throw http(404, 'terminal_request_not_found');
      });
      final flow = tracker(node);
      final entry = await flow.openWork();
      expect(entry!.status, TerminalRequestStatus.notAdmitted);
      expect(node.reads('workRequestId=req-1').length, 1);
      expect(flow.actions(entry), {
        TerminalRequestAction.resubmit,
        TerminalRequestAction.dismiss,
      });
      // Not automatic: only the explicit resubmit sends again.
      expect(node.posts.length, 1);
      await flow.resubmit(entry);
      expect(node.posts.length, 2);
      expect(node.posts[1].body, node.posts[0].body);
      expect(entry.status, TerminalRequestStatus.live);
    });

    test('503 node_offline is resolved by GET, not a new request', () async {
      var polls = 0;
      final node = Node((c) {
        if (isCaps(c)) return caps();
        if (c.method == 'POST') throw http(503, 'node_offline');
        return ++polls == 1
            ? work('req-1', 'preparing')
            : work('req-1', 'running', terminal: tty('t'));
      });
      final flow = tracker(node);
      final entry = await flow.openWork();
      await settle();
      expect(entry!.status, TerminalRequestStatus.live);
      expect(node.posts.length, 1);
      expect(node.reads('workRequestId=req-1').length, 2);
    });

    test('connection loss while reading stays ambiguous: GET only', () async {
      final node = Node((c) {
        if (isCaps(c)) return caps();
        throw network;
      });
      final flow = tracker(node);
      final entry = await flow.openWork();
      expect(entry!.status, TerminalRequestStatus.ambiguous);
      expect(flow.actions(entry), {
        TerminalRequestAction.refresh,
        TerminalRequestAction.dismiss,
      });
      await flow.resubmit(entry);
      await flow.refresh(entry);
      expect(node.posts.length, 1);
      expect(node.reads('workRequestId').length, 2);
      node.route = (c) => work('req-1', 'outcome_unknown');
      await flow.refresh(entry);
      expect(entry.status, TerminalRequestStatus.outcomeUnknown);
      await settle();
      // No automatic retry of an unknown outcome.
      expect(node.posts.length, 1);
      expect(node.log.length, 5);
    });

    test('a lease or size change after 404 allows GET only', () async {
      final node = Node((c) {
        if (isCaps(c)) return caps();
        if (c.method == 'POST') throw http(504, 'node_timeout');
        throw http(404, 'terminal_request_not_found');
      });
      final flow = tracker(node);
      final entry = await flow.openWork();
      expect(entry!.status, TerminalRequestStatus.notAdmitted);
      lease = 8;
      expect(flow.actions(entry), {TerminalRequestAction.dismiss});
      await flow.resubmit(entry);
      expect(node.posts.length, 1);
      lease = 7;
      cols = 100;
      expect(flow.actions(entry), {TerminalRequestAction.dismiss});
      await flow.resubmit(entry);
      expect(node.posts.length, 1);
      cols = 80;
      expect(flow.actions(entry), contains(TerminalRequestAction.resubmit));
    });

    test(
      'unavailable isolation never POSTs the omitted-path host terminal',
      () async {
        for (final value in [
          caps(isolated: 0),
          caps(isolated: 0, host: 0),
          caps(work: 1),
          caps(enabled: false),
          {'terminals': []},
        ]) {
          final node = Node((_) => value);
          final flow = tracker(node);
          expect(await flow.openWork(), isNull);
          expect(node.posts, isEmpty);
          expect(terminalUnavailableMessage(flow), isNotEmpty);
        }
        final mac = Node((_) => caps(isolated: 0));
        final flow = tracker(mac);
        await flow.openWork();
        expect(
          terminalUnavailableMessage(flow),
          contains('host management terminal can be reviewed separately'),
        );
        final broken = Node((_) => throw network);
        final none = tracker(broken);
        expect(await none.openWork(), isNull);
        expect(none.capabilitiesError, isNotNull);
        expect(broken.posts, isEmpty);
      },
    );

    test('no control lease: nothing is read or sent', () async {
      final node = Node((_) => caps());
      final flow = TerminalRequestTracker(
        api: node.api,
        session: 's',
        current: () => null,
      );
      expect(await flow.openWork(), isNull);
      expect(await flow.reviewHost(), isNull);
      expect(node.log, isEmpty);
    });
  });

  group('host management', () {
    test('review, then confirm with the exact review identity', () async {
      final node = Node((c) {
        if (isCaps(c)) return caps(isolated: 0);
        return c.body!['action'] == 'review'
            ? host('req-1', 'review')
            : host('req-1', 'running', terminal: tty('h', 'host_management'));
      });
      final flow = tracker(node);
      expect(await tracker(node).openWork(), isNull);
      expect(node.posts, isEmpty);
      final entry = await flow.reviewHost();
      expect(node.posts.single.body, {
        'clientId': 'phone',
        'generation': 7,
        'cols': 80,
        'rows': 24,
        'executionPath': 'host_management',
        'action': 'review',
        'requestId': 'req-1',
      });
      expect(entry!.status, TerminalRequestStatus.review);
      expect(entry.result!.review!.warning, warning);
      expect(opened, isEmpty);
      await flow.confirm(entry);
      expect(node.posts.last.body, {
        'clientId': 'phone',
        'generation': 7,
        'cols': 80,
        'rows': 24,
        'executionPath': 'host_management',
        'action': 'confirm',
        'requestId': 'req-1',
        'reviewId': 'host_terminal_req-1',
        'reviewHash': 'hash-req-1',
        'confirmed': true,
      });
      expect(entry.status, TerminalRequestStatus.live);
      expect(opened.single['executionPath'], 'host_management');
    });

    test('isolation available: no host review is offered', () async {
      final node = Node((_) => caps());
      expect(await tracker(node).reviewHost(), isNull);
      expect(node.posts, isEmpty);
    });

    test('a lease change blocks confirming the review', () async {
      final node = Node(
        (c) => isCaps(c) ? caps(isolated: 0) : host('req-1', 'review'),
      );
      final flow = tracker(node);
      final entry = await flow.reviewHost();
      lease = 9;
      expect(
        flow.actions(entry!),
        isNot(contains(TerminalRequestAction.confirm)),
      );
      await flow.confirm(entry);
      expect(node.posts.length, 1);
    });

    test('ambiguous confirm recovers with hostRequestId', () async {
      final node = Node((c) {
        if (isCaps(c)) return caps(isolated: 0);
        if (c.method == 'POST') {
          if (c.body!['action'] == 'review') return host('req-1', 'review');
          throw http(504, 'node_timeout');
        }
        return host('req-1', 'running', terminal: tty('h', 'host_management'));
      });
      final flow = tracker(node);
      final entry = await flow.reviewHost();
      await flow.confirm(entry!);
      expect(node.reads('hostRequestId=req-1').length, 1);
      expect(entry.status, TerminalRequestStatus.live);
      expect(node.posts.length, 2);
    });

    test('refused confirm keeps the review and allows GET', () async {
      final node = Node((c) {
        if (isCaps(c)) return caps(isolated: 0);
        if (c.method == 'POST') {
          if (c.body!['action'] == 'review') return host('req-1', 'review');
          throw http(409, 'host_terminal_review_required');
        }
        return host('req-1', 'expired');
      });
      final flow = tracker(node);
      final entry = await flow.reviewHost();
      await flow.confirm(entry!);
      expect(entry.status, TerminalRequestStatus.rejected);
      expect(flow.actions(entry), contains(TerminalRequestAction.refresh));
      await flow.refresh(entry);
      expect(entry.status, TerminalRequestStatus.expired);
      // A new review is a new user action with a new ID.
      node.route = (c) =>
          isCaps(c) ? caps(isolated: 0) : host('req-2', 'review');
      final next = await flow.startOver(entry);
      expect(next!.requestId, 'req-2');
      expect(next.kind, TerminalRequestKind.host);
      expect(node.posts.last.body!['action'], 'review');
    });

    test('an isolated no-start offers the explicit host action only', () async {
      final node = Node((c) {
        if (isCaps(c)) return caps();
        return work(
          'req-1',
          'not_started',
          error: 'isolated_terminal_unavailable',
        );
      });
      final flow = tracker(node);
      final entry = await flow.openWork();
      expect(node.posts.length, 1);
      // The Node now reports isolation unavailable on a capability refresh.
      node.route = (_) => caps(isolated: 0);
      await flow.loadCapabilities();
      expect(
        flow.actions(entry!),
        contains(TerminalRequestAction.hostManagement),
      );
      expect(node.posts.length, 1);
    });
  });

  group('unresolved-request discovery', () {
    test('follows next through short and empty pages', () async {
      final node = Node((c) {
        final uri = Uri.parse('https://x${c.path}');
        expect(uri.queryParameters['unresolvedRequests'], '1');
        expect(uri.queryParameters['limit'], '2');
        return switch (uri.queryParameters['after']) {
          null => {
            'terminalRequests': {
              'version': 1,
              'items': [work('w1', 'preparing'), host('h1', 'review')],
              'next': '10.host.h1',
            },
          },
          '10.host.h1' => {
            'terminalRequests': {
              'version': 1,
              'items': [],
              'next': '11.work.w2',
            },
          },
          '11.work.w2' => {
            'terminalRequests': {
              'version': 1,
              'items': [work('w3', 'outcome_unknown')],
              'next': null,
            },
          },
          _ => throw StateError('unexpected cursor'),
        };
      });
      final items = await node.api.unresolved('s', limit: 2);
      expect(items.map((r) => r.requestId), ['w1', 'h1', 'w3']);
      expect(node.log.length, 3);
      expect(
        node.log[1].path,
        '/api/sessions/s/terminals?unresolvedRequests=1&limit=2&after=10.host.h1',
      );
      expect(node.log.every((c) => c.method == 'GET'), true);
    });

    test('a cursor that does not advance stops paging', () async {
      final node = Node(
        (_) => {
          'terminalRequests': {'version': 1, 'items': [], 'next': 'x'},
        },
      );
      await expectLater(node.api.unresolved('s'), throwsStateError);
      await settle();
      expect(node.log.length, 2);
    });

    test('recover maps each discovered state without POSTing', () async {
      var polls = 0;
      final node = Node((c) {
        if (c.path.contains('unresolvedRequests')) {
          return {
            'terminalRequests': {
              'version': 1,
              'items': [
                work('w1', 'preparing'),
                host('h1', 'review'),
                work('w2', 'outcome_unknown'),
              ],
              'next': null,
            },
          };
        }
        if (c.path.contains('workRequestId=w1')) {
          return ++polls < 2
              ? work('w1', 'preparing')
              : work('w1', 'running', terminal: tty('t1'));
        }
        return host('h1', 'running', terminal: tty('t2', 'host_management'));
      });
      final flow = tracker(node);
      await flow.recover();
      await settle();
      final byId = {for (final e in flow.entries) e.requestId: e};
      expect(byId.keys, ['w1', 'h1', 'w2']);
      expect(byId['w1']!.status, TerminalRequestStatus.live);
      expect(byId['w1']!.intent, isNull);
      expect(byId['h1']!.status, TerminalRequestStatus.review);
      expect(byId['w2']!.status, TerminalRequestStatus.outcomeUnknown);
      expect(flow.actions(byId['w2']!), {
        TerminalRequestAction.refresh,
        TerminalRequestAction.dismiss,
      });
      expect(node.posts, isEmpty);
      // A discovered review is confirmed with the current lease and its size.
      cols = 120;
      expect(
        flow.actions(byId['h1']!),
        contains(TerminalRequestAction.confirm),
      );
      await flow.confirm(byId['h1']!);
      expect(node.posts.single.body!['cols'], 80);
      expect(node.posts.single.body!['reviewId'], 'host_terminal_h1');
      expect(byId['h1']!.status, TerminalRequestStatus.live);
      // Rediscovery updates existing entries instead of duplicating them.
      await flow.recover();
      expect(flow.entries.length, 3);
    });

    test(
      'a discovered request that GET no longer finds is never re-POSTed',
      () async {
        final node = Node((c) {
          if (c.path.contains('unresolvedRequests')) {
            return {
              'terminalRequests': {
                'version': 1,
                'items': [work('w1', 'outcome_unknown')],
                'next': null,
              },
            };
          }
          throw http(404, 'terminal_request_not_found');
        });
        final flow = tracker(node);
        await flow.recover();
        final entry = flow.entries.single;
        await flow.refresh(entry);
        expect(entry.status, TerminalRequestStatus.unrecognized);
        expect(
          flow.actions(entry),
          isNot(contains(TerminalRequestAction.resubmit)),
        );
        expect(node.posts, isEmpty);
      },
    );
  });

  group('v3 specific errors', () {
    test('only 404 terminal_request_not_found means not admitted', () async {
      final node = Node((_) => throw http(404, 'not_found'));
      await expectLater(
        node.api.read('s', TerminalRequestKind.work, 'w'),
        throwsA(isA<PlatformException>()),
      );
      node.route = (_) => throw http(404, terminalRequestNotFound);
      expect(await node.api.read('s', TerminalRequestKind.host, 'h'), isNull);
    });

    test('a missing session after an ambiguous POST is a refusal', () async {
      final node = Node((c) {
        if (isCaps(c)) return caps(work: 3);
        if (c.method == 'POST') throw http(504, 'node_timeout');
        throw http(404, 'not_found');
      });
      final flow = tracker(node);
      final entry = await flow.openWork();
      expect(entry!.status, TerminalRequestStatus.rejected);
      expect(
        flow.actions(entry),
        isNot(contains(TerminalRequestAction.resubmit)),
      );
      await flow.resubmit(entry);
      expect(node.posts.length, 1);
    });

    test('a generic 404 never marks an admitted request missing', () async {
      final node = Node((c) {
        if (c.path.contains('unresolvedRequests')) {
          return {
            'terminalRequests': {
              'version': 1,
              'items': [work('w1', 'outcome_unknown')],
              'next': null,
            },
          };
        }
        throw http(404, 'not_found');
      });
      final flow = tracker(node);
      await flow.recover();
      final entry = flow.entries.single;
      await flow.refresh(entry);
      expect(entry.status, TerminalRequestStatus.outcomeUnknown);
      expect(entry.error, isNotNull);
      expect(node.posts, isEmpty);
    });

    test('409 terminal_capacity is its own definite refusal', () async {
      final node = Node((c) {
        if (isCaps(c)) return caps(work: 3);
        throw http(409, terminalCapacity);
      });
      final flow = tracker(node);
      final entry = await flow.openWork();
      expect(entry!.status, TerminalRequestStatus.capacity);
      expect(flow.actions(entry), {
        TerminalRequestAction.startOver,
        TerminalRequestAction.dismiss,
      });
      expect(node.reads('workRequestId'), isEmpty);
      expect(terminalRequestMessage(entry), contains('Too many terminals'));
      // A host review refused by quota is the same refusal.
      final mac = Node((c) {
        if (isCaps(c)) return caps(isolated: 0, work: 3);
        throw http(409, terminalCapacity);
      });
      final host = await tracker(mac).reviewHost();
      expect(host!.status, TerminalRequestStatus.capacity);
    });
  });

  group('v3 acknowledgement', () {
    Json unresolved(Json item) => {
      'terminalRequests': {
        'version': 1,
        'items': [item],
        'next': null,
      },
    };

    test('acknowledgedAt parses in both result shapes', () {
      expect(
        TerminalRequestResult.parse(
          work('w', 'outcome_unknown', acknowledgedAt: 5),
        ).acknowledgedAt,
        5,
      );
      expect(
        TerminalRequestResult.parse(
          host('h', 'outcome_unknown', acknowledgedAt: 6),
        ).acknowledgedAt,
        6,
      );
      expect(
        TerminalRequestResult.parse(
          work('w', 'outcome_unknown'),
        ).acknowledgedAt,
        isNull,
      );
    });

    test('the API sends exactly one ID and the current lease', () async {
      final node = Node(
        (c) => c.body!.containsKey('workRequestId')
            ? work('w1', 'outcome_unknown', acknowledgedAt: 9)
            : host('h1', 'outcome_unknown', acknowledgedAt: 9),
      );
      final w = await node.api.acknowledge(
        's',
        TerminalRequestKind.work,
        'w1',
        clientId: 'phone',
        generation: 7,
      );
      final h = await node.api.acknowledge(
        's',
        TerminalRequestKind.host,
        'h1',
        clientId: 'phone',
        generation: 7,
      );
      expect(node.posts.map((c) => c.path).toSet(), {
        '/api/sessions/s/terminals',
      });
      expect(node.posts[0].body, {
        'action': 'acknowledge',
        'clientId': 'phone',
        'generation': 7,
        'workRequestId': 'w1',
      });
      expect(node.posts[1].body, {
        'action': 'acknowledge',
        'clientId': 'phone',
        'generation': 7,
        'hostRequestId': 'h1',
      });
      expect((w.acknowledgedAt, h.acknowledgedAt), (9, 9));
      expect(w.state, 'outcome_unknown');
    });

    test('offered only for outcome_unknown on v3 with the lease', () {
      final v3 = TerminalCapabilities.parse(caps(work: 3));
      final v3Disabled = TerminalCapabilities.parse(
        caps(work: 3, enabled: false),
      );
      final v2 = TerminalCapabilities.parse(caps());
      TerminalRequestEntry entry(Json data) {
        final result = TerminalRequestResult.parse(data);
        return TerminalRequestEntry(result.kind, result.requestId, null)
          ..result = result
          ..status = terminalStatusFor(result.phase);
      }

      bool offered(
        TerminalRequestEntry e,
        TerminalCapabilities c, [
        TerminalIntent? lease,
      ]) => terminalRequestActions(
        e,
        current: lease,
        capabilities: c,
      ).contains(TerminalRequestAction.acknowledge);
      final unknown = entry(work('w', 'outcome_unknown'));
      expect(v3.acknowledgesUnknown, true);
      expect(v2.acknowledgesUnknown, false);
      expect(offered(unknown, v3, intent()), true);
      expect(offered(entry(host('h', 'outcome_unknown')), v3, intent()), true);
      // Works while new terminals are disabled; needs the control lease.
      expect(offered(unknown, v3Disabled, intent()), true);
      expect(offered(unknown, v3), false);
      expect(offered(unknown, v2, intent()), false);
      final done = entry(work('w', 'outcome_unknown', acknowledgedAt: 1));
      expect(offered(done, v3, intent()), false);
      for (final data in [
        work('w', 'preparing'),
        work('w', 'running', terminal: tty('t')),
        work('w', 'not_started'),
        work('w', 'settled'),
        host('h', 'review'),
        host('h', 'stale'),
        host('h', 'expired'),
        host('h', 'unconfirmed'),
      ]) {
        expect(offered(entry(data), v3, intent()), false, reason: '$data');
      }
    });

    test('success keeps outcome_unknown and leaves pending', () async {
      final node = Node((c) {
        if (isCaps(c)) return caps(work: 3);
        if (c.path.contains('unresolvedRequests')) {
          return unresolved(work('w1', 'outcome_unknown'));
        }
        return work('w1', 'outcome_unknown', acknowledgedAt: 42);
      });
      final flow = tracker(node);
      await flow.loadCapabilities();
      await flow.recover();
      final entry = flow.entries.single;
      expect(flow.pending, [entry]);
      expect(flow.actions(entry), contains(TerminalRequestAction.acknowledge));
      await flow.acknowledge(entry);
      expect(node.posts.single.body!['workRequestId'], 'w1');
      expect(entry.status, TerminalRequestStatus.outcomeUnknown);
      expect(entry.acknowledged, true);
      expect(flow.pending, isEmpty);
      expect(flow.entries, [entry]);
      expect(
        flow.actions(entry),
        isNot(contains(TerminalRequestAction.acknowledge)),
      );
      final message = terminalRequestMessage(entry);
      expect(message, contains('still not confirmed'));
      expect(message, isNot(contains('closed')));
      await flow.acknowledge(entry);
      expect(node.posts.length, 1);
    });

    test('409 terminal_request_not_unknown re-reads the result', () async {
      final node = Node((c) {
        if (isCaps(c)) return caps(work: 3);
        if (c.path.contains('unresolvedRequests')) {
          return unresolved(host('h1', 'outcome_unknown'));
        }
        if (c.method == 'POST') {
          throw http(409, 'terminal_request_not_unknown');
        }
        return host('h1', 'unconfirmed');
      });
      final flow = tracker(node);
      await flow.loadCapabilities();
      await flow.recover();
      final entry = flow.entries.single;
      await flow.acknowledge(entry);
      expect(node.reads('hostRequestId=h1').length, 1);
      expect(entry.status, TerminalRequestStatus.unconfirmed);
      expect(entry.acknowledged, false);
      expect(node.posts.length, 1);
    });

    test('an ambiguous acknowledgement is resolved by GET', () async {
      final node = Node((c) {
        if (isCaps(c)) return caps(work: 3);
        if (c.path.contains('unresolvedRequests')) {
          return unresolved(work('w1', 'outcome_unknown'));
        }
        if (c.method == 'POST') throw http(504, 'node_timeout');
        return work('w1', 'outcome_unknown', acknowledgedAt: 3);
      });
      final flow = tracker(node);
      await flow.loadCapabilities();
      await flow.recover();
      final entry = flow.entries.single;
      await flow.acknowledge(entry);
      expect(node.posts.length, 1);
      expect(node.reads('workRequestId=w1').length, 1);
      expect(entry.status, TerminalRequestStatus.outcomeUnknown);
      expect(entry.acknowledged, true);
      expect(flow.pending, isEmpty);
    });

    test('a definite refusal keeps the request pending', () async {
      final node = Node((c) {
        if (isCaps(c)) return caps(work: 3);
        if (c.path.contains('unresolvedRequests')) {
          return unresolved(work('w1', 'outcome_unknown'));
        }
        throw http(409, 'stale_control');
      });
      final flow = tracker(node);
      await flow.loadCapabilities();
      await flow.recover();
      final entry = flow.entries.single;
      await flow.acknowledge(entry);
      expect(entry.status, TerminalRequestStatus.outcomeUnknown);
      expect(entry.error, isNotNull);
      expect(flow.pending, [entry]);
      expect(node.reads('workRequestId'), isEmpty);
    });

    test('a v2 Node or no lease sends no acknowledgement', () async {
      final node = Node(
        (c) => isCaps(c) ? caps() : unresolved(work('w1', 'outcome_unknown')),
      );
      final flow = tracker(node);
      await flow.loadCapabilities();
      await flow.recover();
      await flow.acknowledge(flow.entries.single);
      expect(node.posts, isEmpty);
      final v3 = Node(
        (c) => isCaps(c)
            ? caps(work: 3)
            : unresolved(work('w1', 'outcome_unknown')),
      );
      final noLease = TerminalRequestTracker(
        api: v3.api,
        session: 's',
        current: () => null,
      );
      trackers.add(noLease);
      await noLease.loadCapabilities();
      await noLease.recover();
      await noLease.acknowledge(noLease.entries.single);
      expect(v3.posts, isEmpty);
    });
  });

  group('terminal pane state', () {
    test(
      'New terminal opens isolated work and recovery runs on load',
      () async {
        final node = Node((c) {
          if (isCaps(c)) return caps();
          if (c.path.contains('unresolvedRequests')) {
            return {
              'terminalRequests': {
                'version': 1,
                'items': [work('old', 'outcome_unknown')],
                'next': null,
              },
            };
          }
          if (c.method == 'POST') {
            return work(
              '${c.body!['requestId']}',
              'running',
              terminal: tty('t1'),
            );
          }
          return {'terminals': []};
        });
        final c = LiveController(node.gateway)
          ..sessionId = 's'
          ..clientId = 'phone'
          ..control = {'held': true, 'generation': 4};
        final s = TerminalPaneState(c);
        await settle();
        expect(s.pendingRequests.single.requestId, 'old');
        expect(s.requests!.capabilities!.offersIsolated, true);
        await s.create();
        expect(s.error, '');
        expect(s.current, 't1');
        expect(s.terminals.single['executionPath'], 'isolated_work');
        final post = node.posts.single.body!;
        expect(post['executionPath'], 'isolated_work');
        expect(post['generation'], 4);
        expect(post['requestId'], matches(RegExp(r'^[0-9a-f-]{36}$')));
        expect(s.pendingRequests.length, 1);
        // v2 capabilities: no acknowledgement; dismiss is local only.
        expect(
          s.requests!.actions(s.pendingRequests.single),
          isNot(contains(TerminalRequestAction.acknowledge)),
        );
        await s.perform(
          s.pendingRequests.single,
          TerminalRequestAction.dismiss,
        );
        expect(s.pendingRequests, isEmpty);
        s.dispose();
        c.dispose();
      },
    );

    test('acknowledging drops a request from the pane', () async {
      final node = Node((c) {
        if (isCaps(c)) return caps(work: 3);
        if (c.path.contains('unresolvedRequests')) {
          return {
            'terminalRequests': {
              'version': 1,
              'items': [work('old', 'outcome_unknown')],
              'next': null,
            },
          };
        }
        if (c.method == 'POST') {
          return work('old', 'outcome_unknown', acknowledgedAt: 8);
        }
        return {'terminals': []};
      });
      final c = LiveController(node.gateway)
        ..sessionId = 's'
        ..clientId = 'phone'
        ..control = {'held': true, 'generation': 4};
      final s = TerminalPaneState(c);
      await settle();
      final entry = s.pendingRequests.single;
      await s.perform(entry, TerminalRequestAction.acknowledge);
      expect(node.posts.single.body, {
        'action': 'acknowledge',
        'clientId': 'phone',
        'generation': 4,
        'workRequestId': 'old',
      });
      expect(s.pendingRequests, isEmpty);
      expect(
        s.requests!.entries.single.status,
        TerminalRequestStatus.outcomeUnknown,
      );
      s.dispose();
      c.dispose();
    });

    test('isolation unavailable explains itself and never POSTs', () async {
      final node = Node((c) {
        if (isCaps(c)) return caps(isolated: 0, host: 0);
        return {'terminals': []};
      });
      final c = LiveController(node.gateway)
        ..sessionId = 's'
        ..clientId = 'phone'
        ..control = {'held': true, 'generation': 4};
      final s = TerminalPaneState(c);
      await settle();
      await s.create();
      expect(s.error, 'Isolated terminals are unavailable on this Node.');
      await s.reviewHost();
      expect(node.posts, isEmpty);
      s.dispose();
      c.dispose();
    });

    testWidgets('pane shows a discovered review verbatim and confirms it', (
      t,
    ) async {
      t.view.devicePixelRatio = 1;
      t.view.physicalSize = const Size(390, 900);
      addTearDown(t.view.reset);
      final node = Node((c) {
        if (isCaps(c)) return caps(isolated: 0);
        if (c.path.contains('unresolvedRequests')) {
          return {
            'terminalRequests': {
              'version': 1,
              'items': [host('h1', 'review')],
              'next': null,
            },
          };
        }
        if (c.method == 'POST') {
          return host('h1', 'running', terminal: tty('t7', 'host_management'));
        }
        return {'terminals': []};
      });
      final c = LiveController(node.gateway)
        ..sessionId = 's'
        ..clientId = 'phone'
        ..control = {'held': true, 'generation': 4};
      await t.pumpWidget(
        MaterialApp(
          theme: theme.build(Brightness.light),
          home: Scaffold(body: TerminalPane(controller: c, touch: true)),
        ),
      );
      await t.pumpAndSettle();
      expect(find.byTooltip('Host management terminal…'), findsOneWidget);
      expect(find.text(warning), findsOneWidget);
      expect(find.text('Shell: /bin/zsh'), findsOneWidget);
      expect(find.text('Size: 80×24'), findsOneWidget);
      expect(node.posts, isEmpty);
      await t.tap(find.text('Confirm and open'));
      await t.pumpAndSettle();
      expect(node.posts.single.body!['action'], 'confirm');
      expect(node.posts.single.body!['reviewHash'], 'hash-h1');
      expect(find.text(warning), findsNothing);
      expect(find.text('host management'), findsOneWidget);
      await t.pumpWidget(const SizedBox());
      c.dispose();
      await node.gateway.stream.close();
      await t.pump();
    });
  });
}
