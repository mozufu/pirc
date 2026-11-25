import 'package:meta/meta.dart';

import '../api_client.dart';
import '../json.dart';
import 'decisions_api.dart';

List<String> _strings(Object? json) => [
  for (final item in array(json) ?? const []) ?text(item),
];

/// What is left of a pot's budget in the current windows.
///
/// Provisional: the Gateway adds `budgetLeft` in M7 step 0.
@immutable
class BudgetLeft {
  const BudgetLeft({this.moneyMicros, this.tokens});

  static BudgetLeft? fromJson(Object? json) => json is Map
      ? BudgetLeft(
          moneyMicros: number(field(json, 'moneyMicros')),
          tokens: number(field(json, 'tokens')),
        )
      : null;

  /// Money left this month, in micro-dollars; null when the limit is off.
  final int? moneyMicros;

  /// Tokens left today; null when the limit is off.
  final int? tokens;
}

/// A pot as the lists need it (`GET /api/pots`).
@immutable
class PotSummary {
  const PotSummary({
    required this.id,
    required this.name,
    this.state = 'active',
    this.avatarColor = 1,
    this.avatarImage,
    this.intro = '',
    this.status = 'idle',
    this.needsYou = 0,
    this.budgetLeft,
    this.sessionId,
  });

  factory PotSummary.fromJson(Object? json) => PotSummary(
    id: text(field(json, 'id')) ?? '',
    name: str(field(field(json, 'profile'), 'name')) ?? '',
    state: str(field(json, 'state')) ?? 'active',
    avatarColor: number(field(field(json, 'profile'), 'avatarColor')) ?? 1,
    avatarImage: str(field(field(json, 'profile'), 'avatarImage')),
    intro: str(field(field(json, 'work'), 'intro')) ?? '',
    status: str(field(json, 'status')) ?? 'idle',
    needsYou: number(field(json, 'needsYou')) ?? 0,
    budgetLeft: BudgetLeft.fromJson(field(json, 'budgetLeft')),
    sessionId: text(field(json, 'sessionId')),
  );

  final String id;
  final String name;

  /// `active`, `paused` or `archived`.
  final String state;

  /// 1–5 (`avatar.<n>`).
  final int avatarColor;

  /// An image ID for `GET /api/images/{id}` (provisional, step 0).
  final String? avatarImage;

  /// The one-line introduction (`work.intro`).
  final String intro;

  /// `working`, `idle` or `unavailable` (provisional, step 0).
  final String status;

  /// How many items wait on the user (provisional, step 0).
  final int needsYou;

  /// Provisional, step 0.
  final BudgetLeft? budgetLeft;
  final String? sessionId;
}

/// Who a pot is: the first step of the design.
@immutable
class PotProfile {
  const PotProfile({
    required this.name,
    this.avatarColor = 1,
    this.personality = '',
    this.avatarImage,
  });

  factory PotProfile.fromJson(Object? json) => PotProfile(
    name: str(field(json, 'name')) ?? '',
    avatarColor: number(field(json, 'avatarColor')) ?? 1,
    personality: str(field(json, 'personality')) ?? '',
    avatarImage: str(field(json, 'avatarImage')),
  );

  final String name;

  /// 1–5 (`avatar.<n>`).
  final int avatarColor;
  final String personality;

  /// An image ID (provisional, step 0). It is sent only when set.
  final String? avatarImage;

  Map<String, Object?> toJson() => {
    'name': name,
    'avatarColor': avatarColor,
    'personality': personality,
    'avatarImage': ?avatarImage,
  };
}

@immutable
class PotResponsibility {
  const PotResponsibility({required this.title, this.detail = ''});

  factory PotResponsibility.fromJson(Object? json) => PotResponsibility(
    title: str(field(json, 'title')) ?? '',
    detail: str(field(json, 'detail')) ?? '',
  );

  final String title;
  final String detail;

  Map<String, Object?> toJson() => {'title': title, 'detail': detail};
}

