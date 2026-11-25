import 'package:meta/meta.dart';

import '../api_client.dart';
import '../json.dart';

/// One client of the account that took control of a session, as
/// `GET /api/clients` lists it.
@immutable
class GatewayClient {
  const GatewayClient({
    required this.clientId,
    required this.name,
    required this.kind,
    this.deviceId,
    this.lastSeenAt = 0,
  });

  factory GatewayClient.fromJson(Object? json) => GatewayClient(
    clientId: str(field(json, 'clientId')) ?? '',
    name: str(field(json, 'name')) ?? '',
    kind: str(field(json, 'kind')) ?? '',
    deviceId: str(field(json, 'deviceId')),
    lastSeenAt: number(field(json, 'lastSeenAt')) ?? 0,
  );

  final String clientId;
  final String name;

  /// `device` (a paired app) or `browser`.
  final String kind;

  /// The paired device's record; absent for a browser.
  final String? deviceId;
  final int lastSeenAt;

  bool get isDevice => kind == 'device';
}

/// `/api/clients`: the account's clients that took control, most recently
/// seen first, and a browser's rename.
class ClientsApi {
  const ClientsApi(this.api);
  final ApiClient api;

  Future<List<GatewayClient>> list() async => [
    for (final c
        in array(field(await api.get('/api/clients'), 'clients')) ?? const [])
      GatewayClient.fromJson(c),
  ];

  /// Renames a browser; a paired device renames itself with [DeviceApi].
  Future<GatewayClient> rename(String clientId, String name) async {
    final reply = await api.put(
      '/api/clients/${Uri.encodeComponent(clientId)}',
      {'name': name},
    );
    return GatewayClient.fromJson(field(reply, 'client'));
  }
}
