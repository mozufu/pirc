/// Client side of conversation environment switching
/// (`plans/transition-installation.md`, T3a/T3b): preview, confirm, progress,
/// acknowledgement of unproven revocation, cancel and the final result.
///
/// UI-independent. Every mutation keeps one identity (the operation ID chosen
/// for the user's review) and is never repeated with a new one. Ambiguous
/// replies (5xx, connection loss) are resolved by reading the status or by
/// `advance`, which only joins the same Node step. Nothing is persisted: after
/// a restart [EnvironmentTransitionFlow.load] rediscovers the operation from
/// `activeTransition`, so the private envelope stays at version 3.
library;

import 'dart:async';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import '../l10n/app_i18n.dart';
import 'gateway.dart';

int? _int(dynamic value) => value is num ? value.toInt() : null;
String? _text(dynamic value) => value is String ? value : null;

/// The Gateway error code of a failed call, if any.
String? transitionErrorCode(Object error) =>
    error is PlatformException ? _text(obj(error.details)['code']) : null;

int? _status(Object error) => error is PlatformException
    ? _int(obj(error.details)['status']) ??
          int.tryParse(error.code.replaceFirst('HTTP_', ''))
    : null;

/// 5xx (including `transition_step_failed` and `invalid_transition_receipt`),
/// a lost connection or a cancelled call: the outcome is unknown and is
/// resolved by a read, never by repeating the mutation with a new identity.
bool transitionOutcomeAmbiguous(Object error) {
  final status = _status(error);
  return status == null || status < 400 || status >= 500;
}

/// Gateway switching is off by default: both codes mean "disabled here".
const transitionDisabledCodes = {
  'coordinator_not_available',
  'transition_coordinator_unavailable',
};

/// A fresh operation ID per user review (`[A-Za-z0-9_-]{1,100}`).
String newTransitionOperationId([Random? random]) {
  final r = random ?? Random.secure();
  return 'switch-${List.generate(16, (_) => r.nextInt(256).toRadixString(16).padLeft(2, '0')).join()}';
}

@immutable
class TransitionLease {
  const TransitionLease(this.clientId, this.generation);
  final String clientId;
  final Object generation;
  Json get body => {'clientId': clientId, 'generation': generation};
}

/// `GET /api/sessions/{id}/environment`.
class ConversationEnvironment {
  ConversationEnvironment(this.raw);
  final Json raw;
  Json? get binding => raw['binding'] is Map ? obj(raw['binding']) : null;
  String? get workspaceId => _text(obj(binding?['execution'])['workspaceId']);

  /// An accepted or fenced transition, discoverable from any device.
  Json? get activeTransition =>
      raw['activeTransition'] is Map ? obj(raw['activeTransition']) : null;
  String? get activeOperationId => _text(activeTransition?['operationId']);
}

class TransitionPreview {
  TransitionPreview(this.raw);
  final Json raw;
  Json get _preview => obj(raw['preview']);
  String get operationId => '${_preview['operationId'] ?? ''}';
  String get targetWorkspaceId => '${_preview['targetWorkspaceId'] ?? ''}';
  String? get planHash => _text(_preview['planHash']);
  String? get observationHash =>
      _text(obj(raw['resourcePreflight'])['observationHash']);
  String get preflightStatus =>
      '${obj(raw['resourcePreflight'])['status'] ?? ''}';
  bool get stale => raw['state'] == 'stale';
  bool get canConfirm =>
      raw['canConfirm'] == true &&
      !stale &&
      planHash != null &&
      observationHash != null;
  List<String> get blockedBy => [
    for (final reason in (raw['blockedBy'] as List? ?? const [])) '$reason',
  ];
  bool get disabled => blockedBy.any(transitionDisabledCodes.contains);
  List<Json> get nodeObservations => rows(raw['nodeObservations']);
}

/// One sanitized revocation item: `{kind, reason, acknowledgeable}`.
class RevocationItem {
  RevocationItem(this.raw);
  final Json raw;
  String get kind => '${raw['kind'] ?? ''}';
  String get reason => '${raw['reason'] ?? ''}';
  bool get acknowledgeable => raw['acknowledgeable'] == true;
}

class TransitionRevocation {
  TransitionRevocation(this.raw);
  final Json raw;

  /// `pending`, `blocked`, `unproven` or `confirmed`.
  String get status => '${raw['status'] ?? ''}';

  /// Kept internally: an acknowledgement binds to exactly this digest.
  String? get digest => _text(raw['digest']);
  int get itemsTotal => _int(raw['itemsTotal']) ?? items.length;
  bool get confirmsContainment => raw['confirmsContainment'] == true;
  List<RevocationItem> get items => [
    for (final item in rows(raw['items'])) RevocationItem(item),
  ];
}

