import '../render_l10n.dart';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'journey_model.dart';

const _actorColors = <Color>[
  Color(0xff8fbc8f),
  Color(0xff7cfc00),
  Color(0xff00ffff),
  Color(0xff20b2aa),
  Color(0xffb0e0e6),
  Color(0xffffffe0),
];
const _legacySectionFills = <Color>[
  Color(0xff191970),
  Color(0xff8b008b),
  Color(0xff4b0082),
  Color(0xff2f4f4f),
  Color(0xff800000),
  Color(0xff8b4513),
  Color(0xff00008b),
];

class NativeJourneyLegendEntry {
  const NativeJourneyLegendEntry({
    required this.actor,
    required this.color,
    required this.center,
    required this.lines,
    required this.baselines,
    required this.maxLineWidth,
  });

  final String actor;
  final Color color;
  final Offset center;
  final List<String> lines;
  final List<double> baselines;
  final double maxLineWidth;
}

class NativeJourneySectionLayout {
  const NativeJourneySectionLayout({
    required this.name,
    required this.firstTaskIndex,
    required this.taskCount,
    required this.colorIndex,
    required this.bounds,
  });

  final String name;
  final int firstTaskIndex;
  final int taskCount;
  final int colorIndex;
  final Rect bounds;
  Color fill(bool dark) => _journeySectionFill(colorIndex, dark);
}

class NativeJourneyTaskLayout {
  const NativeJourneyTaskLayout({
    required this.task,
    required this.bounds,
    required this.scoreCenter,
    required this.colorIndex,
    required this.textColor,
    required this.actorBadges,
  });

  final NativeMermaidJourneyTask task;
  final Rect bounds;
  final Offset scoreCenter;
  final int colorIndex;
  final Color textColor;
  final List<(String, Offset, Color)> actorBadges;
  Color fill(bool dark) => _journeySectionFill(colorIndex, dark);
}

class NativeMermaidJourneyLayout {
  const NativeMermaidJourneyLayout({
    required this.diagram,
    required this.size,
    required this.viewBox,
    required this.scale,
    required this.leftMargin,
    required this.legend,
    required this.sections,
    required this.tasks,
    required this.axisY,
    required this.axisStartX,
    required this.axisEndX,
    required this.titleBaseline,
    required this.titleFontSize,
    required this.textStyle,
    required this.titleStyle,
    required this.dark,
  });

  final NativeMermaidJourneyDiagram diagram;
  final Size size;
  final Rect viewBox;
  final double scale;
  final double leftMargin;
  final List<NativeJourneyLegendEntry> legend;
  final List<NativeJourneySectionLayout> sections;
  final List<NativeJourneyTaskLayout> tasks;
  final double axisY;
  final double axisStartX;
  final double axisEndX;
  final double titleBaseline;
  final double titleFontSize;
  final TextStyle textStyle;
  final TextStyle titleStyle;
  final bool dark;
}

