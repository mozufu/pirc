import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter/rendering.dart';
import 'package:pirc_render_document/src/document_canvas.dart';

void main() {
  testWidgets('Canvas updates pixels without repainting its static parent', (
    tester,
  ) async {
    final x = ValueNotifier<double>(2);
    addTearDown(x.dispose);
    var parentPaints = 0;
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Align(
          alignment: Alignment.topLeft,
          child: CustomPaint(
            painter: _CanvasParentPaintCounter(() => parentPaints++),
            child: ValueListenableBuilder<double>(
              valueListenable: x,
              builder: (_, value, _) => NativeDocumentCanvas(
                width: 20,
                height: 12,
                snapshot: _snapshot(20, 12, [
                  _command('fillRect', [
                    value,
                    2,
                    4,
                    6,
                  ], state: _state(fillStyle: 'red')),
                ]),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    final finder = find.descendant(
      of: find.byType(NativeDocumentCanvas),
      matching: find.byType(RepaintBoundary),
    );
    final boundary = tester.renderObject<RenderRepaintBoundary>(finder);
    Future<List<int>> pixelAt(int position) async {
      final image = (await tester.runAsync(() => boundary.toImage()))!;
      try {
        final bytes = (await tester.runAsync(
          () => image.toByteData(format: ui.ImageByteFormat.rawRgba),
        ))!;
        return bytes.buffer.asUint8List().sublist(
          (4 * 20 + position) * 4,
          (4 * 20 + position) * 4 + 4,
        );
      } finally {
        image.dispose();
      }
    }

    expect(await pixelAt(3), [255, 0, 0, 255]);
    expect(await pixelAt(11), [0, 0, 0, 0]);
    final initialParentPaints = parentPaints;
    expect(initialParentPaints, greaterThan(0));
    x.value = 10;
    await tester.pump();
    expect(tester.renderObject<RenderRepaintBoundary>(finder), same(boundary));
    expect(await pixelAt(3), [0, 0, 0, 0]);
    expect(await pixelAt(11), [255, 0, 0, 255]);
    expect(parentPaints, initialParentPaints);
  });
  testWidgets('negative rect dimensions and clearRect keep Canvas geometry', (
    tester,
  ) async {
    final snapshot = _snapshot(20, 12, [
      _command('fillRect', [12, 2, -8, 8], state: _state(fillStyle: '#e11d48')),
      _command('clearRect', [
        0,
        0,
        9,
        12,
      ], state: _state(clips: [_clip(_rectPath(0, 0, 9, 12))])),
    ]);

    final pixels = await _renderSamples(tester, snapshot, [
      (6, 3),
      (11, 9),
      (19, 11),
    ]);
    expect(pixels[0][3], 0, reason: 'clearRect clears inside its clip');
    _expectPixelCloseTo(pixels[1], [225, 29, 72, 255]);
    expect(pixels[2][3], 0, reason: 'the canvas bounds clip all commands');
  });

  testWidgets('captured path transforms, clips, and dashed strokes paint', (
    tester,
  ) async {
    final path = [
      _segment('rect', [0, 0, 6, 6], [1, 0, 0, 1, 8, 2]),
    ];
    final line = [
      _segment('moveTo', [1, 11]),
      _segment('lineTo', [19, 11]),
    ];
    final snapshot = _snapshot(22, 14, [
      _command(
        'fill',
        ['nonzero'],
        state: _state(
          fillStyle: 'blue',
          transform: [2, 0, 0, 2, 0, 0],
          path: path,
        ),
      ),
      _command(
        'stroke',
        const [],
        state: _state(
          strokeStyle: 'red',
          lineWidth: 2,
          lineDash: [4, 4],
          path: line,
        ),
      ),
    ]);

    final pixels = await _renderSamples(tester, snapshot, [
      (11, 5),
      (5, 5),
      (2, 11),
      (6, 11),
      (10, 11),
    ]);
    _expectPixelCloseTo(pixels[0], [0, 0, 255, 255]);
    expect(pixels[1][3], 0);
    expect(pixels[2][3], greaterThan(150));
    expect(pixels[3][3], lessThan(80));
    expect(pixels[4][3], greaterThan(150));
  });

  testWidgets(
    'global alpha, destination-out, and source-in use layer semantics',
    (tester) async {
      final alphaSnapshot = _snapshot(16, 8, [
        _command('fillRect', [0, 0, 16, 8], state: _state(fillStyle: 'red')),
        _command(
          'fillRect',
          [0, 0, 6, 8],
          state: _state(
            fillStyle: 'black',
            alpha: .5,
            composite: 'destination-out',
          ),
        ),
      ]);
      final alphaPixels = await _renderSamples(tester, alphaSnapshot, [
        (2, 4),
        (10, 4),
      ]);
      _expectPixelCloseTo(alphaPixels[0], [255, 0, 0, 128]);
      _expectPixelCloseTo(alphaPixels[1], [255, 0, 0, 255]);

      final sourceInSnapshot = _snapshot(16, 8, [
        _command('fillRect', [0, 0, 16, 8], state: _state(fillStyle: 'red')),
        _command('fillRect', [
          0,
          0,
          5,
          8,
        ], state: _state(fillStyle: 'blue', composite: 'source-in')),
      ]);
      final sourceInPixels = await _renderSamples(tester, sourceInSnapshot, [
        (2, 4),
        (10, 4),
      ]);
      _expectPixelCloseTo(sourceInPixels[0], [0, 0, 255, 255]);
      expect(sourceInPixels[1][3], 0);
    },
  );

  testWidgets('linear gradient follows draw transform, not creation transform', (
    tester,
  ) async {
    final gradient = <String, Object?>{
      'type': 'linear',
      'args': [0, 0, 40, 0],
      'transform': [1, 0, 0, 1, 50, 0],
      'stops': [
        {'offset': 0, 'color': '#ef4444'},
        {'offset': 1, 'color': '#2563eb'},
      ],
    };
    final snapshot = _snapshot(110, 30, [
      _command('fillRect', [
        0,
        0,
        40,
        30,
      ], state: _state(fillStyle: gradient, transform: [2, 0, 0, 1, 20, 0])),
    ]);
    final pixels = await _renderSamples(tester, snapshot, [
      (22, 10),
      (40, 10),
      (60, 10),
      (90, 10),
      (110, 10),
    ]);
    const browser = [
      [232, 69, 73, 255],
      [187, 76, 110, 255],
      [136, 83, 152, 255],
      [61, 95, 215, 255],
      [0, 0, 0, 0],
    ];
    for (var sample = 0; sample < browser.length; sample++) {
      for (var channel = 0; channel < 4; channel++) {
        expect(
          (pixels[sample][channel] - browser[sample][channel]).abs(),
          lessThanOrEqualTo(8),
          reason:
              'sample $sample channel $channel: ${pixels[sample]} vs ${browser[sample]}',
        );
      }
    }
  });

  testWidgets('text uses Canvas font, alignment, and baseline layout', (
    tester,
  ) async {
    final snapshot = _snapshot(100, 36, [
      _command(
        'fillText',
        ['Canvas', 50, 25],
        state: _state(
          fillStyle: 'black',
          font: '16px Arial',
          textAlign: 'center',
        ),
      ),
    ]);
    final pixels = await _renderSamples(tester, snapshot, [
      for (var y = 0; y < 36; y++)
        for (var x = 0; x < 100; x++) (x, y),
    ]);
    var ink = 0;
    var minX = 100;
    var maxX = 0;
    var minY = 36;
    var maxY = 0;
    var index = 0;
    for (var y = 0; y < 36; y++) {
      for (var x = 0; x < 100; x++) {
        if (pixels[index++][3] == 0) continue;
        ink++;
        minX = x < minX ? x : minX;
        maxX = x > maxX ? x : maxX;
        minY = y < minY ? y : minY;
        maxY = y > maxY ? y : maxY;
      }
    }
    expect(ink, greaterThan(40));
    expect((minX + maxX) / 2, closeTo(50, 2));
    expect(minY, greaterThan(0));
    expect(maxY, lessThan(35));
  });

  testWidgets('native text baseline metadata moves rendered ink', (
    tester,
  ) async {
    const width = 64;
    const height = 48;
    final points = [
      for (var y = 0; y < height; y++)
        for (var x = 0; x < width; x++) (x, y),
    ];
    NativeDocumentCanvasSnapshot draw(double baselineOffset) =>
        _snapshot(width, height, [
          _command(
            'fillText',
            ['A', 8, 24],
            state: _state(
              fillStyle: 'black',
              font: '18px Arial',
              textBaselineOffset: baselineOffset,
            ),
          ),
        ]);

    final first = _topInkRow(
      await _renderSamples(tester, draw(1.25), points),
      width,
      height,
    );
    final shifted = _topInkRow(
      await _renderSamples(tester, draw(6.25), points),
      width,
      height,
    );

    expect(first, greaterThanOrEqualTo(0));
    expect(shifted, first + 5);
  });

  testWidgets('fillText and strokeText normalize whitespace before shaping', (
    tester,
  ) async {
    final points = [
      for (var y = 0; y < 36; y++)
        for (var x = 0; x < 150; x++) (x, y),
    ];
    for (final operation in ['fillText', 'strokeText']) {
      NativeDocumentCanvasSnapshot draw(String text) => _snapshot(150, 36, [
        _command(
          operation,
          [text, 2, 25],
          state: _state(
            fillStyle: 'black',
            strokeStyle: 'black',
            font: '16px Arial',
          ),
        ),
      ]);
      final actual = await _renderSamples(
        tester,
        draw('A\tV\nT\vX\fY\rZ'),
        points,
      );
      final expected = await _renderSamples(
        tester,
        draw('A V T X Y Z'),
        points,
      );
      expect(actual, expected, reason: operation);
      expect(actual.any((pixel) => pixel[3] != 0), true);
    }
  });

  testWidgets('one-stop gradients paint as their stop color', (tester) async {
    final snapshot = _snapshot(8, 8, [
      _command(
        'fillRect',
        [0, 0, 8, 8],
        state: _state(
          fillStyle: {
            'type': 'linear',
            'args': [0, 0, 8, 0],
            'transform': [1, 0, 0, 1, 0, 0],
            'stops': [
              {'offset': 0.5, 'color': '#22c55e'},
            ],
          },
        ),
      ),
    ]);
    final pixels = await _renderSamples(tester, snapshot, [(4, 4)]);
    _expectPixelCloseTo(pixels.single, [34, 197, 94, 255]);
  });

  test(
    'decoder reports unsupported commands and accepts transparent gradients',
    () {
      final unsupported = _snapshotJson(4, 4, [
        _command('drawImage', const [], state: _state()),
      ]);
      expect(
        () => NativeDocumentCanvasSnapshot.fromJson(unsupported),
        throwsA(isA<NativeDocumentCanvasException>()),
      );

      final emptyGradient = _snapshot(4, 4, [
        _command(
          'fillRect',
          [0, 0, 4, 4],
          state: _state(
            fillStyle: {
              'type': 'linear',
              'args': [0, 0, 4, 0],
              'transform': [1, 0, 0, 1, 0, 0],
              'stops': const <Object?>[],
            },
          ),
        ),
      ]);
      expect(emptyGradient.commands, hasLength(1));
    },
  );

  test('decoder validates optional native text baseline metadata', () {
    Map<String, Object?> textSnapshot({double? offset}) => _snapshotJson(8, 8, [
      _command('fillText', [
        'A',
        0,
        4,
      ], state: _state(textBaselineOffset: offset)),
    ]);

    final missing = NativeDocumentCanvasSnapshot.fromJson(textSnapshot());
    expect(missing.commands.single.state.textBaselineOffset, isNull);

    final finite = NativeDocumentCanvasSnapshot.fromJson(
      textSnapshot(offset: -2.5),
    );
    expect(finite.commands.single.state.textBaselineOffset, -2.5);

    for (final invalidOffset in [
      double.nan,
      double.infinity,
      double.negativeInfinity,
      1e9 + 1,
    ]) {
      expect(
        () => NativeDocumentCanvasSnapshot.fromJson(
          textSnapshot(offset: invalidOffset),
        ),
        throwsA(isA<NativeDocumentCanvasException>()),
        reason: 'baseline offset $invalidOffset must be rejected',
      );
    }
  });

  test('decoder rejects dashed paths that exceed the paint work budget', () {
    final snapshot = _snapshotJson(8, 8, [
      _command(
        'stroke',
        const [],
        state: _state(
          lineDash: [0.0001, 0.0001],
          path: [
            _segment('moveTo', [0, 4]),
            _segment('lineTo', [10000, 4]),
          ],
        ),
      ),
    ]);
    expect(
      () => NativeDocumentCanvasSnapshot.fromJson(snapshot),
      throwsA(
        isA<NativeDocumentCanvasException>().having(
          (error) => error.code,
          'code',
          'canvas-dash-limit',
        ),
      ),
    );
  });

  test('dash work is rejected before painting can monopolize the UI', () {
    expect(
      () => _snapshot(120, 60, [
        _command('strokeRect', [
          0,
          0,
          120,
          60,
        ], state: _state(lineDash: [1e-13, 1e-13])),
      ]),
      throwsA(isA<NativeDocumentCanvasException>()),
    );
    expect(
      () => _snapshot(120, 60, [
        _command('strokeRect', [
          0,
          0,
          120,
          60,
        ], state: _state(lineDash: [0, 4])),
      ]),
      returnsNormally,
    );
  });

  testWidgets('degenerate natural ratio uses the other natural dimension', (
    tester,
  ) async {
    for (final row in [
      (0, 150, 80.0, null, const Size(80, 150)),
      (160, 0, null, 90.0, const Size(160, 90)),
      (0, 0, 80.0, null, const Size(80, 0)),
    ]) {
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: Align(
            alignment: Alignment.topLeft,
            child: NativeDocumentCanvas(
              snapshot: _snapshot(row.$1, row.$2, const []),
              width: row.$3,
              height: row.$4,
            ),
          ),
        ),
      );
      expect(tester.getSize(find.byType(CustomPaint)), row.$5);
    }
  });

  testWidgets('one-axis CSS sizing preserves the canvas intrinsic ratio', (
    tester,
  ) async {
    final snapshot = _snapshot(120, 60, const []);
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Align(
          alignment: Alignment.topLeft,
          child: NativeDocumentCanvas(snapshot: snapshot, width: 240),
        ),
      ),
    );
    expect(tester.getSize(find.byType(CustomPaint)), const Size(240, 120));

    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Align(
          alignment: Alignment.topLeft,
          child: NativeDocumentCanvas(snapshot: snapshot, height: 90),
        ),
      ),
    );
    expect(tester.getSize(find.byType(CustomPaint)), const Size(180, 90));
  });
}

