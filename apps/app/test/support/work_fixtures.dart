import 'package:pirc_client/pirc_client.dart';

import 'harness.dart';

/// 2026-11-25 11:00 local time: "today" in the fixtures.
final fixedNow = DateTime(2026, 11, 25, 11);

int at(int hour, [int minute = 0, int daysAgo = 0]) =>
    DateTime(2026, 11, 25 - daysAgo, hour, minute).millisecondsSinceEpoch;

Map<String, Object?> sessionJson(
  String id,
  String name, {
  String workspace = 'laptop:pirc',
  String? node = 'Laptop',
  String? runStatus,
  int? updatedAt,
  bool unread = false,
  bool pinned = false,
  bool settled = false,
  Map<String, Object?>? origin,
}) => {
  'id': id,
  'workspaceId': workspace,
  'nodeId': node,
  'name': name,
  'runStatus': ?runStatus,
  'updatedAt': updatedAt ?? at(10),
  'createdAt': at(9),
  'unread': unread,
  'pinnedAt': pinned ? 1 : null,
  'settledAt': settled ? 1 : null,
  'origin': ?origin,
};

/// The E2 list: pots, a schedule, the user's own work, a pending approval.
class WorkFixture {
  WorkFixture() {
    sessions = [
      sessionJson(
        's-fix',
        'Fix the login keyboard',
        runStatus: 'running',
        updatedAt: at(10, 28),
      ),
      sessionJson(
        's-nightly',
        'Check the nightly test',
        node: 'CI-runner',
        workspace: 'ci:pirc',
        runStatus: 'waiting_input',
        updatedAt: at(10, 42),
        unread: true,
      ),
      sessionJson(
        's-ipad',
        'Add iPad keyboard tests',
        node: 'CI-runner',
        workspace: 'ci:pirc',
        runStatus: 'running',
        updatedAt: at(10, 34),
      ),
      sessionJson(
        's-flutter',
        'Flutter tablet layouts',
        updatedAt: at(9, 0, 2),
        pinned: true,
      ),
      sessionJson(
        's-trip',
        'Weekend trip budget',
        workspace: 'laptop:travel',
        updatedAt: at(18, 0, 1),
        settled: true,
      ),
      sessionJson(
        's-daily',
        'Morning test run',
        workspace: 'gone:x',
        node: null,
        updatedAt: at(8),
        origin: {
          'kind': 'schedule',
          'scheduleId': 'sch1',
          'title': 'Every morning',
          'dueAt': at(8),
        },
      ),
    ];
  }

  late List<Map<String, Object?>> sessions;

  List<Map<String, Object?>> workspaces = [
    {'id': 'laptop:pirc', 'hostId': 'h', 'displayName': 'pirc mobile'},
    {'id': 'ci:pirc', 'hostId': 'h2', 'displayName': 'pirc mobile'},
    {'id': 'laptop:travel', 'hostId': 'h', 'displayName': 'Travel'},
  ];

  List<Map<String, Object?>> pots = [
    {
      'id': 'p-tester',
      'state': 'active',
      'profile': {'name': 'Tester', 'avatarColor': 2},
    },
    {
      'id': 'p-butler',
      'state': 'active',
      'profile': {'name': 'Butler', 'avatarColor': 1},
    },
  ];

  List<Map<String, Object?>> works = [
    {
      'id': 'w-nightly',
      'potId': 'p-tester',
      'sessionId': 's-nightly',
      'workspaceId': 'ci:pirc',
      'title': 'Check the nightly test',
      'state': 'open',
    },
    {
      'id': 'w-ipad',
      'potId': 'p-tester',
      'sessionId': 's-ipad',
      'workspaceId': 'ci:pirc',
      'title': 'Add iPad keyboard tests',
      'state': 'open',
    },
  ];

  List<Map<String, Object?>> approvals = [
    {
      'id': 'a-api',
      'potId': 'p-butler',
      'workTitle': 'Compare three API specs',
      'workspaceId': 'laptop:pirc',
      'model': 'Claude Opus',
      'state': 'pending',
      'createdAt': at(10, 45),
    },
  ];

  List<Map<String, Object?>> nodes = [
    {'id': 'Laptop', 'workspaces': <Object?>[]},
    {'id': 'CI-runner', 'workspaces': <Object?>[]},
  ];

  /// Installs the routes on [gateway].
  FakeGateway install([FakeGateway? gateway]) {
    final target = gateway ?? FakeGateway();
    target.json['GET /api/sessions'] = (_) => {'sessions': sessions};
    target.json['GET /api/workspaces'] = (_) => {'workspaces': workspaces};
    target.json['GET /api/pots'] = (_) => {'pots': pots};
    target.json['GET /api/pot-works'] = (_) => {'works': works};
    target.json['GET /api/model-approvals'] = (_) => {'approvals': approvals};
    target.json['GET /api/nodes'] = (_) => {'nodes': nodes};
    return target;
  }

  List<Session> get parsedSessions => [
    for (final json in sessions) Session.fromJson(json),
  ];
  List<WorkspaceInfo> get parsedWorkspaces => [
    for (final json in workspaces) WorkspaceInfo.fromJson(json),
  ];
  List<PotWork> get parsedWorks => [
    for (final json in works) PotWork.fromJson(json),
  ];
  List<PotSummary> get parsedPots => [
    for (final json in pots) PotSummary.fromJson(json),
  ];
  List<ModelApproval> get parsedApprovals => [
    for (final json in approvals) ModelApproval.fromJson(json),
  ];
}
