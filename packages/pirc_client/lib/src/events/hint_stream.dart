import 'dart:async';
import 'dart:math';

import '../errors.dart';
import '../models/event_message.dart';
import '../transport/transport.dart';
import 'event_stream.dart';

/// What a [HintStream] reports.
sealed class HintSignal {
  const HintSignal();
}

/// A `<kind>_changed` frame: lists of that kind read again.
class HintArrived extends HintSignal {
  const HintArrived(this.type);
  final String type;
}

/// The socket (re)opened. The Gateway replays nothing, so every list reads
/// again: a change may have been missed while the socket was down.
class HintsReadAgain extends HintSignal {
  const HintsReadAgain();
}

class HintConnectionChanged extends HintSignal {
  const HintConnectionChanged(this.state);
  final EventConnectionState state;
}

/// The stream gave up for good ([error] says why); it does not retry.
class HintsStopped extends HintSignal {
  const HintsStopped(this.error);
  final PircException error;
}

/// The hint names `/api/hints` accepts as query flags.
const hintKinds = {
  'directory',
  'memory',
  'schedules',
  'sessions',
  'pots',
  'threads',
  'approvals',
  'activity',
  'budgetRequests',
  'notifications',
  'causalRoots',
};

/// The `/api/hints` socket: change hints without a session. It reconnects
/// with the backoff of [SessionEventStream], stops on the same fatal close
/// codes, and connects again after close code 1013 (the client was too slow).
class HintStream {
  HintStream({
    required this.transport,
    required this.kinds,
    this.connectTimeout = const Duration(seconds: 15),
    Random? random,
  }) : assert(kinds.isNotEmpty && kinds.every(hintKinds.contains)),
       _random = random ?? Random();

  final Transport transport;

  /// Subset of [hintKinds].
  final Set<String> kinds;
  final Duration connectTimeout;
  final Random _random;

  final _signals = StreamController<HintSignal>.broadcast();
  EventSocket? _socket;
  StreamSubscription<Object?>? _subscription;
  Timer? _timer;
  int _attempts = 0;
  int _generation = 0;
  EventConnectionState _state = EventConnectionState.idle;

  Stream<HintSignal> get signals => _signals.stream;
  EventConnectionState get state => _state;

  /// Failed attempts since the last successful open.
  int get attempts => _attempts;

  Uri get target => Uri(
    path: '/api/hints',
    queryParameters: {for (final kind in kinds) kind: '1'},
  );

  void start() {
    if (_state == EventConnectionState.idle) unawaited(_open());
  }

  /// Connectivity regained or the app came back: reconnect now instead of
  /// waiting out the backoff. Does nothing while connected.
  void retryNow() {
    if (_state != EventConnectionState.waiting &&
        _state != EventConnectionState.connecting) {
      return;
    }
    _timer?.cancel();
    _attempts = 0;
    unawaited(_open());
  }

  Future<void> close() async {
    _setState(EventConnectionState.stopped);
    _drop();
    await _signals.close();
  }

  void _drop() {
    _generation++;
    _timer?.cancel();
    unawaited(_subscription?.cancel());
    unawaited(_socket?.close(1000, 'Closed'));
    _subscription = null;
    _socket = null;
  }

  Future<void> _open() async {
    final generation = ++_generation;
    _setState(EventConnectionState.connecting);
    final EventSocket socket;
    try {
      final pending = transport.connectEvents(target);
      socket = await pending.timeout(
        connectTimeout,
        onTimeout: () {
          unawaited(
            pending.then(
              (abandoned) => abandoned.close(1000, 'Timed out'),
              onError: (Object _) {},
            ),
          );
          throw const TransportException('Hint socket connect timed out');
        },
      );
    } on EventSocketRefused catch (error) {
      if (generation != _generation) return;
      final fatal = _refusal(error.status);
      return fatal != null ? _stop(fatal) : _schedule();
    } catch (_) {
      if (generation != _generation) return;
      return _schedule();
    }
    if (generation != _generation || _state == EventConnectionState.stopped) {
      unawaited(socket.close(1000, 'Replaced'));
      return;
    }
    _socket = socket;
    _attempts = 0;
    _setState(EventConnectionState.connected);
    _emit(const HintsReadAgain());
    _subscription = socket.messages.listen(
      _onFrame,
      onError: (Object _) {},
      onDone: () {
        if (generation == _generation) _onClosed(socket.closeCode);
      },
    );
  }

  void _onFrame(Object? frame) {
    if (EventMessage.fromJson(frame) case HintMessage hint) {
      _emit(HintArrived(hint.type));
    }
  }

  void _onClosed(int? code) {
    _subscription = null;
    _socket = null;
    if (_state == EventConnectionState.stopped) return;
    if (code != null && fatalCloseCodes.contains(code)) {
      return _stop(
        code == 4401
            ? const PairingRequired('Device token revoked or expired')
            : ApiError(
                code - 4000,
                'hint_socket_closed',
                'Hint socket closed ($code)',
              ),
      );
    }
    if (code == backpressureCloseCode) {
      // Too slow: connect again at once; the open reads everything again.
      _attempts = 0;
      unawaited(_open());
      return;
    }
    _schedule();
  }

  PircException? _refusal(int? status) => switch (status) {
    401 => const PairingRequired('Hint socket refused (401)'),
    426 => const ClientUpgradeRequired('Hint socket refused (426)'),
    409 => const AccountChanged('Hint socket refused (409)'),
    400 || 403 || 404 => ApiError(
      status!,
      'hint_socket_refused',
      'Hint socket refused ($status)',
    ),
    _ => null,
  };

  void _schedule() {
    if (_state == EventConnectionState.stopped) return;
    _setState(EventConnectionState.waiting);
    final delay = reconnectDelay(_attempts++, _random.nextDouble());
    _timer = Timer(delay, () => unawaited(_open()));
  }

  void _stop(PircException error) {
    _drop();
    _setState(EventConnectionState.stopped);
    _emit(HintsStopped(error));
  }

  void _setState(EventConnectionState state) {
    if (_state == state) return;
    _state = state;
    _emit(HintConnectionChanged(state));
  }

  void _emit(HintSignal signal) {
    if (!_signals.isClosed) _signals.add(signal);
  }
}
