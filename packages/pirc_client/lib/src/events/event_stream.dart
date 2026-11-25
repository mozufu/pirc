import 'dart:async';
import 'dart:math';

import '../errors.dart';
import '../models/cursor.dart';
import '../models/event_message.dart';
import '../transport/transport.dart';

/// What a [SessionEventStream] reports.
sealed class EventStreamSignal {
  const EventStreamSignal();
}

/// A session event, in order. Its cursor is already remembered.
class EventReceived extends EventStreamSignal {
  const EventReceived(this.event);
  final SessionEvent event;
}

/// The events can no longer be applied: load a new snapshot, then call
/// [SessionEventStream.resumeFrom] with its watermark.
class SnapshotNeeded extends EventStreamSignal {
  const SnapshotNeeded(this.reason, this.watermark);
  final String reason;
  final Cursor? watermark;
}

/// An out-of-sequence hint (`directory_changed`, …).
class HintReceived extends EventStreamSignal {
  const HintReceived(this.type);
  final String type;
}

class ConnectionChanged extends EventStreamSignal {
  const ConnectionChanged(this.state);
  final EventConnectionState state;
}

/// The stream gave up for good ([error] says why); it does not retry.
class StreamStopped extends EventStreamSignal {
  const StreamStopped(this.error);
  final PircException error;
}

enum EventConnectionState { idle, connecting, connected, waiting, stopped }

/// Close codes after which retrying cannot help.
const fatalCloseCodes = {4400, 4401, 4403, 4404};

/// The gateway closed a lagging socket after a `backpressure` reset.
const backpressureCloseCode = 1013;

/// `min(20 s, 750 ms·2^attempt) + jitter·400 ms` (`jitter` in [0, 1)).
Duration reconnectDelay(int attempt, double jitter) {
  final base = attempt >= 15 ? 20000 : min(20000, 750 * (1 << attempt));
  return Duration(milliseconds: base + (jitter * 400).floor());
}

/// The `/api/events` stream of one session: resumes from the last event's
/// cursor, reconnects with backoff, and stops on fatal close codes.
class SessionEventStream {
  SessionEventStream({
    required this.transport,
    required this.sessionId,
    Cursor? cursor,
    this.hints = const {},
    Random? random,
  }) : _random = random ?? Random() {
    _cursor = cursor;
  }

  final Transport transport;
  final String sessionId;

  /// Hint subscriptions: any of `directory`, `memory`, `schedules`, `sessions`.
  final Set<String> hints;
  final Random _random;

  final _signals = StreamController<EventStreamSignal>.broadcast();
  Cursor? _cursor;
  EventSocket? _socket;
  StreamSubscription<Object?>? _subscription;
  Timer? _timer;
  int _attempts = 0;
  int _generation = 0;
  bool _resetSeen = false;
  EventConnectionState _state = EventConnectionState.idle;

  Stream<EventStreamSignal> get signals => _signals.stream;

  /// Where the next connection resumes.
  Cursor? get cursor => _cursor;
  EventConnectionState get state => _state;

  /// Failed attempts since the last successful open.
  int get attempts => _attempts;

  void start() {
    if (_state == EventConnectionState.idle) unawaited(_open());
  }

  /// Connectivity regained or page visible: reconnect now instead of waiting
  /// out the backoff. Does nothing while connected or connecting.
  void retryNow() {
    if (_state != EventConnectionState.waiting) return;
    _timer?.cancel();
    _attempts = 0;
    unawaited(_open());
  }

  /// After loading a snapshot: continue from its [watermark]. An open socket
  /// is replaced so the gateway replays everything after the watermark;
  /// events delivered since the reset may be dropped by the caller.
  void resumeFrom(Cursor watermark) {
    _cursor = watermark;
    switch (_state) {
      case EventConnectionState.connected || EventConnectionState.connecting:
        _drop();
        unawaited(_open());
      case EventConnectionState.waiting:
        retryNow();
      case EventConnectionState.idle || EventConnectionState.stopped:
        break;
    }
  }

  Future<void> close() async {
    _setState(EventConnectionState.stopped);
    _drop();
    await _signals.close();
  }

  Uri get _target => Uri(
    path: '/api/events',
    queryParameters: {
      'sessionId': sessionId,
      if (_cursor != null) 'cursor': _cursor.toString(),
      for (final hint in hints) hint: '1',
    },
  );

  void _drop() {
    _generation++;
    _timer?.cancel();
    unawaited(_subscription?.cancel());
    unawaited(_socket?.close(1000, 'Resync'));
    _subscription = null;
    _socket = null;
  }

  Future<void> _open() async {
    final generation = ++_generation;
    _setState(EventConnectionState.connecting);
    final EventSocket socket;
    try {
      socket = await transport.connectEvents(_target);
    } on EventSocketRefused catch (error) {
      if (generation != _generation) return;
      final fatal = _refusal(error.status);
      return fatal != null ? _stop(fatal) : _schedule();
    } on TransportException {
      if (generation != _generation) return;
      return _schedule();
    } catch (_) {
      // A token store or platform failure: keep retrying, never get stuck.
      if (generation != _generation) return;
      return _schedule();
    }
    if (generation != _generation || _state == EventConnectionState.stopped) {
      unawaited(socket.close(1000, 'Replaced'));
      return;
    }
    _socket = socket;
    _attempts = 0;
    _resetSeen = false;
    _setState(EventConnectionState.connected);
    _subscription = socket.messages.listen(
      _onFrame,
      onError: (Object _) {},
      onDone: () {
        if (generation == _generation) _onClosed(socket.closeCode);
      },
    );
  }

  void _onFrame(Object? frame) {
    switch (EventMessage.fromJson(frame)) {
      case SessionEvent event:
        final last = _cursor;
        // A replay after resumeFrom may repeat what the snapshot holds.
        if (last != null && event.epoch == last.epoch && event.cursor <= last) {
          return;
        }
        _cursor = event.cursor;
        _emit(EventReceived(event));
      case ResetMessage reset:
        _resetSeen = true;
        if (reset.watermark != null) _cursor = reset.watermark;
        _emit(SnapshotNeeded(reset.reason, reset.watermark));
      case HintMessage hint:
        _emit(HintReceived(hint.type));
      case null:
        break;
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
                'event_socket_closed',
                'Event socket closed ($code)',
              ),
      );
    }
    if (code == backpressureCloseCode && !_resetSeen) {
      _emit(const SnapshotNeeded('backpressure', null));
    }
    _schedule();
  }

  PircException? _refusal(int? status) => switch (status) {
    401 => const PairingRequired('Event socket refused (401)'),
    426 => const ClientUpgradeRequired('Event socket refused (426)'),
    409 => const AccountChanged('Event socket refused (409)'),
    400 || 403 || 404 => ApiError(
      status!,
      'event_socket_refused',
      'Event socket refused ($status)',
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
    _emit(StreamStopped(error));
  }

  void _setState(EventConnectionState state) {
    if (_state == state) return;
    _state = state;
    _emit(ConnectionChanged(state));
  }

  void _emit(EventStreamSignal signal) {
    if (!_signals.isClosed) _signals.add(signal);
  }
}
