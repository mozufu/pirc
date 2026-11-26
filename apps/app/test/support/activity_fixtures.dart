import 'harness.dart';
import 'chat_fixtures.dart';
import 'work_fixtures.dart';

Map<String, Object?> activityJson(
  String id,
  String kind,
  String potId,
  String summary,
  int at, {
  String? potName,
  Map<String, Object?>? counterpart,
  Map<String, Object?> refs = const {},
}) => {
  'id': id,
  'kind': kind,
  'potId': potId,
  'potName': ?potName,
  'at': at,
  'counterpart': ?counterpart,
  'summary': summary,
  'refs': refs,
};

Map<String, Object?> _pot(String id) => {'kind': 'pot', 'id': id};
const _user = {'kind': 'user'};

/// E5, E18–E20, E27: the activity of E5 (en), one open and one read
/// observation notification, Tester's point of view (the Mobile team, its
/// DM with Butler and its direct thread; the instructions it sent into two
/// works; two messages it sent) and the DM's messages. GET /api/activity
/// filters by `potId` and `kind` as the Gateway does; [olderPages] answers
/// `before=<cursor>`.
class ActivityFixture extends ConversationFixture {
  ActivityFixture() {
    pots[1]['status'] = 'idle';
  }

  late List<Map<String, Object?>> activity = [
    activityJson(
      'e1',
      'awaiting_approval',
      'p-butler',
      'Wants Claude Opus · High: compare three API specs; Sonnet compared '
          'them twice and disagreed',
      at(10, 45),
      counterpart: _user,
      refs: {'approval': 'a1'},
    ),
    activityJson(
      'e2',
      'forwarded_to_user',
      'p-tester',
      'The work asks: rerun only the failed cases? Tester can\'t answer for '
          'you.',
      at(10, 42, 0) + 2,
      counterpart: {'kind': 'work_session', 'id': 's-nightly'},
      refs: {'session': 's-nightly'},
    ),
    activityJson(
      'e3',
      'dm',
      'p-tester',
      'All 3 failures are timeouts. Whether to rerun, I passed to the user.',
      at(10, 42),
      counterpart: _pot('p-butler'),
      refs: {'thread': 't-dm', 'message': 'dm4'},
    ),
    activityJson(
      'e4',
      'assign',
      'p-butler',
      'Check the nightly test: find the cause first, don\'t change code.',
      at(10, 40),
      counterpart: _pot('p-tester'),
      refs: {'handover': 'h1'},
    ),
    activityJson(
      'e5',
      'work_instruction',
      'p-tester',
      'Add an iPad floating keyboard test that sets viewInsets to 0.',
      at(10, 34),
      counterpart: {'kind': 'work_session', 'id': 's-ipad'},
      refs: {'session': 's-ipad'},
    ),
    activityJson(
      'e6',
      'group_message',
      'p-research',
      'Will update: viewInsets follows split view, but the floating '
          'keyboard reports 0.',
      at(10, 33),
      counterpart: {'kind': 'system'},
      refs: {'thread': 't-mobile'},
    ),
    activityJson(
      'e7',
      'thinking_adjust',
      'p-research',
      'Medium → High to compare three documents; back to Medium after '
          'replying',
      at(10, 32) + 1,
    ),
    activityJson(
      'e8',
      'file_read',
      'p-research',
      'docs/keyboard.md · pirc mobile · read only, with Researcher\'s own '
          'permissions',
      at(10, 32),
      counterpart: {'kind': 'workspace', 'id': 'laptop:pirc'},
    ),
    activityJson(
      'e9',
      'fallback',
      'p-tester',
      'Switched to OpenAI · GPT-5: Claude Sonnet is out of budget; switches '
          'back when it recovers',
      at(10, 12),
    ),
    activityJson(
      'e10',
      'paused',
      'p-travel',
      'Paused by you · its duties and follow-ups are kept',
      at(21, 30, 1),
      counterpart: _user,
    ),
    activityJson(
      'e11',
      'budget_request',
      'p-travel',
      'Asked the user for \$10 more this month',
      at(21, 10, 1),
      counterpart: _user,
      refs: {'budget': 'b1'},
    ),
  ];

  /// The first page's cursor; null on a single page.
  String? nextBefore;

  /// Pages by `before`.
  final olderPages = <String, Map<String, Object?>>{};

  late List<Map<String, Object?>> notifications = [
    // The Gateway lists them newest first; the read one is newer.
    {
      'id': 'n2',
      'eventId': 'ev2',
      'sourceKind': 'session',
      'sourceRef': 's-ipad',
      'condition': 'run_finished',
      'observations': [
        {
          'potId': 'p-butler',
          'potName': 'Butler',
          'note': 'The iPad tests finished; nothing failed',
          'createdAt': at(10, 50),
        },
        {
          'potId': 'p-research',
          'potName': 'Researcher',
          'note': 'Split view is covered now',
          'createdAt': at(10, 50),
        },
      ],
      'state': 'read',
      'createdAt': at(10, 50),
      'updatedAt': at(10, 52),
    },
    {
      'id': 'n1',
      'eventId': 'ev1',
      'sourceKind': 'session',
      'sourceRef': 's-nightly',
      'condition': 'waiting_input',
      'issuerPotId': 'p-tester',
      'observations': [
        {
          'potId': 'p-tester',
          'potName': 'Tester',
          'note': 'The nightly run asks whether to rerun only the failed cases',
          'createdAt': at(10, 43),
        },
      ],
      'state': 'open',
      'createdAt': at(10, 43),
      'updatedAt': at(10, 43),
    },
  ];

