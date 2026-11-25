import 'package:meta/meta.dart';

import '../api_client.dart';
import '../json.dart';
import 'pots_api.dart';

/// A pot's request for more budget (`/api/budget-requests`).
@immutable
class BudgetRequest {
  const BudgetRequest({
    required this.id,
    required this.potId,
    this.window = 'month',
    this.amountMicros,
    this.tokens,
    this.reason = '',
    this.state = 'pending',
    this.approvedAmountMicros,
    this.approvedTokens,
    this.createdAt = 0,
    this.answeredAt,
  });

  factory BudgetRequest.fromJson(Object? json) => BudgetRequest(
    id: text(field(json, 'id')) ?? '',
    potId: text(field(json, 'potId')) ?? '',
    window: str(field(json, 'window')) ?? 'month',
    amountMicros: number(field(json, 'amountMicros')),
    tokens: number(field(json, 'tokens')),
    reason: str(field(json, 'reason')) ?? '',
    state: str(field(json, 'state')) ?? 'pending',
    approvedAmountMicros: number(field(json, 'approvedAmountMicros')),
    approvedTokens: number(field(json, 'approvedTokens')),
    createdAt: number(field(json, 'createdAt')) ?? 0,
    answeredAt: number(field(json, 'answeredAt')),
  );

  final String id;
  final String potId;

  /// `month` (money) or `day` (tokens).
  final String window;

  /// The money asked for, in micro-dollars.
  final int? amountMicros;

  /// The tokens asked for.
  final int? tokens;
  final String reason;

  /// `pending`, `approved`, `approved_amount` or `denied`.
  final String state;
  final int? approvedAmountMicros;
  final int? approvedTokens;
  final int createdAt;
  final int? answeredAt;

  bool get pending => state == 'pending';

  /// `money` or `tokens`: the unit of an answer's `amount`.
  String get unit => amountMicros != null ? 'money' : 'tokens';
}

/// Where a handover sends items: a pot, the user, or nowhere (retire only).
@immutable
class HandoverTo {
  const HandoverTo.pot(String this.potId) : kind = 'pot';
  const HandoverTo.user() : kind = 'user', potId = null;
  const HandoverTo.none() : kind = 'none', potId = null;
  const HandoverTo._(this.kind, this.potId);

  factory HandoverTo.fromJson(Object? json) => HandoverTo._(
    str(field(json, 'kind')) ?? 'none',
    text(field(json, 'potId')),
  );

  /// `pot`, `user` or `none`.
  final String kind;
  final String? potId;

  Map<String, Object?> toJson() => {'kind': kind, 'potId': ?potId};
}

/// One item of a handover with its fit at the receiver.
@immutable
class HandoverEntry {
  const HandoverEntry({required this.item, this.fit = 'ok', this.reason});

  factory HandoverEntry.fromJson(Object? json) => HandoverEntry(
    item: HeldItem.fromJson(json),
    fit: str(field(json, 'fit')) ?? 'ok',
    reason: str(field(json, 'reason')),
  );

  final HeldItem item;

  /// `ok`, `narrowed` or `stop`; checked again on confirm.
  final String fit;
  final String? reason;
}

/// Moving a pot's items to another pot or the user (`/api/handovers`).
@immutable
class Handover {
  const Handover({
    required this.id,
    required this.to,
    this.fromPotId,
    this.proposedBy = 'user',
    this.reason = '',
    this.state = 'proposed',
    this.revision = 0,
    this.items = const [],
    this.createdAt = 0,
    this.appliedAt,
  });

  factory Handover.fromJson(Object? json) => Handover(
    id: text(field(json, 'id')) ?? '',
    to: HandoverTo.fromJson(field(json, 'to')),
    fromPotId: text(field(json, 'fromPotId')),
    proposedBy: str(field(json, 'proposedBy')) ?? 'user',
    reason: str(field(json, 'reason')) ?? '',
    state: str(field(json, 'state')) ?? 'proposed',
    revision: number(field(json, 'revision')) ?? 0,
    items: [
      for (final item in array(field(json, 'items')) ?? const [])
        HandoverEntry.fromJson(item),
    ],
    createdAt: number(field(json, 'createdAt')) ?? 0,
    appliedAt: number(field(json, 'appliedAt')),
  );

  final String id;
  final HandoverTo to;

