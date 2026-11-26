import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:pirc_client/pirc_client.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../platform/credentials.dart';

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

  /// A fixed UTC offset (`+05:30`) for the calendar; absent means the
  /// device's own time zone.
  static const timeZone = 'timeZone';
  static const gatewayUrl = 'gatewayUrl';
  static const clientId = 'clientId';

  /// The Web build's chosen client name; empty means the Gateway names it.
  static const clientName = 'clientName';

  /// When a token rotation whose reply was lost was sent (milliseconds);
  /// absent when no rotation outcome is unknown. Holds no secret.
  static const rotationUnknownSince = 'rotationUnknownSince';

  /// Per-session drafts and the first-send journal use these prefixes.
  static const draftPrefix = 'draft.';
  static const firstSendJournal = 'firstSendJournal';
}

/// Secrets: the device token. Android keeps it in the Keystore through the
/// credentials channel, macOS in the Keychain through
/// `flutter_secure_storage` (default A); the Web build has no token.
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

/// Android: the device token through the `org.mozufu.pirc/credentials`
/// channel, which holds only that one secret.
class CredentialsSecretStore implements SecretStore {
  const CredentialsSecretStore([
    this._credentials = const ChannelCredentials(),
  ]);

  final Credentials _credentials;

  static void _check(String key) {
    if (key != deviceTokenKey) {
      throw ArgumentError.value(key, 'key', 'only the device token is kept');
    }
  }

  @override
  Future<String?> read(String key) {
    _check(key);
    return _credentials.readToken();
  }

  @override
  Future<void> write(String key, String value) {
    _check(key);
    return _credentials.saveToken(value);
  }

  @override
  Future<void> delete(String key) {
    _check(key);
    return _credentials.deleteToken();
  }
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
  (ref) => !kIsWeb && defaultTargetPlatform == TargetPlatform.android
      ? const CredentialsSecretStore()
      : const SecureSecretStore(),
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

  /// Uses [token] from now on; it is already saved (token rotation).
  void replace(String token) {
    _cached = token;
    _loaded = true;
  }
}