/// Mermaid 11.17.2 user-journey layout using its fixed task grid, actor
/// legend, section runs, score-to-face mapping and useMaxWidth behavior.
NativeMermaidJourneyLayout layoutNativeMermaidJourney(
  NativeMermaidJourneyDiagram diagram, {
  required double width,
  required bool dark,
  String? fontFamily,
}) {
  if (!width.isFinite || width <= 0) {
    throw FormatException(tr("Journey width must be positive"));
  }
  const taskWidth = 150.0;
  const taskHeight = 50.0;
  const taskMargin = 50.0;
  const diagramMarginX = 50.0;
  const diagramMarginY = 10.0;
  const baseLeftMargin = 150.0;
  const taskFontSize = 14.0;
  const titleFontSize = 32.0;

  final textColor = dark ? const Color(0xffcccccc) : const Color(0xff0f1115);
  final textStyle = TextStyle(
    fontFamily: fontFamily,
    fontSize: taskFontSize,
    height: 1,
    color: textColor,
  );
  final legendStyle = TextStyle(
    fontFamily: fontFamily,
    fontSize: 16,
    height: 1,
    color: textColor,
  );
  final titleStyle = TextStyle(
    fontFamily: fontFamily,
    fontSize: titleFontSize,
    fontWeight: FontWeight.bold,
    height: 1,
    color: dark ? const Color(0xfff9fffe) : const Color(0xff060504),
  );

  final legend = <NativeJourneyLegendEntry>[];
  var widestLegendLine = 0.0;
  var legendY = 60.0;
  for (var index = 0; index < diagram.actors.length; index++) {
    final actor = diagram.actors[index];
    final lines = _wrapLegendActor(actor, legendStyle, 360);
    final widths = <double>[];
    final baselines = <double>[];
    for (var lineIndex = 0; lineIndex < lines.length; lineIndex++) {
      final painter = _measure(
        lines[lineIndex],
        legendStyle,
        maxWidth: 360,
        textAlign: TextAlign.left,
      );
      widths.add(painter.width);
      painter.dispose();
      baselines.add(legendY + 7 + lineIndex * 20.0);
    }
    final lineWidth = widths.isEmpty ? 0.0 : widths.reduce(math.max);
    if (lineWidth > widestLegendLine &&
        lineWidth > baseLeftMargin - lineWidth) {
      widestLegendLine = lineWidth;
    }
    legend.add(
      NativeJourneyLegendEntry(
        actor: actor,
        color: _actorColors[index % _actorColors.length],
        center: Offset(20, legendY),
        lines: List.unmodifiable(lines),
        baselines: List.unmodifiable(baselines),
        maxLineWidth: lineWidth,
      ),
    );
    legendY += math.max(20, lines.length * 20).toDouble();
  }
  final leftMargin = baseLeftMargin + widestLegendLine;
  final sections = <NativeJourneySectionLayout>[];
  final tasks = <NativeJourneyTaskLayout>[];
  final actorColors = <String, Color>{
    for (var i = 0; i < diagram.actors.length; i++)
      diagram.actors[i]: _actorColors[i % _actorColors.length],
  };

  var lastSection = '';
  var sectionNumber = 0;
  var currentColorIndex = 0;
  var currentTextColor = Colors.black;
  for (var index = 0; index < diagram.tasks.length; index++) {
    final task = diagram.tasks[index];
    if (lastSection != task.sectionName) {
      final isInitialUnsectionedRun =
          lastSection.isEmpty && task.sectionName.isEmpty;
      if (!isInitialUnsectionedRun) {
        currentColorIndex = sectionNumber % _legacySectionFills.length;
        currentTextColor = textColor;
        var count = 0;
        for (var next = index; next < diagram.tasks.length; next++) {
          if (diagram.tasks[next].sectionName != task.sectionName) break;
          count++;
        }
        sections.add(
          NativeJourneySectionLayout(
            name: task.sectionName,
            firstTaskIndex: index,
            taskCount: count,
            colorIndex: currentColorIndex,
            bounds: Rect.fromLTWH(
              leftMargin + index * (taskWidth + taskMargin),
              50,
              taskWidth * count + diagramMarginX * (count - 1),
              taskHeight,
            ),
          ),
        );
        sectionNumber++;
      } else {
        currentTextColor = Colors.black;
      }
      lastSection = task.sectionName;
    }

    final taskX = leftMargin + index * (taskWidth + taskMargin);
    final taskBounds = Rect.fromLTWH(taskX, 110, taskWidth, taskHeight);
    final badges = <(String, Offset, Color)>[];
    var badgeX = taskX + 14;
    for (final actor in task.actors) {
      final color = actorColors[actor];
      if (color == null) continue;
      badges.add((actor, Offset(badgeX, taskBounds.top), color));
      badgeX += 10;
    }
    tasks.add(
      NativeJourneyTaskLayout(
        task: task,
        bounds: taskBounds,
        scoreCenter: Offset(taskX + taskWidth / 2, 300 + (5 - task.score) * 30),
        colorIndex: currentColorIndex,
        textColor: currentTextColor,
        actorBadges: List.unmodifiable(badges),
      ),
    );
  }

  final hasTasks = tasks.isNotEmpty;
  final boundsMaxX = hasTasks
      ? math.max(leftMargin, tasks.last.bounds.left + 100)
      : leftMargin;
  final boundsMaxY = math.max(
    diagram.actors.length * 50.0,
    hasTasks ? 450.0 : 0.0,
  );
  final contentHeight = math.max(50.0, boundsMaxY) + 2 * diagramMarginY;
  final chartWidth = leftMargin + boundsMaxX + 2 * diagramMarginX;
  final hasTitle = diagram.title.isNotEmpty;
  final svgHeight = contentHeight + (hasTitle ? 70 : 0) + 25;
  final viewBox = Rect.fromLTWH(
    0,
    -25,
    math.max(1, chartWidth),
    contentHeight + (hasTitle ? 70 : 0),
  );
  final scale = math.min(1.0, width / viewBox.width).toDouble();
  final titleMetrics = _measure(
    diagram.title,
    titleStyle,
    maxWidth: viewBox.width,
    textAlign: TextAlign.left,
  );
  const titleBaseline = 25.0;
  titleMetrics.dispose();
  return NativeMermaidJourneyLayout(
    diagram: diagram,
    size: Size(viewBox.width * scale, svgHeight * scale),
    viewBox: viewBox,
    scale: scale,
    leftMargin: leftMargin,
    legend: List.unmodifiable(legend),
    sections: List.unmodifiable(sections),
    tasks: List.unmodifiable(tasks),
    axisY: 200,
    axisStartX: leftMargin,
    axisEndX: chartWidth - leftMargin - 4,
    titleBaseline: titleBaseline,
    titleFontSize: titleFontSize,
    textStyle: textStyle,
    titleStyle: titleStyle,
    dark: dark,
  );
}

