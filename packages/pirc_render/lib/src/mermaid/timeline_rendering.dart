import '../render_l10n.dart';
// Mermaid 11.17.2 classic timeline layout port. Upstream MIT notice is in
// MERMAID_MIT_LICENSE.txt. Paths and positions derive from the live model and
// native text metrics; product code never reads reference fixtures or SVGs.
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'classic_palette.dart';
import 'timeline_model.dart';
import 'timeline_node.dart';

class NativeTimelineTypography
    extends ThemeExtension<NativeTimelineTypography> {
  const NativeTimelineTypography({
    this.fontFamily,
    this.letterSpacing = 0,
    this.titleFontSize = 26,
    this.titleLetterSpacing = 0,
    this.svgXHeight,
  });
  final String? fontFamily;
  final double letterSpacing, titleFontSize, titleLetterSpacing;
  final double? svgXHeight;
  @override
  NativeTimelineTypography copyWith({
    String? fontFamily,
    double? letterSpacing,
    double? titleFontSize,
    double? titleLetterSpacing,
    double? svgXHeight,
  }) => NativeTimelineTypography(
    fontFamily: fontFamily ?? this.fontFamily,
    letterSpacing: letterSpacing ?? this.letterSpacing,
    titleFontSize: titleFontSize ?? this.titleFontSize,
    titleLetterSpacing: titleLetterSpacing ?? this.titleLetterSpacing,
    svgXHeight: svgXHeight ?? this.svgXHeight,
  );
  @override
  NativeTimelineTypography lerp(
    covariant NativeTimelineTypography? other,
    double t,
  ) => other == null
      ? this
      : NativeTimelineTypography(
          fontFamily: t < .5 ? fontFamily : other.fontFamily,
          letterSpacing:
              letterSpacing + (other.letterSpacing - letterSpacing) * t,
          titleFontSize:
              titleFontSize + (other.titleFontSize - titleFontSize) * t,
          titleLetterSpacing:
              titleLetterSpacing +
              (other.titleLetterSpacing - titleLetterSpacing) * t,
          svgXHeight: t < .5 ? svgXHeight : other.svgXHeight,
        );
}

class NativeTimelinePlacedNode {
  const NativeTimelinePlacedNode({
    required this.kind,
    required this.ordinal,
    required this.description,
    required this.position,
    required this.geometry,
    required this.colorIndex,
    required this.event,
  });
  final String kind, description;
  final int ordinal, colorIndex;
  final Offset position;
  final NativeTimelineNodeLayout geometry;
  final bool event;
  Rect get bounds => geometry.localBounds
      .shift(position)
      .expandToInclude(
        geometry.textBounds.shift(position + geometry.textTransform),
      );
}

class NativeTimelineConnector {
  const NativeTimelineConnector(
    this.start,
    this.end,
    this.width, {
    this.dashed = false,
    this.arrow = false,
    this.axis = false,
    this.afterNodeOrdinal,
  });
  final Offset start, end;
  final double width;
  final bool dashed, arrow, axis;
  final int? afterNodeOrdinal;
}

class NativeTimelineTitle {
  const NativeTimelineTitle(this.text, this.position, this.style, this.bounds);
  final String text;
  final Offset position;
  final TextStyle style;
  final Rect bounds;
}

class NativeTimelineLayout {
  const NativeTimelineLayout({
    required this.diagram,
    required this.nodes,
    required this.connectors,
    required this.title,
    required this.viewBox,
    required this.size,
    required this.scale,
    required this.textStyle,
    required this.dark,
  });
  final NativeMermaidTimelineDiagram diagram;
  final List<NativeTimelinePlacedNode> nodes;
  final List<NativeTimelineConnector> connectors;
  final NativeTimelineTitle? title;
  final Rect viewBox;
  final Size size;
  final double scale;
  final TextStyle textStyle;
  final bool dark;
}

