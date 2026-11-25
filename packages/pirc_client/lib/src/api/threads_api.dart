import 'package:meta/meta.dart';

import '../api_client.dart';
import '../json.dart';

/// The newest message of a thread, as the chat list shows it.
///
/// Provisional: the Gateway adds `lastMessage` in M7 step 0.
@immutable
class ThreadLastMessage {
  const ThreadLastMessage({
    this.authorKind = '',
    this.authorId,
    this.authorName,
    this.firstLine = '',
    this.createdAt = 0,
  });

  factory ThreadLastMessage.fromJson(Object? json) => ThreadLastMessage(
    authorKind: str(field(json, 'authorKind')) ?? '',
    authorId: text(field(json, 'authorId')),
    authorName: str(field(json, 'authorName')),
    firstLine:
        str(field(json, 'firstLine')) ??
        str(field(json, 'body'))?.split('\n').first ??
        '',
    createdAt: number(field(json, 'createdAt')) ?? 0,
  );

  /// `user`, `pot` or `system`.
  final String authorKind;
  final String? authorId;

  /// A deleted pot's name.
  final String? authorName;
  final String firstLine;
  final int createdAt;
}

/// A conversation: a pot's direct thread, a group, or a DM between two pots.
@immutable
class PotThread {
  const PotThread({
    required this.id,
    required this.kind,
    this.name = '',
    this.avatarColor,
    this.avatarImage,
    this.hostPotId,
    this.projectId,
    this.pots = const [],
    this.lastSeq = 0,
    this.updatedAt = 0,
    this.revision = 0,
    this.unread = 0,
    this.lastMessage,
  });

  factory PotThread.fromJson(Object? json) => PotThread(
    id: text(field(json, 'id')) ?? '',
    kind: str(field(json, 'kind')) ?? '',
    name: str(field(json, 'name')) ?? '',
    avatarColor: number(field(json, 'avatarColor')),
    avatarImage: str(field(json, 'avatarImage')),
    hostPotId: text(field(json, 'hostPotId')),
    projectId: text(field(json, 'projectId')),
    pots: [
      for (final pot in array(field(json, 'pots')) ?? const []) ?text(pot),
    ],
    lastSeq: number(field(json, 'lastSeq')) ?? 0,
    updatedAt: number(field(json, 'updatedAt')) ?? 0,
    revision: number(field(json, 'revision')) ?? 0,
    unread: number(field(json, 'unread')) ?? 0,
    lastMessage: field(json, 'lastMessage') is Map
        ? ThreadLastMessage.fromJson(field(json, 'lastMessage'))
        : null,
  );

  final String id;

  /// `direct`, `group` or `pot_dm`.
  final String kind;

  /// A group's name, or a deleted pot's name on its old threads.
  final String name;

  /// A group's colour, 1–5.
  final int? avatarColor;

  /// A group's image ID (provisional, step 0).
  final String? avatarImage;
  final String? hostPotId;
  final String? projectId;

  /// The member pots: the direct thread's pot, a DM's two, a group's members.
  final List<String> pots;
  final int lastSeq;
  final int updatedAt;

  /// Sent back with a group edit (provisional, step 0).
  final int revision;

  /// Messages after the read position (provisional, step 0).
  final int unread;

  /// Provisional, step 0.
  final ThreadLastMessage? lastMessage;

  bool get isDirect => kind == 'direct';
  bool get isGroup => kind == 'group';
  bool get isPotDm => kind == 'pot_dm';
}

/// What a system message points at. The item's own route has its state.
@immutable
sealed class ThreadCard {
  const ThreadCard();

  /// The card of a message, or null when it has none.
  static ThreadCard? fromJson(Object? json) {
    if (json is! Map) return null;
    String id(String key) => text(field(json, key)) ?? '';
    return switch (str(field(json, 'kind'))) {
      'model_approval' => ModelApprovalCard(id('approvalId')),
      'budget_request' => BudgetRequestCard(id('requestId')),
      'work' => WorkSessionCard(
        workId: id('workId'),
        sessionId: id('sessionId'),
      ),
      'handover' => HandoverCard(id('handoverId')),
      'loop_guard' => LoopGuardCard(id('rootId')),
      final kind => UnknownCard(kind ?? '', json.cast()),
    };
  }

