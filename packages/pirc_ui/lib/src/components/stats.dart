import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme.dart';
import '../tokens.g.dart';

/// One number of [StatGrid].
@immutable
class StatValue {
  const StatValue(this.value, this.label);
  final String value;
  final String label;
}

/// `e-stats`: numbers in a grid of [columns] (2 on phones, 3 on tablets),
/// 2 apart, each on `surface.layer` (20/26 600 over a 12.5 label), in one
/// rounded block 16 from each side.
class StatGrid extends StatelessWidget {
  const StatGrid({super.key, required this.values, this.columns = 2});

  final List<StatValue> values;
  final int columns;

  @override
  Widget build(BuildContext context) {
    final colors = PircColorTokens.of(context);
    final rows = <List<StatValue>>[
      for (var i = 0; i < values.length; i += columns)
        values.sublist(i, math.min(i + columns, values.length)),
    ];
    Widget cell(StatValue? v) => Expanded(
      child: Container(
        color: v == null ? null : colors['surface.layer'],
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        child: v == null
            ? null
            : Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                spacing: 2,
                children: [
                  Text(
                    v.value,
                    maxLines: 1,
                    softWrap: false,
                    overflow: TextOverflow.fade,
                    style: TextStyle(
                      fontSize: 20,
                      height: 26 / 20,
                      fontWeight: FontWeight.w600,
                      color: colors['text.primary'],
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                  Text(
                    v.label,
                    style: TextStyle(
                      fontSize: 12.5,
                      height: 17 / 12.5,
                      color: colors['text.muted'],
                    ),
                  ),
                ],
              ),
      ),
    );
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(PircRadius.lg),
        child: Column(
          spacing: 2,
          children: [
            for (final row in rows)
              IntrinsicHeight(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  spacing: 2,
                  children: [
                    for (var i = 0; i < columns; i++)
                      cell(i < row.length ? row[i] : null),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// `e-card`: a block on `surface.layer` (radius 16, padding 14) with an
/// optional header: the [title] and text [tabs] (`e-tt`).
class StatCard extends StatelessWidget {
  const StatCard({
    super.key,
    this.title,
    this.tabs = const [],
    this.selectedTab = 0,
    this.onTab,
    required this.child,
  });

  final String? title;
  final List<String> tabs;
  final int selectedTab;
  final ValueChanged<int>? onTab;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final colors = PircColorTokens.of(context);
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: colors['surface.layer'],
        borderRadius: BorderRadius.circular(PircRadius.lg),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (title != null || tabs.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Row(
                spacing: 8,
                children: [
                  Expanded(
                    child: Text(
                      title ?? '',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: colors['text.primary'],
                      ),
                    ),
                  ),
                  for (final (i, tab) in tabs.indexed)
                    Semantics(
                      button: true,
                      selected: i == selectedTab,
                      child: InkWell(
                        onTap: onTab == null ? null : () => onTab!(i),
                        borderRadius: BorderRadius.circular(8),
                        child: Container(
                          height: 32,
                          padding: const EdgeInsets.symmetric(horizontal: 6),
                          alignment: Alignment.center,
                          child: Text(
                            tab,
                            style: TextStyle(
                              fontSize: 13.5,
                              fontWeight: i == selectedTab
                                  ? FontWeight.w600
                                  : FontWeight.w500,
                              color: i == selectedTab
                                  ? colors['text.primary']
                                  : colors['text.muted'],
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          child,
        ],
      ),
    );
  }
}

/// The five heat levels: none, then 28 %, 52 %, 76 % and 100 % accent over
/// `surface.layer`.
List<Color> heatColors(PircColorTokens colors) {
  final accent = colors['accent.default'];
  final layer = colors['surface.layer'];
  return [
    colors['fill.hoverStrong'],
    Color.lerp(layer, accent, 0.28)!,
    Color.lerp(layer, accent, 0.52)!,
    Color.lerp(layer, accent, 0.76)!,
    accent,
  ];
}

/// `e-hm-x`: labels spread under a chart (11.5 muted, 8 above).
class ChartLabels extends StatelessWidget {
  const ChartLabels(this.labels, {super.key});
  final List<String> labels;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 8),
    child: Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        for (final label in labels)
          Text(
            label,
            style: TextStyle(
              fontSize: 11.5,
              color: PircColorTokens.of(context)['text.muted'],
            ),
          ),
      ],
    ),
  );
}

/// `e-hm`: tokens per day, one column per week (Sunday on top), 3 apart,
/// square cells with radius 3; [levels] (0–4) run down each week, oldest
/// week first. Under it the [monthLabels] and a legend from [lessLabel] to
/// [moreLabel].
class Heatmap extends StatelessWidget {
  const Heatmap({
    super.key,
    required this.levels,
    required this.monthLabels,
    required this.lessLabel,
    required this.moreLabel,
    required this.semanticLabel,
  });

  final List<int> levels;
  final List<String> monthLabels;
  final String lessLabel;
  final String moreLabel;
  final String semanticLabel;

  @override
  Widget build(BuildContext context) {
    final colors = PircColorTokens.of(context);
    final palette = heatColors(colors);
    final weeks = (levels.length / 7).ceil();
    final muted = TextStyle(fontSize: 11.5, color: colors['text.muted']);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Semantics(
          image: true,
          label: semanticLabel,
          child: LayoutBuilder(
            builder: (context, box) {
              final cell = weeks == 0
                  ? 0.0
                  : (box.maxWidth - 3 * (weeks - 1)) / weeks;
              return SizedBox(
                height: cell * 7 + 3 * 6,
                child: CustomPaint(
                  painter: _HeatPainter(levels, weeks, cell, palette),
                ),
              );
            },
          ),
        ),
        ChartLabels(monthLabels),
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.end,
            spacing: 3,
            children: [
              Text(lessLabel, style: muted),
              for (final color in palette)
                Container(
                  width: 11,
                  height: 11,
                  decoration: BoxDecoration(
                    color: color,
                    borderRadius: BorderRadius.circular(3),
                  ),
                ),
              Text(moreLabel, style: muted),
            ],
          ),
        ),
      ],
    );
  }
}

class _HeatPainter extends CustomPainter {
  const _HeatPainter(this.levels, this.weeks, this.cell, this.palette);
  final List<int> levels;
  final int weeks;
  final double cell;
  final List<Color> palette;

  @override
  void paint(Canvas canvas, Size size) {
    for (var i = 0; i < levels.length; i++) {
      final x = (i ~/ 7) * (cell + 3);
      final y = (i % 7) * (cell + 3);
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(x, y, cell, cell),
          const Radius.circular(3),
        ),
        Paint()..color = palette[levels[i].clamp(0, 4)],
      );
    }
  }

