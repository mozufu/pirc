/// Client side of conversation environment switching
/// (`plans/transition-installation.md`, T3a/T3b, C4 G1–G5, C1–C3): preview,
/// confirm, progress, operation authority and reauthorization, paged
/// revocation evidence with inherited risk, acknowledgement of all items,
/// serialized cancellation and the installation/readiness result.
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

/// The only `404` codes that mean "this object is not stored" (C4/G5). Any
/// other `404` is a definite refusal, never "not sent".
const transitionNotStoredCodes = {
  'preview_not_found',
  'acceptance_not_found',
  'receipt_not_found',
  'conversation_not_found',
};
bool transitionNotStored(Object error) =>
    _status(error) == 404 &&
    transitionNotStoredCodes.contains(transitionErrorCode(error));

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
  String? get activeState => _text(activeTransition?['state']);
  String? get activeTargetWorkspaceId =>
      _text(activeTransition?['targetWorkspaceId']);

  /// A Node fence without Gateway acceptance (C4/G3): only `reconcile`.
  bool get reconciliationRequired => activeState == 'reconciliation_required';
  String? get recoveryReason => _text(activeTransition?['recoveryReason']);
  List<String> get safeActions => [
    for (final a in (activeTransition?['safeActions'] as List? ?? const []))
      '$a',
  ];

  /// The newest installed or released switch (C4/G2), or null.
  TransitionSummary? get lastFinishedTransition =>
      raw['lastFinishedTransition'] is Map
      ? TransitionSummary(obj(raw['lastFinishedTransition']))
      : null;
}

/// One public transition summary (history item or `lastFinishedTransition`).
class TransitionSummary {
  TransitionSummary(this.raw);
  final Json raw;
  String get operationId => '${raw['operationId'] ?? ''}';
  String get state => '${raw['state'] ?? ''}';
  int? get createdAt => _int(raw['createdAt']);
  String? get targetWorkspaceId => _text(raw['targetWorkspaceId']);
  bool get targetInstalled => raw['targetInstalled'] == true;
  bool get revocationConfirmed => raw['revocationConfirmed'] == true;
}

class TransitionHistoryPage {
  TransitionHistoryPage(Json data)
    : items = [
        for (final item in rows(obj(data['transitions'])['items']))
          TransitionSummary(item),
      ],
      next = _text(obj(data['transitions'])['next']);
  final List<TransitionSummary> items;
  final String? next;
}

/// One page of an immutable evaluation snapshot (C2).
class EvaluationPage {
  EvaluationPage(Json data) : raw = obj(data['evaluation']);
  final Json raw;
  String? get evaluationId => _text(raw['evaluationId']);
  String? get digest => _text(raw['digest']);
  String get status => '${raw['status'] ?? ''}';
  int? get itemsTotal => _int(raw['itemsTotal']);
  String? get next => _text(raw['next']);
  List<RevocationItem> get items => [
    for (final item in rows(raw['items'])) RevocationItem(item),
  ];
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

  /// C1: whether the Gateway may finish this switch without a device holding
  /// control, and for how long. Shown before Confirm.
  bool get operationAuthorityAvailable =>
      obj(raw['operationAuthority'])['available'] == true;
  int? get operationAuthoritySeconds =>
      _int(obj(raw['operationAuthority'])['durationSeconds']);
}

/// One sanitized revocation item: `{kind, reason, acknowledgeable}`.
class RevocationItem {
  RevocationItem(this.raw);
  final Json raw;
  String get kind => '${raw['kind'] ?? ''}';
  String get reason => '${raw['reason'] ?? ''}';
  bool get acknowledgeable => raw['acknowledgeable'] == true;

  /// C2: from an earlier binding generation (or unattributed legacy).
  bool get inherited => raw['inherited'] == true;
  int? get generation => _int(raw['generation']);
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

  /// C2: the immutable snapshot an acknowledgement covers in full.
  String? get evaluationId => _text(raw['evaluationId']);