  String get kind;
}

/// `GET /api/model-approvals/{approvalId}`.
final class ModelApprovalCard extends ThreadCard {
  const ModelApprovalCard(this.approvalId);
  final String approvalId;
  @override
  String get kind => 'model_approval';
}

/// `GET /api/budget-requests/{requestId}`.
final class BudgetRequestCard extends ThreadCard {
  const BudgetRequestCard(this.requestId);
  final String requestId;
  @override
  String get kind => 'budget_request';
}

/// `GET /api/pot-works/{workId}`; the work runs in [sessionId].
final class WorkSessionCard extends ThreadCard {
  const WorkSessionCard({required this.workId, required this.sessionId});
  final String workId;
  final String sessionId;
  @override
  String get kind => 'work';
}

/// `GET /api/handovers/{handoverId}`: a pot proposes a handover.
final class HandoverCard extends ThreadCard {
  const HandoverCard(this.handoverId);
  final String handoverId;
  @override
  String get kind => 'handover';
}

/// `GET /api/causal-roots/{rootId}`: the loop guard suspended the root.
final class LoopGuardCard extends ThreadCard {
  const LoopGuardCard(this.rootId);
  final String rootId;
  @override
  String get kind => 'loop_guard';
}

/// A card kind this client does not know; shown as a plain notice.
final class UnknownCard extends ThreadCard {
  const UnknownCard(this.kind, this.raw);
  @override
  final String kind;
  final Map<String, Object?> raw;
}

/// One message in a thread.
@immutable
class ThreadMessage {
  const ThreadMessage({
    required this.id,
    required this.threadId,
    required this.seq,
    required this.authorKind,
    this.authorId,
    this.authorName,
    this.body = '',
    this.mentions = const [],
    this.all = false,
    this.createdAt = 0,
    this.card,
  });

  factory ThreadMessage.fromJson(Object? json) => ThreadMessage(
    id: text(field(json, 'id')) ?? '',
    threadId: text(field(json, 'threadId')) ?? '',
    seq: number(field(json, 'seq')) ?? 0,
    authorKind: str(field(json, 'authorKind')) ?? '',
    authorId: text(field(json, 'authorId')),
    authorName: str(field(json, 'authorName')),
    body: str(field(json, 'body')) ?? '',
    mentions: [
      for (final pot in array(field(json, 'mentions')) ?? const []) ?text(pot),
    ],
    all: field(json, 'all') == true,
    createdAt: number(field(json, 'createdAt')) ?? 0,
    card: ThreadCard.fromJson(field(json, 'card')),
  );

  final String id;
  final String threadId;
  final int seq;

  /// `user`, `pot` or `system`.
  final String authorKind;

  /// The pot's ID when a pot wrote it; kept after the pot is deleted.
  final String? authorId;

  /// Set only when the author pot was deleted: its name.
  final String? authorName;
  final String body;

  /// Pot IDs the user mentioned.
  final List<String> mentions;

  /// The user woke every member.
  final bool all;
  final int createdAt;
  final ThreadCard? card;

  bool get fromUser => authorKind == 'user';
  bool get fromPot => authorKind == 'pot';
  bool get isSystem => authorKind == 'system';

  /// The author pot was deleted; show [authorName] instead of its profile.
  bool get authorDeleted => authorName != null;
}

/// A pot that a posted message did not wake, and why.
@immutable
class RefusedWake {
  const RefusedWake({required this.potId, this.code = '', this.reason = ''});

  factory RefusedWake.fromJson(Object? json) => RefusedWake(
    potId: text(field(json, 'potId')) ?? '',
    code: str(field(json, 'code')) ?? '',
    reason: str(field(json, 'reason')) ?? '',
  );

  final String potId;
  final String code;
  final String reason;
}

