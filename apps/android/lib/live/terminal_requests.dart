/// Client side of the frozen terminal execution-path contract v1
/// (`plans/execution-isolation.md`): capabilities, durable request identity,
/// ambiguous-outcome recovery, unresolved-request discovery and the mapping of
/// every result state to a client status and its allowed actions.
///
/// This layer is UI-independent. It never falls back to the omitted-path host
/// terminal, never retries a POST by itself and keeps no pending ID on disk:
/// after a restart or on another device, [TerminalRequestTracker.recover]
/// rediscovers unresolved requests from the Node.
library;

import 'dart:async';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'gateway.dart';

/// Discovery and result parity arrived in work-request version 2; a Node that
/// advertises less needs an update instead of an adapted client.
const minWorkTerminalRequestVersion = 2;

/// Acknowledgement of unconfirmed starts and the specific
/// `terminal_request_not_found`/`terminal_capacity` codes arrived in 3.
const acknowledgeWorkTerminalRequestVersion = 3;

/// The only `404` that means "not admitted": the session exists but this
/// request ID does not. Any other `404` (a missing session) is a refusal.
const terminalRequestNotFound = 'terminal_request_not_found';

/// A terminal quota refusal: definite, nothing was admitted.
const terminalCapacity = 'terminal_capacity';

int _version(dynamic value) => value is num ? value.toInt() : 0;
int? _int(dynamic value) => value is num ? value.toInt() : null;
String? _text(dynamic value) => value is String ? value : null;

/// HTTP error code from the native bridge, such as `work_terminal_request_conflict`.
String? terminalRequestErrorCode(Object error) =>
    error is PlatformException ? _text(obj(error.details)['code']) : null;

/// `404 terminal_request_not_found`: not admitted, so the same ID may be
/// re-POSTed with the same intent.
bool terminalRequestNotAdmitted(Object error) =>
    _status(error) == 404 &&
    terminalRequestErrorCode(error) == terminalRequestNotFound;

int? _status(Object error) => error is PlatformException
    ? _int(obj(error.details)['status']) ??
          int.tryParse(error.code.replaceFirst('HTTP_', ''))
    : null;

/// A request whose outcome is unknown: a relay `504 node_timeout`, `503
/// node_offline`, any other 5xx, a lost connection or a cancelled call. Only
/// a definite 4xx answer proves what happened; everything else is resolved
/// by GET, never by a new request.
bool terminalOutcomeAmbiguous(Object error) {
  final status = _status(error);
  return status == null || status < 400 || status >= 500;
}

/// A new client-generated request ID (`[A-Za-z0-9_-]{1,128}`): a random UUID.
String newTerminalRequestId([Random? random]) {
  final r = random ?? Random.secure();
  final bytes = List.generate(16, (_) => r.nextInt(256));
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
      '${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
}

enum TerminalAvailability {
  /// No `terminalCapabilities`, or `workTerminalRequestVersion < 2`.
  needsUpdate,

  /// `enabled: false`: no new terminal of any path.
  disabled,

  /// The ordinary New terminal action uses isolated work.
  isolated,

  /// Isolation is unavailable; see [TerminalCapabilities.offersHostManagement].
  isolationUnavailable,
}

class TerminalCapabilities {
  const TerminalCapabilities({
    required this.known,
    this.enabled = false,
    this.isolatedTerminalVersion = 0,
    this.hostTerminalReviewVersion = 0,
    this.workTerminalRequestVersion = 0,
  });

  /// An older Node ignores `?capabilities=1` and answers the terminal list:
  /// that is [known] false, not a guessed path. Missing fields mean 0.
  factory TerminalCapabilities.parse(Json data) {
    final value = data['terminalCapabilities'];
    if (value is! Map) return const TerminalCapabilities(known: false);
    final c = obj(value);
    return TerminalCapabilities(
      known: true,
      enabled: c['enabled'] == true,
      isolatedTerminalVersion: _version(c['isolatedTerminalVersion']),
      hostTerminalReviewVersion: _version(c['hostTerminalReviewVersion']),
      workTerminalRequestVersion: _version(c['workTerminalRequestVersion']),
    );
  }
  final bool known, enabled;
  final int isolatedTerminalVersion,
      hostTerminalReviewVersion,
      workTerminalRequestVersion;

