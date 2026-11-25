import 'package:meta/meta.dart';

import '../json.dart';

/// Who holds the control lease, as `GET …/control` names it: a paired device
/// by its device record or a browser by the name it sent (else its user agent).
@immutable
class ControlHolder {
  const ControlHolder({
    required this.name,
    required this.kind,
    this.lastActionAt,
  });

  factory ControlHolder.fromJson(Object? json) => ControlHolder(
    name: str(field(json, 'name')) ?? '',
    kind: str(field(json, 'kind')) ?? '',
    lastActionAt: number(field(json, 'lastActionAt')),
  );

  final String name;

  /// `device` (a paired app) or `browser`.
  final String kind;

  /// When the holder last sent a command or an answer in this session.
  final int? lastActionAt;
}

/// Who may drive a session (`GET /api/sessions/{id}/control`). TTL 30 s.
@immutable
class ControlLease {
  const ControlLease({
    required this.clientId,
    required this.generation,
    this.expiresAt,
    this.expired = false,
    this.holder,
  });

  factory ControlLease.fromJson(Object? json) => ControlLease(
    clientId: text(field(json, 'clientId')) ?? '',
    generation: number(field(json, 'generation')) ?? 0,
    expiresAt: number(field(json, 'expiresAt')),
    expired: field(json, 'expired') == true,
    holder: field(json, 'holder') == null
        ? null
        : ControlHolder.fromJson(field(json, 'holder')),
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

  /// The holder's name; null on older Gateways or before it is resolved.
  final ControlHolder? holder;

  ControlLease copyWith({ControlHolder? holder}) => ControlLease(
    clientId: clientId,
    generation: generation,
    expiresAt: expiresAt,
    expired: expired,
    holder: holder ?? this.holder,
  );
}
