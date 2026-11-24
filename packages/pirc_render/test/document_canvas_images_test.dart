import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_render/src/document_canvas.dart';

const _twoByTwoPng =
    'iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAYAAABytg0kAAAAFElEQVR4nGP4z8DwHwyBNBAw/AcAR8oI+ItOQ4UAAAAASUVORK5CYII=';

void main() {
  testWidgets('3, 5, and 9 argument draws paint the expected source pixels', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final image = await _decodeFixtureImage();
      try {
        final snapshot = _snapshot(12, 4, [
          // Three argument overload: intrinsic size at the destination point.
          _command('drawImage', [
            'decoded-1',
            0,
            0,
            2,
            2,
            0,
            0,
            2,
            2,
          ], _state()),
          // Five argument overload: full source stretched to the destination.
          _command('drawImage', [
            'decoded-1',
            0,
            0,
            2,
            2,
            4,
            0,
            4,
            4,
          ], _state()),
          // Nine argument overload: crop the source's right-hand column.
          _command('drawImage', [
            'decoded-1',
            1,
            0,
            1,
            2,
            8,
            0,
            4,
            4,
          ], _state()),
        ]);
        final pixels = await _renderSamples(
          snapshot,
          {'decoded-1': image},
          [
            (0, 0),
            (1, 0),
            (0, 1),
            (1, 1),
            (4, 0),
            (6, 0),
            (4, 2),
            (6, 2),
            (9, 0),
            (9, 2),
          ],
        );
        _expectPixelCloseTo(pixels[0], [255, 0, 0, 255]);
        _expectPixelCloseTo(pixels[1], [0, 255, 0, 255]);
        _expectPixelCloseTo(pixels[2], [0, 0, 255, 255]);
        _expectPixelCloseTo(pixels[3], [255, 255, 0, 255]);
        _expectPixelCloseTo(pixels[4], [255, 0, 0, 255]);
        _expectPixelCloseTo(pixels[5], [0, 255, 0, 255]);
        _expectPixelCloseTo(pixels[6], [0, 0, 255, 255]);
        _expectPixelCloseTo(pixels[7], [255, 255, 0, 255]);
        _expectPixelCloseTo(pixels[8], [0, 255, 0, 255]);
        _expectPixelCloseTo(pixels[9], [255, 255, 0, 255]);
      } finally {
        image.dispose();
      }
    });
  });

  testWidgets(
    'drawImage paints a decoded image crop with transform, clip, and alpha',
    (tester) async {
      await tester.runAsync(() async {
        final image = await _decodeFixtureImage();
        try {
          final snapshot = _snapshot(10, 8, [
            _command(
              'drawImage',
              ['decoded-1', 0, 0, 2, 2, 0, 0, 4, 4],
              _state(
                transform: [1, 0, 0, 1, 4, 2],
                alpha: 0.5,
                imageSmoothingEnabled: false,
                clips: [_clip(_rectPath(4, 2, 3, 4))],
              ),
            ),
          ]);

          final pixels = await _renderSamples(
            snapshot,
            {'decoded-1': image},
            [
              (4, 2), // clipped top-left red
              (6, 2), // clipped top-right green
              (4, 4), // clipped bottom-left blue
              (6, 4), // clipped bottom-right yellow
              (7, 2), // outside the clip
              (1, 1), // background
            ],
          );
          _expectPixelCloseTo(pixels[0], [255, 0, 0, 128]);
          _expectPixelCloseTo(pixels[1], [0, 255, 0, 128]);
          _expectPixelCloseTo(pixels[2], [0, 0, 255, 128]);
          _expectPixelCloseTo(pixels[3], [255, 255, 0, 128]);
          _expectPixelCloseTo(pixels[4], [0, 0, 0, 0]);
          _expectPixelCloseTo(pixels[5], [0, 0, 0, 0]);
        } finally {
          image.dispose();
        }
      });
    },
  );

  test('drawImage quality state is decoded and validated', () {
    final command = _command('drawImage', [
      'decoded-1',
      0,
      0,
      2,
      2,
      0,
      0,
      4,
      4,
    ], _state(imageSmoothingEnabled: true, imageSmoothingQuality: 'high'));
    final snapshot = _snapshot(4, 4, [command]);
    expect(snapshot.commands.single.state.imageSmoothingEnabled, isTrue);
    expect(
      snapshot.commands.single.state.imageSmoothingQuality,
      ui.FilterQuality.high,
    );

    final invalidQuality = _snapshotJson(4, 4, [
      _command('drawImage', [
        'decoded-1',
        0,
        0,
        2,
        2,
        0,
        0,
        4,
        4,
      ], _state(imageSmoothingQuality: 'nearest')),
    ]);
    expect(
      () => NativeDocumentCanvasSnapshot.fromJson(invalidQuality),
      throwsA(isA<NativeDocumentCanvasException>()),
    );
  });

  test(
    'missing drawImage handle reports a specific painter exception',
    () async {
      final snapshot = _snapshot(4, 4, [
        _command('drawImage', [
          'missing-image',
          0,
          0,
          2,
          2,
          0,
          0,
          4,
          4,
        ], _state()),
      ]);
      final recorder = ui.PictureRecorder();
      final canvas = ui.Canvas(recorder);
      expect(
        () => NativeDocumentCanvasPainter(
          snapshot,
        ).paint(canvas, const ui.Size(4, 4)),
        throwsA(
          isA<NativeDocumentCanvasException>().having(
            (error) => error.code,
            'code',
            'missing-canvas-image',
          ),
        ),
      );
      recorder.endRecording().dispose();
    },
  );
}

