import '../api_client.dart';
import '../json.dart';
import '../transport/transport.dart';

/// `/api/push`: push targets and the test notification.
class PushApi {
  const PushApi(this.api);
  final ApiClient api;

  /// `{publicKey, subscriptions:[{id, kind, name, host, createdAt,
  /// lastSuccessAt, failing, levels, quietHours, timeZone, lockScreen,
  /// digestAt, revision}]}`.
  Future<Map<String, Object?>> status() async =>
      object(await api.get('/api/push')) ?? const {};

  Future<void> remove(String id) => api.json(
    ApiRequest('DELETE', '/api/push/subscriptions', json: {'id': id}),
  );

  /// `PATCH /api/push/subscriptions/{id}`: changes one target's
  /// notification preferences at [revision] (only the given fields). Returns
  /// the target with its new revision. A stale revision is an [ApiError] 409
  /// `revision_mismatch` whose `details['subscription']` is the current
  /// target.
  Future<Map<String, Object?>> update(
    String id, {
    required int revision,
    Map<String, String>? levels,
    bool setQuietHours = false,
    ({String start, String end})? quietHours,
    String? timeZone,
    String? lockScreen,
    String? digestAt,
  }) async {
    final reply = await api.patch(
      '/api/push/subscriptions/${Uri.encodeComponent(id)}',
      {
        'revision': revision,
        'levels': ?levels,
        if (setQuietHours)
          'quietHours': quietHours == null
              ? null
              : {'start': quietHours.start, 'end': quietHours.end},
        'timeZone': ?timeZone,
        'lockScreen': ?lockScreen,
        'digestAt': ?digestAt,
      },
    );
    return object(field(reply, 'subscription')) ?? const {};
  }

  /// Returns how many targets it reached.
  Future<int> sendTest() async =>
      number(field(await api.post('/api/push/test'), 'delivered')) ?? 0;
}