  /// Null once the giving pot is deleted.
  final String? fromPotId;

  /// `user` or `pot`.
  final String proposedBy;
  final String reason;

  /// `proposed`, `applied` or `rejected`.
  final String state;

  /// Sent back with confirm.
  final int revision;
  final List<HandoverEntry> items;
  final int createdAt;
  final int? appliedAt;
}

/// The causal root behind one user message, event, review or reminder
/// (`/api/causal-roots`).
@immutable
class CausalRoot {
  const CausalRoot({
    required this.id,
    this.originKind = '',
    this.originRef = '',
    this.threadId,
    this.initiatorPot = '',
    this.depthLimit = 0,
    this.fanoutLimit = 0,
    this.budgetMoneyMicros = 0,
    this.budgetTokens = 0,
    this.spentMoneyMicros = 0,
    this.spentTokens = 0,
    this.reservedMoneyMicros = 0,
    this.reservedTokens = 0,
    this.state = 'active',
    this.suspendReason,
    this.suspendedAt,
    this.lastProgressAt = 0,
    this.createdAt = 0,
    this.wakesSinceProgress = 0,
    this.messagesSinceProgress = 0,
  });

  factory CausalRoot.fromJson(Object? json) => CausalRoot(
    id: text(field(json, 'id')) ?? '',
    originKind: str(field(json, 'originKind')) ?? '',
    originRef: text(field(json, 'originRef')) ?? '',
    threadId: text(field(json, 'threadId')),
    initiatorPot: text(field(json, 'initiatorPot')) ?? '',
    depthLimit: number(field(json, 'depthLimit')) ?? 0,
    fanoutLimit: number(field(json, 'fanoutLimit')) ?? 0,
    budgetMoneyMicros: number(field(json, 'budgetMoneyMicros')) ?? 0,
    budgetTokens: number(field(json, 'budgetTokens')) ?? 0,
    spentMoneyMicros: number(field(json, 'spentMoneyMicros')) ?? 0,
    spentTokens: number(field(json, 'spentTokens')) ?? 0,
    reservedMoneyMicros: number(field(json, 'reservedMoneyMicros')) ?? 0,
    reservedTokens: number(field(json, 'reservedTokens')) ?? 0,
    state: str(field(json, 'state')) ?? 'active',
    suspendReason: str(field(json, 'suspendReason')),
    suspendedAt: number(field(json, 'suspendedAt')),
    lastProgressAt: number(field(json, 'lastProgressAt')) ?? 0,
    createdAt: number(field(json, 'createdAt')) ?? 0,
    wakesSinceProgress: number(field(json, 'wakesSinceProgress')) ?? 0,
    messagesSinceProgress: number(field(json, 'messagesSinceProgress')) ?? 0,
  );

  final String id;

  /// `user_message`, `event`, `review` or `reminder`.
  final String originKind;
  final String originRef;

  /// Where the user sees it; null means the initiator's direct thread.
  final String? threadId;
  final String initiatorPot;
  final int depthLimit;
  final int fanoutLimit;
  final int budgetMoneyMicros;
  final int budgetTokens;
  final int spentMoneyMicros;
  final int spentTokens;
  final int reservedMoneyMicros;
  final int reservedTokens;

  /// `active`, `suspended` or `stopped`.
  final String state;
  final String? suspendReason;
  final int? suspendedAt;
  final int lastProgressAt;
  final int createdAt;
  final int wakesSinceProgress;
  final int messagesSinceProgress;

  bool get suspended => state == 'suspended';
}

/// The answer to resuming a root: the root and the pots woken again.
@immutable
class ResumedRoot {
  const ResumedRoot({required this.root, this.kicked = const []});

  factory ResumedRoot.fromJson(Object? json) => ResumedRoot(
    root: CausalRoot.fromJson(field(json, 'causalRoot')),
    kicked: [
      for (final pot in array(field(json, 'kicked')) ?? const []) ?text(pot),
    ],
  );

  final CausalRoot root;
  final List<String> kicked;
}

/// What waits on the user: model approvals, budget requests, handovers and
/// suspended causal roots.
class DecisionsApi {
  const DecisionsApi(this.api);
  final ApiClient api;

  static String _id(String id) => Uri.encodeComponent(id);

