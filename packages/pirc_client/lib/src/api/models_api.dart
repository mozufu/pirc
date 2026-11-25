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
    this.thinkingLevels = const [],
  });

  factory ModelInfo.fromJson(Object? json) => ModelInfo(
    provider: str(field(json, 'provider')) ?? '',
    id: text(field(json, 'id')) ?? '',
    name: str(field(json, 'name')) ?? text(field(json, 'id')) ?? '',
    reasoning: field(json, 'reasoning') == true,
    contextWindow: number(field(json, 'contextWindow')),
    thinkingLevels: [
      for (final level in array(field(json, 'thinkingLevels')) ?? const [])
        ?str(level),
    ],
  );

  final String provider;
  final String id;
  final String name;

  /// Whether the model has thinking levels; without it the row is disabled.
  final bool reasoning;
  final int? contextWindow;

  /// The levels it accepts, from `minimal`, `low`, `medium`, `high`,
  /// `xhigh` and `max`; empty without thinking.
  ///
  /// Provisional: the Gateway adds it in M7 step 0.
  final List<String> thinkingLevels;
}

/// The Gateway's default model.
@immutable
class DefaultModel {
  const DefaultModel({required this.provider, required this.id, this.thinking});

  factory DefaultModel.fromJson(Object? json) => DefaultModel(
    provider: str(field(json, 'provider')) ?? '',
    id: text(field(json, 'id')) ?? '',
    thinking: str(field(json, 'thinking')),
  );

  final String provider;
  final String id;
  final String? thinking;
}

/// The models and the default one.
@immutable
class ModelCatalog {
  const ModelCatalog({this.models = const [], this.defaultModel});

  factory ModelCatalog.fromJson(Object? json) => ModelCatalog(
    models: [
      for (final model in array(field(json, 'models')) ?? const [])
        ModelInfo.fromJson(model),
    ],
    defaultModel: field(json, 'defaultModel') is Map
        ? DefaultModel.fromJson(field(json, 'defaultModel'))
        : null,
  );

  final List<ModelInfo> models;

  /// Null when none is set (provisional, step 0).
  final DefaultModel? defaultModel;
}

class ModelsApi {
  const ModelsApi(this.api);
  final ApiClient api;

  Future<List<ModelInfo>> list() async => (await catalog()).models;

  /// The models with the Gateway's default model.
  Future<ModelCatalog> catalog() async =>
      ModelCatalog.fromJson(await api.get('/api/models'));
}
