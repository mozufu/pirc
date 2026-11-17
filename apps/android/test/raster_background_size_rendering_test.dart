import 'package:pirc_mobile/live/remote_content_gate.dart';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:html/parser.dart' as html;
import 'package:pirc_mobile/live/common.dart';
import 'package:pirc_mobile/live/document_background_image.dart';
import 'package:pirc_mobile/live/document_navigation_state.dart';
import 'package:pirc_mobile/rendering/html_document_styles.dart';
import 'package:pirc_mobile/rendering/html_image_background_decoration.dart';

import 'live_test.dart' show FakeGateway, theme;

final _rasterFixture = Map<String, dynamic>.from(
  jsonDecode(
        File(
          '../../fixtures/mobile-parity/raster-background-sizes-expected.json',
        ).readAsStringSync(),
      )
      as Map,
);
final _rasterCases = (_rasterFixture['cases'] as List).map(_object).toList();
final _animationCases =
    (jsonDecode(
              File(
                '../../fixtures/mobile-parity/animated-images.json',
              ).readAsStringSync(),
            )['cases']
            as List)
        .map(_object)
        .toList();

Map<String, dynamic> _object(Object? value) =>
    Map<String, dynamic>.from(value as Map);

String _cssName(String value) => value.replaceAllMapped(
  RegExp(r'[A-Z]'),
  (match) => '-${match[0]!.toLowerCase()}',
);

String _renderableMarkup(
  Map<String, dynamic> testCase, {
  required bool normalize,
  required Map<String, String> declarations,
}) {
  final document = html.parse('<div id="target"></div>');
  final element = document.querySelector('#target')!;
  final dimensions = _object(testCase['element']);
  element.attributes['style'] = <String>[
    'width:${(dimensions['width'] as num).toInt()}px',
    'height:${(dimensions['height'] as num).toInt()}px',
    for (final entry in declarations.entries) '${entry.key}:${entry.value}',
  ].join(';');
  if (normalize) {
    NativeDocumentStyleEngine(
      stylesheets: const [],
      viewportWidth: 390,
      dark: false,
      documentBaseUrl: 'https://gateway.example/parity.html',
    ).apply(document);
  }
  return element.outerHtml;
}

List<Map<String, dynamic>> _samples(Map<String, dynamic> testCase) =>
    (testCase['pixelSamples'] as List).map(_object).toList();

Future<({int width, int height, List<List<int>> rgba})> _captureSamples(
  WidgetTester tester,
  Finder boundaryFinder,
  List<Map<String, dynamic>> expected,
) async {
  final boundary = tester.renderObject<RenderRepaintBoundary>(boundaryFinder);
  final image = await boundary.toImage(pixelRatio: 1);
  try {
    final data = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
    final bytes = data.buffer.asUint8List(
      data.offsetInBytes,
      data.lengthInBytes,
    );
    return (
      width: image.width,
      height: image.height,
      rgba: [
        for (final sample in expected)
          (() {
            final x = (sample['x'] as num).toInt();
            final y = (sample['y'] as num).toInt();
            final offset = (y * image.width + x) * 4;
            return bytes.sublist(offset, offset + 4);
          })(),
      ],
    );
  } finally {
    image.dispose();
  }
}

List<String> _mismatches(
  List<Map<String, dynamic>> expected,
  List<List<int>> actual,
) {
  final mismatches = <String>[];
  for (var index = 0; index < expected.length; index++) {
    final item = expected[index];
    final want = (item['rgba'] as List)
        .cast<num>()
        .map((value) => value.toInt())
        .toList();
    final got = actual[index];
    for (var channel = 0; channel < 4; channel++) {
      final delta = (want[channel] - got[channel]).abs();
      if (delta > 3) {
        mismatches.add(
          '(${item['x']},${item['y']}) channel $channel expected '
          '${want[channel]}, got ${got[channel]} (Δ$delta)',
        );
      }
    }
  }
  return mismatches;
}

Future<({int width, int height, List<List<int>> rgba})> _captureUntilStable(
  WidgetTester tester,
  Finder boundaryFinder,
  List<Map<String, dynamic>> expected,
) async {
  late ({int width, int height, List<List<int>> rgba}) result;
  for (var attempt = 0; attempt < 30; attempt++) {
    if (attempt > 0) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump();
    }
    result = (await tester.runAsync(
      () => _captureSamples(tester, boundaryFinder, expected),
    ))!;
    if (_mismatches(expected, result.rgba).isEmpty) return result;
  }
  return result;
}

