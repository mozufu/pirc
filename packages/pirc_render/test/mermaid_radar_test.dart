import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_render/src/mermaid/radar_parser.dart';
import 'package:pirc_render/src/mermaid/radar_rendering.dart';

Map<String, dynamic> _readJson(String path) =>
    jsonDecode(File(path).readAsStringSync()) as Map<String, dynamic>;

Map<String, dynamic> _webCapture(String id, String colorScheme) {
  final fixture = _readJson(
    '../../fixtures/mobile-parity/mermaid-important-web.json',
  );
  final captures = fixture['captures'] as List<dynamic>;
  return captures.cast<Map<String, dynamic>>().singleWhere(
    (item) =>
        item['id'] == id &&
        item['colorScheme'] == colorScheme &&
        item['width'] == 390,
  );
}

void main() {
  final oracle = _readJson(
    '../../fixtures/mobile-parity/mermaid-radar-oracle.json',
  );
  final cases = (oracle['cases'] as List<dynamic>).cast<Map<String, dynamic>>();

  group('parseNativeMermaidRadar', () {
    test('matches the pinned Mermaid DB for axes, curves and options', () {
      for (final testCase in cases) {
        final expected = testCase['expected'] as Map<String, dynamic>;
        final chart = parseNativeMermaidRadar(testCase['source'] as String);
        expect(
          chart.title,
          expected['title'],
          reason: testCase['id'] as String,
        );
        expect(chart.axes.map((axis) => axis.name).toList(), [
          for (final axis in expected['axes'] as List<dynamic>)
            (axis as Map<String, dynamic>)['name'],
        ]);
        expect(chart.axes.map((axis) => axis.label).toList(), [
          for (final axis in expected['axes'] as List<dynamic>)
            (axis as Map<String, dynamic>)['label'],
        ]);
        expect(chart.curves.map((curve) => curve.name).toList(), [
          for (final curve in expected['curves'] as List<dynamic>)
            (curve as Map<String, dynamic>)['name'],
        ]);
        expect(chart.curves.map((curve) => curve.label).toList(), [
          for (final curve in expected['curves'] as List<dynamic>)
            (curve as Map<String, dynamic>)['label'],
        ]);
        for (var i = 0; i < chart.curves.length; i++) {
          expect(
            chart.curves[i].entries,
            (expected['curves'][i]['entries'] as List<dynamic>)
                .map((value) => (value as num).toDouble())
                .toList(),
            reason: '${testCase['id']} curve $i',
          );
        }
        final expectedOptions = expected['options'] as Map<String, dynamic>;
        expect(chart.options.showLegend, expectedOptions['showLegend']);
        expect(chart.options.ticks, expectedOptions['ticks']);
        expect(chart.options.max, (expectedOptions['max'] as num?)?.toDouble());
        expect(chart.options.min, (expectedOptions['min'] as num).toDouble());
        expect(chart.options.graticule.name, expectedOptions['graticule']);
        final expectedConfig = expected['config'] as Map<String, dynamic>;
        expect(chart.config.width, (expectedConfig['width'] as num).toDouble());
        expect(
          chart.config.height,
          (expectedConfig['height'] as num).toDouble(),
        );
        expect(
          chart.config.marginTop,
          (expectedConfig['marginTop'] as num).toDouble(),
        );
        expect(
          chart.config.marginRight,
          (expectedConfig['marginRight'] as num).toDouble(),
        );
        expect(
          chart.config.marginBottom,
          (expectedConfig['marginBottom'] as num).toDouble(),
        );
        expect(
          chart.config.marginLeft,
          (expectedConfig['marginLeft'] as num).toDouble(),
        );
        expect(
          chart.config.axisScaleFactor,
          (expectedConfig['axisScaleFactor'] as num).toDouble(),
        );
        expect(
          chart.config.axisLabelFactor,
          (expectedConfig['axisLabelFactor'] as num).toDouble(),
        );
        expect(
          chart.config.curveTension,
          (expectedConfig['curveTension'] as num).toDouble(),
        );
        expect(chart.config.useMaxWidth, expectedConfig['useMaxWidth']);
      }
    });

    test(
      'preserves title, accessibility text, and all values in semantics',
      () {
        final chart = parseNativeMermaidRadar('''
radar-beta
title "Product profile"
accTitle: Accessible radar
accDescr: Three attribute comparison
axis reach["Market reach"]
axis ease["Ease of use"]
axis cost["Build cost"]
curve prototype{8, 7, 3}
''');

        expect(chart.title, 'Product profile');
        expect(chart.accessibleTitle, 'Accessible radar');
        expect(chart.accessibleDescription, 'Three attribute comparison');
        expect(chart.semanticsLabel, contains('Product profile'));
        expect(chart.semanticsLabel, contains('Market reach 8'));
        expect(chart.semanticsLabel, contains('Ease of use 7'));
        expect(chart.semanticsLabel, contains('Build cost 3'));
        final unquotedTitle = parseNativeMermaidRadar('''
radar-beta
title Profile for this team
axis a["A"]
axis b["B"]
axis c["C"]
curve series{1, 2, 3}
''');
        expect(unquotedTitle.title, 'Profile for this team');
      },
    );

    test('supports positional values, defaults and radar init sizing', () {
      final chart = parseNativeMermaidRadar('''
%%{init: {"radar":{"width":480,"height":420,"marginLeft":30}}}%%
radar-beta
axis a["A"]
axis b["B"]
axis c["C"]
curve Default{1, 2, 3}
''');

      expect(chart.curves.single.entries, [1, 2, 3]);
      expect(chart.options.showLegend, isTrue);
      expect(chart.options.ticks, 5);
      expect(chart.options.max, isNull);
      expect(chart.config.width, 480);
      expect(chart.config.height, 420);
      expect(chart.config.marginLeft, 30);
    });

    test(
      'rejects malformed data and unsupported config instead of dropping it',
      () {
        const header = '''
radar-beta
axis a["A"]
axis b["B"]
axis c["C"]
''';
        expect(
          () => parseNativeMermaidRadar('''
%%{init: {"radar":{"unknown":1}}}%%
$header
curve C{1, 2, 3}
'''),
          throwsA(
            isA<FormatException>().having(
              (error) => error.message,
              'message',
              contains('Unsupported radar init option'),
            ),
          ),
        );
        expect(
          () => parseNativeMermaidRadar(
            '$header\ncurve C{a: 1, b: 2, missing: 3}',
          ),
          throwsA(isA<FormatException>()),
        );
        expect(
          () => parseNativeMermaidRadar('$header\ncurve C{1, 2}'),
          throwsA(
            isA<FormatException>().having(
              (error) => error.message,
              'message',
              contains('values for 3 axes'),
            ),
          ),
        );
        expect(
          () => parseNativeMermaidRadar('$header\ncurve C{1, 2, 3}\nmax 0'),
          throwsA(isA<FormatException>()),
        );
      },
    );

    test('enforces bounded input and chart counts', () {
      final comments = List.filled(1201, '%% comment').join('\n');
      expect(
        () => parseNativeMermaidRadar('radar-beta\n$comments'),
        throwsA(isA<FormatException>()),
      );
      final tooManyAxes = [
        'radar-beta',
        for (var i = 0; i < 25; i++) 'axis a$i["Axis $i"]',
      ].join('\n');
      expect(
        () => parseNativeMermaidRadar(tooManyAxes),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            contains('at most 24 axes'),
          ),
        ),
      );
    });
  });

  group('layoutNativeMermaidRadar', () {
    test(
      'matches the pinned SVG viewBox, axes, rings, points and curve tension',
      () {
        final capture = _webCapture('radar-comparison', 'light');
        final chart = parseNativeMermaidRadar(capture['source'] as String);
        final layout = layoutNativeMermaidRadar(
          chart,
          width: ((capture['box'] as Map<String, dynamic>)['width'] as num)
              .toDouble(),
          dark: false,
        );

        expect(layout.viewBoxSize, const Size(700, 700));
        expect(layout.size, const Size(332, 332));
        expect(layout.scale, closeTo(332 / 700, .000001));
        expect(layout.center, const Offset(350, 350));
        expect(layout.radius, 300);
        expect(layout.axes.map((axis) => axis.axis.label), [
          'Focus',
          'Clarity',
          'Speed',
        ]);
        expect(layout.seriesPoints, hasLength(2));
        expect(layout.seriesPoints.first, hasLength(3));
        expect(layout.seriesPoints.first[0].dx, closeTo(0, .000001));
        expect(
          layout.seriesPoints.first[0].dy,
          closeTo(-233.3333333333, .000001),
        );
        expect(layout.seriesPoints.first[1].dx, closeTo(144.3375673, .000001));
        expect(layout.seriesPoints.first[1].dy, closeTo(83.3333333, .000001));
        expect(
          layout.curves.first.segments.first.control1.dx,
          closeTo(63.7972047, .000001),
        );
        expect(
          layout.curves.first.segments.first.control1.dy,
          closeTo(-241.8333333, .000001),
        );
        expect(layout.graticule.map((ring) => ring.radius), [
          60,
          120,
          180,
          240,
          300,
        ]);

        final capturedAxisLabels = (capture['labels'] as List<dynamic>)
            .cast<Map<String, dynamic>>()
            .where((label) => label['class'] == 'radarAxisLabel')
            .toList();
        for (var i = 0; i < capturedAxisLabels.length; i++) {
          final attributes =
              capturedAxisLabels[i]['attributes'] as Map<String, dynamic>;
          expect(
            layout.axes[i].labelPosition.dx,
            closeTo(double.parse(attributes['x'] as String), .000001),
          );
          expect(
            layout.axes[i].labelPosition.dy,
            closeTo(double.parse(attributes['y'] as String), .000001),
          );
        }
        expect(layout.legendLabels, ['Current', 'Target']);
        expect(layout.curves.first.color, const Color(0xff74a2f7));
        expect(layout.axisColor, const Color(0xff81858c));
      },
    );

    test(
      'uses polygon graticules, flat closed curves, and showLegend false',
      () {
        final capture = _webCapture('radar-options', 'light');
        final chart = parseNativeMermaidRadar(capture['source'] as String);
        final layout = layoutNativeMermaidRadar(chart, width: 700, dark: false);

        expect(layout.smoothCurves, isFalse);
        expect(layout.graticule.map((ring) => ring.radius), [
          75,
          150,
          225,
          300,
        ]);
        expect(layout.graticule.first.points, hasLength(3));
        expect(layout.graticule.first.points[0].dy, closeTo(-75, .000001));
        expect(layout.legend, isEmpty);
        expect(layout.legendLabels, isEmpty);
        expect(layout.curves.single.points, hasLength(3));
      },
    );

    test('matches responsive dark colors and retains legend labels', () {
      final capture = _webCapture('radar-labels', 'dark');
      final chart = parseNativeMermaidRadar(capture['source'] as String);
      final layout = layoutNativeMermaidRadar(chart, width: 768, dark: true);

      expect(layout.viewBoxSize, const Size(700, 700));
      expect(layout.size, const Size(700, 700));
      expect(layout.legendLabels, ['Fire mage', 'Stone knight']);
      expect(layout.curves.first.color, const Color(0xff1f2020));
      expect(layout.curves[1].color, const Color(0xff0b0000));
      expect(layout.axisColor, const Color(0xffd3d3d3));
      expect(layout.textColor, const Color(0xffcccccc));
    });
  });

  testWidgets(
    'scales to its LayoutBuilder width and exposes all chart semantics',
    (tester) async {
      final chart = parseNativeMermaidRadar('''
radar-beta
title "Product profile"
axis reach["Market reach"]
axis ease["Ease of use"]
axis cost["Build cost"]
curve prototype["Prototype"]{8, 7, 3}
''');
      final semantics = tester.ensureSemantics();
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(390, 900);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 332,
              child: NativeMermaidRadar(diagram: chart, dark: false),
            ),
          ),
        ),
      );

      expect(tester.takeException(), isNull);
      final paint = find.descendant(
        of: find.byType(NativeMermaidRadar),
        matching: find.byType(CustomPaint),
      );
      expect(tester.getSize(paint), const Size(332, 332));
      expect(find.bySemanticsLabel(chart.semanticsLabel), findsOneWidget);
      expect(chart.semanticsLabel, contains('Market reach 8'));
      semantics.dispose();
    },
  );
}
