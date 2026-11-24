import '../render_l10n.dart';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'gantt_model.dart';

class NativeGanttTaskLayout {
  const NativeGanttTaskLayout(
    this.task,
    this.bounds,
    this.labelPosition,
    this.anchor,
  );
  final NativeMermaidGanttTask task;
  final Rect bounds;
  final Offset labelPosition;
  final TextAlign anchor;
}

class NativeGanttTick {
  const NativeGanttTick(this.date, this.x, this.label);
  final DateTime date;
  final double x;
  final String label;
}

class NativeGanttLayout {
  const NativeGanttLayout(
    this.diagram,
    this.size,
    this.tasks,
    this.ticks,
    this.exclusions,
  );
  final NativeMermaidGanttDiagram diagram;
  final Size size;
  final List<NativeGanttTaskLayout> tasks;
  final List<NativeGanttTick> ticks;
  final List<Rect> exclusions;
  double x(DateTime value) {
    final span = diagram.end.difference(diagram.start).inMicroseconds;
    return 75 +
        (span == 0
            ? (size.width - 150) / 2
            : (value.difference(diagram.start).inMicroseconds /
                      span *
                      (size.width - 150))
                  .roundToDouble());
  }
}

TextPainter _text(String text, String? family, double fontSize, Color color) =>
    TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          fontFamily: family,
          fontFamilyFallback: const ['sans-serif'],
          fontSize: fontSize,
          height: 1,
          letterSpacing: 0,
          fontWeight: FontWeight.w400,
          color: color,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();

/// Uses the pinned ganttRenderer's user-unit dimensions and rounded time scale.
/// Labels deliberately use renderEnd for x but logical end for their anchor,
/// matching Mermaid even when an excluded day makes those branches differ.
NativeGanttLayout layoutNativeMermaidGantt(
  NativeMermaidGanttDiagram diagram, {
  required double width,
  String? fontFamily,
}) {
  if (diagram.tasks.isEmpty) {
    throw FormatException(tr("Native Gantt requires at least one task"));
  }
  if (!width.isFinite || width <= 150) {
    throw FormatException(
      tr("Native Gantt viewport is too narrow for its fixed margins"),
    );
  }
  if (diagram.tasks.any(
    (t) => t.statuses.contains(NativeMermaidGanttTaskStatus.vertical),
  )) {
    throw FormatException(
      tr("Native Gantt vertical task markers are not yet rendered"),
    );
  }
  final size = Size(width, 100 + diagram.tasks.length * 24);
  final shell = NativeGanttLayout(diagram, size, const [], const [], const []);
  final tasks = <NativeGanttTaskLayout>[];
  for (var i = 0; i < diagram.tasks.length; i++) {
    final task = diagram.tasks[i];
    final start = shell.x(task.start), logicalEnd = shell.x(task.end);
    var left = start, right = shell.x(task.renderEnd ?? task.end);
    if (task.isMilestone) {
      left = start + (logicalEnd - start) / 2 - 10;
      right = left + 20;
    }
    final painter = _text(task.label, fontFamily, 11, Colors.black);
    final textWidth = painter.width;
    painter.dispose();
    final labelX = textWidth > right - left
        ? right + textWidth + 37.5 > width
              ? left - 5
              : right + 5
        : (left + right) / 2;
    final anchorEnd = task.isMilestone ? start + 20 : logicalEnd;
    final anchor = textWidth > anchorEnd - start
        ? anchorEnd + textWidth + 37.5 > width
              ? TextAlign.right
              : TextAlign.left
        : TextAlign.center;
    tasks.add(
      NativeGanttTaskLayout(
        task,
        Rect.fromLTWH(left, 50 + i * 24, right - left, 20),
        Offset(labelX, 63.5 + i * 24),
        anchor,
      ),
    );
  }
  final exclusions = <Rect>[];
  var day = DateTime.utc(
    diagram.start.year,
    diagram.start.month,
    diagram.start.day,
  );
  DateTime? excludedStart;
  var count = 0;
  while (!day.isAfter(diagram.end)) {
    if (++count > 60000) {
      throw FormatException(tr("Native Gantt exclusion range is too large"));
    }
    if (diagram.isExcluded(day)) {
      excludedStart ??= day;
    } else if (excludedStart != null) {
      exclusions.add(
        Rect.fromLTWH(
          shell.x(excludedStart),
          35,
          shell.x(day.subtract(const Duration(milliseconds: 1))) -
              shell.x(excludedStart),
          size.height - 85,
        ),
      );
      excludedStart = null;
    }
    day = day.add(const Duration(days: 1));
  }
  if (excludedStart != null) {
    exclusions.add(
      Rect.fromLTWH(
        shell.x(excludedStart),
        35,
        shell.x(day.subtract(const Duration(milliseconds: 1))) -
            shell.x(excludedStart),
        size.height - 85,
      ),
    );
  }
  final ticks = _ticks(diagram.start, diagram.end)
      .map(
        (date) => NativeGanttTick(
          date,
          shell.x(date) + .5,
          _format(date, diagram.axisFormat ?? '%Y-%m-%d'),
        ),
      )
      .toList();
  return NativeGanttLayout(
    diagram,
    size,
    List.unmodifiable(tasks),
    List.unmodifiable(ticks),
    List.unmodifiable(exclusions),
  );
}

