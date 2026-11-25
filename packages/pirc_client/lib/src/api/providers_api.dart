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
