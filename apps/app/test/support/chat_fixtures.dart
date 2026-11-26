import 'package:pirc_client/pirc_client.dart';

import 'harness.dart';
import 'work_fixtures.dart';

Map<String, Object?> potJson(
  String id,
  String name, {
  int color = 1,
  String intro = '',
  String state = 'active',
  String status = 'idle',
  int needsYou = 0,
  String? avatarImage,
  Map<String, Object?>? budgetLeft,
}) => {
  'id': id,
  'state': state,
  'status': status,
  'needsYou': needsYou,
  'profile': {'name': name, 'avatarColor': color, 'avatarImage': ?avatarImage},
  'work': {'intro': intro},
  'budgetLeft': ?budgetLeft,
};

Map<String, Object?> threadJson(
  String id, {
  String kind = 'direct',
  String name = '',
  List<String> pots = const [],
  int? updatedAt,
  int unread = 0,
  String? hostPotId,
  int? avatarColor,
  Map<String, Object?>? last,
}) => {
  'id': id,
  'kind': kind,
  'name': name,
  'pots': pots,
  'hostPotId': ?hostPotId,
  'avatarColor': ?avatarColor,
  'updatedAt': updatedAt ?? last?['createdAt'] ?? at(9),
  'unread': unread,
  'revision': 1,
  'lastMessage': ?last,
};

Map<String, Object?> lastJson(
  String body,
  int createdAt, {
  String authorKind = 'pot',
  String? authorId,
}) => {
  'authorKind': authorKind,
  'authorId': ?authorId,
  'body': body,
  'createdAt': createdAt,
};

/// The E1 list: four pots (one paused, one working, one waiting on the
/// user), two groups, plus an archived pot and a pot DM that the Chat tab
/// leaves out.
class ChatFixture {
  List<Map<String, Object?>> pots = [
    potJson('p-butler', 'Butler', color: 1, intro: 'Manager', needsYou: 1),
    potJson(
      'p-tester',
      'Tester',
      color: 2,
      intro: 'Testing',
      status: 'working',
    ),
    potJson('p-research', 'Researcher', color: 3, intro: 'Research'),
    potJson(
      'p-travel',
      'Travel buddy',
      color: 4,
      intro: 'Travel',
      state: 'paused',
      status: 'unavailable',
    ),
    potJson('p-old', 'Old helper', color: 5, state: 'archived'),
  ];

  List<Map<String, Object?>> threads = [
    threadJson(
      't-butler',
      pots: ['p-butler'],
      last: lastJson(
        'Shall I start "Tidy the API docs"?',
        at(9),
        authorId: 'p-butler',
      ),
    ),
    threadJson(
      't-mobile',
      kind: 'group',
      name: 'Mobile team',
      pots: ['p-butler', 'p-research', 'p-tester'],
      hostPotId: 'p-butler',
      unread: 3,
      last: lastJson('OK, I opened a work.', at(10, 34), authorId: 'p-tester'),
    ),
    threadJson(
      't-tester',
      pots: ['p-tester'],
      unread: 1,
      last: lastJson(
        'I passed the nightly problem to you',
        at(10, 42),
        authorId: 'p-tester',
      ),
    ),
    threadJson(
      't-research',
      pots: ['p-research'],
      last: lastJson(
        'Will update: viewInsets changes in split view…',
        at(10, 33),
        authorId: 'p-research',
      ),
    ),
    threadJson(
      't-travel',
      pots: ['p-travel'],
      last: lastJson(
        'The trip on 11/14 is now three days',
        at(18, 0, 1),
        authorId: 'p-travel',
      ),
    ),
    threadJson(
      't-trip',
      kind: 'group',
      name: 'Trip plan',
      pots: ['p-travel', 'p-butler'],
      hostPotId: 'p-travel',
      last: lastJson(
        'Both hotels can still be cancelled for free',
        at(12, 0, 4),
        authorId: 'p-travel',
      ),
    ),
    threadJson('t-old', pots: ['p-old'], updatedAt: at(10, 50)),
    threadJson(
      't-dm',
      kind: 'pot_dm',
      pots: ['p-butler', 'p-tester'],
      updatedAt: at(10, 55),
    ),
  ];

  /// Installs the routes on [gateway] (with the Work tab's, so its badge
  /// reads cleanly).
  FakeGateway install([FakeGateway? gateway]) {
    final target = WorkFixture().install(gateway);
    target.json['GET /api/pots'] = (_) => {'pots': pots};
    target.json['GET /api/threads'] = (_) => {'threads': threads};
    return target;
  }

  List<PotSummary> get parsedPots => [
    for (final json in pots) PotSummary.fromJson(json),
  ];
  List<PotThread> get parsedThreads => [
    for (final json in threads) PotThread.fromJson(json),
  ];
}

Map<String, Object?> messageJson(
  int seq,
  String body, {
  String authorKind = 'pot',
  String? authorId,
  String? authorName,
  int? createdAt,
  Map<String, Object?>? card,
  String threadId = 't-butler',
}) => {
  'id': 'm$seq',
  'threadId': threadId,
  'seq': seq,
  'authorKind': authorKind,
  'authorId': ?authorId,
  'authorName': ?authorName,
  'body': body,
  'createdAt': createdAt ?? at(9, 0),
  'card': ?card,
};