List<DateTime> _ticks(DateTime start, DateTime end) {
  if (start == end) return [start];
  // d3-time's default ten ticks choose between these calendar intervals.
  final choices = <(Duration, String, int)>[
    for (final n in [1, 5, 15, 30]) (Duration(seconds: n), 'second', n),
    for (final n in [1, 5, 15, 30]) (Duration(minutes: n), 'minute', n),
    for (final n in [1, 3, 6, 12]) (Duration(hours: n), 'hour', n),
    (const Duration(days: 1), 'day', 1),
    (const Duration(days: 2), 'day', 2),
    (const Duration(days: 7), 'week', 1),
    (const Duration(days: 30), 'month', 1),
    (const Duration(days: 90), 'month', 3),
    (const Duration(days: 365), 'year', 1),
  ];
  final target = end.difference(start).inMicroseconds / 10;
  var index = choices.indexWhere(
    (choice) => choice.$1.inMicroseconds >= target,
  );
  if (index < 0) index = choices.length - 1;
  if (index > 0 &&
      target / choices[index - 1].$1.inMicroseconds <
          choices[index].$1.inMicroseconds / target) {
    index--;
  }
  final (_, unit, every) = choices[index];
  var date = switch (unit) {
    'second' => DateTime.utc(
      start.year,
      start.month,
      start.day,
      start.hour,
      start.minute,
      start.second,
    ),
    'minute' => DateTime.utc(
      start.year,
      start.month,
      start.day,
      start.hour,
      start.minute,
    ),
    'hour' => DateTime.utc(start.year, start.month, start.day, start.hour),
    'day' || 'week' => DateTime.utc(start.year, start.month, start.day),
    'month' => DateTime.utc(start.year, start.month),
    _ => DateTime.utc(start.year),
  };
  final result = <DateTime>[];
  var attempts = 0;
  while (!date.isAfter(end)) {
    if (++attempts > 20000) {
      throw FormatException(tr("Native Gantt axis contains too many ticks"));
    }
    final aligned = switch (unit) {
      'second' => date.second % every == 0,
      'minute' => date.minute % every == 0,
      'hour' => date.hour % every == 0,
      'day' => (date.day - 1) % every == 0,
      'week' => date.weekday == DateTime.sunday,
      'month' => (date.month - 1) % every == 0,
      _ => date.year % every == 0,
    };
    if (!date.isBefore(start) && aligned) result.add(date);
    date = switch (unit) {
      'month' => DateTime.utc(date.year, date.month + 1),
      'year' => DateTime.utc(date.year + 1),
      'week' => date.add(const Duration(days: 1)),
      'day' => date.add(const Duration(days: 1)),
      _ => date.add(
        unit == 'hour'
            ? const Duration(hours: 1)
            : unit == 'minute'
            ? const Duration(minutes: 1)
            : const Duration(seconds: 1),
      ),
    };
  }
  return result;
}

