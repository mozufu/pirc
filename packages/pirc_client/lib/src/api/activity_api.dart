import 'package:meta/meta.dart';

import '../api_client.dart';
import '../json.dart';
import 'threads_api.dart';

List<String> _strings(Object? json) => [
  for (final item in array(json) ?? const []) ?text(item),
];

/// Who a pot acted toward.
@immutable
class ActivityCounterpart {
  const ActivityCounterpart({required this.kind, this.id});

  factory ActivityCounterpart.fromJson(Object? json) => ActivityCounterpart(
    kind: str(field(json, 'kind')) ?? '',
    id: text(field(json, 'id')),
  );

  /// `user`, `pot`, `work_session`, `workspace` or `system`.
  final String kind;
  final String? id;
}

/// What an activity row points at.
@immutable
class ActivityRefs {
  const ActivityRefs({
    this.thread,
    this.message,
    this.session,
    this.approval,
    this.handover,
    this.budget,
    this.root,
  });

  factory ActivityRefs.fromJson(Object? json) => ActivityRefs(
    thread: text(field(json, 'thread')),
    message: text(field(json, 'message')),
    session: text(field(json, 'session')),
    approval: text(field(json, 'approval')),
    handover: text(field(json, 'handover')),
    budget: text(field(json, 'budget')),
    root: text(field(json, 'root')),
  );

  final String? thread;
  final String? message;
  final String? session;
  final String? approval;
  final String? handover;

  /// A budget request ID, or the key of a used-up window.
  final String? budget;

  /// A causal root ID.
  final String? root;
}

/// One thing a pot did (`GET /api/activity`).
@immutable
class ActivityEntry {
  const ActivityEntry({
    required this.id,
    required this.kind,
    this.potId,
    this.potName = '',
    this.potAvatarColor = 1,
    this.at = 0,
    this.counterpart,
    this.summary = '',
    this.refs = const ActivityRefs(),
    this.causalRoot,
  });

  factory ActivityEntry.fromJson(Object? json) => ActivityEntry(
    id: text(field(json, 'id')) ?? '',
    kind: str(field(json, 'kind')) ?? '',
    potId: text(field(json, 'potId')),
    potName: str(field(json, 'potName')) ?? '',
    potAvatarColor: number(field(json, 'potAvatarColor')) ?? 1,
    at: number(field(json, 'at')) ?? 0,
    counterpart: field(json, 'counterpart') is Map
        ? ActivityCounterpart.fromJson(field(json, 'counterpart'))
        : null,
    summary: str(field(json, 'summary')) ?? '',
    refs: ActivityRefs.fromJson(field(json, 'refs')),
    causalRoot: text(field(json, 'causalRoot')),
  );

  final String id;

  /// `created`, `dm`, `work_opened`, `loop_guard` and so on.
  final String kind;

  /// Null once the pot is deleted; its name and colour remain.
  final String? potId;
  final String potName;
  final int potAvatarColor;

  /// Epoch milliseconds.
  final int at;
  final ActivityCounterpart? counterpart;
  final String summary;
  final ActivityRefs refs;
  final String? causalRoot;
}

/// A page of activity, newest first.
@immutable
class ActivityPage {
  const ActivityPage({this.entries = const [], this.nextBefore});

  factory ActivityPage.fromJson(Object? json) => ActivityPage(
    entries: [
      for (final entry in array(field(json, 'activity')) ?? const [])
        ActivityEntry.fromJson(entry),
    ],
    nextBefore: text(field(json, 'nextBefore')),
  );

  final List<ActivityEntry> entries;

  /// Pass as `before` for the next, older page; null on the last page.
  final String? nextBefore;
}

/// An instruction a pot sent into a work session.
///
/// Provisional: `instructions` comes with M7 step 0.
@immutable
class SentInstruction {
  const SentInstruction({
    this.id = '',
    this.workId = '',
    this.workTitle = '',
    this.sessionId = '',
    this.body = '',
    this.state,
    this.createdAt = 0,
  });

  factory SentInstruction.fromJson(Object? json) => SentInstruction(
    id: text(field(json, 'id')) ?? '',
    workId: text(field(json, 'workId')) ?? '',
    workTitle: str(field(json, 'workTitle')) ?? str(field(json, 'title')) ?? '',
    sessionId: text(field(json, 'sessionId')) ?? '',
    body: str(field(json, 'body')) ?? str(field(json, 'text')) ?? '',
    state: str(field(json, 'state')),
    createdAt: number(field(json, 'createdAt')) ?? 0,
  );

  final String id;
  final String workId;
  final String workTitle;

  /// The work session, to open its conversation.
  final String sessionId;
  final String body;
  final String? state;
  final int createdAt;
}

/// A pot's point of view, read only (`GET /api/pots/{id}/view`).
@immutable
class PotView {
  const PotView({
    required this.potId,
    this.threads = const [],
    this.sent = const [],
    this.instructions = const [],
    this.nextBefore,
  });