/// What a pot does: the second step of the design (the `work` section).
@immutable
class PotWorkSection {
  const PotWorkSection({
    this.intro = '',
    this.description = '',
    this.responsibilities = const [],
  });

  factory PotWorkSection.fromJson(Object? json) => PotWorkSection(
    intro: str(field(json, 'intro')) ?? '',
    description: str(field(json, 'description')) ?? '',
    responsibilities: [
      for (final item in array(field(json, 'responsibilities')) ?? const [])
        PotResponsibility.fromJson(item),
    ],
  );

  final String intro;
  final String description;
  final List<PotResponsibility> responsibilities;

  Map<String, Object?> toJson() => {
    'intro': intro,
    'description': description,
    'responsibilities': [for (final r in responsibilities) r.toJson()],
  };
}

/// A source a pot observes.
@immutable
class ObserveScope {
  const ObserveScope({required this.kind, this.ref = '', this.lead = false});

  factory ObserveScope.fromJson(Object? json) => ObserveScope(
    kind: str(field(json, 'kind')) ?? '',
    ref: text(field(json, 'ref')) ?? '',
    lead: field(json, 'lead') == true,
  );

  /// `project`, `workspace`, `session`, `calendar` or `schedules`.
  final String kind;
  final String ref;
  final bool lead;

  Map<String, Object?> toJson() => {'kind': kind, 'ref': ref, 'lead': lead};
}

/// A workspace where a pot may open work.
@immutable
class WorkLocation {
  const WorkLocation({required this.workspaceId, this.access = 'read'});

  factory WorkLocation.fromJson(Object? json) => WorkLocation(
    workspaceId: str(field(json, 'workspaceId')) ?? '',
    access: str(field(json, 'access')) ?? 'read',
  );

  final String workspaceId;

  /// `read` or `write`.
  final String access;

  Map<String, Object?> toJson() => {
    'workspaceId': workspaceId,
    'access': access,
  };
}

/// Who a pot may message and hear from.
@immutable
class DmRules {
  const DmRules({
    this.send = 'all',
    this.receive = 'all',
    this.sendTo = const [],
    this.receiveFrom = const [],
  });

  factory DmRules.fromJson(Object? json) => DmRules(
    send: str(field(json, 'send')) ?? 'all',
    receive: str(field(json, 'receive')) ?? 'all',
    sendTo: _strings(field(json, 'sendTo')),
    receiveFrom: _strings(field(json, 'receiveFrom')),
  );

  /// `all`, `selected` or `off`.
  final String send;
  final String receive;

  /// Pot IDs, used when [send] is `selected`.
  final List<String> sendTo;

  /// Pot IDs, used when [receive] is `selected`.
  final List<String> receiveFrom;

  Map<String, Object?> toJson() => {
    'send': send,
    'receive': receive,
    'sendTo': sendTo,
    'receiveFrom': receiveFrom,
  };
}

/// What a pot may do: the third step of the design.
@immutable
class PotPermissions {
  const PotPermissions({
    this.reach = 'answer',
    this.observe = const [],
    this.dm = const DmRules(),
    this.workLocations = const [],
    this.maxConcurrentWorks = 2,
    this.budgetMoneyMonthMicros = 20000000,
    this.budgetTokensDay = 2000000,
  });

  factory PotPermissions.fromJson(Object? json) => PotPermissions(
    reach: str(field(json, 'reach')) ?? 'answer',
    observe: [
      for (final scope in array(field(json, 'observe')) ?? const [])
        ObserveScope.fromJson(scope),
    ],
    dm: DmRules.fromJson(field(json, 'dm')),
    workLocations: [
      for (final location in array(field(json, 'workLocations')) ?? const [])
        WorkLocation.fromJson(location),
    ],
    maxConcurrentWorks: number(field(json, 'maxConcurrentWorks')) ?? 0,
    budgetMoneyMonthMicros: number(field(json, 'budgetMoneyMonthMicros')),
    budgetTokensDay: number(field(json, 'budgetTokensDay')),
  );