  /// Newest first; [state] is `pending`, `allowed_once`, `denied` or `used`.
  Future<List<ModelApproval>> approvals({String? state}) async => [
    for (final approval
        in array(
              field(
                await api.get('/api/model-approvals', query: {'state': ?state}),
                'approvals',
              ),
            ) ??
            const [])
      ModelApproval.fromJson(approval),
  ];

  Future<ModelApproval> approval(String id) async => ModelApproval.fromJson(
    field(await api.get('/api/model-approvals/${_id(id)}'), 'approval'),
  );

  /// [answer] is `deny` or `allow_once`; [reason] goes only with `deny`.
  /// An answered approval is answered 409.
  Future<ModelApproval> answerApproval(
    String id, {
    required String answer,
    String? reason,
  }) async {
    assert(answer == 'deny' || answer == 'allow_once');
    assert(reason == null || answer == 'deny');
    return ModelApproval.fromJson(
      field(
        await api.post('/api/model-approvals/${_id(id)}/answer', {
          'answer': answer,
          'reason': ?reason,
        }),
        'approval',
      ),
    );
  }

  /// [state] is `pending`, `approved`, `approved_amount` or `denied`.
  Future<List<BudgetRequest>> budgetRequests({String? state}) async => [
    for (final request
        in array(
              field(
                await api.get('/api/budget-requests', query: {'state': ?state}),
                'budgetRequests',
              ),
            ) ??
            const [])
      BudgetRequest.fromJson(request),
  ];

  Future<BudgetRequest> budgetRequest(String id) async =>
      BudgetRequest.fromJson(
        field(
          await api.get('/api/budget-requests/${_id(id)}'),
          'budgetRequest',
        ),
      );

  /// [answer] is `approve`, `approve_amount` (with [amount] in the request's
  /// unit) or `deny`.
  Future<BudgetRequest> answerBudgetRequest(
    String id, {
    required String answer,
    int? amount,
  }) async {
    assert(
      answer == 'approve' || answer == 'approve_amount' || answer == 'deny',
    );
    return BudgetRequest.fromJson(
      field(
        await api.post('/api/budget-requests/${_id(id)}/answer', {
          'answer': answer,
          'amount': ?amount,
        }),
        'budgetRequest',
      ),
    );
  }

  /// [state] is `proposed`, `applied` or `rejected`.
  Future<List<Handover>> handovers({String? state}) async => [
    for (final handover
        in array(
              field(
                await api.get('/api/handovers', query: {'state': ?state}),
                'handovers',
              ),
            ) ??
            const [])
      Handover.fromJson(handover),
  ];

  Future<Handover> handover(String id) async => Handover.fromJson(
    field(await api.get('/api/handovers/${_id(id)}'), 'handover'),
  );

  /// Proposes moving [items] (all the pot holds when null) to [to], which is
  /// a pot or the user. Confirm applies it.
  Future<Handover> createHandover({
    required String fromPotId,
    required HandoverTo to,
    List<HeldItem>? items,
    String? reason,
  }) async {
    assert(to.kind != 'none');
    return Handover.fromJson(
      field(
        await api.post('/api/handovers', {
          'fromPotId': fromPotId,
          'to': to.toJson(),
          'items': ?items?.map((item) => item.toRef()).toList(),
          'reason': ?reason,
        }),
        'handover',
      ),
    );
  }

  Future<Handover> confirmHandover(String id, {required int revision}) async =>
      Handover.fromJson(
        field(
          await api.post('/api/handovers/${_id(id)}/confirm', {
            'revision': revision,
          }),
          'handover',
        ),
      );

  Future<Handover> rejectHandover(String id) async => Handover.fromJson(
    field(await api.post('/api/handovers/${_id(id)}/reject'), 'handover'),
  );

  Future<CausalRoot> causalRoot(String id) async => CausalRoot.fromJson(
    field(await api.get('/api/causal-roots/${_id(id)}'), 'causalRoot'),
  );

  /// Lifts a suspension; its queued wakes may deliver again.
  Future<ResumedRoot> resumeCausalRoot(String id) async => ResumedRoot.fromJson(
    await api.post('/api/causal-roots/${_id(id)}/resume'),
  );

  /// Fails the root's queued wakes. This cannot be undone.
  Future<CausalRoot> stopCausalRoot(String id) async => CausalRoot.fromJson(
    field(await api.post('/api/causal-roots/${_id(id)}/stop'), 'causalRoot'),
  );
}