  factory PotView.fromJson(Object? json) => PotView(
    potId: text(field(json, 'potId')) ?? '',
    threads: [
      for (final thread in array(field(json, 'threads')) ?? const [])
        PotThread.fromJson(thread),
    ],
    sent: [
      for (final message in array(field(json, 'sent')) ?? const [])
        ThreadMessage.fromJson(message),
    ],
    instructions: [
      for (final item in array(field(json, 'instructions')) ?? const [])
        SentInstruction.fromJson(item),
    ],
    nextBefore: text(field(json, 'nextBefore')),
  );

  final String potId;

  /// The threads it is in.
  final List<PotThread> threads;

  /// Messages it wrote, newest first.
  final List<ThreadMessage> sent;

  /// Newest first (provisional, step 0).
  final List<SentInstruction> instructions;

  /// A message ID to pass as `before` for older messages; null on the last
  /// page.
  final String? nextBefore;
}

/// One pot's note attached to a notification.
@immutable
class NotedBy {
  const NotedBy({
    required this.potId,
    this.potName = '',
    this.note = '',
    this.evidence = const [],
    this.createdAt = 0,
  });

  factory NotedBy.fromJson(Object? json) => NotedBy(
    potId: text(field(json, 'potId')) ?? '',
    potName: str(field(json, 'potName')) ?? '',
    note: str(field(json, 'note')) ?? '',
    evidence: _strings(field(json, 'evidence')),
    createdAt: number(field(json, 'createdAt')) ?? 0,
  );

  final String potId;
  final String potName;
  final String note;
  final List<String> evidence;
  final int createdAt;
}

/// What pots noticed on a source they observe
/// (`/api/observation-notifications`).
@immutable
class ObservationNotification {
  const ObservationNotification({
    required this.id,
    this.eventId = '',
    this.sourceKind = '',
    this.sourceRef = '',
    this.condition = '',
    this.issuerPotId,
    this.observations = const [],
    this.state = 'open',
    this.createdAt = 0,
    this.updatedAt = 0,
  });

  factory ObservationNotification.fromJson(Object? json) =>
      ObservationNotification(
        id: text(field(json, 'id')) ?? '',
        eventId: text(field(json, 'eventId')) ?? '',
        sourceKind: str(field(json, 'sourceKind')) ?? '',
        sourceRef: text(field(json, 'sourceRef')) ?? '',
        condition: str(field(json, 'condition')) ?? '',
        issuerPotId: text(field(json, 'issuerPotId')),
        observations: [
          for (final note in array(field(json, 'observations')) ?? const [])
            NotedBy.fromJson(note),
        ],
        state: str(field(json, 'state')) ?? 'open',
        createdAt: number(field(json, 'createdAt')) ?? 0,
        updatedAt: number(field(json, 'updatedAt')) ?? 0,
      );

  final String id;
  final String eventId;

  /// `session`, `workspace`, `project`, `schedules` or `calendar`.
  final String sourceKind;
  final String sourceRef;
  final String condition;

  /// The lead pot that told the user; null when the notes were merged.
  final String? issuerPotId;
  final List<NotedBy> observations;

  /// `open` or `read`.
  final String state;
  final int createdAt;
  final int updatedAt;

  bool get open => state == 'open';
}

/// `/api/activity`, a pot's point of view and observation notifications.
class ActivityApi {
  const ActivityApi(this.api);
  final ApiClient api;

  /// Newest first. [kinds] are joined with commas; [since] is inclusive and
  /// [until] exclusive (epoch ms); [before] is the previous page's
  /// [ActivityPage.nextBefore].
  Future<ActivityPage> activity({
    String? potId,
    List<String> kinds = const [],
    int? since,
    int? until,
    String? before,
    int? limit,
  }) async => ActivityPage.fromJson(
    await api.get(
      '/api/activity',
      query: {
        'potId': ?potId,
        if (kinds.isNotEmpty) 'kind': kinds.join(','),
        'since': ?since?.toString(),
        'until': ?until?.toString(),
        'before': ?before,
        'limit': ?limit?.toString(),
      },
    ),
  );

  /// [before] is the previous page's [PotView.nextBefore].
  Future<PotView> view(String potId, {String? before}) async =>
      PotView.fromJson(
        await api.get(
          '/api/pots/${Uri.encodeComponent(potId)}/view',
          query: {'before': ?before},
        ),
      );

  /// Newest first; [state] is `open` or `read`.
  Future<List<ObservationNotification>> notifications({String? state}) async {
    assert(state == null || state == 'open' || state == 'read');
    return [
      for (final notification
          in array(
                field(
                  await api.get(
                    '/api/observation-notifications',
                    query: {'state': ?state},
                  ),
                  'notifications',
                ),
              ) ??
              const [])
        ObservationNotification.fromJson(notification),
    ];
  }

  Future<ObservationNotification> markNotificationRead(String id) async =>
      ObservationNotification.fromJson(
        field(
          await api.post(
            '/api/observation-notifications/${Uri.encodeComponent(id)}/read',
          ),
          'notification',
        ),
      );
}
