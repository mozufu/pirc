// Resource lifecycle, containment and limits: safety regressions, so the
// default suite runs them (plans/client.md, Testing).
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_render_document/src/document_script_images.dart';

const source =
    '<svg xmlns="http://www.w3.org/2000/svg" width="2" height="2"><rect width="2" height="2" fill="red"/></svg>';

Future<ui.Image> tinyImage() async {
  final recorder = ui.PictureRecorder();
  ui.Canvas(recorder).drawRect(const ui.Rect.fromLTWH(0, 0, 2, 2), ui.Paint());
  final picture = recorder.endRecording();
  try {
    return await picture.toImage(2, 2);
  } finally {
    picture.dispose();
  }
}

void main() {
  testWidgets(
    'SVG source and bitmap own the same immutable version until frame retirement',
    (t) async {
      final pool = NativeDocumentImagePool();
      final bytes = Uint8List.fromList(utf8.encode(source));
      final result = (await t.runAsync(() async {
        final pending = pool.decode(
          'image-1',
          bytes,
          'image/svg+xml; charset=utf-8',
          originClean: true,
        );
        bytes.fillRange(0, bytes.length, 0);
        return pending;
      }))!;
      final id = result['imageId'] as String;
      expect(utf8.decode(pool.vectorSources[id]!), source);
      expect(() => pool.vectorSources.clear(), throwsUnsupportedError);
      expect(() => pool.vectorSources[id]![0] = 0, throwsUnsupportedError);
      expect(pool.allocatedVectorSourceBytes, utf8.encode(source).length);
      final pixels = (await t.runAsync(
        () => pool.images[id]!.toByteData(
          format: ui.ImageByteFormat.rawStraightRgba,
        ),
      ))!;
      expect(
        [for (var i = 0; i < 4; i++) pixels.getUint8(i)],
        [255, 0, 0, 255],
      );
      pool.retain([id]);
      pool.acknowledge(id);
      expect(pool.vectorSources.keys, [id]);
      pool.retain([]);
      expect(pool.vectorSources, isEmpty);
      expect(pool.allocatedVectorSourceBytes, greaterThan(0));
      await t.pump();
      await t.pump();
      expect(pool.allocatedVectorSourceBytes, 0);
      expect(pool.allocatedPixels, 0);
      pool.dispose();
    },
  );

  testWidgets(
    'SVG source budget remains bounded and recovers after version retirement',
    (t) async {
      await t.runAsync(() async {
        final prototype = await tinyImage();
        final release = Completer<void>();
        final pool = NativeDocumentImagePool(
          decoder: (_, _, reserve) async {
            await reserve(2, 2);
            return prototype.clone();
          },
          release: (image) async {
            await release.future;
            image.dispose();
          },
        );
        try {
          final bytes = Uint8List(NativeDocumentImagePool.maxEncodedBytes);
          for (var i = 1; i <= 17; i++) {
            await pool.decode(
              'image-$i',
              bytes,
              'image/svg+xml',
              originClean: true,
            );
          }
          expect(pool.images, hasLength(17));
          expect(pool.vectorSources, hasLength(16));
          expect(
            pool.allocatedVectorSourceBytes,
            NativeDocumentImagePool.maxVectorSourceBytes,
          );
          // Raster decoding must keep working even when the optional vector source cache is full.
          await pool.decode(
            'image-18',
            Uint8List(1),
            'image/png',
            originClean: true,
          );
          expect(pool.images, hasLength(18));
          expect(pool.vectorSources, hasLength(16));
          pool.dispose();
          expect(pool.vectorSources, isEmpty);
          expect(
            pool.allocatedVectorSourceBytes,
            NativeDocumentImagePool.maxVectorSourceBytes,
          );
          release.complete();
          await Future<void>.delayed(Duration.zero);
          expect(pool.allocatedVectorSourceBytes, 0);
          expect(pool.allocatedPixels, 0);
        } finally {
          if (!release.isCompleted) release.complete();
          pool.dispose();
          prototype.dispose();
        }
      });
    },
  );

  testWidgets(
    'failed and obsolete decodes return reserved vector source memory',
    (t) async {
      await t.runAsync(() async {
        final failure = NativeDocumentImagePool(
          decoder: (_, _, _) async =>
              throw const FormatException('synthetic failed SVG'),
        );
        await expectLater(
          failure.decode(
            'image-1',
            Uint8List(8),
            'image/svg+xml',
            originClean: true,
          ),
          throwsFormatException,
        );
        expect(failure.vectorSources, isEmpty);
        expect(failure.allocatedVectorSourceBytes, 0);
        failure.dispose();
        final gate = Completer<ui.Image>();
        final pool = NativeDocumentImagePool(
          decoder: (_, _, reserve) async {
            await reserve(2, 2);
            return gate.future;
          },
          release: (image) async => image.dispose(),
        );
        final pending = pool.decode(
          'image-1',
          Uint8List(8),
          'image/svg+xml',
          originClean: true,
        );
        final assertion = expectLater(pending, throwsStateError);
        expect(pool.allocatedVectorSourceBytes, 8);
        pool.dispose();
        gate.complete(await tinyImage());
        await assertion;
        await Future<void>.delayed(Duration.zero);
        expect(pool.vectorSources, isEmpty);
        expect(pool.allocatedVectorSourceBytes, 0);
        expect(pool.allocatedPixels, 0);
      });
    },
  );
}
