import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_render/src/mermaid/mindmap_model.dart';
import 'package:pirc_render/src/mermaid/mindmap_parser.dart';

void main() {
  group('parseNativeMermaidMindmap', () {
    test('uses nearest preceding shallower node for irregular indentation', () {
      final diagram = parseNativeMermaidMindmap(
        'mindmap\n    root\n      first\n          deep\n       irregular',
      );
      expect(diagram.nodes.map((node) => node.id), [0, 1, 2, 3]);
      expect(diagram.root.sourceIndent, 4);
      expect(diagram.root.level, 0);
      expect(diagram.root.childIds, [1]);
      expect(diagram.nodeById(1)!.childIds, [2, 3]);
      expect(diagram.nodeById(2)!.parentId, 1);
      expect(diagram.nodeById(3)!.level, 3);
      expect(diagram.nodeById(3)!.parentId, 1);
    });

    test('counts tabs as one source indentation code unit', () {
      final diagram = parseNativeMermaidMindmap(
        'mindmap\n\troot\n\t\tone\n\t\t\t\tdeep\n\t\t two',
      );
      expect(diagram.nodes.map((node) => node.sourceIndent), [1, 2, 4, 3]);
      expect(diagram.nodes.map((node) => node.level), [0, 1, 3, 2]);
      expect(diagram.nodeById(3)!.parentId, 1);
    });

    test('parses the six explicit node shapes with source ids and labels', () {
      final diagram = parseNativeMermaidMindmap(
        'mindmap\n'
        '  root((Main))\n'
        '    square[Square]\n'
        '    rounded(Rounded)\n'
        '    circle((Circle))\n'
        '    cloud)Cloud(\n'
        '    bang))Bang((\n'
        '    hex{{Hexagon}}',
      );
      expect(diagram.root.shape, NativeMermaidMindmapShape.circle);
      expect(diagram.nodes.skip(1).map((node) => node.shape), [
        NativeMermaidMindmapShape.rectangle,
        NativeMermaidMindmapShape.roundedRectangle,
        NativeMermaidMindmapShape.circle,
        NativeMermaidMindmapShape.cloud,
        NativeMermaidMindmapShape.bang,
        NativeMermaidMindmapShape.hexagon,
      ]);
      expect(diagram.nodes.skip(1).map((node) => node.nodeId), [
        'square',
        'rounded',
        'circle',
        'cloud',
        'bang',
        'hex',
      ]);
      expect(diagram.nodes.skip(1).map((node) => node.label), [
        'Square',
        'Rounded',
        'Circle',
        'Cloud',
        'Bang',
        'Hexagon',
      ]);
    });

    test('uses a shaped label as node id when no id is present', () {
      final node = parseNativeMermaidMindmap(
        'mindmap\n  root\n    [Square]',
      ).nodes.last;
      expect(node.nodeId, 'Square');
      expect(node.label, 'Square');
      expect(node.shape, NativeMermaidMindmapShape.rectangle);
    });

    test('quoted shaped labels may contain shape delimiter characters', () {
      final node = parseNativeMermaidMindmap(
        'mindmap\n  root\n    item["A ) and [bracket]"]',
      ).nodes.last;
      expect(node.nodeId, 'item');
      expect(node.label, 'A ) and [bracket]');
    });

    test(
      'preprocesses leading comments and whitespace before a mixed-case header',
      () {
        final diagram = parseNativeMermaidMindmap(
          '\n%% leading comment\n  MiNdMaP\n  root\n    child',
        );
        expect(diagram.root.nodeId, 'root');
        expect(diagram.root.sourceIndent, 2);
        expect(diagram.root.sourceLine, 4);
        expect(diagram.nodes.last.parentId, diagram.root.id);
      },
    );

    test(
      'joins multiline shaped descriptions and preserves source locations',
      () {
        final diagram = parseNativeMermaidMindmap(
          'mindmap\n'
          '  root\n'
          '    quoted["first line\n'
          '      second line"]\n'
          '      child\n'
          '    ticks["`one\n'
          'two`"]\n'
          '    sibling',
        );

        final quoted = diagram.nodes[1];
        final child = diagram.nodes[2];
        final ticks = diagram.nodes[3];
        final sibling = diagram.nodes[4];
        expect(quoted.label, 'first line\n      second line');
        expect(quoted.nodeId, 'quoted');
        expect(quoted.sourceLine, 3);
        expect(quoted.sourceIndent, 4);
        expect(quoted.level, 2);
        expect(child.nodeId, 'child');
        expect(child.sourceLine, 5);
        expect(child.parentId, quoted.id);
        expect(child.level, 4);
        expect(ticks.label, 'one\ntwo');
        expect(ticks.sourceLine, 6);
        expect(ticks.parentId, diagram.root.id);
        expect(sibling.sourceLine, 8);
        expect(sibling.parentId, diagram.root.id);
      },
    );

    test(
      'ignores comments and blank lines; directives decorate the latest node',
      () {
        final diagram = parseNativeMermaidMindmap(
          '%% leading comment\n'
          'mindmap\n\n'
          '  root\n'
          '  %% comment between nodes\n'
          '    branch\n'
          '      :::critical\n'
          '  ::icon(fa fa-cat)\n'
          '    sibling',
        );
        final branch = diagram.nodeById(1)!;
        expect(branch.className, 'critical');
        expect(branch.icon, 'fa fa-cat');
        expect(diagram.nodeById(2)!.className, isNull);
        expect(diagram.root.childIds, [1, 2]);
      },
    );

    test('retains trailing label whitespace and Markdown text type', () {
      final node = parseNativeMermaidMindmap('mindmap\n  root  ').root;
      expect(node.nodeId, 'root  ');
      expect(node.label, 'root  ');
      expect(node.textType, 'markdown');
      expect(node.labelType, 'markdown');
    });

    test('accepts whitespace after a closed shaped label', () {
      final node = parseNativeMermaidMindmap(
        'mindmap\n  root\n    item[Label]  ',
      ).nodes.last;
      expect(node.nodeId, 'item');
      expect(node.label, 'Label');
    });

    test('sanitizes unsafe markup while retaining allowed inline HTML', () {
      final node = parseNativeMermaidMindmap(
        'mindmap\n  root\n'
        '    item["<script>drop</script><b class=kept onclick=bad>safe</b>"]',
      ).nodes.last;
      expect(node.label, '<b class="kept">safe</b>');
    });

    test('assigns and inherits Mermaid root-branch section indices', () {
      final branches = List.generate(
        13,
        (index) => '    branch$index',
      ).join('\n');
      final diagram = parseNativeMermaidMindmap('mindmap\n  root\n$branches');
      expect(diagram.root.sectionIndex, isNull);
      expect(diagram.nodes.skip(1).map((node) => node.sectionIndex), [
        0,
        1,
        2,
        3,
        4,
        5,
        6,
        7,
        8,
        9,
        10,
        0,
        1,
      ]);

      final nested = parseNativeMermaidMindmap(
        'mindmap\n  root\n    left\n      left child\n    right\n      right child',
      );
      expect(nested.nodes.map((node) => node.sectionIndex), [null, 0, 0, 1, 1]);
    });

    test('rejects multiple roots, malformed shapes, and empty diagrams', () {
      expect(
        () => parseNativeMermaidMindmap('mindmap\n  root\nsecond'),
        throwsFormatException,
      );
      expect(
        () => parseNativeMermaidMindmap('mindmap\n  root\n    item[]'),
        throwsFormatException,
      );
      expect(
        () => parseNativeMermaidMindmap('mindmap\n  root\n    item[label'),
        throwsFormatException,
      );
      expect(() => parseNativeMermaidMindmap('mindmap'), throwsFormatException);
    });

    test('rejects unsupported configuration and frontmatter explicitly', () {
      expect(
        () => parseNativeMermaidMindmap(
          '%%{init: {"theme":"dark"}}%%\nmindmap\n  root',
        ),
        throwsFormatException,
      );
      expect(
        () => parseNativeMermaidMindmap(
          '---\ntitle: unsupported\n---\nmindmap\n  root',
        ),
        throwsFormatException,
      );
    });

    test('requires a root node and rejects trailing header whitespace', () {
      expect(
        () => parseNativeMermaidMindmap('mindmap  \n  root'),
        throwsFormatException,
      );
      expect(
        () =>
            parseNativeMermaidMindmap('%% comment\nmindmap\n  %% only comment'),
        throwsFormatException,
      );
    });

    test('enforces the processed 50000 character limit', () {
      final limitLabel = List.filled(49992, 'x').join();
      final overLimitLabel = List.filled(49993, 'x').join();
      final removedComment = List.filled(50001, 'x').join();
      final atLimit = parseNativeMermaidMindmap('mindmap\n$limitLabel');
      expect(atLimit.root.label.length, 49992);
      final crlfAtLimit = parseNativeMermaidMindmap('mindmap\r\n$limitLabel');
      expect(crlfAtLimit.root.label.length, 49992);
      expect(
        () => parseNativeMermaidMindmap('mindmap\n$overLimitLabel'),
        throwsFormatException,
      );

      final longComment = '%%$removedComment\nmindmap\nroot';
      expect(parseNativeMermaidMindmap(longComment).root.nodeId, 'root');
    });

    test('does not impose a node limit below Mermaid source limits', () {
      final children = List.filled(10000, '  a').join('\n');
      final diagram = parseNativeMermaidMindmap('mindmap\nroot\n$children');
      expect(diagram.nodes, hasLength(10001));
      expect(diagram.root.childIds, hasLength(10000));
    });
  });
}