  /// The current generation's own settlement; [status] is cumulative.
  String? get currentGenerationStatus =>
      _text(obj(raw['currentGeneration'])['status']);
  int? get currentGenerationItemsTotal =>
      _int(obj(raw['currentGeneration'])['itemsTotal']);
}

/// C1 operation authority: never a token, only its public condition.
class TransitionAuthority {
  TransitionAuthority(this.raw);
  final Json raw;
  int? get revision => _int(raw['revision']);
  int? get deadlineAt => _int(raw['deadlineAt']);

  /// `active`, `expired`, `revoked` or `clock_uncertain`.
  String get state => '${raw['state'] ?? ''}';
  bool get reauthorizationRequired => raw['reauthorizationRequired'] == true;
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

  /// The receipt GET is the complete read model since C4/G1; older replies
  /// (a duplicate confirm) omit `progress`.
  bool get hasProgress => raw.containsKey('progress');
  int? get observedAt => _int(progress?['observedAt']);

  /// `review_required` for an acceptance that can no longer be sent (G4).
  String? get stage => _text(progress?['stage']);
  String? get waitReason => _text(progress?['waitReason']);
  List<String> get safeActions => [
    for (final a in (progress?['safeActions'] as List? ?? const [])) '$a',
  ];
  TransitionAuthority? get authority => raw['authority'] is Map
      ? TransitionAuthority(obj(raw['authority']))
      : null;

  /// C3: the durable cancellation intent and the Node's pending reason.
  int? get cancellationRequestedAt =>
      _int(obj(raw['cancellation'])['requestedAt']) ??
      _int(obj(progress?['cancellation'])['requestedAt']);
  bool get cancellationRequested =>
      raw['cancellation'] is Map || progress?['cancellation'] is Map;
  String? get cancellationPendingReason =>
      _text(obj(progress?['cancellation'])['pendingReason']);
  Json get installation => obj(progress?['installation']);
  bool get bindingCommitted => installation['bindingCommitted'] == true;
  bool get policyValidated => installation['policyValidated'] == true;

  /// `not_started`, `ready`, `failed` or `unknown`; null before C3 receipts.
  String? get runtimeReady => _text(installation['runtimeReady']);
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

  /// The complete read model without control and without a Node call
  /// (C4/G1); `404 receipt_not_found` before acceptance.
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

  /// Consent covers every item of [evaluationId] (C2), not only those shown.
  Future<TransitionStatus> acknowledge(
    String session,
    String op, {
    required String digest,
    String? evaluationId,
    required TransitionLease lease,
  }) async => TransitionStatus(
    await gateway.request(
      '${_base(session)}/${enc(op)}/acknowledge',
      method: 'POST',
      body: {'digest': digest, 'evaluationId': ?evaluationId, ...lease.body},
    ),
  );

  /// C1: the current controller renews the same operation's authority.
  Future<TransitionStatus> reauthorize(
    String session,
    String op,
    TransitionLease lease,
  ) async => TransitionStatus(
    await gateway.request(
      '${_base(session)}/${enc(op)}/reauthorize',
      method: 'POST',
      body: lease.body,
    ),
  );

  /// Read-only receipt reconciliation, the only action for a bare fence.
  Future<Json> reconcile(String session, String op) => gateway.request(
    '${_base(session)}/previews/${enc(op)}/reconcile',
    method: 'POST',
  );

  /// Paged history of accepted transitions, newest first (C4/G2).
  Future<TransitionHistoryPage> history(
    String session, {
    String? cursor,
    int? limit,
  }) async => TransitionHistoryPage(
    await gateway.request(
      '${_base(session)}${_query({'cursor': cursor, 'limit': limit})}',
    ),
  );

