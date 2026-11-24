import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_render/src/mermaid/architecture_model.dart';
import 'package:pirc_render/src/mermaid/architecture_parser.dart';
import 'package:pirc_render/src/mermaid/architecture_rendering.dart';

Map<String, dynamic> _map(Object? value) =>
    Map<String, dynamic>.from(value! as Map);

String _iconName(NativeMermaidArchitectureIcon? icon) => switch (icon) {
  NativeMermaidArchitectureIcon.cloud => 'cloud',
  NativeMermaidArchitectureIcon.database => 'database',
  NativeMermaidArchitectureIcon.disk => 'disk',
  NativeMermaidArchitectureIcon.internet => 'internet',
  NativeMermaidArchitectureIcon.server => 'server',
  null => '',
};

String _directionCode(NativeMermaidArchitectureDirection direction) =>
    switch (direction) {
      NativeMermaidArchitectureDirection.left => 'L',
      NativeMermaidArchitectureDirection.right => 'R',
      NativeMermaidArchitectureDirection.top => 'T',
      NativeMermaidArchitectureDirection.bottom => 'B',
    };

void main() {
  final oracle = _map(
    jsonDecode(
      File(
        '../../fixtures/mobile-parity/mermaid-architecture-oracle.json',
      ).readAsStringSync(),
    ),
  );
  final cases = (oracle['cases'] as List).map(_map).toList();

  test('matches the pinned Mermaid architecture parser and database', () {
    expect(oracle['webRevision'], 'bd3d90981271e1f93cf3d1d1a5bbf9b61136b74c');
    expect(oracle['mermaidVersion'], '11.17.2');
    expect(cases, hasLength(3));

    for (final item in cases) {
      final diagram = parseNativeMermaidArchitecture(item['source'] as String);
      final db = _map(item['db']);
      expect(
        [
          for (final group in diagram.groups)
            {
              'id': group.id,
              'icon': _iconName(group.icon),
              if (group.title != null) 'title': group.title,
              if (group.parentId != null) 'in': group.parentId,
            },
        ],
        db['groups'],
        reason: item['id'] as String,
      );
      expect(
        [
          for (final service in diagram.services)
            {
              'id': service.id,
              'icon': _iconName(service.icon),
              'title': service.title,
              if (service.parentId != null) 'in': service.parentId,
            },
        ],
        [
          for (final raw in db['services'] as List)
            {
              'id': _map(raw)['id'],
              'icon': _map(raw)['icon'],
              'title': _map(raw)['title'],
              if (_map(raw).containsKey('in')) 'in': _map(raw)['in'],
            },
        ],
        reason: item['id'] as String,
      );
      expect(
        diagram.junctions.map((junction) => junction.id).toList(),
        (db['junctions'] as List).map((raw) => _map(raw)['id']).toList(),
        reason: item['id'] as String,
      );
      expect(
        [
          for (final edge in diagram.edges)
            {
              'lhsId': edge.sourceId,
              'lhsDir': _directionCode(edge.sourceDirection),
              'lhsInto': edge.sourceInto,
              'lhsGroup': edge.sourceGroup,
              'rhsId': edge.targetId,
              'rhsDir': _directionCode(edge.targetDirection),
              'rhsInto': edge.targetInto,
              'rhsGroup': edge.targetGroup,
            },
        ],
        [
          for (final raw in db['edges'] as List)
            {for (final entry in _map(raw).entries) entry.key: entry.value},
        ],
        reason: item['id'] as String,
      );
    }
  });

  test(
    'keeps service, junction, group, and edge topology in native layout',
    () {
      for (final item in cases) {
        final diagram = parseNativeMermaidArchitecture(
          item['source'] as String,
        );
        final layout = layoutNativeMermaidArchitecture(
          diagram,
          width: 720,
          dark: false,
        );

        expect(layout.nodes.map((node) => node.id), diagram.nodeIds);
        expect(layout.groups.map((group) => group.id), [
          for (final group in diagram.groups) group.id,
        ]);
        expect(layout.edges, hasLength(diagram.edges.length));
        expect(layout.viewBox.width, greaterThan(0));
        expect(layout.viewBox.height, greaterThan(0));
        for (final node in layout.nodes) {
          expect(layout.viewBox.contains(node.bounds.topLeft), isTrue);
          expect(layout.viewBox.contains(node.bounds.bottomRight), isTrue);
          if (!node.isJunction) expect(node.labelPainter, isNotNull);
        }
        for (final edge in layout.edges) {
          expect(edge.path.computeMetrics().single.length, greaterThan(0));
          expect(edge.sourceId, isNotEmpty);
          expect(edge.targetId, isNotEmpty);
        }

        switch (item['id']) {
          case 'architecture-services':
            final web = layout.nodeById('web')!;
            final database = layout.nodeById('db')!;
            final api = layout.groupById('api')!;
            expect(web.center.dx, lessThan(database.center.dx));
            expect(api.bounds.contains(web.bounds.topLeft), isTrue);
            expect(api.bounds.contains(database.bounds.bottomRight), isTrue);
            expect(layout.edges.single.targetInto, isTrue);
            break;
          case 'architecture-junction':
            final client = layout.nodeById('client')!;
            final fanout = layout.nodeById('fanout')!;
            final cache = layout.nodeById('cache')!;
            expect(fanout.isJunction, isTrue);
            expect(client.center.dx, lessThan(fanout.center.dx));
            expect(fanout.center.dy, lessThan(cache.center.dy));
            break;
          case 'architecture-nested':
            final outer = layout.groupById('outer')!;
            final inner = layout.groupById('inner')!;
            final app = layout.nodeById('app')!;
            final external = layout.nodeById('ext')!;
            final edge = layout.edges.single;
            expect(outer.bounds.contains(inner.bounds.topLeft), isTrue);
            expect(outer.bounds.contains(inner.bounds.bottomRight), isTrue);
            expect(inner.bounds.contains(app.bounds.topLeft), isTrue);
            expect(inner.bounds.contains(app.bounds.bottomRight), isTrue);
            expect(edge.edge.sourceGroup, isTrue);
            expect(edge.start.dx, closeTo(inner.bounds.right + 2, 0.001));
            expect(edge.start.dx, lessThan(external.center.dx));
            break;
        }
      }
    },
  );

  test(
    'preserves labels containing comment markers and arrow endpoint flags',
    () {
      final diagram = parseNativeMermaidArchitecture('''
architecture-beta
group api(cloud)[API %% zone] %% comment after the declaration
service web(server)[Web %% tier] in api
service db(database)[Database] in api
web:R >-- L:db
db:L --< R:web
web:T <--> B:db
''');

      expect(diagram.groups.single.title, 'API %% zone');
      expect(diagram.serviceById('web')!.title, 'Web %% tier');
      expect(diagram.edges, hasLength(3));
      expect(diagram.edges[0].sourceInto, isTrue);
      expect(diagram.edges[0].targetInto, isFalse);
      expect(diagram.edges[1].sourceInto, isFalse);
      expect(diagram.edges[1].targetInto, isTrue);
      expect(diagram.edges[2].sourceInto, isTrue);
      expect(diagram.edges[2].targetInto, isTrue);
    },
  );

  test('wraps complete long service and group labels inside their bounds', () {
    final serviceLabel = List.filled(18, 'service label content').join(' ');
    final groupLabel = List.filled(
      20,
      'regional network description',
    ).join(' ');
    final source =
        'architecture-beta\n'
        'group api(cloud)[$groupLabel]\n'
        'service gateway(server)[$serviceLabel] in api\n'
        'service database(database)[Database] in api\n'
        'gateway:B --> T:database';
    final diagram = parseNativeMermaidArchitecture(source);
    final layout = layoutNativeMermaidArchitecture(
      diagram,
      width: 390,
      dark: false,
    );
    final gateway = layout.nodeById('gateway')!;
    final api = layout.groupById('api')!;
    final serviceLabelLayout = gateway.labelPainter!;
    final groupLabelLayout = api.titlePainter!;

    expect(serviceLabelLayout.didExceedMaxLines, isFalse);
    expect(groupLabelLayout.didExceedMaxLines, isFalse);
    expect(serviceLabelLayout.height, greaterThan(16));
    expect(groupLabelLayout.height, greaterThan(38));
    expect(gateway.bounds.left, lessThanOrEqualTo(gateway.labelBounds!.left));
    expect(gateway.bounds.top, lessThanOrEqualTo(gateway.labelBounds!.top));
    expect(
      gateway.bounds.right,
      greaterThanOrEqualTo(gateway.labelBounds!.right),
    );
    expect(
      gateway.bounds.bottom,
      greaterThanOrEqualTo(gateway.labelBounds!.bottom),
    );
    expect(api.bounds.left, lessThanOrEqualTo(api.titleBounds!.left));
    expect(api.bounds.top, lessThanOrEqualTo(api.titleBounds!.top));
    expect(api.bounds.right, greaterThanOrEqualTo(api.titleBounds!.right));
    expect(api.bounds.bottom, greaterThanOrEqualTo(api.titleBounds!.bottom));
    expect(api.bounds.contains(gateway.bounds.topLeft), isTrue);
    expect(api.bounds.contains(gateway.bounds.bottomRight), isTrue);
    expect(
      layout.nodeById('database')!.center.dy,
      greaterThan(gateway.center.dy),
    );
  });

  test('keeps declared column members in top-to-bottom source order', () {
    final diagram = parseNativeMermaidArchitecture('''
architecture-beta
service first(server)[First]
service second(server)[Second]
service third(server)[Third]
align column first second third
''');
    final layout = layoutNativeMermaidArchitecture(
      diagram,
      width: 390,
      dark: false,
    );

    expect(
      layout.nodeById('first')!.center.dy,
      lessThan(layout.nodeById('second')!.center.dy),
    );
    expect(
      layout.nodeById('second')!.center.dy,
      lessThan(layout.nodeById('third')!.center.dy),
    );
  });

  test('rejects invalid references, duplicate IDs, unsupported config and icons', () {
    final invalidCases = (oracle['invalidCases'] as List).map(_map);
    for (final item in invalidCases) {
      expect(
        () => parseNativeMermaidArchitecture(item['source'] as String),
        throwsFormatException,
        reason: item['id'] as String,
      );
    }
    for (final source in [
      'architecture-beta\n%%{init: {"theme":"dark"}}%%',
      'architecture-beta\ngroup custom(foo)[Custom]',
      'architecture-beta\ngroup custom(fa:fa-cloud)[Custom]',
      'architecture-beta\ngroup api(cloud)[API]\nservice web(server)[Web] in missing',
      'architecture-beta\nservice web(server)[Web]\nweb:R --> L:missing',
      'architecture-beta\nservice web(server)[Web]\nservice web(disk)[Again]',
      'architecture-beta\ngroup first(cloud)[First] in second\ngroup second(server)[Second] in first',
      'architecture-beta\ngroup api(cloud)[API]\nservice web(server)[Web] in api\nweb:R --> L:api',
    ]) {
      expect(
        () => parseNativeMermaidArchitecture(source),
        throwsFormatException,
        reason: source,
      );
    }
  });

  test('enforces the bounded node limit', () {
    final source = [
      'architecture-beta',
      for (var index = 0; index < 201; index++)
        'service node$index(server)[Node $index]',
    ].join('\n');
    expect(() => parseNativeMermaidArchitecture(source), throwsFormatException);
  });

  testWidgets('paints semantic groups, service icons, junctions, and edges', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    final diagram = parseNativeMermaidArchitecture(
      cases.firstWhere(
            (item) => item['id'] == 'architecture-junction',
          )['source']
          as String,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 390,
            child: NativeMermaidArchitecture(diagram: diagram, dark: false),
          ),
        ),
      ),
    );

    expect(
      find.byKey(const ValueKey('native-mermaid-architecture-chart')),
      findsOneWidget,
    );
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is CustomPaint &&
            widget.painter is NativeMermaidArchitecturePainter,
      ),
      findsOneWidget,
    );
    expect(
      find.bySemanticsLabel(RegExp(r'Client.*Cache.*fanout')),
      findsOneWidget,
    );
    semantics.dispose();
  });
}
