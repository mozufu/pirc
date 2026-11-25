import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:pirc_client/pirc_client.dart';
import 'package:test/test.dart';

import 'support/fakes.dart';

Map<String, Object?> _event(int epoch, int sequence) => {
  'sessionId': 's1',
  'epoch': epoch,
  'sequence': sequence,
  'type': 'pi_event',
  'timestamp': 0,
  'data': <String, Object?>{},
};

/// A stream over a [FakeTransport] whose connections succeed with fresh
/// [FakeEventSocket]s unless [failures] says otherwise.
class _Harness {
  _Harness(
    FakeAsync async, {
    Cursor? cursor,
    double jitter = 0,
    Set<String> hints = const {},
  }) : _async = async {
    transport = FakeTransport(
      onConnect: (_) async {
        connectTimes.add(_async.elapsed);
        if (failures.isNotEmpty) throw failures.removeAt(0);
        if (failAll != null) throw failAll!;
        final socket = FakeEventSocket();
        sockets.add(socket);
        return socket;
      },
    );
    stream = SessionEventStream(
      transport: transport,
      sessionId: 's1',
      cursor: cursor,
      hints: hints,
      random: FixedRandom(jitter),
    );
    stream.signals.listen(signals.add);
  }

  final FakeAsync _async;
  late final FakeTransport transport;
  late final SessionEventStream stream;
  final sockets = <FakeEventSocket>[];
  final signals = <EventStreamSignal>[];
  final connectTimes = <Duration>[];
  final failures = <Object>[];
  Object? failAll;

  FakeEventSocket get socket => sockets.last;

  List<int> get sequences => [
    for (final signal in signals)
      if (signal is EventReceived) signal.event.sequence,
  ];

  List<SnapshotNeeded> get snapshotsNeeded =>
      signals.whereType<SnapshotNeeded>().toList();

  void flush() => _async.flushMicrotasks();
}

