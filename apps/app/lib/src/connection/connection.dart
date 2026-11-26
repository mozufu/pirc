import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pirc_client/pirc_client.dart';

import '../platform/media.dart';
import 'storage.dart';

/// Builds the transport; tests replace it with a fake.
typedef TransportFactory =
    Transport Function(TransportConfig config, TokenStore? tokens);

final transportFactoryProvider = Provider<TransportFactory>(
  (ref) =>
      (config, tokens) => createTransport(config, tokens: tokens),
);

/// Whether this is the Web build: no pairing, the page origin is the Gateway
/// and the browser carries the sign-in.
final isWebProvider = Provider<bool>((ref) => kIsWeb);

/// The Gateway origin of the Web build.
final webOriginProvider = Provider<Uri>(
  (ref) => Uri.base.replace(path: '/', query: '', fragment: ''),
);

/// The management grant, in memory only (step 15 fills it).
final managementGrantProvider = NotifierProvider<ManagementGrant, String?>(
  ManagementGrant.new,
);

class ManagementGrant extends Notifier<String?> {
  @override
  String? build() => null;

  void set(String? grant) => state = grant;
}

/// One connection to a Gateway that answered `GET /api/capabilities`.
@immutable
class Connection {
  const Connection({
    required this.gateway,
    required this.transport,
    required this.api,
    required this.capabilities,
  });

  final Uri gateway;
  final Transport transport;
  final ApiClient api;
  final Capabilities capabilities;

  String? get account => capabilities.accountUser;
}

enum ConnectionPhase {
  /// Reading the saved Gateway and token.
  starting,

  /// No device token (native builds): the pairing page opens.
  unpaired,

  /// Asking the Gateway for its capabilities.
  connecting,
  online,

  /// The Gateway could not be reached; retrying with backoff.
  offline,

  /// The Gateway refused this build (426).
  upgradeRequired,

  /// The browser's sign-in ended (Web build).
  signedOut,
}

@immutable
class ConnectionStatus {
  const ConnectionStatus(
    this.phase, {
    this.connection,
    this.error,
    this.pairingExpired = false,
  });

  final ConnectionPhase phase;

  /// [ConnectionPhase.unpaired] because the Gateway refused the token (it
  /// expired or was revoked), not because the user unpaired or never paired.
  /// The settings are kept.
  final bool pairingExpired;

  /// The last good connection; kept while offline so screens can show what
  /// they had, marked as possibly out of date.
  final Connection? connection;
  final Object? error;
}

final connectionProvider =
    NotifierProvider<ConnectionController, ConnectionStatus>(
      ConnectionController.new,
    );

/// Owns the transport and the connection phase. `PairingRequired` anywhere
/// (401, close code 4401) clears the token and opens the pairing page;
/// `ClientUpgradeRequired` shows the blocking update page.
class ConnectionController extends Notifier<ConnectionStatus> {
  Timer? _retry;
  Transport? _transport;
  SecretTokenStore? _tokens;

  /// The token this connection started with. A refusal after a rotation
  /// is for that old token and must not remove the new one.
  String? _startedWith;
  String? _account;
  int _attempts = 0;
  int _generation = 0;
  final _random = Random();

  @override
  ConnectionStatus build() {
    ref.onDispose(() {
      _retry?.cancel();
      _transport?.close();
    });
    scheduleMicrotask(start);
    return const ConnectionStatus(ConnectionPhase.starting);
  }

  /// Reads the saved Gateway and token, then connects.
  Future<void> start() async {
    final generation = ++_generation;
    _retry?.cancel();
    final web = ref.read(isWebProvider);
    final Uri gateway;
    SecretTokenStore? tokens;
    String? startedWith;
    if (web) {
      gateway = ref.read(webOriginProvider);
    } else {
      final url = ref
          .read(sharedPreferencesProvider)
          .getString(PrefKeys.gatewayUrl);
      final secrets = ref.read(secretStoreProvider);
      final token = await secrets.read(deviceTokenKey);
      if (generation != _generation) return;
      if (url == null || token == null || token.isEmpty) {
        state = const ConnectionStatus(ConnectionPhase.unpaired);
        return;
      }
      gateway = Uri.parse(url);
      tokens = SecretTokenStore(secrets)..replace(token);
      startedWith = token;
    }
    _transport?.close();
    final transport = ref.read(transportFactoryProvider)(
      TransportConfig(
        baseUri: gateway,
        account: () => _account,
        managementGrant: () => ref.read(managementGrantProvider),
      ),
      tokens,
    );
    _transport = transport;
    _tokens = tokens;
    _startedWith = startedWith;
    _account = null;
    state = const ConnectionStatus(ConnectionPhase.connecting);
    await _connect(generation, gateway, transport);
  }

  Future<void> _connect(
    int generation,
    Uri gateway,
    Transport transport,
  ) async {
    final api = ApiClient(
      transport,
      // A 401 or 426 from any later request (a list read, a panel) ends the
      // connection the same way as one at connect time. Deferred, so the
      // caller's own handling and this one never run inside each other; the
      // generation check makes the second one a no-op.
      onFatal: (error) => scheduleMicrotask(() {
        if (generation == _generation) _handleFatal(error);
      }),
    );
    try {
      final capabilities = await api.connect();
      if (generation != _generation) return;
      _attempts = 0;
      _account = capabilities.accountUser;
      state = ConnectionStatus(
        ConnectionPhase.online,
        connection: Connection(
          gateway: gateway,
          transport: transport,
          api: api,
          capabilities: capabilities,
        ),
      );
    } on PircException catch (error) {
      if (generation != _generation) return;
      if (!_handleFatal(error)) {
        _goOffline(error, () => _connect(generation, gateway, transport));
      }
    }
  }

