import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_render/src/mermaid/git_graph_model.dart';
import 'package:pirc_render/src/mermaid/git_graph_parser.dart';
import 'package:pirc_render/src/mermaid/git_graph_rendering.dart';

const _fixturePath = '../../fixtures/mobile-parity/mermaid-gitgraph.json';

Map<String, dynamic> _object(Object? value) =>
    (value as Map).cast<String, dynamic>();

List<Map<String, dynamic>> _objects(Object? value) =>
    (value as List).map(_object).toList();

String _directionName(NativeGitGraphDirection direction) => switch (direction) {
  NativeGitGraphDirection.lr => 'lr',
  NativeGitGraphDirection.tb => 'tb',
  NativeGitGraphDirection.bt => 'bt',
};

String _typeName(NativeGitCommitType type) => switch (type) {
  NativeGitCommitType.normal => 'normal',
  NativeGitCommitType.reverse => 'reverse',
  NativeGitCommitType.highlight => 'highlight',
  NativeGitCommitType.merge => 'merge',
  NativeGitCommitType.cherryPick => 'cherryPick',
};

String _normalizedId(String id) {
  final generated = RegExp(r'^(\d+)-[A-Za-z0-9]{7}$').firstMatch(id);
  return generated == null ? id : 'auto:${generated.group(1)}';
}

Map<String, Object?> _actual(NativeGitGraphDiagram diagram) => {
  'direction': _directionName(diagram.direction),
  'currentBranch': diagram.currentBranch,
  'branches': [
    for (final branch in diagram.branches)
      {
        'name': branch.name,
        'order': branch.order,
        'headId': branch.headId == null ? null : _normalizedId(branch.headId!),
      },
  ],
  'commits': [
    for (final commit in diagram.commits)
      {
        'id': _normalizedId(commit.id),
        'message': commit.message,
        'sequence': commit.sequence,
        'type': _typeName(commit.type),
        if (commit.customId) 'customId': true,
        'tags': commit.tags,
        'parents': commit.parents.map(_normalizedId).toList(),
        'branch': commit.branch,
      },
  ],
};

