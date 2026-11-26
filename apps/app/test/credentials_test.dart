import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_app/src/connection/connection.dart';
import 'package:pirc_app/src/connection/storage.dart';
import 'package:pirc_app/src/platform/credentials.dart';

import 'support/harness.dart';

/// Answers the credentials channel from [token] and records each call.
List<MethodCall> _mockChannel({String? token}) {
  final calls = <MethodCall>[];
  var stored = token;
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(ChannelCredentials.channel, (call) async {
    calls.add(call);
    switch (call.method) {
      case 'read':
        return stored;
      case 'save':
        stored = (call.arguments as Map)['token'] as String;
      case 'delete':
        stored = null;
    }
    return null;
  });
  addTearDown(
    () => messenger.setMockMethodCallHandler(ChannelCredentials.channel, null),
  );
  return calls;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('the wrapper reads, saves and deletes through the channel', () async {
    final calls = _mockChannel(token: 'device-token');
    const credentials = ChannelCredentials();

    expect(ChannelCredentials.channel.name, 'org.mozufu.pirc/credentials');
    expect(await credentials.readToken(), 'device-token');
    await credentials.saveToken('new-token');
    expect(await credentials.readToken(), 'new-token');
    await credentials.deleteToken();
    expect(await credentials.readToken(), isNull);
    expect(calls.map((call) => call.method), [
      'read',
      'save',
      'read',
      'delete',
      'read',
    ]);
    expect(calls[1].arguments, {'token': 'new-token'});
  });

  test('the channel keeps only the device token', () async {
    final store = CredentialsSecretStore(FakeCredentials('device-token'));
    expect(await store.read(deviceTokenKey), 'device-token');
    expect(() => store.read('other'), throwsArgumentError);
    expect(() => store.write('other', 'x'), throwsArgumentError);
  });

  appTest('on Android the app reads its token through the channel', (
    tester,
  ) async {
    final calls = _mockChannel(token: 'device-token');
    final gateway = FakeGateway();

    final container = await pumpApp(
      tester,
      gateway: gateway,
      platformSecrets: true,
    );

    expect(container.read(secretStoreProvider), isA<CredentialsSecretStore>());
    expect(calls.map((call) => call.method), contains('read'));
    expect(await gateway.tokens.last!.read(), 'device-token');
    expect(container.read(connectionProvider).phase, ConnectionPhase.online);
  });

  appTest('on Android pairing saves the token through the channel', (
    tester,
  ) async {
    final calls = _mockChannel();

    await pumpApp(
      tester,
      gateway: FakeGateway(),
      saved: Saved.unpaired(),
      platformSecrets: true,
    );
    await tester.enterText(
      find.byKey(const Key('pairing-link')),
      'pirc://pair?url=https%3A%2F%2Fgateway.test&token=new-token',
    );
    await tester.tap(find.text('Pair'));
    await tester.pumpAndSettle();

    final save = calls.singleWhere((call) => call.method == 'save');
    expect(save.arguments, {'token': 'new-token'});
  });

  testWidgets(
    'macOS keeps flutter_secure_storage',
    (tester) async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      expect(container.read(secretStoreProvider), isA<SecureSecretStore>());
    },
    variant: TargetPlatformVariant.only(TargetPlatform.macOS),
  );

  test('Android uses the credentials channel', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final container = ProviderContainer();
    addTearDown(container.dispose);
    expect(container.read(secretStoreProvider), isA<CredentialsSecretStore>());
  });
}
