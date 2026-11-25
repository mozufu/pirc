import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pirc_client/pirc_client.dart';

import '../connection/connection.dart';
import '../connection/storage.dart';

/// This app install's control-lease client ID, kept in app storage.
final clientIdProvider = Provider<String>((ref) {
  final prefs = ref.read(sharedPreferencesProvider);
  final saved = prefs.getString(PrefKeys.clientId);
  if (saved != null && saved.isNotEmpty) return saved;
  final id = randomId();
  prefs.setString(PrefKeys.clientId, id);
  return id;
});

/// Who controls the session, as this device sees it.
enum ControlState {
  /// Not known yet (the lease is being read or taken).
  unknown,

  /// This device holds the lease: it may send.
  mine,

  /// Another client holds it: the composer is read-only.
  other,
}

@immutable
class SessionView {
  const SessionView({
    this.state,
    this.error,
    this.control = ControlState.unknown,
    this.lease,
    this.events = EventConnectionState.idle,
    this.partialOutputLost = false,
    this.deleted = false,
    this.panels = const {},
  });

  /// The timeline; null until the first snapshot.
  final SessionState? state;

  /// The first snapshot failed.
  final Object? error;
  final ControlState control;
  final ControlLease? lease;
  final EventConnectionState events;
  final bool partialOutputLost;

  /// The session was deleted elsewhere.
  final bool deleted;

  /// A counter per panel section (`memory`, `git`, `checkpoints`, …) that
  /// moves on each `panel_changed` naming it: open panels read again.
  final Map<String, int> panels;

  SessionView copyWith({
    SessionState? state,
    Object? error,
    ControlState? control,
    ControlLease? lease,
    bool clearLease = false,
    EventConnectionState? events,
    bool? partialOutputLost,
    bool? deleted,
    Map<String, int>? panels,
  }) => SessionView(
    state: state ?? this.state,
    error: error,
    control: control ?? this.control,
    lease: clearLease ? null : lease ?? this.lease,
    events: events ?? this.events,
    partialOutputLost: partialOutputLost ?? this.partialOutputLost,
    deleted: deleted ?? this.deleted,
    panels: panels ?? this.panels,
  );
}

final sessionControllerProvider = NotifierProvider.autoDispose
    .family<SessionController, SessionView, String>(SessionController.new);

/// One open session: snapshot, `SessionEventStream`, `reduceEvent`, a new
/// snapshot on `SnapshotNeeded`, and the control lease kept alive by
/// `LeaseHeartbeat` while the session is open (slower while the app is
/// hidden).
class SessionController extends Notifier<SessionView> {
  SessionController(this.sessionId);

  final String sessionId;

  Connection? _connection;
  SessionEventStream? _stream;
  StreamSubscription<EventStreamSignal>? _signals;
  LeaseHeartbeat? _heartbeat;
  AppLifecycleListener? _lifecycle;
  bool _reloading = false;
  bool _disposed = false;

  ApiClient get _api => _connection!.api;
  ControlLeaseClient get _leases => ControlLeaseClient(_api);
  String get _clientId => ref.read(clientIdProvider);

  @override
  SessionView build() {
    _connection = ref.watch(
      connectionProvider.select((status) => status.connection),
    );
    _disposed = false;
    ref.onDispose(_close);
    if (_connection != null) scheduleMicrotask(_open);
    return const SessionView();
  }

  Future<void> _open() async {
    if (_disposed) return;
    final snapshot = await _snapshot();
    if (snapshot == null || _disposed) return;
    final stream = SessionEventStream(
      transport: _connection!.transport,
      sessionId: sessionId,
      cursor: snapshot.watermark,
    );
    _stream = stream;
    _signals = stream.signals.listen(_onSignal);
    stream.start();
    _lifecycle = AppLifecycleListener(
      onStateChange: (state) =>
          _heartbeat?.visible = state == AppLifecycleState.resumed,
    );
    await _takeControlIfFree();
  }

  /// Reads a snapshot into the state; null when it failed.
  Future<SessionSnapshot?> _snapshot() async {
    try {
      final raw = await _api.get(
        '/api/sessions/${Uri.encodeComponent(sessionId)}/snapshot',
      );
      if (_disposed) return null;
      final snapshot = SessionSnapshot.fromJson(raw);
      state = state.copyWith(
        state: snapshotState(raw),
        partialOutputLost: snapshot.partialOutputLost,
      );
      return snapshot;
    } on PircException catch (error) {
      if (_disposed) return null;
      if (ref.read(connectionProvider.notifier).report(error)) return null;
      if (error is ApiError && error.status == 404) {
        state = state.copyWith(deleted: true);
      } else if (state.state == null) {
        state = state.copyWith(error: error);
      }
      return null;
    }
  }