/// A whole pot as `GET /api/pots/{id}` answers it.
Map<String, Object?> fullPotJson(
  Map<String, Object?> summary, {
  String reach = 'observe',
  int? moneyMicros = 20000000,
  int? tokens = 2000000,
  int revision = 7,
}) => {
  ...summary,
  'revision': revision,
  'permissions': {
    'reach': reach,
    'budgetMoneyMonthMicros': moneyMicros,
    'budgetTokensDay': tokens,
  },
  'models': {
    'main': {'provider': 'anthropic', 'model': 'claude-sonnet'},
  },
};

/// E11: Butler's direct thread (`t-butler`) with a bubble of each side,
/// a model approval, the handoff line with Tester's work and an answered
/// budget request; each card's item, the read position and posting.
class ConversationFixture extends ChatFixture {
  ConversationFixture() {
    pots[0]['budgetLeft'] = {'moneyMicros': 15800000, 'tokens': 1200000};
    pots[0]['needsYou'] = 1;
  }

  late List<Map<String, Object?>> messages = [
    messageJson(
      1,
      'Anything from last night?',
      authorKind: 'user',
      createdAt: at(8, 58),
    ),
    messageJson(
      2,
      "Good morning. Last night's nightly had 3 failures; Tester is "
      'already looking. One thing needs your decision.',
      authorId: 'p-butler',
    ),
    messageJson(
      3,
      '',
      authorKind: 'system',
      card: {'kind': 'model_approval', 'approvalId': 'a1'},
    ),
    messageJson(
      4,
      'Butler asked Tester to handle “Check the nightly test”',
      authorKind: 'system',
      card: {'kind': 'work', 'workId': 'w1', 'sessionId': 's-nightly'},
    ),
    messageJson(
      5,
      '',
      authorKind: 'system',
      card: {'kind': 'budget_request', 'requestId': 'b1'},
    ),
  ];

  /// Messages after the read position.
  int unread = 2;

  /// `GET /api/threads/{id}/messages?before=<seq>` pages, by `before`.
  final older = <int, List<Map<String, Object?>>>{};

  Map<String, Object?> approval = {
    'id': 'a1',
    'potId': 'p-butler',
    'workTitle': 'Tidy the API docs',
    'workspaceId': 'laptop:pirc',
    'provider': 'anthropic',
    'model': 'Claude Opus',
    'thinking': 'high',
    'reason': 'Three specs disagree',
    'estimateMicros': 300000,
    'remainingMicros': 15800000,
    'state': 'pending',
    'createdAt': at(9),
  };

  Map<String, Object?> budget = {
    'id': 'b1',
    'potId': 'p-butler',
    'window': 'month',
    'amountMicros': 10000000,
    'reason': 'Two more comparison runs',
    'state': 'approved',
    'createdAt': at(9),
  };

  Map<String, Object?> work = {
    'id': 'w1',
    'potId': 'p-tester',
    'sessionId': 's-nightly',
    'workspaceId': 'ci:pirc',
    'title': 'Check the nightly test',
    'state': 'open',
  };

  Map<String, Object?> handover = {
    'id': 'h1',
    'fromPotId': 'p-butler',
    'to': {'kind': 'user'},
    'proposedBy': 'pot',
    'reason': 'You review the release notes yourself',
    'state': 'proposed',
    'revision': 3,
    'items': [
      {'kind': 'responsibility', 'ref': 'r1', 'label': 'Release notes'},
    ],
  };

  Map<String, Object?> root = {
    'id': 'root1',
    'initiatorPot': 'p-butler',
    'state': 'suspended',
    'lastProgressAt': at(8, 30),
    'wakesSinceProgress': 12,
    'messagesSinceProgress': 30,
  };

  /// The posted message's reply; [refused] wakes come with it.
  List<Map<String, Object?>> refused = [];

  Map<String, Object?> get thread => threadJson(
    't-butler',
    pots: ['p-butler'],
    unread: unread,
    last: lastJson('', at(9)),
  )..['lastSeq'] = messages.isEmpty ? 0 : messages.last['seq'];

  @override
  FakeGateway install([FakeGateway? gateway]) {
    final g = super.install(gateway);
    g.json['GET /api/pots/p-butler'] = (_) => {'pot': fullPotJson(pots.first)};
    g.json['GET /api/pots/p-butler/thread'] = (_) => {'thread': thread};
    g.json['GET /api/threads/t-butler'] = (_) => {'thread': thread};
    g.json['GET /api/threads/t-butler/messages'] = (request) {
      final before = int.tryParse(request.query['before'] ?? '');
      return {
        'messages': before == null ? messages : older[before] ?? const [],
      };
    };
    g.json['POST /api/threads/t-butler/read'] = (_) => <String, Object?>{};
    g.json['POST /api/threads/t-butler/messages'] = (request) {
      final body = (request.json! as Map)['body'] as String;
      final message = messageJson(
        (messages.last['seq']! as int) + 1,
        body,
        authorKind: 'user',
        createdAt: at(10, 59),
      );
      messages.add(message);
      return {
        'message': message,
        'woken': refused.isEmpty ? ['p-butler'] : const [],
        'refused': refused,
      };
    };
    g.json['GET /api/model-approvals/a1'] = (_) => {'approval': approval};
    g.json['GET /api/budget-requests/b1'] = (_) => {'budgetRequest': budget};
    g.json['GET /api/pot-works/w1'] = (_) => {'work': work};
    g.json['GET /api/handovers/h1'] = (_) => {'handover': handover};
    g.json['GET /api/causal-roots/root1'] = (_) => {'causalRoot': root};
    return g;
  }
}
