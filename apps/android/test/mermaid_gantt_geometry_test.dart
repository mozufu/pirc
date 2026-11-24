import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_render/src/mermaid/gantt_parser.dart';
import 'package:pirc_render/src/mermaid/gantt_rendering.dart';

import '../tool/parity/capture_fonts.dart'
    show loadParityFonts, noPingFang, pingFangFont;

const _fixturePath = '../../fixtures/mobile-parity/mermaid-gantt-expected.json';
const _sfFontPath = '/System/Library/Fonts/SFNS.ttf';

Future<void> _loadComparisonFonts(WidgetTester tester) async {
  await tester.runAsync(() async {
    await loadParityFonts();
    final pingFang = pingFangFont()!;
    await (FontLoader(
      'sans-serif',
    )..addFont(pingFang.readAsBytes().then(ByteData.sublistView))).load();
    await (FontLoader('Mermaid reference')
          ..addFont(File(_sfFontPath).readAsBytes().then(ByteData.sublistView)))
        .load();
  });
}

void main() {
  final fixture = jsonDecode(File(_fixturePath).readAsStringSync()) as Map;
  final fixedNow = DateTime.parse(fixture['fixedNow'] as String);
  final light = (fixture['themes'] as Map)['light'] as Map;

  group('native Mermaid Gantt geometry', () {
    for (final widthData in (light['widths'] as List).cast<Map>()) {
      final width = (widthData['width'] as num).toDouble();
      final scale = ((widthData['scales'] as List).first as Map);
      final cases = (scale['cases'] as List).cast<Map>();
      for (final browserCase in cases) {
        final caseId = browserCase['id'] as String;
        testWidgets(
          '$caseId at ${width.toInt()} CSS px matches pinned geometry',
          (tester) async {
            await _loadComparisonFonts(tester);
            final diagram = parseNativeMermaidGantt(
              browserCase['source'] as String,
              clock: fixedNow,
            );
            final layout = layoutNativeMermaidGantt(
              diagram,
              width: width,
              fontFamily: 'Mermaid reference',
            );
            final svg = browserCase['svg'] as Map;
            final viewBox = (svg['attrs'] as Map)['viewBox'] as String;
            final viewBoxParts = viewBox.split(' ').map(double.parse).toList();
            expect(layout.size.width, viewBoxParts[2], reason: 'viewBox width');
            expect(
              layout.size.height,
              viewBoxParts[3],
              reason: 'viewBox height',
            );

            final expectedRows = (svg['taskRows'] as List).cast<Map>();
            expect(layout.tasks, hasLength(expectedRows.length));
            for (var index = 0; index < expectedRows.length; index++) {
              final expectedRow = expectedRows[index];
              final taskLayout = layout.tasks[index];
              final bar = expectedRow['bar'] as Map;
              final attrs = bar['attrs'] as Map;
              final id = expectedRow['id'] as String;
              expect(taskLayout.task.id, id, reason: 'task order at $index');
              _expectClose(
                taskLayout.bounds.left,
                _number(attrs['x']),
                '$caseId/$id bar x',
              );
              _expectClose(
                taskLayout.bounds.top,
                _number(attrs['y']),
                '$caseId/$id bar y',
              );
              _expectClose(
                taskLayout.bounds.width,
                _number(attrs['width']),
                '$caseId/$id bar width',
              );
              _expectClose(
                taskLayout.bounds.height,
                _number(attrs['height']),
                '$caseId/$id bar height',
              );
            }

            final expectedTicks = ((svg['axes'] as Map)['ticks'] as List)
                .cast<Map>();
            expect(layout.ticks, hasLength(expectedTicks.length));
            for (var index = 0; index < expectedTicks.length; index++) {
              final expectedTick = expectedTicks[index];
              final expectedTransform = expectedTick['transform'] as String;
              final localX = double.parse(
                RegExp(
                  r'translate\(([-\d.]+),',
                ).firstMatch(expectedTransform)![1]!,
              );
              final expectedText =
                  ((expectedTick['text'] as Map)['text'] as String);
              final nativeTick = layout.ticks[index];
              expect(
                nativeTick.label,
                expectedText,
                reason: '$caseId tick $index label',
              );
              _expectClose(
                nativeTick.x,
                localX + 75,
                '$caseId tick $index x (browser transform + 75px axis origin)',
              );
            }

            final expectedExclusions = (svg['excludeRanges'] as List)
                .cast<Map>();
            expect(layout.exclusions, hasLength(expectedExclusions.length));
            for (var index = 0; index < expectedExclusions.length; index++) {
              final attrs = expectedExclusions[index]['attrs'] as Map;
              final rect = layout.exclusions[index];
              _expectClose(
                rect.left,
                _number(attrs['x']),
                '$caseId exclusion $index x',
              );
              _expectClose(
                rect.top,
                _number(attrs['y']),
                '$caseId exclusion $index y',
              );
              _expectClose(
                rect.width,
                _number(attrs['width']),
                '$caseId exclusion $index width',
              );
              _expectClose(
                rect.height,
                _number(attrs['height']),
                '$caseId exclusion $index height',
              );
            }
          },
          skip: noPingFang,
        );
      }
    }

    testWidgets(
      'reports label residuals using the SFNS browser-reference font file',
      (tester) async {
        await _loadComparisonFonts(tester);
        final differences = _labelDifferences(fixture, fixedNow);
        if (differences.isEmpty) {
          // This is a same-file host comparison, not a system-font guarantee
          // for other platforms or a claim of browser-engine equivalence.
          debugPrint('All Gantt labels matched the SFNS.ttf host reference.');
        } else {
          debugPrint(
            'Unaccepted Gantt label residuals using the same host SFNS.ttf '
            'file as Mermaid reference:\n${differences.join('\n')}',
            wrapWidth: 2000,
          );
        }
      },
      skip: noPingFang,
    );
  });
}