  void _goOffline(Object error, Future<void> Function() again) {
    state = ConnectionStatus(
      ConnectionPhase.offline,
      connection: state.connection,
      error: error,
    );
    final delay = reconnectDelay(_attempts++, _random.nextDouble());
    _retry = Timer(delay, () => unawaited(again()));
  }

  /// Connectivity regained or the app came back: try at once.
  void retryNow() {
    if (state.phase != ConnectionPhase.offline) return;
    _attempts = 0;
    unawaited(start());
  }

  /// A screen hit [error]; fatal ones change the phase. Returns whether the
  /// error was handled here.
  bool report(Object error) {
    // A panel's socket upgrade is refused with the HTTP status, unlike the
    // session and hint streams, which map it themselves.
    final fatal = switch (error) {
      EventSocketRefused(status: 401) => const PairingRequired(
        'Event socket refused (401)',
      ),
      EventSocketRefused(status: 426) => const ClientUpgradeRequired(
        'Event socket refused (426)',
      ),
      PircException exception => exception,
      _ => null,
    };
    return fatal != null && _handleFatal(fatal);
  }

  bool _handleFatal(PircException error) {
    switch (error) {
      case PairingRequired():
        if (ref.read(isWebProvider)) {
          _set(ConnectionPhase.signedOut, error);
        } else {
          unawaited(_refused(_generation, _startedWith, error));
        }
        return true;
      case ClientUpgradeRequired():
        _set(ConnectionPhase.upgradeRequired, error);
        return true;
      default:
        return false;
    }
  }

  /// The Gateway refused the token. When the saved token is no longer the
  /// one this connection started with, the app rotated it meanwhile and the
  /// refusal was for the old one (its sockets close with 4401 once the new
  /// token is used): connect again with the new token. Otherwise the
  /// pairing ended; the settings are kept.
  Future<void> _refused(
    int generation,
    String? startedWith,
    PircException error,
  ) async {
    final saved = await ref.read(secretStoreProvider).read(deviceTokenKey);
    if (generation != _generation) return;
    if (saved != null && saved.isNotEmpty && saved != startedWith) {
      await start();
      return;
    }
    unawaited(_forgetToken());
    unawaited(_closeMedia());
    _set(ConnectionPhase.unpaired, error, pairingExpired: true);
  }

  void _set(
    ConnectionPhase phase,
    Object error, {
    bool pairingExpired = false,
  }) {
    _generation++;
    _retry?.cancel();
    ref.read(managementGrantProvider.notifier).set(null);
    _transport?.close();
    _transport = null;
    _tokens = null;
    _startedWith = null;
    _account = null;
    state = ConnectionStatus(
      phase,
      error: error,
      pairingExpired: pairingExpired,
    );
  }

  /// The device token the transport sends now; null without one.
  Future<String?> currentToken() async => _tokens?.read();

  /// Token rotation: saves [token] in the secret store and only then sends
  /// it, in place of [previous]. Returns false and keeps nothing when the
  /// pairing changed meanwhile (the user unpaired or paired again).
  Future<bool> replaceToken(String token, {required String previous}) async {
    final generation = _generation;
    final tokens = _tokens;
    if (tokens == null) return false;
    final secrets = ref.read(secretStoreProvider);
    if (await secrets.read(deviceTokenKey) != previous ||
        generation != _generation) {
      return false;
    }
    await secrets.write(deviceTokenKey, token);
    if (generation != _generation) {
      // Unpaired while the write ran: do not bring the pairing back.
      if (state.phase == ConnectionPhase.unpaired) await _forgetToken();
      return false;
    }
    tokens.replace(token);
    return true;
  }

  Future<void> _forgetToken() =>
      ref.read(secretStoreProvider).delete(deviceTokenKey);

  /// Stops the recordings of the pairing that ends and drops their cached
  /// copies.
  Future<void> _closeMedia() async {
    try {
      await ref.read(mediaPlayersProvider)?.closeAll();
    } on Exception {
      // The players are already gone with the engine.
    }
  }

  /// Saves a checked pairing and connects with it.
  Future<void> savePairing(Uri gateway, String token) async {
    await _closeMedia();
    await ref.read(secretStoreProvider).write(deviceTokenKey, token);
    await ref
        .read(sharedPreferencesProvider)
        .setString(PrefKeys.gatewayUrl, gateway.toString());
    await start();
  }

  /// "Unpair this device…": removes the token and the local data.
  Future<void> unpair() async {
    await _forgetToken();
    await _closeMedia();
    final prefs = ref.read(sharedPreferencesProvider);
    for (final key in prefs.getKeys().toList()) {
      if (key == PrefKeys.gatewayUrl ||
          key == PrefKeys.firstSendJournal ||
          key.startsWith(PrefKeys.draftPrefix)) {
        await prefs.remove(key);
      }
    }
    _set(ConnectionPhase.unpaired, const PairingRequired('Unpaired'));
  }
}

/// The connection as screens show it.
enum AppConnectionState {
  connecting,
  online,

  /// Online, but the hint socket is reconnecting.
  reconnecting,
  offline,
  unpaired,
  upgradeRequired,
  signedOut,
}
