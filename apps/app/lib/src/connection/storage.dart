import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:pirc_client/pirc_client.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Failed providers are not retried on a timer: lists read again on hints
/// and offer "Try again".
Duration? noRetry(int retryCount, Object error) => null;

/// App settings that are not secret (language, appearance, text size, start
/// tab, Gateway URL). `main` overrides this with the loaded instance.
final sharedPreferencesProvider = Provider<SharedPreferences>(
  (ref) => throw UnimplementedError('sharedPreferencesProvider not loaded'),
);

/// Keys in [SharedPreferences].
abstract final class PrefKeys {
  static const language = 'language';
  static const appearance = 'appearance';
  static const textScale = 'textScale';
  static const startTab = 'startTab';
  static const gatewayUrl = 'gatewayUrl';

  /// Per-session drafts and the first-send journal use these prefixes.
  static const draftPrefix = 'draft.';
  static const firstSendJournal = 'firstSendJournal';
}

/// Secrets: the device token. Android and macOS keep it in the platform's
/// secure store (default A); the Web build has no token.
abstract interface class SecretStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

class SecureSecretStore implements SecretStore {
  const SecureSecretStore([this._storage = const FlutterSecureStorage()]);

  final FlutterSecureStorage _storage;

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);

  @override
  Future<void> delete(String key) => _storage.delete(key: key);
}

/// For tests and the Web build.
class MemorySecretStore implements SecretStore {
  MemorySecretStore([Map<String, String>? values]) : values = values ?? {};

  final Map<String, String> values;

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async => values[key] = value;

  @override
  Future<void> delete(String key) async => values.remove(key);
}

final secretStoreProvider = Provider<SecretStore>(
  (ref) => const SecureSecretStore(),
);

const deviceTokenKey = 'deviceToken';

/// The transport's [TokenStore]: the saved device token, cached after the
/// first read so each request does not reach the secure store.
class SecretTokenStore implements TokenStore {
  SecretTokenStore(this._secrets);

  final SecretStore _secrets;
  String? _cached;
  bool _loaded = false;

  @override
  Future<String?> read() async {
    if (!_loaded) {
      _cached = await _secrets.read(deviceTokenKey);
      _loaded = true;
    }
    return _cached;
  }
}