List<String> _labelDifferences(Map fixture, DateTime fixedNow) {
  final light = (fixture['themes'] as Map)['light'] as Map;
  final differences = <String>[];
  for (final widthData in (light['widths'] as List).cast<Map>()) {
    final width = (widthData['width'] as num).toDouble();
    final scale = (widthData['scales'] as List).first as Map;
    for (final browserCase in (scale['cases'] as List).cast<Map>()) {
      final layout = layoutNativeMermaidGantt(
        parseNativeMermaidGantt(
          browserCase['source'] as String,
          clock: fixedNow,
        ),
        width: width,
        fontFamily: 'Mermaid reference',
      );
      final rows = (browserCase['svg'] as Map)['taskRows'] as List;
      for (var index = 0; index < rows.length; index++) {
        final row = rows[index] as Map;
        final label = row['labelGeometry'] as Map;
        final attrs = label['attrs'] as Map;
        final computed = label['computed'] as Map;
        final expectedX = _number(attrs['x']);
        final expectedY = _number(attrs['y']);
        final expectedAnchor = computed['textAnchor'] as String;
        final task = layout.tasks[index];
        final actualAnchor = switch (task.anchor) {
          TextAlign.left || TextAlign.start => 'start',
          TextAlign.right || TextAlign.end => 'end',
          _ => 'middle',
        };
        if ((task.labelPosition.dx - expectedX).abs() > 0.01 ||
            (task.labelPosition.dy - expectedY).abs() > 0.01 ||
            actualAnchor != expectedAnchor) {
          differences.add(
            '${browserCase['id']}@${width.toInt()} ${row['id']}: '
            'browser x=$expectedX y=$expectedY anchor=$expectedAnchor; '
            'native SFNS x=${task.labelPosition.dx} '
            'y=${task.labelPosition.dy} anchor=$actualAnchor',
          );
        }
      }
    }
  }
  return differences;
}

double _number(Object? value) =>
    value is num ? value.toDouble() : double.parse(value as String);

void _expectClose(double actual, double expected, String reason) {
  expect(actual, closeTo(expected, 0.01), reason: reason);
}