  TerminalAvailability get availability {
    if (!known || workTerminalRequestVersion < minWorkTerminalRequestVersion) {
      return TerminalAvailability.needsUpdate;
    }
    if (!enabled) return TerminalAvailability.disabled;
    return isolatedTerminalVersion >= 1
        ? TerminalAvailability.isolated
        : TerminalAvailability.isolationUnavailable;
  }

  bool get offersIsolated => availability == TerminalAvailability.isolated;

  /// The separate, explicit host-management action. Never offered while
  /// isolation is available, and never used as a fallback by this client.
  /// `outcome_unknown` requests can be acknowledged (Node 2030). This needs
  /// the control lease but not `enabled`.
  bool get acknowledgesUnknown =>
      known &&
      workTerminalRequestVersion >= acknowledgeWorkTerminalRequestVersion;

  bool get offersHostManagement =>
      availability == TerminalAvailability.isolationUnavailable &&
      hostTerminalReviewVersion >= 1;
}

/// What the Node digests: a POST retry is valid only with the same session,
/// control lease and size.
@immutable
class TerminalIntent {
  const TerminalIntent({
    required this.sessionId,
    required this.clientId,
    required this.generation,
    this.cols = 80,
    this.rows = 24,
  });
  final String sessionId, clientId;
  final Object generation;
  final int cols, rows;
  Json get body => {
    'clientId': clientId,
    'generation': generation,
    'cols': cols,
    'rows': rows,
  };
  @override
  bool operator ==(Object other) =>
      other is TerminalIntent &&
      other.sessionId == sessionId &&
      other.clientId == clientId &&
      other.generation == generation &&
      other.cols == cols &&
      other.rows == rows;
  @override
  int get hashCode => Object.hash(sessionId, clientId, generation, cols, rows);
}

enum TerminalRequestKind { work, host }

/// The minimal human review of a host-management terminal.
class TerminalHostReview {
  TerminalHostReview(this.raw);
  final Json raw;
  String get shell => '${raw['shell'] ?? ''}';
  String get cwd => '${raw['cwd'] ?? ''}';
  int? get cols => _int(raw['cols']);
  int? get rows => _int(raw['rows']);

  /// Shown verbatim: it is the Node's statement of host effects.
  String get warning => '${raw['warning'] ?? ''}';
}

/// Which row of the contract's state table a result is in.
enum TerminalRequestPhase {
  review,
  stale,
  expired,
  preparing,

  /// `launching`/`running` with its live `terminal`: attach to its stream.
  live,
  notStarted,
  outcomeUnknown,
  settled,
  unconfirmed,

  /// A state this client does not know; shown raw, only GET is allowed.
  unrecognized,
}

/// One `workRequest` or `hostManagement` result, the same shape from POST,
/// the single-request GET and each `unresolvedRequests` item.
class TerminalRequestResult {
  TerminalRequestResult._(this.kind, this.raw, this.terminal);
  factory TerminalRequestResult.parse(Json data) {
    final work = data['workRequest'], host = data['hostManagement'];
    final terminal = data['terminal'] is Map ? obj(data['terminal']) : null;
    if (work is Map) {
      return TerminalRequestResult._(
        TerminalRequestKind.work,
        obj(work),
        terminal,
      );
    }
    if (host is Map) {
      return TerminalRequestResult._(
        TerminalRequestKind.host,
        obj(host),
        terminal,
      );
    }
    throw const FormatException('Not a terminal request result');
  }
  final TerminalRequestKind kind;
  final Json raw;

  /// The live terminal linked to this request, if the Node still has it.
  final Json? terminal;
  int get version => _version(raw['version']);
  String get requestId => '${raw['requestId'] ?? ''}';
  String get state => '${raw['state'] ?? ''}';
  String? get errorCode => _text(raw['errorCode']);
  String? get terminalId => _text(raw['terminalId']);

  /// Set once the user acknowledged an unconfirmed start. The state stays
  /// `outcome_unknown`; this is not a closure.
  int? get acknowledgedAt => _int(raw['acknowledgedAt']);

  /// Host only: the exact review identity a confirmation must echo.
  String? get reviewId => _text(raw['id']);
  String? get reviewHash => _text(raw['reviewHash']);
  int? get expiresAt => _int(raw['expiresAt']);
  TerminalHostReview? get review =>
      raw['review'] is Map ? TerminalHostReview(obj(raw['review'])) : null;

