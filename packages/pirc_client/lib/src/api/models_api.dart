import 'package:meta/meta.dart';

import '../api_client.dart';
import '../json.dart';

/// A model the Gateway serves (`GET /api/models`).
@immutable
class ModelInfo {
  const ModelInfo({
    required this.provider,
    required this.id,
    required this.name,
    this.reasoning = false,
    this.contextWindow,
  });

  factory ModelInfo.fromJson(Object? json) => ModelInfo(
    provider: str(field(json, 'provider')) ?? '',
    id: text(field(json, 'id')) ?? '',
    name: str(field(json, 'name')) ?? text(field(json, 'id')) ?? '',
    reasoning: field(json, 'reasoning') == true,
    contextWindow: number(field(json, 'contextWindow')),
  );

  final String provider;
  final String id;
  final String name;

  /// Whether the model has thinking levels; without it the row is disabled.
  final bool reasoning;
  final int? contextWindow;
}

class ModelsApi {
  const ModelsApi(this.api);
  final ApiClient api;

  Future<List<ModelInfo>> list() async => [
    for (final model
        in array(field(await api.get('/api/models'), 'models')) ?? const [])
      ModelInfo.fromJson(model),
  ];
}
