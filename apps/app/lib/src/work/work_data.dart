import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pirc_client/pirc_client.dart';

import '../connection/data.dart';
import '../connection/hints.dart';

/// The user's pots, for names ("From `pot`"); read again on `pots_changed`.
final potsProvider = FutureProvider<List<PotSummary>>((ref) {
  watchHint(ref, 'pots_changed');
  return PotsApi(requireApi(ref)).pots();
});

/// Works the pots opened; read again on `pots_changed`.
final potWorksProvider = FutureProvider<List<PotWork>>((ref) {
  watchHint(ref, 'pots_changed');
  return PotsApi(requireApi(ref)).works();
});

/// Pending model approvals; read again on `approvals_changed`.
final pendingApprovalsProvider = FutureProvider<List<ModelApproval>>((ref) {
  watchHint(ref, 'approvals_changed');
  return PotsApi(requireApi(ref)).approvals(state: 'pending');
});

enum WorkFilter { all, needsYou, running, mine, pots }

/// Who started a session, for line 1 of its row.
sealed class WorkSource {
  const WorkSource();
}

class FromUser extends WorkSource {
  const FromUser();
}

class FromPot extends WorkSource {
  const FromPot(this.potName, this.work);
  final String potName;
  final PotWork work;
}

class FromSchedule extends WorkSource {
  const FromSchedule(this.title);
  final String title;
}

/// One row of the Work list: a session, or a pending model approval (shown
/// but not opened; its sheet is M7).
@immutable
sealed class WorkItem {
  const WorkItem();

  String get title;
  String get workspaceId;
  int get time;
  bool get needsYou;
  String get key;
}

class SessionItem extends WorkItem {
  const SessionItem(this.session, this.source, {this.host});

  final Session session;
  final WorkSource source;

  /// The node's name, when the session has one.
  final String? host;

  @override
  String get title => session.name;
  @override
  String get workspaceId => session.workspaceId;
  @override
  int get time => session.updatedAt;
  @override
  bool get needsYou => session.runStatus == 'waiting_input';
  @override
  String get key => 'session:${session.id}';

  bool get running => session.runStatus == 'running';
  bool get openedByPot => source is FromPot;
  bool get mine => source is FromUser;
}

class ApprovalItem extends WorkItem {
  const ApprovalItem(this.approval, this.potName);

  final ModelApproval approval;
  final String potName;

  @override
  String get title => approval.workTitle;
  @override
  String get workspaceId => approval.workspaceId;
  @override
  int get time => approval.createdAt;
  @override
  bool get needsYou => true;
  @override
  String get key => 'approval:${approval.id}';
}

/// A project group: the folder header and its rows.
@immutable
class WorkGroup {
  const WorkGroup({
    required this.workspaceId,
    required this.name,
    required this.items,
  });

  /// Null for "No project".
  final String? workspaceId;
  final String? name;
  final List<WorkItem> items;
}

@immutable
class WorkList {
  const WorkList({required this.groups, required this.needsYou});

  final List<WorkGroup> groups;

  /// The Needs you count (the filter chip and the tab badge).
  final int needsYou;

  bool get isEmpty => groups.isEmpty;
}