  TerminalRequestPhase get phase => switch (state) {
    'review' => TerminalRequestPhase.review,
    'stale' => TerminalRequestPhase.stale,
    'expired' => TerminalRequestPhase.expired,
    'preparing' => TerminalRequestPhase.preparing,
    // Without its terminal the start or liveness cannot be confirmed
    // (Node itself reports `outcome_unknown` then); never attach blindly.
    'launching' || 'running' =>
      terminal != null && terminal!['id'] != null
          ? TerminalRequestPhase.live
          : TerminalRequestPhase.outcomeUnknown,
    'not_started' => TerminalRequestPhase.notStarted,
    'outcome_unknown' => TerminalRequestPhase.outcomeUnknown,
    'settled' => TerminalRequestPhase.settled,
    'unconfirmed' => TerminalRequestPhase.unconfirmed,
    _ => TerminalRequestPhase.unrecognized,
  };
}

class TerminalRequestPage {
  const TerminalRequestPage(this.items, this.next);

  /// An older Node ignores the query and answers the list: no requests.
  factory TerminalRequestPage.parse(Json data) {
    final page = obj(data['terminalRequests']);
    return TerminalRequestPage([
      for (final item in rows(page['items'])) TerminalRequestResult.parse(item),
    ], _text(page['next']));
  }
  final List<TerminalRequestResult> items;
  final String? next;
}

/// The HTTP calls of the contract. Paired Android calls the Gateway directly
/// at the same `/api/sessions/:id/terminals` paths as Web.
class TerminalRequestApi {
  const TerminalRequestApi(this.gateway);
  final Gateway gateway;
  String _path(String session) => '${sessionPath(session)}/terminals';

  Future<TerminalCapabilities> capabilities(String session) async =>
      TerminalCapabilities.parse(
        await gateway.request('${_path(session)}?capabilities=1'),
      );

  Future<TerminalRequestResult> submitWork(
    String requestId,
    TerminalIntent intent,
  ) async => TerminalRequestResult.parse(
    await gateway.request(
      _path(intent.sessionId),
      method: 'POST',
      body: {
        ...intent.body,
        'executionPath': 'isolated_work',
        'requestId': requestId,
      },
    ),
  );

  Future<TerminalRequestResult> reviewHost(
    String requestId,
    TerminalIntent intent,
  ) async => TerminalRequestResult.parse(
    await gateway.request(
      _path(intent.sessionId),
      method: 'POST',
      body: {
        ...intent.body,
        'executionPath': 'host_management',
        'action': 'review',
        'requestId': requestId,
      },
    ),
  );

  Future<TerminalRequestResult> confirmHost(
    TerminalRequestResult review,
    TerminalIntent intent,
  ) async => TerminalRequestResult.parse(
    await gateway.request(
      _path(intent.sessionId),
      method: 'POST',
      body: {
        ...intent.body,
        'executionPath': 'host_management',
        'action': 'confirm',
        'requestId': review.requestId,
        'reviewId': review.reviewId,
        'reviewHash': review.reviewHash,
        'confirmed': true,
      },
    ),
  );

  /// Record the user's acknowledgement of an `outcome_unknown` request:
  /// exactly one ID and the current lease, no other fields.
  Future<TerminalRequestResult> acknowledge(
    String session,
    TerminalRequestKind kind,
    String requestId, {
    required String clientId,
    required Object generation,
  }) async => TerminalRequestResult.parse(
    await gateway.request(
      _path(session),
      method: 'POST',
      body: {
        'action': 'acknowledge',
        'clientId': clientId,
        'generation': generation,
        kind == TerminalRequestKind.work ? 'workRequestId' : 'hostRequestId':
            requestId,
      },
    ),
  );

  /// The retained result, or null on `404 terminal_request_not_found`: the
  /// request was not admitted. Any other failure, including a `404` for a
  /// missing session, is rethrown.
  Future<TerminalRequestResult?> read(
    String session,
    TerminalRequestKind kind,
    String requestId,
  ) async {
    final key = kind == TerminalRequestKind.work
        ? 'workRequestId'
        : 'hostRequestId';
    try {
      return TerminalRequestResult.parse(
        await gateway.request('${_path(session)}?$key=${enc(requestId)}'),
      );
    } on PlatformException catch (e) {
      if (terminalRequestNotAdmitted(e)) return null;
      rethrow;
    }
  }

