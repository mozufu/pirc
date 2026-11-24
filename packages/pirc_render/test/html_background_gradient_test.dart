import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_render/src/html_background_gradient.dart';

final _reference =
    jsonDecode(
          File(
            '../../fixtures/mobile-parity/html-background-gradients.json',
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

  test(
    'parses a non-gradient and rejects recognized unsupported gradients',
    () {
      expect(parseNativeHtmlBackgroundGradient('url(image.png)'), isNull);
      expect(
        () => parseNativeHtmlBackgroundGradient(
          'repeating-linear-gradient(red 1turn, blue)',
        ),
        throwsFormatException,
      );
      expect(
        () =>
            parseNativeHtmlBackgroundGradient('conic-gradient(red 10px, blue)'),
        throwsFormatException,
      );
      expect(
        () => parseNativeHtmlBackgroundGradient(
          'linear-gradient(red, blue), url(x.png)',
        ),
        throwsFormatException,
      );
      expect(
        () => parseNativeHtmlBackgroundGradient(
          'linear-gradient(in oklab, red, blue)',
        ),
        throwsFormatException,
      );
    },
  );

  test(
    'linear angles accept CSS angle units and preserve non-square corners',
    () {
      double angle(String css, Rect rect) {
        final gradient =
            parseNativeHtmlBackgroundGradient(css)! as NativeHtmlLinearGradient;
        return gradient.angleRadiansFor(rect);
      }

      const rect = Rect.fromLTWH(0, 0, 120, 80);
      expect(
        angle('linear-gradient(180deg, red, blue)', rect),
        closeTo(math.pi, 1e-10),
      );
      expect(
        angle('linear-gradient(0.5turn, red, blue)', rect),
        closeTo(math.pi, 1e-10),
      );
      expect(
        angle('linear-gradient(200grad, red, blue)', rect),
        closeTo(math.pi, 1e-10),
      );
      expect(
        angle('linear-gradient(${math.pi}rad, red, blue)', rect),
        closeTo(math.pi, 1e-10),
      );
      expect(
        angle('linear-gradient(to top right, red, blue)', rect),
        closeTo(math.atan2(80, 120), 1e-10),
      );
    },
  );

  test(
    'linear pixel and double-position stops resolve against the paint box',
    () {
      final gradient =
          parseNativeHtmlBackgroundGradient(
                'linear-gradient(90deg, rgba(255,0,0,0) 0px 20px, blue 40px 60px, white 100%)',
              )!
              as NativeHtmlLinearGradient;
      expect(
        gradient.resolveStopsFor(const Rect.fromLTWH(0, 0, 160, 32)),
        <double>[0, 0.125, 0.25, 0.375, 1],
      );

      final distributed =
          parseNativeHtmlBackgroundGradient(
                'linear-gradient(red 20%, green, blue 80%)',
              )!
              as NativeHtmlLinearGradient;
      expect(
        distributed.resolveStopsFor(const Rect.fromLTWH(0, 0, 100, 10)),
        <double>[0.2, 0.5, 0.8],
      );
    },
  );

  test('radial default, circle, and explicit ellipse resolve to CSS boxes', () {
    final defaultGradient =
        parseNativeHtmlBackgroundGradient('radial-gradient(red, blue)')!
            as NativeHtmlRadialGradient;
    final defaultGeometry = defaultGradient.geometryFor(
      const Rect.fromLTWH(0, 0, 120, 80),
    );
    expect(defaultGeometry.center, const Offset(60, 40));
    expect(defaultGeometry.radiusX, closeTo(60 * math.sqrt2, 0.001));
    expect(defaultGeometry.radiusY, closeTo(40 * math.sqrt2, 0.001));

    final circle =
        parseNativeHtmlBackgroundGradient('radial-gradient(circle, red, blue)')!
            as NativeHtmlRadialGradient;
    final circleGeometry = circle.geometryFor(
      const Rect.fromLTWH(0, 0, 120, 80),
    );
    expect(
      circleGeometry.radiusX,
      closeTo(math.sqrt(60 * 60 + 40 * 40), 0.001),
    );
    expect(circleGeometry.radiusY, circleGeometry.radiusX);

    final ellipse =
        parseNativeHtmlBackgroundGradient(
              'radial-gradient(ellipse 60px 30px at 25% 50%, lime, black)',
            )!
            as NativeHtmlRadialGradient;
    final ellipseGeometry = ellipse.geometryFor(
      const Rect.fromLTWH(0, 0, 120, 80),
    );
    expect(ellipseGeometry.center, const Offset(30, 40));
    expect(ellipseGeometry.radiusX, 60);
    expect(ellipseGeometry.radiusY, 30);
  });

  test('full CSS named colors, alpha hex, and HSL colors parse', () {
    final named = parseNativeHtmlBackgroundGradient(
      'linear-gradient(aliceblue, rebeccapurple)',
    )!;
    expect(named.colors.first.toARGB32(), const Color(0xfff0f8ff).toARGB32());
    expect(named.colors.last.toARGB32(), const Color(0xff663399).toARGB32());

    final alpha = parseNativeHtmlBackgroundGradient(
      'linear-gradient(#f008, hsla(120, 100%, 50%, 50%))',
    )!;
    expect(alpha.colors.first.a, closeTo(0.533, 0.005));
    expect(alpha.colors.last.g, closeTo(1, 0.001));
    expect(alpha.colors.last.a, closeTo(0.5, 0.005));
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
