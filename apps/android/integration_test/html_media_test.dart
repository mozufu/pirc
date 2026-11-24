import 'package:pirc_render/src/remote_content_gate.dart';
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:html/parser.dart' as html;
import 'package:integration_test/integration_test.dart';
import 'package:pirc_mobile/live/gateway.dart';
import 'package:pirc_mobile/live/html_media.dart';
import 'package:pirc_mobile/live/scoped_gateway.dart';
import 'package:pirc_render/src/html_media_spec.dart';

class MediaAcceptanceGateway extends Gateway {
  final opened = <Json>[];

  @override
  Future<dynamic> call(String method, [Json args = const {}]) async {
    final result = await super.call(method, args);
    if (method == 'htmlMediaOpen') opened.add(obj(result));
    return result;
  }
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  // These suites exercise the image/media loaders themselves, not the hold-back.
  setUpAll(() => NativeRemoteContentPolicy.debugOpenForTests = true);
  tearDownAll(() => NativeRemoteContentPolicy.debugOpenForTests = false);

  testWidgets(
    'real Android HTML media decodes video/audio, acknowledges paused seek, caches read, and enforces context ownership',
    (t) async {
      expect(const bool.fromEnvironment('PIRC_HTML_MEDIA'), isTrue);
      final origin = const String.fromEnvironment('PIRC_HTML_MEDIA_ORIGIN');
      final pairLink = const String.fromEnvironment('PIRC_PAIR_LINK');
      expect(origin, isNotEmpty);
      expect(pairLink, isNotEmpty);

      final gateway = MediaAcceptanceGateway();
      final videoUri = '$origin/parity-html-media/red-blue.mp4';
      final audioUri = '$origin/parity-html-media/tone.wav';
      final video = NativeHtmlMediaSpec.fromElement(
        html
            .parseFragment(
              '<video controls preload="auto" muted src="$videoUri"></video>',
            )
            .children
            .single,
      );
      DartScopedGateway? audioOwner;
      DartScopedGateway? intruder;
      int? videoId;
      int? audioId;

      Future<void> until(bool Function() ready, String step) async {
        for (var i = 0; i < 240 && !ready(); i++) {
          await t.pump(const Duration(milliseconds: 100));
        }
        expect(ready(), isTrue, reason: step);
        expect(t.takeException(), isNull, reason: step);
        debugPrint('HTML_MEDIA_STEP:$step');
      }

      Future<List<int>> screenshotBytes(String name) async {
        await t.pump();
        return binding.takeScreenshot(name);
      }

      Future<bool> sampleDominantColor({required bool red}) async {
        final png = await screenshotBytes(
          red ? 'html-media-red' : 'html-media-blue',
        );
        final codec = await ui.instantiateImageCodec(Uint8List.fromList(png));
        final image = (await codec.getNextFrame()).image;
        final pixels = (await image.toByteData(
          format: ui.ImageByteFormat.rawRgba,
        ))!.buffer.asUint8List();
        final rect = t.getRect(find.byType(Texture));
        final view = WidgetsBinding.instance.platformDispatcher.views.first;
        final logicalWidth = view.physicalSize.width / view.devicePixelRatio;
        final logicalHeight = view.physicalSize.height / view.devicePixelRatio;
        final x = (rect.center.dx * image.width / logicalWidth)
            .round()
            .clamp(0, image.width - 1)
            .toInt();
        // Sample above the overlaid controls, away from the widget edges.
        final y =
            ((rect.top + rect.height * .35) * image.height / logicalHeight)
                .round()
                .clamp(0, image.height - 1)
                .toInt();
        final offset = (y * image.width + x) * 4;
        final r = pixels[offset],
            g = pixels[offset + 1],
            b = pixels[offset + 2];
        image.dispose();
        codec.dispose();
        return red
            ? r > 170 && r > g * 1.5 && r > b * 1.5 && g < 90 && b < 90
            : b > 150 && b > r * 1.5 && b > g * 1.3 && r < 90;
      }

      Future<void> waitForColor({
        required bool red,
        required String step,
      }) async {
        for (var i = 0; i < 40; i++) {
          if (await sampleDominantColor(red: red)) {
            debugPrint('HTML_MEDIA_STEP:$step');
            return;
          }
          await t.pump(const Duration(milliseconds: 80));
        }
        fail('Decoded texture never displayed ${red ? 'red' : 'blue'}: $step');
      }

      Future<Json> mediaReceipt(String pairingStamp) async {
        final response = obj(
          await gateway.call('document', {
            'url': '$origin/parity-html-media/receipt',
            'method': 'GET',
            'pairingStamp': pairingStamp,
          }),
        );
        return obj(jsonDecode(utf8.decode(response['bytes'] as Uint8List)));
      }

      try {
        await gateway.call('pair', {'link': pairLink});
        await gateway.call('completeOnboarding');
        final boot = obj(await gateway.call('boot'));
        final pairingStamp = boot['pairingStamp'] as String;

        await t.pumpWidget(
          MaterialApp(
            theme: ThemeData.light(),
            home: Scaffold(
              body: Center(
                child: NativeHtmlMedia(
                  gateway: gateway,
                  spec: video,
                  baseUrl: '$origin/',
                ),
              ),
            ),
          ),
        );
        await until(
          () =>
              find.byType(Texture).evaluate().isNotEmpty &&
              gateway.opened.isNotEmpty,
          'video-prepared-texture',
        );
        videoId = t.widget<Texture>(find.byType(Texture)).textureId;
        final videoOpen = gateway.opened.single;
        expect(videoOpen['id'], videoId);
        expect(videoOpen['width'], 160);
        expect(videoOpen['height'], 90);
        expect(videoOpen['mimeType'], 'video/mp4');
        expect((videoOpen['duration'] as num) >= 7800, isTrue);

        final videoUnmuted = obj(
          await gateway.call('htmlMediaControl', {
            'id': videoId,
            'action': 'volume',
            'volume': 1,
          }),
        );
        expect(videoUnmuted['muted'], isFalse);
        expect(videoUnmuted['volume'], 1);
        final videoRemuted = obj(
          await gateway.call('htmlMediaControl', {
            'id': videoId,
            'action': 'volume',
            'volume': 0,
          }),
        );
        expect(videoRemuted['muted'], isTrue);
        expect(videoRemuted['volume'], 0);
        final changedRate = obj(
          await gateway.call('htmlMediaControl', {
            'id': videoId,
            'action': 'rate',
            'rate': 1.5,
          }),
        );
        expect(changedRate['rate'], 1.5);
        expect(changedRate['playing'], isFalse);

        await binding.convertFlutterSurfaceToImage();
        await t.pump();
        await waitForColor(
          red: true,
          step: 'video-texture-displayed-red-frame',
        );

        final videoBytes = obj(
          await gateway.call('htmlMediaRead', {'id': videoId}),
        );
        expect(videoBytes['mimeType'], 'video/mp4');
        expect(videoBytes['finalUrl'], videoUri);
        expect(obj(videoBytes['headersRelevant'])['Content-Type'], 'video/mp4');
        expect((videoBytes['bytes'] as Uint8List).length, greaterThan(0));

        final pausedSeek = obj(
          await gateway.call('htmlMediaControl', {
            'id': videoId,
            'action': 'seek',
            'position': 5500,
          }),
        );
        expect(pausedSeek['playing'], isFalse);
        expect((pausedSeek['position'] as num) >= 5000, isTrue);
        expect((pausedSeek['position'] as num) <= 7800, isTrue);
        await waitForColor(
          red: false,
          step: 'paused-seek-displayed-blue-frame',
        );

        await t.tap(find.byTooltip('Play media'));
        await until(
          () => find.byTooltip('Pause media').evaluate().isNotEmpty,
          'flutter-play-control',
        );
        final playing = obj(
          await gateway.call('htmlMediaControl', {
            'id': videoId,
            'action': 'status',
          }),
        );
        expect(playing['playing'], isTrue);
        await t.tap(find.byTooltip('Pause media'));
        await until(
          () => find.byTooltip('Play media').evaluate().isNotEmpty,
          'flutter-pause-control',
        );
        final paused = obj(
          await gateway.call('htmlMediaControl', {
            'id': videoId,
            'action': 'status',
          }),
        );
        expect(paused['playing'], isFalse);

        audioOwner = DartScopedGateway(gateway, contextId: 'html-media-owner');
        await audioOwner.ensureContext();
        final audioOpen = obj(
          await audioOwner.call('htmlMediaOpen', {
            'source': audioUri,
            'pairingStamp': pairingStamp,
            'kind': 'audio',
            'muted': false,
            'loop': false,
          }),
        );
        audioId = audioOpen['id'] as int;
        expect(audioOpen['mimeType'], 'audio/wav');
        expect(audioOpen['width'], 0);
        expect(audioOpen['height'], 0);
        expect((audioOpen['duration'] as num) >= 7800, isTrue);

        final audioPlaying = obj(
          await audioOwner.call('htmlMediaControl', {
            'id': audioId,
            'action': 'play',
          }),
        );
        expect(audioPlaying['playing'], isTrue);
        final muted = obj(
          await audioOwner.call('htmlMediaControl', {
            'id': audioId,
            'action': 'volume',
            'volume': 0,
          }),
        );
        expect(muted['muted'], isTrue);
        expect(muted['volume'], 0);
        final unmuted = obj(
          await audioOwner.call('htmlMediaControl', {
            'id': audioId,
            'action': 'volume',
            'volume': 1,
          }),
        );
        expect(unmuted['muted'], isFalse);
        expect(unmuted['volume'], 1);
        await audioOwner.call('htmlMediaControl', {
          'id': audioId,
          'action': 'pause',
        });
        final audioSeek = obj(
          await audioOwner.call('htmlMediaControl', {
            'id': audioId,
            'action': 'seek',
            'position': 600,
          }),
        );
        expect(audioSeek['playing'], isFalse);
        expect((audioSeek['position'] as num) >= 400, isTrue);
        expect((audioSeek['position'] as num) <= 900, isTrue);
        final audioBytes = obj(
          await audioOwner.call('htmlMediaRead', {'id': audioId}),
        );
        expect(audioBytes['mimeType'], 'audio/wav');
        expect(audioBytes['finalUrl'], audioUri);
        expect((audioBytes['bytes'] as Uint8List).length, greaterThan(0));

        intruder = DartScopedGateway(gateway, contextId: 'html-media-intruder');
        await intruder.ensureContext();
        await expectLater(
          intruder.call('htmlMediaControl', {
            'id': videoId,
            'action': 'status',
          }),
          throwsA(isA<PlatformException>()),
        );

        final receipt = await mediaReceipt(pairingStamp);
        final counts = obj(receipt['counts']);
        expect(counts['/parity-html-media/red-blue.mp4'], 1);
        expect(counts['/parity-html-media/tone.wav'], 1);
        final requests = rows(receipt['requests']);
        expect(
          requests.every(
            (request) => request['accept'] == 'audio/*,video/*,*/*;q=0.1',
          ),
          isTrue,
        );
        debugPrint('HTML_MEDIA_STEP:cached-read-no-second-fetch');

        await audioOwner.closeContext();
        audioOwner = null;
        await expectLater(
          gateway.call('htmlMediaControl', {'id': audioId, 'action': 'status'}),
          throwsA(isA<PlatformException>()),
        );
        await t.pumpWidget(const SizedBox());
        await t.pump(const Duration(milliseconds: 200));
        await expectLater(
          gateway.call('htmlMediaControl', {'id': videoId, 'action': 'status'}),
          throwsA(isA<PlatformException>()),
        );
        debugPrint('HTML_MEDIA_STEP:context-owner-and-close-enforced');
        expect(t.takeException(), isNull);
      } finally {
        await t.pumpWidget(const SizedBox());
        await t.pump(const Duration(milliseconds: 100));
        if (audioOwner != null) await audioOwner.closeContext();
        if (intruder != null) await intruder.closeContext();
        await gateway.call('unpair');
      }
    },
    timeout: const Timeout(Duration(minutes: 4)),
  );
}