  /// `answer`, `observe` or `work`.
  final String reach;
  final List<ObserveScope> observe;
  final DmRules dm;
  final List<WorkLocation> workLocations;
  final int maxConcurrentWorks;

  /// Money per month in micro-dollars; null turns the limit off (step 0).
  final int? budgetMoneyMonthMicros;

  /// Tokens per day; null turns the limit off (step 0).
  final int? budgetTokensDay;

  Map<String, Object?> toJson() => {
    'reach': reach,
    'observe': [for (final scope in observe) scope.toJson()],
    'dm': dm.toJson(),
    'workLocations': [for (final location in workLocations) location.toJson()],
    'maxConcurrentWorks': maxConcurrentWorks,
    'budgetMoneyMonthMicros': budgetMoneyMonthMicros,
    'budgetTokensDay': budgetTokensDay,
  };
}

/// A model by provider and model ID.
@immutable
class PotModelChoice {
  const PotModelChoice({required this.provider, required this.model});

  factory PotModelChoice.fromJson(Object? json) => PotModelChoice(
    provider: str(field(json, 'provider')) ?? '',
    model: text(field(json, 'model')) ?? '',
  );

  final String provider;
  final String model;

  Map<String, Object?> toJson() => {'provider': provider, 'model': model};
}

/// A model a pot may open work with.
@immutable
class PotWorkModel {
  const PotWorkModel({
    required this.provider,
    required this.model,
    this.mode = 'direct',
  });

  factory PotWorkModel.fromJson(Object? json) => PotWorkModel(
    provider: str(field(json, 'provider')) ?? '',
    model: text(field(json, 'model')) ?? '',
    mode: str(field(json, 'mode')) ?? 'direct',
  );

  final String provider;
  final String model;

  /// `direct`, or `ask` when each start needs the user's approval.
  final String mode;

  Map<String, Object?> toJson() => {
    'provider': provider,
    'model': model,
    'mode': mode,
  };
}

/// The models a pot uses: the fourth step of the design.
@immutable
class PotModels {
  const PotModels({
    required this.main,
    this.fallbacks = const [],
    this.thinking = 'medium',
    this.thinkingAuto = false,
    this.workModels = const [],
  });

  factory PotModels.fromJson(Object? json) => PotModels(
    main: PotModelChoice.fromJson(field(json, 'main')),
    fallbacks: [
      for (final choice in array(field(json, 'fallbacks')) ?? const [])
        PotModelChoice.fromJson(choice),
    ],
    thinking: str(field(json, 'thinking')) ?? 'medium',
    thinkingAuto: field(json, 'thinkingAuto') == true,
    workModels: [
      for (final model in array(field(json, 'workModels')) ?? const [])
        PotWorkModel.fromJson(model),
    ],
  );

  final PotModelChoice main;
  final List<PotModelChoice> fallbacks;

  /// A thinking level (`off`, `minimal` … `xhigh`, `max`).
  final String thinking;

  /// "Adjust by itself".
  final bool thinkingAuto;
  final List<PotWorkModel> workModels;

  Map<String, Object?> toJson() => {
    'main': main.toJson(),
    'fallbacks': [for (final choice in fallbacks) choice.toJson()],
    'thinking': thinking,
    'thinkingAuto': thinkingAuto,
    'workModels': [for (final model in workModels) model.toJson()],
  };
}

/// How often a pot reviews its own work.
@immutable
class PotAutonomy {
  const PotAutonomy({this.intervalS = 172800});

  factory PotAutonomy.fromJson(Object? json) =>
      PotAutonomy(intervalS: number(field(json, 'intervalS')));

  /// Seconds between reviews; null turns reviews off.
  final int? intervalS;

  Map<String, Object?> toJson() => {'intervalS': intervalS};
}

/// Everything a pot is created with (`POST /api/pots`).
@immutable
class PotInput {
  const PotInput({
    required this.profile,
    required this.work,
    required this.permissions,
    required this.models,
    this.autonomy = const PotAutonomy(),
  });

