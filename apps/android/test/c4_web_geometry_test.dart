import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_render/src/mermaid/c4_layout.dart';
import 'package:pirc_render/src/mermaid/c4_rendering.dart';
import 'package:pirc_render/src/mermaid/c4_parser.dart';

import '../tool/parity/capture_fonts.dart' show loadParityFonts;

const _fixturePath = 'mobile-parity/mermaid-c4-web-expected.json';
const _arialFontPath = '/System/Library/Fonts/Supplemental/Arial.ttf';
const _reportPath = 'build/parity/c4-geometry-report.json';
const _referenceFontFamily = 'Mermaid C4 reference';

void main() {
  final fixture = _readFixture();

  testWidgets('compares C4 node, boundary, relation and viewBox geometry with Chrome', (
    tester,
  ) async {
    await _loadComparisonFonts(tester);
    final captures = _map(fixture['captures']);
    final cases = <Map<String, dynamic>>[];
    for (final captureName in ['light390', 'dark768']) {
      for (final browserCase in (captures[captureName] as List).map(_map)) {
        cases.add({...browserCase, 'captureName': captureName});
      }
    }

    final caseReports = <Map<String, dynamic>>[];
    for (final browserCase in cases) {
      final browser = _compareCapture(browserCase);
      caseReports.add(browser);
    }

    final differences = caseReports
        .expand((item) => (item['differences'] as List).cast<Map>())
        .toList(growable: false);
    final major = differences
        .where((difference) => difference['severity'] == 'major')
        .toList(growable: false);
    final minor = differences
        .where((difference) => difference['severity'] == 'minor')
        .toList(growable: false);
    final report = <String, Object?>{
      'fixture': fixture['fixture'],
      'mermaidVersion': fixture['mermaidVersion'],
      'reference': 'Chrome rendererDb and SVG DOM captures',
      'comparisonFont': {
        'family': _referenceFontFamily,
        'file': _arialFontPath,
        'note':
            'Uses host Arial as the Open Sans sans-serif fallback. Ahem is not selected for text measurement.',
      },
      'tolerances': {
        'smallResiduals':
            'Node and boundary coordinate deltas <= 2px, dimension deltas <= 4px, relation endpoint deltas <= 3px, and viewBox deltas <= 6px are omitted as small font/rendering residuals.',
        'majorGeometry':
            'Node and boundary coordinate deltas > 12px, dimension deltas > 16px, relation endpoint deltas > 12px, or viewBox deltas > 18px are failures. Any order or containment mismatch is a failure.',
      },
      'summary': {
        'captureCount': caseReports.length,
        'majorDifferenceCount': major.length,
        'minorDifferenceCount': minor.length,
      },
      'captures': caseReports,
    };
    _writeReport(report);

    debugPrint(
      'C4 Chrome geometry report: ${caseReports.length} captures, '
      '${major.length} major and ${minor.length} minor differences; '
      '$_reportPath',
      wrapWidth: 2000,
    );
    expect(cases, hasLength(14));
    expect(
      major,
      isEmpty,
      reason:
          'C4 geometry differs materially from the pinned Chrome captures. '
          'See $_reportPath for node, boundary, relation, order, and viewBox residuals.',
    );
  });
}