NativeTimelineLayout layoutNativeMermaidTimeline(
  NativeMermaidTimelineDiagram diagram, {
  required double width,
  required bool dark,
  String? fontFamily,
  double letterSpacing = 0,
  double titleFontSize = 26,
  double titleLetterSpacing = 0,
  double? svgXHeight,
}) {
  if (!width.isFinite || width <= 0) {
    throw FormatException(tr("Timeline width must be positive"));
  }
  final style = TextStyle(
    fontFamily: fontFamily,
    fontSize: 13,
    height: kTextHeightNone,
    letterSpacing: letterSpacing,
    fontWeight: FontWeight.w400,
    fontVariations: const [FontVariation('opsz', 13)],
    color: dark ? const Color(0xffd3d3d3) : const Color(0xff0f1115),
  );
  final nodes = <NativeTimelinePlacedNode>[];
  final connectors = <NativeTimelineConnector>[];
  const leftMargin = 150.0, configFontSize = 16.0;
  final vertical = diagram.direction == 'TD';
  final padding = vertical ? 5.0 : 20.0;
  final taskWidth = vertical ? 200.0 : 150.0;
  final eventWidth = vertical ? 300.0 : 150.0;
  final sectionWidth = vertical ? 580.0 : 150.0;
  NativeTimelineNodeLayout measure(
    String label,
    double w,
    double p, {
    double minimum = 0,
    int color = 0,
    bool event = false,
  }) => layoutNativeTimelineNode(
    descr: label,
    width: w,
    padding: p,
    maxHeight: minimum,
    configFontSize: configFontSize,
    textStyle: style,
    sectionDepth: color,
    isEvent: event,
    svgXHeight: svgXHeight,
  );
  double virtual(String label, double w, double p) =>
      measure(label, w, p).virtualHeight;
  var maxSectionHeight = 0.0, maxTaskHeight = 0.0, maxEventStack = 0.0;
  for (final section in diagram.sections) {
    maxSectionHeight = math.max(
      maxSectionHeight,
      virtual(section.name, sectionWidth, padding) + (vertical ? 0 : 20),
    );
  }
  for (final task in diagram.tasks) {
    // The source preflight hands the complete task object to d3.text(),
    // which uses JavaScript's '[object Object]' string, not the period label.
    maxTaskHeight = math.max(
      maxTaskHeight,
      virtual('[object Object]', taskWidth, padding) + (vertical ? 0 : 20),
    );
    var eventStack = 0.0;
    for (final event in task.events) {
      eventStack += virtual(event.text, eventWidth, padding);
    }
    if (task.events.isNotEmpty) eventStack += (task.events.length - 1) * 10;
    maxEventStack = math.max(maxEventStack, eventStack);
  }
  void place(
    String kind,
    String label,
    Offset point,
    double w,
    double p,
    double minimum,
    int color, {
    bool event = false,
  }) {
    nodes.add(
      NativeTimelinePlacedNode(
        kind: kind,
        ordinal: nodes.length,
        description: label,
        position: point,
        geometry: measure(
          label,
          w,
          p,
          minimum: minimum,
          color: color,
          event: event,
        ),
        colorIndex: color % 12,
        event: event,
      ),
    );
  }

  final hasSections = diagram.sections.isNotEmpty;
  if (!vertical) {
    var masterX = 50 + leftMargin;
    final masterY = 50.0 + (hasSections ? maxSectionHeight + 50 : 0);
    void tasks(List<NativeMermaidTimelineTask> group, int color) {
      var groupMaxTaskHeight = maxTaskHeight;
      for (final task in group) {
        place(
          'task',
          task.period,
          Offset(masterX, masterY),
          150,
          20,
          groupMaxTaskHeight,
          color,
        );
        groupMaxTaskHeight = math.max(
          groupMaxTaskHeight,
          nodes.last.geometry.height,
        );
        // Source events[] is an array and is truthy even when empty.
        var eventY = masterY + 200;
        for (final event in task.events) {
          place(
            'event',
            event.text,
            Offset(masterX, eventY),
            150,
            20,
            50,
            color,
            event: true,
          );
          eventY += nodes.last.geometry.height + 10;
        }
        connectors.add(
          NativeTimelineConnector(
            Offset(masterX + 95, masterY + groupMaxTaskHeight),
            Offset(
              masterX + 95,
              masterY + groupMaxTaskHeight + 200 + maxEventStack,
            ),
            2,
            dashed: true,
            arrow: true,
          ),
        );
        masterX += 200;
        if (!hasSections) color++;
      }
    }

    if (hasSections) {
      for (var index = 0; index < diagram.sections.length; index++) {
        final section = diagram.sections[index];
        final group = diagram.tasks
            .where((task) => task.sectionName == section.name)
            .toList();
        final start = masterX;
        place(
          'section',
          section.name,
          Offset(start, 50),
          200 * math.max(group.length, 1) - 50,
          20,
          maxSectionHeight,
          index,
        );
        tasks(group, index);
        masterX = start + 200 * math.max(group.length, 1);
      }
    } else {
      tasks(diagram.tasks, 0);
    }
  } else {
    const axisX = 430.0;
    final taskSpacing = math.max(maxTaskHeight, maxEventStack) + 30;
    var masterY = 50.0;
    void tasks(List<NativeMermaidTimelineTask> group, int color, double y) {
      var groupMaxTaskHeight = maxTaskHeight;
      for (final task in group) {
        final geometry = measure(
          task.period,
          200,
          5,
          minimum: groupMaxTaskHeight,
          color: color,
        );
        place(
          'task',
          task.period,
          Offset(axisX - 20 - geometry.width, y),
          200,
          5,
          groupMaxTaskHeight,
          color,
        );
        groupMaxTaskHeight = math.max(
          groupMaxTaskHeight,
          nodes.last.geometry.height,
        );
        var eventY = y;
        for (final event in task.events) {
          place(
            'event',
            event.text,
            Offset(axisX + 50, eventY),
            300,
            5,
            0,
            color,
            event: true,
          );
          final eventHeight = nodes.last.geometry.height;
          connectors.add(
            NativeTimelineConnector(
              Offset(axisX, eventY + eventHeight / 2),
              Offset(axisX + 50, eventY + eventHeight / 2),
              2,
              dashed: true,
              afterNodeOrdinal: nodes.last.ordinal,
            ),
          );
          eventY += eventHeight + 10;
        }
        y += taskSpacing;
        if (!hasSections) color++;
      }
    }

    if (hasSections) {
      for (var index = 0; index < diagram.sections.length; index++) {
        final section = diagram.sections[index];
        final group = diagram.tasks
            .where((task) => task.sectionName == section.name)
            .toList();
        place(
          'section',
          section.name,
          Offset(200, masterY),
          580,
          5,
          maxSectionHeight,
          index,
        );
        final sectionHeight = nodes.last.geometry.height;
        tasks(group, index, masterY + sectionHeight + 20);
        masterY +=
            sectionHeight +
            20 +
            taskSpacing * math.max(group.length, 1) -
            (group.isNotEmpty ? 60 : 0);
      }
    } else {
      tasks(diagram.tasks, 0, masterY);
    }
  }
  Rect? all;
  void include(Rect value) =>
      all = all == null ? value : all!.expandToInclude(value);
  for (final node in nodes) {
    include(node.bounds);
  }
  for (final line in connectors) {
    include(Rect.fromPoints(line.start, line.end));
  }
  all ??= Rect.zero;
  final beforeTitle = all!;
  NativeTimelineTitle? title;
  if (diagram.title.isNotEmpty) {
    final titleStyle = style.copyWith(
      fontSize: titleFontSize,
      fontWeight: FontWeight.w700,
      fontVariations: [FontVariation('opsz', titleFontSize)],
      letterSpacing: titleLetterSpacing,
    );
    final titlePainter = TextPainter(
      text: TextSpan(text: diagram.title, style: titleStyle),
      textDirection: TextDirection.ltr,
    )..layout();
    final titleMetrics = titlePainter.computeLineMetrics().first;
    // The source SVG title uses rounded font ascent/descent cells, rather
    // than Flutter's paragraph baseline distribution. Measure before the
    // responsive viewBox transform, as setupGraphViewbox does.
    final titleAscent = titleMetrics.ascent.roundToDouble();
    final titleDescent = titleMetrics.descent.roundToDouble();
    final point = Offset(beforeTitle.width / 2 - leftMargin, 20);
    title = NativeTimelineTitle(
      diagram.title,
      point,
      titleStyle,
      Rect.fromLTWH(
        point.dx,
        point.dy - titleAscent,
        (titlePainter.width * 64).ceil() / 64,
        titleAscent + titleDescent,
      ),
    );
    titlePainter.dispose();
    include(title.bounds);
  }
  if (vertical) {
    // The source TD renderer references #arrowhead while initGraphics creates
    // undefined-arrowhead. That unresolved marker paints no arrow in TD.
    final end = all!.bottom + configFontSize * .5 + 20;
    connectors.insert(
      0,
      NativeTimelineConnector(
        const Offset(430, 18),
        Offset(430, end),
        4,
        axis: true,
      ),
    );
    include(Rect.fromPoints(connectors.first.start, connectors.first.end));
  } else {
    final depth = hasSections
        ? maxSectionHeight + maxTaskHeight + 150
        : maxTaskHeight + 100;
    connectors.add(
      NativeTimelineConnector(
        Offset(leftMargin, depth),
        Offset(beforeTitle.width + 3 * leftMargin, depth),
        4,
        arrow: true,
        axis: true,
      ),
    );
    include(Rect.fromPoints(connectors.last.start, connectors.last.end));
  }
  final viewBox = all!.inflate(50);
  final scale = math.min(1.0, width / viewBox.width);
  return NativeTimelineLayout(
    diagram: diagram,
    nodes: List.unmodifiable(nodes),
    connectors: List.unmodifiable(connectors),
    title: title,
    viewBox: viewBox,
    size: Size(viewBox.width * scale, viewBox.height * scale),
    scale: scale,
    textStyle: style,
    dark: dark,
  );
}

