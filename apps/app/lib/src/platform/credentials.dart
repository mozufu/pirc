import 'package:flutter/services.dart';

/// The device token in the Android Keystore, through the
/// `org.mozufu.pirc/credentials` channel (plans/roadmap.md M8 step 1). The
/// Kotlin side encrypts it with AES-GCM under the key `pirc-device-token`;
/// the background client reads it from there without the Flutter engine.
abstract interface class Credentials {
  Future<String?> readToken();
  Future<void> saveToken(String token);
  Future<void> deleteToken();
}

class ChannelCredentials implements Credentials {
  const ChannelCredentials();

  static const channel = MethodChannel('org.mozufu.pirc/credentials');

  @override
  Future<String?> readToken() => channel.invokeMethod<String>('read');

  @override
  Future<void> saveToken(String token) =>
      channel.invokeMethod<void>('save', {'token': token});

  @override
  Future<void> deleteToken() => channel.invokeMethod<void>('delete');
}

/// For tests: the token in memory.
class FakeCredentials implements Credentials {
  FakeCredentials([this.token]);

  String? token;

  @override
  Future<String?> readToken() async => token;

  @override
  Future<void> saveToken(String token) async => this.token = token;

  @override
  Future<void> deleteToken() async => token = null;
}
