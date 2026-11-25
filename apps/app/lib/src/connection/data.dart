import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pirc_client/pirc_client.dart';

import 'connection.dart';
import 'hints.dart';

/// The API client of the current connection (kept while offline, so a read
/// fails like any request instead of waiting); null before the first one.
final apiProvider = Provider<ApiClient?>(
  (ref) => ref.watch(connectionProvider.select((s) => s.connection?.api)),
);

/// Thrown by list providers while there is no connection yet.
class NotConnected implements Exception {
  const NotConnected();
}

ApiClient requireApi(Ref ref) =>
    ref.watch(apiProvider) ?? (throw const NotConnected());

/// Connected hosts; read again on `directory_changed`.
final nodesProvider = FutureProvider<List<NodeInfo>>((ref) {
  watchHint(ref, 'directory_changed');
  return DirectoryApi(requireApi(ref)).nodes();
});

/// Workspaces (projects); read again on `directory_changed` and
/// `sessions_changed` (a new project is announced as both).
final workspacesProvider = FutureProvider<List<WorkspaceInfo>>((ref) {
  watchHint(ref, 'directory_changed');
  watchHint(ref, 'sessions_changed');
  return DirectoryApi(requireApi(ref)).workspaces();
});

/// The user's sessions; read again on `sessions_changed`.
final sessionsProvider = FutureProvider<List<Session>>((ref) {
  watchHint(ref, 'sessions_changed');
  return SessionsApi(requireApi(ref)).list();
});