  final PotProfile profile;
  final PotWorkSection work;
  final PotPermissions permissions;
  final PotModels models;
  final PotAutonomy autonomy;

  Map<String, Object?> toJson() => {
    'profile': profile.toJson(),
    'work': work.toJson(),
    'permissions': permissions.toJson(),
    'models': models.toJson(),
    'autonomy': autonomy.toJson(),
  };
}

/// A whole pot (`GET /api/pots/{id}`).
@immutable
class Pot {
  const Pot({
    required this.id,
    required this.profile,
    required this.work,
    required this.permissions,
    required this.models,
    this.autonomy = const PotAutonomy(),
    this.state = 'active',
    this.revision = 0,
    this.createdAt = 0,
    this.updatedAt = 0,
    this.sessionId,
    this.status = 'idle',
    this.needsYou = 0,
    this.budgetLeft,
  });

  factory Pot.fromJson(Object? json) => Pot(
    id: text(field(json, 'id')) ?? '',
    profile: PotProfile.fromJson(field(json, 'profile')),
    work: PotWorkSection.fromJson(field(json, 'work')),
    permissions: PotPermissions.fromJson(field(json, 'permissions')),
    models: PotModels.fromJson(field(json, 'models')),
    autonomy: PotAutonomy.fromJson(field(json, 'autonomy')),
    state: str(field(json, 'state')) ?? 'active',
    revision: number(field(json, 'revision')) ?? 0,
    createdAt: number(field(json, 'createdAt')) ?? 0,
    updatedAt: number(field(json, 'updatedAt')) ?? 0,
    sessionId: text(field(json, 'sessionId')),
    status: str(field(json, 'status')) ?? 'idle',
    needsYou: number(field(json, 'needsYou')) ?? 0,
    budgetLeft: BudgetLeft.fromJson(field(json, 'budgetLeft')),
  );

  final String id;
  final PotProfile profile;
  final PotWorkSection work;
  final PotPermissions permissions;
  final PotModels models;
  final PotAutonomy autonomy;

  /// `active`, `paused` or `archived`.
  final String state;

  /// Sent back with every change; a stale one is answered 409.
  final int revision;
  final int createdAt;
  final int updatedAt;
  final String? sessionId;

  /// `working`, `idle` or `unavailable` (provisional, step 0).
  final String status;

  /// Provisional, step 0.
  final int needsYou;

  /// Provisional, step 0.
  final BudgetLeft? budgetLeft;

  String get name => profile.name;

  PotInput get input => PotInput(
    profile: profile,
    work: work,
    permissions: permissions,
    models: models,
    autonomy: autonomy,
  );
}

/// The owner's limits for all pots (`/api/pots/settings`). A change sends
/// every field back with [revision].
@immutable
class PotSettings {
  const PotSettings({
    this.capMoneyMonthMicros = 0,
    this.capTokensDay = 0,
    this.onExhausted = 'ask',
    this.activityRetentionDays = 90,
    this.countSubscriptionMoney = false,
    this.loopDepth = 0,
    this.loopFanout = 0,
    this.loopNoProgressWakes = 0,
    this.loopNoProgressMessages = 0,
    this.loopPairMessagesMinute = 0,
    this.loopPairMessagesHour = 0,
    this.loopRootWakesMinute = 0,
    this.handbackCooldownS = 0,
    this.revision = 0,
  });

