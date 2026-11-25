import '../api_client.dart';
import '../json.dart';
import '../models/session.dart';

/// `/api/sessions`: the list and the row actions.
class SessionsApi {
  const SessionsApi(this.api);
  final ApiClient api;

  static String path(String id) => '/api/sessions/${Uri.encodeComponent(id)}';

  Future<List<Session>> list() async => [
    for (final session
        in array(field(await api.get('/api/sessions'), 'sessions')) ?? const [])
      Session.fromJson(session),
  ];

  /// Renames, pins or settles; at least one of them.
  Future<Session> update(
    String id, {
    String? name,
    bool? pinned,
    bool? settled,
  }) async {
    assert(name != null || pinned != null || settled != null);
    final reply = await api.patch(path(id), {
      'name': ?name,
      'pinned': ?pinned,
      'settled': ?settled,
    });
    return Session.fromJson(field(reply, 'session'));
  }

  /// The Gateway refuses this for modes that cannot delete sessions.
  Future<void> delete(String id) => api.delete(path(id));

  /// Clears the unread mark on every device.
  Future<void> markRead(String id) => api.post('${path(id)}/read');
}