Color _timelineTextColor(bool dark) =>
    dark ? const Color(0xffd3d3d3) : const Color(0xff0f1115);
Color _brightness(Color color, bool enabled) => !enabled
    ? color
    : Color.fromARGB(
        (color.a * 255).round(),
        (color.r * 255 * 1.2).round().clamp(0, 255),
        (color.g * 255 * 1.2).round().clamp(0, 255),
        (color.b * 255 * 1.2).round().clamp(0, 255),
      );

class NativeMermaidTimeline extends StatelessWidget {
  const NativeMermaidTimeline({
    super.key,
    required this.diagram,
    required this.dark,
  });
  final NativeMermaidTimelineDiagram diagram;
  final bool dark;
  @override
  Widget build(BuildContext context) {
    RenderL10n.watch(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final typography =
            Theme.of(context).extension<NativeTimelineTypography>() ??
            const NativeTimelineTypography();
        final layout = layoutNativeMermaidTimeline(
          diagram,
          width: constraints.maxWidth,
          dark: dark,
          fontFamily:
              typography.fontFamily ??
              Theme.of(context).textTheme.bodyMedium?.fontFamily,
          letterSpacing: typography.letterSpacing,
          titleFontSize: typography.titleFontSize,
          titleLetterSpacing: typography.titleLetterSpacing,
          svgXHeight: typography.svgXHeight,
        );
        return Semantics(
          container: true,
          label: diagram.accessibleTitle.isEmpty
              ? null
              : diagram.accessibleTitle,
          value: diagram.accessibleDescription.isEmpty
              ? null
              : diagram.accessibleDescription,
          child: Center(
            child: SizedBox(
              width: layout.size.width,
              height: layout.size.height,
              child: FittedBox(
                child: SizedBox(
                  width: layout.viewBox.width,
                  height: layout.viewBox.height,
                  child: SelectionArea(
                    child: Stack(
                      children: [
                        Positioned.fill(
                          child: CustomPaint(
                            painter: NativeTimelinePainter(layout),
                          ),
                        ),
                        for (final node in layout.nodes)
                          for (final line in node.geometry.lines)
                            if (line.paintText.isNotEmpty)
                              Positioned(
                                left:
                                    node.position.dx +
                                    node.geometry.textTransform.dx +
                                    line.glyphBounds.left -
                                    layout.viewBox.left,
                                top:
                                    node.position.dy +
                                    node.geometry.textTransform.dy +
                                    line.glyphBounds.top -
                                    layout.viewBox.top,
                                width: line.glyphBounds.width,
                                height: line.glyphBounds.height,
                                child: Baseline(
                                  baseline:
                                      line.baseline - line.glyphBounds.top,
                                  baselineType: TextBaseline.alphabetic,
                                  child: Text(
                                    line.paintText,
                                    softWrap: false,
                                    overflow: TextOverflow.visible,
                                    maxLines: 1,
                                    textScaler: TextScaler.noScaling,
                                    style: layout.textStyle.copyWith(
                                      color: _brightness(
                                        _timelineTextColor(dark),
                                        node.event,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                        if (layout.title != null)
                          Positioned(
                            left:
                                layout.title!.bounds.left - layout.viewBox.left,
                            top: layout.title!.bounds.top - layout.viewBox.top,
                            width: layout.title!.bounds.width,
                            height: layout.title!.bounds.height,
                            child: Baseline(
                              baseline:
                                  layout.title!.position.dy -
                                  layout.title!.bounds.top,
                              baselineType: TextBaseline.alphabetic,
                              child: Text(
                                layout.title!.text,
                                softWrap: false,
                                overflow: TextOverflow.visible,
                                maxLines: 1,
                                textScaler: TextScaler.noScaling,
                                style: layout.title!.style,
                              ),
                            ),
                          ),
                      ],
                    ),
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

class NativeTimelinePainter extends CustomPainter {
  const NativeTimelinePainter(this.layout);
  final NativeTimelineLayout layout;
  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.translate(-layout.viewBox.left, -layout.viewBox.top);
    void drawConnector(NativeTimelineConnector line) {
      final paint = Paint()
        ..color = _timelineTextColor(layout.dark)
        ..strokeWidth = line.width;
      final delta = line.end - line.start;
      if (line.dashed && delta.distance > 0) {
        final unit = delta / delta.distance;
        for (var offset = 0.0; offset < delta.distance; offset += 10) {
          canvas.drawLine(
            line.start + unit * offset,
            line.start + unit * math.min(offset + 5, delta.distance),
            paint,
          );
        }
      } else {
        canvas.drawLine(line.start, line.end, paint);
      }
      if (line.arrow && delta.distance > 0) {
        final unit = delta / delta.distance,
            perpendicular = Offset(-unit.dy, unit.dx);
        final base = line.end - unit * 5 * line.width;
        final tip = line.end + unit * line.width;
        canvas.drawPath(
          Path()..addPolygon([
            base - perpendicular * 2 * line.width,
            base + perpendicular * 2 * line.width,
            tip,
          ], true),
          Paint()..color = Colors.black,
        );
      }
    }

    for (final line in layout.connectors) {
      if (layout.diagram.direction == 'TD' ? line.axis : !line.axis) {
        drawConnector(line);
      }
    }
    for (final node in layout.nodes) {
      canvas.save();
      canvas.translate(node.position.dx, node.position.dy);
      canvas.drawPath(
        node.geometry.backgroundPath,
        Paint()
          ..color = _brightness(
            mermaidClassicSectionColor(node.colorIndex, layout.dark),
            node.event,
          ),
      );
      if (node.geometry.bottomRulePath != null) {
        canvas.drawPath(
          node.geometry.bottomRulePath!,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 3
            ..color = _brightness(
              mermaidClassicInverseColor(node.colorIndex, layout.dark),
              node.event,
            ),
        );
      }
      canvas.restore();
      // The vertical source appends each connector after its event box,
      // preserving the half-stroke overlap at the event's left edge.
      if (layout.diagram.direction == 'TD') {
        for (final line in layout.connectors) {
          if (line.afterNodeOrdinal == node.ordinal) drawConnector(line);
        }
      }
    }
    if (layout.diagram.direction == 'LR') {
      for (final line in layout.connectors) {
        if (line.axis) drawConnector(line);
      }
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant NativeTimelinePainter oldDelegate) =>
      oldDelegate.layout != layout;
}