  factory PotSettings.fromJson(Object? json) => PotSettings(
    capMoneyMonthMicros: number(field(json, 'capMoneyMonthMicros')) ?? 0,
    capTokensDay: number(field(json, 'capTokensDay')) ?? 0,
    onExhausted: str(field(json, 'onExhausted')) ?? 'ask',
    activityRetentionDays: number(field(json, 'activityRetentionDays')) ?? 90,
    countSubscriptionMoney: field(json, 'countSubscriptionMoney') == true,
    loopDepth: number(field(json, 'loopDepth')) ?? 0,
    loopFanout: number(field(json, 'loopFanout')) ?? 0,
    loopNoProgressWakes: number(field(json, 'loopNoProgressWakes')) ?? 0,
    loopNoProgressMessages: number(field(json, 'loopNoProgressMessages')) ?? 0,
    loopPairMessagesMinute: number(field(json, 'loopPairMessagesMinute')) ?? 0,
    loopPairMessagesHour: number(field(json, 'loopPairMessagesHour')) ?? 0,
    loopRootWakesMinute: number(field(json, 'loopRootWakesMinute')) ?? 0,
    handbackCooldownS: number(field(json, 'handbackCooldownS')) ?? 0,
    revision: number(field(json, 'revision')) ?? 0,
  );

  /// Owner-wide money cap per month in micro-dollars; 0 means no cap.
  final int capMoneyMonthMicros;

  /// Owner-wide token cap per day; 0 means no cap.
  final int capTokensDay;

  /// `pause_all` or `ask`.
  final String onExhausted;
  final int activityRetentionDays;
  final bool countSubscriptionMoney;
  final int loopDepth;
  final int loopFanout;
  final int loopNoProgressWakes;
  final int loopNoProgressMessages;
  final int loopPairMessagesMinute;
  final int loopPairMessagesHour;
  final int loopRootWakesMinute;
  final int handbackCooldownS;
  final int revision;

  PotSettings copyWith({
    int? capMoneyMonthMicros,
    int? capTokensDay,
    String? onExhausted,
    int? activityRetentionDays,
    bool? countSubscriptionMoney,
  }) => PotSettings(
    capMoneyMonthMicros: capMoneyMonthMicros ?? this.capMoneyMonthMicros,
    capTokensDay: capTokensDay ?? this.capTokensDay,
    onExhausted: onExhausted ?? this.onExhausted,
    activityRetentionDays: activityRetentionDays ?? this.activityRetentionDays,
    countSubscriptionMoney:
        countSubscriptionMoney ?? this.countSubscriptionMoney,
    loopDepth: loopDepth,
    loopFanout: loopFanout,
    loopNoProgressWakes: loopNoProgressWakes,
    loopNoProgressMessages: loopNoProgressMessages,
    loopPairMessagesMinute: loopPairMessagesMinute,
    loopPairMessagesHour: loopPairMessagesHour,
    loopRootWakesMinute: loopRootWakesMinute,
    handbackCooldownS: handbackCooldownS,
    revision: revision,
  );

  Map<String, Object?> toJson() => {
    'capMoneyMonthMicros': capMoneyMonthMicros,
    'capTokensDay': capTokensDay,
    'onExhausted': onExhausted,
    'activityRetentionDays': activityRetentionDays,
    'countSubscriptionMoney': countSubscriptionMoney,
    'loopDepth': loopDepth,
    'loopFanout': loopFanout,
    'loopNoProgressWakes': loopNoProgressWakes,
    'loopNoProgressMessages': loopNoProgressMessages,
    'loopPairMessagesMinute': loopPairMessagesMinute,
    'loopPairMessagesHour': loopPairMessagesHour,
    'loopRootWakesMinute': loopRootWakesMinute,
    'handbackCooldownS': handbackCooldownS,
    'revision': revision,
  };
}

/// Something a pot holds (`GET /api/pots/{id}/held`).
@immutable
class HeldItem {
  const HeldItem({required this.kind, required this.ref, this.label = ''});

  factory HeldItem.fromJson(Object? json) => HeldItem(
    kind: str(field(json, 'kind')) ?? '',
    ref: text(field(json, 'ref')) ?? '',
    label: str(field(json, 'label')) ?? '',
  );

  /// `responsibility`, `reminder`, `work` or `group_host`.
  final String kind;
  final String ref;
  final String label;

  /// The `{ kind, ref }` a handover or retire request names.
  Map<String, Object?> toRef() => {'kind': kind, 'ref': ref};
}

