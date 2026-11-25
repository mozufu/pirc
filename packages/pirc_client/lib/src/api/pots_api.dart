import 'package:meta/meta.dart';

import '../api_client.dart';
import '../json.dart';

/// A pot as the lists need it (`GET /api/pots`); M7 reads the rest.
@immutable
class PotSummary {
  const PotSummary({
    required this.id,
    required this.name,
    this.state = 'active',
    this.avatarColor = 1,
  });

  factory PotSummary.fromJson(Object? json) => PotSummary(
    id: text(field(json, 'id')) ?? '',
    name: str(field(field(json, 'profile'), 'name')) ?? '',
    state: str(field(json, 'state')) ?? 'active',
    avatarColor: number(field(field(json, 'profile'), 'avatarColor')) ?? 1,
  );

  final String id;
  final String name;

  /// `active`, `paused` or `archived`.
  final String state;

  /// 1–5 (`avatar.<n>`).
  final int avatarColor;
}

/// A work session a pot opened (`GET /api/pot-works`).
@immutable
class PotWork {
  const PotWork({
    required this.id,
    required this.potId,
    required this.sessionId,
    required this.workspaceId,
    required this.title,
    this.provider,
    this.model,
    this.thinking,
    this.state = 'open',
    this.createdAt = 0,
  });

  factory PotWork.fromJson(Object? json) => PotWork(
    id: text(field(json, 'id')) ?? '',
    potId: text(field(json, 'potId')) ?? '',
    sessionId: text(field(json, 'sessionId')) ?? '',
    workspaceId: str(field(json, 'workspaceId')) ?? '',
    title: str(field(json, 'title')) ?? '',
    provider: str(field(json, 'provider')),
    model: str(field(json, 'model')),
    thinking: str(field(json, 'thinking')),
    state: str(field(json, 'state')) ?? 'open',
    createdAt: number(field(json, 'createdAt')) ?? 0,
  );

  final String id;
  final String potId;
  final String sessionId;
  final String workspaceId;
  final String title;
  final String? provider;
  final String? model;
  final String? thinking;

  /// `open` while the pot coordinates it; `taken_over` after the user took
  /// it over.
  final String state;
  final int createdAt;

  bool get open => state == 'open';
}

/// A pot's request to use a "ask you first" model (`/api/model-approvals`).
@immutable
class ModelApproval {
  const ModelApproval({
    required this.id,
    required this.potId,
    required this.workTitle,
    required this.workspaceId,
    required this.model,
    this.provider,
    this.reason = '',
    this.state = 'pending',
    this.createdAt = 0,
  });

  factory ModelApproval.fromJson(Object? json) => ModelApproval(
    id: text(field(json, 'id')) ?? '',
    potId: text(field(json, 'potId')) ?? '',
    workTitle: str(field(json, 'workTitle')) ?? '',
    workspaceId: str(field(json, 'workspaceId')) ?? '',
    model: str(field(json, 'model')) ?? '',
    provider: str(field(json, 'provider')),
    reason: str(field(json, 'reason')) ?? '',
    state: str(field(json, 'state')) ?? 'pending',
    createdAt: number(field(json, 'createdAt')) ?? 0,
  );

  final String id;
  final String potId;
  final String workTitle;
  final String workspaceId;
  final String model;
  final String? provider;
  final String reason;

  /// `pending`, `allowed_once`, `denied` or `used`.
  final String state;
  final int createdAt;
}

/// Pots, the works they open and their model approvals.
class PotsApi {
  const PotsApi(this.api);
  final ApiClient api;

  Future<List<PotSummary>> pots() async => [
    for (final pot
        in array(field(await api.get('/api/pots'), 'pots')) ?? const [])
      PotSummary.fromJson(pot),
  ];

  Future<List<PotWork>> works() async => [
    for (final work
        in array(field(await api.get('/api/pot-works'), 'works')) ?? const [])
      PotWork.fromJson(work),
  ];

  Future<PotWork> work(String id) async => PotWork.fromJson(
    field(await api.get('/api/pot-works/${Uri.encodeComponent(id)}'), 'work'),
  );

  /// Takes the work over: the pot sends no more instructions to it.
  Future<PotWork> takeOver(String workId) async => PotWork.fromJson(
    field(
      await api.post('/api/pot-works/${Uri.encodeComponent(workId)}/take-over'),
      'work',
    ),
  );

  Future<List<ModelApproval>> approvals({String? state}) async => [
    for (final approval
        in array(
              field(
                await api.get('/api/model-approvals', query: {'state': ?state}),
                'approvals',
              ),
            ) ??
            const [])
      ModelApproval.fromJson(approval),
  ];
}
