import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pirc_client/pirc_client.dart';

import '../../l10n/app_localizations.dart';
import '../chat/chat_data.dart';
import '../connection/data.dart';
import '../connection/hints.dart';
import '../work/work_data.dart';
import '../work/work_side.dart';

// Locations of the Activity tab (M7 step 10):
// - `/activity`: every pot's activity, newest first;
// - `pot=<id>`: filtered to one pot (the profile's "See all");
// - `kind=<a,b>`: filtered to those kinds;
// - `notification=<id>`: where a push of an observation notification lands,
//   with that notification in view;
// - `open=pov:<id>`: the pot's point of view (E18), with `thread=<id>` one
//   of its threads read only (E20) or `work=<workId>` the instructions it
//   sent into a work (E19).

/// The Activity tab's `open` value of a pot's point of view.
String povKey(String potId) => 'pov:$potId';

/// The pot of a point-of-view key, or null.
String? povPotOf(String? open) =>
    open != null && open.startsWith('pov:') ? open.substring(4) : null;

/// The Activity tab with its filters and open item.
String activityLocation({
  String? potId,
  String? kind,
  String? open,
  String? thread,
  String? work,
  String? notification,
}) {
  final query = {
    'pot': ?potId,
    'kind': ?kind,
    'open': ?open,
    'thread': ?thread,
    'work': ?work,
    'notification': ?notification,
  };
  return Uri(
    path: '/activity',
    queryParameters: query.isEmpty ? null : query,
  ).toString();
}

/// A pot's point of view (E18), the list filtered to it beside it.
String povLocation(String potId) =>
    activityLocation(potId: potId, open: povKey(potId));

/// One of a pot's threads as it sees it (E20).
String povThreadLocation(String potId, String threadId) =>
    activityLocation(potId: potId, open: povKey(potId), thread: threadId);

/// The instructions a pot sent into one work (E19).
String povWorkLocation(String potId, String workId) =>
    activityLocation(potId: potId, open: povKey(potId), work: workId);

/// Where a push of an observation notification opens.
String notificationLocation(String id) => activityLocation(notification: id);

/// Where Back goes from the Activity tab's open item at [location]: a
/// thread or a work back to the point of view, the point of view to the
/// list filtered to its pot.
String activityBackLocation(Uri location) {
  final params = location.queryParameters;
  final potId = povPotOf(params['open']);
  if (potId == null) return '/activity';
  if (params['thread'] != null || params['work'] != null) {
    return povLocation(potId);
  }
  return activityLocation(potId: potId, kind: params['kind']);
}

/// The Activity list's filters: a pot and the kinds (comma-joined, as
/// `kind=` sends them).
typedef ActivityQuery = ({String? potId, String? kind});

/// Rows on screen, newest first, with the cursor of the next older page.
@immutable
class ActivityFeed {
  const ActivityFeed({
    this.entries = const [],
    this.nextBefore,
    this.loaded = false,
    this.loadingOlder = false,
    this.error,
  });

  final List<ActivityEntry> entries;
  final String? nextBefore;
  final bool loaded;
  final bool loadingOlder;
  final Object? error;

  ActivityFeed copyWith({
    List<ActivityEntry>? entries,
    String? nextBefore,
    bool clearNext = false,
    bool? loaded,
    bool? loadingOlder,
    Object? error,
    bool clearError = false,
  }) => ActivityFeed(
    entries: entries ?? this.entries,
    nextBefore: clearNext ? null : nextBefore ?? this.nextBefore,
    loaded: loaded ?? this.loaded,
    loadingOlder: loadingOlder ?? this.loadingOlder,
    error: clearError ? null : error ?? this.error,
  );
}

/// The Activity list of one filter. Reads the newest page again on
/// `activity_changed` and merges it with what is loaded, so older pages
/// stay; [ActivityFeedController.loadOlder] reads the page before the
/// oldest row.
final activityFeedProvider = NotifierProvider.autoDispose
    .family<ActivityFeedController, ActivityFeed, ActivityQuery>(
      ActivityFeedController.new,
    );

class ActivityFeedController extends Notifier<ActivityFeed> {
  ActivityFeedController(this.query);

  final ActivityQuery query;
  bool _reading = false;
  bool _again = false;

  /// Pages loaded so far.
  int _pages = 0;

