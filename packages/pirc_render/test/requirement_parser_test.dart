import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_render/src/mermaid/requirement_model.dart';
import 'package:pirc_render/src/mermaid/requirement_parser.dart';

void main() {
  group('parseNativeMermaidRequirement', () {
    test('parses all six requirement kinds and element attributes', () {
      final diagram = parseNativeMermaidRequirement('''
requirementDiagram
requirement Basic {
  id: "REQ-1"
  text: Basic check
  risk: low
  verifyMethod: test
}
functionalRequirement Functional {
  id: REQ2
}
interfaceRequirement Interface {
  text: Connector check
}
performanceRequirement Performance {
}
physicalRequirement Physical {
}
designConstraint Design {
}
element Service {
  type: Backend
  docRef: "Architecture A"
}
''');

      expect(diagram.requirements.map((node) => node.type), [
        'Requirement',
        'Functional Requirement',
        'Interface Requirement',
        'Performance Requirement',
        'Physical Requirement',
        'Design Constraint',
      ]);
      expect(diagram.requirements.first.requirementId, 'REQ-1');
      expect(diagram.requirements.first.text, 'Basic check');
      expect(diagram.requirements.first.risk, 'Low');
      expect(diagram.requirements.first.verifyMethod, 'Test');
      expect(diagram.elements.single.type, 'Backend');
      expect(diagram.elements.single.docRef, 'Architecture A');
      expect(diagram.direction, 'TB');
      expect(diagram.nodes, hasLength(7));
    });

    test('keeps directions and diagram accessibility metadata', () {
      final diagram = parseNativeMermaidRequirement('''
%% leading comment
# alternate comment
requirementDiagram
direction RL
accTitle: Requirements overview
accDescr {A system
with an accessible description}
requirement A {
}
''');

      expect(diagram.direction, 'RL');
      expect(diagram.title, isNull);
      expect(diagram.accTitle, 'Requirements overview');
      expect(
        diagram.accDescription,
        'A system\nwith an accessible description',
      );
    });

    test('accepts each supported explicit direction', () {
      for (final direction in ['TB', 'BT', 'LR', 'RL']) {
        expect(
          parseNativeMermaidRequirement(
            'requirementDiagram\ndirection $direction',
          ).direction,
          direction,
        );
      }
    });

    test('parses seven relation kinds and normalizes reverse arrows', () {
      final diagram = parseNativeMermaidRequirement('''
requirementDiagram
A - contains -> B
A - copies -> B
A - derives -> B
A - satisfies -> B
A - verifies -> B
A - refines -> B
A - traces -> B
B <- contains - A
''');

      expect(diagram.relations.map((edge) => edge.type), [
        'contains',
        'copies',
        'derives',
        'satisfies',
        'verifies',
        'refines',
        'traces',
        'contains',
      ]);
      expect(diagram.relations.first.from, 'A');
      expect(diagram.relations.first.to, 'B');
      expect(diagram.relations.last.from, 'A');
      expect(diagram.relations.last.to, 'B');
    });

    test('applies class and style statements in database order', () {
      final diagram = parseNativeMermaidRequirement('''
requirementDiagram
classDef warm fill:red
classDef spaced fill: red,color:"Deep Blue"
requirement A :::warm {
}
class A cool
style A stroke:blue
classDef cool color:white
requirement A :::late {
  id: ignored
}
''');
      final node = diagram.requirements.single;

      expect(node.classes, ['default', 'warm', 'cool', 'late']);
      expect(node.cssStyles, ['fill:red', 'stroke:blue', 'color:white']);
      expect(node.requirementId, '');
      expect(diagram.classDefinitions, {
        'warm': ['fill:red'],
        'spaced': ['fill:red', 'color:Deep Blue'],
        'cool': ['color:white'],
      });
    });

    test('honors classDef changes made after a node is assigned', () {
      final diagram = parseNativeMermaidRequirement('''
requirementDiagram
requirement "Login flow" {
}
class "Login flow" reviewed
classDef reviewed fill:#123,stroke-width:2px
''');

      expect(diagram.requirements.single.classes, ['default', 'reviewed']);
      expect(diagram.requirements.single.cssStyles, [
        'fill:#123',
        'stroke-width:2px',
      ]);
    });

    test(
      'first duplicate node definition wins and optional labels override display',
      () {
        final diagram = parseNativeMermaidRequirement('''
requirementDiagram
requirement First {
  id: original
}
requirement First {
  id: replacement
}
''');
        final node = diagram.requirements.single;
        final labeled = NativeRequirementNode(
          name: 'source',
          label: 'Shown label',
        );

        expect(node.requirementId, 'original');
        expect(node.displayLabel, 'First');
        expect(labeled.displayLabel, 'Shown label');
      },
    );

    test('rejects unknown requirement fields and invalid enum values', () {
      expect(
        () => parseNativeMermaidRequirement('''
requirementDiagram
requirement Bad {
  priority: high
}
'''),
        throwsFormatException,
      );
      expect(
        () => parseNativeMermaidRequirement('''
requirementDiagram
requirement Bad {
  risk: urgent
}
'''),
        throwsFormatException,
      );
    });

    test('rejects unsupported statements and enforces parser limits', () {
      expect(
        () => parseNativeMermaidRequirement('requirementDiagram\nclick A "x"'),
        throwsFormatException,
      );
      expect(
        () => parseNativeMermaidRequirement(
          'requirementDiagram\ntitle Unsupported',
        ),
        throwsFormatException,
      );
      expect(
        () => parseNativeMermaidRequirement(
          'requirementDiagram\n${List.filled(50000, 'x').join()}',
        ),
        throwsFormatException,
      );
      final tooManyNodes = List.generate(
        513,
        (index) => 'requirement R$index {\n}',
      ).join('\n');
      expect(
        () =>
            parseNativeMermaidRequirement('requirementDiagram\n$tooManyNodes'),
        throwsFormatException,
      );
      final tooManyRelations = List.filled(
        1025,
        'A - contains -> B',
      ).join('\n');
      expect(
        () => parseNativeMermaidRequirement(
          'requirementDiagram\n$tooManyRelations',
        ),
        throwsFormatException,
      );
    });
  });
}