  @override
  bool shouldRepaint(_HeatPainter old) =>
      old.levels != levels || old.cell != cell || old.palette != palette;
}

/// `e-wk`: one bar per week (120 high, 4 apart, top radius 4); the last is
/// this week in accent, the others 52 % accent. Heights are relative to the
/// largest value.
class WeeklyBars extends StatelessWidget {
  const WeeklyBars({
    super.key,
    required this.values,
    required this.labels,
    required this.semanticLabel,
  });

  final List<double> values;
  final List<String> labels;
  final String semanticLabel;

  @override
  Widget build(BuildContext context) {
    final colors = PircColorTokens.of(context);
    final top = values.fold<double>(0, math.max);
    final accent = colors['accent.default'];
    final past = Color.lerp(colors['surface.layer'], accent, 0.52)!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Semantics(
          image: true,
          label: semanticLabel,
          child: SizedBox(
            height: 120,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              spacing: 4,
              children: [
                for (final (i, value) in values.indexed)
                  Expanded(
                    child: Container(
                      height: math.max(2, top <= 0 ? 0 : 120 * value / top),
                      decoration: BoxDecoration(
                        color: i == values.length - 1 ? accent : past,
                        borderRadius: const BorderRadius.vertical(
                          top: Radius.circular(4),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
        ChartLabels(labels),
      ],
    );
  }
}

/// `e-cum`: the running total as an area (`accent.soft`) under a 2 line
/// (accent), 120 high, from 0 at the left.
class CumulativeArea extends StatelessWidget {
  const CumulativeArea({
    super.key,
    required this.totals,
    required this.labels,
    required this.semanticLabel,
  });

  /// Running totals, oldest first.
  final List<double> totals;
  final List<String> labels;
  final String semanticLabel;

  @override
  Widget build(BuildContext context) {
    final colors = PircColorTokens.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Semantics(
          image: true,
          label: semanticLabel,
          child: SizedBox(
            height: 120,
            child: CustomPaint(
              painter: _AreaPainter(
                totals,
                colors['accent.soft'],
                colors['accent.default'],
              ),
            ),
          ),
        ),
        ChartLabels(labels),
      ],
    );
  }
}

class _AreaPainter extends CustomPainter {
  const _AreaPainter(this.totals, this.fill, this.line);
  final List<double> totals;
  final Color fill;
  final Color line;

  @override
  void paint(Canvas canvas, Size size) {
    if (totals.isEmpty) return;
    final top = totals.fold<double>(0, math.max);
    Offset at(int i) => Offset(
      totals.length == 1 ? size.width : size.width * i / (totals.length - 1),
      size.height - (top <= 0 ? 0 : size.height * totals[i] / top),
    );
    final edge = Path()..moveTo(at(0).dx, at(0).dy);
    for (var i = 1; i < totals.length; i++) {
      edge.lineTo(at(i).dx, at(i).dy);
    }
    final area = Path.from(edge)
      ..lineTo(size.width, size.height)
      ..lineTo(0, size.height)
      ..close();
    canvas.drawPath(area, Paint()..color = fill);
    canvas.drawPath(
      edge,
      Paint()
        ..color = line
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..strokeJoin = StrokeJoin.round,
    );
  }

  @override
  bool shouldRepaint(_AreaPainter old) =>
      old.totals != totals || old.fill != fill || old.line != line;
}

/// One row of [BarList].
@immutable
class BarListItem {
  const BarListItem({
    required this.leading,
    required this.name,
    required this.value,
    required this.fraction,
  });

  /// An avatar (28) or a [BarListMark].
  final Widget leading;
  final String name;
  final String value;

  /// 0–1 of the track.
  final double fraction;
}

/// `e-mic`: a model's two letters in a 28 rounded square.
class BarListMark extends StatelessWidget {
  const BarListMark(this.text, {super.key});
  final String text;

  @override
  Widget build(BuildContext context) {
    final colors = PircColorTokens.of(context);
    return Container(
      width: 28,
      height: 28,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: colors['fill.hoverStrong'],
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          color: colors['text.secondary'],
        ),
      ),
    );
  }
}

/// `e-br`: who or which model used how much: the [BarListItem.leading]
/// (28), the name over a 6 track, and the value at the end. The values
/// share one column, so every track is as wide.
class BarList extends StatelessWidget {
  const BarList({super.key, required this.items});
  final List<BarListItem> items;