Map<String, dynamic> _compareCapture(Map<String, dynamic> browserCase) {
  if (browserCase['status'] != 'ok') {
    expect(
      () => parseNativeMermaidC4(browserCase['sourceExpected'] as String),
      throwsA(isA<FormatException>()),
    );
    return {
      'id': browserCase['id'],
      'captureName': browserCase['captureName'],
      'status': 'matching-parser-error',
      'differences': <Map<String, Object?>>[],
    };
  }
  final captureName = browserCase['captureName'] as String;
  final caseId = browserCase['id'] as String;
  final environment = _map(browserCase['environment']);
  final screen = _map(environment['screen']);
  final width = _number(screen['availWidth']);
  final rendererDb = _map(browserCase['rendererDb']);
  final svg = _map(browserCase['svg']);
  final svgAttrs = _map(svg['attrs']);
  final viewBox = (svgAttrs['viewBox'] as String)
      .trim()
      .split(RegExp(r'\s+'))
      .map(double.parse)
      .toList(growable: false);
  final layout = layoutNativeMermaidC4(
    parseNativeMermaidC4(browserCase['sourceExpected'] as String),
    screenWidth: width,
    fontFamily: _referenceFontFamily,
    resolveColor: nativeC4Color,
  );
  final differences = <Map<String, Object?>>[];

  void addDifference({
    required String subject,
    required String field,
    required Object? expected,
    required Object? actual,
    required double tolerance,
    required double majorThreshold,
  }) {
    final expectedNumber = _tryNumber(expected);
    final actualNumber = _tryNumber(actual);
    if (expectedNumber == null || actualNumber == null) {
      if (expected != actual) {
        differences.add({
          'subject': subject,
          'field': field,
          'expected': expected,
          'actual': actual,
          'delta': null,
          'severity': 'major',
        });
      }
      return;
    }
    final delta = (actualNumber - expectedNumber).abs();
    if (delta <= tolerance) return;
    differences.add({
      'subject': subject,
      'field': field,
      'expected': expectedNumber,
      'actual': actualNumber,
      'delta': delta,
      'severity': delta > majorThreshold ? 'major' : 'minor',
    });
  }

  void addStructuralDifference({
    required String subject,
    required Object? expected,
    required Object? actual,
  }) {
    if (listEquals(expected as List?, actual as List?)) return;
    differences.add({
      'subject': subject,
      'field': 'order-or-containment',
      'expected': expected,
      'actual': actual,
      'delta': null,
      'severity': 'major',
    });
  }

  final expectedShapes = (rendererDb['shapes'] as List).map(_map).toList();
  final expectedShapeOrder = expectedShapes
      .map((shape) => _map(shape['raw'])['alias'] as String)
      .toList(growable: false);
  final domNodeOrder = (svg['nodeGroups'] as List)
      .map(_map)
      .map((group) => _aliasFromSvgId(group['id'] as String))
      .toList(growable: false);
  final actualNodeOrder = layout.paintOrder
      .where((entry) => entry.startsWith('n:'))
      .map((entry) => entry.substring(2))
      .toList(growable: false);
  addStructuralDifference(
    subject: 'node order: renderer DB',
    expected: expectedShapeOrder,
    actual: layout.nodes.keys.toList(growable: false),
  );
  addStructuralDifference(
    subject: 'node order: SVG DOM paint sequence',
    expected: domNodeOrder,
    actual: actualNodeOrder,
  );

  for (final expectedShape in expectedShapes) {
    final raw = _map(expectedShape['raw']);
    final alias = raw['alias'] as String;
    final actual = layout.nodes[alias];
    if (actual == null) {
      differences.add({
        'subject': 'node $alias',
        'field': 'missing-node',
        'expected': raw['geometry'],
        'actual': null,
        'delta': null,
        'severity': 'major',
      });
      continue;
    }
    final expectedGeometry = _map(expectedShape['geometry']);
    for (final field in ['x', 'y']) {
      addDifference(
        subject: 'node $alias',
        field: field,
        expected: expectedGeometry[field],
        actual: field == 'x' ? actual.bounds.left : actual.bounds.top,
        tolerance: 2,
        majorThreshold: 12,
      );
    }
    for (final field in ['width', 'height']) {
      addDifference(
        subject: 'node $alias',
        field: field,
        expected: expectedGeometry[field],
        actual: field == 'width' ? actual.bounds.width : actual.bounds.height,
        tolerance: 4,
        majorThreshold: 16,
      );
    }
  }

  final expectedBoundaries = (rendererDb['boundaries'] as List)
      .map(_map)
      .where((boundary) => _map(boundary['raw'])['alias'] != 'global')
      .toList(growable: false);
  final expectedBoundaryOrder = expectedBoundaries
      .map((boundary) => _map(boundary['raw'])['alias'] as String)
      .toList(growable: false);
  final expectedTextOrder = (svg['texts'] as List)
      .map(_map)
      .map((text) => text['text'] as String)
      .toList(growable: false);
  final actualBoundaryOrder = layout.paintOrder
      .where((entry) => entry.startsWith('b:'))
      .map((entry) => entry.substring(2))
      .toList(growable: false);
  final expectedBoundaryPaintOrder = expectedBoundaries.toList()
    ..sort((left, right) {
      final leftRaw = _map(left['raw']);
      final rightRaw = _map(right['raw']);
      final leftLabel = _textValue(leftRaw['label']);
      final rightLabel = _textValue(rightRaw['label']);
      return expectedTextOrder
          .indexOf(leftLabel)
          .compareTo(expectedTextOrder.indexOf(rightLabel));
    });
  addStructuralDifference(
    subject: 'boundary order: renderer DB',
    expected: expectedBoundaryOrder,
    actual: layout.boundaries.keys
        .where((alias) => alias != 'global')
        .toList(growable: false),
  );
  // The Chrome DOM paints nested boundaries with their text. Sorting labels
  // by that captured text order handles sibling branches as well as nesting.
  addStructuralDifference(
    subject: 'boundary order: SVG paint sequence',
    expected: expectedBoundaryPaintOrder
        .map((boundary) => _map(boundary['raw'])['alias'] as String)
        .toList(growable: false),
    actual: actualBoundaryOrder,
  );

  for (final expectedBoundary in expectedBoundaries) {
    final raw = _map(expectedBoundary['raw']);
    final alias = raw['alias'] as String;
    final actual = layout.boundaries[alias];
    if (actual == null) {
      differences.add({
        'subject': 'boundary $alias',
        'field': 'missing-boundary',
        'expected': expectedBoundary['geometry'],
        'actual': null,
        'delta': null,
        'severity': 'major',
      });
      continue;
    }
    final expectedGeometry = _map(expectedBoundary['geometry']);
    for (final field in ['x', 'y', 'width', 'height']) {
      addDifference(
        subject: 'boundary $alias',
        field: field,
        expected: expectedGeometry[field],
        actual: switch (field) {
          'x' => actual.bounds.left,
          'y' => actual.bounds.top,
          'width' => actual.bounds.width,
          _ => actual.bounds.height,
        },
        tolerance: field == 'x' || field == 'y' ? 2 : 4,
        majorThreshold: field == 'x' || field == 'y' ? 12 : 16,
      );
    }
  }

  for (final node in layout.nodes.values) {
    final parent = layout.boundaries[node.shape.parentBoundary];
    if (parent == null || parent.boundary.alias == 'global') continue;
    if (!_containsRect(parent.bounds, node.bounds)) {
      differences.add({
        'subject': 'node ${node.shape.alias} in ${node.shape.parentBoundary}',
        'field': 'parent-boundary-containment',
        'expected': _rectJson(parent.bounds),
        'actual': _rectJson(node.bounds),
        'delta': null,
        'severity': 'major',
      });
    }
  }
  for (final boundary in layout.boundaries.values) {
    final parent = layout.boundaries[boundary.boundary.parentBoundary];
    if (parent == null || boundary.boundary.alias == 'global') continue;
    if (!_containsRect(parent.bounds, boundary.bounds)) {
      differences.add({
        'subject':
            'boundary ${boundary.boundary.alias} in '
            '${boundary.boundary.parentBoundary}',
        'field': 'parent-boundary-containment',
        'expected': _rectJson(parent.bounds),
        'actual': _rectJson(boundary.bounds),
        'delta': null,
        'severity': 'major',
      });
    }
  }

  final expectedRelations = (rendererDb['rels'] as List).map(_map).toList();
  addStructuralDifference(
    subject: 'relationship order',
    expected: expectedRelations
        .map((relation) {
          final raw = _map(relation['raw']);
          final label = _textValue(
            raw['label'],
          ).replaceFirst(RegExp(r'^\d+: '), '');
          return '${raw['from']}→${raw['to']}:$label';
        })
        .toList(growable: false),
    actual: layout.relations
        .map(
          (relation) =>
              '${relation.relation.from}→${relation.relation.to}:'
              '${relation.label.text.replaceFirst(RegExp(r'^\d+: '), '')}',
        )
        .toList(growable: false),
  );
  if (layout.relations.length != expectedRelations.length) {
    differences.add({
      'subject': 'relationships',
      'field': 'count',
      'expected': expectedRelations.length,
      'actual': layout.relations.length,
      'delta': null,
      'severity': 'major',
    });
  }
  for (
    var index = 0;
    index < layout.relations.length && index < expectedRelations.length;
    index++
  ) {
    final expected = expectedRelations[index];
    final endpointData = _map(expected['endpoints']);
    final actual = layout.relations[index];
    for (final (name, actualPoint) in [
      ('startPoint', actual.start),
      ('endPoint', actual.end),
    ]) {
      final expectedPoint = _map(endpointData[name]);
      addDifference(
        subject:
            'relationship[$index] ${actual.relation.from}→${actual.relation.to}',
        field: '$name.x',
        expected: expectedPoint['x'],
        actual: actualPoint.dx,
        tolerance: 3,
        majorThreshold: 12,
      );
      addDifference(
        subject:
            'relationship[$index] ${actual.relation.from}→${actual.relation.to}',
        field: '$name.y',
        expected: expectedPoint['y'],
        actual: actualPoint.dy,
        tolerance: 3,
        majorThreshold: 12,
      );
    }
  }

  addDifference(
    subject: 'viewBox',
    field: 'x',
    expected: viewBox[0],
    actual: 0,
    tolerance: 0.01,
    majorThreshold: 18,
  );
  addDifference(
    subject: 'viewBox',
    field: 'y offset',
    expected: -viewBox[1],
    actual: layout.viewBoxOffset.dy,
    tolerance: 6,
    majorThreshold: 18,
  );
  addDifference(
    subject: 'viewBox',
    field: 'width',
    expected: viewBox[2],
    actual: layout.size.width,
    tolerance: 6,
    majorThreshold: 18,
  );
  addDifference(
    subject: 'viewBox',
    field: 'height',
    expected: viewBox[3],
    actual: layout.size.height,
    tolerance: 6,
    majorThreshold: 18,
  );

  final actualTextOrder = _paintTextOrder(layout);
  addStructuralDifference(
    subject: 'SVG DOM text paint order and labels',
    // SVG wraps may join adjacent tspan textContent without a separating space.
    // Parser tests already compare the original strings exactly; here compare
    // ordered visible characters, preserving every non-whitespace character.
    expected: expectedTextOrder
        .map((s) => s.replaceAll(RegExp(r'\s+'), ''))
        .toList(),
    actual: actualTextOrder
        .map((s) => s.replaceAll(RegExp(r'\s+'), ''))
        .toList(),
  );

  return {
    'capture': captureName,
    'id': caseId,
    'width': width,
    'theme': captureName == 'light390' ? 'light' : 'dark',
    'expectedViewBox': svgAttrs['viewBox'],
    'actualViewBox': {
      'x': 0,
      'y': -layout.viewBoxOffset.dy,
      'width': layout.size.width,
      'height': layout.size.height,
    },
    'expectedNodeOrder': domNodeOrder,
    'actualNodeOrder': actualNodeOrder,
    'expectedBoundaryOrder': expectedBoundaryOrder,
    'actualBoundaryPaintOrder': actualBoundaryOrder,
    'expectedTextOrder': expectedTextOrder,
    'actualTextOrder': actualTextOrder,
    'differences': differences,
  };
}

