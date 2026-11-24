import '../render_l10n.dart';
// Native, bounded Mermaid 11.17.2 gitGraph renderer.
// Upstream source is MIT licensed; see MERMAID_MIT_LICENSE.txt.
import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'git_graph_model.dart';

const _gitColorsLight = <(double, double, double)>[
  (218.8235294118, 89.4736842105, 71.2745098039),
  (210, 16.6666666667, 70.2941176471),
  (210, 20, 73.0392156863),
  (188.8235294118, 89.4736842105, 71.2745098039),
  (158.8235294118, 89.4736842105, 71.2745098039),
  (128.8235294118, 89.4736842105, 71.2745098039),
  (278.8235294118, 89.4736842105, 71.2745098039),
  (338.8235294118, 89.4736842105, 71.2745098039),
];
const _gitColorsDark = <(double, double, double)>[
  (180, 1.5873015873, 48.3529411765),
  (321.6393442623, 65.5913978495, 38.2352941176),
  (194.4, 16.5562913907, 49.6078431373),
  (23.0769230769, 49.0566037736, 40.7843137255),
  (0, 83.3333333333, 43.5294117647),
  (289.1666666667, 100, 24.1176470588),
  (35.1315789474, 98.7012987013, 40.1960784314),
  (106.1538461538, 84.4155844156, 35.0980392157),
];

Color _branchColor(int index, bool dark) {
  final values = (dark ? _gitColorsDark : _gitColorsLight)[index % 8];
  return HSLColor.fromAHSL(
    1,
    values.$1,
    values.$2 / 100,
    values.$3 / 100,
  ).toColor();
}

class NativeGitGraphBranchLayout {
  const NativeGitGraphBranchLayout({
    required this.branch,
    required this.index,
    required this.position,
    required this.labelBounds,
    required this.color,
  });

  final NativeGitGraphBranch branch;
  final int index;
  final Offset position;
  final Rect labelBounds;
  final Color color;
}

class NativeGitGraphCommitLayout {
  const NativeGitGraphCommitLayout({
    required this.commit,
    required this.center,
    required this.branchIndex,
    required this.idSize,
    required this.color,
  });

  final NativeGitGraphCommit commit;
  final Offset center;
  final int branchIndex;
  final Size idSize;
  final Color color;
}

class NativeGitGraphEdgeLayout {
  const NativeGitGraphEdgeLayout({
    required this.parentId,
    required this.childId,
    required this.path,
    required this.color,
  });

  final String parentId;
  final String childId;
  final Path path;
  final Color color;
}

class NativeGitGraphLayout {
  NativeGitGraphLayout({
    required this.diagram,
    required this.size,
    required Iterable<NativeGitGraphBranchLayout> branches,
    required Iterable<NativeGitGraphCommitLayout> commits,
    required Iterable<NativeGitGraphEdgeLayout> edges,
    required Iterable<Path> branchSpines,
    required this.titleStyle,
    required this.branchStyle,
    required this.commitLabelStyle,
    required this.tagStyle,
    required this.dark,
  }) : branches = List.unmodifiable(branches),
       commits = List.unmodifiable(commits),
       edges = List.unmodifiable(edges),
       branchSpines = List.unmodifiable(branchSpines);

  final NativeGitGraphDiagram diagram;
  final Size size;
  final List<NativeGitGraphBranchLayout> branches;
  final List<NativeGitGraphCommitLayout> commits;
  final List<NativeGitGraphEdgeLayout> edges;
  final List<Path> branchSpines;
  final TextStyle titleStyle;
  final TextStyle branchStyle;
  final TextStyle commitLabelStyle;
  final TextStyle tagStyle;
  final bool dark;

  NativeGitGraphCommitLayout? commitPosition(String id) {
    for (final item in commits) {
      if (item.commit.id == id) return item;
    }
    return null;
  }
}