String _format(DateTime date, String format) {
  final days = [
    tr("Mon"),
    tr("Tue"),
    tr("Wed"),
    tr("Thu"),
    tr("Fri"),
    tr("Sat"),
    tr("Sun"),
  ];
  final months = [
    tr("Jan"),
    tr("Feb"),
    tr("Mar"),
    tr("Apr"),
    tr("May"),
    tr("Jun"),
    tr("Jul"),
    tr("Aug"),
    tr("Sep"),
    tr("Oct"),
    tr("Nov"),
    tr("Dec"),
  ];
  String padded(int value, [int digits = 2]) => '$value'.padLeft(digits, '0');
  return format.replaceAllMapped(
    RegExp(r'%[A-Za-z%]'),
    (m) => switch (m[0]) {
      '%Y' => padded(date.year, 4),
      '%y' => padded(date.year % 100),
      '%m' => padded(date.month),
      '%d' => padded(date.day),
      '%e' => '${date.day}'.padLeft(2),
      '%H' => padded(date.hour),
      '%M' => padded(date.minute),
      '%S' => padded(date.second),
      '%a' => days[date.weekday - 1],
      '%b' => months[date.month - 1],
      '%%' => '%',
      _ => throw FormatException(
        tr("Native Gantt axis format {0} is not yet supported", [m[0]]),
      ),
    },
  );
}

class NativeMermaidGantt extends StatelessWidget {
  const NativeMermaidGantt({
    super.key,
    required this.diagram,
    required this.dark,
    this.layout,
    this.clock,
  });
  final NativeGanttLayout? layout;
  final DateTime? clock;
  final NativeMermaidGanttDiagram diagram;
  final bool dark;
  @override
  Widget build(BuildContext context) {
    RenderL10n.watch(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final family = Theme.of(context).textTheme.bodyMedium?.fontFamily;
        final layout =
            this.layout ??
            layoutNativeMermaidGantt(
              diagram,
              width: MediaQuery.sizeOf(context).width,
              fontFamily: family,
            );
        final width = math.min(layout.size.width, constraints.maxWidth);
        final scale = width / layout.size.width;
        return Semantics(
          label:
              '${diagram.title ?? 'Gantt chart'}. ${diagram.sections.map((s) => s.name).join(', ')}. ${diagram.tasks.map((t) => '${t.label.trim()}: ${t.start.toIso8601String()} to ${t.end.toIso8601String()}').join('; ')}',
          image: true,
          child: SizedBox(
            width: width,
            height: layout.size.height * scale,
            child: CustomPaint(
              painter: NativeGanttPainter(
                layout,
                dark: dark,
                fontFamily: family,
                clock: clock,
              ),
            ),
          ),
        );
      },
    );
  }
}