/// An accepted transition's status: `transition`, sanitized `progress` and an
/// optional `reconciliationState`.
class TransitionStatus {
  TransitionStatus(this.raw);
  final Json raw;
  Json get transition => obj(raw['transition']);
  String get operationId => '${transition['operationId'] ?? ''}';

  /// `accepted`, `outcome_unknown`, `node_fenced`, `installed`, `released`
  /// or `deleted`.
  String get state => '${transition['state'] ?? ''}';
  bool get revocationConfirmed => transition['revocationConfirmed'] == true;
  bool get targetInstalled => transition['targetInstalled'] == true;
  Json? get progress => raw['progress'] is Map ? obj(raw['progress']) : null;

  /// The Node fence state from the latest receipt.
  String? get fenceState => _text(progress?['state']);
  TransitionRevocation? get revocation => progress?['revocation'] is Map
      ? TransitionRevocation(obj(progress!['revocation']))
      : null;

  /// `node_unavailable`, `connection_changed`, `receipt_unavailable`, …
  String? get reconciliationState => _text(raw['reconciliationState']);

  /// `progress` comes only from coordinator replies (confirm, advance,
  /// acknowledge, cancel, reconcile); the plain receipt GET omits it.
  bool get hasProgress => raw.containsKey('progress');
}

/// The HTTP calls of the switching contract, through the direct Gateway link.
class EnvironmentTransitionApi {
  const EnvironmentTransitionApi(this.gateway);
  final Gateway gateway;
  String _base(String session) =>
      '${sessionPath(session)}/environment-transitions';

  Future<ConversationEnvironment> environment(String session) async =>
      ConversationEnvironment(
        await gateway.request('${sessionPath(session)}/environment'),
      );

  Future<TransitionPreview> preview(
    String session, {
    required String operationId,
    required String targetWorkspaceId,
    required Json expectedBinding,
  }) async => TransitionPreview(
    await gateway.request(
      '${_base(session)}/previews',
      method: 'POST',
      body: {
        'operationId': operationId,
        'targetWorkspaceId': targetWorkspaceId,
        'expectedBinding': expectedBinding,
      },
    ),
  );

  Future<TransitionPreview> readPreview(String session, String op) async =>
      TransitionPreview(
        await gateway.request('${_base(session)}/previews/${enc(op)}'),
      );

  Future<TransitionStatus> confirm(
    String session,
    String op, {
    required String planHash,
    required String observationHash,
    required TransitionLease lease,
  }) async => TransitionStatus(
    await gateway.request(
      '${_base(session)}/previews/${enc(op)}/confirm',
      method: 'POST',
      body: {
        'planHash': planHash,
        'observationHash': observationHash,
        ...lease.body,
      },
    ),
  );

  /// The accepted transition without `progress`; `404` before acceptance.
  Future<TransitionStatus> status(String session, String op) async =>
      TransitionStatus(
        await gateway.request('${_base(session)}/receipts/${enc(op)}'),
      );

  /// Drive the same Node step again: drain, then install when revocation is
  /// confirmed or already acknowledged. Idempotent per operation.
  Future<TransitionStatus> advance(
    String session,
    String op,
    TransitionLease lease,
  ) async => TransitionStatus(
    await gateway.request(
      '${_base(session)}/${enc(op)}/advance',
      method: 'POST',
      body: lease.body,
    ),
  );

  Future<TransitionStatus> acknowledge(
    String session,
    String op, {
    required String digest,
    required TransitionLease lease,
  }) async => TransitionStatus(
    await gateway.request(
      '${_base(session)}/${enc(op)}/acknowledge',
      method: 'POST',
      body: {'digest': digest, ...lease.body},
    ),
  );

  Future<TransitionStatus> cancel(
    String session,
    String op,
    TransitionLease lease,
  ) async => TransitionStatus(
    await gateway.request(
      '${_base(session)}/${enc(op)}/cancel',
      method: 'POST',
      body: lease.body,
    ),
  );
}

/// One client status per contract state.
enum EnvironmentSwitchStatus {
  /// No operation yet.
  idle,

  /// Switching is off on this Gateway (`coordinator_not_available` /
  /// `transition_coordinator_unavailable`).
  disabled,

  /// A request is in flight.
  working,

  /// The outcome of the last call is unknown; resolved by reading.
  ambiguous,

  /// The preview POST may not have been saved; the same ID may be sent again.
  previewNotSaved,

