import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pirc_client/pirc_client.dart';

import '../connection/connection.dart';
import '../connection/data.dart';
import '../connection/storage.dart';

/// A browser's chosen name from `GET /api/clients`, keyed by client ID. It is
/// read once and again whenever an unknown ID appears (an event only carries
/// the ID).
final clientNamesProvider =
    NotifierProvider<ClientNames, Map<String, GatewayClient>>(ClientNames.new);

class ClientNames extends Notifier<Map<String, GatewayClient>> {
  @override
  Map<String, GatewayClient> build() => const {};

  /// The client for [clientId], reading `GET /api/clients` when it is not
  /// cached yet; null when it is gone or the read failed.
  Future<GatewayClient?> resolve(String clientId) async {
    final cached = state[clientId];
    if (cached != null) return cached;
    final api = ref.read(apiProvider);
    if (api == null) return null;
    try {
      final clients = await ClientsApi(api).list();
      state = {for (final client in clients) client.clientId: client};
      return state[clientId];
    } on PircException {
      return null;
    }
  }

  /// Keeps a rename visible without another read.
  void remember(GatewayClient client) =>
      state = {...state, client.clientId: client};
}

/// The Web build's browser name, kept in app storage. Empty means the Gateway
/// names the browser from its user agent. Paired apps have no value here: the
/// Gateway names them by their device record.
final webClientNameProvider = NotifierProvider<WebClientName, String?>(
  WebClientName.new,
);

class WebClientName extends Notifier<String?> {
  @override
  String? build() {
    if (!ref.watch(isWebProvider)) return null;
    return _stored(
      ref.watch(sharedPreferencesProvider).getString(PrefKeys.clientName),
    );
  }

  static String? _stored(String? value) =>
      value == null || value.isEmpty ? null : value;

  /// Stores [name]; null or empty clears it.
  Future<void> set(String? name) async {
    final clean = _stored(name?.trim());
    final prefs = ref.read(sharedPreferencesProvider);
    if (clean == null) {
      await prefs.remove(PrefKeys.clientName);
    } else {
      await prefs.setString(PrefKeys.clientName, clean);
    }
    state = clean;
  }
}