class NativeGanttPainter extends CustomPainter {
  const NativeGanttPainter(
    this.layout, {
    required this.dark,
    this.fontFamily,
    this.clock,
  });
  final NativeGanttLayout layout;
  final bool dark;
  final String? fontFamily;
  final DateTime? clock;
  void _label(
    Canvas canvas,
    String value,
    Offset position,
    double fontSize,
    Color color,
    TextAlign anchor, {
    bool central = false,
  }) {
    final painter = _text(value, fontFamily, fontSize, color);
    final x =
        position.dx -
        (anchor == TextAlign.center
            ? painter.width / 2
            : anchor == TextAlign.right
            ? painter.width
            : 0);
    final y =
        position.dy -
        (central
            ? painter.height / 2
            : painter.computeDistanceToActualBaseline(TextBaseline.alphabetic));
    painter.paint(canvas, Offset(x, y));
    painter.dispose();
  }

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.width / layout.size.width);
    final height = layout.size.height;
    final titleColor = dark ? const Color(0xfff9fffe) : const Color(0xff060504);
    final outside = dark ? const Color(0xffcccccc) : const Color(0xff0f1115);
    final grid = Paint()
      ..color = (dark ? const Color(0xfff9fafb) : const Color(0xff0f1115))
      ..strokeWidth = 1;
    for (final rect in layout.exclusions) {
      canvas.drawRect(
        rect,
        Paint()
          ..color = dark ? const Color(0xff9f9758) : const Color(0xffeeeeee),
      );
    }
    for (final item in layout.tasks) {
      final section = item.task.sectionIndex % 4;
      final band = dark
          ? section.isEven
                ? const Color(0xffb4ac76)
                : const Color(0xff333333)
          : section.isEven
          ? const Color(0xfff9fafb)
          : Colors.white;
      canvas.drawRect(
        Rect.fromLTWH(0, item.bounds.top - 2, layout.size.width - 37.5, 24),
        Paint()..color = band.withValues(alpha: .2),
      );
    }
    for (final tick in layout.ticks) {
      canvas.drawLine(Offset(tick.x, 35), Offset(tick.x, height - 50), grid);
      _label(
        canvas,
        tick.label,
        Offset(tick.x, height - 50 + 13),
        10,
        outside,
        TextAlign.center,
      );
    }
    for (final item in layout.tasks) {
      final flags = item.task.statuses;
      final active = flags.contains(NativeMermaidGanttTaskStatus.active),
          done = flags.contains(NativeMermaidGanttTaskStatus.done),
          critical = flags.contains(NativeMermaidGanttTaskStatus.critical);
      var fill = dark ? const Color(0xff595c5c) : const Color(0xffedf3fe);
      var stroke = dark ? Colors.white : const Color(0xff4176e6);
      if (active) {
        fill = dark ? const Color(0xff81b1db) : Colors.white;
        stroke = critical
            ? dark
                  ? const Color(0xffe83737)
                  : const Color(0xffff8888)
            : dark
            ? Colors.white
            : const Color(0xffedf3fe);
      } else if (done) {
        fill = const Color(0xffd3d3d3);
        stroke = critical
            ? dark
                  ? const Color(0xffe83737)
                  : const Color(0xffff8888)
            : const Color(0xff808080);
      } else if (critical) {
        fill = dark ? const Color(0xffe83737) : Colors.red;
        stroke = dark ? const Color(0xffe83737) : const Color(0xffff8888);
      }
      canvas.save();
      if (item.task.isMilestone) {
        final center = item.bounds.center;
        canvas.translate(center.dx, center.dy);
        canvas.rotate(math.pi / 4);
        canvas.translate(-center.dx, -center.dy);
      }
      final shape = RRect.fromRectAndRadius(
        item.bounds,
        const Radius.circular(3),
      );
      canvas.drawRRect(shape, Paint()..color = fill);
      canvas.drawRRect(
        shape,
        Paint()
          ..color = stroke
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2,
      );
      canvas.restore();
      final inside = dark ? Colors.white : const Color(0xff0f1115);
      final labelColor = item.anchor == TextAlign.center
          ? done
                ? const Color(0xff0f1115)
                : inside
          : outside;
      _label(
        canvas,
        item.task.label,
        item.labelPosition,
        11,
        labelColor,
        item.anchor,
      );
    }
    var previous = 0;
    for (final section in layout.diagram.sections) {
      final count = section.tasks.length;
      if (count == 0) continue;
      _label(
        canvas,
        section.name,
        Offset(10, 50 + previous * 24 + count * 12),
        11,
        titleColor,
        TextAlign.left,
        central: true,
      );
      previous += count;
    }
    _label(
      canvas,
      layout.diagram.title ?? '',
      Offset(layout.size.width / 2, 25),
      18,
      titleColor,
      TextAlign.center,
    );
    if (layout.diagram.todayMarkerEnabled) {
      final today = (clock ?? DateTime.now()).toUtc();
      final x = layout.x(today);
      canvas.drawLine(
        Offset(x, 25),
        Offset(x, height - 25),
        Paint()
          ..color = dark ? const Color(0xffdb5757) : Colors.red
          ..strokeWidth = 2,
      );
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(NativeGanttPainter oldDelegate) =>
      oldDelegate.layout != layout ||
      oldDelegate.dark != dark ||
      oldDelegate.fontFamily != fontFamily ||
      oldDelegate.clock != clock;
}
