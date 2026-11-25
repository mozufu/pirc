import 'package:meta/meta.dart';

import '../json.dart';
import 'cursor.dart';
import 'session.dart';

/// The top level of `GET /api/sessions/{id}/snapshot`. The timeline parts
/// (history, partial message, interactions, …) are read by `snapshotState`
/// from [raw]; this type keeps what transport and commands need.
@immutable
class SessionSnapshot {
  const SessionSnapshot({
    required this.session,
    required this.watermark,
    this.partialOutputLost = false,
    required this.raw,
  });

  factory SessionSnapshot.fromJson(Object? json) => SessionSnapshot(
    session: Session.fromJson(field(json, 'session')),
    watermark: Cursor.fromJson(field(json, 'watermark')) ?? const Cursor(0, 0),
    partialOutputLost: field(json, 'partialOutputLost') == true,
    raw: object(json) ?? const {},
  );

  final Session session;

  /// Where the event stream resumes after this snapshot.
  final Cursor watermark;
  final bool partialOutputLost;
  final Map<String, Object?> raw;
}
