import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_app/src/platform/links.dart';
import 'package:pirc_app/src/platform/scanner.dart';

const _link = 'pirc://pair?url=https%3A%2F%2Fgateway.test&token=t';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  void answer(MethodChannel channel, Future<Object?> Function(MethodCall) on) {
    messenger.setMockMethodCallHandler(channel, on);
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
  }

  group('scanner channel', () {
    test('a scan answers the text, or null when closed', () async {
      final answers = <Object?>[_link, null];
      final calls = <String>[];
      answer(ChannelScanner.channel, (call) async {
        calls.add(call.method);
        return answers.removeAt(0);
      });
      const scanner = ChannelScanner();
      expect(await scanner.scan(), _link);
      expect(await scanner.scan(), isNull);
      expect(calls, ['scan', 'scan']);
    });

    test('a failure keeps only its code', () async {
      answer(
        ChannelScanner.channel,
        (call) async => throw PlatformException(
          code: 'SCAN_UNSUPPORTED',
          message: 'The scanner could not be opened',
        ),
      );
      await expectLater(
        const ChannelScanner().scan(),
        throwsA(
          isA<ScanFailure>().having((f) => f.code, 'code', 'SCAN_UNSUPPORTED'),
        ),
      );
    });
  });

  group('links channel', () {
    test('reads the link that opened the app', () async {
      answer(
        ChannelAppLinks.channel,
        (call) async => call.method == 'initialLink' ? _link : null,
      );
      expect(await ChannelAppLinks().initialLink(), _link);
    });

    test('links while running arrive on the stream', () async {
      final links = ChannelAppLinks();
      final received = <String>[];
      final subscription = links.links.listen(received.add);
      addTearDown(subscription.cancel);
      await messenger.handlePlatformMessage(
        ChannelAppLinks.channel.name,
        const StandardMethodCodec().encodeMethodCall(
          const MethodCall('link', _link),
        ),
        (_) {},
      );
      // Anything that is not a link is ignored.
      await messenger.handlePlatformMessage(
        ChannelAppLinks.channel.name,
        const StandardMethodCodec().encodeMethodCall(
          const MethodCall('other', 3),
        ),
        (_) {},
      );
      await Future<void>.delayed(Duration.zero);
      expect(received, [_link]);
    });

    test('opens an address in the browser', () async {
      final calls = <MethodCall>[];
      answer(ChannelAppLinks.channel, (call) async {
        calls.add(call);
        return null;
      });
      await ChannelAppLinks().openBrowser(
        Uri.parse('https://gateway.test/?pair=p1'),
      );
      expect(calls.single.method, 'openBrowser');
      expect(calls.single.arguments, {'url': 'https://gateway.test/?pair=p1'});
    });
  });
}