List<String> _paintTextOrder(NativeC4Layout layout) {
  final texts = <String>[];
  for (final entry in layout.paintOrder) {
    if (entry.startsWith('n:')) {
      final node = layout.nodes[entry.substring(2)]!;
      texts.addAll(
        node.sections.map((section) => section.text).where(_nonEmpty),
      );
    } else {
      final boundary = layout.boundaries[entry.substring(2)]!;
      texts.addAll(
        [
          boundary.label.text,
          boundary.type.text,
          if (boundary.description != null) boundary.description!.text,
        ].where(_nonEmpty),
      );
    }
  }
  for (final relation in layout.relations) {
    if (relation.label.text.isNotEmpty) texts.add(relation.label.text);
    if (relation.technology?.text.isNotEmpty == true) {
      texts.add(relation.technology!.text);
    }
  }
  if (layout.title?.text.isNotEmpty == true) texts.add(layout.title!.text);
  return texts;
}

Future<void> _loadComparisonFonts(WidgetTester tester) async {
  await tester.runAsync(() async {
    await loadParityFonts();
    await (FontLoader(_referenceFontFamily)..addFont(
          File(_arialFontPath).readAsBytes().then(ByteData.sublistView),
        ))
        .load();
  });
}

Map<String, dynamic> _readFixture() {
  final file = [
    File('../../fixtures/$_fixturePath'),
    File('fixtures/$_fixturePath'),
  ].where((candidate) => candidate.existsSync()).firstOrNull;
  if (file == null) {
    throw FileSystemException('Could not find the Mermaid C4 web fixture');
  }
  return _map(jsonDecode(file.readAsStringSync()));
}

void _writeReport(Map<String, Object?> report) {
  final file = File(_reportPath);
  file.parent.createSync(recursive: true);
  file.writeAsStringSync(const JsonEncoder.withIndent('  ').convert(report));
}

bool _containsRect(Rect outer, Rect inner) =>
    inner.left >= outer.left - .01 &&
    inner.top >= outer.top - .01 &&
    inner.right <= outer.right + .01 &&
    inner.bottom <= outer.bottom + .01;

Map<String, double> _rectJson(Rect rect) => {
  'x': rect.left,
  'y': rect.top,
  'width': rect.width,
  'height': rect.height,
};

String _aliasFromSvgId(String id) =>
    id.replaceFirst(RegExp(r'^pirc-mermaid-\d+-'), '');

String _textValue(Object? value) => value is Map
    ? (_map(value)['text'] as String? ?? '')
    : value as String? ?? '';

Map<String, dynamic> _map(Object? value) =>
    Map<String, dynamic>.from(value as Map);

double _number(Object? value) =>
    value is num ? value.toDouble() : double.parse(value as String);

double? _tryNumber(Object? value) => value is num
    ? value.toDouble()
    : value is String
    ? double.tryParse(value)
    : null;

bool _nonEmpty(String value) => value.isNotEmpty;