/// Layout for Mermaid 11.17.2's classic gitGraph renderer. Commit sequence
/// spacing, branch lanes, type glyphs and parent edges come from its renderer.
/// Fixed SVG text sizes are intentionally independent of Flutter text scaling.
NativeGitGraphLayout layoutNativeMermaidGitGraph(
  NativeGitGraphDiagram diagram, {
  required bool dark,
  String? fontFamily,
}) {
  const branchFontSize = 13.0;
  const idFontSize = 10.0;
  const tagFontSize = 10.0;
  const titleFontSize = 18.0;
  const layoutOffset = 10.0;
  const commitStep = 40.0;
  const branchGap = 50.0;
  const padding = 8.0;
  final vertical = diagram.direction != NativeGitGraphDirection.lr;
  final titleStyle = TextStyle(
    fontFamily: fontFamily,
    fontSize: titleFontSize,
    height: kTextHeightNone,
    fontWeight: FontWeight.w400,
    color: dark ? const Color(0xffcccccc) : const Color(0xff0f1115),
  );
  final branchStyle = TextStyle(
    fontFamily: fontFamily,
    fontSize: branchFontSize,
    height: kTextHeightNone,
    color: dark ? const Color(0xffcccccc) : const Color(0xff0f1115),
  );
  final commitLabelStyle = TextStyle(
    fontFamily: fontFamily,
    fontSize: idFontSize,
    height: kTextHeightNone,
    color: dark ? const Color(0xffb7b5b5) : const Color(0xff0e0c0a),
  );
  final tagStyle = TextStyle(
    fontFamily: fontFamily,
    fontSize: tagFontSize,
    height: kTextHeightNone,
    color: dark ? const Color(0xffe0dfdf) : const Color(0xff0f1115),
  );

  Size measure(String text, TextStyle style) {
    final painter = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: TextDirection.ltr,
      textScaler: TextScaler.noScaling,
    )..layout();
    final result = painter.size;
    painter.dispose();
    return result;
  }

  final branchWidths = <String, double>{};
  for (final branch in diagram.branches) {
    branchWidths[branch.name] = measure(branch.name, branchStyle).width;
  }
  final branchRawPositions = <String, double>{};
  var branchCursor = 0.0;
  for (final branch in diagram.branches) {
    branchRawPositions[branch.name] = branchCursor;
    branchCursor +=
        branchGap + 40 + (vertical ? (branchWidths[branch.name] ?? 0) / 2 : 0);
  }

  final sortedCommits = [...diagram.commits]
    ..sort((a, b) => a.sequence.compareTo(b.sequence));
  if (diagram.direction == NativeGitGraphDirection.bt) {
    sortedCommits.sort((a, b) => b.sequence.compareTo(a.sequence));
  }
  final rawCenters = <String, Offset>{};
  var commitCursor = vertical ? 30.0 : 0.0;
  var maxPosition = 0.0;
  for (final commit in sortedCommits) {
    final branchPosition = branchRawPositions[commit.branch];
    if (branchPosition == null) {
      throw FormatException(tr("Missing branch for commit {0}", [commit.id]));
    }
    final withOffset = commitCursor + layoutOffset;
    rawCenters[commit.id] = vertical
        ? Offset(branchPosition, withOffset)
        : Offset(withOffset, branchPosition - 2);
    commitCursor += commitStep + layoutOffset;
    maxPosition = math.max(maxPosition, commitCursor);
  }

  final rawBranchRects = <String, Rect>{};
  for (final branch in diagram.branches) {
    final lane = branchRawPositions[branch.name] ?? 0;
    final labelSize = measure(branch.name, branchStyle);
    rawBranchRects[branch.name] = vertical
        ? Rect.fromLTWH(
            lane - labelSize.width / 2 - 10,
            diagram.direction == NativeGitGraphDirection.tb ? -20 : maxPosition,
            labelSize.width + 20,
            labelSize.height + 8,
          )
        : Rect.fromLTWH(
            -labelSize.width - 18,
            lane - labelSize.height / 2 - 8,
            labelSize.width + 18,
            labelSize.height + 16,
          );
  }

  var rawBounds = Rect.zero;
  var hasBounds = false;
  void include(Rect rect) {
    rawBounds = hasBounds ? rawBounds.expandToInclude(rect) : rect;
    hasBounds = true;
  }

  for (final rect in rawBranchRects.values) {
    include(rect);
  }
  final rawSpines = <Path>[];
  for (final branch in diagram.branches) {
    final lane = branchRawPositions[branch.name] ?? 0;
    final spine = Path();
    if (diagram.direction == NativeGitGraphDirection.lr) {
      spine
        ..moveTo(0, lane - 2)
        ..lineTo(maxPosition, lane - 2);
      include(Rect.fromLTRB(0, lane - 4, maxPosition, lane));
    } else if (diagram.direction == NativeGitGraphDirection.tb) {
      spine
        ..moveTo(lane, 30)
        ..lineTo(lane, maxPosition);
      include(Rect.fromLTRB(lane - 1, 30, lane + 1, maxPosition));
    } else {
      spine
        ..moveTo(lane, maxPosition)
        ..lineTo(lane, 30);
      include(Rect.fromLTRB(lane - 1, 30, lane + 1, maxPosition));
    }
    rawSpines.add(spine);
  }

  for (final commit in diagram.commits) {
    final center = rawCenters[commit.id]!;
    include(Rect.fromCircle(center: center, radius: 11));
    final idSize = measure(commit.id, commitLabelStyle);
    if (commit.type != NativeGitCommitType.cherryPick &&
        (commit.type != NativeGitCommitType.merge || commit.customId)) {
      include(
        Rect.fromCenter(
          center: center + Offset(0, idSize.height + 20),
          width: idSize.width + 12,
          height: idSize.height + 12,
        ),
      );
    }
    if (commit.tags.isNotEmpty) {
      include(
        Rect.fromLTWH(
          center.dx - 90,
          center.dy - 28 - commit.tags.length * 20,
          180,
          commit.tags.length * 20 + 8,
        ),
      );
    }
  }

  if (diagram.title.isNotEmpty) {
    final size = measure(diagram.title, titleStyle);
    include(
      Rect.fromLTWH(
        -size.width / 2,
        rawBounds.top - size.height - 30,
        size.width,
        size.height + 25,
      ),
    );
  }
  if (!hasBounds) rawBounds = const Rect.fromLTWH(0, 0, 1, 1);
  final shift = Offset(padding - rawBounds.left, padding - rawBounds.top);
  final size = Size(
    rawBounds.width + padding * 2,
    rawBounds.height + padding * 2,
  );

  final branchLayouts = <NativeGitGraphBranchLayout>[];
  for (var index = 0; index < diagram.branches.length; index++) {
    final branch = diagram.branches[index];
    final lane = branchRawPositions[branch.name] ?? 0;
    branchLayouts.add(
      NativeGitGraphBranchLayout(
        branch: branch,
        index: index,
        position: (vertical ? Offset(lane, 0) : Offset(0, lane - 2)) + shift,
        labelBounds: rawBranchRects[branch.name]!.shift(shift),
        color: _branchColor(index, dark),
      ),
    );
  }
  final branchIndices = <String, int>{
    for (var index = 0; index < diagram.branches.length; index++)
      diagram.branches[index].name: index,
  };
  final commitLayouts = <NativeGitGraphCommitLayout>[
    for (final commit in diagram.commits)
      NativeGitGraphCommitLayout(
        commit: commit,
        center: rawCenters[commit.id]! + shift,
        branchIndex: branchIndices[commit.branch] ?? 0,
        idSize: measure(commit.id, commitLabelStyle),
        color: _branchColor(branchIndices[commit.branch] ?? 0, dark),
      ),
  ];
  final shiftedCenters = <String, Offset>{
    for (final entry in rawCenters.entries) entry.key: entry.value + shift,
  };
  final edgeLayouts = <NativeGitGraphEdgeLayout>[];
  final occupiedLanes = <double>[
    for (final branch in diagram.branches)
      (branchRawPositions[branch.name] ?? 0) + (vertical ? 0 : -2),
  ];
  for (final child in diagram.commits) {
    for (
      var parentIndex = 0;
      parentIndex < child.parents.length;
      parentIndex++
    ) {
      final parentId = child.parents[parentIndex];
      final parent = diagram.commitById(parentId);
      final start = shiftedCenters[parentId];
      final end = shiftedCenters[child.id];
      if (parent == null || start == null || end == null) {
        throw FormatException(
          tr("GitGraph commit parent is missing: {0}", [parentId]),
        );
      }
      final reroute = _shouldReroute(
        parent,
        child,
        diagram.commits,
        shiftedCenters,
        vertical,
      );
      final rawPath = _edgePath(
        start,
        end,
        vertical: vertical,
        reroute: reroute,
        occupiedLanes: occupiedLanes,
      );
      final colorBranch =
          child.type == NativeGitCommitType.merge && parentIndex > 0
          ? parent.branch
          : child.branch;
      final colorIndex = branchIndices[colorBranch] ?? 0;
      edgeLayouts.add(
        NativeGitGraphEdgeLayout(
          parentId: parentId,
          childId: child.id,
          path: rawPath,
          color: _branchColor(colorIndex, dark),
        ),
      );
    }
  }

  return NativeGitGraphLayout(
    diagram: diagram,
    size: size,
    branches: branchLayouts,
    commits: commitLayouts,
    edges: edgeLayouts,
    branchSpines: [for (final path in rawSpines) path.shift(shift)],
    titleStyle: titleStyle,
    branchStyle: branchStyle,
    commitLabelStyle: commitLabelStyle,
    tagStyle: tagStyle,
    dark: dark,
  );
}

