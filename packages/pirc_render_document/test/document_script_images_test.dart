// Resource lifecycle, containment and limits: safety regressions, so the
// default suite runs them (plans/client.md, Testing).
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_render_document/src/document_script_images.dart';

const _tinyPngBase64 =
    'iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAYAAABytg0kAAAAFElEQVR4nGP4z8DwHwyBNBAw/AcAR8oI+ItOQ4UAAAAASUVORK5CYII=';

void main() {
  testWidgets(
    'decoded PNG stays alive through delivery and command retention, then releases after a frame',
    (tester) async {
      final pool = NativeDocumentImagePool();
      final completion = await tester.runAsync(
        () => pool.decode(
          'image-1',
          _tinyPngBytes(),
          'image/png',
          originClean: true,
        ),
      );

      expect(completion, isNotNull);
      final result = completion!;
      expect(result['ok'], isTrue);
      expect(result['originClean'], isTrue);
      expect(result['width'], 2);
      expect(result['height'], 2);
      final id = result['imageId'] as String;
      final image = pool.images[id];
      expect(image, isNotNull);
      expect(image!.width, 2);
      expect(image.height, 2);
      expect(pool.allocatedPixels, 4);
      expect(() => pool.images.clear(), throwsUnsupportedError);

      // A freshly decoded handle is protected until its completion is acked.
      pool.retain(const []);
      expect(pool.images.containsKey(id), isTrue);
      expect(
        () => pool.retain(const ['unknown-canvas-image']),
        throwsA(isA<FormatException>()),
      );
      expect(pool.images.containsKey(id), isTrue);

      // The canvas keeps it alive after JS receives the completion.
      pool.retain([id]);
      pool.acknowledge(id);
      expect(pool.images.containsKey(id), isTrue);

      // Removing the final canvas reference drops the published map now and
      // defers ui.Image disposal until the next frame.
      pool.retain(const []);
      expect(pool.images.containsKey(id), isFalse);
      expect(pool.allocatedPixels, 4);
      await tester.pump();
      await tester.pump();
      expect(pool.allocatedPixels, 0);
      expect(pool.images, isEmpty);
      pool.dispose();
    },
  );

  testWidgets(
    'reserves image dimensions before decode and rejects over-budget dimensions first',
    (tester) async {
      late NativeDocumentImagePool pool;
      var pixelsAtCodecStart = 0;
      var oversizedCodecStarted = false;
      pool = NativeDocumentImagePool(
        decoder: (bytes, mimeType, reserve) async {
          if (bytes.first == 0) {
            await reserve(8192, 2049);
            oversizedCodecStarted = true;
            return await _decodePng(bytes);
          }
          await reserve(2, 2);
          pixelsAtCodecStart = pool.allocatedPixels;
          return await _decodePng(bytes);
        },
        release: (image) async => image.dispose(),
      );

      final completion = await tester.runAsync(
        () => pool.decode(
          'image-1',
          _tinyPngBytes(),
          'image/png',
          originClean: true,
        ),
      );
      expect(completion, isNotNull);
      expect(pixelsAtCodecStart, 4);
      expect(pool.allocatedPixels, 4);

      await tester.runAsync(() async {
        await expectLater(
          pool.decode(
            'image-2',
            Uint8List.fromList([0]),
            'image/png',
            originClean: true,
          ),
          throwsA(isA<FormatException>()),
        );
      });
      expect(oversizedCodecStarted, isFalse);
      expect(pool.allocatedPixels, 4);

      pool.dispose();
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      expect(pool.allocatedPixels, 0);
    },
  );

  testWidgets(
    'late decode after pool disposal releases without publishing a handle',
    (tester) async {
      await tester.runAsync(() async {
        final decodeGate = Completer<ui.Image>();
        final reserved = Completer<void>();
        final releaseFinished = Completer<void>();
        final releasedImages = <ui.Image>[];
        final pool = NativeDocumentImagePool(
          decoder: (bytes, mimeType, reserve) async {
            await reserve(2, 2);
            reserved.complete();
            return decodeGate.future;
          },
          release: (image) async {
            releasedImages.add(image);
            image.dispose();
            releaseFinished.complete();
          },
        );

        final image = await _decodePng(_tinyPngBytes());
        final pending = pool.decode(
          'image-1',
          _tinyPngBytes(),
          'image/png',
          originClean: true,
        );
        await reserved.future;
        expect(pool.allocatedPixels, 4);
        pool.dispose();
        decodeGate.complete(image);

        await expectLater(pending, throwsA(isA<StateError>()));
        await releaseFinished.future;
        await Future<void>.delayed(Duration.zero);
        expect(pool.images, isEmpty);
        expect(pool.allocatedPixels, 0);
        expect(releasedImages, [same(image)]);
      });
    },
  );

  testWidgets('SVG decoding reports the root element natural dimensions', (
    tester,
  ) async {
    final releasedImages = <ui.Image>[];
    final pool = NativeDocumentImagePool(
      release: (image) async {
        releasedImages.add(image);
        image.dispose();
      },
    );
    final svgBytes = Uint8List.fromList(
      utf8.encode(
        '<svg xmlns="http://www.w3.org/2000/svg" width="7" height="3" viewBox="0 0 7 3">'
        '<rect width="7" height="3" fill="#d946ef"/></svg>',
      ),
    );

    final completion = await tester.runAsync(
      () =>
          pool.decode('image-1', svgBytes, 'image/svg+xml', originClean: false),
    );
    expect(completion, isNotNull);
    expect(completion!['originClean'], isFalse);
    expect(completion['width'], 7);
    expect(completion['height'], 3);
    final id = completion['imageId'] as String;
    expect(pool.images[id]!.width, 7);
    expect(pool.images[id]!.height, 3);

    pool.dispose();
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    expect(releasedImages, hasLength(1));
    expect(pool.allocatedPixels, 0);
  });
}

Uint8List _tinyPngBytes() => Uint8List.fromList(base64Decode(_tinyPngBase64));

Future<ui.Image> _decodePng(Uint8List bytes) async {
  final codec = await ui.instantiateImageCodec(bytes);
  try {
    return (await codec.getNextFrame()).image;
  } finally {
    codec.dispose();
  }
}
