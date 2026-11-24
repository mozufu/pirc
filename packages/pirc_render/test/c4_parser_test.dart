import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_render/src/mermaid/c4_parser.dart';

final _fixture = _readFixture();
final _cases = (_fixture['cases'] as List).map(_object).toList();
final _invalidCases = (_fixture['invalidCases'] as List).map(_object).toList();

Map<String, dynamic> _readFixture() {
  const path = 'mobile-parity/mermaid-c4-parser-expected.json';
  final files = [File('../../fixtures/$path'), File('fixtures/$path')];
  final matches = files.where((candidate) => candidate.existsSync()).toList();
  if (matches.isEmpty) {
    throw FileSystemException('Could not find the shared Mermaid C4 fixture');
  }
  return _object(jsonDecode(matches.first.readAsStringSync()));
}

Map<String, dynamic> _object(Object? value) =>
    Map<String, dynamic>.from(value as Map);

String? _text(Object? value) {
  if (value is Map) return value['text'] as String?;
  return value as String?;
}

bool _bool(Object? value) => value as bool? ?? false;

void main() {
  for (final fixtureCase in _cases) {
    test('matches pinned Mermaid DB: ${fixtureCase['id']}', () {
      final db = _object(fixtureCase['db']);
      final config = fixtureCase['config'] == null
          ? <String, dynamic>{}
          : _object(fixtureCase['config']);
      final diagram = parseNativeMermaidC4(fixtureCase['source'] as String);

      expect(diagram.kind, db['type']);
      expect(diagram.title ?? '', db['title'] ?? '');
      expect(diagram.wrap, config['wrap'] ?? true);
      expect(diagram.shapeInRow, db['shapeInRow']);
      expect(diagram.boundaryInRow, db['boundaryInRow']);
      expect(diagram.shapes, hasLength((db['shapes'] as List).length));
      expect(diagram.boundaries, hasLength((db['boundaries'] as List).length));
      expect(diagram.relations, hasLength((db['rels'] as List).length));

      for (var index = 0; index < diagram.shapes.length; index++) {
        final actual = diagram.shapes[index];
        final expected = _object((db['shapes'] as List)[index]);
        expect(actual.alias, expected['alias'], reason: 'shape[$index].alias');
        expect(
          actual.kind,
          _text(expected['typeC4Shape']),
          reason: 'shape[$index].typeC4Shape',
        );
        expect(
          actual.label,
          _text(expected['label']),
          reason: 'shape[$index].label',
        );
        expect(
          actual.type,
          _text(expected['type']),
          reason: 'shape[$index].type',
        );
        expect(
          actual.technology,
          _text(expected['techn']),
          reason: 'shape[$index].techn',
        );
        expect(
          actual.description,
          _text(expected['descr']),
          reason: 'shape[$index].descr',
        );
        expect(
          actual.parentBoundary,
          expected['parentBoundary'],
          reason: 'shape[$index].parentBoundary',
        );
        expect(
          actual.wrap,
          _bool(expected['wrap']),
          reason: 'shape[$index].wrap',
        );
        expect(
          actual.backgroundColor,
          expected['bgColor'],
          reason: 'shape[$index].bgColor',
        );
        expect(
          actual.fontColor,
          expected['fontColor'],
          reason: 'shape[$index].fontColor',
        );
        expect(
          actual.borderColor,
          expected['borderColor'],
          reason: 'shape[$index].borderColor',
        );
        expect(
          actual.shadowing,
          expected['shadowing'],
          reason: 'shape[$index].shadowing',
        );
      }

      for (var index = 0; index < diagram.boundaries.length; index++) {
        final actual = diagram.boundaries[index];
        final expected = _object((db['boundaries'] as List)[index]);
        expect(
          actual.alias,
          expected['alias'],
          reason: 'boundary[$index].alias',
        );
        expect(
          actual.label,
          _text(expected['label']),
          reason: 'boundary[$index].label',
        );
        expect(
          actual.type,
          _text(expected['type']),
          reason: 'boundary[$index].type',
        );
        expect(
          actual.parentBoundary,
          expected['parentBoundary'],
          reason: 'boundary[$index].parentBoundary',
        );
        expect(
          actual.description,
          _text(expected['descr']),
          reason: 'boundary[$index].descr',
        );
        expect(
          actual.technology,
          _text(expected['techn']),
          reason: 'boundary[$index].techn',
        );
        expect(
          actual.nodeType,
          expected['nodeType'],
          reason: 'boundary[$index].nodeType',
        );
        expect(
          actual.wrap,
          _bool(expected['wrap']),
          reason: 'boundary[$index].wrap',
        );
        expect(
          actual.backgroundColor,
          expected['bgColor'],
          reason: 'boundary[$index].bgColor',
        );
        expect(
          actual.fontColor,
          expected['fontColor'],
          reason: 'boundary[$index].fontColor',
        );
        expect(
          actual.borderColor,
          expected['borderColor'],
          reason: 'boundary[$index].borderColor',
        );
        expect(
          actual.shadowing,
          expected['shadowing'],
          reason: 'boundary[$index].shadowing',
        );
      }

      for (var index = 0; index < diagram.relations.length; index++) {
        final actual = diagram.relations[index];
        final expected = _object((db['rels'] as List)[index]);
        expect(actual.kind, expected['type'], reason: 'relation[$index].type');
        expect(actual.from, expected['from'], reason: 'relation[$index].from');
        expect(actual.to, expected['to'], reason: 'relation[$index].to');
        expect(
          actual.label,
          _text(expected['label']),
          reason: 'relation[$index].label',
        );
        expect(
          actual.technology,
          _text(expected['techn']) ?? '',
          reason: 'relation[$index].techn',
        );
        expect(
          actual.description,
          _text(expected['descr']) ?? '',
          reason: 'relation[$index].descr',
        );
        expect(
          actual.wrap,
          _bool(expected['wrap']),
          reason: 'relation[$index].wrap',
        );
        expect(
          actual.textColor,
          expected['textColor'],
          reason: 'relation[$index].textColor',
        );
        expect(
          actual.lineColor,
          expected['lineColor'],
          reason: 'relation[$index].lineColor',
        );
        expect(
          actual.offsetX,
          expected['offsetX'],
          reason: 'relation[$index].offsetX',
        );
        expect(
          actual.offsetY,
          expected['offsetY'],
          reason: 'relation[$index].offsetY',
        );
      }
    });
  }

  for (final fixtureCase in _invalidCases) {
    test('rejects pinned Mermaid invalid input: ${fixtureCase['id']}', () {
      expect(
        () => parseNativeMermaidC4(fixtureCase['source'] as String),
        throwsA(isA<FormatException>()),
      );
    });
  }

  test('lexes quoted commas, newlines, and entity escapes as literal text', () {
    const source = '''C4Component
Component(api, "Catalog, API\n(v2)", "Go, gRPC", "Accepts, filters\nand keeps &amp; literal")
Component(db, "Store", "PostgreSQL", "")
Rel(api, db, "Reads, then\nreturns", "SQL, prepared", "")''';
    final diagram = parseNativeMermaidC4(source);

    expect(diagram.shapes.first.label, 'Catalog, API\n(v2)');
    expect(
      diagram.shapes.first.description,
      'Accepts, filters\nand keeps &amp; literal',
    );
    expect(diagram.relations.single.label, 'Reads, then\nreturns');
    expect(diagram.relations.single.technology, 'SQL, prepared');
  });

  test('keeps omitted item wrap false while renderer config defaults true', () {
    final diagram = parseNativeMermaidC4('C4Context\nPerson(user, "User")');
    expect(diagram.wrap, isTrue);
    expect(diagram.shapes.single.wrap, isFalse);

    final explicitlyDisabled = parseNativeMermaidC4(
      'C4Context\nPerson(user, "User")',
      wrap: false,
    );
    expect(explicitlyDisabled.wrap, isFalse);
    expect(explicitlyDisabled.shapes.single.wrap, isFalse);

    final explicitlyEnabled = parseNativeMermaidC4(
      'C4Context\nPerson(user, "User")',
      wrap: true,
    );
    expect(explicitlyEnabled.wrap, isTrue);
    expect(explicitlyEnabled.shapes.single.wrap, isTrue);
  });

  test('rejects unsupported shape variants and non-empty overrides', () {
    expect(
      () => parseNativeMermaidC4(
        'C4Context\nPerson(user, "User", "", "sprite-name")',
      ),
      throwsA(isA<FormatException>()),
    );
    expect(
      () => parseNativeMermaidC4(
        'C4Context\nPerson(user, "User")\nUpdateElementStyle(user,,,,,"circle")',
      ),
      throwsA(isA<FormatException>()),
    );
    expect(
      () => parseNativeMermaidC4('%%{init: {"theme": "dark"}}%%\nC4Context'),
      throwsA(isA<FormatException>()),
    );
  });
}