  /// Preview with `blockedBy` reasons; Confirm is not offered.
  previewBlocked,

  /// Stale preview, `transition_review_changed` or `stale_environment`.
  reviewStale,

  /// `canConfirm` is true.
  readyToConfirm,

  /// `transition.state: accepted` (no Node request yet).
  accepted,

  /// `transition.state: outcome_unknown`.
  outcomeUnknown,

  /// `node_fenced` with no progress, a pending revocation or a running drain.
  draining,

  /// Revocation `blocked`: shows the items, offers no acknowledgement.
  revocationBlocked,

  /// Revocation `unproven`: shows the items and offers Acknowledge and switch.
  unproven,

  /// Revocation `confirmed` (or acknowledged) and installation is next.
  installing,
  installedConfirmed,
  installedUnconfirmed,
  released,
  deleted,

  /// A definite refusal; [EnvironmentTransitionFlow.errorCode] says why.
  failed,
  unrecognized,
}

enum EnvironmentSwitchAction {
  /// Start a new review (a new operation ID).
  preview,

  /// Re-read the current preview, or re-send its same ID after a lost reply.
  refreshPreview,
  confirm,

  /// Read the status (`advance` with control, else the receipt GET).
  refresh,

  /// Acknowledge exactly the shown digest, then switch.
  acknowledge,

  /// Explicit cancel, offered until installation.
  cancel,

  /// Forget the finished or abandoned operation locally.
  dismiss,
}

/// The client status for an accepted transition's status reply.
EnvironmentSwitchStatus transitionStatusFor(TransitionStatus status) {
  switch (status.state) {
    case 'accepted':
      return EnvironmentSwitchStatus.accepted;
    case 'outcome_unknown':
      return EnvironmentSwitchStatus.outcomeUnknown;
    case 'installed':
      return status.revocationConfirmed
          ? EnvironmentSwitchStatus.installedConfirmed
          : EnvironmentSwitchStatus.installedUnconfirmed;
    case 'released':
      return EnvironmentSwitchStatus.released;
    case 'deleted':
      return EnvironmentSwitchStatus.deleted;
    case 'node_fenced':
      final revocation = status.revocation;
      if (status.fenceState == 'blocked' || revocation?.status == 'blocked') {
        return EnvironmentSwitchStatus.revocationBlocked;
      }
      return switch (revocation?.status) {
        'unproven' => EnvironmentSwitchStatus.unproven,
        'confirmed' => EnvironmentSwitchStatus.installing,
        _ => EnvironmentSwitchStatus.draining,
      };
  }
  return EnvironmentSwitchStatus.unrecognized;
}

/// While the source is still draining, progress is read again with backoff.
bool transitionNeedsPolling(TransitionStatus status) =>
    status.state == 'node_fenced' &&
    (status.progress == null ||
        status.revocation == null ||
        status.revocation!.status == 'pending');

/// The interface state of one conversation's switching.
class EnvironmentTransitionFlow extends ChangeNotifier {
  EnvironmentTransitionFlow({
    required this.api,
    required this.session,
    required this.lease,
    this.onBinding,
    String Function()? newId,
    Future<void> Function(Duration)? wait,
    this.backoff = const [
      Duration(seconds: 1),
      Duration(seconds: 2),
      Duration(seconds: 4),
      Duration(seconds: 8),
      Duration(seconds: 15),
      Duration(seconds: 30),
    ],
  }) : newId = newId ?? newTransitionOperationId,
       wait = wait ?? Future<void>.delayed;
  final EnvironmentTransitionApi api;
  final String session;

  /// The current control lease, or null without control.
  final TransitionLease? Function() lease;

  /// Called with the conversation's binding after a read that may have
  /// changed it (load, a stale refusal or an installed switch). Later commands
  /// must send it as `expectedBinding`.
  final void Function(Json binding)? onBinding;
  final String Function() newId;
  final Future<void> Function(Duration) wait;
  final List<Duration> backoff;

  ConversationEnvironment? environment;
  String? operationId, targetWorkspaceId;
  TransitionPreview? preview;
  TransitionStatus? transition;
  EnvironmentSwitchStatus status = EnvironmentSwitchStatus.idle;

  /// The last refusal or ambiguous failure (shown; does not change identity).
  String? errorCode;
  Object? error;
  bool disposed = false, polling = false;
  int _serial = 0, polls = 0;

  Json? get binding => environment?.binding;

  void _emit() {
    if (!disposed) notifyListeners();
  }

  bool _current(int serial, String? op) =>
      !disposed && serial == _serial && op == operationId;

