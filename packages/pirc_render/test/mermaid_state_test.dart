import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_render/src/mermaid/state_model.dart';

void main() {
  test('parses start/end, aliases, descriptions, labels, and direction', () {
    final model = parseNativeMermaidStateDiagram('''
stateDiagram-v2
direction LR
[*] --> Idle : initialize
state "Waiting for input" as Idle
Idle : ready
Idle --> [*] : finish
''');

    expect(model.direction, 'LR');
    expect(model.node('root_start')?.shape, 'stateStart');
    expect(model.node('root_end')?.shape, 'stateEnd');
    expect(model.node('Idle')?.label, 'Waiting for input');
    expect(model.node('Idle')?.description, 'ready');
    expect(model.node('Idle')?.descriptions, ['ready']);
    expect(
      model.edges.map((edge) => [edge.start, edge.end, edge.label]).toList(),
      [
        ['root_start', 'Idle', 'initialize'],
        ['Idle', 'root_end', 'finish'],
      ],
    );
  });

  test(
    'first unaliased description is the label; later rows are body text',
    () {
      final model = parseNativeMermaidStateDiagram('''
stateDiagram-v2
Idle : Ready
Idle : Waiting
''');

      final node = model.node('Idle')!;
      expect(node.label, 'Ready');
      expect(node.descriptions, ['Waiting']);
      expect(node.description, 'Waiting');
      expect(node.shape, 'rectWithTitle');
    },
  );

  test('alias remains label and preserves all description rows in order', () {
    final model = parseNativeMermaidStateDiagram('''
stateDiagram-v2
state "Waiting for response" as Waiting
Waiting : Ready
Waiting : Later
''');

    final node = model.node('Waiting')!;
    expect(node.label, 'Waiting for response');
    expect(node.descriptions, ['Ready', 'Later']);
    expect(node.description, 'Ready\nLater');
    expect(node.shape, 'rectWithTitle');
  });

  test('title keyword line follows web as two ordinary state identifiers', () {
    final model = parseNativeMermaidStateDiagram('''
stateDiagram-v2
title Lifecycle
''');

    expect(model.title, isEmpty);
    expect(model.node('title')?.label, 'title');
    expect(model.node('Lifecycle')?.label, 'Lifecycle');
  });

  test('special shapes depend on declaration order like Mermaid', () {
    final declaredFirst = parseNativeMermaidStateDiagram('''
stateDiagram-v2
state Check <<choice>>
state Split <<fork>>
state Joiner <<join>>
Check --> Split
Split --> Joiner
''');
    expect(declaredFirst.node('Check')?.shape, 'choice');
    expect(declaredFirst.node('Split')?.shape, 'fork');
    expect(declaredFirst.node('Joiner')?.shape, 'join');

    final edgeFirst = parseNativeMermaidStateDiagram('''
stateDiagram-v2
Check --> Split
state Check <<choice>>
state Split <<fork>>
''');
    expect(edgeFirst.node('Check')?.shape, 'rect');
    expect(edgeFirst.node('Split')?.shape, 'rect');
  });

  test(
    'preserves composite direction, nested state, note, and authored classes',
    () {
      final model = parseNativeMermaidStateDiagram('''
stateDiagram-v2
classDef highlighted fill:rgb(16, 32, 48),stroke:rgba(12, 24, 36, .5),color:#fff
state Composite {
  direction LR
  Idle
  Active
  Idle --> Active
}
Done
note right of Done : working
class Done highlighted
''');

      final composite = model.node('Composite')!;
      expect(composite.isGroup, isTrue);
      expect(composite.direction, 'LR');
      expect(composite.children.map((node) => node.id), ['Idle', 'Active']);
      expect(model.node('Active')?.parentId, 'Composite');
      final noteGroup = model.node('Done----parent')!;
      final note = model.node('Done----note-1')!;
      expect(noteGroup.shape, 'noteGroup');
      expect(noteGroup.noteSide, 'right');
      expect(noteGroup.classes, ['highlighted']);
      expect(note.classes, isEmpty);
      expect(note.noteSide, 'right');
      expect(model.styleClasses['highlighted']?.styles, [
        'fill:rgb(16, 32, 48)',
        'stroke:rgba(12, 24, 36, .5)',
        'color:#fff',
      ]);
      expect(model.styleClasses['highlighted']?.textStyles, ['fill:#fff']);
    },
  );

  test('rejects malformed diagrams and unsupported or invalid styles', () {
    expect(
      () => parseNativeMermaidStateDiagram('stateDiagram\nA --> B'),
      throwsFormatException,
    );
    expect(
      () => parseNativeMermaidStateDiagram('stateDiagram-v2\nA -->'),
      throwsFormatException,
    );
    expect(
      () => parseNativeMermaidStateDiagram(
        'stateDiagram-v2\nclassDef x filter:blur(2px)\nA',
      ),
      throwsFormatException,
    );
    expect(
      () => parseNativeMermaidStateDiagram(
        'stateDiagram-v2\nclassDef x fill:#12345\nA',
      ),
      throwsFormatException,
    );
    expect(
      () => parseNativeMermaidStateDiagram(
        'stateDiagram-v2\nstyle A stroke-width:NaN\nA',
      ),
      throwsFormatException,
    );
  });
}
