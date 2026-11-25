import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pirc_client/pirc_client.dart';

import '../../connection/connection.dart';
import '../../connection/data.dart';
import '../../connection/hints.dart';
import '../session_controller.dart';

/// Waits between reads of an open transition: 1, 2, 4, 8, 15, 30 s.
final transitionBackoffProvider = Provider<List<Duration>>(
  (ref) => const [1, 2, 4, 8, 15, 30].map((s) => Duration(seconds: s)).toList(),
);

/// Where a transition is, as the banner shows it.
enum TransitionStep {
  stopping,
  confirmingRevocation,
  needsAcknowledgement,
  preparingTarget,
  needsAuthority,
  uncertain,
  switched,
  cancelled,
}

@immutable
class EnvironmentState {
  const EnvironmentState({
    this.environment,
    this.status,
    this.error,
    this.busy = false,
  });

  /// `GET …/environment`.
  final Map<String, Object?>? environment;

  /// The open (or just finished) transition's status read model.
  final Map<String, Object?>? status;
  final String? error;
  final bool busy;

  Map<String, Object?>? get active =>
      (environment?['activeTransition'] as Map?)?.cast<String, Object?>();

  String? get operationId =>
      (status?['transition'] as Map?)?['operationId'] as String? ??
      active?['operationId'] as String?;

  /// Commands wait while a transition is open (the draft is kept).
  bool get transitioning {
    final step = this.step;
    return active != null &&
        step != TransitionStep.switched &&
        step != TransitionStep.cancelled;
  }

  Map<String, Object?>? get _progress =>
      (status?['progress'] as Map?)?.cast<String, Object?>();

  /// The source host is offline: nothing starts on the target before it
  /// confirms.
  bool get sourceOffline =>
      status?['reconciliationState'] == 'node_unavailable' ||
      _progress?['waitReason'] == 'node_unavailable' ||
      active?['state'] == 'reconciliation_required';

  Map<String, Object?>? get revocation =>
      (_progress?['revocation'] as Map?)?.cast<String, Object?>();

  TransitionStep? get step {
    final state = (status?['transition'] as Map?)?['state'] ?? active?['state'];
    if (state == null) return null;
    if (state == 'installed') return TransitionStep.switched;
    if (state == 'released' || state == 'deleted') {
      return TransitionStep.cancelled;
    }
    final authority = status?['authority'] as Map?;
    if (authority?['reauthorizationRequired'] == true) {
      return TransitionStep.needsAuthority;
    }
    if (state == 'outcome_unknown' ||
        _progress?['stage'] == 'outcome_unknown') {
      return TransitionStep.uncertain;
    }
    return switch ((_progress?['state'], revocation?['status'])) {
      (_, 'unproven' || 'blocked') => TransitionStep.needsAcknowledgement,
      (_, 'pending') => TransitionStep.confirmingRevocation,
      ('supervisor_drained', _) ||
      (_, 'confirmed') => TransitionStep.preparingTarget,
      _ => TransitionStep.stopping,
    };
  }

  EnvironmentState copyWith({
    Map<String, Object?>? environment,
    Map<String, Object?>? status,
    String? error,
    bool clearError = false,
    bool? busy,
  }) => EnvironmentState(
    environment: environment ?? this.environment,
    status: status ?? this.status,
    error: clearError ? null : error ?? this.error,
    busy: busy ?? this.busy,
  );
}

final environmentProvider = NotifierProvider.autoDispose
    .family<EnvironmentController, EnvironmentState, String>(
      EnvironmentController.new,
    );

/// Reads the environment and follows an open transition: the controlling
/// device advances it, other devices read its receipt. Read again on
/// `sessions_changed` (how the Gateway announces transition changes).
class EnvironmentController extends Notifier<EnvironmentState> {
  EnvironmentController(this.sessionId);
  final String sessionId;

  Timer? _timer;
  int _attempt = 0;
  bool _disposed = false;

  EnvironmentApi? get _api {
    final api = ref.read(apiProvider);
    return api == null ? null : EnvironmentApi(api, sessionId);
  }

  ControlLease? get _lease =>
      ref.read(sessionControllerProvider(sessionId).notifier).heldLease;

  @override
  EnvironmentState build() {
    _disposed = false;
    watchHint(ref, 'sessions_changed');
    ref.onDispose(() {
      _disposed = true;
      _timer?.cancel();
    });
    scheduleMicrotask(load);
    return stateOrNull ?? const EnvironmentState();
  }