  Set<EnvironmentSwitchAction> get actions {
    final hasLease = lease() != null;
    final unfinished = {
      EnvironmentSwitchStatus.accepted,
      EnvironmentSwitchStatus.outcomeUnknown,
      EnvironmentSwitchStatus.draining,
      EnvironmentSwitchStatus.revocationBlocked,
      EnvironmentSwitchStatus.unproven,
      EnvironmentSwitchStatus.installing,
    };
    final accepted = transition != null;
    return switch (status) {
      EnvironmentSwitchStatus.idle => {
        if (hasLease && binding != null) EnvironmentSwitchAction.preview,
      },
      EnvironmentSwitchStatus.disabled => {EnvironmentSwitchAction.dismiss},
      EnvironmentSwitchStatus.working => {},
      EnvironmentSwitchStatus.ambiguous => {
        accepted || transitionAccepted || confirmSent
            ? EnvironmentSwitchAction.refresh
            : EnvironmentSwitchAction.refreshPreview,
      },
      EnvironmentSwitchStatus.previewNotSaved => {
        EnvironmentSwitchAction.refreshPreview,
        EnvironmentSwitchAction.dismiss,
      },
      EnvironmentSwitchStatus.previewBlocked => {
        EnvironmentSwitchAction.refreshPreview,
        EnvironmentSwitchAction.dismiss,
      },
      EnvironmentSwitchStatus.reviewStale => {
        if (hasLease) EnvironmentSwitchAction.preview,
        EnvironmentSwitchAction.dismiss,
      },
      EnvironmentSwitchStatus.readyToConfirm => {
        if (hasLease) EnvironmentSwitchAction.confirm,
        EnvironmentSwitchAction.refreshPreview,
        EnvironmentSwitchAction.dismiss,
      },
      EnvironmentSwitchStatus.installedConfirmed ||
      EnvironmentSwitchStatus.installedUnconfirmed ||
      EnvironmentSwitchStatus.released ||
      EnvironmentSwitchStatus.deleted => {EnvironmentSwitchAction.dismiss},
      EnvironmentSwitchStatus.failed =>
        accepted || transitionAccepted
            ? {
                EnvironmentSwitchAction.refresh,
                if (hasLease && !installedRefusal)
                  EnvironmentSwitchAction.cancel,
              }
            : {
                if (hasLease) EnvironmentSwitchAction.preview,
                EnvironmentSwitchAction.dismiss,
              },
      EnvironmentSwitchStatus.unrecognized => {EnvironmentSwitchAction.refresh},
      _ when unfinished.contains(status) => {
        EnvironmentSwitchAction.refresh,
        if (status == EnvironmentSwitchStatus.unproven &&
            hasLease &&
            transition?.revocation?.digest != null)
          EnvironmentSwitchAction.acknowledge,
        if (hasLease) EnvironmentSwitchAction.cancel,
      },
      _ => {},
    };
  }

  /// True once confirmation reached the Gateway (a status exists or the
  /// operation came from `activeTransition`).
  bool transitionAccepted = false;

  /// A confirmation was sent for this operation (its outcome may be unknown).
  bool confirmSent = false;
  bool get installedRefusal => errorCode == 'transition_installed';

  /// Read the environment: the current binding and any active transition.
  /// Rediscovers an in-progress switch after a restart.
  Future<void> load() async {
    final serial = _serial;
    try {
      final value = await api.environment(session);
      if (disposed || serial != _serial) return;
      environment = value;
      final b = value.binding;
      if (b != null) onBinding?.call(b);
      final active = value.activeOperationId;
      if (active != null && active != operationId) {
        _adopt(active);
        transitionAccepted = true;
        await refresh();
        return;
      }
    } catch (e) {
      if (!disposed && serial == _serial) error = e;
    }
    _emit();
  }

  void _adopt(String op, {String? target}) {
    _serial++;
    operationId = op;
    targetWorkspaceId = target;
    preview = null;
    transition = null;
    transitionAccepted = false;
    confirmSent = false;
    errorCode = null;
    error = null;
    polls = 0;
  }

  /// A new review with a fresh operation ID.
  Future<void> startPreview(String target) async {
    if (status == EnvironmentSwitchStatus.working) return;
    if (binding == null) await load();
    final expected = binding;
    if (expected == null || lease() == null || disposed) return;
    _adopt(newId(), target: target);
    await _postPreview(expected);
  }

