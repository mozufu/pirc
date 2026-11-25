import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pirc_client/pirc_client.dart';

import 'connection.dart';

/// The hints the app subscribes to (default B: lists read again on hints).
const appHintKinds = {
  'directory',
  'memory',
  'schedules',
  'sessions',
  'pots',
  'approvals',
};

/// A counter per hint type (`sessions_changed`, …). A list provider watches
/// its counters and reads again when one moves. Every (re)connect moves all
/// of them: the Gateway replays nothing.
final hintRevisionsProvider = NotifierProvider<HintRevisions, Map<String, int>>(
  HintRevisions.new,
);

class HintRevisions extends Notifier<Map<String, int>> {
  @override
  Map<String, int> build() => const {};

  void bump(String type) => state = {...state, type: (state[type] ?? 0) + 1};

  void bumpAll() => state = {
    for (final kind in appHintKinds) '${_snake(kind)}_changed': 0,
    ...state,
  }.map((key, value) => MapEntry(key, value + 1));

  static String _snake(String kind) => kind.replaceAllMapped(
    RegExp('[A-Z]'),
    (match) => '_${match[0]!.toLowerCase()}',
  );
}

/// Watches the revision of [type]; use inside a provider that reads a list.
int watchHint(Ref ref, String type) => ref.watch(
  hintRevisionsProvider.select((revisions) => revisions[type] ?? 0),
);

/// Runs the `/api/hints` socket while the connection is online and reports
/// its state.
final hintsProvider = NotifierProvider<HintsController, EventConnectionState>(
  HintsController.new,
);

class HintsController extends Notifier<EventConnectionState> {
  HintStream? _stream;

  @override
  EventConnectionState build() {
    final connection = ref.watch(
      connectionProvider.select(
        (status) =>
            status.phase == ConnectionPhase.online ? status.connection : null,
      ),
    );
    if (connection == null) return EventConnectionState.idle;
    final stream = HintStream(
      transport: connection.transport,
      kinds: appHintKinds,
    );
    _stream = stream;
    final subscription = stream.signals.listen(_onSignal);
    ref.onDispose(() {
      unawaited(subscription.cancel());
      unawaited(stream.close());
      if (identical(_stream, stream)) _stream = null;
    });
    stream.start();
    return stream.state;
  }

  void _onSignal(HintSignal signal) {
    final revisions = ref.read(hintRevisionsProvider.notifier);
    switch (signal) {
      case HintArrived(:final type):
        revisions.bump(type);
      case HintsReadAgain():
        revisions.bumpAll();
      case HintConnectionChanged(state: final next):
        state = next;
      case HintsStopped(:final error):
        ref.read(connectionProvider.notifier).report(error);
    }
  }

  void retryNow() => _stream?.retryNow();
}

/// The connection state the screens show.
final appConnectionStateProvider = Provider<AppConnectionState>((ref) {
  final phase = ref.watch(connectionProvider.select((status) => status.phase));
  final hints = ref.watch(hintsProvider);
  return switch (phase) {
    ConnectionPhase.starting ||
    ConnectionPhase.connecting => AppConnectionState.connecting,
    ConnectionPhase.unpaired => AppConnectionState.unpaired,
    ConnectionPhase.offline => AppConnectionState.offline,
    ConnectionPhase.upgradeRequired => AppConnectionState.upgradeRequired,
    ConnectionPhase.signedOut => AppConnectionState.signedOut,
    ConnectionPhase.online =>
      hints == EventConnectionState.waiting
          ? AppConnectionState.reconnecting
          : AppConnectionState.online,
  };
});