  /// One page of the immutable evaluation snapshot; read-only.
  Future<EvaluationPage> evaluation(
    String session,
    String op,
    String evaluationId, {
    String? cursor,
    int? limit,
  }) async => EvaluationPage(
    await gateway.request(
      '${_base(session)}/${enc(op)}/evaluations/${enc(evaluationId)}'
      '${_query({'cursor': cursor, 'limit': limit})}',
    ),
  );

  static String _query(Map<String, Object?> values) {
    final parts = [
      for (final e in values.entries)
        if (e.value != null) '${e.key}=${enc('${e.value}')}',
    ];
    return parts.isEmpty ? '' : '?${parts.join('&')}';
  }

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

  /// An undispatched acceptance that can no longer be sent (G4): cancel only.
  reviewRequired,

  /// C3: cancellation requested; the Node completes it once safe.
  cancelPending,

  /// C1: operation authority expired, revoked or clock-uncertain.
  reauthorizationRequired,

  /// C4/G3: a Node fence the Gateway never accepted; reconcile only.
  reconciliationRequired,
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

  /// C1: renew operation authority (current control only).
  reauthorize,

  /// C4/G3: read-only receipt reconciliation of a bare Node fence.
  reconcile,

  /// C2: load the next page of the reviewed evaluation.
  moreItems,

  /// Forget the finished or abandoned operation locally.
  dismiss,
}