bool _shouldReroute(
  NativeGitGraphCommit parent,
  NativeGitGraphCommit child,
  List<NativeGitGraphCommit> commits,
  Map<String, Offset> positions,
  bool vertical,
) {
  final from = positions[parent.id]!;
  final to = positions[child.id]!;
  final childIsFurthest = vertical ? from.dx < to.dx : from.dy < to.dy;
  final branchToCheck = childIsFurthest ? child.branch : parent.branch;
  return commits.any(
    (commit) =>
        commit.sequence > parent.sequence &&
        commit.sequence < child.sequence &&
        commit.branch == branchToCheck,
  );
}

Path _edgePath(
  Offset start,
  Offset end, {
  required bool vertical,
  required bool reroute,
  required List<double> occupiedLanes,
}) {
  final path = Path()..moveTo(start.dx, start.dy);
  if (!reroute) {
    if (vertical) {
      if (start.dx == end.dx || start.dy == end.dy) {
        path.lineTo(end.dx, end.dy);
      } else {
        final sign = end.dx >= start.dx ? 1.0 : -1.0;
        final bend = Offset(start.dx + sign * 20, start.dy);
        path
          ..lineTo(bend.dx, bend.dy)
          ..quadraticBezierTo(start.dx, end.dy, start.dx, end.dy)
          ..lineTo(end.dx, end.dy);
      }
    } else if (start.dy == end.dy || start.dx == end.dx) {
      path.lineTo(end.dx, end.dy);
    } else {
      final sign = end.dy >= start.dy ? 1.0 : -1.0;
      final bend = Offset(start.dx, end.dy - sign * 20);
      path
        ..lineTo(bend.dx, bend.dy)
        ..quadraticBezierTo(start.dx, end.dy, start.dx + 20, end.dy)
        ..lineTo(end.dx, end.dy);
    }
    return path;
  }

  final lane = _findLane(
    vertical ? start.dx : start.dy,
    vertical ? end.dx : end.dy,
    occupiedLanes,
  );
  occupiedLanes.add(lane);
  if (vertical) {
    path
      ..lineTo(lane, start.dy)
      ..lineTo(lane, end.dy)
      ..lineTo(end.dx, end.dy);
  } else {
    path
      ..lineTo(start.dx, lane)
      ..lineTo(end.dx, lane)
      ..lineTo(end.dx, end.dy);
  }
  return path;
}

