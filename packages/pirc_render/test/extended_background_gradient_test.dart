import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_render/src/html_background_gradient.dart';

final _reference =
    jsonDecode(
          File(
            '../../fixtures/mobile-parity/html-extended-background-gradients.json',
          ).readAsStringSync(),
        )
        as Map<String, dynamic>;
final _cases = (_reference['cases'] as List).cast<Map<String, dynamic>>();

void main() {
  for (final item in _cases) {
    testWidgets('gradient ${item['id']} matches local Chrome pixels', (
      tester,
    ) async {
      final gradient = parseNativeHtmlBackgroundGradient(item['css'] as String);
      expect(gradient, isNotNull);
      final samples = (item['samples'] as List).cast<Map<String, dynamic>>();
      final points = samples
          .map((sample) => (sample['x'] as int, sample['y'] as int))
          .toList(growable: false);
      final pixels = await tester.runAsync(
        () => _paintSamples(
          gradient!,
          item['width'] as int,
          item['height'] as int,
          points,
        ),
      );
      expect(pixels, hasLength(samples.length));
      final actualPixels = pixels!;
      for (var index = 0; index < samples.length; index++) {
        final expected = (samples[index]['rgba'] as List).cast<int>();
        for (var channel = 0; channel < 4; channel++) {
          expect(
            (actualPixels[index][channel] - expected[channel]).abs(),
            lessThanOrEqualTo(4),
            reason:
                '${item['id']} pixel $index channel $channel: '
                'native=${actualPixels[index]}, Chrome=$expected',
          );
        }
      }
    });
  }

  test('conic header keywords and angle units are case insensitive', () {
    final gradient =
        parseNativeHtmlBackgroundGradient(
              'CONIC-GRADIENT(FROM 100GRAD AT 25% 75% IN SRGB, RED 0DEG, BLUE 1TURN)',
            )!
            as NativeHtmlConicGradient;
    expect(gradient.angleRadians, closeTo(1.5707963267948966, 1e-9));
    expect(
      gradient.centerFor(const Rect.fromLTWH(10, 20, 200, 80)),
      const Offset(60, 80),
    );
    expect(gradient.resolveStopsFor(const Rect.fromLTWH(0, 0, 100, 100)), [
      0,
      1,
    ]);
  });
  test('conic positions and units resolve without losing negative stops', () {
    final gradient =
        parseNativeHtmlBackgroundGradient(
              'repeating-conic-gradient(from 100grad at 25% 75%, red -0.25turn, blue 180deg)',
            )!
            as NativeHtmlConicGradient;
    expect(gradient.angleRadians, closeTo(1.5707963267948966, 1e-9));
    expect(
      gradient.centerFor(const Rect.fromLTWH(10, 20, 200, 80)),
      const Offset(60, 80),
    );
    expect(gradient.resolveStopsFor(const Rect.fromLTWH(0, 0, 100, 100)), [
      -.25,
      .5,
    ]);
    expect((gradient.scale(.5) as NativeHtmlConicGradient).repeating, isTrue);
    expect(
      (gradient.withOpacity(.5) as NativeHtmlConicGradient).repeating,
      isTrue,
    );
  });
  test('repeating radial length stops use the ellipse horizontal radius', () {
    final gradient =
        parseNativeHtmlBackgroundGradient(
              'repeating-radial-gradient(ellipse 40px 20px, red -10px, blue 30px)',
            )!
            as NativeHtmlRadialGradient;
    expect(gradient.resolveStopsFor(const Rect.fromLTWH(0, 0, 100, 100)), [
      -.25,
      .75,
    ]);
    expect((gradient.scale(.5) as NativeHtmlRadialGradient).repeating, isTrue);
    expect(
      (gradient.withOpacity(.5) as NativeHtmlRadialGradient).repeating,
      isTrue,
    );
    final linear =
        parseNativeHtmlBackgroundGradient(
              'repeating-linear-gradient(red, blue)',
            )!
            as NativeHtmlLinearGradient;
    expect((linear.scale(.5) as NativeHtmlLinearGradient).repeating, isTrue);
    expect(
      (linear.withOpacity(.5) as NativeHtmlLinearGradient).repeating,
      isTrue,
    );
  });
}

Future<List<List<int>>> _paintSamples(
  Gradient gradient,
  int width,
  int height,
  List<(int, int)> points,
) async {
  final rect = Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble());
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawRect(rect, Paint()..shader = gradient.createShader(rect));
  final picture = recorder.endRecording();
  final image = await picture.toImage(width, height);
  try {
    final data = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
    final rgba = data.buffer.asUint8List();
    return points
        .map((point) {
          final offset = (point.$2 * width + point.$1) * 4;
          final alpha = rgba[offset + 3];
          if (alpha == 0) return <int>[0, 0, 0, 0];
          return <int>[
            for (var channel = 0; channel < 3; channel++)
              ((rgba[offset + channel] * 255 + alpha / 2) / alpha)
                  .round()
                  .clamp(0, 255),
            alpha,
          ];
        })
        .toList(growable: false);
  } finally {
    image.dispose();
    picture.dispose();
  }
}