/// The client status for an accepted transition's status reply.
EnvironmentSwitchStatus transitionStatusFor(TransitionStatus status) {
  const unfinished = {'accepted', 'outcome_unknown', 'node_fenced'};
  if (unfinished.contains(status.state)) {
    if (status.cancellationRequested) {
      return EnvironmentSwitchStatus.cancelPending;
    }
    if (status.state == 'accepted' && status.stage == 'review_required') {
      return EnvironmentSwitchStatus.reviewRequired;
    }
    if (status.authority?.reauthorizationRequired == true) {
      return EnvironmentSwitchStatus.reauthorizationRequired;
    }
  }
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

/// While the source is still draining, or a requested cancellation waits for
/// the Node, progress is read again with backoff.
bool transitionNeedsPolling(TransitionStatus status) {
  final cancelling =
      transitionStatusFor(status) == EnvironmentSwitchStatus.cancelPending;
  return cancelling ||
      (status.state == 'node_fenced' &&
          status.authority?.reauthorizationRequired != true &&
          (status.progress == null ||
              status.revocation == null ||
              status.revocation!.status == 'pending'));
}

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

  /// C4: the last finished switch and the paged history (newest first).
  TransitionSummary? lastFinished;
  final history = <TransitionSummary>[];
  String? historyNext;
  bool historyLoaded = false;

  /// C2: pages of the evaluation currently shown. Reset when the status
  /// names another evaluation (a changed digest).
  String? pagedEvaluationId;
  final evaluationItems = <RevocationItem>[];
  String? evaluationNext;
  bool evaluationStarted = false;
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
      EnvironmentSwitchStatus.installedUnconfirmed => {
        // Readiness is refreshed read-only (advance once installed).
        if (transition?.runtimeReady != null &&
            transition?.runtimeReady != 'ready')
          EnvironmentSwitchAction.refresh,
        EnvironmentSwitchAction.dismiss,
      },
      EnvironmentSwitchStatus.released ||
      EnvironmentSwitchStatus.deleted => {EnvironmentSwitchAction.dismiss},
      EnvironmentSwitchStatus.reviewRequired => {
        EnvironmentSwitchAction.refresh,
        if (hasLease && (transition?.safeActions.contains('cancel') ?? true))
          EnvironmentSwitchAction.cancel,
      },
      // Never offer install-bound actions after a cancellation request.
      EnvironmentSwitchStatus.cancelPending => {
        EnvironmentSwitchAction.refresh,
      },
      EnvironmentSwitchStatus.reconciliationRequired => {
        if (environment?.safeActions.contains('reconcile') ?? true)
          EnvironmentSwitchAction.reconcile,
      },
      EnvironmentSwitchStatus.reauthorizationRequired => {
        EnvironmentSwitchAction.refresh,
        if (hasLease) EnvironmentSwitchAction.reauthorize,
        if (hasLease &&
            transition?.revocation?.status == 'unproven' &&
            transition?.revocation?.digest != null)
          EnvironmentSwitchAction.acknowledge,
        if (moreItemsAvailable) EnvironmentSwitchAction.moreItems,
        if (hasLease) EnvironmentSwitchAction.cancel,
      },
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
        if (moreItemsAvailable) EnvironmentSwitchAction.moreItems,
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

  /// More items of the shown evaluation exist than are loaded.
  bool get moreItemsAvailable {
    final revocation = transition?.revocation;
    if (revocation?.evaluationId == null) return false;
    if (!evaluationStarted || pagedEvaluationId != revocation!.evaluationId) {
      return revocation!.itemsTotal > revocation.items.length;
    }
    return evaluationNext != null;
  }

  /// The items to show: every loaded page of the shown evaluation, else the
  /// first items carried by the status.
  List<RevocationItem> get shownItems {
    final revocation = transition?.revocation;
    if (revocation == null) return const [];
    return evaluationStarted && pagedEvaluationId == revocation.evaluationId
        ? List.unmodifiable(evaluationItems)
        : revocation.items;
  }

  /// Read the environment: the current binding and any active transition.
  /// Rediscovers an in-progress switch after a restart.
  Future<void> load() async {
    final serial = _serial;
    try {
      final value = await api.environment(session);
      if (disposed || serial != _serial) return;
      environment = value;
      lastFinished = value.lastFinishedTransition;
      final b = value.binding;
      if (b != null) onBinding?.call(b);
      final active = value.activeOperationId;
      if (active != null && value.reconciliationRequired) {
        // Not consent: only read-only reconciliation is offered.
        if (active != operationId) {
          _adopt(active, target: value.activeTargetWorkspaceId);
        }
        status = EnvironmentSwitchStatus.reconciliationRequired;
      } else if (active != null && active != operationId) {
        _adopt(active, target: value.activeTargetWorkspaceId);
        transitionAccepted = true;
        await refresh();
        return;
      } else if (active == null &&
          status == EnvironmentSwitchStatus.reconciliationRequired) {
        dismissLocal();
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
    pagedEvaluationId = null;
    evaluationItems.clear();
    evaluationNext = null;
    evaluationStarted = false;
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
      if (transitionNotStored(e) && preview == null) {
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
      if (transitionNotStored(e) && preview != null) {
        _applyPreview(preview!);
      } else if (!transitionOutcomeAmbiguous(e)) {
        // A generic 404 or another refusal is definite, never "not sent".
        _fail(e, EnvironmentSwitchStatus.failed);
      } else {
        error = e;
        _emit();
      }
    }
  }

  void _applyStatus(TransitionStatus value) {
    final before = status;
    final evaluation = value.revocation?.evaluationId;
    if (evaluationStarted && evaluation != pagedEvaluationId) {
      // A new evaluation (changed digest): earlier pages no longer apply.
      pagedEvaluationId = null;
      evaluationItems.clear();
      evaluationNext = null;
      evaluationStarted = false;
    }
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
        evaluationId: shown.revocation?.evaluationId,
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
      if (_current(serial, op)) {
        _applyStatus(result);
        // A pending cancellation keeps being read until the Node settles it.
        if (transitionNeedsPolling(result)) unawaited(_poll(serial, op));
      }
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
            'transition_cancel_requested',
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
    dismissLocal();
  }

  /// Forget the shown operation locally; nothing changes on the Gateway.
  void dismissLocal() {
    _adopt('');
    operationId = null;
    status = EnvironmentSwitchStatus.idle;
    _emit();
  }

  /// C1: renew operation authority for the same operation, then continue.
  /// `plan_changed` means a new switch is needed after this one ends.
  Future<void> reauthorize() async {
    final control = lease(), op = operationId;
    if (!actions.contains(EnvironmentSwitchAction.reauthorize) ||
        control == null ||
        op == null) {
      return;
    }
    final serial = _serial, shown = transition;
    status = EnvironmentSwitchStatus.working;
    _emit();
    try {
      final result = await api.reauthorize(session, op, control);
      if (!_current(serial, op)) return;
      _applyStatus(result);
      if (transitionNeedsPolling(result)) unawaited(_poll(serial, op));
    } catch (e) {
      if (!_current(serial, op)) return;
      final code = transitionErrorCode(e);
      transition = shown;
      status = shown == null
          ? EnvironmentSwitchStatus.unrecognized
          : transitionStatusFor(shown);
      final ambiguous = transitionOutcomeAmbiguous(e);
      // The read shows the authority actually recorded.
      if (ambiguous || (code?.startsWith('operation_authority_') ?? false)) {
        await _read(serial, op);
      }
      if (!_current(serial, op)) return;
      error = e;
      errorCode = code;
      if (!ambiguous && !(code?.startsWith('operation_authority_') ?? false)) {
        status = EnvironmentSwitchStatus.failed;
      }
      _emit();
    }
  }

  /// C4/G3: read-only reconciliation of a bare Node fence, then re-read the
  /// environment. It never confirms, advances or cancels anything.
  Future<void> reconcile() async {
    final op = operationId;
    if (!actions.contains(EnvironmentSwitchAction.reconcile) || op == null) {
      return;
    }
    final serial = _serial;
    try {
      await api.reconcile(session, op);
    } catch (e) {
      if (!_current(serial, op)) return;
      error = e;
      errorCode = transitionErrorCode(e);
    }
    if (!_current(serial, op)) return;
    final code = errorCode, failure = error;
    await load();
    if (_current(serial, op)) {
      errorCode ??= code;
      error ??= failure;
      _emit();
    }
  }

  /// C2: load the next page of the shown evaluation (a stable snapshot).
  Future<void> loadMoreItems({int? limit}) async {
    final op = operationId, revocation = transition?.revocation;
    final evaluation = revocation?.evaluationId;
    if (op == null || evaluation == null) return;
    if (pagedEvaluationId != evaluation) {
      pagedEvaluationId = evaluation;
      evaluationItems.clear();
      evaluationNext = null;
      evaluationStarted = false;
    }
    if (evaluationStarted && evaluationNext == null) return;
    final serial = _serial, cursor = evaluationNext;
    try {
      final page = await api.evaluation(
        session,
        op,
        evaluation,
        cursor: cursor,
        limit: limit,
      );
      if (!_current(serial, op) || pagedEvaluationId != evaluation) return;
      evaluationItems.addAll(page.items);
      evaluationNext = page.next == cursor ? null : page.next;
      evaluationStarted = true;
      _emit();
    } catch (e) {
      if (!_current(serial, op)) return;
      error = e;
      errorCode = transitionErrorCode(e);
      // A missing snapshot means the evaluation changed: show the current one.
      if (errorCode == 'evaluation_not_found') await _read(serial, op);
      if (_current(serial, op)) {
        error = e;
        errorCode = transitionErrorCode(e);
        _emit();
      }
    }
  }

  /// C4/G2: page this conversation's switches, newest first.
  Future<void> loadHistory({bool more = false, int? limit}) async {
    if (more && historyNext == null) return;
    try {
      final page = await api.history(
        session,
        cursor: more ? historyNext : null,
        limit: limit,
      );
      if (disposed) return;
      if (!more) history.clear();
      history.addAll(page.items);
      historyNext = page.next;
      historyLoaded = true;
      _emit();
    } catch (e) {
      if (disposed) return;
      error = e;
      _emit();
    }
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
      case EnvironmentSwitchAction.reauthorize:
        await reauthorize();
      case EnvironmentSwitchAction.reconcile:
        await reconcile();
      case EnvironmentSwitchAction.moreItems:
        await loadMoreItems();
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
  'operation_authority_missing' => tr(
    "This switch has no operation authority.",
  ),
  'operation_authority_superseded' => tr(
    "A newer authorization replaced this one.",
  ),
  'operation_authority_revoked' => tr("Operation authority was revoked."),
  'operation_authority_expired' => tr("Operation authority expired."),
  'operation_authority_clock_uncertain' => tr(
    "The clock moved back, so the operation authority cannot be trusted.",
  ),
  'operation_authority_revision' => tr(
    "The operation authority revision is out of date.",
  ),
  'operation_authority_invalid' => tr("The operation authority is invalid."),
  'operation_authority_unavailable' => tr(
    "This Gateway does not issue operation authority.",
  ),
  'plan_changed' => tr(
    "The reviewed environment changed. Cancel this switch and review a new one.",
  ),
  'transition_cancel_requested' => tr(
    "Cancellation was requested; this switch will not be installed.",
  ),
  'transition_ended' => tr("This switch has already ended."),
  'evaluation_not_found' => tr(
    "That list of items is no longer current; showing the current one.",
  ),
  'preview_not_found' => tr("The review was not found."),
  'acceptance_not_found' => tr("The switch was not found."),
  'receipt_not_found' => tr("No result was found for this switch."),
  'conversation_not_found' => tr(
    "The conversation is not available on a Node.",
  ),
  'no_gateway_acceptance' => tr(
    "The Node holds a switch fence that this Gateway never accepted.",
  ),
  _ => code,
};

/// C3: why a requested cancellation still waits.
String cancellationReasonText(String? reason) => switch (reason) {
  'drain_active' => tr("work is still stopping"),
  'resources_unresolved' => tr("some resources are unresolved"),
  'original_binding_invalid' => tr("the original workspace is no longer valid"),
  null || '' => tr("waiting for the Node"),
  _ => reason,
};

/// Revocation status words for the current and cumulative reports (C2).
String revocationStatusText(String? status) => switch (status) {
  'pending' => tr("pending"),
  'blocked' => tr("blocked"),
  'unproven' => tr("not fully proven"),
  'confirmed' => tr("confirmed"),
  null || '' => '—',
  _ => status,
};

String transitionDurationText(int seconds) => seconds % 3600 == 0
    ? tr("{0} hours", [seconds ~/ 3600])
    : seconds % 60 == 0
    ? tr("{0} minutes", [seconds ~/ 60])
    : tr("{0} seconds", [seconds]);

/// C1, shown before Confirm.
String operationAuthorityPreviewText(TransitionPreview preview) {
  final seconds = preview.operationAuthoritySeconds;
  return preview.operationAuthorityAvailable && seconds != null
      ? tr(
          "After you confirm, the Gateway may finish this switch without this device for {0}.",
          [transitionDurationText(seconds)],
        )
      : tr("This switch continues only while a device holds control.");
}

String operationAuthorityText(TransitionAuthority authority) =>
    switch (authority.state) {
      'active' => tr("Operation authority is valid until {0}.", [
        authority.deadlineAt == null
            ? '—'
            : DateTime.fromMillisecondsSinceEpoch(
                authority.deadlineAt!,
              ).toLocal().toString().substring(0, 16),
      ]),
      'expired' => tr("Operation authority expired; reauthorize to continue."),
      'revoked' => tr(
        "Operation authority was revoked; reauthorize to continue.",
      ),
      'clock_uncertain' => tr(
        "The Gateway clock moved back; reauthorize to continue.",
      ),
      _ => authority.state,
    };

/// C2: both reports, so a settled new environment is never read as global
/// revocation.
String revocationReportText(TransitionRevocation revocation) =>
    tr("Current environment: {0}. Including earlier environments: {1}.", [
      revocationStatusText(revocation.currentGenerationStatus),
      revocationStatusText(revocation.status),
    ]);

String readinessText(String? runtimeReady) => switch (runtimeReady) {
  'not_started' => tr("Switched; execution not started."),
  'failed' => tr("Switched; execution failed to start."),
  'unknown' => tr("Switched; execution readiness unknown."),
  _ => '',
};

String lastFinishedText(TransitionSummary summary) => switch (summary.state) {
  'installed' =>
    summary.revocationConfirmed
        ? tr("Last switch: switched; revocation confirmed.")
        : tr("Last switch: switched; revocation not fully confirmed."),
  'released' => tr("Last switch: cancelled; original workspace kept."),
  _ => summary.state,
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

String revocationItemText(RevocationItem item) {
  final text =
      '${revocationKindText(item.kind)}: ${revocationReasonText(item.reason)}';
  if (!item.inherited) return text;
  final from = item.generation == null
      ? tr("inherited from earlier history")
      : tr("inherited from environment {0}", [item.generation!]);
  return '$text ($from)';
}

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
    EnvironmentSwitchStatus.installedConfirmed =>
      readinessText(t?.runtimeReady).isEmpty
          ? tr("Switched; revocation confirmed.")
          : '${readinessText(t?.runtimeReady)} ${tr("Revocation confirmed.")}',
    EnvironmentSwitchStatus.installedUnconfirmed =>
      readinessText(t?.runtimeReady).isEmpty
          ? tr("Switched; revocation not fully confirmed.")
          : '${readinessText(t?.runtimeReady)} ${tr("Revocation not fully confirmed.")}',
    EnvironmentSwitchStatus.reviewRequired => tr(
      "This switch can no longer be sent as reviewed: {0} Cancel it.",
      [transitionReasonText(t?.waitReason ?? '')],
    ),
    EnvironmentSwitchStatus.cancelPending => tr("Cancellation pending: {0}.", [
      cancellationReasonText(t?.cancellationPendingReason),
    ]),
    EnvironmentSwitchStatus.reauthorizationRequired =>
      t?.authority == null ? '' : operationAuthorityText(t!.authority!),
    EnvironmentSwitchStatus.reconciliationRequired => [
      transitionReasonText(
        flow.environment?.recoveryReason ?? 'no_gateway_acceptance',
      ),
      tr("Reconcile to read its state."),
    ].join(' '),
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
  final revocation = t?.revocation;
  final authority = t?.authority;
  final parts = [
    message,
    if (revocation != null &&
        revocation.currentGenerationStatus != null &&
        flow.status != EnvironmentSwitchStatus.installedConfirmed &&
        flow.status != EnvironmentSwitchStatus.installedUnconfirmed)
      revocationReportText(revocation),
    if (authority != null &&
        authority.state == 'active' &&
        const {
          EnvironmentSwitchStatus.accepted,
          EnvironmentSwitchStatus.draining,
          EnvironmentSwitchStatus.unproven,
          EnvironmentSwitchStatus.revocationBlocked,
          EnvironmentSwitchStatus.installing,
        }.contains(flow.status))
      operationAuthorityText(authority),
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
      EnvironmentSwitchAction.reauthorize => tr("Reauthorize"),
      EnvironmentSwitchAction.reconcile => tr("Reconcile"),
      EnvironmentSwitchAction.moreItems => tr("Show more items"),
      EnvironmentSwitchAction.cancel => tr("Cancel switch"),
      EnvironmentSwitchAction.dismiss => tr("Dismiss"),
    };

/// The acknowledgement covers every item of the evaluation, not the page.
String acknowledgeLabel(EnvironmentTransitionFlow flow) {
  final total = flow.transition?.revocation?.itemsTotal;
  return total == null
      ? tr("Acknowledge and switch")
      : tr("Acknowledge all {0} items and switch", [total]);
}
