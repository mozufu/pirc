import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_render/src/mermaid/requirement_model.dart';
import 'package:pirc_render/src/mermaid/requirement_parser.dart';

Map<String, dynamic> _map(dynamic value) =>
    Map<String, dynamic>.from(value as Map);
Map<String, dynamic> _node(NativeRequirementNode n) => {
  'name': n.name,
  'type': n.type,
  if (n.isElement) 'docRef': n.docRef,
  if (!n.isElement) ...{
    'requirementId': n.requirementId,
    'text': n.text,
    'risk': n.risk,
    'verifyMethod': n.verifyMethod,
  },
  'cssStyles': n.cssStyles,
  'classes': n.classes,
};
void main() {
  final oracle = _map(
    jsonDecode(
      File(
        '../../fixtures/mobile-parity/mermaid-requirement-parser-expected.json',
      ).readAsStringSync(),
    ),
  );
  for (final rawCase in oracle['cases'] as List) {
    final input = _map(rawCase);
    test('actual Mermaid requirement DB ${input['id']}', () {
      final actual = parseNativeMermaidRequirement(input['source'] as String);
      final expected = _map(_map(_map(input['parser'])['db'])['raw']);
      expect([
        for (final node in actual.requirements) [node.name, _node(node)],
      ], expected['requirements']);
      expect([
        for (final node in actual.elements) [node.name, _node(node)],
      ], expected['elements']);
      expect([
        for (final rel in actual.relations)
          {'type': rel.type, 'src': rel.from, 'dst': rel.to},
      ], expected['relations']);
      expect(actual.direction, expected['direction']);
      expect(actual.title ?? '', expected['title']);
      expect(actual.accTitle ?? '', expected['accTitle']);
      expect(actual.accDescription ?? '', expected['accDescription']);
      expect(actual.classDefinitions, {
        for (final entry in expected['classes'] as List)
          entry[0]: _map(entry[1])['styles'],
      });
    });
  }
  for (final rawCase in oracle['invalidCases'] as List) {
    final input = _map(rawCase);
    test(
      'actual Mermaid invalid requirement ${input['id']}',
      () => expect(
        () => parseNativeMermaidRequirement(input['source'] as String),
        throwsFormatException,
      ),
    );
  }
}
