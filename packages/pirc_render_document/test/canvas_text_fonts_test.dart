import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_render_document/pirc_render_document.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const fonts = ChannelCanvasTextFonts();
  tearDown(
    () => messenger.setMockMethodCallHandler(
      ChannelCanvasTextFonts.channel,
      null,
    ),
  );

  test('collects the fonts through the channel', () async {
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(ChannelCanvasTextFonts.channel, (
      call,
    ) async {
      calls.add(call);
      if (call.method == 'fontCapabilities') return {'canvasText': true};
      return {
        'resources': [
          {
            'id': 'font-1',
            'bytes': Uint8List.fromList([0, 1, 0, 0]),
            'ttcIndex': 0,
            'originalTtcIndex': 2,
            'weight': 400,
            'italic': false,
            'fakeBold': false,
            'fakeItalic': false,
            'axes': [
              {'axis': 'wght', 'value': 400.0},
            ],
            'label': 'NotoSansCJK-Regular.ttc',
          },
        ],
        'matches': [
          {
            'family': 'sans-serif',
            'weight': 700,
            'italic': false,
            'resourceIds': ['font-1'],
          },
        ],
      };
    });

    expect(ChannelCanvasTextFonts.channel.name, 'org.mozufu.pirc/fonts');
    expect(await fonts.supported(), isTrue);
    final set = await fonts.collect(['sans-serif'], '中文');
    expect(calls.last.method, 'canvasTextFonts');
    expect(calls.last.arguments, {
      'families': ['sans-serif'],
      'sample': '中文',
    });
    final resource = set.resources.single;
    expect(resource.id, 'font-1');
    expect(resource.bytes, [0, 1, 0, 0]);
    expect(resource.originalTtcIndex, 2);
    expect(resource.axes, {'wght': 400.0});
    expect(resource.label, 'NotoSansCJK-Regular.ttc');
    final match = set.matches.single;
    expect(
      (match.family, match.weight, match.italic),
      ('sans-serif', 700, false),
    );
    expect(match.resourceIds, ['font-1']);
  });

  test('without the channel there are no canvas fonts', () async {
    expect(await fonts.supported(), isFalse);
  });

  test('a refusal reaches the caller', () async {
    messenger.setMockMethodCallHandler(
      ChannelCanvasTextFonts.channel,
      (call) async => throw PlatformException(code: 'UNSUPPORTED'),
    );
    await expectLater(
      fonts.collect(['serif'], ''),
      throwsA(
        isA<PlatformException>().having((e) => e.code, 'code', 'UNSUPPORTED'),
      ),
    );
  });

  test('the fake records requests and can refuse', () async {
    final fake = FakeCanvasTextFonts();
    await fake.collect(['serif'], 'abc');
    expect(fake.requests.single.$1, ['serif']);
    expect(fake.requests.single.$2, 'abc');
    fake.isSupported = false;
    expect(await fake.supported(), isFalse);
    expect(
      () => fake.collect(['serif'], ''),
      throwsA(isA<PlatformException>()),
    );
  });
}