  Future<void> _postPreview(Json expected) async {
    final serial = _serial, op = operationId!;
    status = EnvironmentSwitchStatus.working;
    _emit();
    try {
      final value = await api.preview(
        session,
        operationId: op,
        targetWorkspaceId: targetWorkspaceId!,
        expectedBinding: expected,
      );
      if (_current(serial, op)) _applyPreview(value);
    } catch (e) {
      if (!_current(serial, op)) return;
      if (transitionOutcomeAmbiguous(e)) {
        _fail(e, EnvironmentSwitchStatus.ambiguous);
        await refreshPreview();
        return;
      }
      if (transitionErrorCode(e) == 'stale_environment') {
        _fail(e, EnvironmentSwitchStatus.reviewStale);
        await _reloadBinding();
        return;
      }
      _fail(e, EnvironmentSwitchStatus.failed);
    }
  }

  void _fail(Object e, EnvironmentSwitchStatus next) {
    error = e;
    errorCode = transitionErrorCode(e);
    status = next;
    _emit();
  }

  void _applyPreview(TransitionPreview value) {
    preview = value;
    error = null;
    errorCode = null;
    status = value.disabled
        ? EnvironmentSwitchStatus.disabled
        : value.stale
        ? EnvironmentSwitchStatus.reviewStale
        : value.canConfirm
        ? EnvironmentSwitchStatus.readyToConfirm
        : EnvironmentSwitchStatus.previewBlocked;
    _emit();
  }

  /// GET the preview again; after a lost POST a `404` means it was not
  /// saved, and the same ID with the same intent may be sent again.
  Future<void> refreshPreview() async {
    final op = operationId, serial = _serial;
    if (op == null) return;
    if (status == EnvironmentSwitchStatus.previewNotSaved) {
      final expected = binding;
      if (expected != null) await _postPreview(expected);
      return;
    }
    try {
      final value = await api.readPreview(session, op);
      if (_current(serial, op)) _applyPreview(value);
    } catch (e) {
      if (!_current(serial, op)) return;
      if (_status(e) == 404 && preview == null) {
        _fail(e, EnvironmentSwitchStatus.previewNotSaved);
      } else if (!transitionOutcomeAmbiguous(e)) {
        _fail(e, EnvironmentSwitchStatus.failed);
      } else {
        error = e;
        _emit();
      }
    }
  }

  Future<void> confirm() async {
    final value = preview, control = lease(), op = operationId;
    if (!actions.contains(EnvironmentSwitchAction.confirm) ||
        value == null ||
        control == null ||
        op == null) {
      return;
    }
    final serial = _serial;
    status = EnvironmentSwitchStatus.working;
    confirmSent = true;
    _emit();
    try {
      final result = await api.confirm(
        session,
        op,
        planHash: value.planHash!,
        observationHash: value.observationHash!,
        lease: control,
      );
      if (!_current(serial, op)) return;
      transitionAccepted = true;
      _applyStatus(result);
      // The user confirmed the switch; continue it.
      if (status == EnvironmentSwitchStatus.accepted ||
          status == EnvironmentSwitchStatus.outcomeUnknown ||
          transitionNeedsPolling(result) ||
          status == EnvironmentSwitchStatus.installing) {
        await refresh();
      }
    } catch (e) {
      if (!_current(serial, op)) return;
      final code = transitionErrorCode(e);
      if (transitionOutcomeAmbiguous(e)) {
        _fail(e, EnvironmentSwitchStatus.ambiguous);
        await _readAccepted(serial, op);
      } else if (transitionDisabledCodes.contains(code)) {
        _fail(e, EnvironmentSwitchStatus.disabled);
      } else if (code == 'transition_review_changed' ||
          code == 'stale_environment') {
        _fail(e, EnvironmentSwitchStatus.reviewStale);
        if (code == 'stale_environment') await _reloadBinding();
      } else {
        _fail(e, EnvironmentSwitchStatus.failed);
      }
    }
  }

  /// After a lost confirm: the receipt GET says whether it was accepted.
  /// A `404` leaves the reviewed preview, so the same confirmation (same ID,
  /// same body) can be sent again by the user.
  Future<void> _readAccepted(int serial, String op) async {
    try {
      final result = await api.status(session, op);
      if (!_current(serial, op)) return;
      transitionAccepted = true;
      _applyStatus(result);
      await refresh();
    } catch (e) {
      if (!_current(serial, op)) return;
      if (_status(e) == 404 && preview != null) {
        _applyPreview(preview!);
      } else {
        error = e;
        _emit();
      }
    }
  }

