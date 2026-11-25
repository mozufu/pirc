import 'package:meta/meta.dart';

import '../json.dart';
import 'cursor.dart';

/// One message on `/api/events`.
sealed class EventMessage {
  const EventMessage();

  /// Classifies a decoded frame; null when it is none of the known shapes.
  static EventMessage? fromJson(Object? json) {
    final type = str(field(json, 'type'));
    if (type == null) return null;
    if (type == 'reset') return ResetMessage.fromJson(json);
    if (HintMessage.types.contains(type)) return HintMessage(type);
    final epoch = number(field(json, 'epoch'));
    final sequence = number(field(json, 'sequence'));
    if (epoch == null || sequence == null) return null;
    return SessionEvent(
      sessionId: text(field(json, 'sessionId')) ?? '',
      epoch: epoch,
      sequence: sequence,
      type: type,
      data: field(json, 'data'),
      timestamp: number(field(json, 'timestamp')),
      raw: json,
    );
  }
}

/// A session event `{sessionId, epoch, sequence, type, data?, timestamp}`.
@immutable
class SessionEvent extends EventMessage {
  const SessionEvent({
    required this.sessionId,
    required this.epoch,
    required this.sequence,
    required this.type,
    this.data,
    this.timestamp,
    this.raw,
  });

  final String sessionId;
  final int epoch;
  final int sequence;
  final String type;
  final Object? data;
  final int? timestamp;

  /// The decoded frame, for [normalizeEvent].
  final Object? raw;

  Cursor get cursor => Cursor(epoch, sequence);
}

/// `{type: "reset", reason, watermark}`: only a new snapshot can tell what
/// changed. `backpressure` resets are followed by close code 1013.
@immutable
class ResetMessage extends EventMessage {
  const ResetMessage({required this.reason, this.watermark});

  factory ResetMessage.fromJson(Object? json) => ResetMessage(
    reason: text(field(json, 'reason')) ?? 'cursor_expired',
    watermark: Cursor.fromJson(field(json, 'watermark')),
  );

  final String reason;
  final Cursor? watermark;
}

/// Out-of-sequence hints (`directory_changed`, …); they never move the cursor.
@immutable
class HintMessage extends EventMessage {
  const HintMessage(this.type);

  static const types = {
    'directory_changed',
    'memory_changed',
    'schedules_changed',
    'sessions_changed',
    'pots_changed',
    'threads_changed',
    'approvals_changed',
    'activity_changed',
    'budget_requests_changed',
    'notifications_changed',
    'causal_roots_changed',
  };

  final String type;
}
