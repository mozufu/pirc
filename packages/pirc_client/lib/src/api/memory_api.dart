import '../api_client.dart';
import '../json.dart';

/// `/api/memory`: the user's memory. Only the agent writes entries; the user
/// approves or rejects proposals, forgets and restores.
class MemoryApi {
  const MemoryApi(this.api);
  final ApiClient api;

  static String _id(String id) => Uri.encodeComponent(id);

  /// `{usage, user, notes, removed, proposals, sessions}`.
  Future<Map<String, Object?>> view() async =>
      object(await api.get('/api/memory')) ?? const {};

  Future<Map<String, Object?>> approve(
    String id, {
    int? targetRevision,
  }) async =>
      object(
        await api.post('/api/memory/proposals/${_id(id)}/approve', {
          'targetRevision': ?targetRevision,
        }),
      ) ??
      const {};

  Future<Map<String, Object?>> reject(String id) async =>
      object(await api.post('/api/memory/proposals/${_id(id)}/reject')) ??
      const {};

  /// Wipes the entry and keeps the same text from coming back.
  Future<Map<String, Object?>> forget(String id) async =>
      object(await api.post('/api/memory/entries/${_id(id)}/forget')) ??
      const {};

  Future<Map<String, Object?>> restore(String id, {int? revision}) async =>
      object(
        await api.post('/api/memory/entries/${_id(id)}/restore', {
          'revision': ?revision,
        }),
      ) ??
      const {};
}