  void _applyStatus(TransitionStatus value) {
    final before = status;
    transition = value;
    status = transitionStatusFor(value);
    error = null;
    errorCode = null;
    _emit();
    final installed =
        status == EnvironmentSwitchStatus.installedConfirmed ||
        status == EnvironmentSwitchStatus.installedUnconfirmed;
    final wasInstalled =
        before == EnvironmentSwitchStatus.installedConfirmed ||
        before == EnvironmentSwitchStatus.installedUnconfirmed;
    // The binding moved: later commands must send the new one.
    if (installed && !wasInstalled) unawaited(_reloadBinding());
  }

  Future<void> _reloadBinding() async {
    try {
      final value = await api.environment(session);
      if (disposed) return;
      environment = value;
      final b = value.binding;
      if (b != null) onBinding?.call(b);
      _emit();
    } catch (_) {
      /* The next load or command refusal reads it again. */
    }
  }

  /// Read the status: `advance` with control (it only joins the same Node
  /// step), otherwise the receipt GET. Polls with backoff while draining.
  Future<void> refresh() async {
    final op = operationId, serial = _serial;
    if (op == null) return;
    if (!transitionAccepted) {
      // Only a confirmation whose reply was lost gets here.
      if (confirmSent) await _readAccepted(serial, op);
      return;
    }
    final ok = await _read(serial, op);
    if (ok && transition != null && transitionNeedsPolling(transition!)) {
      unawaited(_poll(serial, op));
    }
  }

  Future<bool> _read(int serial, String op) async {
    final control = lease();
    try {
      final result = control == null
          ? await api.status(session, op)
          : await api.advance(session, op, control);
      if (!_current(serial, op)) return false;
      transitionAccepted = true;
      // The receipt GET carries no progress; keep the last one shown.
      final merged = !result.hasProgress && transition?.progress != null
          ? TransitionStatus({...result.raw, 'progress': transition!.progress})
          : result;
      _applyStatus(merged);
      return true;
    } catch (e) {
      if (!_current(serial, op)) return false;
      final code = transitionErrorCode(e);
      error = e;
      errorCode = code;
      if (code == 'lost_control' || (!transitionOutcomeAmbiguous(e))) {
        status = EnvironmentSwitchStatus.failed;
      }
      _emit();
      return false;
    }
  }

  Future<void> _poll(int serial, String op) async {
    if (polling) return;
    polling = true;
    var attempt = 0;
    try {
      while (_current(serial, op) &&
          transition != null &&
          transitionNeedsPolling(transition!)) {
        await wait(backoff[min(attempt, backoff.length - 1)]);
        attempt++;
        if (!_current(serial, op)) return;
        polls++;
        if (!await _read(serial, op)) return;
      }
    } finally {
      polling = false;
    }
  }

  /// Acknowledge exactly the digest that is shown, then switch. Never
  /// automatic: a changed digest re-reads and shows the new items.
  Future<void> acknowledge() async {
    final control = lease(), op = operationId;
    final digest = transition?.revocation?.digest;
    if (!actions.contains(EnvironmentSwitchAction.acknowledge) ||
        control == null ||
        op == null ||
        digest == null) {
      return;
    }
    final serial = _serial, shown = transition!;
    status = EnvironmentSwitchStatus.working;
    _emit();
    try {
      final result = await api.acknowledge(
        session,
        op,
        digest: digest,
        lease: control,
      );
      if (_current(serial, op)) _applyStatus(result);
    } catch (e) {
      if (!_current(serial, op)) return;
      final code = transitionErrorCode(e);
      if (transitionOutcomeAmbiguous(e) ||
          code == 'revocation_digest_changed' ||
          code == 'transition_not_unproven' ||
          code == 'revocation_unconfirmed') {
        // Show the current items; the user decides again.
        transition = shown;
        status = transitionStatusFor(shown);
        await _read(serial, op);
        if (_current(serial, op)) {
          error = e;
          errorCode = code;
          _emit();
        }
        return;
      }
      transition = shown;
      _fail(e, transitionStatusFor(shown));
    }
  }

  /// Explicit cancel until installation. `transition_installed` means too
  /// late: switching back is a new switch.
  Future<void> cancel() async {
    final control = lease(), op = operationId;
    if (!actions.contains(EnvironmentSwitchAction.cancel) ||
        control == null ||
        op == null) {
      return;
    }
    final serial = _serial, shown = transition;
    status = EnvironmentSwitchStatus.working;
    _emit();
    try {
      final result = await api.cancel(session, op, control);
      if (_current(serial, op)) _applyStatus(result);
    } catch (e) {
      if (!_current(serial, op)) return;
      final code = transitionErrorCode(e);
      transition = shown;
      status = shown == null
          ? EnvironmentSwitchStatus.unrecognized
          : transitionStatusFor(shown);
      final reread =
          transitionOutcomeAmbiguous(e) ||
          const {
            'transition_installed',
            'transition_outcome_unknown',
            'transition_released',
          }.contains(code);
      // Too late, unknown or already ended: the status read decides.
      if (reread) await _read(serial, op);
      if (!_current(serial, op)) return;
      error = e;
      errorCode = code;
      if (!reread) status = EnvironmentSwitchStatus.failed;
      _emit();
    }
  }