/// The answer to posting a message: it, the pots it woke, and those it did
/// not.
@immutable
class PostedMessage {
  const PostedMessage({
    required this.message,
    this.woken = const [],
    this.refused = const [],
  });

  factory PostedMessage.fromJson(Object? json) => PostedMessage(
    message: ThreadMessage.fromJson(field(json, 'message')),
    woken: [
      for (final pot in array(field(json, 'woken')) ?? const []) ?text(pot),
    ],
    refused: [
      for (final item in array(field(json, 'refused')) ?? const [])
        RefusedWake.fromJson(item),
    ],
  );

  final ThreadMessage message;
  final List<String> woken;
  final List<RefusedWake> refused;
}

/// `/api/threads`: conversations with and between pots.
class ThreadsApi {
  const ThreadsApi(this.api);
  final ApiClient api;

  static String path(String id) => '/api/threads/${Uri.encodeComponent(id)}';

  PotThread _thread(Object? reply) =>
      PotThread.fromJson(field(reply, 'thread'));

  Future<List<PotThread>> list() async => [
    for (final thread
        in array(field(await api.get('/api/threads'), 'threads')) ?? const [])
      PotThread.fromJson(thread),
  ];

  /// The pot's direct thread, made on first use.
  Future<PotThread> direct(String potId) async =>
      _thread(await api.get('/api/pots/${Uri.encodeComponent(potId)}/thread'));

  Future<PotThread> read(String id) async => _thread(await api.get(path(id)));

  /// A group of 2–16 member pots with a host among them.
  Future<PotThread> createGroup({
    required String name,
    required String hostPotId,
    required List<String> memberPotIds,
    int? avatarColor,
    String? avatarImage,
    String? projectId,
  }) async => _thread(
    await api.post('/api/threads', {
      'name': name,
      'hostPotId': hostPotId,
      'memberPotIds': memberPotIds,
      'avatarColor': ?avatarColor,
      'avatarImage': ?avatarImage,
      'projectId': ?projectId,
    }),
  );

  /// Edits a group. [removeAvatarImage] sends `avatarImage: null`.
  ///
  /// Provisional: the route comes with M7 step 0.
  Future<PotThread> update(
    String id, {
    required int revision,
    String? name,
    int? avatarColor,
    String? avatarImage,
    bool removeAvatarImage = false,
    String? hostPotId,
    List<String>? memberPotIds,
  }) async {
    assert(avatarImage == null || !removeAvatarImage);
    return _thread(
      await api.patch(path(id), {
        'revision': revision,
        'name': ?name,
        'avatarColor': ?avatarColor,
        if (removeAvatarImage)
          'avatarImage': null
        else
          'avatarImage': ?avatarImage,
        'hostPotId': ?hostPotId,
        'memberPotIds': ?memberPotIds,
      }),
    );
  }

  /// Deletes a group. Provisional: the route comes with M7 step 0.
  Future<void> delete(String id) => api.delete(path(id));

  /// Moves the read position to [seq]. Provisional, step 0.
  Future<void> markRead(String id, int seq) =>
      api.post('${path(id)}/read', {'seq': seq});

  /// 50 messages, newest last; [before] is a `seq` to page back from.
  Future<List<ThreadMessage>> messages(String id, {int? before}) async => [
    for (final message
        in array(
              field(
                await api.get(
                  '${path(id)}/messages',
                  query: {'before': ?before?.toString()},
                ),
                'messages',
              ),
            ) ??
            const [])
      ThreadMessage.fromJson(message),
  ];

  /// Posts as the user. In a group the host wakes, plus the [mentions]
  /// (pot IDs), or every member with [all].
  Future<PostedMessage> post(
    String id,
    String body, {
    List<String> mentions = const [],
    bool all = false,
  }) async => PostedMessage.fromJson(
    await api.post('${path(id)}/messages', {
      'body': body,
      if (mentions.isNotEmpty) 'mentions': mentions,
      if (all) 'all': true,
    }),
  );
}