  Future<TerminalRequestPage> unresolvedPage(
    String session, {
    int? limit,
    String? after,
  }) async => TerminalRequestPage.parse(
    await gateway.request(
      '${_path(session)}?unresolvedRequests=1'
      '${limit == null ? '' : '&limit=$limit'}'
      '${after == null ? '' : '&after=${enc(after)}'}',
    ),
  );

  /// Every unresolved request: pages may be short or empty, so this follows
  /// `next` until it is null.
  Future<List<TerminalRequestResult>> unresolved(
    String session, {
    int? limit,
  }) async {
    final items = <TerminalRequestResult>[];
    String? after;
    while (true) {
      final page = await unresolvedPage(session, limit: limit, after: after);
      items.addAll(page.items);
      if (page.next == null) return items;
      if (page.next == after) {
        throw StateError('Terminal request paging did not advance');
      }
      after = page.next;
    }
  }
}

/// One client status per contract row, plus the transport states before a
/// result is known.
enum TerminalRequestStatus {
  /// POST in flight (work submission, host review or host confirmation).
  submitting,

  /// The POST outcome is unknown (504/503/5xx/connection loss); GET resolves it.
  ambiguous,

  /// GET answered `404 terminal_request_not_found` after an ambiguous POST:
  /// not admitted yet.
  notAdmitted,

  /// `409 work_terminal_request_conflict`: this ID has a different intent.
  conflict,

  /// A definite 4xx refusal; nothing was admitted by this POST.
  rejected,

  /// `409 terminal_capacity`: too many open or preparing terminals.
  capacity,
  review,
  stale,
  expired,
  preparing,
  live,
  notStarted,
  outcomeUnknown,
  settled,
  unconfirmed,
  unrecognized,
}

enum TerminalRequestAction {
  /// GET this request's retained result (polling, ambiguity, conflict).
  refresh,

  /// Re-POST the same ID with the same intent; only after a `404` GET and
  /// only while the control lease and size are unchanged.
  resubmit,

  /// Confirm a pending host review with its exact `reviewId`/`reviewHash`.
  confirm,

  /// Attach to the live terminal stream.
  attach,

  /// A new user action with a new ID (Try again, or a new host review).
  startOver,

  /// Record a retained acknowledgement of an `outcome_unknown` request on
  /// the Node (v3). It hides the request from discovery; it is not a closure.
  acknowledge,

  /// The explicit host-management action, offered after an isolated
  /// no-start when the Node offers it. Never chosen automatically.
  hostManagement,

  /// Hide locally. Nothing is cleared on the Node; discovery shows an
  /// unresolved request again after a reload.
  dismiss,
}

class TerminalRequestEntry {
  TerminalRequestEntry(this.kind, this.requestId, this.intent);
  final TerminalRequestKind kind;
  final String requestId;

  /// The intent this client POSTed with; null when the request was
  /// discovered, which allows GET only (and confirming a discovered review).
  final TerminalIntent? intent;
  TerminalRequestStatus status = TerminalRequestStatus.submitting;
  TerminalRequestResult? result;

  /// The last failed call, kept for display; it does not change [status].
  Object? error;
  bool polling = false;
  String? get errorCode => result?.errorCode;

  /// The Node retains the user's acknowledgement; no longer pending.
  bool get acknowledged => result?.acknowledgedAt != null;
}

TerminalRequestStatus terminalStatusFor(TerminalRequestPhase phase) =>
    switch (phase) {
      TerminalRequestPhase.review => TerminalRequestStatus.review,
      TerminalRequestPhase.stale => TerminalRequestStatus.stale,
      TerminalRequestPhase.expired => TerminalRequestStatus.expired,
      TerminalRequestPhase.preparing => TerminalRequestStatus.preparing,
      TerminalRequestPhase.live => TerminalRequestStatus.live,
      TerminalRequestPhase.notStarted => TerminalRequestStatus.notStarted,
      TerminalRequestPhase.outcomeUnknown =>
        TerminalRequestStatus.outcomeUnknown,
      TerminalRequestPhase.settled => TerminalRequestStatus.settled,
      TerminalRequestPhase.unconfirmed => TerminalRequestStatus.unconfirmed,
      TerminalRequestPhase.unrecognized => TerminalRequestStatus.unrecognized,
    };