/// Builds the rows of [filter] matching [query], grouped by workspace.
/// Pinned rows first, then the newest; settled rows last. Groups are
/// ordered by their newest row.
WorkList buildWorkList({
  required List<Session> sessions,
  required List<WorkspaceInfo> workspaces,
  required List<PotWork> works,
  required List<PotSummary> pots,
  required List<ModelApproval> approvals,
  WorkFilter filter = WorkFilter.all,
  String query = '',
}) {
  final potNames = {for (final pot in pots) pot.id: pot.name};
  final workBySession = {for (final work in works) work.sessionId: work};
  final workspaceNames = {
    for (final workspace in workspaces) workspace.id: workspace.displayName,
  };
  final items = <WorkItem>[
    for (final session in sessions)
      SessionItem(session, switch ((
        workBySession[session.id],
        session.origin,
      )) {
        (final PotWork work, _) => FromPot(potNames[work.potId] ?? '', work),
        (null, final SessionOrigin origin) => FromSchedule(origin.title),
        (null, null) => const FromUser(),
      }, host: session.nodeId),
    for (final approval in approvals)
      if (approval.state == 'pending')
        ApprovalItem(approval, potNames[approval.potId] ?? ''),
  ];
  final needsYou = items.where((item) => item.needsYou).length;
  bool keep(WorkItem item) => switch (filter) {
    WorkFilter.all => true,
    WorkFilter.needsYou => item.needsYou,
    WorkFilter.running => item is SessionItem && item.running,
    WorkFilter.mine => item is SessionItem && item.mine,
    WorkFilter.pots =>
      item is ApprovalItem || (item is SessionItem && item.openedByPot),
  };
  final needle = query.trim().toLowerCase();
  bool matches(WorkItem item) {
    if (needle.isEmpty) return true;
    final project = workspaceNames[item.workspaceId] ?? '';
    return item.title.toLowerCase().contains(needle) ||
        project.toLowerCase().contains(needle);
  }

  final byWorkspace = <String?, List<WorkItem>>{};
  for (final item in items.where(keep).where(matches)) {
    final id = workspaceNames.containsKey(item.workspaceId)
        ? item.workspaceId
        : null;
    byWorkspace.putIfAbsent(id, () => []).add(item);
  }
  int rank(WorkItem item) => switch (item) {
    SessionItem(:final session) when session.pinned => 0,
    SessionItem(:final session) when session.settled => 2,
    _ => 1,
  };
  final groups = [
    for (final MapEntry(key: id, value: rows) in byWorkspace.entries)
      WorkGroup(
        workspaceId: id,
        name: id == null ? null : workspaceNames[id],
        items: rows
          ..sort((a, b) {
            final byRank = rank(a).compareTo(rank(b));
            return byRank != 0 ? byRank : b.time.compareTo(a.time);
          }),
      ),
  ];
  int newest(WorkGroup group) =>
      group.items.map((item) => item.time).fold(0, (a, b) => a > b ? a : b);
  groups.sort((a, b) {
    // "No project" goes last.
    if ((a.workspaceId == null) != (b.workspaceId == null)) {
      return a.workspaceId == null ? 1 : -1;
    }
    return newest(b).compareTo(newest(a));
  });
  return WorkList(groups: groups, needsYou: needsYou);
}

final workFilterProvider = NotifierProvider<WorkFilterNotifier, WorkFilter>(
  WorkFilterNotifier.new,
);

class WorkFilterNotifier extends Notifier<WorkFilter> {
  @override
  WorkFilter build() => WorkFilter.all;
  void select(WorkFilter filter) => state = filter;
}

final workQueryProvider = NotifierProvider<WorkQueryNotifier, String>(
  WorkQueryNotifier.new,
);

class WorkQueryNotifier extends Notifier<String> {
  @override
  String build() => '';
  void set(String query) => state = query;
}

/// The Work list as the screen shows it; loading or failed while the
/// sessions are. The other lists are optional: a failure there shows the
/// sessions without names or approvals rather than nothing.
final workListProvider = Provider<AsyncValue<WorkList>>((ref) {
  final sessions = ref.watch(sessionsProvider);
  return sessions.whenData(
    (sessions) => buildWorkList(
      sessions: sessions,
      workspaces: ref.watch(workspacesProvider).value ?? const [],
      works: ref.watch(potWorksProvider).value ?? const [],
      pots: ref.watch(potsProvider).value ?? const [],
      approvals: ref.watch(pendingApprovalsProvider).value ?? const [],
      filter: ref.watch(workFilterProvider),
      query: ref.watch(workQueryProvider),
    ),
  );
});

/// The Needs you count across all rows, for the tab badge.
final workBadgeProvider = Provider<int>((ref) {
  final sessions = ref.watch(sessionsProvider).value ?? const <Session>[];
  final approvals =
      ref.watch(pendingApprovalsProvider).value ?? const <ModelApproval>[];
  return sessions.where((s) => s.runStatus == 'waiting_input').length +
      approvals.where((a) => a.state == 'pending').length;
});

/// The pot work of a session, if a pot opened it.
final potWorkOfSessionProvider = Provider.family<PotWork?, String>((
  ref,
  sessionId,
) {
  final works = ref.watch(potWorksProvider).value ?? const <PotWork>[];
  for (final work in works) {
    if (work.sessionId == sessionId) return work;
  }
  return null;
});
