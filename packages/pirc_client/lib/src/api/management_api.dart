import 'package:meta/meta.dart';

import '../api_client.dart';
import '../json.dart';

/// A native management request as the Gateway shows it
/// (`/api/native-management/requests/{id}`).
@immutable
class ManagementRequest {
  const ManagementRequest({
    required this.id,
    required this.status,
    required this.expiresAt,
    required this.serverNow,
    required this.deviceName,
    required this.capabilities,
    this.pairingIdleDays,
    this.pairingMaxDays,
    this.verificationPath,
  });

  factory ManagementRequest.fromJson(Object? json) => ManagementRequest(
    id: text(field(json, 'id')) ?? '',
    status: str(field(json, 'status')) ?? 'pending',
    expiresAt: number(field(json, 'expiresAt')) ?? 0,
    serverNow: number(field(json, 'serverNow')) ?? 0,
    deviceName: str(field(json, 'deviceName')) ?? '',
    capabilities: [
      for (final c in array(field(json, 'capabilities')) ?? const [])
        if (c is String) c,
    ],
    pairingIdleDays: number(field(field(json, 'pairing'), 'idleDays')),
    pairingMaxDays: number(field(field(json, 'pairing'), 'maxDays')),
    verificationPath: str(field(json, 'verificationPath')),
  );

  final String id;

  /// pending, approved, denied, claimed, revoked or expired.
  final String status;
  final int expiresAt;
  final int serverNow;
  final String deviceName;

  /// `providers`, `devices:read`, `devices:revoke`, `devices:pair`.
  final List<String> capabilities;

  /// The lifetime of a device this grant could pair (`devices:pair`).
  final int? pairingIdleDays;
  final int? pairingMaxDays;

  /// Where a browser approves it (`/?nativeManagement=<id>`); only in the
  /// create reply.
  final String? verificationPath;
}

/// A claimed grant: sent as `x-pirc-management`, kept in memory only.
@immutable
class ManagementGrantToken {
  const ManagementGrantToken({
    required this.token,
    required this.expiresAt,
    required this.serverNow,
    required this.capabilities,
  });

  factory ManagementGrantToken.fromJson(Object? json) => ManagementGrantToken(
    token: str(field(json, 'token')) ?? '',
    expiresAt: number(field(json, 'expiresAt')) ?? 0,
    serverNow: number(field(json, 'serverNow')) ?? 0,
    capabilities: [
      for (final c in array(field(json, 'capabilities')) ?? const [])
        if (c is String) c,
    ],
  );

  final String token;
  final int expiresAt;
  final int serverNow;
  final List<String> capabilities;
}

/// `/api/native-management/requests`: a paired app asks, a browser approves,
/// the app claims the grant with its verifier.
class ManagementApi {
  const ManagementApi(this.api);
  final ApiClient api;

  static const _base = '/api/native-management/requests';
  static String _path(String id, [String action = '']) =>
      '$_base/${Uri.encodeComponent(id)}${action.isEmpty ? '' : '/$action'}';

  /// [challenge] is the hex SHA-256 of the verifier; at most two
  /// capabilities.
  Future<ManagementRequest> create({
    required String challenge,
    required List<String> capabilities,
    bool replace = false,
  }) async => ManagementRequest.fromJson(
    await api.post(_base, {
      'challenge': challenge,
      'capabilities': capabilities,
      if (replace) 'replace': true,
    }),
  );

  Future<ManagementRequest> view(String id) async =>
      ManagementRequest.fromJson(await api.get(_path(id)));

  Future<ManagementGrantToken> claim(String id, String verifier) async =>
      ManagementGrantToken.fromJson(
        await api.post(_path(id, 'claim'), {'verifier': verifier}),
      );

  Future<ManagementRequest> cancel(String id) async =>
      ManagementRequest.fromJson(await api.delete(_path(id)));

  /// Browser only (the approval screen).
  Future<ManagementRequest> approve(String id) async =>
      ManagementRequest.fromJson(await api.post(_path(id, 'approve')));

  /// Browser only (the approval screen).
  Future<ManagementRequest> deny(String id) async =>
      ManagementRequest.fromJson(await api.post(_path(id, 'deny')));
}

/// A paired device (`GET /api/devices`).
@immutable
class DeviceSummary {
  const DeviceSummary({
    required this.id,
    required this.name,
    this.createdAt = 0,
    this.lastUsedAt = 0,
    this.expiresAt = 0,
    this.idleExpiresAt = 0,
    this.maxAgeMs = 0,
  });

  factory DeviceSummary.fromJson(Object? json) => DeviceSummary(
    id: text(field(json, 'id')) ?? '',
    name: str(field(json, 'name')) ?? '',
    createdAt: number(field(json, 'createdAt')) ?? 0,
    lastUsedAt: number(field(json, 'lastUsedAt')) ?? 0,
    expiresAt: number(field(json, 'expiresAt')) ?? 0,
    idleExpiresAt: number(field(json, 'idleExpiresAt')) ?? 0,
    maxAgeMs: number(field(json, 'maxAgeMs')) ?? 0,
  );

  final String id;
  final String name;
  final int createdAt;
  final int lastUsedAt;

  /// In `GET /api/devices`, when the token dies if it is not used again (the
  /// earlier of the two windows). In `GET /api/device` and the pairing and
  /// rotation replies, the end of the maximum window.
  final int expiresAt;

  /// The end of the idle window; 0 when the Gateway did not send it.
  final int idleExpiresAt;

  /// The length of the maximum window (`GET /api/device` and the pairing and
  /// rotation replies); 0 when the Gateway did not send it.
  final int maxAgeMs;

  /// When the token dies without another use: the earlier of the idle and
  /// the maximum window.
  int get effectiveExpiresAt => idleExpiresAt > 0 && idleExpiresAt < expiresAt
      ? idleExpiresAt
      : expiresAt;
}

/// `/api/devices`; a paired app needs the management grant for each call.
class DevicesApi {
  const DevicesApi(this.api);
  final ApiClient api;

  Future<List<DeviceSummary>> list() async => [
    for (final d
        in array(field(await api.get('/api/devices'), 'devices')) ?? const [])
      DeviceSummary.fromJson(d),
  ];

  /// Pairs a new device; the token is shown once.
  Future<(DeviceSummary, String)> pair(String name) async {
    final reply = await api.post('/api/devices', {'name': name});
    return (
      DeviceSummary.fromJson(field(reply, 'device')),
      str(field(reply, 'token')) ?? '',
    );
  }

  Future<void> revoke(String id) =>
      api.delete('/api/devices/${Uri.encodeComponent(id)}');
}