  late Map<String, Object?> dm = threadJson(
    't-dm',
    kind: 'pot_dm',
    pots: ['p-butler', 'p-tester'],
    last: lastJson(
      "OK, I'll put it in today's summary reminder.",
      at(10, 43),
      authorId: 'p-butler',
    ),
  )..['lastSeq'] = 5;

  late List<Map<String, Object?>> dmMessages = [
    messageJson(
      1,
      "Please take the nightly: find the cause first, don't change code.",
      authorId: 'p-butler',
      createdAt: at(10, 40),
      threadId: 't-dm',
    ),
    messageJson(
      2,
      'Handed over: Check the nightly test · Butler → Tester',
      authorKind: 'system',
      createdAt: at(10, 40),
      threadId: 't-dm',
    ),
    messageJson(
      3,
      "Got it, I'm opening a work on CI-runner.",
      authorId: 'p-tester',
      createdAt: at(10, 41),
      threadId: 't-dm',
    ),
    messageJson(
      4,
      'All 3 failures are timeouts. Whether to rerun, I passed to the user.',
      authorId: 'p-tester',
      createdAt: at(10, 42),
      threadId: 't-dm',
    ),
    messageJson(
      5,
      "OK, I'll put it in today's summary reminder.",
      authorId: 'p-butler',
      createdAt: at(10, 43),
      threadId: 't-dm',
    ),
  ];

  late List<Map<String, Object?>> groupMessages = [
    messageJson(
      1,
      '@Tester add an iPad floating keyboard test',
      authorKind: 'user',
      createdAt: at(10, 30),
      threadId: 't-mobile',
    ),
    messageJson(
      2,
      'OK, I opened a work.',
      authorId: 'p-tester',
      createdAt: at(10, 34),
      threadId: 't-mobile',
    ),
  ];

  Map<String, Object?> get testerView => {
    'potId': 'p-tester',
    'threads': [
      {
        ...threads[1], // Mobile team, as E18 shows it
        'lastMessage': lastJson(
          '@Tester add an iPad floating keyboard test',
          at(10, 34),
          authorKind: 'user',
        ),
      },
      dm,
      threadJson(
        't-tester',
        pots: ['p-tester'],
        last: lastJson(
          'nightly has a question for you',
          at(10, 42),
          authorId: 'p-tester',
        ),
      ),
    ],
    'sent': [
      {...dmMessages[3], 'id': 'dm4'},
      {...groupMessages[1], 'id': 'g2'},
    ],
    'instructions': [
      {
        'id': 'i2',
        'workId': 'w-nightly',
        'workTitle': 'Check the nightly test',
        'sessionId': 's-nightly',
        'body':
            'Run the nightly tests; if any fail, find the cause first '
            "and don't change code.",
        'delivery': 'delivered',
        'createdAt': at(10, 40),
      },
      {
        'id': 'i1',
        'workId': 'w-ipad',
        'workTitle': 'Add iPad keyboard tests',
        'sessionId': 's-ipad',
        'body':
            'Add an iPad floating keyboard test that sets viewInsets '
            'to 0.',
        'delivery': 'delivered',
        'createdAt': at(10, 34),
      },
    ],
  };

  @override
  FakeGateway install([FakeGateway? gateway]) {
    final g = super.install(gateway);
    // The DM's first message in the fixture threads list is updated.
    threads[threads.indexWhere((t) => t['id'] == 't-dm')] = dm;
    g.json['GET /api/activity'] = (request) {
      final before = request.query['before'];
      if (before != null) {
        return olderPages[before] ?? {'activity': <Object?>[]};
      }
      final potId = request.query['potId'];
      final kinds = request.query['kind']?.split(',');
      return {
        'activity': [
          for (final row in activity)
            if ((potId == null || row['potId'] == potId) &&
                (kinds == null || kinds.contains(row['kind'])))
              row,
        ],
        'nextBefore': ?nextBefore,
      };
    };
    g.json['GET /api/observation-notifications'] = (_) => {
      'notifications': notifications,
    };
    g.routes.add((request) {
      final match = RegExp(
        r'^/api/observation-notifications/([^/]+)/read$',
      ).firstMatch(request.path);
      if (request.method != 'POST' || match == null) return null;
      final n = notifications.firstWhere((n) => n['id'] == match[1]);
      n['state'] = 'read';
      return reply(200, {'notification': n});
    });
    g.json['GET /api/pots/p-tester/view'] = (_) => testerView;
    g.json['GET /api/threads/t-dm'] = (_) => {'thread': dm};
    g.json['GET /api/threads/t-dm/messages'] = (_) => {'messages': dmMessages};
    g.json['GET /api/threads/t-mobile'] = (_) => {'thread': threads[1]};
    g.json['GET /api/threads/t-mobile/messages'] = (_) => {
      'messages': groupMessages,
    };
    return g;
  }
}