List<String> _wrapLegendActor(String actor, TextStyle style, double maxWidth) {
  final full = _measure(actor, style, maxWidth: maxWidth);
  final fits = full.width <= maxWidth;
  full.dispose();
  if (fits) return [actor];
  final words = actor.split(' ');
  final lines = <String>[];
  var line = '';
  for (final word in words) {
    final candidate = line.isEmpty ? word : '$line $word';
    final measure = _measure(candidate, style, maxWidth: maxWidth);
    final candidateFits = measure.width <= maxWidth;
    measure.dispose();
    if (candidateFits) {
      line = candidate;
      continue;
    }
    if (line.isNotEmpty) lines.add(line);
    line = word;
    final wordMeasure = _measure(word, style, maxWidth: maxWidth);
    final wordFits = wordMeasure.width <= maxWidth;
    wordMeasure.dispose();
    if (!wordFits) {
      final pieces = _hyphenate(word, style, maxWidth);
      lines.addAll(pieces.take(pieces.length - 1));
      line = pieces.isEmpty ? word : pieces.last;
    }
  }
  if (line.isNotEmpty) lines.add(line);
  return lines.isEmpty ? [actor] : lines;
}

List<String> _hyphenate(String word, TextStyle style, double maxWidth) {
  final result = <String>[];
  var fragment = '';
  for (final rune in word.runes) {
    final character = String.fromCharCode(rune);
    final candidate = '$fragment$character';
    final measure = _measure('$candidate-', style, maxWidth: maxWidth);
    final fits = measure.width <= maxWidth;
    measure.dispose();
    if (!fits && fragment.isNotEmpty) {
      result.add('$fragment-');
      fragment = character;
    } else {
      fragment = candidate;
    }
  }
  if (fragment.isNotEmpty) result.add(fragment);
  return result;
}

TextPainter _measure(
  String text,
  TextStyle style, {
  double maxWidth = double.infinity,
  TextAlign textAlign = TextAlign.center,
}) => TextPainter(
  text: TextSpan(text: text, style: style),
  textDirection: TextDirection.ltr,
  textAlign: textAlign,
)..layout(maxWidth: maxWidth);

Color _journeySectionFill(int index, bool dark) {
  if (index < 0 || index > 7) {
    return _legacySectionFills[index % _legacySectionFills.length];
  }
  if (dark) {
    const darkColors = <Color>[
      Color(0xff1f2020),
      Color(0xff474949),
      Color(0xff1f1f20),
      Color(0xff474749),
      Color(0xff1f201f),
      Color(0xff474947),
      Color(0xff201f20),
      Color(0xff494749),
    ];
    return darkColors[index];
  }
  const lightColors = <Color>[
    Color(0xffedf3fe),
    Color(0xfff1f3f5),
    Color(0xfff9edfe),
    Color(0xfff3f1f5),
    Color(0xffedfef7),
    Color(0xfff1f5f3),
    Color(0xfffeedf1),
    Color(0xfff5f1f2),
  ];
  return lightColors[index];
}

