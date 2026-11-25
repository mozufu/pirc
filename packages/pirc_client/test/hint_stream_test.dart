import 'package:fake_async/fake_async.dart';
import 'package:pirc_client/pirc_client.dart';
import 'package:test/test.dart';

import 'support/fakes.dart';

class _Harness {
  _Harness(FakeAsync async) {
    transport = FakeTransport(
      onConnect: (_) async {
        if (failures.isNotEmpty) throw failures.removeAt(0);
        final socket = FakeEventSocket();
        sockets.add(socket);
        return socket;
      },
    );
    stream = HintStream(
      transport: transport,
      kinds: const {'sessions', 'pots'},
      random: FixedRandom(0),
    );
    stream.signals.listen(signals.add);
  }

  late final FakeTransport transport;
  late final HintStream stream;
  final sockets = <FakeEventSocket>[];
  final signals = <HintSignal>[];
  final failures = <Object>[];

  int get readAgain => signals.whereType<HintsReadAgain>().length;
  List<String> get hints => [
    for (final signal in signals)
      if (signal is HintArrived) signal.type,
  ];
}

void main() {
  test('asks for its kinds and reports hints', () {
    fakeAsync((async) {
      final h = _Harness(async)..stream.start();
      async.flushMicrotasks();
      final target = h.transport.connects.single;
      expect(target.path, '/api/hints');
      expect(target.queryParameters, {'sessions': '1', 'pots': '1'});
      expect(h.stream.state, EventConnectionState.connected);
      expect(h.readAgain, 1, reason: 'the first open reads everything');
      h.sockets.last.push({'type': 'sessions_changed'});
      h.sockets.last.push({'type': 'pots_changed'});
      h.sockets.last.push({'type': 'pi_event', 'epoch': 1, 'sequence': 1});
      async.flushMicrotasks();
      expect(h.hints, ['sessions_changed', 'pots_changed']);
    });
  });

  test('a reconnect asks for a new read', () {
    fakeAsync((async) {
      final h = _Harness(async)..stream.start();
      async.flushMicrotasks();
      h.sockets.last.serverClose(1006);
      async.flushMicrotasks();
      expect(h.stream.state, EventConnectionState.waiting);
      async.elapse(const Duration(milliseconds: 750));
      expect(h.stream.state, EventConnectionState.connected);
      expect(h.readAgain, 2);
    });
  });

  test('close code 1013 connects again at once', () {
    fakeAsync((async) {
      final h = _Harness(async)..stream.start();
      async.flushMicrotasks();
      h.sockets.last.serverClose(backpressureCloseCode, 'resync required');
      async.flushMicrotasks();
      expect(h.sockets, hasLength(2));
      expect(h.stream.state, EventConnectionState.connected);
      expect(h.readAgain, 2);
    });
  });

  test('backs off while the gateway cannot be reached', () {
    fakeAsync((async) {
      final h = _Harness(async)
        ..failures.addAll([
          const TransportException('down'),
          const TransportException('down'),
        ])
        ..stream.start();
      async.flushMicrotasks();
      expect(h.stream.state, EventConnectionState.waiting);
      async.elapse(const Duration(milliseconds: 750));
      expect(h.stream.state, EventConnectionState.waiting);
      async.elapse(const Duration(milliseconds: 1500));
      expect(h.stream.state, EventConnectionState.connected);
      expect(h.readAgain, 1);
    });
  });

  test('4401 and a 401 refusal stop with PairingRequired', () {
    fakeAsync((async) {
      final h = _Harness(async)..stream.start();
      async.flushMicrotasks();
      h.sockets.last.serverClose(4401);
      async.flushMicrotasks();
      expect(h.stream.state, EventConnectionState.stopped);
      expect(
        h.signals.whereType<HintsStopped>().single.error,
        isA<PairingRequired>(),
      );
      async.elapse(const Duration(minutes: 1));
      expect(h.sockets, hasLength(1), reason: 'no retry after a fatal close');

      final refused = _Harness(async)
        ..failures.add(const EventSocketRefused(401, 'no'))
        ..stream.start();
      async.flushMicrotasks();
      expect(
        refused.signals.whereType<HintsStopped>().single.error,
        isA<PairingRequired>(),
      );
    });
  });
}
