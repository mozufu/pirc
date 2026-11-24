import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:html/parser.dart' as html;
import 'package:pirc_render/src/mermaid/class_diagram.dart';
import 'package:pirc_render/src/mermaid/state_model.dart';

const _fixturePath = '../../fixtures/mobile-parity/mermaid-uml.json';
const _expectedPath = '../../fixtures/mobile-parity/mermaid-uml-expected.json';

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

    if (item['kind'] == 'state') {
      test('state parser matches pinned Mermaid DB semantics: $id', () {
        if (db['accepted'] != true) {
          expect(
            () => parseNativeMermaidStateDiagram(source),
            throwsFormatException,
            reason: 'Pinned Mermaid rejected $id: ${reference['errorText']}',
          );
          return;
        }

        _expectStateCase(id, source, db);
      });
      continue;
    }
    if (item['kind'] != 'class') continue;

    test('class parser matches pinned Mermaid DB semantics: $id', () {
      if (db['accepted'] != true) {
        expect(
          () => parseNativeMermaidClassDiagram(source),
          throwsFormatException,
          reason: 'Pinned Mermaid rejected $id: ${reference['errorText']}',
        );
        return;
      }

      final actual = parseNativeMermaidClassDiagram(source);
      expect(
        actual.direction,
        (db['direction'] as String).toUpperCase(),
        reason: id,
      );

      final dbNodes = (db['nodes'] as List<dynamic>)
          .cast<Map<String, dynamic>>();
      final expectedClasses = dbNodes
          .where((node) => node['shape'] == 'classBox')
          .toList();
      final actualClasses = {for (final node in actual.classes) node.id: node};
      expect(
        actualClasses.keys.toSet(),
        expectedClasses.map((node) => node['id'] as String).toSet(),
        reason: '$id class IDs',
      );
      for (final expectedNode in expectedClasses) {
        final nodeId = expectedNode['id'] as String;
        final node = actualClasses[nodeId]!;
        expect(expectedNode['shape'], 'classBox', reason: '$id $nodeId shape');
        expect(
          node.label,
          _renderedText(expectedNode['label'] as String),
          reason: '$id $nodeId rendered label',
        );
        expect(
          node.text,
          expectedNode['text'],
          reason: '$id $nodeId rendered text',
        );
        expect(
          node.displayLabel,
          _renderedText(expectedNode['text'] as String),
          reason: '$id $nodeId generic display text',
        );
        expect(
          node.namespace,
          expectedNode['parentId'] as String?,
          reason: '$id $nodeId namespace',
        );
        expect(
          node.annotations,
          ((expectedNode['annotations'] as List<dynamic>?) ?? const [])
              .cast<String>(),
          reason: '$id $nodeId annotations',
        );

        _expectMembers(
          id,
          nodeId,
          'members',
          (expectedNode['members'] as List<dynamic>?) ?? const [],
          node.members,
        );
      }

      final expectedNamespaces =
          dbNodes
              .where((node) => node['isGroup'] == true)
              .map(
                (node) => <String?>[
                  node['id'] as String,
                  _renderedText(
                    node['label'] as String? ?? node['id'] as String,
                  ),
                  node['parentId'] as String?,
                ],
              )
              .toList()
            ..sort((a, b) => a[0]!.compareTo(b[0]!));
      final actualNamespaces =
          actual.namespaces
              .map(
                (namespace) => <String?>[
                  namespace.id,
                  namespace.label,
                  namespace.parent,
                ],
              )
              .toList()
            ..sort((a, b) => a[0]!.compareTo(b[0]!));
      expect(actualNamespaces, expectedNamespaces, reason: '$id namespaces');

      final noteNodes = dbNodes.where((node) => node['shape'] == 'note');
      final expectedNotes = noteNodes.map((node) {
        final noteEdge = (db['edges'] as List<dynamic>)
            .cast<Map<String, dynamic>>()
            .firstWhere((edge) => edge['start'] == node['id']);
        return <String>[
          node['id'] as String,
          noteEdge['end'] as String,
          _renderedText(node['label'] as String),
        ];
      }).toList()..sort((a, b) => a[0].compareTo(b[0]));
      final actualNotes =
          actual.notes
              .map((note) => <String>[note.id, note.classId, note.text])
              .toList()
            ..sort((a, b) => a[0].compareTo(b[0]));
      expect(actualNotes, expectedNotes, reason: '$id notes');

      final expectedRelations =
          (db['edges'] as List<dynamic>)
              .cast<Map<String, dynamic>>()
              .map(
                (edge) => <String>[
                  edge['start'] as String,
                  edge['end'] as String,
                  edge['arrowTypeStart'] as String? ?? 'none',
                  edge['arrowTypeEnd'] as String? ?? 'none',
                  edge['pattern'] as String? ?? 'solid',
                  edge['startLabelRight'] as String? ?? '',
                  edge['endLabelLeft'] as String? ?? '',
                  _renderedText(edge['label'] as String? ?? ''),
                ],
              )
              .toList()
            ..sort(_compareTuple);
      final actualRelations =
          actual.relations
              .map(
                (relation) => <String>[
                  relation.start,
                  relation.end,
                  relation.startMarker.dbName,
                  relation.endMarker.dbName,
                  relation.pattern,
                  relation.startMultiplicity,
                  relation.endMultiplicity,
                  relation.label,
                ],
              )
              .toList()
            ..sort(_compareTuple);
      expect(actualRelations, expectedRelations, reason: '$id relationships');
    });
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