/// The contract's allowed actions for an entry. [current] is the intent the
/// client would send now (null without control); [capabilities] the last read.
Set<TerminalRequestAction> terminalRequestActions(
  TerminalRequestEntry entry, {
  required TerminalIntent? current,
  required TerminalCapabilities? capabilities,
}) {
  const refresh = TerminalRequestAction.refresh,
      dismiss = TerminalRequestAction.dismiss;
  return switch (entry.status) {
    TerminalRequestStatus.submitting => {},
    // Dismissing is local: an admitted request is rediscovered or listed.
    TerminalRequestStatus.ambiguous => {refresh, dismiss},
    TerminalRequestStatus.notAdmitted => {
      if (entry.intent != null && entry.intent == current)
        TerminalRequestAction.resubmit,
      dismiss,
    },
    TerminalRequestStatus.conflict => {refresh, dismiss},
    TerminalRequestStatus.rejected => {
      if (entry.result != null) refresh,
      TerminalRequestAction.startOver,
      dismiss,
    },
    TerminalRequestStatus.capacity => {
      TerminalRequestAction.startOver,
      dismiss,
    },
    TerminalRequestStatus.review => {
      if (_confirmIntent(entry, current) != null) TerminalRequestAction.confirm,
      refresh,
      dismiss,
    },
    TerminalRequestStatus.stale ||
    TerminalRequestStatus.expired => {TerminalRequestAction.startOver, dismiss},
    TerminalRequestStatus.preparing => {refresh},
    TerminalRequestStatus.live => {TerminalRequestAction.attach},
    TerminalRequestStatus.notStarted => {
      TerminalRequestAction.startOver,
      if (entry.kind == TerminalRequestKind.work &&
          capabilities?.offersHostManagement == true)
        TerminalRequestAction.hostManagement,
      dismiss,
    },
    TerminalRequestStatus.outcomeUnknown => {
      refresh,
      if (current != null &&
          capabilities?.acknowledgesUnknown == true &&
          entry.result != null &&
          !entry.acknowledged)
        TerminalRequestAction.acknowledge,
      dismiss,
    },
    TerminalRequestStatus.settled ||
    TerminalRequestStatus.unconfirmed => {dismiss},
    TerminalRequestStatus.unrecognized => {refresh, dismiss},
  };
}

/// The intent a host confirmation is sent with: the current lease with the
/// reviewed `cols`/`rows`. A review this client made needs its own intent to be
/// still current; for a discovered review Node refuses a different lease.
TerminalIntent? _confirmIntent(
  TerminalRequestEntry entry,
  TerminalIntent? current,
) {
  final result = entry.result;
  if (current == null ||
      result == null ||
      result.reviewId == null ||
      result.reviewHash == null) {
    return null;
  }
  if (entry.intent != null && entry.intent != current) return null;
  final review = result.review;
  return TerminalIntent(
    sessionId: current.sessionId,
    clientId: current.clientId,
    generation: current.generation,
    cols: review?.cols ?? current.cols,
    rows: review?.rows ?? current.rows,
  );
}

/// The request flow of one session. Recreate it when the session, origin or
/// client changes; it holds no persisted state.
class TerminalRequestTracker extends ChangeNotifier {
  TerminalRequestTracker({
    required this.api,
    required this.session,
    required this.current,
    this.onLive,
    String Function()? newId,
    Future<void> Function(Duration)? wait,
    this.pollInterval = const Duration(seconds: 1),
  }) : newId = newId ?? newTerminalRequestId,
       wait = wait ?? Future<void>.delayed;
  final TerminalRequestApi api;
  final String session;

  /// The intent the client would send now, or null without control.
  final TerminalIntent? Function() current;

  /// Called once per entry that reaches [TerminalRequestStatus.live].
  final void Function(Json terminal)? onLive;
  final String Function() newId;
  final Future<void> Function(Duration) wait;
  final Duration pollInterval;
  final entries = <TerminalRequestEntry>[];
  TerminalCapabilities? capabilities;
  Object? capabilitiesError, recoverError;
  bool disposed = false, recovering = false;

  void _emit() {
    if (!disposed) notifyListeners();
  }

  bool _alive(TerminalRequestEntry entry) =>
      !disposed && entries.contains(entry);

  /// Requests still needing a decision: not attached as a live terminal and
  /// not acknowledged on the Node.
  List<TerminalRequestEntry> get pending => [
    for (final entry in entries)
      if (entry.status != TerminalRequestStatus.live && !entry.acknowledged)
        entry,
  ];

