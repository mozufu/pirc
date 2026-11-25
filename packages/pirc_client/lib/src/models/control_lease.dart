import 'package:meta/meta.dart';

import '../json.dart';

/// Who may drive a session (`GET /api/sessions/{id}/control`). TTL 30 s.
@immutable
class ControlLease {
  const ControlLease({
    required this.clientId,
    required this.generation,
    this.expiresAt,
    this.expired = false,
  });

  factory ControlLease.fromJson(Object? json) => ControlLease(
    clientId: text(field(json, 'clientId')) ?? '',
    generation: number(field(json, 'generation')) ?? 0,
    expiresAt: number(field(json, 'expiresAt')),
    expired: field(json, 'expired') == true,
  );

  /// The `lease` field of a control reply; null when nobody holds control.
  static ControlLease? fromReply(Object? json) {
    final lease = field(json, 'lease');
    return lease == null ? null : ControlLease.fromJson(lease);
  }

  final String clientId;
  final int generation;
  final int? expiresAt;
  final bool expired;
}