  void dismiss() {
    if (!actions.contains(EnvironmentSwitchAction.dismiss)) return;
    _adopt('');
    operationId = null;
    status = EnvironmentSwitchStatus.idle;
    _emit();
  }

  Future<void> perform(EnvironmentSwitchAction action) async {
    switch (action) {
      case EnvironmentSwitchAction.preview:
        final target = targetWorkspaceId ?? preview?.targetWorkspaceId;
        if (target != null && target.isNotEmpty) await startPreview(target);
      case EnvironmentSwitchAction.refreshPreview:
        await refreshPreview();
      case EnvironmentSwitchAction.confirm:
        await confirm();
      case EnvironmentSwitchAction.refresh:
        await refresh();
      case EnvironmentSwitchAction.acknowledge:
        await acknowledge();
      case EnvironmentSwitchAction.cancel:
        await cancel();
      case EnvironmentSwitchAction.dismiss:
        dismiss();
    }
  }

  @override
  void dispose() {
    disposed = true;
    _serial++;
    super.dispose();
  }
}

// Plain-language text. Codes are shown verbatim only when unknown.

String transitionReasonText(String code) => switch (code) {
  'coordinator_not_available' || 'transition_coordinator_unavailable' => tr(
    "Environment switching is not enabled on this Gateway.",
  ),
  'resource_preflight_required' => tr(
    "The Node has not checked the target's resources yet.",
  ),
  'node_policy_mismatch' => tr("The Node's policies differ from the review."),
  'resource_overlap_requires_review' => tr(
    "The source and target share resources.",
  ),
  'resource_unavailable' => tr("A source or target resource is unavailable."),
  'source_has_pending_work' => tr("The conversation still has pending work."),
  'source_already_fenced' => tr("Another switch is already in progress."),
  'mode_unavailable' => tr("The workspace mode is unavailable."),
  'preview_stale' => tr("The review is out of date."),
  'cross_node_handoff_not_available' => tr(
    "Switching to another Node is not available.",
  ),
  'environment_unchanged' => tr(
    "The conversation already uses this workspace.",
  ),
  'node_unavailable_or_unsupported' => tr(
    "The Node is unavailable or does not support switching.",
  ),
  'revocation_unconfirmed' => tr(
    "Revocation is not confirmed; the listed items need your acknowledgement.",
  ),
  'target_installation_unavailable' => tr(
    "The Node cannot install the target environment.",
  ),
  'revocation_digest_changed' => tr(
    "The listed items changed. Review the new list before acknowledging.",
  ),
  'transition_not_unproven' => tr(
    "There is nothing to acknowledge in the current state.",
  ),
  'transition_not_drained' => tr(
    "The current environment has not finished stopping.",
  ),
  'transition_draining' => tr(
    "The Node is still stopping the current environment; try again shortly.",
  ),
  'transition_installed' => tr(
    "The switch is already installed; switching back is a new switch.",
  ),
  'transition_released' => tr("This switch was cancelled."),
  'transition_target_unreviewed' => tr(
    "This switch has no reviewed target and cannot be installed; cancel it.",
  ),
  'stale_transition_target' => tr(
    "The target workspace changed; cancel and review a new switch.",
  ),
  'lost_control' => tr("Take control of the conversation to continue."),
  'transition_outcome_unknown' => tr(
    "The Node outcome is unknown; check the status before cancelling.",
  ),
  'transition_step_failed' => tr(
    "The Node did not complete the step; check the status.",
  ),
  'invalid_transition_receipt' => tr(
    "The Node's reply did not match this switch; check the status.",
  ),
  'transition_review_changed' => tr(
    "Resources or activity changed. Review the switch again.",
  ),
  'stale_environment' => tr(
    "The conversation environment changed. Review the switch again.",
  ),
  'transition_not_reviewable' => tr(
    "Only a stopped switch can be acknowledged.",
  ),
  _ => code,
};