  @override
  Widget build(BuildContext context) {
    final colors = PircColorTokens.of(context);
    return Table(
      columnWidths: const {
        0: FixedColumnWidth(38),
        1: FlexColumnWidth(),
        2: IntrinsicColumnWidth(),
      },
      defaultVerticalAlignment: TableCellVerticalAlignment.middle,
      children: [
        for (final item in items)
          TableRow(
            children: [
              Padding(
                padding: const EdgeInsets.only(right: 10),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: item.leading,
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  spacing: 4,
                  children: [
                    Text(
                      item.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 14,
                        height: 20 / 14,
                        color: colors['text.primary'],
                      ),
                    ),
                    Container(
                      height: 6,
                      alignment: Alignment.centerLeft,
                      decoration: BoxDecoration(
                        color: colors['fill.hover'],
                        borderRadius: BorderRadius.circular(3),
                      ),
                      child: FractionallySizedBox(
                        widthFactor: item.fraction.clamp(0, 1),
                        heightFactor: 1,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: colors['accent.default'],
                            borderRadius: BorderRadius.circular(3),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.only(left: 10),
                child: Text(
                  item.value,
                  textAlign: TextAlign.end,
                  style: TextStyle(
                    fontSize: 13,
                    color: colors['text.secondary'],
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ),
            ],
          ),
      ],
    );
  }
}
