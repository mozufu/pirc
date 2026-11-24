import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_render/src/mermaid/block_layout.dart';
import 'package:pirc_render/src/mermaid/block_model.dart';
import 'package:pirc_render/src/mermaid/block_parser.dart';
import 'package:pirc_render/src/mermaid/block_rendering.dart';

void main() {
  late List<Map<String, dynamic>> references;

  setUpAll(() {
    final file = File(
      '../../fixtures/mobile-parity/mermaid-block-beta-reference.json',
    );
    final data = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
    expect(data['sourceVersion'], 'mermaid@11.17.2');
    references = (data['cases'] as List).cast<Map<String, dynamic>>();
  });

  test('parses structures recorded by the pinned Mermaid block parser', () {
    for (final reference in references) {
      final parsed = parseNativeMermaidBlock(reference['source'] as String);
      expect(
        _canonicalDiagram(parsed),
        _canonicalSource(reference['parserAst'] as List),
        reason: reference['id'] as String,
      );
    }
  });

  test(
    'preserves column span, nested columns, and invisible spacing slots',
    () {
      final spans = parseNativeMermaidBlock(
        references.firstWhere(
              (item) => item['id'] == 'spans-and-space',
            )['source']
            as String,
      );
      expect(spans.root.columns, 3);
      final wide = spans.root.children.firstWhere((node) => node.id == 'wide');
      final gap = spans.root.children.firstWhere((node) => node.isSpace);
      expect(wide.widthInColumns, 2);
      expect(gap.spaceCount, 1);

      final nested = parseNativeMermaidBlock(
        references.firstWhere(
              (item) => item['id'] == 'nested-columns',
            )['source']
            as String,
      );
      final group = nested.root.children.first;
      expect(group.isComposite, isTrue);
      expect(group.columns, 2);
      expect(group.children.map((node) => node.id), ['a', 'b']);

      final nestedLayout = layoutNativeMermaidBlock(
        nested,
        width: 390,
        dark: false,
      );
      final boxes = {
        for (final item in nestedLayout.nodes) item.node.id: item.bounds,
      };
      expect(boxes['group'], isNotNull);
      expect(boxes['group']!.contains(boxes['a']!.topLeft), isTrue);
      expect(boxes['group']!.contains(boxes['a']!.bottomRight), isTrue);
      expect(boxes['group']!.contains(boxes['b']!.topLeft), isTrue);
      expect(boxes['group']!.contains(boxes['b']!.bottomRight), isTrue);
    },
  );

  test('rejects unsupported style directives and malformed containers', () {
    expect(
      () => parseNativeMermaidBlock('block-beta\na\nstyle a fill:#fff'),
      throwsFormatException,
    );
    expect(
      () => parseNativeMermaidBlock('block-beta\nblock:group\na'),
      throwsFormatException,
    );
    expect(
      () => parseNativeMermaidBlock('block-beta\nend'),
      throwsFormatException,
    );
    expect(
      () => parseNativeMermaidBlock('block-beta\na[unquoted]'),
      throwsFormatException,
    );
    expect(
      () => parseNativeMermaidBlock(
        'block-beta\n%%{init: {"block":{"padding":12}}}%%',
      ),
      throwsFormatException,
    );
  });

  test('enforces the 50000-character block diagram source limit', () {
    const header = 'block-beta\n';
    final atLimit = header + List.filled(50000 - header.length, ' ').join();
    expect(atLimit.length, 50000);
    expect(parseNativeMermaidBlock(atLimit).root.children, isEmpty);

    expect(() => parseNativeMermaidBlock('$atLimit '), throwsFormatException);
  });

  test('layout uses measured labels, columns, spans, and edge endpoints', () {
    final spans = parseNativeMermaidBlock(
      references.firstWhere((item) => item['id'] == 'spans-and-space')['source']
          as String,
    );
    final spanLayout = layoutNativeMermaidBlock(spans, width: 390, dark: false);
    final boxes = {
      for (final item in spanLayout.nodes) item.node.id: item.bounds,
    };
    expect(boxes['wide']!.width, greaterThan(boxes['tail']!.width));
    expect(spanLayout.viewBoxSize.width, greaterThan(0));
    expect(spanLayout.scale, inInclusiveRange(0, 1));

    final links = parseNativeMermaidBlock(
      references.firstWhere(
            (item) => item['id'] == 'labeled-and-styled-arrows',
          )['source']
          as String,
    );
    final linkLayout = layoutNativeMermaidBlock(links, width: 768, dark: true);
    expect(linkLayout.edges, hasLength(3));
    expect(linkLayout.edges.first.edge.label, 'labeled');
    expect(linkLayout.edges.first.path.getBounds().width, greaterThan(0));
  });

  test('square nodes use Mermaid block horizontal label padding', () {
    final diagram = parseNativeMermaidBlock('block-beta\na["A"]');
    final layout = layoutNativeMermaidBlock(diagram, width: 390, dark: false);
    final label = TextPainter(
      text: const TextSpan(
        text: 'A',
        style: TextStyle(fontSize: 13, letterSpacing: 0),
      ),
      textDirection: TextDirection.ltr,
      textScaler: TextScaler.noScaling,
    )..layout();
    expect(layout.nodes.single.bounds.width, closeTo(label.width + 32, 0.01));
    expect(layout.nodes.single.bounds.height, closeTo(label.height + 16, 0.01));
    label.dispose();
  });

  testWidgets('paint-only block chart renders its data and semantics', (
    tester,
  ) async {
    final diagram = parseNativeMermaidBlock(
      references.firstWhere(
            (item) => item['id'] == 'labeled-and-styled-arrows',
          )['source']
          as String,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Padding(
            padding: const EdgeInsets.all(12),
            child: NativeMermaidBlockChart(diagram: diagram, dark: false),
          ),
        ),
      ),
    );
    expect(
      find.byKey(const ValueKey('native-mermaid-block-chart')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('paints nested composite containers with their child nodes', (
    tester,
  ) async {
    final diagram = parseNativeMermaidBlock(
      references.firstWhere((item) => item['id'] == 'nested-columns')['source']
          as String,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 390,
            child: NativeMermaidBlockChart(diagram: diagram, dark: false),
          ),
        ),
      ),
    );
    expect(
      find.byKey(const ValueKey('native-mermaid-block-chart')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });
}

Map<String, Object?> _canonicalDiagram(NativeMermaidBlockDiagram diagram) => {
  'root': _canonicalNode(diagram.root),
  'edges': diagram.edges.map(_canonicalEdge).toList(),
};

Map<String, Object?> _canonicalNode(NativeMermaidBlockNode node) => {
  'id': node.id,
  'label': node.label,
  'type': node.sourceType,
  'widthInColumns': node.widthInColumns,
  'spaceCount': node.spaceCount,
  'columns': node.columns,
  'children': node.children.map(_canonicalNode).toList(),
};

Map<String, Object?> _canonicalEdge(NativeMermaidBlockEdge edge) => {
  'id': edge.id,
  'start': edge.start,
  'end': edge.end,
  'label': edge.label,
  'thickness': edge.thickness,
  'pattern': edge.pattern,
  'arrowTypeStart': edge.arrowTypeStart,
  'arrowTypeEnd': edge.arrowTypeEnd,
};

Map<String, Object?> _canonicalSource(List<dynamic> raw) {
  final edges = <Map<String, Object?>>[];
  Map<String, Object?> container(List<dynamic> rawItems) {
    var columns = -1;
    final nodes = <Map<String, Object?>>[];
    final indices = <String, int>{};

    void add(Map<String, Object?> item) {
      final id = item['id']! as String;
      final oldIndex = indices[id];
      if (oldIndex == null) {
        indices[id] = nodes.length;
        nodes.add(item);
      } else if (item['type'] != 'na') {
        final old = nodes[oldIndex];
        old['label'] = item['label'];
        old['type'] = item['type'];
      }
    }

    void visit(Object? rawItem) {
      if (rawItem is List) {
        for (final item in rawItem) {
          visit(item);
        }
        return;
      }
      if (rawItem is! Map) return;
      final item = rawItem.cast<String, dynamic>();
      final type = (item['type'] ?? 'na') as String;
      if (type == 'column-setting') {
        columns = item['columns'] as int;
      } else if (type == 'edge') {
        edges.add({
          'id': item['id'],
          'start': item['start'],
          'end': item['end'],
          'label': item['label'] ?? '',
          'thickness': item['thickness'] ?? 'normal',
          'pattern': item['pattern'] ?? 'solid',
          'arrowTypeStart': item['arrowTypeStart'] ?? 'arrow_open',
          'arrowTypeEnd': item['arrowTypeEnd'] ?? '',
        });
      } else if (type == 'composite') {
        final nested = container((item['children'] as List?) ?? const []);
        add({
          'id': item['id'],
          'label': item['label'] ?? '',
          'type': 'composite',
          'widthInColumns': item['widthInColumns'] ?? 1,
          'spaceCount': 0,
          'columns': nested['columns'],
          'children': nested['children'],
        });
      } else if (type == 'space') {
        add({
          'id': item['id'],
          'label': '',
          'type': 'space',
          'widthInColumns': 1,
          'spaceCount': item['width'] ?? 1,
          'columns': -1,
          'children': const [],
        });
      } else {
        final id = item['id'] as String;
        add({
          'id': id,
          'label': item['label'] ?? id,
          'type': type,
          'widthInColumns': item['widthInColumns'] ?? 1,
          'spaceCount': 0,
          'columns': -1,
          'children': const [],
        });
      }
    }

    for (final item in rawItems) {
      visit(item);
    }
    return {'columns': columns, 'children': nodes};
  }

  final root = container(raw);
  return {
    'root': {
      'id': 'root',
      'label': '',
      'type': 'composite',
      'widthInColumns': 1,
      'spaceCount': 0,
      'columns': root['columns'],
      'children': root['children'],
    },
    'edges': edges,
  };
}