Future<ui.Image> _decodeFixtureImage() async {
  final codec = await ui.instantiateImageCodec(
    Uint8List.fromList(base64Decode(_twoByTwoPng)),
  );
  try {
    return (await codec.getNextFrame()).image;
  } finally {
    codec.dispose();
  }
}

Future<List<List<int>>> _renderSamples(
  NativeDocumentCanvasSnapshot snapshot,
  Map<String, ui.Image> images,
  List<(int, int)> points,
) async {
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder);
  NativeDocumentCanvasPainter(
    snapshot,
    images: images,
  ).paint(canvas, ui.Size(snapshot.width, snapshot.height));
  final picture = recorder.endRecording();
  final output = await picture.toImage(
    snapshot.width.toInt(),
    snapshot.height.toInt(),
  );
  try {
    final data = (await output.toByteData(format: ui.ImageByteFormat.rawRgba))!;
    final rgba = data.buffer.asUint8List();
    return points
        .map((point) {
          final offset = (point.$2 * snapshot.width.toInt() + point.$1) * 4;
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
    output.dispose();
    picture.dispose();
  }
}

NativeDocumentCanvasSnapshot _snapshot(
  int width,
  int height,
  List<Map<String, Object?>> commands,
) => NativeDocumentCanvasSnapshot.fromJson(
  _snapshotJson(width, height, commands),
);

Map<String, Object?> _snapshotJson(
  int width,
  int height,
  List<Map<String, Object?>> commands,
) => <String, Object?>{
  'id': 'image-test',
  'width': width,
  'height': height,
  'revision': 1,
  'commands': commands,
};

Map<String, Object?> _command(
  String op,
  List<Object?> args,
  Map<String, Object?> state,
) => <String, Object?>{'op': op, 'args': args, 'state': state};

Map<String, Object?> _state({
  Object fillStyle = 'black',
  List<num> transform = const [1, 0, 0, 1, 0, 0],
  double alpha = 1,
  bool imageSmoothingEnabled = false,
  String imageSmoothingQuality = 'low',
  List<Map<String, Object?>> clips = const [],
}) => <String, Object?>{
  'transform': transform,
  'fillStyle': fillStyle,
  'strokeStyle': 'black',
  'globalAlpha': alpha,
  'globalCompositeOperation': 'source-over',
  'lineWidth': 1,
  'lineCap': 'butt',
  'lineJoin': 'miter',
  'miterLimit': 10,
  'lineDash': const <num>[],
  'lineDashOffset': 0,
  'imageSmoothingEnabled': imageSmoothingEnabled,
  'imageSmoothingQuality': imageSmoothingQuality,
  'font': '10px sans-serif',
  'textAlign': 'start',
  'textBaseline': 'alphabetic',
  'direction': 'ltr',
  'clips': clips,
};

Map<String, Object?> _clip(List<Map<String, Object?>> path) =>
    <String, Object?>{'path': path, 'rule': 'nonzero'};

List<Map<String, Object?>> _rectPath(num x, num y, num width, num height) => [
  {
    'op': 'rect',
    'args': [x, y, width, height],
    'transform': const [1, 0, 0, 1, 0, 0],
  },
];

void _expectPixelCloseTo(List<int> actual, List<int> expected) {
  expect(actual, hasLength(expected.length));
  for (var channel = 0; channel < expected.length; channel++) {
    expect(
      (actual[channel] - expected[channel]).abs(),
      lessThanOrEqualTo(2),
      reason: 'channel $channel: $actual vs $expected',
    );
  }
}