String _memberVisibleText(String source) =>
    source.startsWith(r'\') ? source.substring(1) : source;

void _expectMembers(
  String caseId,
  String classId,
  String section,
  List<dynamic> rawExpected,
  List<NativeMermaidClassMember> actual,
) {
  final expected = rawExpected.cast<Map<String, dynamic>>();
  expect(
    actual,
    hasLength(expected.length),
    reason: '$caseId $classId $section count',
  );
  for (var index = 0; index < expected.length; index++) {
    final expectedMember = expected[index];
    final member = actual[index];
    final reason = '$caseId $classId $section[$index]';
    expect(
      member.memberType,
      expectedMember['memberType'],
      reason: '$reason type',
    );
    expect(member.id, expectedMember['id'], reason: '$reason ID');
    expect(
      member.visibility,
      expectedMember['visibility'],
      reason: '$reason visibility',
    );
    expect(
      member.classifier,
      expectedMember['classifier'],
      reason: '$reason classifier',
    );
    expect(
      member.parameters,
      expectedMember['parameters'] ?? '',
      reason: '$reason parameters',
    );
    expect(
      member.returnType,
      expectedMember['returnType'] ?? '',
      reason: '$reason return type',
    );
    expect(member.text, expectedMember['text'], reason: '$reason DB text');
    expect(
      member.displayText,
      _renderedText(_memberVisibleText(expectedMember['text'] as String)),
      reason: '$reason rendered text',
    );
  }
}

int _compareTuple(List<String> a, List<String> b) {
  for (var index = 0; index < a.length; index++) {
    final order = a[index].compareTo(b[index]);
    if (order != 0) return order;
  }
  return 0;
}

void _expectStateCase(String caseId, String source, Map<String, dynamic> db) {
  final actual = parseNativeMermaidStateDiagram(source);
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

  final expectedNodes = (db['nodes'] as List<dynamic>)
      .cast<Map<String, dynamic>>();
  final expectedDividerIds = expectedNodes
      .where((node) => node['shape'] == 'divider')
      .map((node) => node['id'] as String)
      .toList();
  final actualDividerIds = actual.nodes
      .where((node) => node.shape == 'divider')
      .map((node) => node.id)
      .toList();
  expect(
    actualDividerIds,
    hasLength(expectedDividerIds.length),
    reason: '$caseId parallel divider count',
  );
  final canonicalIds = <String, String>{};
  for (var index = 0; index < expectedDividerIds.length; index++) {
    final canonical = 'divider#${index + 1}';
    canonicalIds[expectedDividerIds[index]] = canonical;
    canonicalIds[actualDividerIds[index]] = canonical;
  }
  String canonicalId(String id) => canonicalIds[id] ?? id;

  final expectedById = {
    for (final node in expectedNodes) canonicalId(node['id'] as String): node,
  };
  final actualById = {
    for (final node in actual.nodes) canonicalId(node.id): node,
  };
  expect(
    actualById.keys.toSet(),
    expectedById.keys.toSet(),
    reason: '$caseId state IDs',
  );

  for (final entry in expectedById.entries) {
    final id = entry.key;
    final expected = entry.value;
    final node = actualById[id]!;
    expect(node.shape, expected['shape'], reason: '$caseId $id shape');
    expect(
      node.type,
      _stateTypeFromDb(expected),
      reason: '$caseId $id parser type',
    );
    expect(
      node.isGroup,
      expected['isGroup'] ?? false,
      reason: '$caseId $id group',
    );
    expect(
      node.label,
      _renderedText(_dbText(expected['label']) ?? expected['id'] as String),
      reason: '$caseId $id rendered label',
    );
    final parentId = (expected['parentId'] ?? expected['parent']) as String?;
    expect(
      node.parentId == null ? null : canonicalId(node.parentId!),
      parentId == null ? null : canonicalId(parentId),
      reason: '$caseId $id parent',
    );
    if (expected['position'] is String) {
      expect(
        node.noteSide,
        _noteSideFromDb(expected['position'] as String),
        reason: '$caseId $id note side',
      );
    }
    final expectedNodeDirection = expected['dir'] as String?;
    if (expectedNodeDirection != null) {
      expect(
        node.direction ?? actual.direction,
        expectedNodeDirection,
        reason: '$caseId $id effective direction',
      );
    } else {
      expect(
        node.direction == null || node.direction == actual.direction,
        isTrue,
        reason: '$caseId $id direction inheritance',
      );
    }

    final descriptions = expected['description'];
    final expectedDescriptions = descriptions is List
        ? descriptions.map((value) => _renderedText(value.toString())).toList()
        : <String>[];
    final expectedDescription =
        descriptions is String && descriptions.isNotEmpty
        ? _renderedText(descriptions)
        : expectedDescriptions.isEmpty
        ? null
        : expectedDescriptions.join('\n');
    expect(
      node.description,
      expectedDescription,
      reason: '$caseId $id description',
    );
    expect(
      node.descriptions,
      expectedDescriptions,
      reason: '$caseId $id descriptions',
    );

    const builtInClasses = {
      'statediagram-state',
      'statediagram-cluster',
      'statediagram-cluster-alt',
      'statediagram-note',
    };
    final expectedClasses = (expected['cssClasses'] as String? ?? '')
        .split(RegExp(r'\s+'))
        .where((name) => name.isNotEmpty && !builtInClasses.contains(name))
        .toList();
    expect(
      node.classes,
      expectedClasses,
      reason: '$caseId $id authored classes',
    );
    expect(
      node.styles,
      ((expected['cssStyles'] as List<dynamic>?) ?? const []).cast<String>(),
      reason: '$caseId $id authored styles',
    );

    final expectedChildIds =
        expectedNodes
            .where(
              (child) =>
                  (child['parentId'] ?? child['parent']) == expected['id'],
            )
            .map((child) => canonicalId(child['id'] as String))
            .toList()
          ..sort();
    final actualChildIds =
        node.children.map((child) => canonicalId(child.id)).toList()..sort();
    expect(
      actualChildIds,
      expectedChildIds,
      reason: '$caseId $id child states',
    );
  }

  final expectedEdges = (db['edges'] as List<dynamic>)
      .cast<Map<String, dynamic>>()
      .map(
        (edge) => <String>[
          canonicalId(edge['start'] as String),
          canonicalId(edge['end'] as String),
          _renderedText(edge['label'] as String? ?? ''),
          edge['arrowhead'] as String? ?? 'normal',
        ],
      )
      .toList();
  final actualEdges = actual.edges
      .map(
        (edge) => <String>[
          canonicalId(edge.start),
          canonicalId(edge.end),
          edge.label ?? '',
          edge.arrowhead,
        ],
      )
      .toList();
  expect(
    actualEdges,
    expectedEdges,
    reason: '$caseId transition endpoints, labels, and arrowheads',
  );

  final expectedStyleClasses =
      (db['styleClasses'] as Map<String, dynamic>? ?? const {});
  expect(
    actual.styleClasses.keys.toSet(),
    expectedStyleClasses.keys.toSet(),
    reason: '$caseId classDef IDs',
  );
  for (final entry in expectedStyleClasses.entries) {
    final expected = entry.value as Map<String, dynamic>;
    final styleClass = actual.styleClasses[entry.key]!;
    expect(
      styleClass.id,
      expected['id'] ?? entry.key,
      reason: '$caseId ${entry.key} id',
    );
    expect(
      styleClass.styles,
      ((expected['styles'] as List<dynamic>?) ?? const []).cast<String>(),
      reason: '$caseId ${entry.key} styles',
    );
    expect(
      styleClass.textStyles,
      ((expected['textStyles'] as List<dynamic>?) ?? const []).cast<String>(),
      reason: '$caseId ${entry.key} text styles',
    );
  }
}

String _stateTypeFromDb(Map<String, dynamic> node) {
  final shape = node['shape'] as String;
  return switch (shape) {
    'stateStart' => 'start',
    'stateEnd' => 'end',
    'choice' => 'choice',
    'fork' => 'fork',
    'join' => 'join',
    'divider' => 'divider',
    'note' => 'note',
    _ => 'default',
  };
}

String? _dbText(Object? value) {
  if (value == null) return null;
  if (value is String) return value;
  if (value is List) return value.map((item) => item.toString()).join(' ');
  return value.toString();
}

String? _noteSideFromDb(String position) {
  if (position.startsWith('right ')) return 'right';
  if (position.startsWith('left ')) return 'left';
  return position;
}
