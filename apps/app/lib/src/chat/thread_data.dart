import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pirc_client/pirc_client.dart';

import '../connection/data.dart';
import '../connection/hints.dart';
import 'chat_data.dart';

/// A page of messages, as the Gateway sends it.
const threadPageSize = 50;

/// One pot in full (profile, permissions, revision); read again on
/// `pots_changed`. A deleted pot answers 404.
final potProvider = FutureProvider.autoDispose.family<Pot, String>((ref, id) {
  watchHint(ref, 'pots_changed');
  return PotsApi(requireApi(ref)).read(id);
});

/// A work a pot opened (its `work` card); read again on `pots_changed`.
final potWorkProvider = FutureProvider.autoDispose.family<PotWork, String>((
  ref,
  id,
) {
  watchHint(ref, 'pots_changed');
  return PotsApi(requireApi(ref)).work(id);
});

/// A causal root (its `loop_guard` card); read again on
/// `causal_roots_changed`.
final causalRootProvider = FutureProvider.autoDispose
    .family<CausalRoot, String>((ref, id) {
      watchHint(ref, 'causal_roots_changed');
      return DecisionsApi(requireApi(ref)).causalRoot(id);
    });

/// A handover (its `handover` card). Handovers have no hint of their own:
/// read again on `pots_changed` and `threads_changed`.
final handoverProvider = FutureProvider.autoDispose.family<Handover, String>((
  ref,
  id,
) {
  watchHint(ref, 'pots_changed');
  watchHint(ref, 'threads_changed');
  return DecisionsApi(requireApi(ref)).handover(id);
});

/// A conversation as the screen shows it: the thread and the messages
/// loaded so far, oldest first.
@immutable
class ThreadView {
  const ThreadView({
    this.thread,
    this.messages = const [],
    this.hasOlder = false,
    this.loadingOlder = false,
    this.error,
  });

  final PotThread? thread;
  final List<ThreadMessage> messages;

  /// Older messages may be on the Gateway (the last page was full).
  final bool hasOlder;
  final bool loadingOlder;

  /// The last read failed (shown only while nothing is loaded).
  final Object? error;

  bool get loaded => thread != null;
  int get newestSeq => messages.isEmpty ? 0 : messages.last.seq;

  ThreadView copyWith({
    PotThread? thread,
    List<ThreadMessage>? messages,
    bool? hasOlder,
    bool? loadingOlder,
    Object? error,
    bool clearError = false,
  }) => ThreadView(
    thread: thread ?? this.thread,
    messages: messages ?? this.messages,
    hasOlder: hasOlder ?? this.hasOlder,
    loadingOlder: loadingOlder ?? this.loadingOlder,
    error: clearError ? null : error ?? this.error,
  );
}

/// Messages by `seq`, oldest first, without duplicates.
List<ThreadMessage> _merge(
  Iterable<ThreadMessage> a,
  Iterable<ThreadMessage> b,
) {
  final bySeq = {for (final m in a) m.seq: m, for (final m in b) m.seq: m};
  return bySeq.values.toList()..sort((x, y) => x.seq.compareTo(y.seq));
}

/// The conversation of a Chat tab key: `pot:<id>` (the pot's direct
/// thread, made on first use) or a thread ID. Reads the thread and the
/// newest page again on `threads_changed` and merges them with what is
/// loaded, so older pages stay.
final threadControllerProvider = NotifierProvider.autoDispose
    .family<ThreadController, ThreadView, String>(ThreadController.new);

class ThreadController extends Notifier<ThreadView> {
  ThreadController(this.chatKey);

  /// `pot:<id>` or a thread ID.
  final String chatKey;

  bool _reading = false;
  bool _again = false;

  /// The read position the Gateway has, as far as this device knows.
  int _readSeq = 0;

  String? get _potId =>
      chatKey.startsWith('pot:') ? chatKey.substring('pot:'.length) : null;

  @override
  ThreadView build() {
    ref.listen(
      hintRevisionsProvider.select((r) => r['threads_changed'] ?? 0),
      (_, _) => refresh(),
    );
    ref.listen(apiProvider, (before, now) {
      if (before == null && now != null) refresh();
    });
    Future.microtask(refresh);
    return const ThreadView();
  }

  /// Reads the thread and its newest page again.
  Future<void> refresh() async {
    if (_reading) {
      _again = true;
      return;
    }
    final api = ref.read(apiProvider);
    if (api == null) return;
    _reading = true;
    try {
      final threads = ThreadsApi(api);
      final potId = _potId;
      final thread = potId != null
          ? await threads.direct(potId)
          : await threads.read(chatKey);
      final page = await threads.messages(thread.id);
      if (!ref.mounted) return;
      final had = state.messages;
      final List<ThreadMessage> messages;
      final bool hasOlder;
      if (had.isEmpty ||
          (page.isNotEmpty && page.first.seq > had.last.seq + 1)) {
        // First read, or more than a page arrived: start again from here.
        messages = page;
        hasOlder = page.length >= threadPageSize;
      } else {
        messages = _merge(had, page);
        hasOlder = state.hasOlder;
      }
      // Another device may have moved it forward.
      _readSeq = math.max(_readSeq, thread.lastSeq - thread.unread);
      state = state.copyWith(
        thread: thread,
        messages: messages,
        hasOlder: hasOlder,
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

  /// Loads the page before the oldest loaded message.
  Future<void> loadOlder() async {
    final view = state;
    final thread = view.thread;
    final api = ref.read(apiProvider);
    if (thread == null ||
        api == null ||
        !view.hasOlder ||
        view.loadingOlder ||
        view.messages.isEmpty) {
      return;
    }
    state = view.copyWith(loadingOlder: true);
    try {
      final page = await ThreadsApi(
        api,
      ).messages(thread.id, before: view.messages.first.seq);
      if (!ref.mounted) return;
      state = state.copyWith(
        messages: _merge(page, state.messages),
        hasOlder: page.length >= threadPageSize,
        loadingOlder: false,
      );
    } on PircException {
      if (ref.mounted) state = state.copyWith(loadingOlder: false);
    }
  }

  /// Posts [body] as the user and adds the message at once (the pot's
  /// reply arrives with `threads_changed`). In a group, [mentions] (pot
  /// IDs) wake only those members and [all] every member; without either
  /// the host wakes. Throws when it fails.
  Future<PostedMessage> post(
    String body, {
    List<String> mentions = const [],
    bool all = false,
  }) async {
    final thread = state.thread;
    final api = ref.read(apiProvider);
    if (thread == null || api == null) throw const NotConnected();
    final posted = await ThreadsApi(
      api,
    ).post(thread.id, body, mentions: mentions, all: all);
    if (ref.mounted && posted.message.seq > 0) {
      state = state.copyWith(
        messages: _merge(state.messages, [posted.message]),
      );
    }
    return posted;
  }

  /// Moves the read position to the newest message when it is past the
  /// one the Gateway has; never backwards, never twice for one message.
  void markNewestRead() {
    final thread = state.thread;
    final seq = state.newestSeq;
    final api = ref.read(apiProvider);
    if (thread == null || api == null || seq <= _readSeq) return;
    _readSeq = seq;
    ThreadsApi(api)
        .markRead(thread.id, seq)
        .then((_) {
          if (ref.mounted) ref.invalidate(threadsProvider);
        })
        .catchError((Object _) {});
  }
}
