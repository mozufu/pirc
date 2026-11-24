import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_render/src/mermaid/er_diagram.dart';

void main() {
  test('preserves semicolons inside quoted ER labels and comments', () {
    final diagram = parseNativeMermaidErDiagram('''
erDiagram
"Customer; Account" {
  string id "primary; identifier;"
}
o["Order; Line"]
"Customer; Account" ||--o{ o : "contains; lines;"
''');

    final customer = diagram.entities.firstWhere(
      (entity) => entity.name == 'Customer; Account',
    );
    final order = diagram.entities.firstWhere((entity) => entity.name == 'o');
    expect(customer.attributes.single.comment, 'primary; identifier;');
    expect(order.alias, 'Order; Line');
    expect(order.displayLabel, 'Order; Line');
    expect(diagram.relationships.single.roleA, 'contains; lines;');
  });

  test('does not treat quoted semicolons as statement separators', () {
    final diagram = parseNativeMermaidErDiagram('''
erDiagram
A ||--|| B : "role; text;"
''');
    expect(diagram.relationships.single.roleA, 'role; text;');
  });

  test(
    'rejects outside-quote semicolon separators the pinned parser rejects',
    () {
      expect(
        () => parseNativeMermaidErDiagram('''
erDiagram
A;
'''),
        throwsFormatException,
      );
      expect(
        () => parseNativeMermaidErDiagram('''
erDiagram
A ||--|| B : "role; text";
'''),
        throwsFormatException,
      );
      expect(
        () => parseNativeMermaidErDiagram('''
erDiagram
A {
  string id "comment; text";
}
'''),
        throwsFormatException,
      );
    },
  );

  test('rejects unclosed quoted entity, relationship, and attribute text', () {
    for (final source in <String>[
      '''
erDiagram
"Customer; Account ||--|| B
''',
      '''
erDiagram
A ||--|| B : "unfinished;
''',
      '''
erDiagram
A {
  string id "unfinished;
}
''',
    ]) {
      expect(() => parseNativeMermaidErDiagram(source), throwsFormatException);
    }
  });

  test('fails closed on styling statements outside native parser coverage', () {
    expect(
      () => parseNativeMermaidErDiagram('''
erDiagram
A
style A fill:#fff
'''),
      throwsFormatException,
    );
    expect(
      () => parseNativeMermaidErDiagram('''
erDiagram
A
class A important
'''),
      throwsFormatException,
    );
  });
}
