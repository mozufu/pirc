import '../api_client.dart';
import '../json.dart';
import '../models/binding.dart';
import '../models/control_lease.dart';

/// A session's environment, folder grants and environment transitions
/// (`/api/sessions/{id}/environment*`, `/grants*`). Reads need no lease;
/// writes carry it. Replies are JSON maps (contracts § 7).
class EnvironmentApi {
  const EnvironmentApi(this.api, this.sessionId);
  final ApiClient api;
  final String sessionId;

  String get _base => '/api/sessions/${Uri.encodeComponent(sessionId)}';
  String get _transitions => '$_base/environment-transitions';
  static String _id(String id) => Uri.encodeComponent(id);
  static Map<String, Object?> _lease(ControlLease lease) => {
    'clientId': lease.clientId,
    'generation': lease.generation,
  };

  Future<Map<String, Object?>> _map(Future<Object?> reply) async =>
      object(await reply) ?? const {};

  /// `{binding, activeTransition, lastFinishedTransition, …}`.
  Future<Map<String, Object?>> environment() =>
      _map(api.get('$_base/environment'));

  /// `{grantsEnabled, effectiveAccess:{grants:[…], …}}`.
  Future<Map<String, Object?>> grants() => _map(api.get('$_base/grants'));

  Future<Map<String, Object?>> addGrant(
    String path,
    String access,
    ControlLease lease,
  ) => _map(
    api.post('$_base/grants', {
      'path': path,
      'access': access,
      ..._lease(lease),
    }),
  );

  Future<Map<String, Object?>> revokeGrant(
    String grantId,
    ControlLease lease,
  ) => _map(api.post('$_base/grants/${_id(grantId)}/revoke', _lease(lease)));

  /// A preview changes nothing. [operationId] is the client's.
  Future<Map<String, Object?>> preview({
    required String operationId,
    required String targetWorkspaceId,
    required ExpectedBinding binding,
  }) => _map(
    api.post('$_transitions/previews', {
      'operationId': operationId,
      'targetWorkspaceId': targetWorkspaceId,
      'expectedBinding': binding.toJson(),
    }),
  );

  Future<Map<String, Object?>> confirm(
    String operationId, {
    required String planHash,
    String? observationHash,
    required ControlLease lease,
  }) => _map(
    api.post('$_transitions/previews/${_id(operationId)}/confirm', {
      'planHash': planHash,
      'observationHash': ?observationHash,
      ..._lease(lease),
    }),
  );

  /// The status read model; for a device without control.
  Future<Map<String, Object?>> receipt(String operationId) =>
      _map(api.get('$_transitions/receipts/${_id(operationId)}'));

  /// Continues the drain and install; also how the controlling device polls.
  Future<Map<String, Object?>> advance(
    String operationId,
    ControlLease lease,
  ) => _map(
    api.post('$_transitions/${_id(operationId)}/advance', _lease(lease)),
  );

  Future<Map<String, Object?>> acknowledge(
    String operationId, {
    required String digest,
    String? evaluationId,
    required ControlLease lease,
  }) => _map(
    api.post('$_transitions/${_id(operationId)}/acknowledge', {
      'digest': digest,
      'evaluationId': ?evaluationId,
      ..._lease(lease),
    }),
  );

  Future<Map<String, Object?>> cancel(String operationId, ControlLease lease) =>
      _map(api.post('$_transitions/${_id(operationId)}/cancel', _lease(lease)));

  Future<Map<String, Object?>> reauthorize(
    String operationId,
    ControlLease lease,
  ) => _map(
    api.post('$_transitions/${_id(operationId)}/reauthorize', _lease(lease)),
  );
}
