import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pirc_client/pirc_client.dart';

import '../connection/connection.dart';
import '../connection/storage.dart';
import '../format.dart';
import 'client_names.dart';

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

  /// Another client holds it: this device takes control when it sends, and
  /// explicit-control actions stay disabled.
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
    this.continuedOn,
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

  /// The name from the last `control_changed` that gave another client
  /// control; cleared when control comes back here.
  final String? continuedOn;

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
    String? continuedOn,
    bool clearContinuedOn = false,
  }) => SessionView(
    state: state ?? this.state,
    error: error,
    control: control ?? this.control,
    lease: clearLease ? null : lease ?? this.lease,
    events: events ?? this.events,
    partialOutputLost: partialOutputLost ?? this.partialOutputLost,
    deleted: deleted ?? this.deleted,
    panels: panels ?? this.panels,
    continuedOn: clearContinuedOn ? null : continuedOn ?? this.continuedOn,
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

  /// Names this browser where it holds control; a paired app is named by its
  /// device record instead.
  String? get _clientName =>
      ref.read(isWebProvider) ? ref.read(webClientNameProvider) : null;

  @override
  SessionView build() {
    _connection = ref.watch(
      connectionProvider.select((status) => status.connection),
    );
    _disposed = false;
    ref.listen(
      webClientNameProvider,
      (_, name) => _heartbeat?.clientName = name,
    );
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

  /// Loads a new snapshot and continues the stream from its watermark; opens
  /// the session when its first snapshot had failed.
  Future<void> reload() async {
    if (_reloading || _disposed) return;
    if (_stream == null) {
      _reloading = true;
      try {
        await _open();
      } finally {
        _reloading = false;
      }
      return;
    }
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
        if (event.type == 'control_changed') {
          _applyControlEvent(event.data);
          return;
        }
        if (event.type == 'interaction_answered') {
          _applyInteractionAnswered(event.data);
          return;
        }
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

  /// `control_changed` names the new holder, or nobody on release. Another
  /// client taking over leaves a notice and keeps the composer usable.
  void _applyControlEvent(Object? data) {
    final raw = data is Map ? data : const {};
    final clientId = raw['clientId'];
    if (clientId == null) {
      _heartbeat?.stop();
      state = state.copyWith(
        control: ControlState.unknown,
        clearLease: true,
        clearContinuedOn: true,
      );
      return;
    }
    if (clientId is! String || clientId.isEmpty) return;
    final holder = raw['holder'] is Map
        ? ControlHolder.fromJson(raw['holder'])
        : null;
    final mine = clientId == _clientId;
    if (!mine) _heartbeat?.stop();
    final current = state.lease;
    final lease = mine && current != null && current.clientId == clientId
        ? current.copyWith(holder: holder)
        : ControlLease(clientId: clientId, generation: 0, holder: holder);
    final notice = mine || (holder?.name.isEmpty ?? true) ? null : holder!.name;
    state = state.copyWith(
      control: mine ? ControlState.mine : ControlState.other,
      lease: lease,
      continuedOn: notice,
      clearContinuedOn: notice == null,
    );
    if (!mine && notice == null) _resolveHolder(lease, forNotice: true);
  }

  /// `interaction_answered` carries the real end: status, answering client
  /// and time. Apply it to the open question at once; an event for a question
  /// this snapshot does not know asks for a fresh one.
  void _applyInteractionAnswered(Object? data) {
    final raw = data is Map ? data : const {};
    final id = raw['interactionId'];
    final current = state.state;
    if (id is! String || id.isEmpty || current == null) return;
    final reported = raw['status'];
    if (reported is! String && raw['cancelled'] != true) {
      // An older event without an end status: only a snapshot can say, and a
      // question that disappeared gets the neutral fallback.
      unawaited(reload());
      return;
    }
    final status = reported is String ? reported : 'cancelled';
    final answeredBy = raw['answeredBy'] is String
        ? raw['answeredBy'] as String
        : null;
    final resolvedAt = raw['resolvedAt'] is num
        ? (raw['resolvedAt'] as num).toInt()
        : null;
    var found = false;
    final interactions = [
      for (final interaction in current.interactions)
        if (interaction.id == id)
          () {
            found = true;
            return interaction.copyWith(
              status: status,
              statusKnown: true,
              answeredBy: answeredBy,
              resolvedAt: resolvedAt,
            );
          }()
        else
          interaction,
    ];
    if (!found) {
      unawaited(reload());
      return;
    }
    state = state.copyWith(state: current.copyWith(interactions: interactions));
  }

  /// Reads the name of a holder this Gateway did not name itself.
  void _resolveHolder(ControlLease? lease, {bool forNotice = false}) {
    if (lease == null ||
        (lease.holder?.name.isNotEmpty ?? false) ||
        lease.expired ||
        lease.clientId == _clientId) {
      return;
    }
    final clientId = lease.clientId;
    unawaited(
      ref.read(clientNamesProvider.notifier).resolve(clientId).then((client) {
        if (_disposed || client == null) return;
        final current = state.lease;
        if (current == null || current.clientId != clientId) return;
        final holder = ControlHolder(
          name: client.name,
          kind: client.kind,
          lastActionAt: current.holder?.lastActionAt,
        );
        state = state.copyWith(
          lease: current.copyWith(holder: holder),
          continuedOn: forNotice && state.control == ControlState.other
              ? client.name
              : null,
        );
      }),
    );
  }

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
        _resolveHolder(lease);
      }
    } on PircException catch (error) {
      if (!_disposed && error is LostControl) await readControl();
    }
  }

  /// Takes the lease; [force] takes it from another client. Returns the held
  /// lease, or null when it could not be taken.
  Future<ControlLease?> takeControl({
    bool force = false,
    int? generation,
  }) async {
    try {
      final lease = await _leases.acquire(
        sessionId,
        clientId: _clientId,
        generation: generation,
        force: force,
        clientName: _clientName,
      );
      if (_disposed) return null;
      _heartbeat?.stop();
      _heartbeat = LeaseHeartbeat(
        _leases,
        sessionId,
        lease,
        visible:
            WidgetsBinding.instance.lifecycleState == null ||
            WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed,
        onLost: (_) => unawaited(readControl()),
        clientName: _clientName,
      )..start();
      state = state.copyWith(
        control: ControlState.mine,
        lease: lease,
        clearContinuedOn: true,
      );
      return lease;
    } on LostControl {
      if (!_disposed) await readControl(retake: false);
    } on ApiError catch (error) {
      if (!_disposed && error.status == 409) await readControl(retake: false);
    }
    return null;
  }

  /// The lease a send needs. Without control it reads who holds it: another
  /// client that acted within 30 seconds asks [confirm] first; then control
  /// is taken with `force` and the send goes on.
  Future<ControlLease?> leaseForSend({
    Future<bool> Function(String name)? confirm,
  }) async {
    final held = heldLease;
    if (held != null) return held;
    try {
      final lease = await _leases.read(sessionId);
      if (_disposed) return null;
      final other =
          lease != null && !lease.expired && lease.clientId != _clientId;
      if (other) {
        var holder = lease.holder;
        if (holder == null || holder.name.isEmpty) {
          final client = await ref
              .read(clientNamesProvider.notifier)
              .resolve(lease.clientId);
          if (client != null) {
            holder = ControlHolder(
              name: client.name,
              kind: client.kind,
              lastActionAt: holder?.lastActionAt,
            );
          }
        }
        state = state.copyWith(
          control: ControlState.other,
          lease: lease.copyWith(holder: holder),
        );
        final last = holder?.lastActionAt;
        final recent =
            last != null &&
            ref.read(clockProvider)().millisecondsSinceEpoch - last <
                const Duration(seconds: 30).inMilliseconds;
        if (recent) {
          final name = holder?.name ?? '';
          if (confirm == null || !await confirm(name)) return null;
        }
        if (_disposed) return null;
        return await takeControl(force: true);
      }
      return await takeControl(
        generation: lease?.clientId == _clientId ? lease?.generation : null,
      );
    } on PircException {
      return null;
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
        clearContinuedOn: mine,
      );
      _resolveHolder(lease);
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

  // `build` runs again on the same notifier when the connection changes, so
  // what was closed is cleared: a later close must not touch it again.
  void _close() {
    _disposed = true;
    _lifecycle?.dispose();
    _lifecycle = null;
    unawaited(_signals?.cancel());
    _signals = null;
    unawaited(_stream?.close());
    _stream = null;
    final heartbeat = _heartbeat;
    _heartbeat = null;
    heartbeat?.stop();
    final connection = _connection;
    if (heartbeat != null && connection != null) {
      ControlLeaseClient(
        connection.api,
      ).release(sessionId, heartbeat.lease).ignore();
    }
  }
}