  List<String> get _kinds => query.kind == null || query.kind!.isEmpty
      ? const []
      : query.kind!.split(',');

  @override
  ActivityFeed build() {
    ref.listen(
      hintRevisionsProvider.select((r) => r['activity_changed'] ?? 0),
      (_, _) => refresh(),
    );
    ref.listen(apiProvider, (before, now) {
      if (before == null && now != null) refresh();
    });
    Future.microtask(refresh);
    return const ActivityFeed();
  }

  Future<void> refresh() async {
    if (_reading) {
      _again = true;
      return;
    }
    final api = ref.read(apiProvider);
    if (api == null) return;
    _reading = true;
    try {
      final page = await ActivityApi(
        api,
      ).activity(potId: query.potId, kinds: _kinds);
      if (!ref.mounted) return;
      final had = state.entries;
      final pageIds = {for (final e in page.entries) e.id};
      // Only the first page loaded, or more than a page arrived: start
      // again from here; else keep the older pages under the new one.
      final restart =
          _pages <= 1 ||
          page.nextBefore == null ||
          (page.entries.isNotEmpty &&
              had.isNotEmpty &&
              page.entries.last.at > had.first.at);
      if (restart) _pages = 1;
      state = restart
          ? ActivityFeed(
              entries: page.entries,
              nextBefore: page.nextBefore,
              loaded: true,
            )
          : state.copyWith(
              entries: [
                ...page.entries,
                for (final e in had)
                  if (!pageIds.contains(e.id) &&
                      (page.entries.isEmpty || e.at <= page.entries.last.at))
                    e,
              ],
              clearError: true,
            );
    } on PircException catch (error) {
      if (ref.mounted) state = state.copyWith(error: error);
    } finally {
      _reading = false;
      if (_again && ref.mounted) {
        _again = false;
        refresh();
      }
    }
  }

  /// Loads the page before the oldest row.
  Future<void> loadOlder() async {
    final feed = state;
    final before = feed.nextBefore;
    final api = ref.read(apiProvider);
    if (before == null || api == null || feed.loadingOlder) return;
    state = feed.copyWith(loadingOlder: true);
    try {
      final page = await ActivityApi(
        api,
      ).activity(potId: query.potId, kinds: _kinds, before: before);
      if (!ref.mounted) return;
      final ids = {for (final e in state.entries) e.id};
      _pages++;
      state = state.copyWith(
        entries: [
          ...state.entries,
          for (final e in page.entries)
            if (!ids.contains(e.id)) e,
        ],
        nextBefore: page.nextBefore,
        clearNext: page.nextBefore == null,
        loadingOlder: false,
      );
    } on PircException {
      if (ref.mounted) state = state.copyWith(loadingOlder: false);
    }
  }
}

/// What pots noticed, open ones first (each group newest first); read
/// again on `notifications_changed`.
final notificationsProvider = FutureProvider<List<ObservationNotification>>((
  ref,
) async {
  watchHint(ref, 'notifications_changed');
  final all = await ActivityApi(requireApi(ref)).notifications();
  return [
    for (final n in all)
      if (n.open) n,
    for (final n in all)
      if (!n.open) n,
  ];
});

/// The Activity tab badge: open notifications.
final activityBadgeProvider = Provider<int>(
  (ref) =>
      ref.watch(notificationsProvider).value?.where((n) => n.open).length ?? 0,
);

/// A pot's point of view; read again when its threads, its activity (the
/// instructions it sends) or the pots change.
final potViewProvider = FutureProvider.autoDispose.family<PotView, String>((
  ref,
  potId,
) {
  watchHint(ref, 'threads_changed');
  watchHint(ref, 'activity_changed');
  watchHint(ref, 'pots_changed');
  return ActivityApi(requireApi(ref)).view(potId);
});

/// "→ You", "→ Tester", "→ Check the nightly test" (a work by its
/// session), "→ Mobile team" (a group by the row's thread); null when the
/// counterpart has no name the app knows.
String? activityTarget(
  AppLocalizations l10n,
  ActivityEntry entry, {
  required List<PotSummary> pots,
  List<PotWork> works = const [],
  List<PotThread> threads = const [],
}) {
  final counterpart = entry.counterpart;
  final String? name = switch (counterpart?.kind) {
    'user' => l10n.activityToYou,
    'pot' => pots.where((p) => p.id == counterpart!.id).firstOrNull?.name,
    'work_session' =>
      works.where((w) => w.sessionId == counterpart!.id).firstOrNull?.title,
    'system' => () {
      final thread = threads
          .where((t) => t.id == entry.refs.thread)
          .firstOrNull;
      return thread != null && thread.isGroup ? thread.name : null;
    }(),
    _ => null,
  };
  return name == null || name.isEmpty ? null : '→ $name';
}

