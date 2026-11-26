import 'package:meta/meta.dart' show immutable;

import '../api_client.dart';
import '../errors.dart';
import '../json.dart';
import '../transport/policy.dart';
import '../transport/transport.dart';
import 'management_api.dart';

/// The reply of `POST /api/pairing/requests`.
@immutable
class PairingRequestCreated {
  const PairingRequestCreated({
    required this.id,
    required this.expiresAt,
    required this.serverNow,
    required this.approvePath,
  });

  factory PairingRequestCreated.fromJson(Object? json) => PairingRequestCreated(
    id: text(field(json, 'id')) ?? '',
    expiresAt: number(field(json, 'expiresAt')) ?? 0,
    serverNow: number(field(json, 'serverNow')) ?? 0,
    approvePath: str(field(json, 'approvePath')) ?? '/',
  );

  final String id;
  final int expiresAt;
  final int serverNow;

  /// Where a browser approves the request (`/?pair=<id>`), on the Gateway.
  final String approvePath;
}

/// What a claim answered when it did not fail.
@immutable
sealed class PairingClaim {
  const PairingClaim();
}

/// `202`: not approved yet ([status] `pending`), or approved and waiting for
/// the code (`approved`).
class PairingWaiting extends PairingClaim {
  const PairingWaiting({
    required this.status,
    required this.expiresAt,
    required this.serverNow,
  });

  final String status;
  final int expiresAt;
  final int serverNow;

  bool get approved => status == 'approved';
}

/// `200`: the new device and its token, shown this once.
class PairingClaimed extends PairingClaim {
  const PairingClaimed(this.device, this.token);

  /// The record `GET /api/device` returns.
  final DeviceSummary device;
  final String token;
}

/// A pairing request as the browser's approval page shows it.
@immutable
class PairingApproval {
  const PairingApproval({
    required this.id,
    required this.status,
    required this.expiresAt,
    required this.serverNow,
    required this.deviceName,
    required this.platform,
    this.idleDays,
    this.maxDays,
    this.code,
  });

  factory PairingApproval.fromJson(Object? json) => PairingApproval(
    id: text(field(json, 'id')) ?? '',
    status: str(field(json, 'status')) ?? 'pending',
    expiresAt: number(field(json, 'expiresAt')) ?? 0,
    serverNow: number(field(json, 'serverNow')) ?? 0,
    deviceName: str(field(json, 'deviceName')) ?? '',
    platform: str(field(json, 'platform')) ?? '',
    idleDays: number(field(field(json, 'pairing'), 'idleDays')),
    maxDays: number(field(field(json, 'pairing'), 'maxDays')),
    code: str(field(json, 'code')),
  );

  final String id;

  /// pending, approved, denied, claimed, revoked or expired.
  final String status;
  final int expiresAt;
  final int serverNow;
  final String deviceName;
  final String platform;

  /// The lifetime of the device this request pairs.
  final int? idleDays;
  final int? maxDays;

  /// The 6-digit confirmation code: only for the user who approved it, and
  /// only while the app can still claim.
  final String? code;
}

/// Pairing v2 (`/api/pairing/*`). The app asks first and claims its token
/// with a verifier and the code a browser shows.
///
/// [create] and [claim] need no identity, and the Gateway refuses them with
/// `401 bearer_not_allowed` when an `Authorization` header is sent: call them
/// on a transport without a token. [view], [approve] and [deny] accept only a
/// browser identity.
class PairingApi {
  const PairingApi(this.api);
  final ApiClient api;

  static String _request(String id, [String action = '']) =>
      '/api/pairing/requests/${Uri.encodeComponent(id)}'
      '${action.isEmpty ? '' : '/$action'}';
  static String _approval(String id, [String action = '']) =>
      '/api/pairing/approvals/${Uri.encodeComponent(id)}'
      '${action.isEmpty ? '' : '/$action'}';

  /// [challenge] is the hex SHA-256 of the verifier, which only the app
  /// holds. `429` when 20 requests are open.
  Future<PairingRequestCreated> create({
    required String deviceName,
    required String platform,
    required String challenge,
  }) async => PairingRequestCreated.fromJson(
    await api.post('/api/pairing/requests', {
      'deviceName': deviceName,
      'platform': platform,
      'challenge': challenge,
    }),
  );

  /// Without [code] it only reads whether the request was approved. Throws
  /// `403 invalid_code` (see [attemptsLeft]), `410 pairing_ended` when it was
  /// denied, expired or ended, `404` once the Gateway forgot it, and `409`
  /// when the account already has 10 phones.
  Future<PairingClaim> claim(
    String id, {
    required String verifier,
    String? code,
  }) async {
    final response = checked(
      await api.send(
        ApiRequest.post(
          _request(id, 'claim'),
          json: {'verifier': verifier, 'code': ?code},
        ),
      ),
    );
    final json = response.json();
    if (response.status == 202) {
      return PairingWaiting(
        status: str(field(json, 'status')) ?? 'pending',
        expiresAt: number(field(json, 'expiresAt')) ?? 0,
        serverNow: number(field(json, 'serverNow')) ?? 0,
      );
    }
    return PairingClaimed(
      DeviceSummary.fromJson(field(json, 'device')),
      str(field(json, 'token')) ?? '',
    );
  }

  /// Browser only (the approval page).
  Future<PairingApproval> view(String id) async =>
      PairingApproval.fromJson(await api.get(_approval(id)));

  /// Browser only: binds the request to this user and adds the code.
  Future<PairingApproval> approve(String id) async =>
      PairingApproval.fromJson(await api.post(_approval(id, 'approve')));

  /// Browser only.
  Future<PairingApproval> deny(String id) async =>
      PairingApproval.fromJson(await api.post(_approval(id, 'deny')));

  /// The attempts a `403 invalid_code` leaves; null for any other error.
  static int? attemptsLeft(Object error) =>
      error is ApiError && error.code == 'invalid_code'
      ? number(field(error.details, 'attemptsLeft'))
      : null;
}