/// One of a pot's own notes.
@immutable
class PotNote {
  const PotNote({
    required this.id,
    required this.content,
    this.revision = 0,
    this.createdAt = 0,
    this.updatedAt = 0,
  });

  factory PotNote.fromJson(Object? json) => PotNote(
    id: text(field(json, 'id')) ?? '',
    content: str(field(json, 'content')) ?? '',
    revision: number(field(json, 'revision')) ?? 0,
    createdAt: number(field(json, 'createdAt')) ?? 0,
    updatedAt: number(field(json, 'updatedAt')) ?? 0,
  );

  final String id;
  final String content;
  final int revision;
  final int createdAt;
  final int updatedAt;
}

/// A pot's memory: its notes, oldest first, and its size limit in characters.
@immutable
class PotMemory {
  const PotMemory({this.notes = const [], this.budget = 0});

  factory PotMemory.fromJson(Object? json) => PotMemory(
    notes: [
      for (final note in array(field(json, 'notes')) ?? const [])
        PotNote.fromJson(note),
    ],
    budget: number(field(json, 'budget')) ?? 0,
  );

  final List<PotNote> notes;
  final int budget;
}

/// Where one held item goes when a pot retires.
@immutable
class RetireTarget {
  const RetireTarget({required this.item, required this.to});

  final HeldItem item;

  /// A pot, the user, or [HandoverTo.none] to drop it.
  final HandoverTo to;

  Map<String, Object?> toJson() => {...item.toRef(), 'to': to.toJson()};
}

/// One held item in a retire preview.
@immutable
class RetireItem {
  const RetireItem({
    required this.item,
    required this.to,
    this.fit = 'ok',
    this.reason,
  });

  factory RetireItem.fromJson(Object? json) => RetireItem(
    item: HeldItem.fromJson(json),
    to: HandoverTo.fromJson(field(json, 'to')),
    fit: str(field(json, 'fit')) ?? 'ok',
    reason: str(field(json, 'reason')),
  );

  final HeldItem item;
  final HandoverTo to;

  /// `ok`, `narrowed` or `stop`.
  final String fit;
  final String? reason;
}

/// What retiring a pot would do (`POST /api/pots/{id}/retire/preview`).
@immutable
class RetirePreview {
  const RetirePreview({
    required this.mode,
    this.revision = 0,
    this.items = const [],
    this.stops = const [],
    this.kept = const [],
  });

  factory RetirePreview.fromJson(Object? json) => RetirePreview(
    mode: str(field(json, 'mode')) ?? '',
    revision: number(field(json, 'revision')) ?? 0,
    items: [
      for (final item in array(field(json, 'items')) ?? const [])
        RetireItem.fromJson(item),
    ],
    stops: _strings(field(json, 'stops')),
    kept: _strings(field(json, 'kept')),
  );

  /// `archive` or `delete`.
  final String mode;

  /// The pot's revision, to send with the retire request.
  final int revision;
  final List<RetireItem> items;

  /// What will stop, one sentence each.
  final List<String> stops;

  /// What is kept, one sentence each.
  final List<String> kept;
}

/// The result of retiring a pot: the archived pot, or [deleted].
@immutable
class RetireResult {
  const RetireResult({
    this.pot,
    this.deleted = false,
    this.handovers = const [],
  });

  factory RetireResult.fromJson(Object? json) => RetireResult(
    pot: field(json, 'pot') is Map ? Pot.fromJson(field(json, 'pot')) : null,
    deleted: field(json, 'deleted') == true,
    handovers: [
      for (final handover in array(field(json, 'handovers')) ?? const [])
        Handover.fromJson(handover),
    ],
  );

  /// The archived pot; null after a delete.
  final Pot? pot;
  final bool deleted;

  /// The handovers that moved its items.
  final List<Handover> handovers;
}

/// A work session a pot opened (`GET /api/pot-works`).
@immutable
class PotWork {
  const PotWork({
    required this.id,
    required this.potId,
    required this.sessionId,
    required this.workspaceId,
    required this.title,
    this.provider,
    this.model,
    this.thinking,
    this.causalRoot,
    this.state = 'open',
    this.createdAt = 0,
  });

