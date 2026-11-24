import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:html/parser.dart' as html;
import 'package:pirc_render/src/mermaid/er_diagram.dart';

const _fixturePath = '../../fixtures/mobile-parity/mermaid-er.json';
const _expectedPath = '../../fixtures/mobile-parity/mermaid-er-expected.json';

void main() {
  final fixture =
      jsonDecode(File(_fixturePath).readAsStringSync()) as Map<String, dynamic>;
  final expected =
      jsonDecode(File(_expectedPath).readAsStringSync())
          as Map<String, dynamic>;
  final fixtureCases = fixture['cases'] as List<dynamic>;
  final referenceCases =
      (((expected['themes'] as Map<String, dynamic>)['light']
                      as Map<String, dynamic>)['widths']
                  as List<dynamic>)
              .cast<Map<String, dynamic>>()
              .firstWhere((row) => row['width'] == 390)['cases']
          as List<dynamic>;
  final references = {
    for (final raw in referenceCases)
      (raw as Map<String, dynamic>)['id'] as String: raw,
  };

  for (final raw in fixtureCases) {
    final item = Map<String, dynamic>.from(raw as Map);
    final id = item['id'] as String;
    final reference = references[id] as Map<String, dynamic>;
    final source = _diagramSource(item['source'] as String);
    final db = reference['db'] as Map<String, dynamic>;

    test('ER parser matches pinned Mermaid DB semantics: $id', () {
      if (db['accepted'] != true) {
        expect(
          () => parseNativeMermaidErDiagram(source),
          throwsFormatException,
          reason: 'Pinned Mermaid rejected $id: ${db['error']}',
        );
        return;
      }
      _expectErCase(id, source, db);
    });
  }
}

void _expectErCase(String caseId, String source, Map<String, dynamic> db) {
  final actual = parseNativeMermaidErDiagram(source);
  expect(actual.direction, db['direction'], reason: '$caseId direction');
  expect(
    actual.accessibleTitle,
    db['accessibleTitle'] ?? '',
    reason: '$caseId accessible title',
  );
  expect(
    actual.accessibleDescription,
    db['accessibleDescription'] ?? '',
    reason: '$caseId accessible description',
  );

  final dbEntities = <String, Map<String, dynamic>>{
    for (final raw in (db['entities'] as List<dynamic>))
      (raw as List<dynamic>)[0] as String: Map<String, dynamic>.from(
        raw[1] as Map,
      ),
  };
  final expectedNodes = (db['nodes'] as List<dynamic>)
      .cast<Map<String, dynamic>>()
      .where((node) => node['shape'] == 'erBox')
      .toList();
  final actualById = {for (final entity in actual.entities) entity.id: entity};
  expect(
    actualById.keys.toSet(),
    expectedNodes.map((node) => node['id'] as String).toSet(),
    reason: '$caseId entity IDs',
  );

  for (final expectedNode in expectedNodes) {
    final id = expectedNode['id'] as String;
    final sourceName = expectedNode['label'] as String;
    final expectedEntity = dbEntities[sourceName]!;
    final entity = actualById[id]!;
    final reason = '$caseId $sourceName';
    expect(entity.name, sourceName, reason: '$reason source name');
    expect(
      entity.label,
      _renderedText(expectedEntity['label'] as String),
      reason: '$reason DB label',
    );
    final expectedAlias = expectedEntity['alias'] as String? ?? '';
    expect(entity.alias, expectedAlias, reason: '$reason alias');
    expect(
      entity.displayLabel,
      _renderedText(
        expectedAlias.isNotEmpty
            ? expectedAlias
            : expectedEntity['label'] as String,
      ),
      reason: '$reason displayed label',
    );

    final expectedAttributes = (expectedEntity['attributes'] as List<dynamic>)
        .cast<Map<String, dynamic>>();
    expect(
      entity.attributes,
      hasLength(expectedAttributes.length),
      reason: '$reason attribute count',
    );
    for (var index = 0; index < expectedAttributes.length; index++) {
      final expectedAttribute = expectedAttributes[index];
      final attribute = entity.attributes[index];
      final attributeReason = '$reason attribute[$index]';
      expect(
        attribute.type,
        expectedAttribute['type'],
        reason: '$attributeReason type',
      );
      expect(
        attribute.name,
        expectedAttribute['name'],
        reason: '$attributeReason name',
      );
      expect(
        attribute.keys,
        expectedAttribute['keys'] ?? const <String>[],
        reason: '$attributeReason keys',
      );
      expect(
        attribute.comment,
        expectedAttribute['comment'] ?? '',
        reason: '$attributeReason comment',
      );
    }
  }

  final expectedRelationships = (db['relationships'] as List<dynamic>)
      .cast<Map<String, dynamic>>();
  expect(
    actual.relationships,
    hasLength(expectedRelationships.length),
    reason: '$caseId relationship count',
  );
  for (var index = 0; index < expectedRelationships.length; index++) {
    final expectedRelationship = expectedRelationships[index];
    final relationship = actual.relationships[index];
    final reason = '$caseId relationship[$index]';
    expect(
      relationship.entityA,
      expectedRelationship['entityA'],
      reason: '$reason first entity',
    );
    expect(
      relationship.roleA,
      _renderedText(expectedRelationship['roleA'] as String? ?? ''),
      reason: '$reason role',
    );
    expect(
      relationship.entityB,
      expectedRelationship['entityB'],
      reason: '$reason second entity',
    );
    final expectedSpec =
        expectedRelationship['relSpec'] as Map<String, dynamic>;
    expect(relationship.cardA, expectedSpec['cardA'], reason: '$reason card A');
    expect(relationship.cardB, expectedSpec['cardB'], reason: '$reason card B');
    expect(
      relationship.relType,
      expectedSpec['relType'],
      reason: '$reason identification',
    );
  }
}

String _diagramSource(String fencedSource) {
  const prefix = '```mermaid\n';
  const suffix = '\n```';
  if (!fencedSource.startsWith(prefix) || !fencedSource.endsWith(suffix)) {
    throw FormatException('Expected a Mermaid fenced block: $fencedSource');
  }
  return fencedSource.substring(
    prefix.length,
    fencedSource.length - suffix.length,
  );
}

String _renderedText(String source) {
  final restoredEntities = source.replaceAllMapped(RegExp(r'ﬂ°([\w#]+)¶ß'), (
    match,
  ) {
    final reference = '&${match[1]!};';
    return html.parseFragment(reference).text ?? match[0]!;
  });
  return html.parseFragment(restoredEntities).text ?? '';
}