/// What an activity row opens.
sealed class ActivityOpen {
  const ActivityOpen();
}

/// A location in the app.
class OpenLocation extends ActivityOpen {
  const OpenLocation(this.location);
  final String location;
}

/// The model approval sheet (step 6).
class OpenApproval extends ActivityOpen {
  const OpenApproval(this.id);
  final String id;
}

/// The budget request sheet (step 6).
class OpenBudgetRequest extends ActivityOpen {
  const OpenBudgetRequest(this.id);
  final String id;
}

/// The reference a row of [entry] opens, by its kind first: an approval's
/// sheet, a budget request's sheet, a handover, a work session, then a
/// thread (a pot's conversation, a group, or a pot DM in the pot's point of
/// view). `budget` on `budget_exhausted` is a window, not a request.
///
/// A direct thread whose pot was deleted opens by its thread ID: the
/// Gateway's direct-thread route needs the pot, but a thread ID still reads
/// the stored conversation (read only). A pot DM whose pot was deleted is
/// opened the same way instead of as a point of view.
ActivityOpen? activityOpenOf(
  ActivityEntry entry,
  List<PotThread> threads, {
  List<PotSummary> pots = const [],
}) {
  final refs = entry.refs;
  final kind = entry.kind;
  if ((kind == 'awaiting_approval' || kind == 'approval_answered') &&
      refs.approval != null) {
    return OpenApproval(refs.approval!);
  }
  if (kind == 'budget_request' && refs.budget != null) {
    return OpenBudgetRequest(refs.budget!);
  }
  if (refs.handover != null) {
    return OpenLocation(chatLocation(handoverKey(refs.handover!)));
  }
  if (refs.session != null) {
    return OpenLocation(workLocation(refs.session!));
  }
  final threadId = refs.thread;
  if (threadId != null) {
    final thread = threads.where((t) => t.id == threadId).firstOrNull;
    final potId = entry.potId;
    final pot = potId == null
        ? null
        : pots.where((p) => p.id == potId).firstOrNull;
    if (thread != null && thread.kind == 'pot_dm' && pot != null) {
      return OpenLocation(povThreadLocation(pot.id, threadId));
    }
    if (thread != null && thread.isDirect && thread.pots.isNotEmpty) {
      final owner = pots.where((p) => p.id == thread.pots.first).firstOrNull;
      if (owner != null) {
        return OpenLocation(chatLocation(potChatKey(owner.id)));
      }
    }
    return OpenLocation(chatLocation(threadId));
  }
  if (refs.approval != null) return OpenApproval(refs.approval!);
  return null;
}

/// The works a pot coordinates or sent instructions into, newest first.
@immutable
class PovWork {
  const PovWork({
    required this.workId,
    required this.title,
    required this.sessionId,
    this.instructions = const [],
  });

  final String workId;
  final String title;
  final String sessionId;

  /// Newest first.
  final List<SentInstruction> instructions;

  int get time => instructions.firstOrNull?.createdAt ?? 0;
}

/// [view]'s works: those with instructions, then the pot's other works.
List<PovWork> povWorks(PotView view, List<PotWork> works) {
  final byWork = <String, List<SentInstruction>>{};
  for (final i in view.instructions) {
    (byWork[i.workId] ??= []).add(i);
  }
  final result = [
    for (final MapEntry(key: id, value: list) in byWork.entries)
      PovWork(
        workId: id,
        title: list.first.workTitle,
        sessionId: list.first.sessionId,
        instructions: list,
      ),
  ];
  for (final work in works) {
    if (work.potId == view.potId && !byWork.containsKey(work.id)) {
      result.add(
        PovWork(workId: work.id, title: work.title, sessionId: work.sessionId),
      );
    }
  }
  return result;
}

/// The pot works, for names of works; empty while they load.
List<PotWork> watchPotWorks(WidgetRef ref) =>
    ref.watch(potWorksProvider).value ?? const [];
