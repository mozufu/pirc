import 'package:meta/meta.dart';

import '../json.dart';
import 'binding.dart';

/// A session as the gateway reports it (`snapshot.session`, session lists).
@immutable
class Session {
  const Session({
    required this.id,
    required this.workspaceId,
    required this.name,
    this.nameSource,
    this.nodeId,
    this.runnerState = 'stopped',
    this.runStatus,
    this.runnerEpoch,
    this.pinnedAt,
    this.settledAt,
    this.unread = false,
    this.createdAt = 0,
    this.updatedAt = 0,
    this.binding,
  });

  factory Session.fromJson(Object? json) => Session(
    id: text(field(json, 'id')) ?? '',
    workspaceId: str(field(json, 'workspaceId')) ?? '',
    name: str(field(json, 'name')) ?? '',
    nameSource: str(field(json, 'nameSource')),
    nodeId: str(field(json, 'nodeId')),
    runnerState: str(field(json, 'runnerState')) ?? 'stopped',
    runStatus: str(field(json, 'runStatus')),
    runnerEpoch: number(field(json, 'runnerEpoch')),
    pinnedAt: number(field(json, 'pinnedAt')),
    settledAt: number(field(json, 'settledAt')),
    unread: truthy(field(json, 'unread')),
    createdAt: number(field(json, 'createdAt')) ?? 0,
    updatedAt: number(field(json, 'updatedAt')) ?? 0,
    binding: ExpectedBinding.maybe(field(json, 'binding')),
  );

  final String id;
  final String workspaceId;
  final String name;

  /// `user` or `auto`.
  final String? nameSource;
  final String? nodeId;
  final String runnerState;
  final String? runStatus;
  final int? runnerEpoch;
  final int? pinnedAt;
  final int? settledAt;
  final bool unread;
  final int createdAt;
  final int updatedAt;

  /// Durable environment identity; commands echo it as `expectedBinding`.
  final ExpectedBinding? binding;

  bool get pinned => pinnedAt != null;
  bool get settled => settledAt != null;

  Session copyWith({String? name}) => Session(
    id: id,
    workspaceId: workspaceId,
    name: name ?? this.name,
    nameSource: nameSource,
    nodeId: nodeId,
    runnerState: runnerState,
    runStatus: runStatus,
    runnerEpoch: runnerEpoch,
    pinnedAt: pinnedAt,
    settledAt: settledAt,
    unread: unread,
    createdAt: createdAt,
    updatedAt: updatedAt,
    binding: binding,
  );
}
