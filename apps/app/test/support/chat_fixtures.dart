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