Future<List<List<int>>> _renderSamples(
  WidgetTester tester,
  NativeDocumentCanvasSnapshot snapshot,
  List<(int, int)> points,
) async {
  final pixels = await tester.runAsync(
    () => _renderSamplesFromPicture(snapshot, points),
  );
  return pixels!;
}

Future<List<List<int>>> _renderSamplesFromPicture(
  NativeDocumentCanvasSnapshot snapshot,
  List<(int, int)> points,
) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  NativeDocumentCanvasPainter(
    snapshot,
  ).paint(canvas, Size(snapshot.width, snapshot.height));
  final picture = recorder.endRecording();
  final image = await picture.toImage(
    snapshot.width.toInt(),
    snapshot.height.toInt(),
  );
  try {
    final data = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
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
    image.dispose();
    picture.dispose();
  }
}

int _topInkRow(List<List<int>> pixels, int width, int height) {
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      if (pixels[y * width + x][3] != 0) return y;
    }
  }
  return -1;
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
  'id': 'test-canvas',
  'width': width,
  'height': height,
  'revision': 1,
  'commands': commands,
};

Map<String, Object?> _command(
  String op,
  List<Object?> args, {
  required Map<String, Object?> state,
}) => <String, Object?>{'op': op, 'args': args, 'state': state};