double _findLane(double first, double second, List<double> occupied) {
  var candidate = first + (second - first).abs() / 2;
  for (var attempt = 0; attempt < 6; attempt++) {
    if (occupied.every((lane) => (lane - candidate).abs() >= 10)) {
      return candidate;
    }
    final difference = (second - first).abs();
    candidate = first + (second - difference / 5 - first).abs() / 2;
  }
  return candidate;
}

class NativeMermaidGitGraph extends StatelessWidget {
  const NativeMermaidGitGraph({
    super.key,
    required this.diagram,
    required this.dark,
    this.fontFamily,
  });

  final NativeGitGraphDiagram diagram;
  final bool dark;
  final String? fontFamily;

  @override
  Widget build(BuildContext context) {
    RenderL10n.watch(context);
    final layout = layoutNativeMermaidGitGraph(
      diagram,
      dark: dark,
      fontFamily: fontFamily ?? DefaultTextStyle.of(context).style.fontFamily,
    );
    final summary = [
      diagram.title,
      for (final branch in diagram.branches) 'Branch ${branch.name}',
      for (final commit in diagram.commits)
        'Commit ${commit.id}: ${commit.message}',
    ].where((value) => value.isNotEmpty).join('. ');
    return Semantics(
      image: true,
      label: diagram.accessibleTitle.isEmpty
          ? summary
          : diagram.accessibleTitle,
      value: diagram.accessibleDescription.isEmpty
          ? null
          : diagram.accessibleDescription,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final scale =
              constraints.maxWidth.isFinite &&
                  layout.size.width > constraints.maxWidth
              ? constraints.maxWidth / layout.size.width
              : 1.0;
          final fittedSize = Size(
            layout.size.width * scale,
            layout.size.height * scale,
          );
          return Align(
            alignment: Alignment.topCenter,
            child: SizedBox(
              width: fittedSize.width,
              height: fittedSize.height,
              child: FittedBox(
                fit: BoxFit.contain,
                alignment: Alignment.topLeft,
                clipBehavior: Clip.hardEdge,
                child: SizedBox.fromSize(
                  size: layout.size,
                  child: CustomPaint(
                    size: layout.size,
                    painter: NativeGitGraphPainter(layout),
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

class NativeGitGraphPainter extends CustomPainter {
  const NativeGitGraphPainter(this.layout);

  final NativeGitGraphLayout layout;

  @override
  void paint(Canvas canvas, Size size) {
    _paintBranchSpines(canvas);
    _paintCommitEdges(canvas);
    _paintBranches(canvas);
    _paintCommits(canvas);
    if (layout.diagram.title.isNotEmpty) _paintTitle(canvas);
  }

  void _paintBranchSpines(Canvas canvas) {
    final color = layout.dark
        ? const Color(0xffd3d3d3)
        : const Color(0xff81858c);
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    for (final path in layout.branchSpines) {
      final metrics = path.computeMetrics();
      for (final metric in metrics) {
        var distance = 0.0;
        while (distance < metric.length) {
          final end = math.min(distance + 2, metric.length);
          canvas.drawPath(metric.extractPath(distance, end), paint);
          distance = end + 2;
        }
      }
    }
  }

  void _paintCommitEdges(Canvas canvas) {
    for (final edge in layout.edges) {
      canvas.drawPath(
        edge.path,
        Paint()
          ..color = edge.color
          ..style = PaintingStyle.stroke
          ..strokeWidth = 8
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round,
      );
    }
  }

  void _paintBranches(Canvas canvas) {
    for (final branch in layout.branches) {
      final bounds = branch.labelBounds;
      canvas.drawRRect(
        RRect.fromRectAndRadius(bounds, const Radius.circular(4)),
        Paint()..color = branch.color,
      );
      _paintText(
        canvas,
        branch.branch.name,
        layout.branchStyle.copyWith(
          color: layout.dark
              ? const Color(0xffcccccc)
              : const Color(0xff0f1115),
        ),
        bounds.left + 6,
        bounds.top +
            (bounds.height -
                    _measureHeight(branch.branch.name, layout.branchStyle)) /
                2,
      );
    }
  }

  void _paintCommits(Canvas canvas) {
    for (final item in layout.commits) {
      final commit = item.commit;
      final center = item.center;
      final color = item.color;
      final primary = layout.dark
          ? const Color(0xff1f2020)
          : const Color(0xffedf3fe);
      switch (commit.renderedType) {
        case NativeGitCommitType.highlight:
          canvas.drawRect(
            Rect.fromCenter(center: center, width: 20, height: 20),
            Paint()
              ..color = layout.dark
                  ? const Color(0xffe0dfdf)
                  : const Color(0xff8b5d08),
          );
          canvas.drawRect(
            Rect.fromCenter(center: center, width: 12, height: 12),
            Paint()..color = primary,
          );
        case NativeGitCommitType.reverse:
          canvas.drawCircle(center, 10, Paint()..color = color);
          final cross = Paint()
            ..color = primary
            ..strokeWidth = 2
            ..strokeCap = StrokeCap.square;
          canvas
            ..drawLine(
              center + const Offset(-5, -5),
              center + const Offset(5, 5),
              cross,
            )
            ..drawLine(
              center + const Offset(-5, 5),
              center + const Offset(5, -5),
              cross,
            );
        case NativeGitCommitType.merge:
          canvas.drawCircle(center, 10, Paint()..color = color);
          canvas.drawCircle(center, 6, Paint()..color = primary);
        case NativeGitCommitType.cherryPick:
          canvas.drawCircle(center, 10, Paint()..color = color);
          final hole = Paint()
            ..color = layout.dark ? Colors.black : Colors.white;
          canvas
            ..drawCircle(center + const Offset(-3, 2), 2.75, hole)
            ..drawCircle(center + const Offset(3, 2), 2.75, hole)
            ..drawLine(
              center + const Offset(-3, 1),
              center + const Offset(0, -5),
              Paint()
                ..color = layout.dark ? Colors.black : Colors.white
                ..strokeWidth = 1.5,
            )
            ..drawLine(
              center + const Offset(3, 1),
              center + const Offset(0, -5),
              Paint()
                ..color = layout.dark ? Colors.black : Colors.white
                ..strokeWidth = 1.5,
            );
        case NativeGitCommitType.normal:
          canvas.drawCircle(center, 10, Paint()..color = color);
      }

      if (commit.tags.isNotEmpty) _paintTags(canvas, item);
      if (commit.type != NativeGitCommitType.cherryPick &&
          (commit.type != NativeGitCommitType.merge || commit.customId)) {
        _paintCommitId(canvas, item);
      }
    }
  }

  void _paintCommitId(Canvas canvas, NativeGitGraphCommitLayout item) {
    final textWidth = item.idSize.width;
    final textHeight = item.idSize.height;
    final center = item.center;
    final labelRect = Rect.fromCenter(
      center: center + Offset(0, textHeight + 20),
      width: textWidth + 8,
      height: textHeight + 6,
    );
    canvas.save();
    if (layout.diagram.direction == NativeGitGraphDirection.lr) {
      canvas.translate(
        -7.5 - (textWidth + 10) / 25 * 9.5,
        10 + textWidth / 25 * 8.5,
      );
      canvas.translate(center.dx, center.dy);
      canvas.rotate(-math.pi / 4);
      canvas.translate(-center.dx, -center.dy);
    } else {
      canvas
        ..translate(center.dx, center.dy)
        ..rotate(-math.pi / 4)
        ..translate(-center.dx, -center.dy);
    }
    canvas.drawRRect(
      RRect.fromRectAndRadius(labelRect, const Radius.circular(2)),
      Paint()
        ..color = layout.dark
            ? const Color(0x80606060)
            : const Color(0x80f1f3f5),
    );
    _paintText(
      canvas,
      item.commit.id,
      layout.commitLabelStyle,
      labelRect.left + 4,
      labelRect.top + (labelRect.height - textHeight) / 2,
    );
    canvas.restore();
  }

  void _paintTags(Canvas canvas, NativeGitGraphCommitLayout item) {
    var offset = 0.0;
    for (final tag in item.commit.tags.reversed) {
      final textSize = _measureSize(tag, layout.tagStyle);
      final center = item.center + Offset(0, -25 - offset);
      final rect = Rect.fromCenter(
        center: center,
        width: textSize.width + 10,
        height: textSize.height + 8,
      );
      final color = layout.dark
          ? const Color(0xffcccccc)
          : const Color(0xff4176e6);
      canvas.drawRRect(
        RRect.fromRectAndRadius(rect, const Radius.circular(2)),
        Paint()
          ..color = layout.dark
              ? const Color(0xff1f2020)
              : const Color(0xffedf3fe),
      );
      canvas.drawRRect(
        RRect.fromRectAndRadius(rect, const Radius.circular(2)),
        Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1,
      );
      _paintText(
        canvas,
        tag,
        layout.tagStyle,
        rect.left + 5,
        rect.top + (rect.height - textSize.height) / 2,
      );
      offset += 20;
    }
  }

  void _paintTitle(Canvas canvas) {
    final title = layout.diagram.title;
    final size = _measureSize(title, layout.titleStyle);
    _paintText(
      canvas,
      title,
      layout.titleStyle,
      (size.width < layout.size.width ? layout.size.width - size.width : 0) / 2,
      8,
    );
  }

  void _paintText(
    Canvas canvas,
    String text,
    TextStyle style,
    double x,
    double y,
  ) {
    final painter = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: TextDirection.ltr,
      textScaler: TextScaler.noScaling,
      maxLines: 1,
    )..layout();
    painter.paint(canvas, Offset(x, y));
    painter.dispose();
  }

  double _measureHeight(String text, TextStyle style) =>
      _measureSize(text, style).height;

  Size _measureSize(String text, TextStyle style) {
    final painter = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: TextDirection.ltr,
      textScaler: TextScaler.noScaling,
      maxLines: 1,
    )..layout();
    final value = painter.size;
    painter.dispose();
    return value;
  }

  @override
  bool shouldRepaint(covariant NativeGitGraphPainter oldDelegate) =>
      oldDelegate.layout != layout;
}
