import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_app/src/platform/media.dart';

Map<String, Object?> _status(
  int id, {
  bool playing = false,
  int position = 0,
}) => {
  'id': id,
  'width': 640,
  'height': 360,
  'duration': 10000,
  'position': position,
  'playing': playing,
  'rate': 1.0,
  'volume': 1.0,
  'muted': false,
  'loop': false,
  'mimeType': 'video/webm',
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(
    () => messenger.setMockMethodCallHandler(ChannelMediaPlayers.channel, null),
  );

  test('the wrapper opens bytes, controls, saves and closes', () async {
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(ChannelMediaPlayers.channel, (
      call,
    ) async {
      calls.add(call);
      final args = call.arguments as Map;
      return switch (call.method) {
        'open' => _status(7),
        'control' => _status(
          7,
          playing: args['action'] == 'play',
          position: args['position'] as int? ?? 0,
        ),
        'save' => 'clip (1).webm',
        _ => null,
      };
    });
    const media = ChannelMediaPlayers();
    final bytes = Uint8List.fromList([0x1a, 0x45, 0xdf, 0xa3]);

    expect(ChannelMediaPlayers.channel.name, 'org.mozufu.pirc/media');
    final opened = await media.open(
      bytes,
      mimeType: 'video/webm',
      kind: 'video',
      muted: true,
    );
    expect(opened.id, 7);
    expect((opened.width, opened.height), (640, 360));
    expect(opened.duration, const Duration(seconds: 10));
    expect(calls.single.arguments, {
      'bytes': bytes,
      'mimeType': 'video/webm',
      'kind': 'video',
      'muted': true,
      'loop': false,
    });

    expect((await media.play(7)).playing, isTrue);
    expect(
      (await media.seek(7, const Duration(seconds: 4))).position,
      const Duration(seconds: 4),
    );
    await media.setVolume(7, 0);
    await media.setRate(7, 1.5);
    await media.setLoop(7, true);
    await media.pause(7);
    await media.status(7);
    expect(await media.save(7, 'clip.webm'), 'clip (1).webm');
    await media.close(7);

    expect(calls.skip(1).map((call) => call.arguments), [
      {'id': 7, 'action': 'play'},
      {'id': 7, 'action': 'seek', 'position': 4000},
      {'id': 7, 'action': 'volume', 'volume': 0.0},
      {'id': 7, 'action': 'rate', 'rate': 1.5},
      {'id': 7, 'action': 'loop', 'loop': true},
      {'id': 7, 'action': 'pause'},
      {'id': 7, 'action': 'status'},
      {'id': 7, 'name': 'clip.webm'},
      {'id': 7},
    ]);
    expect(calls.map((call) => call.method).toSet(), {
      'open',
      'control',
      'save',
      'close',
    });
  });

  test('a recording goes to Android in parts, then opens', () async {
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(ChannelMediaPlayers.channel, (
      call,
    ) async {
      calls.add(call);
      return switch (call.method) {
        'upload' => 3,
        'open' => _status(7),
        _ => null,
      };
    });
    final bytes = Uint8List(MediaPlayers.partBytes * 2 + 5);
    final status = await const ChannelMediaPlayers().openRecording(bytes);
    expect(status.id, 7);
    expect(calls.map((call) => call.method), [
      'upload',
      'upload',
      'upload',
      'open',
    ]);
    final parts = calls.take(3).map((call) => call.arguments as Map).toList();
    expect(parts.first.containsKey('upload'), isFalse);
    expect(parts.skip(1).map((part) => part['upload']), [3, 3]);
    expect(parts.map((part) => (part['bytes'] as Uint8List).length), [
      MediaPlayers.partBytes,
      MediaPlayers.partBytes,
      5,
    ]);
    expect(calls.last.arguments, {
      'upload': 3,
      'mimeType': 'video/webm',
      'kind': 'video',
    });

    await const ChannelMediaPlayers().closeAll();
    expect(calls.last.method, 'closeAll');
  });

  test('a failed part drops the upload', () async {
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(ChannelMediaPlayers.channel, (
      call,
    ) async {
      calls.add(call);
      if (call.method == 'upload' &&
          (call.arguments as Map)['upload'] != null) {
        throw PlatformException(code: MediaError.media);
      }
      return call.method == 'upload' ? 4 : null;
    });
    await expectLater(
      const ChannelMediaPlayers().openRecording(
        Uint8List(MediaPlayers.partBytes + 1),
      ),
      throwsA(isA<PlatformException>()),
    );
    expect(calls.last.method, 'discard');
    expect(calls.last.arguments, {'upload': 4});
  });

  test('a cancelled recording stops between parts and is dropped', () async {
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(ChannelMediaPlayers.channel, (
      call,
    ) async {
      calls.add(call);
      return call.method == 'upload' ? 5 : null;
    });
    var cancelled = false;
    final opening = const ChannelMediaPlayers().openRecording(
      Uint8List(MediaPlayers.partBytes * 3),
      cancelled: () {
        // The widget goes away after the first part.
        final now = cancelled;
        cancelled = true;
        return now;
      },
    );
    await expectLater(
      opening,
      throwsA(isA<PlatformException>().having((e) => e.code, 'code', 'CLOSED')),
    );
    expect(calls.map((call) => call.method), ['upload', 'discard']);
    expect(calls.last.arguments, {'upload': 5});
  });

  test('a failed discard keeps the original error', () async {
    messenger.setMockMethodCallHandler(ChannelMediaPlayers.channel, (
      call,
    ) async {
      final args = call.arguments as Map?;
      if (call.method == 'upload' && args?['upload'] == null) return 6;
      if (call.method == 'upload') {
        throw PlatformException(code: MediaError.invalid);
      }
      throw PlatformException(code: MediaError.media);
    });
    await expectLater(
      const ChannelMediaPlayers().openRecording(
        Uint8List(MediaPlayers.partBytes + 1),
      ),
      throwsA(
        isA<PlatformException>().having((e) => e.code, 'code', 'INVALID'),
      ),
    );
  });

  test('the fake checks what the channel checks', () async {
    final media = FakeMediaPlayers();
    Matcher code(String code) =>
        throwsA(isA<PlatformException>().having((e) => e.code, 'code', code));
    expect(
      () => media.open(
        Uint8List(MediaPlayers.maxBytes + 1),
        mimeType: 'video/webm',
        kind: 'video',
      ),
      code(MediaError.invalid),
    );
    for (final mime in ['video/*', 'text/html', 'image/png', '']) {
      expect(
        () => media.open(Uint8List(1), mimeType: mime, kind: 'video'),
        code(MediaError.invalid),
      );
    }
    // A recording may be larger than HTML media.
    final recording = await media.openRecording(
      Uint8List(MediaPlayers.maxBytes + 1),
    );
    media.notReady.add(recording.id);
    expect(() => media.play(recording.id), code(MediaError.notReady));
    media.notReady.clear();
    media.background = true;
    expect(() => media.play(recording.id), code(MediaError.background));
    expect(() => media.setRate(recording.id, 0), code(MediaError.invalid));
    await media.closeAll();
    expect(media.closedAll, 1);
    expect(() => media.status(recording.id), code(MediaError.closed));
  });

  test('channel errors keep their code', () async {
    messenger.setMockMethodCallHandler(
      ChannelMediaPlayers.channel,
      (call) async => throw PlatformException(code: MediaError.background),
    );
    await expectLater(
      const ChannelMediaPlayers().play(1),
      throwsA(
        isA<PlatformException>().having(
          (e) => e.code,
          'code',
          MediaError.background,
        ),
      ),
    );
  });

  test('the fake plays, seeks within the media and closes', () async {
    final media = FakeMediaPlayers();
    final audio = await media.open(
      Uint8List.fromList([1, 2]),
      mimeType: 'audio/webm; codecs=opus',
      kind: 'audio',
    );
    expect(audio.mimeType, 'audio/webm');
    expect((await media.play(audio.id)).playing, isTrue);
    expect(
      (await media.seek(audio.id, const Duration(minutes: 5))).position,
      const Duration(seconds: 10),
    );
    expect((await media.setVolume(audio.id, 0)).muted, isTrue);
    expect(await media.save(audio.id, 'a.webm'), 'a.webm');
    expect(media.saved['a.webm'], [1, 2]);
    await media.close(audio.id);
    expect(
      () => media.status(audio.id),
      throwsA(isA<PlatformException>().having((e) => e.code, 'code', 'CLOSED')),
    );
    expect(
      () => media.open(Uint8List(0), mimeType: 'video/webm', kind: 'video'),
      throwsA(isA<PlatformException>()),
    );
  });
}