Map<String, Object?> _state({
  Object fillStyle = 'black',
  Object strokeStyle = 'black',
  List<num> transform = const [1, 0, 0, 1, 0, 0],
  double alpha = 1,
  String composite = 'source-over',
  double lineWidth = 1,
  List<num> lineDash = const [],
  String font = '10px sans-serif',
  String textAlign = 'start',
  String textBaseline = 'alphabetic',
  double? textBaselineOffset,
  List<Map<String, Object?>>? path,
  List<Map<String, Object?>> clips = const [],
}) => <String, Object?>{
  'transform': transform,
  'fillStyle': fillStyle,
  'strokeStyle': strokeStyle,
  'globalAlpha': alpha,
  'globalCompositeOperation': composite,
  'lineWidth': lineWidth,
  'lineCap': 'butt',
  'lineJoin': 'miter',
  'miterLimit': 10,
  'lineDash': lineDash,
  'lineDashOffset': 0,
  'font': font,
  'textAlign': textAlign,
  'textBaseline': textBaseline,
  'textBaselineOffset': ?textBaselineOffset,
  'direction': 'ltr',
  'clips': clips,
  'path': ?path,
};

void _expectPixelCloseTo(
  List<int> actual,
  List<int> expected, {
  int tolerance = 2,
}) {
  expect(actual, hasLength(expected.length));
  for (var channel = 0; channel < expected.length; channel++) {
    expect(
      (actual[channel] - expected[channel]).abs(),
      lessThanOrEqualTo(tolerance),
      reason: 'channel $channel: $actual vs $expected',
    );
  }
}

Map<String, Object?> _clip(List<Map<String, Object?>> path) =>
    <String, Object?>{'path': path, 'rule': 'nonzero'};

List<Map<String, Object?>> _rectPath(num x, num y, num width, num height) => [
  _segment('rect', [x, y, width, height]),
];

Map<String, Object?> _segment(
  String op,
  List<Object?> args, [
  List<num> transform = const [1, 0, 0, 1, 0, 0],
]) => <String, Object?>{'op': op, 'args': args, 'transform': transform};

class _CanvasParentPaintCounter extends CustomPainter {
  _CanvasParentPaintCounter(this.onPaint);
  final VoidCallback onPaint;
  @override
  void paint(Canvas canvas, Size size) => onPaint();
  @override
  bool shouldRepaint(covariant _CanvasParentPaintCounter oldDelegate) => false;
}
