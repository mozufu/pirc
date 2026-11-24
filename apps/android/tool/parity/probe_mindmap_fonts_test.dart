import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_render/src/mermaid/mindmap_rendering.dart';
import 'package:pirc_render/src/mermaid/mindmap_parser.dart';
import 'package:pirc_render/src/native_markdown.dart';
import 'capture_fonts.dart';
import '../../test/live_test.dart' show theme;
import 'mermaid_font_tracking.dart';

const _outputPath = 'build/parity/mindmap-font-probe-native.json';
const _fixturePath = '../../fixtures/mobile-parity/mermaid-mindmap.json';
const _expectedPath =
    '../../fixtures/mobile-parity/mermaid-mindmap-expected.json';
const _words = ['Planning', 'Prototype', 'root'];
const _variations = <String, double?>{
  'none': null,
  'opsz13': 13,
  'opsz14': 14,
  'opsz17': 17,
  'opsz20': 20,
};

Future<void> _loadFonts(WidgetTester tester) async {
  await tester.runAsync(() async {
    await loadParityFonts();
    await (FontLoader('Mermaid reference')..addFont(
          File(
            '/System/Library/Fonts/SFNS.ttf',
          ).readAsBytes().then(ByteData.sublistView),
        ))
        .load();
  });
}

TextStyle _labelStyle(double? opticalSize) => TextStyle(
  fontFamily: 'Mermaid reference',
  fontSize: 13,
  height: 1.5,
  letterSpacing: 0,
  color: const Color(0xff0f1115),
  fontWeight: FontWeight.w400,
  fontVariations: opticalSize == null
      ? null
      : [FontVariation('opsz', opticalSize)],
);

Map<String, Object?> _metricsForTextPainter(String text, double? opticalSize) {
  final style = _labelStyle(opticalSize);
  final painter = TextPainter(
    text: TextSpan(text: text, style: style),
    textAlign: TextAlign.center,
    textDirection: TextDirection.ltr,
  )..layout(maxWidth: 200);
  final lines = painter.computeLineMetrics();
  final output = <String, Object?>{
    'word': text,
    'variation': opticalSize == null ? 'none' : 'opsz$opticalSize',
    'fontFamily': style.fontFamily,
    'fontSize': style.fontSize,
    'heightMultiplier': style.height,
    'fontWeight': style.fontWeight?.value,
    'opticalSize': opticalSize,
    'textPainter': {
      'width': painter.width,
      'height': painter.height,
      'lineCount': lines.length,
      'lines': [
        for (final line in lines)
          {
            'width': line.width,
            'height': line.height,
            'baseline': line.baseline,
            'ascent': line.ascent,
            'descent': line.descent,
            'unscaledAscent': line.unscaledAscent,
          },
      ],
    },
  };
  painter.dispose();
  return output;
}