class NativeMermaidJourney extends StatelessWidget {
  const NativeMermaidJourney({
    super.key,
    required this.diagram,
    required this.dark,
  });

  final NativeMermaidJourneyDiagram diagram;
  final bool dark;

  @override
  Widget build(BuildContext context) {
    RenderL10n.watch(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth.isFinite
            ? constraints.maxWidth
            : MediaQuery.sizeOf(context).width;
        final layout = layoutNativeMermaidJourney(
          diagram,
          width: width,
          dark: dark,
          fontFamily: Theme.of(context).textTheme.bodyMedium?.fontFamily,
        );
        final semanticText = <String>[
          if (diagram.title.isNotEmpty) diagram.title,
          for (final task in diagram.tasks)
            '${task.sectionName}: ${task.label}, score ${task.score}, actors ${task.actors.join(', ')}',
        ].join('. ');
        return Semantics(
          container: true,
          label: diagram.accessibleTitle.isEmpty
              ? (diagram.title.isEmpty ? tr("User journey") : diagram.title)
              : diagram.accessibleTitle,
          value: diagram.accessibleDescription.isEmpty
              ? semanticText
              : diagram.accessibleDescription,
          child: SizedBox(
            width: layout.size.width,
            height: layout.size.height,
            child: ClipRect(
              child: FittedBox(
                fit: BoxFit.contain,
                alignment: Alignment.topLeft,
                child: SizedBox(
                  width: layout.viewBox.width,
                  height: layout.viewBox.height,
                  child: CustomPaint(
                    size: Size(layout.viewBox.width, layout.viewBox.height),
                    painter: NativeMermaidJourneyPainter(layout),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class NativeMermaidJourneyPainter extends CustomPainter {
  const NativeMermaidJourneyPainter(this.layout);

  final NativeMermaidJourneyLayout layout;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.clipRect(Offset.zero & size);
    canvas.translate(-layout.viewBox.left, -layout.viewBox.top);
    final legendStyle = layout.textStyle.copyWith(
      fontSize: 16,
      color: layout.dark ? const Color(0xffcccccc) : const Color(0xff0f1115),
    );

    for (final entry in layout.legend) {
      canvas.drawCircle(
        entry.center,
        7,
        Paint()
          ..color = entry.color
          ..style = PaintingStyle.fill,
      );
      canvas.drawCircle(
        entry.center,
        7,
        Paint()
          ..color = Colors.black
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1,
      );
      for (var index = 0; index < entry.lines.length; index++) {
        _paintBaselineText(
          canvas,
          entry.lines[index],
          Offset(40, entry.baselines[index]),
          legendStyle,
          maxWidth: 360,
          align: TextAlign.left,
        );
      }
    }

    for (final section in layout.sections) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(section.bounds, const Radius.circular(3)),
        Paint()..color = section.fill(layout.dark),
      );
      _paintCellText(
        canvas,
        section.name,
        section.bounds,
        layout.textStyle.copyWith(
          color: layout.dark
              ? const Color(0xffcccccc)
              : const Color(0xff0f1115),
        ),
      );
    }

    for (final task in layout.tasks) {
      _paintDashedLine(
        canvas,
        Offset(task.bounds.center.dx, task.bounds.top),
        Offset(task.bounds.center.dx, 450),
        const Color(0xff666666),
        1,
      );
      _paintFace(canvas, task.scoreCenter, task.task.score);
      canvas.drawRRect(
        RRect.fromRectAndRadius(task.bounds, const Radius.circular(3)),
        Paint()..color = task.fill(layout.dark),
      );
      for (final badge in task.actorBadges) {
        canvas.drawCircle(badge.$2, 7, Paint()..color = badge.$3);
        canvas.drawCircle(
          badge.$2,
          7,
          Paint()
            ..color = Colors.black
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1,
        );
      }
      _paintCellText(
        canvas,
        task.task.label,
        task.bounds,
        layout.textStyle.copyWith(color: task.textColor),
      );
    }

    if (layout.diagram.title.isNotEmpty) {
      _paintBaselineText(
        canvas,
        layout.diagram.title,
        Offset(layout.leftMargin, layout.titleBaseline),
        layout.titleStyle,
        maxWidth: layout.viewBox.width - layout.leftMargin,
        align: TextAlign.left,
      );
    }
    _paintAxis(
      canvas,
      Offset(layout.axisStartX, layout.axisY),
      Offset(layout.axisEndX, layout.axisY),
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant NativeMermaidJourneyPainter oldDelegate) =>
      oldDelegate.layout != layout;
}

void _paintCellText(
  Canvas canvas,
  String source,
  Rect bounds,
  TextStyle style,
) {
  final text = source.replaceAll(
    RegExp(r'<br\s*/?>', caseSensitive: false),
    '\n',
  );
  final painter = _measure(
    text,
    style,
    maxWidth: bounds.width,
    textAlign: TextAlign.center,
  );
  painter.paint(
    canvas,
    Offset(bounds.left, bounds.center.dy - painter.height / 2),
  );
  painter.dispose();
}

void _paintBaselineText(
  Canvas canvas,
  String text,
  Offset baseline,
  TextStyle style, {
  required double maxWidth,
  TextAlign align = TextAlign.center,
}) {
  final painter = _measure(text, style, maxWidth: maxWidth, textAlign: align);
  final ascent = painter.computeDistanceToActualBaseline(
    TextBaseline.alphabetic,
  );
  painter.paint(canvas, Offset(baseline.dx, baseline.dy - ascent));
  painter.dispose();
}

void _paintDashedLine(
  Canvas canvas,
  Offset start,
  Offset end,
  Color color,
  double width,
) {
  final delta = end - start;
  final distance = delta.distance;
  if (!distance.isFinite || distance <= 0) return;
  final unit = delta / distance;
  final paint = Paint()
    ..color = color
    ..strokeWidth = width;
  for (var offset = 0.0; offset < distance; offset += 6) {
    canvas.drawLine(
      start + unit * offset,
      start + unit * math.min(offset + 4, distance),
      paint,
    );
  }
}

void _paintFace(Canvas canvas, Offset center, double score) {
  if (!center.dx.isFinite || !center.dy.isFinite) return;
  canvas.drawCircle(center, 15, Paint()..color = const Color(0xfffff8dc));
  canvas.drawCircle(
    center,
    15,
    Paint()
      ..color = const Color(0xff999999)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2,
  );
  final eye = Paint()..color = const Color(0xff666666);
  canvas.drawCircle(center + const Offset(-5, -5), 1.5, eye);
  canvas.drawCircle(center + const Offset(5, -5), 1.5, eye);
  final mouth = Paint()
    ..color = const Color(0xff666666)
    ..style = PaintingStyle.stroke
    ..strokeWidth = 1;
  if (score == 3) {
    canvas.drawLine(
      center + const Offset(-5, 7),
      center + const Offset(5, 7),
      mouth,
    );
    return;
  }
  final path = Path();
  if (score > 3) {
    path
      ..moveTo(center.dx - 6, center.dy + 3)
      ..quadraticBezierTo(
        center.dx,
        center.dy + 10,
        center.dx + 6,
        center.dy + 3,
      );
  } else {
    path
      ..moveTo(center.dx - 6, center.dy + 9)
      ..quadraticBezierTo(
        center.dx,
        center.dy + 2,
        center.dx + 6,
        center.dy + 9,
      );
  }
  canvas.drawPath(path, mouth);
}

void _paintAxis(Canvas canvas, Offset start, Offset end) {
  final paint = Paint()
    ..color = Colors.black
    ..strokeWidth = 4
    ..strokeCap = StrokeCap.butt;
  canvas.drawLine(start, end, paint);
  final arrow = Path()
    ..moveTo(end.dx - 12, end.dy - 8)
    ..lineTo(end.dx - 12, end.dy + 8)
    ..lineTo(end.dx + 2, end.dy)
    ..close();
  canvas.drawPath(arrow, Paint()..color = Colors.black);
}