  factory PotWork.fromJson(Object? json) => PotWork(
    id: text(field(json, 'id')) ?? '',
    potId: text(field(json, 'potId')) ?? '',
    sessionId: text(field(json, 'sessionId')) ?? '',
    workspaceId: str(field(json, 'workspaceId')) ?? '',
    title: str(field(json, 'title')) ?? '',
    provider: str(field(json, 'provider')),
    model: str(field(json, 'model')),
    thinking: str(field(json, 'thinking')),
    causalRoot: text(field(json, 'causalRoot')),
    state: str(field(json, 'state')) ?? 'open',
    createdAt: number(field(json, 'createdAt')) ?? 0,
  );

  final String id;
  final String potId;
  final String sessionId;
  final String workspaceId;
  final String title;
  final String? provider;
  final String? model;
  final String? thinking;

  /// The causal root that started the work.
  final String? causalRoot;

  /// `open` while the pot coordinates it; `taken_over` after the user took
  /// it over.
  final String state;
  final int createdAt;

  bool get open => state == 'open';
}

/// A pot's request to use a "ask you first" model (`/api/model-approvals`).
@immutable
class ModelApproval {
  const ModelApproval({
    required this.id,
    required this.potId,
    required this.workTitle,
    required this.workspaceId,
    required this.model,
    this.provider,
    this.thinking,
    this.reason = '',
    this.estimateMicros = 0,
    this.remainingMicros,
    this.state = 'pending',
    this.denyReason,
    this.createdAt = 0,
    this.answeredAt,
    this.usedAt,
  });

  factory ModelApproval.fromJson(Object? json) => ModelApproval(
    id: text(field(json, 'id')) ?? '',
    potId: text(field(json, 'potId')) ?? '',
    workTitle: str(field(json, 'workTitle')) ?? '',
    workspaceId: str(field(json, 'workspaceId')) ?? '',
    model: str(field(json, 'model')) ?? '',
    provider: str(field(json, 'provider')),
    thinking: str(field(json, 'thinking')),
    reason: str(field(json, 'reason')) ?? '',
    estimateMicros: number(field(json, 'estimateMicros')) ?? 0,
    remainingMicros: number(field(json, 'remainingMicros')),
    state: str(field(json, 'state')) ?? 'pending',
    denyReason: str(field(json, 'denyReason')),
    createdAt: number(field(json, 'createdAt')) ?? 0,
    answeredAt: number(field(json, 'answeredAt')),
    usedAt: number(field(json, 'usedAt')),
  );

  final String id;
  final String potId;
  final String workTitle;
  final String workspaceId;
  final String model;
  final String? provider;
  final String? thinking;
  final String reason;

  /// The estimated cost of the work, in micro-dollars.
  final int estimateMicros;

  /// The pot's money left, in micro-dollars; null when it has no limit.
  final int? remainingMicros;

  /// `pending`, `allowed_once`, `denied` or `used`.
  final String state;

  /// The user's reason when denied.
  final String? denyReason;
  final int createdAt;
  final int? answeredAt;
  final int? usedAt;

  bool get pending => state == 'pending';
}

/// Pots, the works they open and their model approvals.
class PotsApi {
  const PotsApi(this.api);
  final ApiClient api;

  static String path(String id) => '/api/pots/${Uri.encodeComponent(id)}';

  Future<List<PotSummary>> pots() async => [
    for (final pot
        in array(field(await api.get('/api/pots'), 'pots')) ?? const [])
      PotSummary.fromJson(pot),
  ];

  /// Every pot in full, archived ones included.
  Future<List<Pot>> list() async => [
    for (final pot
        in array(field(await api.get('/api/pots'), 'pots')) ?? const [])
      Pot.fromJson(pot),
  ];

  Future<Pot> create(PotInput input) async =>
      Pot.fromJson(field(await api.post('/api/pots', input.toJson()), 'pot'));

