import '../api_client.dart';
import '../json.dart';
import '../transport/transport.dart';

/// `/api/push`: push targets and the test notification.
class PushApi {
  const PushApi(this.api);
  final ApiClient api;

  /// `{publicKey, subscriptions:[{id, kind, name, host, createdAt,
  /// lastSuccessAt, failing}]}`.
  Future<Map<String, Object?>> status() async =>
      object(await api.get('/api/push')) ?? const {};

  Future<void> remove(String id) => api.json(
    ApiRequest('DELETE', '/api/push/subscriptions', json: {'id': id}),
  );

  /// Returns how many targets it reached.
  Future<int> sendTest() async =>
      number(field(await api.post('/api/push/test'), 'delivered')) ?? 0;
}