void main() {
  test('reconnect delay is min(20 s, 750 ms·2^n) plus up to 400 ms jitter', () {
    expect(reconnectDelay(0, 0), const Duration(milliseconds: 750));
    expect(reconnectDelay(1, 0), const Duration(milliseconds: 1500));
    expect(reconnectDelay(4, 0), const Duration(milliseconds: 12000));
    expect(reconnectDelay(5, 0), const Duration(milliseconds: 20000));
    expect(reconnectDelay(60, 0.999), const Duration(milliseconds: 20399));
  });

  test('resumes from the last event cursor after a drop', () {
    fakeAsync((async) {
      final h = _Harness(async, cursor: const Cursor(2, 10));
      h.stream.start();
      h.flush();
      expect(h.transport.connects.single.path, '/api/events');
      expect(h.transport.connects.single.queryParameters, {
        'sessionId': 's1',
        'cursor': '2:10',
      });

      h.socket
        ..push(_event(2, 11))
        ..push(_event(2, 12));
      h.flush();
      expect(h.stream.cursor, const Cursor(2, 12));

      h.socket.serverClose(1006);
      h.flush();
      expect(h.stream.state, EventConnectionState.waiting);
      async.elapse(const Duration(milliseconds: 749));
      expect(h.transport.connects, hasLength(1));
      async.elapse(const Duration(milliseconds: 1));
      expect(h.transport.connects, hasLength(2));
      expect(h.transport.connects[1].queryParameters['cursor'], '2:12');

      // A replay of what was already seen is dropped.
      h.socket
        ..push(_event(2, 12))
        ..push(_event(2, 13));
      h.flush();
      expect(h.sequences, [11, 12, 13]);
      unawaited(h.stream.close());
    });
  });

  test('backs off exponentially up to 20 s, resetting after an open', () {
    fakeAsync((async) {
      final h = _Harness(async, jitter: 0.5)
        ..failAll = const TransportException('offline');
      h.stream.start();
      async.elapse(const Duration(minutes: 2));
      final gaps = [
        for (var i = 1; i < 8; i++)
          (h.connectTimes[i] - h.connectTimes[i - 1]).inMilliseconds,
      ];
      expect(gaps, [950, 1700, 3200, 6200, 12200, 20200, 20200]);

      // Connected again: the next drop waits the shortest delay.
      h.failAll = null;
      h.stream.retryNow();
      h.flush();
      expect(h.stream.state, EventConnectionState.connected);
      expect(h.stream.attempts, 0);
      final opened = async.elapsed;
      h.socket.serverClose(1006);
      async.elapse(const Duration(seconds: 1));
      expect(h.connectTimes.last - opened, const Duration(milliseconds: 950));
      unawaited(h.stream.close());
    });
  });

  test('retryNow skips the wait, and does nothing while connected', () {
    fakeAsync((async) {
      final h = _Harness(async)
        ..failures.addAll(List.filled(5, const TransportException('x')));
      h.stream.start();
      async.elapse(const Duration(seconds: 20));
      final before = h.transport.connects.length;
      expect(h.stream.state, EventConnectionState.waiting);
      h.stream.retryNow();
      h.flush();
      expect(h.transport.connects, hasLength(before + 1));
      if (h.stream.state == EventConnectionState.connected) {
        h.stream.retryNow();
        h.flush();
        expect(h.transport.connects, hasLength(before + 1));
      }
      unawaited(h.stream.close());
    });
  });

  for (final code in fatalCloseCodes) {
    test('close code $code stops retrying', () {
      fakeAsync((async) {
        final h = _Harness(async);
        h.stream.start();
        h.flush();
        h.socket.serverClose(code);
        async.elapse(const Duration(minutes: 5));
        expect(h.transport.connects, hasLength(1));
        expect(h.stream.state, EventConnectionState.stopped);
        final stopped = h.signals.whereType<StreamStopped>().single;
        if (code == 4401) {
          expect(stopped.error, isA<PairingRequired>());
        } else {
          expect(stopped.error, isA<ApiError>());
        }
        unawaited(h.stream.close());
      });
    });
  }

  test('a refused upgrade stops on 401 but retries on 503', () {
    fakeAsync((async) {
      final h = _Harness(async)
        ..failures.add(const EventSocketRefused(503, 'busy'));
      h.stream.start();
      async.elapse(const Duration(seconds: 1));
      expect(h.stream.state, EventConnectionState.connected);
      unawaited(h.stream.close());

      final pairing = _Harness(async)
        ..failures.add(const EventSocketRefused(401, 'no'));
      pairing.stream.start();
      async.elapse(const Duration(minutes: 1));
      expect(pairing.transport.connects, hasLength(1));
      expect(
        pairing.signals.whereType<StreamStopped>().single.error,
        isA<PairingRequired>(),
      );
    });
  });

  test('an unexpected connect failure is retried, not stuck', () {
    fakeAsync((async) {
      final h = _Harness(async)..failures.add(StateError('keystore locked'));
      h.stream.start();
      h.flush();
      expect(h.stream.state, EventConnectionState.waiting);
      async.elapse(const Duration(milliseconds: 750));
      expect(h.stream.state, EventConnectionState.connected);
      unawaited(h.stream.close());
    });
  });

  test('an upgrade refused with 409 is a changed account and stops', () {
    fakeAsync((async) {
      final h = _Harness(async)
        ..failures.add(const EventSocketRefused(409, 'account'));
      h.stream.start();
      async.elapse(const Duration(minutes: 1));
      expect(h.transport.connects, hasLength(1));
      expect(
        h.signals.whereType<StreamStopped>().single.error,
        isA<AccountChanged>(),
      );
    });
  });

  test('reset asks for a snapshot and resumes from its watermark', () {
    fakeAsync((async) {
      final h = _Harness(async, cursor: const Cursor(1, 5));
      h.stream.start();
      h.flush();
      h.socket.push({
        'type': 'reset',
        'reason': 'cursor_expired_or_epoch_changed',
        'watermark': {'epoch': 2, 'sequence': 40},
      });
      h.flush();
      final needed = h.snapshotsNeeded.single;
      expect(needed.reason, 'cursor_expired_or_epoch_changed');
      expect(needed.watermark, const Cursor(2, 40));
      expect(h.stream.cursor, const Cursor(2, 40));
      expect(h.stream.state, EventConnectionState.connected);

      // The snapshot came back at 2:45: replay from there on a new socket.
      final first = h.socket;
      h.stream.resumeFrom(const Cursor(2, 45));
      h.flush();
      expect(first.closedByClient, isTrue);
      expect(h.transport.connects, hasLength(2));
      expect(h.transport.connects.last.queryParameters['cursor'], '2:45');
      h.socket
        ..push(_event(2, 44))
        ..push(_event(2, 46));
      h.flush();
      expect(h.sequences, [46]);

      // A late close of the replaced socket changes nothing.
      first.serverClose(1006);
      async.elapse(const Duration(seconds: 30));
      expect(h.transport.connects, hasLength(2));
      unawaited(h.stream.close());
    });
  });

  test('1013 is a reset and a reconnect', () {
    fakeAsync((async) {
      final h = _Harness(async);
      h.stream.start();
      h.flush();
      h.socket.push({
        'type': 'reset',
        'reason': 'backpressure',
        'watermark': {'epoch': 3, 'sequence': 9},
      });
      h.socket.serverClose(1013, 'resync required');
      async.elapse(const Duration(seconds: 1));
      expect(h.snapshotsNeeded, hasLength(1));
      expect(h.transport.connects, hasLength(2));
      expect(h.transport.connects.last.queryParameters['cursor'], '3:9');

      // Without a reset frame first, 1013 still asks for a snapshot.
      h.socket.serverClose(1013);
      async.elapse(const Duration(seconds: 1));
      expect(h.snapshotsNeeded, hasLength(2));
      expect(h.snapshotsNeeded.last.reason, 'backpressure');
      expect(h.transport.connects, hasLength(3));
      unawaited(h.stream.close());
    });
  });

  test('hints are reported and never move the cursor', () {
    fakeAsync((async) {
      final h = _Harness(
        async,
        cursor: const Cursor(2, 1),
        hints: {'memory', 'sessions'},
      );
      h.stream.start();
      h.flush();
      expect(h.transport.connects.single.queryParameters, {
        'sessionId': 's1',
        'cursor': '2:1',
        'memory': '1',
        'sessions': '1',
      });
      h.socket.push({'type': 'memory_changed'});
      h.flush();
      expect(h.signals.whereType<HintReceived>().single.type, 'memory_changed');
      expect(h.stream.cursor, const Cursor(2, 1));
      unawaited(h.stream.close());
    });
  });

  test('close stops everything', () {
    fakeAsync((async) {
      final h = _Harness(async);
      h.stream.start();
      h.flush();
      final socket = h.socket;
      unawaited(h.stream.close());
      h.flush();
      expect(socket.closedByClient, isTrue);
      async.elapse(const Duration(minutes: 1));
      expect(h.transport.connects, hasLength(1));
    });
  });
}
