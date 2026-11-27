import 'dart:async';
import 'dart:collection';

/// Keeps one document within the scripts channel's cap on requests in
/// flight. Kotlin refuses a request over the cap rather than queueing it
/// (`ScriptResources.MAX_IN_FLIGHT`), so every caller of
/// `ScriptsPlatform.resource` for a document goes through one limiter.
///
/// Waiting requests start in the order they arrived. A slot is held from the
/// call until it returns, also when the request was cancelled meanwhile:
/// Kotlin frees the request only when its call ends. A waiting request that
/// is cancelled ([cancel]) leaves the queue and never runs.
class DocumentResourceLimiter {
  DocumentResourceLimiter({this.maximum = maxInFlight});

  /// The channel's cap per document.
  static const maxInFlight = 6;

  final int maximum;
  final _waiting = Queue<_Waiter>();
  var _active = 0;
  var _closed = false;

  int get active => _active;
  int get waiting => _waiting.length;

  /// Runs [request] when a slot is free. A request waits while [maximum]
  /// others run. After [close], or when [cancel] names its [id] while it
  /// waits, it fails with a [StateError] and [request] is never called.
  Future<T> run<T>(Future<T> Function() request, {String? id}) async {
    if (_closed) throw StateError('The document closed.');
    if (_active >= maximum) {
      // The slot is handed over by [_release], so no newer caller can take
      // it between the wake-up and this request.
      final turn = _Waiter(id);
      _waiting.add(turn);
      await turn.completer.future;
    } else {
      _active++;
    }
    try {
      return await request();
    } finally {
      _release();
    }
  }

  /// Removes the waiting request [id]; returns whether one was waiting. A
  /// request that already runs is not affected.
  bool cancel(String id) {
    final waiter = _waiting.where((waiter) => waiter.id == id).firstOrNull;
    if (waiter == null) return false;
    _waiting.remove(waiter);
    waiter.completer.completeError(StateError('The request was cancelled.'));
    return true;
  }

  void _release() {
    if (!_closed && _waiting.isNotEmpty) {
      _waiting.removeFirst().completer.complete();
    } else {
      _active--;
    }
  }

  /// Fails every waiting request; running ones end on their own.
  void close() {
    _closed = true;
    while (_waiting.isNotEmpty) {
      _waiting.removeFirst().completer.completeError(
        StateError('The document closed.'),
      );
    }
  }
}

class _Waiter {
  _Waiter(this.id);
  final String? id;
  final completer = Completer<void>();
}