  Future<Pot> read(String id) async =>
      Pot.fromJson(field(await api.get(path(id)), 'pot'));

  /// Replaces each given section whole. A stale [revision] is answered 409.
  Future<Pot> update(
    String id, {
    required int revision,
    PotProfile? profile,
    PotWorkSection? work,
    PotPermissions? permissions,
    PotModels? models,
    PotAutonomy? autonomy,
  }) async => Pot.fromJson(
    field(
      await api.patch(path(id), {
        'revision': revision,
        'profile': ?profile?.toJson(),
        'work': ?work?.toJson(),
        'permissions': ?permissions?.toJson(),
        'models': ?models?.toJson(),
        'autonomy': ?autonomy?.toJson(),
      }),
      'pot',
    ),
  );

  Future<Pot> pause(String id, {required int revision}) =>
      _transition(id, 'pause', revision);

  Future<Pot> resume(String id, {required int revision}) =>
      _transition(id, 'resume', revision);

  /// Brings an archived pot back, paused.
  Future<Pot> restore(String id, {required int revision}) =>
      _transition(id, 'restore', revision);

  Future<Pot> _transition(String id, String action, int revision) async =>
      Pot.fromJson(
        field(
          await api.post('${path(id)}/$action', {'revision': revision}),
          'pot',
        ),
      );

  /// Responsibilities, pending reminders, works and groups it hosts.
  Future<List<HeldItem>> held(String id) async => [
    for (final item
        in array(field(await api.get('${path(id)}/held'), 'items')) ?? const [])
      HeldItem.fromJson(item),
  ];

  Future<PotMemory> memory(String id) async =>
      PotMemory.fromJson(await api.get('${path(id)}/memory'));

  Future<void> forget(String id, String entryId) =>
      api.delete('${path(id)}/memory/${Uri.encodeComponent(entryId)}');

  /// [mode] is `archive` or `delete`. Items without a target go nowhere.
  Future<RetirePreview> retirePreview(
    String id, {
    required String mode,
    List<RetireTarget> targets = const [],
  }) async => RetirePreview.fromJson(
    await api.post('${path(id)}/retire/preview', {
      'mode': mode,
      'targets': [for (final target in targets) target.toJson()],
    }),
  );

  /// Archives or deletes the pot after handing over its items.
  Future<RetireResult> retire(
    String id, {
    required String mode,
    required int revision,
    List<RetireTarget> targets = const [],
  }) async => RetireResult.fromJson(
    await api.post('${path(id)}/retire', {
      'mode': mode,
      'revision': revision,
      'targets': [for (final target in targets) target.toJson()],
    }),
  );

  Future<PotSettings> settings() async => PotSettings.fromJson(
    field(await api.get('/api/pots/settings'), 'settings'),
  );

  /// Saves every field of [settings] with its revision.
  Future<PotSettings> updateSettings(PotSettings settings) async =>
      PotSettings.fromJson(
        field(
          await api.patch('/api/pots/settings', settings.toJson()),
          'settings',
        ),
      );

  /// The works pots opened, newest first; [potId] keeps one pot's.
  Future<List<PotWork>> works({String? potId}) async => [
    for (final work
        in array(
              field(
                await api.get('/api/pot-works', query: {'potId': ?potId}),
                'works',
              ),
            ) ??
            const [])
      PotWork.fromJson(work),
  ];

  Future<PotWork> work(String id) async => PotWork.fromJson(
    field(await api.get('/api/pot-works/${Uri.encodeComponent(id)}'), 'work'),
  );

  /// Takes the work over: the pot sends no more instructions to it.
  Future<PotWork> takeOver(String workId) async => PotWork.fromJson(
    field(
      await api.post('/api/pot-works/${Uri.encodeComponent(workId)}/take-over'),
      'work',
    ),
  );

  /// The same list as [DecisionsApi.approvals].
  Future<List<ModelApproval>> approvals({String? state}) =>
      DecisionsApi(api).approvals(state: state);
}
