import 'package:meta/meta.dart';

import '../api_client.dart';
import '../json.dart';

/// A workspace as a node registered it (`GET /api/nodes`).
@immutable
class NodeWorkspace {
  const NodeWorkspace({
    required this.id,
    required this.displayName,
    this.mode,
    this.available = true,
  });

  factory NodeWorkspace.fromJson(Object? json) => NodeWorkspace(
    id: text(field(json, 'id')) ?? '',
    displayName: str(field(json, 'displayName')) ?? '',
    mode: str(field(json, 'mode')),
    available: field(json, 'available') != false,
  );

  /// The node's own id (without the `<nodeId>:` prefix).
  final String id;
  final String displayName;
  final String? mode;

  /// False when the Gateway does not know its mode.
  final bool available;
}

/// A connected node (host). Offline nodes are not listed.
@immutable
class NodeInfo {
  const NodeInfo({
    required this.id,
    this.role,
    this.modes = const [],
    this.workspaces = const [],
    this.connectedAt,
    this.lastSeenAt,
  });

  factory NodeInfo.fromJson(Object? json) => NodeInfo(
    id: text(field(json, 'id')) ?? '',
    role: str(field(json, 'role')),
    modes: [
      for (final mode in array(field(json, 'modes')) ?? const [])
        if (mode is String) mode,
    ],
    workspaces: [
      for (final workspace in array(field(json, 'workspaces')) ?? const [])
        NodeWorkspace.fromJson(workspace),
    ],
    connectedAt: number(field(json, 'connectedAt')),
    lastSeenAt: number(field(json, 'lastSeenAt')),
  );

  final String id;
  final String? role;
  final List<String> modes;
  final List<NodeWorkspace> workspaces;
  final int? connectedAt;
  final int? lastSeenAt;
}

/// A workspace (project) the user can see (`GET /api/workspaces`).
@immutable
class WorkspaceInfo {
  const WorkspaceInfo({
    required this.id,
    required this.hostId,
    required this.displayName,
    this.mode,
    this.kind,
    this.available = true,
    this.deleting = false,
  });

  factory WorkspaceInfo.fromJson(Object? json) => WorkspaceInfo(
    id: text(field(json, 'id')) ?? '',
    hostId: str(field(json, 'hostId')) ?? '',
    displayName: str(field(json, 'displayName')) ?? '',
    mode: str(field(json, 'mode')),
    kind: str(field(json, 'kind')),
    available: field(json, 'available') != false,
    deleting: field(json, 'deleting') == true,
  );

  /// `<nodeId>:<local id>`.
  final String id;
  final String hostId;
  final String displayName;
  final String? mode;

  /// `chat` or `directory`, when the Gateway knows the mode.
  final String? kind;
  final bool available;

  /// Its deletion has not finished; only its owner sees it.
  final bool deleting;

  /// The node that hosts it: the part before the first `:`.
  String get nodeId {
    final colon = id.indexOf(':');
    return colon < 0 ? hostId : id.substring(0, colon);
  }
}

/// Nodes and workspaces.
class DirectoryApi {
  const DirectoryApi(this.api);
  final ApiClient api;

  Future<List<NodeInfo>> nodes() async => [
    for (final node
        in array(field(await api.get('/api/nodes'), 'nodes')) ?? const [])
      NodeInfo.fromJson(node),
  ];

  Future<List<WorkspaceInfo>> workspaces() async => [
    for (final workspace
        in array(field(await api.get('/api/workspaces'), 'workspaces')) ??
            const [])
      WorkspaceInfo.fromJson(workspace),
  ];
}