  Set<TerminalRequestAction> actions(TerminalRequestEntry entry) =>
      terminalRequestActions(
        entry,
        current: current(),
        capabilities: capabilities,
      );

  Future<TerminalCapabilities?> loadCapabilities() async {
    try {
      final value = await api.capabilities(session);
      if (disposed) return null;
      capabilities = value;
      capabilitiesError = null;
      return value;
    } catch (e) {
      if (!disposed) capabilitiesError = e;
      return null;
    } finally {
      _emit();
    }
  }

  /// The ordinary New terminal action. Re-reads capabilities and POSTs an
  /// isolated work request with a fresh ID only when isolation is available;
  /// otherwise returns null and leaves [capabilities] for the caller to explain.
  Future<TerminalRequestEntry?> openWork() async {
    final intent = current();
    if (intent == null) return null;
    final caps = await loadCapabilities();
    if (caps == null || !caps.offersIsolated || disposed) return null;
    return _start(TerminalRequestKind.work, intent);
  }

  /// The separate, explicit host-management action: asks the Node for a
  /// review. Opening needs a later [confirm].
  Future<TerminalRequestEntry?> reviewHost() async {
    final intent = current();
    if (intent == null) return null;
    final caps = await loadCapabilities();
    if (caps == null || !caps.offersHostManagement || disposed) return null;
    return _start(TerminalRequestKind.host, intent);
  }

  Future<TerminalRequestEntry> _start(
    TerminalRequestKind kind,
    TerminalIntent intent,
  ) async {
    final entry = TerminalRequestEntry(kind, newId(), intent);
    entries.add(entry);
    await _post(entry, intent);
    return entry;
  }

  Future<void> _post(TerminalRequestEntry entry, TerminalIntent intent) async {
    entry
      ..status = TerminalRequestStatus.submitting
      ..error = null;
    _emit();
    try {
      final result = entry.kind == TerminalRequestKind.work
          ? await api.submitWork(entry.requestId, intent)
          : await api.reviewHost(entry.requestId, intent);
      if (_alive(entry)) _apply(entry, result);
    } catch (e) {
      await _failed(entry, e);
    }
  }

  Future<void> _failed(TerminalRequestEntry entry, Object error) async {
    if (!_alive(entry)) return;
    entry.error = error;
    if (terminalOutcomeAmbiguous(error)) {
      entry.status = TerminalRequestStatus.ambiguous;
      _emit();
      // Resolve by a read, never by another request.
      await _read(entry);
      return;
    }
    entry.status = switch (terminalRequestErrorCode(error)) {
      'work_terminal_request_conflict' => TerminalRequestStatus.conflict,
      terminalCapacity => TerminalRequestStatus.capacity,
      _ => TerminalRequestStatus.rejected,
    };
    _emit();
  }

  void _apply(TerminalRequestEntry entry, TerminalRequestResult result) {
    final wasLive = entry.status == TerminalRequestStatus.live;
    entry
      ..result = result
      ..status = terminalStatusFor(result.phase);
    if (entry.status == TerminalRequestStatus.live && !wasLive) {
      onLive?.call(result.terminal!);
    }
    _emit();
    if (entry.status == TerminalRequestStatus.preparing) {
      unawaited(_poll(entry));
    }
  }

  /// GET the retained result. A `404` before any result means not admitted.
  Future<bool> _read(TerminalRequestEntry entry) async {
    try {
      final result = await api.read(session, entry.kind, entry.requestId);
      if (!_alive(entry)) return false;
      entry.error = null;
      if (result != null) {
        _apply(entry, result);
        return true;
      }
      if (entry.result == null) {
        entry.status = TerminalRequestStatus.notAdmitted;
      } else {
        // An admitted request is retained; a missing one is unexplained.
        entry.status = TerminalRequestStatus.unrecognized;
      }
      _emit();
      return true;
    } catch (e) {
      if (_alive(entry)) {
        entry.error = e;
        // Any other 404 (a missing session) is a definite refusal, not
        // "not admitted": the same ID is never re-POSTed for it.
        if (_status(e) == 404 && entry.result == null) {
          entry.status = TerminalRequestStatus.rejected;
        }
        _emit();
      }
      return false;
    }
  }