String revocationKindText(String kind) => switch (kind) {
  'sandbox_launch' => tr("Agent or sandbox launch"),
  'legacy_history' => tr("Earlier history"),
  'unattributed' => tr("Unattributed record"),
  'host_command' => tr("Host-management command"),
  'terminal' => tr("Terminal"),
  'host_terminal' => tr("Host-management terminal"),
  'browser' => tr("Browser session"),
  'native_proxy' => tr("Network proxy"),
  'platform_containment' => tr("Agent processes on this host"),
  _ => kind,
};

String revocationReasonText(String reason) => switch (reason) {
  'unresolved' => tr("still unresolved"),
  'no_binding_generation' => tr("no recorded environment history"),
  'launches_before_journals' => tr("started before complete tracking existed"),
  'binding_changed_without_generation' => tr(
    "the environment changed without a record",
  ),
  'uncontained_launch' => tr("cannot be proven stopped on this host"),
  'untracked_launch' => tr("was not tracked"),
  'other_workspace' => tr("belongs to another workspace"),
  'host_effects_may_survive' => tr("detached host work may survive"),
  'descendants_not_contained' => tr("child processes cannot be proven stopped"),
  _ => reason,
};

String revocationItemText(RevocationItem item) =>
    '${revocationKindText(item.kind)}: ${revocationReasonText(item.reason)}';

String environmentSwitchMessage(EnvironmentTransitionFlow flow) {
  final t = flow.transition;
  final message = switch (flow.status) {
    EnvironmentSwitchStatus.idle => '',
    EnvironmentSwitchStatus.disabled => tr(
      "Environment switching is not enabled on this Gateway.",
    ),
    EnvironmentSwitchStatus.working => tr("Working…"),
    EnvironmentSwitchStatus.ambiguous => tr(
      "The result is unknown. Check the status; nothing is sent again automatically.",
    ),
    EnvironmentSwitchStatus.previewNotSaved => tr(
      "The review may not have been saved. Send the same review again.",
    ),
    EnvironmentSwitchStatus.previewBlocked => tr(
      "This switch cannot be confirmed yet.",
    ),
    EnvironmentSwitchStatus.reviewStale => tr(
      "The review is out of date. Review the switch again.",
    ),
    EnvironmentSwitchStatus.readyToConfirm => tr("Ready to switch."),
    EnvironmentSwitchStatus.accepted => tr(
      "Switch accepted; stopping the current environment…",
    ),
    EnvironmentSwitchStatus.outcomeUnknown => tr(
      "The Node has not confirmed the switch yet.",
    ),
    EnvironmentSwitchStatus.draining => tr(
      "Stopping work in the current environment…",
    ),
    EnvironmentSwitchStatus.revocationBlocked => tr(
      "Some work is not settled yet. Switching waits until it is.",
    ),
    EnvironmentSwitchStatus.unproven => tr(
      "Access cannot be proven revoked for {0} items. Acknowledge them to switch anyway.",
      [t?.revocation?.itemsTotal ?? 0],
    ),
    EnvironmentSwitchStatus.installing => tr("Installing the new environment…"),
    EnvironmentSwitchStatus.installedConfirmed => tr(
      "Switched; revocation confirmed.",
    ),
    EnvironmentSwitchStatus.installedUnconfirmed => tr(
      "Switched; revocation not fully confirmed.",
    ),
    EnvironmentSwitchStatus.released => tr(
      "Cancelled; original workspace kept.",
    ),
    EnvironmentSwitchStatus.deleted => tr(
      "The conversation was deleted; nothing was switched.",
    ),
    EnvironmentSwitchStatus.failed => transitionReasonText(
      flow.errorCode ?? '',
    ),
    EnvironmentSwitchStatus.unrecognized => tr("Unknown switch state: {0}", [
      t?.state ?? '—',
    ]),
  };
  final parts = [
    message,
    if (t?.reconciliationState == 'node_unavailable')
      tr("The Node is unavailable; the switch stays pending."),
    if (flow.errorCode != null && flow.status != EnvironmentSwitchStatus.failed)
      transitionReasonText(flow.errorCode!),
  ];
  return parts.where((p) => p.isNotEmpty).join(' ');
}

String environmentSwitchActionLabel(EnvironmentSwitchAction action) =>
    switch (action) {
      EnvironmentSwitchAction.preview => tr("Review switch"),
      EnvironmentSwitchAction.refreshPreview => tr("Review again"),
      EnvironmentSwitchAction.confirm => tr("Confirm switch"),
      EnvironmentSwitchAction.refresh => tr("Check status"),
      EnvironmentSwitchAction.acknowledge => tr("Acknowledge and switch"),
      EnvironmentSwitchAction.cancel => tr("Cancel switch"),
      EnvironmentSwitchAction.dismiss => tr("Dismiss"),
    };
