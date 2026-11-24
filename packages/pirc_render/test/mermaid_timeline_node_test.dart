import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_render/src/mermaid/timeline_node.dart';

void main() {
  TextStyle ahem(double size) => TextStyle(
    fontFamily: 'Ahem',
    fontSize: size,
    height: 1.65,
    color: Colors.black,
  );

  testWidgets('wrap keeps source whitespace and SVG rendered text separately', (
    tester,
  ) async {
    final result = layoutNativeTimelineNode(
      descr: 'AA BB CC',
      width: 55,
      padding: 5,
      maxHeight: 0,
      configFontSize: 16,
      textStyle: ahem(10),
      sectionDepth: 0,
    );

    expect(result.lines.map((line) => line.rawText), ['AA   BB', 'CC']);
    expect(result.lines.map((line) => line.paintText), ['AA BB', 'CC']);
    expect(result.lines.first.dy, 10);
    expect(result.lines.last.dy, 11);
    expect(result.lines.first.baseline, 12.5);
    expect(result.lines.last.baseline - result.lines.first.baseline, 11);
    expect(result.textBounds.height, greaterThan(0));
    expect(
      result.virtualHeight,
      closeTo(result.textBounds.height + 13.8, 1e-9),
    );
  });

  testWidgets('explicit br follows the pinned tspan behavior', (tester) async {
    final middleBreak = layoutNativeTimelineNode(
      descr: 'one<br>two',
      width: 200,
      padding: 4,
      maxHeight: 0,
      configFontSize: 16,
      textStyle: ahem(10),
      sectionDepth: 1,
    );
    expect(middleBreak.lines.map((line) => line.rawText), ['one', 'two']);

    // The upstream wrapper creates a literal `<br>` tspan at the end of its
    // loop and has no later token to overwrite it.
    final terminalBreak = layoutNativeTimelineNode(
      descr: 'one<br>',
      width: 200,
      padding: 4,
      maxHeight: 0,
      configFontSize: 16,
      textStyle: ahem(10),
      sectionDepth: 1,
    );
    expect(terminalBreak.lines.map((line) => line.rawText), ['one', '<br>']);
  });

  testWidgets('long tokens are moved intact and may overflow text width', (
    tester,
  ) async {
    final result = layoutNativeTimelineNode(
      descr: 'EXTRALONGTOKEN',
      width: 25,
      padding: 5,
      maxHeight: 0,
      configFontSize: 16,
      textStyle: ahem(10),
      sectionDepth: 1,
    );

    expect(result.lines.map((line) => line.rawText), ['', 'EXTRALONGTOKEN']);
    expect(result.lines.last.width, greaterThan(25));
    expect(result.width, 35);
  });

  testWidgets('source maxHeight, section style, and node paths are preserved', (
    tester,
  ) async {
    final classic = layoutNativeTimelineNode(
      descr: 'Node',
      width: 100,
      padding: 6,
      maxHeight: 48,
      configFontSize: 16,
      textStyle: ahem(10),
      sectionDepth: 13,
      maxSections: 12,
    );
    expect(classic.sectionIndex, 0);
    expect(classic.width, 112);
    expect(classic.height, 48);
    expect(classic.localBounds, const Rect.fromLTWH(0, 0, 112, 48));
    expect(classic.textTransform, const Offset(56, 3));
    expect(classic.backgroundPath.getBounds(), classic.localBounds);
    expect(
      classic.bottomRulePath!.getBounds(),
      const Rect.fromLTWH(0, 48, 112, 0),
    );

    final redux = layoutNativeTimelineNode(
      descr: 'Event',
      width: 100,
      padding: 6,
      maxHeight: 48,
      configFontSize: 16,
      textStyle: ahem(10),
      sectionDepth: 12,
      reduxTheme: true,
      isEvent: true,
    );
    expect(redux.sectionIndex, -1);
    expect(redux.textTransform, const Offset(56, 6));
    expect(redux.bottomRulePath, isNull);
    expect(redux.backgroundPath.getBounds(), redux.localBounds);

    final reduxNonEvent = layoutNativeTimelineNode(
      descr: 'Section',
      width: 100,
      padding: 6,
      maxHeight: 48,
      configFontSize: 16,
      textStyle: ahem(10),
      sectionDepth: 12,
      reduxTheme: true,
    );
    expect(reduxNonEvent.textTransform, const Offset(56, 6));
  });

  testWidgets('config and computed SVG font sizes stay independent', (
    tester,
  ) async {
    final result = layoutNativeTimelineNode(
      descr: 'A',
      width: 100,
      padding: 5,
      maxHeight: 0,
      configFontSize: 16,
      textStyle: ahem(10),
      sectionDepth: 0,
    );
    expect(result.lines.single.dy, 10);
    expect(
      result.virtualHeight,
      closeTo(result.textBounds.height + 13.8, 1e-9),
    );
  });

  testWidgets(
    '17px SFNS SVG font cell rounds ascent and descent to nearest pixels',
    (tester) async {
      await tester.runAsync(() async {
        final loader = FontLoader('Timeline-SFNS-17')
          ..addFont(
            File(
              '/System/Library/Fonts/SFNS.ttf',
            ).readAsBytes().then(ByteData.sublistView),
          );
        await loader.load();
      });

      const style = TextStyle(
        fontFamily: 'Timeline-SFNS-17',
        fontSize: 17,
        fontVariations: [FontVariation('opsz', 17)],
      );
      final painter = TextPainter(
        text: const TextSpan(text: 'Hgjpqy', style: style),
        textDirection: TextDirection.ltr,
        textScaler: TextScaler.noScaling,
      )..layout();
      final metrics = painter.computeLineMetrics().single;
      expect(metrics.ascent, closeTo(16.43, 0.25));
      expect(metrics.descent, closeTo(3.59, 0.25));
      expect(metrics.ascent.round() + metrics.descent.round(), 20);
      expect(metrics.ascent.ceil() + metrics.descent.ceil(), 21);
      painter.dispose();

      final output = layoutNativeTimelineNode(
        descr: 'Hgjpqy',
        width: 200,
        padding: 5,
        maxHeight: 0,
        configFontSize: 17,
        textStyle: style,
        sectionDepth: 0,
      );
      // An isolated Chrome 154 SVG probe measured this SFNS 17px font cell as
      // 20px. The native natural metrics distinguish nearest rounding from
      // ceiling (which would produce 21px).
      expect(output.lines.single.glyphBounds.height, 20);
      expect(output.textBounds.height, 20);
    },
    skip: !Platform.isMacOS,
  );

  testWidgets(
    'SFNS host comparison reproduces captured timeline tspan wrapping',
    (tester) async {
      await tester.runAsync(() async {
        final loader = FontLoader('Timeline-SFNS')
          ..addFont(
            File(
              '/System/Library/Fonts/SFNS.ttf',
            ).readAsBytes().then(ByteData.sublistView),
          );
        await loader.load();
      });
      final expected =
          jsonDecode(
                File(
                  '../../fixtures/mobile-parity/mermaid-timeline-test-expected.json',
                ).readAsStringSync(),
              )
              as Map<String, dynamic>;
      expect(expected['reference'], 'bd3d90981271e1f93cf3d1d1a5bbf9b61136b74c');
      expect(expected['mermaidVersion'], '11.17.2');

      const sourceLongText =
          'A long event label that must wrap inside the fixed timeline event node width';
      final output = layoutNativeTimelineNode(
        descr: sourceLongText,
        width: 150,
        padding: 20,
        maxHeight: 0,
        configFontSize: 16,
        // The host system-ui/SFNS optical-size 13 face's x-height comes from
        // CoreText font metadata, independently measured from the timeline
        // fixture. SVG dominant-baseline:middle places the alphabetic baseline
        // xHeight/2 below each tspan's text position.
        svgXHeight: 6.8427734375,
        // Host-only mapping for browser SFNS platform tracking. Product
        // callers keep the font style supplied by their native text context.
        textStyle: const TextStyle(
          fontFamily: 'Timeline-SFNS',
          fontSize: 13,
          letterSpacing: -0.076171875,
          fontVariations: [FontVariation('opsz', 13)],
        ),
        sectionDepth: 1,
      );
      final shared =
          expected['geometryCatalog']['timeline-br-label-wrap-light']['shared']
              as Map;
      final sourceTexts = shared['texts'] as List;
      final node =
          (shared['timelineNodes'] as List).firstWhere(
                (item) => (item['textIndices'] as List).any(
                  (index) =>
                      sourceTexts[index]['tag'] == 'tspan' &&
                      sourceTexts[index]['text'] ==
                          'A   long   event   label   that',
                ),
              )
              as Map;
      final nodeTexts = (node['textIndices'] as List)
          .map((index) => sourceTexts[index])
          .toList();
      final sourceTspans = nodeTexts
          .where((text) => text['tag'] == 'tspan')
          .toList();
      final sourceLines = sourceTspans
          .map((text) => text['text'] as String)
          .toList();
      expect(output.lines.map((line) => line.rawText).toList(), sourceLines);
      final sourceWidths = sourceTspans
          .map((text) => (text['computedTextLength'] as num).toDouble())
          .toList();
      for (var i = 0; i < output.lines.length; i++) {
        expect(output.lines[i].width, closeTo(sourceWidths[i], 0.5));
      }
      final metricPainter = TextPainter(
        text: const TextSpan(
          text: '2001',
          style: TextStyle(
            fontFamily: 'Timeline-SFNS',
            fontSize: 13,
            fontVariations: [FontVariation('opsz', 13)],
          ),
        ),
        textDirection: TextDirection.ltr,
        textScaler: TextScaler.noScaling,
      )..layout();
      final metrics = metricPainter.computeLineMetrics().single;
      final fontCellHeight =
          metrics.ascent.roundToDouble() + metrics.descent.roundToDouble();
      metricPainter.dispose();
      final middleBaselineShift = (6.8427734375 / 2 * 64).roundToDouble() / 64;
      final expectedCellTop = 13 + middleBaselineShift - metrics.ascent.round();
      final expectedCellHeight =
          fontCellHeight + (output.lines.length - 1) * (13 * 1.1);
      // A source-only Chrome 154 probe (not fixture geometry) measured
      // SFNS's 13px SVG font cell as round(ascent)+round(descent), with each
      // additional tspan contributing exactly 1.1em.
      expect(
        output.lines.first.baseline,
        closeTo(13 + middleBaselineShift, 1e-8),
      );
      expect(
        output.lines.first.glyphBounds.top,
        closeTo(expectedCellTop, 1e-8),
      );
      expect(
        output.lines.first.glyphBounds.height,
        closeTo(fontCellHeight, 1e-8),
      );
      expect(output.textBounds.height, closeTo(expectedCellHeight, 1e-8));
      expect(
        output.virtualHeight,
        closeTo(expectedCellHeight + 16 * 1.1 * 0.5 + 20, 1e-8),
      );
      final singleLine = layoutNativeTimelineNode(
        descr: '2001',
        width: 150,
        padding: 20,
        maxHeight: 0,
        configFontSize: 16,
        svgXHeight: 6.8427734375,
        textStyle: const TextStyle(
          fontFamily: 'Timeline-SFNS',
          fontSize: 13,
          letterSpacing: -0.076171875,
          fontVariations: [FontVariation('opsz', 13)],
        ),
        sectionDepth: 1,
      );
      expect(singleLine.textBounds.height, closeTo(fontCellHeight, 1e-8));
      expect(
        singleLine.virtualHeight,
        closeTo(fontCellHeight + 8.8 + 20, 1e-8),
      );
      expect(
        output.lines.first.glyphBounds.height + 3 * (13 * 1.1),
        closeTo(58.9, 0.01),
      );
      for (var i = 1; i < output.lines.length; i++) {
        final sourceDelta =
            (sourceTspans[i]['bbox']['y'] as num).toDouble() -
            (sourceTspans[i - 1]['bbox']['y'] as num).toDouble();
        expect(
          output.lines[i].baseline - output.lines[i - 1].baseline,
          closeTo(sourceDelta, 1e-5),
        );
      }
      expect(output.lines.map((line) => line.rawText), [
        'A   long   event   label   that',
        'must   wrap   inside   the',
        'fixed   timeline   event',
        'node   width',
      ]);
    },
    skip: !Platform.isMacOS,
  );
}