void main() {
  final fixture = _object(jsonDecode(File(_fixturePath).readAsStringSync()));
  final cases = _objects(fixture['cases']);

  test('parser folds pinned Mermaid gitGraph oracle cases', () {
    expect(fixture['webSha'], 'bd3d90981271e1f93cf3d1d1a5bbf9b61136b74c');
    expect(fixture['mermaidVersion'], '11.17.2');
    expect(cases, hasLength(5));

    for (final item in cases) {
      final id = item['id'] as String;
      final diagram = parseNativeMermaidGitGraph(
        item['source'] as String,
        random: Random(73),
      );
      final expected = Map<String, dynamic>.from(item)
        ..remove('id')
        ..remove('source');
      expect(_actual(diagram), expected, reason: id);
    }
  });

  test('generated commit IDs stay stable across source reparses', () {
    const source = 'gitGraph\ncommit\ncommit id: fixed\ncommit';
    final first = parseNativeMermaidGitGraph(source);
    final second = parseNativeMermaidGitGraph(source);

    expect(first.commits.map((commit) => commit.id), [
      for (final commit in second.commits) commit.id,
    ]);
    expect(first.commits[1].id, 'fixed');
    expect(first.commits.first.id, matches(RegExp(r'^0-[A-Za-z0-9]{7}$')));
    expect(first.commits.last.id, matches(RegExp(r'^2-[A-Za-z0-9]{7}$')));
    expect(first.commits.last.parents, ['fixed']);
  });

  test('parser rejects unsupported directives and invalid graph references', () {
    expect(
      () => parseNativeMermaidGitGraph('commit id: a'),
      throwsFormatException,
    );
    expect(
      () =>
          parseNativeMermaidGitGraph('gitGraph\n%%{init: {"theme":"dark"}}%%'),
      throwsFormatException,
    );
    expect(
      () =>
          parseNativeMermaidGitGraph('gitGraph\nbranch feature\nmerge missing'),
      throwsFormatException,
    );
    expect(
      () => parseNativeMermaidGitGraph(
        'gitGraph\ncommit id: root\nbranch feature\n'
        'commit id: source\ncheckout main\ncommit id: base\n'
        'merge feature id: merge\ncherry-pick id: merge',
      ),
      throwsFormatException,
    );
    expect(
      () => parseNativeMermaidGitGraph(
        'gitGraph\ncommit id: root\nbranch feature\n'
        'commit id: source\ncheckout main\ncherry-pick id: source parent: wrong',
      ),
      throwsFormatException,
    );
    expect(
      () => parseNativeMermaidGitGraph('gitGraph\nconfig something'),
      throwsFormatException,
    );
    expect(
      () => parseNativeMermaidGitGraph(
        'gitGraph\ncommit id: repeated\ncommit id: repeated',
      ),
      throwsFormatException,
    );
  });

  test('titles and accessibility text are retained', () {
    final diagram = parseNativeMermaidGitGraph(
      'gitGraph LR:\ntitle Release train\n'
      'accTitle: Delivery history\naccDescr: Branches and merges\n'
      'commit id: c0',
    );
    expect(diagram.title, 'Release train');
    expect(diagram.accessibleTitle, 'Delivery history');
    expect(diagram.accessibleDescription, 'Branches and merges');
  });

  test('layout keeps commit ancestry and branch color assignments', () {
    final branchMerge = cases.firstWhere(
      (item) => item['id'] == 'branch-merge',
    );
    final diagram = parseNativeMermaidGitGraph(branchMerge['source'] as String);
    final light = layoutNativeMermaidGitGraph(diagram, dark: false);
    final dark = layoutNativeMermaidGitGraph(diagram, dark: true);

    expect(light.commits, hasLength(4));
    expect(light.edges, hasLength(4));
    expect(light.branches.map((branch) => branch.branch.name), [
      'main',
      'feature',
    ]);
    expect(
      light.commits.first.center.dx,
      lessThan(light.commits.last.center.dx),
    );
    expect(light.edges.map((edge) => edge.parentId), ['c0', 'c0', 'm1', 'f1']);
    expect(light.branches.first.color, isNot(dark.branches.first.color));
    expect(light.size.width, greaterThan(0));
    expect(light.size.height, greaterThan(0));
    for (final edge in light.edges) {
      expect(edge.path.computeMetrics().single.length, greaterThan(0));
    }
  });

  testWidgets('native graph scales to a narrow viewport', (tester) async {
    final source = '''
gitGraph LR:
  commit id: c0
  commit id: c1
  commit id: c2
  commit id: c3
  commit id: c4
  commit id: c5
  commit id: c6
  commit id: c7
''';
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(240, 500);
    final semantics = tester.ensureSemantics();
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: NativeMermaidGitGraph(
            diagram: parseNativeMermaidGitGraph(source),
            dark: false,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.bySemanticsLabel(RegExp('Commit c0')), findsOneWidget);
    final painter = tester
        .widgetList<CustomPaint>(find.byType(CustomPaint))
        .map((widget) => widget.painter)
        .whereType<NativeGitGraphPainter>()
        .single;
    expect(painter.layout.commits, hasLength(8));
    expect(painter.layout.size.width, greaterThan(240));
    expect(find.byType(SingleChildScrollView), findsNothing);
    expect(tester.getSize(find.byType(NativeMermaidGitGraph)).width, 240);
    semantics.dispose();
  });
  testWidgets('declared GitGraph accessibility metadata reaches the figure', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    final diagram = parseNativeMermaidGitGraph(
      'gitGraph\naccTitle: Delivery history\naccDescr: Branches and merges\ncommit id: "a"',
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: NativeMermaidGitGraph(diagram: diagram, dark: false),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final node = tester.getSemantics(find.bySemanticsLabel('Delivery history'));
    expect(node.label, 'Delivery history');
    expect(node.value, 'Branches and merges');
    expect(tester.takeException(), isNull);
    handle.dispose();
  });
  testWidgets('small GitGraph is centered like the Web Mermaid block', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(768, 500);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: NativeMermaidGitGraph(
            diagram: parseNativeMermaidGitGraph('gitGraph\ncommit id: "a"'),
            dark: false,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final canvas = find.byWidgetPredicate(
      (widget) =>
          widget is CustomPaint && widget.painter is NativeGitGraphPainter,
    );
    expect(canvas, findsOneWidget);
    expect(tester.getCenter(canvas).dx, closeTo(384, .001));
    expect(tester.takeException(), isNull);
  });
}
