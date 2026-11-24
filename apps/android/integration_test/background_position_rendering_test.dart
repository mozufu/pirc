import 'package:pirc_render/src/remote_content_gate.dart';
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:html/parser.dart' as html;
import 'package:pirc_mobile/live/common.dart';
import 'package:pirc_render/src/html_document_styles.dart';

import 'package:integration_test/integration_test.dart';
import 'package:pirc_mobile/live/gateway.dart';
import 'package:pirc_mobile/theme.dart';
import 'background_position_cases.dart';

late PircTheme theme;
Brightness _brightness = Brightness.light;

final _positionFixture = Map<String, dynamic>.from(
  jsonDecode(backgroundPositionCasesJson) as Map,
);
final _positionCases = (_positionFixture['cases'] as List)
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
  Gateway gateway,
) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: theme.build(_brightness),
      home: Scaffold(
        body: RepaintBoundary(
          key: const ValueKey('background-position'),
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
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  // These suites exercise the image/media loaders themselves, not the hold-back.
  setUpAll(() => NativeRemoteContentPolicy.debugOpenForTests = true);
  tearDownAll(() => NativeRemoteContentPolicy.debugOpenForTests = false);
  setUpAll(() async {
    theme = await PircTheme.load();
    expect(_positionCases, hasLength(17));
  });
  for (final testCase in _positionCases) {
    final declarations = _object(
      testCase['authoredCss'],
    ).map((key, value) => MapEntry(_cssName(key), '$value'));
    final expected = _samples(testCase);
    for (final brightness in Brightness.values) {
      const normalize = true;
      testWidgets(
        'Android Chrome background position ${testCase['id']} in ${brightness.name}',
        (tester) async {
          _brightness = brightness;
          final gateway = Gateway();
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
            find.byKey(const ValueKey('background-position')),
            expected,
          );
          expect((actual.width, actual.height), (120, 80));
          expect(
            _mismatches(expected, actual.rgba),
            isEmpty,
            reason: '${testCase['id']} Chrome pixel samples',
          );
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox());
          debugPrint(
            'BACKGROUND_POSITION_ANDROID:${testCase['id']}:${brightness.name}:$backgroundPositionFixtureSha256',
          );
        },
      );
    }
  }
}
