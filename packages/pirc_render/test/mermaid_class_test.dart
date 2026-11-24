import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_render/src/mermaid/class_diagram.dart';

void main() {
  test('lays out class boxes with measured member rows and direction', () {
    final graph = parseNativeMermaidClassDiagram('''
classDiagram
Animal <|-- Dog
Animal : +String name
Animal : +int age
Dog : +bark() void
''');
    final layout = layoutNativeMermaidClassDiagram(graph, fontFamily: 'Arial');
    final animal = layout.boundsForClass('Animal')!;
    final dog = layout.boundsForClass('Dog')!;

    expect(animal.height, closeTo(130.5, 0.1));
    expect(dog.height, closeTo(117, 0.1));
    expect(animal.center.dx, closeTo(dog.center.dx, 0.1));
    expect(animal.bottom, lessThan(dog.top));
    expect(layout.edges, hasLength(1));
    expect(
      layout.edges.single.path.computeMetrics().single.length,
      greaterThan(0),
    );
    expect(layout.size.height, closeTo(313.5, 0.1));
  });

  test('keeps disconnected classes in reading order and lays out LR edges', () {
    final disconnected = parseNativeMermaidClassDiagram('''
classDiagram
class Repository~T~
class User
''');
    final vertical = layoutNativeMermaidClassDiagram(
      disconnected,
      fontFamily: 'Arial',
    );
    expect(
      vertical.boundsForClass('Repository')!.center.dy,
      lessThan(vertical.boundsForClass('User')!.center.dy),
    );

    final horizontal = parseNativeMermaidClassDiagram('''
classDiagram
direction LR
class Customer
class Order
Customer "1" --> "0..*" Order : places
''');
    final horizontalLayout = layoutNativeMermaidClassDiagram(
      horizontal,
      fontFamily: 'Arial',
    );
    final customer = horizontalLayout.boundsForClass('Customer')!;
    final order = horizontalLayout.boundsForClass('Order')!;
    expect(customer.center.dx, lessThan(order.center.dx));
    expect(horizontalLayout.size.height, closeTo(95.5, 0.1));
    expect(horizontalLayout.edges.single.relation.startMultiplicity, '1');
    expect(horizontalLayout.edges.single.relation.endMultiplicity, '0..*');
  });

  test('keeps namespace members together on their local horizontal rank', () {
    final graph = parseNativeMermaidClassDiagram('''
classDiagram
namespace Accounts {
  class User
  class Session
}
User "1" --> "0..*" Session : owns
''');
    final layout = layoutNativeMermaidClassDiagram(graph, fontFamily: 'Arial');
    final user = layout.boundsForClass('User')!;
    final session = layout.boundsForClass('Session')!;
    final group = layout.namespaces.single.bounds;

    expect(user.center.dx, lessThan(session.center.dx));
    expect(user.center.dy, closeTo(session.center.dy, 0.1));
    expect(group.contains(user.topLeft), isTrue);
    expect(group.contains(session.bottomRight), isTrue);
  });

  test(
    'cycle condensation produces finite distinct boxes and connector paths',
    () {
      final graph = parseNativeMermaidClassDiagram('''
classDiagram
A --> B
B *-- C
C ..> A
''');
      final layout = layoutNativeMermaidClassDiagram(
        graph,
        fontFamily: 'Arial',
      );

      expect(layout.size.width.isFinite, isTrue);
      expect(layout.size.height.isFinite, isTrue);
      expect(layout.nodes, hasLength(3));
      expect(layout.edges, hasLength(3));
      expect(
        layout.edges.every(
          (edge) =>
              edge.path.computeMetrics().every((metric) => metric.length > 0),
        ),
        isTrue,
      );
    },
  );

  testWidgets('paints a semantic native class diagram', (tester) async {
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 390,
            child: NativeMermaidClassDiagram(
              source: '''
classDiagram
class User {
  +String id
  +authenticate(password: String) bool
}
User ..> Account : validates
''',
              dark: false,
            ),
          ),
        ),
      ),
    );

    expect(
      find.byKey(const ValueKey('native-mermaid-class-diagram')),
      findsOneWidget,
    );
    expect(
      find.bySemanticsLabel(RegExp(r'Class diagram.*User.*Account.*validates')),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('native-mermaid-class-diagram')),
        matching: find.byType(CustomPaint),
      ),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
    semantics.dispose();
  });

  test('fails closed on unsupported syntax', () {
    expect(
      () => parseNativeMermaidClassDiagram('''
classDiagram
class A
click A "https://example.com"
'''),
      throwsFormatException,
    );
    expect(
      () => parseNativeMermaidClassDiagram('''
classDiagram
A <|--
'''),
      throwsFormatException,
    );
  });
}