Future<void> _pumpRasterHtml(
  WidgetTester tester,
  String markup,
  FakeGateway gateway,
) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: theme.build(Brightness.light),
      home: Scaffold(
        body: RepaintBoundary(
          key: const ValueKey('raster-background-size'),
          child: SizedBox(
            width: 120,
            height: 80,
            child: RichTextBody(markup, gateway: gateway),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

Future<List<int>> _capturePixelRaw(
  WidgetTester tester,
  Finder boundaryFinder,
  int x,
  int y,
) async {
  final boundary = tester.renderObject<RenderRepaintBoundary>(boundaryFinder);
  final image = await boundary.toImage(pixelRatio: 1);
  try {
    final data = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
    final offset = (y * image.width + x) * 4;
    return data.buffer.asUint8List().sublist(offset, offset + 4);
  } finally {
    image.dispose();
  }
}

bool _isRed(List<int> pixel) =>
    pixel[0] > 200 && pixel[1] < 30 && pixel[2] < 30;
bool _isBlue(List<int> pixel) =>
    pixel[2] > 200 && pixel[0] < 30 && pixel[1] < 30;
Future<List<int>> _capturePixel(
  WidgetTester tester,
  Finder boundary,
  int x,
  int y,
) async =>
    (await tester.runAsync(() => _capturePixelRaw(tester, boundary, x, y)))!;

bool _isWhite(List<int> pixel) =>
    pixel[0] > 252 && pixel[1] > 252 && pixel[2] > 252 && pixel[3] > 252;

Future<List<int>> _waitForFrame(
  WidgetTester tester,
  Finder boundaryFinder,
  int x,
  int y,
  bool Function(List<int>) matches,
) async {
  var pixel = <int>[];
  for (var attempt = 0; attempt < 60; attempt++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump();
    pixel = (await tester.runAsync(
      () => _capturePixelRaw(tester, boundaryFinder, x, y),
    ))!;
    if (matches(pixel)) return pixel;
  }
  return pixel;
}

String _animatedMarkup(Map<String, dynamic> item, int width, int height) {
  final id = item['id'] as String;
  final size = id == 'gif' ? '60px auto' : '50% 50%';
  final repeat = id == 'gif' ? 'repeat-x' : 'repeat-y';
  return _renderableMarkup(
    {
      'element': {'width': width, 'height': height},
    },
    normalize: false,
    declarations: {
      'background-color': '#ffffff',
      'background-image': 'url("back.$id")',
      'background-size': size,
      'background-position': 'left top',
      'background-repeat': repeat,
    },
  );
}

Future<void> _pumpAnimatedHtml(
  WidgetTester tester,
  NativeDocumentWindows windows,
  FakeGateway gateway,
  Map<String, dynamic> item, {
  required int width,
  required int height,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: theme.build(Brightness.light),
      home: Scaffold(
        body: NativeDocumentScope(
          windows: windows,
          documentUrl: 'https://gateway.example/animated.html',
          child: RepaintBoundary(
            key: const ValueKey('animated-background-size'),
            child: SizedBox(
              width: width.toDouble(),
              height: height.toDouble(),
              child: RichTextBody(
                _animatedMarkup(item, 120, 80)
                    .replaceFirst('width:120px', 'width:100%')
                    .replaceFirst('height:80px', 'height:100%'),
                gateway: gateway,
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

Widget _directBackgroundHost(Decoration decoration) => MaterialApp(
  home: Scaffold(
    body: RepaintBoundary(
      key: const ValueKey('invalidated-background'),
      child: SizedBox(
        width: 100,
        height: 50,
        child: DecoratedBox(decoration: decoration),
      ),
    ),
  ),
);

void main() {
  setUpAll(() => NativeRemoteContentPolicy.debugOpenForTests = true);
  tearDownAll(() => NativeRemoteContentPolicy.debugOpenForTests = false);
  for (final testCase in _rasterCases) {
    final declarations = _object(
      testCase['authoredCss'],
    ).map((key, value) => MapEntry(_cssName(key), '$value'));
    final expected = _samples(testCase);
    for (final normalize in [false, true]) {
      testWidgets(
        'Chrome raster background size ${testCase['id']} normalized=$normalize',
        (tester) async {
          final gateway = FakeGateway();
          await _pumpRasterHtml(
            tester,
            _renderableMarkup(
              testCase,
              normalize: normalize,
              declarations: declarations,
            ),
            gateway,
          );
          // Oracle sample points are away from the principal interpolation
          // boundaries. Compare every emitted point; do not drop edge samples.
          final actual = await _captureUntilStable(
            tester,
            find.byKey(const ValueKey('raster-background-size')),
            expected,
          );
          expect((actual.width, actual.height), (120, 80));
          expect(
            _mismatches(expected, actual.rgba),
            isEmpty,
            reason: '${testCase['id']} Chrome pixel samples',
          );
          expect(tester.takeException(), isNull);
          expect(gateway.calls.where((call) => call.$1 == 'image'), isEmpty);
          await tester.pumpWidget(const SizedBox());
          await gateway.stream.close();
        },
      );
    }
  }

  for (final item in _animationCases) {
    testWidgets(
      'animated ${item['id']} background size paints both frames and survives resize/rebuild',
      (tester) async {
        final gateway = FakeGateway();
        gateway.handler = (method, args) async => method == 'image'
            ? {
                'bytes': base64Decode(item['base64'] as String),
                'mimeType': item['mimeType'],
              }
            : gateway.normal(method, args);
        final windows = NativeDocumentWindows(gateway);
        const boundary = ValueKey('animated-background-size');
        await _pumpAnimatedHtml(
          tester,
          windows,
          gateway,
          item,
          width: 120,
          height: 80,
        );

        final repeatedX = item['id'] == 'gif';
        final firstX = 5;
        final firstY = repeatedX ? 40 : 5;
        final repeatedPixelX = repeatedX ? 65 : 5;
        final repeatedPixelY = repeatedX ? 40 : 45;
        final unpaintedX = repeatedX ? 5 : 65;
        final unpaintedY = repeatedX ? 65 : 5;
        final initial = await _waitForFrame(
          tester,
          find.byKey(boundary),
          firstX,
          firstY,
          _isRed,
        );
        expect(_isRed(initial), isTrue, reason: '${item['id']} first frame');
        expect(
          _isRed(
            await _capturePixel(
              tester,
              find.byKey(boundary),
              repeatedPixelX,
              repeatedPixelY,
            ),
          ),
          isTrue,
          reason: '${item['id']} repeated tile',
        );
        expect(
          _isWhite(
            await _capturePixel(
              tester,
              find.byKey(boundary),
              unpaintedX,
              unpaintedY,
            ),
          ),
          isTrue,
          reason: '${item['id']} does not repeat on the other axis',
        );

        await tester.pump(
          Duration(milliseconds: (item['frameDurationMs'] as num).toInt() + 20),
        );
        final second = await _waitForFrame(
          tester,
          find.byKey(boundary),
          firstX,
          firstY,
          _isBlue,
        );
        expect(_isBlue(second), isTrue, reason: '${item['id']} second frame');
        expect(
          _isBlue(
            await _capturePixel(
              tester,
              find.byKey(boundary),
              repeatedPixelX,
              repeatedPixelY,
            ),
          ),
          isTrue,
          reason: '${item['id']} repeated second frame',
        );

        await _pumpAnimatedHtml(
          tester,
          windows,
          gateway,
          item,
          width: 100,
          height: 60,
        );
        final resizedX = repeatedX ? 65 : 5;
        final resizedY = repeatedX ? 40 : 35;
        expect(
          _isBlue(
            await _capturePixel(
              tester,
              find.byKey(boundary),
              resizedX,
              resizedY,
            ),
          ),
          isTrue,
          reason: '${item['id']} retains its current frame after rebuild',
        );
        if (!repeatedX) {
          expect(
            _isWhite(await _capturePixel(tester, find.byKey(boundary), 55, 35)),
            isTrue,
            reason: '50% 50% resize keeps the 50px tile width',
          );
        }
        expect(gateway.calls.where((call) => call.$1 == 'image'), hasLength(1));
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        windows.dispose();
        await gateway.stream.close();
      },
    );
  }

  testWidgets(
    'an invalidated account stops painting an authenticated raster background',
    (tester) async {
      final item = _animationCases.firstWhere((item) => item['id'] == 'gif');
      final gateway = FakeGateway();
      gateway.handler = (method, args) async => method == 'image'
          ? {
              'bytes': base64Decode(item['base64'] as String),
              'mimeType': item['mimeType'],
            }
          : gateway.normal(method, args);
      var activeAccount = 'account-a';
      final image = NativeDocumentBackgroundImage(
        source: Uri.parse('/account.gif'),
        gateway: gateway,
        accountIdentity: 'account-a',
        owner: gateway,
        isCurrent: () => activeAccount == 'account-a',
      );
      final decoration = NativeHtmlImageBackgroundDecoration(
        BoxDecoration(
          color: Colors.white,
          image: DecorationImage(
            image: image,
            fit: BoxFit.none,
            alignment: Alignment.topLeft,
            repeat: ImageRepeat.noRepeat,
          ),
        ),
        cssSize: '60px auto',
      );
      const boundary = ValueKey('invalidated-background');
      await tester.pumpWidget(_directBackgroundHost(decoration));
      final before = await _waitForFrame(
        tester,
        find.byKey(boundary),
        5,
        5,
        (pixel) => _isRed(pixel) || _isBlue(pixel),
      );
      expect(_isRed(before) || _isBlue(before), isTrue);
      expect(gateway.calls.where((call) => call.$1 == 'image'), hasLength(1));

      activeAccount = 'account-b';
      tester
          .renderObject<RenderDecoratedBox>(find.byType(DecoratedBox).first)
          .markNeedsPaint();
      await tester.pump();
      expect(
        _isWhite(await _capturePixel(tester, find.byKey(boundary), 5, 5)),
        isTrue,
      );
      expect(gateway.calls.where((call) => call.$1 == 'image'), hasLength(1));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await gateway.stream.close();
    },
  );
}
