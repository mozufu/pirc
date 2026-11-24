import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:html/parser.dart' as html;
import 'package:pirc_mobile/live/common.dart';
import 'package:pirc_render/src/html_document_styles.dart';

import 'live_test.dart' show FakeGateway, theme;

final _fixture = Map<String, dynamic>.from(
  jsonDecode(
        File(
          '../../fixtures/mobile-parity/background-layers-expected.json',
        ).readAsStringSync(),
      )
      as Map,
);
final _assets = <String, String>{
  for (final value in _fixture['assets'] as List)
    '${_object(value)['id']}': '${_object(value)['dataUri']}',
};
final _cases = (_fixture['cases'] as List).map(_object).toList();

Map<String, dynamic> _object(Object? value) =>
    Map<String, dynamic>.from(value as Map);

String _cssName(String value) => value.replaceAllMapped(
  RegExp(r'[A-Z]'),
  (match) => '-${match[0]!.toLowerCase()}',
);

String _resolveAssetTokens(String value) {
  var result = value;
  for (final asset in _assets.entries) {
    result = result.replaceAll('<asset:${asset.key}>', asset.value);
  }
  if (result.contains('<asset:')) {
    throw FormatException('Unresolved background fixture asset: $result');
  }
  return result;
}

String _renderableMarkup(
  Map<String, dynamic> testCase, {
  required bool normalize,
  required Map<String, String> declarations,
}) {
  final document = html.parse('<div id="target"></div>');
  final element = document.querySelector('#target')!;
  final dimensions = _object(testCase['element']);
  final css = <String>[
    'width:${(dimensions['width'] as num).toInt()}px',
    'height:${(dimensions['height'] as num).toInt()}px',
    for (final entry in declarations.entries)
      '${entry.key}:${_resolveAssetTokens(entry.value)}',
  ];
  element.attributes['style'] = css.join(';');

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
    (testCase['pixelSamples'] as List)
        .map((value) => Map<String, dynamic>.from(value as Map))
        .toList();

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
    final rgba = <List<int>>[
      for (final sample in expected)
        (() {
          final x = (sample['x'] as num).toInt();
          final y = (sample['y'] as num).toInt();
          final offset = (y * image.width + x) * 4;
          return bytes.sublist(offset, offset + 4);
        })(),
    ];
    return (width: image.width, height: image.height, rgba: rgba);
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
        .map((v) => v.toInt())
        .toList();
    final got = actual[index];
    final x = item['x'], y = item['y'];
    for (var channel = 0; channel < 4; channel++) {
      final delta = (want[channel] - got[channel]).abs();
      if (delta > 3) {
        mismatches.add(
          '($x,$y) channel $channel expected ${want[channel]}, got ${got[channel]} (Δ$delta)',
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

Future<void> _pumpHtml(
  WidgetTester tester,
  String markup,
  FakeGateway gateway,
) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: theme.build(Brightness.light),
      home: Scaffold(
        body: RepaintBoundary(
          key: const ValueKey('background-layers'),
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

void main() {
  for (final testCase in _cases) {
    final css = _object(
      testCase['authoredCss'],
    ).map((key, value) => MapEntry(_cssName(key), '$value'));
    final expected = _samples(testCase);
    testWidgets('Chrome background layers ${testCase['id']} normalized=false', (
      tester,
    ) async {
      final gateway = FakeGateway();
      await _pumpHtml(
        tester,
        _renderableMarkup(testCase, normalize: false, declarations: css),
        gateway,
      );
      // Compare all 81 fixture points, including x=0/119 and y=0/79.
      // No edge samples are omitted; the 3-channel allowance covers renderer
      // rounding at those exact sampled boundaries.
      final actual = await _captureUntilStable(
        tester,
        find.byKey(const ValueKey('background-layers')),
        expected,
      );
      expect((actual.width, actual.height), (120, 80));
      expect(
        _mismatches(expected, actual.rgba),
        isEmpty,
        reason: '${testCase['id']} raw CSS pixel samples',
      );
      expect(tester.takeException(), isNull);
      expect(gateway.calls.where((call) => call.$1 == 'image'), isEmpty);
      await tester.pumpWidget(const SizedBox());
      await gateway.stream.close();
    });
    testWidgets('Chrome background layers ${testCase['id']} normalized=true', (
      tester,
    ) async {
      final gateway = FakeGateway();
      await _pumpHtml(
        tester,
        _renderableMarkup(testCase, normalize: true, declarations: css),
        gateway,
      );
      final actual = await _captureUntilStable(
        tester,
        find.byKey(const ValueKey('background-layers')),
        expected,
      );
      expect((actual.width, actual.height), (120, 80));
      expect(
        _mismatches(expected, actual.rgba),
        isEmpty,
        reason: '${testCase['id']} normalized CSS pixel samples',
      );
      expect(tester.takeException(), isNull);
      expect(gateway.calls.where((call) => call.$1 == 'image'), isEmpty);
      await tester.pumpWidget(const SizedBox());
      await gateway.stream.close();
    });
  }

  for (final normalize in [false, true]) {
    testWidgets(
      'a failed top image layer preserves the gradient, base color and foreground normalized=$normalize',
      (tester) async {
        final gateway = FakeGateway();
        const markupCss = <String, String>{
          'background-image':
              'url("data:image/png;base64,AA=="), '
              'linear-gradient(to right, '
              'rgba(255,0,0,.5) 0%, rgba(255,0,0,.5) 50%, '
              'transparent 50%, transparent 100%)',
          'background-color': '#00ff00',
        };
        final html = _renderableMarkup(
          {
            'element': {'width': 120, 'height': 80},
          },
          normalize: normalize,
          declarations: markupCss,
        ).replaceFirst('</div>', 'OK</div>');
        await _pumpHtml(tester, html, gateway);

        final key = find.byKey(const ValueKey('background-layers'));
        List<List<int>> pixels = [];
        for (var attempt = 0; attempt < 30; attempt++) {
          if (attempt > 0) {
            await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 10)),
            );
            await tester.pump();
          }
          final sampled = (await tester.runAsync(
            () => _captureSamples(tester, key, const [
              {
                'x': 20,
                'y': 40,
                'rgba': [128, 127, 0, 255],
              },
              {
                'x': 100,
                'y': 40,
                'rgba': [0, 255, 0, 255],
              },
            ]),
          ))!;
          pixels = sampled.rgba;
          if (_mismatches(const [
            {
              'x': 20,
              'y': 40,
              'rgba': [128, 127, 0, 255],
            },
            {
              'x': 100,
              'y': 40,
              'rgba': [0, 255, 0, 255],
            },
          ], pixels).isEmpty) {
            break;
          }
        }
        expect(
          _mismatches(const [
            {
              'x': 20,
              'y': 40,
              'rgba': [128, 127, 0, 255],
            },
            {
              'x': 100,
              'y': 40,
              'rgba': [0, 255, 0, 255],
            },
          ], pixels),
          isEmpty,
        );
        expect(find.textContaining('OK', findRichText: true), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        await gateway.stream.close();
      },
    );

    testWidgets(
      'a later background reset clears an earlier image but keeps color and foreground normalized=$normalize',
      (tester) async {
        final gateway = FakeGateway();
        final markup = _renderableMarkup(
          {
            'element': {'width': 120, 'height': 80},
          },
          normalize: normalize,
          declarations: {
            'background-image': 'url("${_assets['png-overlay']}")',
            'background-color': '#ff0000',
            'background': 'none #ffff00',
          },
        ).replaceFirst('</div>', 'OK</div>');
        await _pumpHtml(tester, markup, gateway);

        final expected = const [
          {
            'x': 10,
            'y': 70,
            'rgba': [255, 255, 0, 255],
          },
          {
            'x': 60,
            'y': 40,
            'rgba': [255, 255, 0, 255],
          },
          {
            'x': 110,
            'y': 70,
            'rgba': [255, 255, 0, 255],
          },
        ];
        final actual = await _captureUntilStable(
          tester,
          find.byKey(const ValueKey('background-layers')),
          expected,
        );
        expect(
          _mismatches(expected, actual.rgba),
          isEmpty,
          reason: 'background:none must reset the preceding image layer',
        );
        expect(find.textContaining('OK', findRichText: true), findsOneWidget);
        expect(tester.takeException(), isNull);
        expect(gateway.calls.where((call) => call.$1 == 'image'), isEmpty);
        await tester.pumpWidget(const SizedBox());
        await gateway.stream.close();
      },
    );
  }
}