  /// Loads a new snapshot and continues the stream from its watermark.
  Future<void> reload() async {
    if (_reloading || _disposed) return;
    _reloading = true;
    try {
      final snapshot = await _snapshot();
      if (snapshot != null) _stream?.resumeFrom(snapshot.watermark);
    } finally {
      _reloading = false;
    }
  }

  void _onSignal(EventStreamSignal signal) {
    switch (signal) {
      case EventReceived(:final event):
        final current = state.state;
        if (current == null) return;
        final envelope = normalizeEvent(event.raw);
        switch (envelope.event) {
          case SessionDeleted():
            state = state.copyWith(deleted: true);
            return;
          case PanelChanged(:final sections):
            _bumpPanels(sections);
          case CheckpointsChanged():
            _bumpPanels(const ['checkpoints']);
          default:
            break;
        }
        final next = reduceEvent(current, envelope);
        state = state.copyWith(state: next);
        if (next.needsSnapshot) unawaited(reload());
      case SnapshotNeeded():
        unawaited(reload());
      case ConnectionChanged(state: final events):
        state = state.copyWith(events: events);
        // After a reconnect the lease may have moved on.
        if (events == EventConnectionState.connected &&
            state.control != ControlState.unknown) {
          unawaited(readControl());
        }
      case HintReceived():
        break;
      case StreamStopped(:final error):
        ref.read(connectionProvider.notifier).report(error);
    }
  }

  void _bumpPanels(List<String> sections) => state = state.copyWith(
    panels: {
      ...state.panels,
      for (final section in sections) section: (state.panels[section] ?? 0) + 1,
    },
  );

  Future<void> _takeControlIfFree() async {
    try {
      final lease = await _leases.read(sessionId);
      if (_disposed) return;
      if (lease == null || lease.expired || lease.clientId == _clientId) {
        await takeControl(
          generation: lease?.clientId == _clientId ? lease?.generation : null,
        );
      } else {
        state = state.copyWith(control: ControlState.other, lease: lease);
      }
    } on PircException catch (error) {
      if (!_disposed && error is LostControl) await readControl();
    }
  }

  /// Takes the lease; [force] takes it from another client ("Take control").
  Future<void> takeControl({bool force = false, int? generation}) async {
    try {
      final lease = await _leases.acquire(
        sessionId,
        clientId: _clientId,
        generation: generation,
        force: force,
      );
      if (_disposed) return;
      _heartbeat?.stop();
      _heartbeat = LeaseHeartbeat(
        _leases,
        sessionId,
        lease,
        visible:
            WidgetsBinding.instance.lifecycleState == null ||
            WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed,
        onLost: (_) => unawaited(readControl()),
      )..start();
      state = state.copyWith(control: ControlState.mine, lease: lease);
    } on LostControl {
      if (!_disposed) await readControl(retake: false);
    } on ApiError catch (error) {
      if (!_disposed && error.status == 409) await readControl(retake: false);
    }
  }

  /// Reads who holds the lease now (after losing it); takes a free lease
  /// unless [retake] is false.
  Future<void> readControl({bool retake = true}) async {
    try {
      final lease = await _leases.read(sessionId);
      if (_disposed) return;
      final mine =
          lease != null && !lease.expired && lease.clientId == _clientId;
      if (!mine) _heartbeat?.stop();
      state = state.copyWith(
        control: mine
            ? ControlState.mine
            : lease == null || lease.expired
            ? ControlState.unknown
            : ControlState.other,
        lease: lease,
        clearLease: lease == null,
      );
      if (retake && (lease == null || lease.expired)) await takeControl();
    } on PircException {
      // Leave the state as it is; the next action reads it again.
    }
  }

  /// The held lease for commands; null when this device does not control.
  ControlLease? get heldLease =>
      state.control == ControlState.mine ? _heartbeat?.lease : null;

  /// A command found that another client took control.
  void lostControl() {
    _heartbeat?.stop();
    unawaited(readControl());
  }

  void _close() {
    _disposed = true;
    _lifecycle?.dispose();
    unawaited(_signals?.cancel());
    unawaited(_stream?.close());
    final heartbeat = _heartbeat;
    heartbeat?.stop();
    final connection = _connection;
    if (heartbeat != null && connection != null) {
      ControlLeaseClient(
        connection.api,
      ).release(sessionId, heartbeat.lease).ignore();
    }
  }
}
