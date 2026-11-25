import 'dart:async';

import '../api_client.dart';
import '../errors.dart';
import '../models/control_lease.dart';

/// The control lease routes `/api/sessions/{id}/control[/…]`.
class ControlLeaseClient {
  ControlLeaseClient(this.api);

  final ApiClient api;

  static String _path(String sessionId, [String action = '']) =>
      '/api/sessions/${Uri.encodeComponent(sessionId)}/control'
      '${action.isEmpty ? '' : '/$action'}';

  /// Who holds control now; null when nobody does.
  Future<ControlLease?> read(String sessionId) async =>
      ControlLease.fromReply(await api.get(_path(sessionId)));

  /// Takes control for [clientId]. [force] takes it from another client.
  /// [clientName] names a browser; the Gateway keeps it (1 to 60 characters).
  Future<ControlLease> acquire(
    String sessionId, {
    required String clientId,
    int? generation,
    bool force = false,
    String? clientName,
  }) async => _lease(
    await api.post(_path(sessionId, 'acquire'), {
      'clientId': clientId,
      'generation': ?generation,
      if (force) 'force': true,
      'clientName': ?clientName,
    }),
  );

  /// Extends [lease]; throws [LostControl] when another client took over.
  Future<ControlLease> heartbeat(
    String sessionId,
    ControlLease lease, {
    String? clientName,
  }) async => _lease(
    await api.post(_path(sessionId, 'heartbeat'), {
      'clientId': lease.clientId,
      'generation': lease.generation,
      'clientName': ?clientName,
    }),
    fallback: lease,
  );

  Future<void> release(String sessionId, ControlLease lease) => api.post(
    _path(sessionId, 'release'),
    {'clientId': lease.clientId, 'generation': lease.generation},
  );

  static ControlLease _lease(Object? reply, {ControlLease? fallback}) {
    final lease = ControlLease.fromReply(reply) ?? fallback;
    if (lease == null) {
      throw const ApiError(502, 'invalid_lease', 'No lease in the reply');
    }
    return lease;
  }
}

/// Keeps a held lease alive: every 10 s while the app is visible, every 15 s
/// while hidden (the lease lives 30 s). Stops on [LostControl].
class LeaseHeartbeat {
  LeaseHeartbeat(
    this.client,
    this.sessionId,
    this._lease, {
    this._visible = true,
    this.onLost,
    this.clientName,
  });

  static const visibleInterval = Duration(seconds: 10);
  static const hiddenInterval = Duration(seconds: 15);

  final ControlLeaseClient client;
  final String sessionId;

  /// Called once when another client took control.
  final void Function(LostControl error)? onLost;

  /// The browser name sent with each heartbeat; set it after a rename.
  String? clientName;

  ControlLease _lease;
  bool _visible;
  Timer? _timer;
  bool _beating = false;

  ControlLease get lease => _lease;
  bool get running => _timer != null;
  Duration get interval => _visible ? visibleInterval : hiddenInterval;

  void start() {
    _timer?.cancel();
    _timer = Timer.periodic(interval, (_) => unawaited(_beat()));
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  /// App visibility changed: restart the schedule at the new interval.
  set visible(bool value) {
    if (value == _visible) return;
    _visible = value;
    if (running) start();
  }

  Future<void> _beat() async {
    if (_beating) return;
    _beating = true;
    try {
      _lease = await client.heartbeat(
        sessionId,
        _lease,
        clientName: clientName,
      );
    } on LostControl catch (error) {
      stop();
      onLost?.call(error);
    } catch (_) {
      // Transient; the next beat retries within the lease's 30 s.
    } finally {
      _beating = false;
    }
  }
}
