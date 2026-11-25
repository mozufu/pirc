import 'package:meta/meta.dart';

import '../json.dart';

/// Which workspace membership a conversation belongs to.
@immutable
class BindingMembership {
  const BindingMembership({
    required this.revision,
    required this.legacyWorkspaceId,
  });

  factory BindingMembership.fromJson(Object? json) => BindingMembership(
    revision: number(field(json, 'revision')) ?? 0,
    legacyWorkspaceId: str(field(json, 'legacyWorkspaceId')) ?? '',
  );

  final int revision;
  final String legacyWorkspaceId;

  Map<String, Object?> toJson() => {
    'revision': revision,
    'legacyWorkspaceId': legacyWorkspaceId,
  };

  @override
  bool operator ==(Object other) =>
      other is BindingMembership &&
      other.revision == revision &&
      other.legacyWorkspaceId == legacyWorkspaceId;

  @override
  int get hashCode => Object.hash(revision, legacyWorkspaceId);
}

/// Where a conversation runs: the execution generation, workspace, node and mode.
@immutable
class BindingExecution {
  const BindingExecution({
    required this.generation,
    required this.workspaceId,
    this.nodeId,
    required this.modeId,
  });

  factory BindingExecution.fromJson(Object? json) => BindingExecution(
    generation: number(field(json, 'generation')) ?? 0,
    workspaceId: str(field(json, 'workspaceId')) ?? '',
    nodeId: str(field(json, 'nodeId')),
    modeId: str(field(json, 'modeId')) ?? '',
  );

  final int generation;
  final String workspaceId;
  final String? nodeId;
  final String modeId;

  /// `nodeId` is always present (explicit `null` when unset).
  Map<String, Object?> toJson() => {
    'generation': generation,
    'workspaceId': workspaceId,
    'nodeId': nodeId,
    'modeId': modeId,
  };

  @override
  bool operator ==(Object other) =>
      other is BindingExecution &&
      other.generation == generation &&
      other.workspaceId == workspaceId &&
      other.nodeId == nodeId &&
      other.modeId == modeId;

  @override
  int get hashCode => Object.hash(generation, workspaceId, nodeId, modeId);
}

/// A session's durable environment identity (`session.binding`). Commands send
/// it back as `expectedBinding`; the gateway refuses unknown fields, so
/// [toJson] writes exactly `version`, `membership` and `execution`.
@immutable
class ExpectedBinding {
  const ExpectedBinding({
    this.version = 1,
    required this.membership,
    required this.execution,
  });

  factory ExpectedBinding.fromJson(Object? json) => ExpectedBinding(
    version: number(field(json, 'version')) ?? 0,
    membership: BindingMembership.fromJson(field(json, 'membership')),
    execution: BindingExecution.fromJson(field(json, 'execution')),
  );

  /// Null when [json] is not an object.
  static ExpectedBinding? maybe(Object? json) =>
      json is Map ? ExpectedBinding.fromJson(json) : null;

  final int version;
  final BindingMembership membership;
  final BindingExecution execution;

  /// Whether this client understands the binding (version 1, consistent ids).
  bool isValidFor(String workspaceId) =>
      version == 1 &&
      workspaceId.isNotEmpty &&
      membership.revision >= 1 &&
      membership.legacyWorkspaceId == workspaceId &&
      execution.generation >= 1 &&
      execution.workspaceId == workspaceId &&
      (execution.nodeId == null || execution.nodeId!.isNotEmpty) &&
      execution.modeId.isNotEmpty;

  Map<String, Object?> toJson() => {
    'version': version,
    'membership': membership.toJson(),
    'execution': execution.toJson(),
  };

  @override
  bool operator ==(Object other) =>
      other is ExpectedBinding &&
      other.version == version &&
      other.membership == membership &&
      other.execution == execution;

  @override
  int get hashCode => Object.hash(version, membership, execution);
}