void main() {
  final actualRows = <Map<String, Object?>>[];
  final variationRows = <Map<String, Object?>>[];
  final sourceCorpusRows = <Map<String, Object?>>[];
  final shapeBoundsRows = <Map<String, Object?>>[];
  SfntFontTracking? trackingTable;
  double? tracking13Px;

  tearDownAll(() {
    Directory('build/parity').createSync(recursive: true);
    File(_outputPath).writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert({
        'browserReference': {
          'fontFamily': '-apple-system, "system-ui", "Segoe UI", sans-serif',
          'fontSize': 13,
          'lineHeight': 19.5,
          'source':
              'Actual pinned Chrome geometryCatalog from the 6-case Web oracle.',
        },
        'hostFont': {
          'familyAlias': 'Mermaid reference',
          'fontFile': '/System/Library/Fonts/SFNS.ttf',
          'fontSize': 13,
          'heightMultiplier': 1.5,
          'devicePixelRatio': 1,
        },
        'fontTracking': trackingTable == null
            ? null
            : {
                'sfntVersion': trackingTable!.version,
                'trakFormat': trackingTable!.format,
                'horizontalOffset': trackingTable!.horizontalOffset,
                'verticalOffset': trackingTable!.verticalOffset,
                'unitsPerEm': trackingTable!.unitsPerEm,
                'normalTrack': 0,
                'sampledSizeValues': trackingTable!.sizes,
                'normal13AdjustmentFontUnits': trackingTable!.adjustmentAt(13),
                'normal13LetterSpacingPx': tracking13Px,
                'formula': '13 * adjustmentFontUnits / unitsPerEm',
                'source':
                    '/System/Library/Fonts/SFNS.ttf head+horizontal trak tables',
              },
        'actualNativeMarkdownLabels': actualRows,
        'opticalSizeProbe': variationRows,
        'sourceCorpusGlyphWidths': sourceCorpusRows,
        'sourceShapeBounds': shapeBoundsRows,
        'limitations': [
          'SFNS and Arial aliases are loaded from the macOS host for comparison; this does not establish Android system-font metrics.',
          'Web reference comes from the pinned host browser output; CSS -apple-system does not identify a bundled font asset.',
          'Flutter RenderParagraph exposes its actual size and alphabetic baseline but not public line metrics. Per-line ascent/descent/height are measured with TextPainter using the same RichText span, scaler, direction, locale, and width.',
        ],
      }),
    );
  });

  testWidgets('mindmap host font metrics and optical-size variations', (
    tester,
  ) async {
    await _loadFonts(tester);
    final sfnt = (await tester.runAsync(
      () => SfntFontTracking.readFile(File('/System/Library/Fonts/SFNS.ttf')),
    ))!;
    trackingTable = sfnt;
    tracking13Px = sfnt.letterSpacing(13);
    expect(sfnt.unitsPerEm, 2048);
    expect(sfnt.format, 0);
    expect(sfnt.horizontalOffset, 12);
    expect(sfnt.verticalOffset, 0);
    expect(sfnt.adjustmentAt(13), -12);
    expect(tracking13Px, closeTo(-0.076171875, 1e-12));

    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 900);
    tester.platformDispatcher.textScaleFactorTestValue = 1;
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

    final baselineSources = <String, String>{
      'root': '~~~mermaid\nmindmap\nroot\n~~~',
      'Planning': '~~~mermaid\nmindmap\nroot((Planning))\n~~~',
      'Prototype': '~~~mermaid\nmindmap\nroot((Planning))\n  Prototype\n~~~',
    };
    final initialTheme = theme.build(Brightness.light);
    final baseTheme = initialTheme.copyWith(
      textTheme: initialTheme.textTheme.apply(fontFamily: 'Arial'),
    );
    for (final entry in baselineSources.entries) {
      await tester.pumpWidget(
        MaterialApp(
          theme: baseTheme.copyWith(
            textTheme: baseTheme.textTheme.copyWith(
              bodyMedium: baseTheme.textTheme.bodyMedium?.copyWith(
                fontFamily: 'Mermaid reference',
              ),
            ),
          ),
          home: Scaffold(
            body: Padding(
              padding: const EdgeInsets.all(16),
              child: NativeMarkdown(source: entry.value),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: entry.key);
      expect(find.byType(NativeMermaidMindmap), findsOneWidget);
      final finder = find.descendant(
        of: find.byType(NativeMermaidMindmap),
        matching: find.byType(RichText),
      );
      final widgets = tester.widgetList<RichText>(finder).toList();
      final targetIndex = widgets.indexWhere(
        (widget) => widget.text.toPlainText() == entry.key,
      );
      expect(targetIndex, isNonNegative, reason: entry.key);
      final widget = widgets[targetIndex];
      final render = tester.renderObject<RenderParagraph>(
        finder.at(targetIndex),
      );
      final width = render.size.width;
      final painter = TextPainter(
        text: widget.text,
        textAlign: widget.textAlign,
        textDirection: widget.textDirection,
        textScaler: widget.textScaler,
        locale: widget.locale,
        maxLines: widget.maxLines,
        strutStyle: widget.strutStyle,
        textWidthBasis: widget.textWidthBasis,
        textHeightBehavior: widget.textHeightBehavior,
      )..layout(maxWidth: width);
      actualRows.add({
        'word': entry.key,
        'renderParagraph': {
          'width': render.size.width,
          'height': render.size.height,
          'alphabeticBaseline': render.getDryBaseline(
            render.constraints,
            TextBaseline.alphabetic,
          ),
          'fontFamily': (widget.text as TextSpan).style?.fontFamily,
          'fontSize': (widget.text as TextSpan).style?.fontSize,
          'heightMultiplier': (widget.text as TextSpan).style?.height,
          'fontVariations': (widget.text as TextSpan).style?.fontVariations
              ?.map(
                (variation) => {
                  'axis': variation.axis,
                  'value': variation.value,
                },
              )
              .toList(),
        },
        'sameSpanTextPainter': {
          'lineCount': painter.computeLineMetrics().length,
          'lines': [
            for (final line in painter.computeLineMetrics())
              {
                'width': line.width,
                'height': line.height,
                'baseline': line.baseline,
                'ascent': line.ascent,
                'descent': line.descent,
                'unscaledAscent': line.unscaledAscent,
              },
          ],
        },
      });
      painter.dispose();
    }

    for (final word in _words) {
      for (final entry in _variations.entries) {
        final output = _metricsForTextPainter(word, entry.value);
        variationRows.add(output);
        final style = _labelStyle(entry.value);
        await tester.pumpWidget(
          MaterialApp(
            theme: baseTheme,
            home: Scaffold(
              body: Center(
                child: RichText(
                  text: TextSpan(text: word, style: style),
                  textAlign: TextAlign.center,
                  textDirection: TextDirection.ltr,
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final render = tester.renderObject<RenderParagraph>(
          find.byType(RichText),
        );
        final row = output;
        row['renderParagraph'] = {
          'width': render.size.width,
          'height': render.size.height,
          'alphabeticBaseline': render.getDryBaseline(
            render.constraints,
            TextBaseline.alphabetic,
          ),
        };
      }
    }

    final fixture = jsonDecode(File(_fixturePath).readAsStringSync()) as Map;
    final expected = jsonDecode(File(_expectedPath).readAsStringSync()) as Map;
    final cases = fixture['cases'] as List;
    final parsedCases = expected['parsedCases'] as Map;
    final geometryCatalog = expected['geometryCatalog'] as Map;
    for (final caseValue in cases) {
      final item = caseValue as Map;
      final caseId = item['id'] as String;
      final parsed = (parsedCases[caseId] as Map)['light'] as Map;
      if (parsed['status'] != 'ok') {
        sourceCorpusRows.add({
          'caseId': caseId,
          'webStatus': parsed['status'],
          'webErrorText': parsed['errorText'],
          'renderedLabelCount': 0,
          'note':
              'The pinned source case has no rendered SVG labels to compare.',
        });
        continue;
      }

      final geometryEntry = geometryCatalog['$caseId-light'] as Map;
      final shared = geometryEntry['shared'] as Map;
      final browserNodes = shared['nodes'] as List;
      final api = parsed['api'] as Map;
      final browserApiNodes = api['nodes'] as List;
      final fontSize = double.parse(
        ((shared['computed'] as Map)['fontSize'] as String).replaceFirst(
          'px',
          '',
        ),
      );
      final lineHeight = double.parse(
        ((shared['computed'] as Map)['lineHeight'] as String).replaceFirst(
          'px',
          '',
        ),
      );
      final maxNodeWidth =
          ((api['config'] as Map)['mindmap'] as Map)['maxNodeWidth'] as num;
      final labelRows = <Map<String, Object?>>[];
      for (var index = 0; index < browserNodes.length; index++) {
        final node = browserNodes[index] as Map;
        final apiNode = browserApiNodes[index] as Map;
        final label = node['label'] as String;
        expect(apiNode['label'], label, reason: '$caseId node $index');
        final browserParagraph = (node['htmlLabels'] as List)
            .map((entry) => entry as Map)
            .singleWhere((entry) => entry['tag'] == 'p');
        final browserBox = browserParagraph['relativeBox'] as Map;
        final browserWidth = (browserBox['width'] as num).toDouble();
        final browserHeight = (browserBox['height'] as num).toDouble();
        final style = TextStyle(
          fontFamily: 'Mermaid reference',
          fontSize: fontSize,
          height: lineHeight / fontSize,
          letterSpacing: tracking13Px,
          color: const Color(0xff0f1115),
          fontWeight: FontWeight.w400,
          fontVariations: const [FontVariation('opsz', 13)],
        );
        final untrackedPainter = TextPainter(
          text: TextSpan(text: label, style: style.copyWith(letterSpacing: 0)),
          textAlign: TextAlign.center,
          textDirection: TextDirection.ltr,
        )..layout(maxWidth: maxNodeWidth.toDouble());
        final painter = TextPainter(
          text: TextSpan(text: label, style: style),
          textAlign: TextAlign.center,
          textDirection: TextDirection.ltr,
        )..layout(maxWidth: maxNodeWidth.toDouble());
        final lines = painter.computeLineMetrics();
        final quantizedNativeWidth = (painter.width * 64).round() / 64;
        final ceilNativeWidth = (painter.width * 64).ceil() / 64;
        final quantizedBrowserWidth = (browserWidth * 64).round() / 64;
        labelRows.add({
          'nodeId': node['id'],
          'label': label,
          'font': {
            'familyAlias': style.fontFamily,
            'size': style.fontSize,
            'lineHeight': lineHeight,
            'letterSpacing': tracking13Px,
            'fontVariation': 'opsz=13',
          },
          'browser': {
            'width': browserWidth,
            'widthRoundedTo64th': quantizedBrowserWidth,
            'height': browserHeight,
            'lineCount': (browserHeight / lineHeight).round(),
            'computed': browserParagraph['computed'],
          },
          'native': {
            'untrackedTextPainterWidth': untrackedPainter.width,
            'textPainterWidth': painter.width,
            'trackingWidthDelta': painter.width - untrackedPainter.width,
            'widthRoundedTo64th': quantizedNativeWidth,
            'widthCeiledTo64th': ceilNativeWidth,
            'height': painter.height,
            'lineCount': lines.length,
            'lineWidths': [for (final line in lines) line.width],
            'widthDeltaAfter64thRounding':
                quantizedNativeWidth - quantizedBrowserWidth,
            'widthDeltaAfter64thCeiling': ceilNativeWidth - browserWidth,
            'ceilMatchesBrowserQuantizedWidth':
                ceilNativeWidth == quantizedBrowserWidth,
            'lineCountMatches':
                lines.length == (browserHeight / lineHeight).round(),
          },
        });
        untrackedPainter.dispose();
        painter.dispose();
      }
      sourceCorpusRows.add({
        'caseId': caseId,
        'webStatus': parsed['status'],
        'source': (item['source'] as String),
        'geometryId': geometryEntry['caseId'] == caseId
            ? '$caseId-light'
            : null,
        'normal13LetterSpacingPx': tracking13Px,
        'maxNodeWidth': maxNodeWidth,
        'labels': labelRows,
        'summary': {
          'labelCount': labelRows.length,
          'roundedWidthMismatches': labelRows
              .where(
                (row) =>
                    ((row['native'] as Map)['widthDeltaAfter64thRounding']
                        as num) !=
                    0,
              )
              .length,
          'lineCountMismatches': labelRows
              .where(
                (row) => !((row['native'] as Map)['lineCountMatches'] as bool),
              )
              .length,
          'ceilWidthMismatches': labelRows
              .where(
                (row) =>
                    !((row['native'] as Map)['ceilMatchesBrowserQuantizedWidth']
                        as bool),
              )
              .length,
        },
      });

      final mermaidSource = (item['source'] as String)
          .replaceFirst(RegExp(r'^~~~mermaid\s*'), '')
          .replaceFirst(RegExp(r'\s*~~~$'), '');
      final nativeDiagram = parseNativeMermaidMindmap(mermaidSource);
      final nativeLayout = layoutNativeMermaidMindmap(
        nativeDiagram,
        width: 390,
        dark: false,
        fontFamily: 'Mermaid reference',
        letterSpacing: tracking13Px!,
      );
      expect(nativeLayout.nodes.length, browserNodes.length, reason: caseId);
      final shapes = <Map<String, Object?>>[];
      for (var index = 0; index < nativeLayout.nodes.length; index++) {
        final nativeNode = nativeLayout.nodes[index];
        final browserNode = browserNodes[index] as Map;
        final labelMeasurement = labelRows[index]['native'] as Map;
        labelMeasurement['nativeLayoutWidth'] = nativeNode.labelSize.width;
        labelMeasurement['nativeLayoutWidthDeltaFromWeb'] =
            nativeNode.labelSize.width -
            (((browserNode['htmlLabels'] as List)
                            .map((entry) => entry as Map)
                            .singleWhere(
                              (entry) => entry['tag'] == 'p',
                            )['relativeBox']
                        as Map)['width']
                    as num)
                .toDouble();
        expect(nativeNode.label.toPlainText(), browserNode['label']);
        final browserShapes = (browserNode['shapes'] as List)
            .map((shape) => shape as Map)
            .where((shape) => (shape['userBBox'] as Map)['width'] != 0)
            .toList();
        final sourceShape = browserShapes.first;
        final sourceBox = browserNode['userBBox'] as Map;
        final nativePathBox = nativeNode.path.getBounds();
        final nativeLocalBox = nativeNode.localBounds;
        shapes.add({
          'label': nativeNode.label.toPlainText(),
          'shapeTag': sourceShape['tag'],
          'sourceNodeBounds': sourceBox,
          'nativeRawPathBoundsConservative': {
            'left': nativePathBox.left,
            'top': nativePathBox.top,
            'width': nativePathBox.width,
            'height': nativePathBox.height,
          },
          'nativeLocalBoundsIncludingLabel': {
            'left': nativeLocalBox.left,
            'top': nativeLocalBox.top,
            'width': nativeLocalBox.width,
            'height': nativeLocalBox.height,
          },
          'nodeBoundsDelta': {
            'left': nativeLocalBox.left - (sourceBox['x'] as num).toDouble(),
            'top': nativeLocalBox.top - (sourceBox['y'] as num).toDouble(),
            'width':
                nativeLocalBox.width - (sourceBox['width'] as num).toDouble(),
            'height':
                nativeLocalBox.height - (sourceBox['height'] as num).toDouble(),
          },
        });
      }
      shapeBoundsRows.add({
        'caseId': caseId,
        'layoutWidth': 390,
        'fontFamily': 'Mermaid reference',
        'letterSpacing': tracking13Px,
        'shapes': shapes,
      });
    }
  });
}
