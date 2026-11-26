import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pirc_client/pirc_client.dart';

import '../connection/data.dart';
import '../connection/hints.dart';
import '../work/work_data.dart';

/// The Chat tab's `open` values besides a thread ID.
const newPotKey = 'new-pot';
const newGroupKey = 'new-group';

/// A pot's conversation (its direct thread) in the Chat tab.
String potChatKey(String potId) => 'pot:$potId';

/// The Chat tab's location with [open] as its open item.
String chatLocation(String open) =>
    Uri(path: '/chat', queryParameters: {'open': open}).toString();

/// Every thread of the user; read again on `threads_changed`.
final threadsProvider = FutureProvider<List<PotThread>>((ref) {
  watchHint(ref, 'threads_changed');
  return ThreadsApi(requireApi(ref)).list();
});

/// An uploaded picture by image ID, read with the device token (the
/// Gateway serves it to its owner only). Kept for the app's life: a
/// replaced picture gets a new ID.
final avatarImageProvider = FutureProvider.family<ImageProvider, String>((
  ref,
  id,
) async {
  final bytes = await ImagesApi(requireApi(ref)).read(id);
  return MemoryImage(Uint8List.fromList(bytes));
});

/// The picture of [id], or null while it loads, when it fails or when
/// there is none: the avatar then shows its colour.
ImageProvider? watchAvatarImage(WidgetRef ref, String? id) =>
    id == null || id.isEmpty ? null : ref.watch(avatarImageProvider(id)).value;

enum ChatFilter { all, unread, pots, groups }

final chatFilterProvider = NotifierProvider<ChatFilterNotifier, ChatFilter>(
  ChatFilterNotifier.new,
);

class ChatFilterNotifier extends Notifier<ChatFilter> {
  @override
  ChatFilter build() => ChatFilter.all;
  void select(ChatFilter filter) => state = filter;
}

final chatQueryProvider = NotifierProvider<ChatQueryNotifier, String>(
  ChatQueryNotifier.new,
);

class ChatQueryNotifier extends Notifier<String> {
  @override
  String build() => '';
  void set(String query) => state = query;
}

/// One row of the Chat tab: a pot's direct thread or a group.
@immutable
sealed class ChatEntry {
  const ChatEntry();

  /// The thread, or null for a pot whose direct thread is not made yet
  /// (the Gateway makes it on first use).
  PotThread? get thread;

  /// The Chat tab's `open` value of this row.
  String get key;

  /// When the newest message arrived (or the thread changed).
  int get time => thread?.lastMessage?.createdAt ?? thread?.updatedAt ?? 0;

  int get unread => thread?.unread ?? 0;

  /// Items that wait on the user (pots only).
  int get needsYou => 0;

  String get name;

  /// What the search matches besides [name].
  Iterable<String> get searchText => [
    name,
    thread?.lastMessage?.firstLine ?? '',
  ];
}

class PotChat extends ChatEntry {
  const PotChat(this.pot, this.thread);

  final PotSummary pot;

  @override
  final PotThread? thread;

  @override
  String get key => potChatKey(pot.id);

  @override
  String get name => pot.name;

  @override
  int get needsYou => pot.needsYou;

  @override
  Iterable<String> get searchText => [...super.searchText, pot.intro];
}

class GroupChat extends ChatEntry {
  const GroupChat(this.thread, this.members);

  @override
  final PotThread thread;

  /// The member pots that still exist, in the thread's order.
  final List<PotSummary> members;

  @override
  String get key => thread.id;

  @override
  String get name => thread.name;
}

/// The Chat tab's rows: every non-archived pot (with its direct thread
/// when there is one) and every group, newest first. Pot DMs, archived
/// and deleted pots are left out.
@immutable
class ChatList {
  const ChatList({required this.all, required this.pots});

  final List<ChatEntry> all;

  /// Every pot (for names of message authors and the "New group" rule).
  final List<PotSummary> pots;

  int get activePots => pots.where((p) => p.state != 'archived').length;

  /// A message author's name: a pot's name, a deleted pot's kept name.
  String? authorName(ThreadLastMessage message) {
    if (message.authorKind != 'pot') return null;
    for (final pot in pots) {
      if (pot.id == message.authorId) return pot.name;
    }
    return message.authorName;
  }

  /// [all] narrowed by [filter] and [query] (names, intros, last lines).
  List<ChatEntry> shown(ChatFilter filter, String query) {
    final needle = query.trim().toLowerCase();
    return [
      for (final entry in all)
        if (switch (filter) {
              ChatFilter.all => true,
              ChatFilter.unread => entry.unread > 0 || entry.needsYou > 0,
              ChatFilter.pots => entry is PotChat,
              ChatFilter.groups => entry is GroupChat,
            } &&
            (needle.isEmpty ||
                entry.searchText.any(
                  (text) => text.toLowerCase().contains(needle),
                )))
          entry,
    ];
  }

  static ChatList build(List<PotThread> threads, List<PotSummary> pots) {
    final byId = {for (final pot in pots) pot.id: pot};
    final direct = {
      for (final thread in threads)
        if (thread.isDirect && thread.pots.isNotEmpty)
          thread.pots.first: thread,
    };
    final entries = <ChatEntry>[
      for (final pot in pots)
        if (pot.state != 'archived') PotChat(pot, direct[pot.id]),
      for (final thread in threads)
        if (thread.isGroup)
          GroupChat(thread, [for (final id in thread.pots) ?byId[id]]),
    ];
    // Stable, so pots without a thread keep the Gateway's order at the end.
    final order = {for (final (i, e) in entries.indexed) e: i};
    entries.sort((a, b) {
      final byTime = b.time.compareTo(a.time);
      return byTime != 0 ? byTime : order[a]!.compareTo(order[b]!);
    });
    return ChatList(all: entries, pots: pots);
  }
}

/// The Chat tab's list; loading or failed while the threads or the pots
/// are (a row needs its pot's name and avatar).
final chatListProvider = Provider<AsyncValue<ChatList>>((ref) {
  final threads = ref.watch(threadsProvider);
  final pots = ref.watch(potsProvider);
  if (threads.hasError) {
    return AsyncError(threads.error!, threads.stackTrace!);
  }
  if (pots.hasError) return AsyncError(pots.error!, pots.stackTrace!);
  final t = threads.value, p = pots.value;
  if (t == null || p == null) return const AsyncLoading();
  return AsyncData(ChatList.build(t, p));
});

/// The Chat tab badge: items that wait on the user across the pots.
final chatBadgeProvider = Provider<int>((ref) {
  final pots = ref.watch(potsProvider).value ?? const <PotSummary>[];
  return pots
      .where((pot) => pot.state != 'archived')
      .fold(0, (sum, pot) => sum + pot.needsYou);
});
