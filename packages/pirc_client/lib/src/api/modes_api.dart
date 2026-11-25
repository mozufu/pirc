import '../api_client.dart';
import '../json.dart';

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