  Future<void> load() async {
    final api = _api;
    if (api == null || _disposed) return;
    try {
      final environment = await api.environment();
      if (_disposed) return;
      state = state.copyWith(environment: environment, clearError: true);
      if (state.active != null) {
        _attempt = 0;
        await _follow();
      }
    } on PircException catch (error) {
      if (_disposed) return;
      if (!ref.read(connectionProvider.notifier).report(error)) {
        state = state.copyWith(error: error.message);
      }
    }
  }

  Future<void> _follow() async {
    final api = _api;
    final operation = state.operationId;
    if (api == null || operation == null || _disposed) return;
    _timer?.cancel();
    try {
      final lease = _lease;
      final status = lease != null
          ? await api.advance(operation, lease)
          : await api.receipt(operation);
      if (_disposed) return;
      // A write's error stays until the next write.
      state = state.copyWith(status: status);
    } on PircException catch (error) {
      if (_disposed) return;
      state = state.copyWith(
        error: error is ApiError ? error.code : error.message,
      );
    }
    final step = state.step;
    if (step == TransitionStep.switched || step == TransitionStep.cancelled) {
      // The binding changed (or did not): read it and the snapshot again.
      unawaited(
        ref.read(sessionControllerProvider(sessionId).notifier).reload(),
      );
      final environment = await api.environment();
      if (!_disposed) state = state.copyWith(environment: environment);
      return;
    }
    final waits = ref.read(transitionBackoffProvider);
    _timer = Timer(waits[_attempt.clamp(0, waits.length - 1)], () {
      _attempt++;
      unawaited(_follow());
    });
  }

  /// Runs a transition write; returns whether it succeeded.
  Future<bool> _write(
    Future<Map<String, Object?>> Function(
      EnvironmentApi api,
      ControlLease lease,
    )
    action,
  ) async {
    final api = _api;
    final lease = _lease;
    if (api == null || lease == null) return false;
    state = state.copyWith(busy: true, clearError: true);
    try {
      final status = await action(api, lease);
      if (_disposed) return false;
      state = state.copyWith(status: status, busy: false);
      return true;
    } on LostControl {
      ref.read(sessionControllerProvider(sessionId).notifier).lostControl();
      state = state.copyWith(busy: false, error: 'lost_control');
    } on PircException catch (error) {
      state = state.copyWith(
        busy: false,
        error: error is ApiError ? error.code : error.message,
      );
    }
    return false;
  }

  /// Confirms a preview; the transition starts.
  Future<bool> confirm(Map<String, Object?> preview) async {
    final operation = (preview['preview'] as Map?)?['operationId'] as String?;
    final planHash = (preview['preview'] as Map?)?['planHash'] as String?;
    if (operation == null || planHash == null) return false;
    final ok = await _write(
      (api, lease) => api.confirm(
        operation,
        planHash: planHash,
        observationHash:
            (preview['resourcePreflight'] as Map?)?['observationHash']
                as String?,
        lease: lease,
      ),
    );
    if (ok) await load();
    return ok;
  }

  Future<void> acknowledge() async {
    final revocation = state.revocation;
    final operation = state.operationId;
    if (revocation == null || operation == null) return;
    await _write(
      (api, lease) => api.acknowledge(
        operation,
        digest: '${revocation['digest']}',
        evaluationId: revocation['evaluationId'] as String?,
        lease: lease,
      ),
    );
    _attempt = 0;
    await _follow();
  }

  Future<void> cancel() async {
    final operation = state.operationId;
    if (operation == null) return;
    await _write((api, lease) => api.cancel(operation, lease));
    _attempt = 0;
    await _follow();
  }

  /// Renews the operation's authority; `plan_changed` means a new preview
  /// is needed.
  Future<void> reauthorize() async {
    final operation = state.operationId;
    if (operation == null) return;
    await _write((api, lease) => api.reauthorize(operation, lease));
  }

  /// Grants a folder (`read`, `write` or `deny`).
  Future<void> addGrant(String path, String access) async {
    final api = _api;
    final lease = _lease;
    if (api == null || lease == null) return;
    try {
      await api.addGrant(path, access, lease);
    } on PircException catch (error) {
      state = state.copyWith(
        error: error is ApiError ? error.code : error.message,
      );
    }
  }

  Future<void> revokeGrant(String grantId) async {
    final api = _api;
    final lease = _lease;
    if (api == null || lease == null) return;
    try {
      await api.revokeGrant(grantId, lease);
    } on PircException catch (error) {
      state = state.copyWith(
        error: error is ApiError ? error.code : error.message,
      );
    }
  }
}