  /// Poll while preparing; a failed read stops polling and leaves [refresh].
  Future<void> _poll(TerminalRequestEntry entry) async {
    if (entry.polling) return;
    entry.polling = true;
    try {
      while (_alive(entry) && entry.status == TerminalRequestStatus.preparing) {
        await wait(pollInterval);
        if (!_alive(entry) || entry.status != TerminalRequestStatus.preparing) {
          return;
        }
        if (!await _read(entry)) return;
      }
    } finally {
      entry.polling = false;
    }
  }

  Future<void> refresh(TerminalRequestEntry entry) async {
    if (!actions(entry).contains(TerminalRequestAction.refresh)) return;
    await _read(entry);
  }

  /// Re-POST the same ID after a `404`, only with the unchanged intent.
  Future<void> resubmit(TerminalRequestEntry entry) async {
    if (!actions(entry).contains(TerminalRequestAction.resubmit)) return;
    await _post(entry, entry.intent!);
  }

  Future<void> confirm(TerminalRequestEntry entry) async {
    final review = entry.result, intent = _confirmIntent(entry, current());
    if (!actions(entry).contains(TerminalRequestAction.confirm) ||
        review == null ||
        intent == null) {
      return;
    }
    entry
      ..status = TerminalRequestStatus.submitting
      ..error = null;
    _emit();
    try {
      final result = await api.confirmHost(review, intent);
      if (_alive(entry)) _apply(entry, result);
    } catch (e) {
      if (!_alive(entry)) return;
      entry.error = e;
      if (terminalOutcomeAmbiguous(e)) {
        entry.status = TerminalRequestStatus.ambiguous;
        _emit();
        await _read(entry);
        return;
      }
      // A refused confirmation consumed nothing; the review result decides.
      entry.status = TerminalRequestStatus.rejected;
      _emit();
    }
  }

  /// Acknowledge an `outcome_unknown` request on the Node (v3). The state
  /// stays `outcome_unknown`; the entry only stops being pending.
  Future<void> acknowledge(TerminalRequestEntry entry) async {
    final lease = current(), previous = entry.result;
    if (!actions(entry).contains(TerminalRequestAction.acknowledge) ||
        lease == null ||
        previous == null) {
      return;
    }
    entry
      ..status = TerminalRequestStatus.submitting
      ..error = null;
    _emit();
    try {
      final result = await api.acknowledge(
        session,
        entry.kind,
        entry.requestId,
        clientId: lease.clientId,
        generation: lease.generation,
      );
      if (_alive(entry)) _apply(entry, result);
    } catch (e) {
      if (!_alive(entry)) return;
      entry.error = e;
      final ambiguous = terminalOutcomeAmbiguous(e);
      // A definite refusal recorded nothing; keep the previous result.
      entry.status = ambiguous
          ? TerminalRequestStatus.ambiguous
          : terminalStatusFor(previous.phase);
      _emit();
      // Unknown outcome, or the state moved on: the retained result decides.
      if (ambiguous ||
          terminalRequestErrorCode(e) == 'terminal_request_not_unknown') {
        await _read(entry);
      }
    }
  }

  /// Start over as a new user action with a new ID.
  Future<TerminalRequestEntry?> startOver(TerminalRequestEntry entry) async {
    if (!actions(entry).contains(TerminalRequestAction.startOver)) return null;
    dismiss(entry);
    return entry.kind == TerminalRequestKind.work ? openWork() : reviewHost();
  }

  void dismiss(TerminalRequestEntry entry) {
    if (entries.remove(entry)) _emit();
  }

  /// Rediscover this owner's unresolved requests (`preparing`, `review`,
  /// `outcome_unknown`) after a reload, reconnect or on another device.
  Future<void> recover({int? limit}) async {
    if (recovering) return;
    recovering = true;
    try {
      final items = await api.unresolved(session, limit: limit);
      if (disposed) return;
      recoverError = null;
      for (final result in items) {
        var entry = entries
            .where(
              (e) => e.kind == result.kind && e.requestId == result.requestId,
            )
            .firstOrNull;
        if (entry == null) {
          entry = TerminalRequestEntry(result.kind, result.requestId, null);
          entries.add(entry);
        }
        _apply(entry, result);
      }
    } catch (e) {
      if (!disposed) recoverError = e;
    } finally {
      recovering = false;
      _emit();
    }
  }

  @override
  void dispose() {
    disposed = true;
    super.dispose();
  }
}
