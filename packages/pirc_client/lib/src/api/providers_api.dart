import '../api_client.dart';
import '../json.dart';
import '../transport/transport.dart';

/// `/api/providers*` and `/api/provider-auth/*`: model providers, their
/// sign-in and the default model. A paired app needs the `providers`
/// management grant for every call. Replies are kept as JSON maps: the
/// settings pages show them as they are.
class ProvidersApi {
  const ProvidersApi(this.api);
  final ApiClient api;

  /// `{providers, oauthProviders, defaultModel?}`; never holds secrets.
  Future<Map<String, Object?>> snapshot() async =>
      object(await api.get('/api/providers')) ?? const {};

  Future<List<Map<String, Object?>>> presets() async => [
    for (final p
        in array(field(await api.get('/api/providers/presets'), 'presets')) ??
            const [])
      ?object(p),
  ];

  /// Adds a provider: `{id, api, baseUrl, models, apiKey?, preset?}`.
  Future<Map<String, Object?>> add(Map<String, Object?> body) async =>
      object(await api.post('/api/providers', body)) ?? const {};

  /// Edits a provider; leaving out `apiKey` keeps the saved key.
  Future<Map<String, Object?>> edit(
    String id,
    Map<String, Object?> body,
  ) async =>
      object(
        await api.put('/api/providers/${Uri.encodeComponent(id)}', body),
      ) ??
      const {};

  /// Removes a provider, or signs out of an account (`oauth:<id>`).
  Future<Map<String, Object?>> remove(String id) async =>
      object(await api.delete('/api/providers/${Uri.encodeComponent(id)}')) ??
      const {};

  /// Lists the models of an unsaved provider form.
  Future<List<Map<String, Object?>>> discover(
    Map<String, Object?> body,
  ) async => [
    for (final m
        in array(
              field(await api.post('/api/providers/discover', body), 'models'),
            ) ??
            const [])
      ?object(m),
  ];

  /// "Test connection": `{ok, message, latencyMs}`.
  Future<Map<String, Object?>> test(Map<String, Object?> body) async =>
      object(await api.post('/api/providers/test', body)) ?? const {};

  /// Sets the default model, or clears it with null.
  Future<Map<String, Object?>> setDefault(
    String? provider,
    String? id, {
    String? thinking,
  }) async =>
      object(
        await api.json(
          ApiRequest.put(
            '/api/providers/default-model',
            json: provider == null || id == null
                ? null
                : {'provider': provider, 'id': id, 'thinking': ?thinking},
          ),
        ),
      ) ??
      const {};

  /// Starts a sign-in (`providerId` is the bare id, e.g. `anthropic`).
  Future<Map<String, Object?>> signIn(
    String providerId, {
    bool policyConsent = false,
  }) async =>
      object(
        await api.post('/api/provider-auth/sessions', {
          'providerId': providerId,
          if (policyConsent) 'policyConsent': true,
        }),
      ) ??
      const {};

  static String _session(String id) =>
      '/api/provider-auth/sessions/${Uri.encodeComponent(id)}';

  Future<Map<String, Object?>> signInStatus(String id) async =>
      object(await api.get(_session(id))) ?? const {};

  Future<Map<String, Object?>> cancelSignIn(String id) async =>
      object(await api.delete(_session(id))) ?? const {};

  /// Answers a sign-in prompt; a null [value] skips it.
  Future<Map<String, Object?>> answerSignIn(
    String id,
    String promptId,
    String? value,
  ) async =>
      object(
        await api.post('${_session(id)}/input', {
          'promptId': promptId,
          'value': ?value,
        }),
      ) ??
      const {};
}

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

/// `GET /api/modes`: the modes the Gateway serves (snake_case fields).
class ModesApi {
  const ModesApi(this.api);
  final ApiClient api;

  Future<List<Map<String, Object?>>> list() async => [
    for (final m
        in array(field(await api.get('/api/modes'), 'modes')) ?? const [])
      ?object(m),
  ];
}
