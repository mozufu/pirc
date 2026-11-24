import '../render_l10n.dart';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:html/dom.dart' as html;
import 'package:html/parser.dart' as html_parser;
import 'package:markdown/markdown.dart' as md;

import 'kanban_model.dart';

const _baseColumnPalette = <(double, double, double)>[
  (210, 20, 83.0392156863),
  (248.8235294118, 89.4736842105, 81.2745098039),
  (278.8235294118, 89.4736842105, 81.2745098039),
  (308.8235294118, 89.4736842105, 81.2745098039),
  (338.8235294118, 89.4736842105, 81.2745098039),
  (8.8235294118, 89.4736842105, 81.2745098039),
  (68.8235294118, 89.4736842105, 85),
  (128.8235294118, 89.4736842105, 81.2745098039),
  (158.8235294118, 89.4736842105, 81.2745098039),
  (188.8235294118, 89.4736842105, 81.2745098039),
];
const _darkColumnPalette = <(double, double, double)>[
  (321.6393442623, 65.5913978495, 28.2352941176),
  (194.4, 16.5562913907, 39.6078431373),
  (23.0769230769, 49.0566037736, 30.7843137255),
  (0, 83.3333333333, 33.5294117647),
  (289.1666666667, 100, 24.1176470588),
  (35.1315789474, 98.7012987013, 40.1960784314),
  (106.1538461538, 84.4155844156, 25.0980392157),
  (235, 21.4285714286, 20.9803921569),
  (217.8378378378, 100, 31.7647058824),
  (202.4516129032, 98.7261146496, 40.7843137255),
];

class NativeKanbanCardLayout {
  const NativeKanbanCardLayout({
    required this.card,
    required this.bounds,
    required this.titleSpan,
    required this.titleTop,
    required this.titleHeight,
    required this.titleLineCount,
    this.ticketSpan,
    this.assignedSpan,
    required this.metadataTop,
    required this.metadataHeight,
    required this.priorityColor,
  });

  final NativeMermaidKanbanCard card;
  final Rect bounds;
  final TextSpan titleSpan;
  final double titleTop;
  final double titleHeight;
  final int titleLineCount;
  final TextSpan? ticketSpan;
  final TextSpan? assignedSpan;
  final double metadataTop;
  final double metadataHeight;
  final Color? priorityColor;
}

class NativeKanbanColumnLayout {
  const NativeKanbanColumnLayout({
    required this.column,
    required this.bounds,
    required this.labelSpan,
    required this.labelTop,
    required this.labelHeight,
    required this.fill,
    required this.labelColor,
    required this.cards,
  });

  final NativeMermaidKanbanColumn column;
  final Rect bounds;
  final TextSpan labelSpan;
  final double labelTop;
  final double labelHeight;
  final Color fill;
  final Color labelColor;
  final List<NativeKanbanCardLayout> cards;
}

class NativeMermaidKanbanLayout {
  const NativeMermaidKanbanLayout({
    required this.board,
    required this.size,
    required this.viewBox,
    required this.scale,
    required this.columns,
    required this.dark,
    required this.fontFamily,
    required this.background,
    required this.borderColor,
    required this.textColor,
  });

  final NativeMermaidKanbanBoard board;
  final Size size;
  final Rect viewBox;
  final double scale;
  final List<NativeKanbanColumnLayout> columns;
  final bool dark;
  final String? fontFamily;
  final Color background;
  final Color borderColor;
  final Color textColor;
}

/// Source-shaped layout for Mermaid's fixed-width Kanban columns.
///
/// Mermaid uses 200px columns, 10px card spacing, 185px cards and a
/// `useMaxWidth` SVG viewBox. The native renderer fits that same wide board to
/// the available width instead of requiring horizontal scrolling.
NativeMermaidKanbanLayout layoutNativeMermaidKanban(
  NativeMermaidKanbanBoard board, {
  required double width,
  required bool dark,
  String? fontFamily,
}) {
  if (!width.isFinite || width <= 0) {
    throw FormatException(tr("Kanban width must be positive"));
  }
  const columnWidth = 200.0;
  const cardWidth = 185.0;
  const cardGap = 5.0;
  const outerPadding = 8.0;
  const columnTop = -300.0;
  final textColor = dark ? const Color(0xffcccccc) : const Color(0xff0f1115);
  final font = fontFamily;
  final titleStyle = TextStyle(
    fontFamily: font,
    fontSize: 13,
    // Mermaid's `addHtmlSpan` sets the label div to line-height: 1.5. The
    // rendered labels are 13px, so multi-line labels use 19.5px line boxes.
    height: 1.5,
    color: textColor,
  );
  final metadataStyle = TextStyle(
    fontFamily: font,
    fontSize: 12,
    height: 1.5,
    color: dark ? const Color(0xffcccccc) : const Color(0xff55585e),
  );
  final columnLabels = <({TextSpan span, double height})>[];
  for (final column in board.columns) {
    final span = _markdownSpan(
      column.label,
      titleStyle.copyWith(color: dark ? const Color(0xffd3d3d3) : textColor),
      dark: dark,
    );
    final painter = _measure(
      span,
      maxWidth: columnWidth,
      textAlign: TextAlign.center,
    );
    columnLabels.add((span: span, height: math.max(16.0, painter.height)));
    painter.dispose();
  }
  final maxLabelHeight = math
      .max(
        25.0,
        columnLabels.fold<double>(
          0,
          (height, item) => math.max(height, item.height),
        ),
      )
      .toDouble();
  final columns = <NativeKanbanColumnLayout>[];
  var right = 100.0;
  var bottom = columnTop + 50;

  for (var columnIndex = 0; columnIndex < board.columns.length; columnIndex++) {
    final column = board.columns[columnIndex];
    final centerX = columnWidth * (columnIndex + 1) + columnIndex * 5.0;
    final columnBounds = Rect.fromLTWH(
      centerX - columnWidth / 2,
      columnTop,
      columnWidth,
      50.0,
    );
    final cardStart = columnTop + maxLabelHeight;
    var cardTop = cardStart;
    final cards = <NativeKanbanCardLayout>[];

    for (final card in column.cards) {
      final titleSpan = _markdownSpan(card.label, titleStyle, dark: dark);
      final titlePainter = _measure(titleSpan, maxWidth: cardWidth - 20);
      final titleHeight = math.max(16.0, titlePainter.height).toDouble();
      final titleLineCount = titlePainter.computeLineMetrics().length;
      titlePainter.dispose();
      final ticketSpan = card.ticket?.isNotEmpty == true
          ? TextSpan(text: card.ticket, style: metadataStyle)
          : null;
      final assignedSpan = card.assigned?.isNotEmpty == true
          ? TextSpan(text: card.assigned, style: metadataStyle)
          : null;
      final ticketPainter = ticketSpan == null
          ? null
          : _measure(ticketSpan, maxWidth: cardWidth / 2 - 12);
      final assignedPainter = assignedSpan == null
          ? null
          : _measure(assignedSpan, maxWidth: cardWidth / 2 - 12);
      final metadataHeight = math
          .max(ticketPainter?.height ?? 0, assignedPainter?.height ?? 0)
          .toDouble();
      ticketPainter?.dispose();
      assignedPainter?.dispose();
      // Match the source's half-row allowance for ordinary one-line metadata.
      // If metadata wraps, enlarge the card enough to keep every line visible.
      final sourceCardHeight = titleHeight + 20 + metadataHeight / 2;
      final unclippedHeight = titleHeight + 11 + metadataHeight;
      final cardHeight = math.max(sourceCardHeight, unclippedHeight).toDouble();
      final cardBounds = Rect.fromLTWH(
        centerX - cardWidth / 2,
        cardTop,
        cardWidth,
        cardHeight,
      );
      cards.add(
        NativeKanbanCardLayout(
          card: card,
          bounds: cardBounds,
          titleSpan: titleSpan,
          titleTop: cardTop + 10,
          titleHeight: titleHeight,
          titleLineCount: titleLineCount,
          ticketSpan: ticketSpan,
          assignedSpan: assignedSpan,
          metadataTop: cardTop + 10 + titleHeight + 1,
          metadataHeight: metadataHeight,
          priorityColor: _priorityColor(card.priority),
        ),
      );
      cardTop += cardHeight + cardGap;
      right = math.max(right, cardBounds.right);
    }

    final contentHeight =
        math.max(cardTop - cardStart + 30.0, 50.0).toDouble() +
        (maxLabelHeight - 25.0);
    final bounds = Rect.fromLTWH(
      columnBounds.left,
      columnTop,
      columnWidth,
      contentHeight,
    );
    right = math.max(right, bounds.right);
    bottom = math.max(bottom, bounds.bottom);
    columns.add(
      NativeKanbanColumnLayout(
        column: column,
        bounds: bounds,
        labelSpan: columnLabels[columnIndex].span,
        // The source foreignObject starts at the column top. Its two-line
        // label fills the measured header height, ending where cards begin.
        labelTop: columnTop,
        labelHeight: columnLabels[columnIndex].height,
        fill: _columnFill(columnIndex, dark),
        labelColor: dark ? const Color(0xffd3d3d3) : textColor,
        cards: List.unmodifiable(cards),
      ),
    );
  }

  final viewBox = Rect.fromLTRB(
    100 - outerPadding,
    columnTop - outerPadding,
    right + outerPadding,
    bottom + outerPadding,
  );
  final scale = math.min(1.0, width / viewBox.width).toDouble();
  return NativeMermaidKanbanLayout(
    board: board,
    size: Size(viewBox.width * scale, viewBox.height * scale),
    viewBox: viewBox,
    scale: scale,
    columns: List.unmodifiable(columns),
    dark: dark,
    fontFamily: font,
    background: dark ? const Color(0xff333333) : const Color(0xffffffff),
    borderColor: dark ? const Color(0xffcccccc) : const Color(0xff4176e6),
    textColor: textColor,
  );
}

class NativeMermaidKanban extends StatelessWidget {
  const NativeMermaidKanban({
    super.key,
    required this.board,
    required this.dark,
  });

  final NativeMermaidKanbanBoard board;
  final bool dark;

  @override
  Widget build(BuildContext context) {
    RenderL10n.watch(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final availableWidth = constraints.maxWidth.isFinite
            ? constraints.maxWidth
            : MediaQuery.sizeOf(context).width;
        final layout = layoutNativeMermaidKanban(
          board,
          width: availableWidth,
          dark: dark,
          fontFamily: Theme.of(context).textTheme.bodyMedium?.fontFamily,
        );
        final summary = board.columns
            .map(
              (column) =>
                  '${column.label}: ${column.cards.map((card) => card.label).join(', ')}',
            )
            .join('. ');
        return Semantics(
          container: true,
          label: tr("Kanban board"),
          value: summary,
          child: SizedBox(
            width: layout.size.width,
            height: layout.size.height,
            child: FittedBox(
              fit: BoxFit.contain,
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: layout.viewBox.width,
                height: layout.viewBox.height,
                child: ClipRect(
                  child: CustomPaint(
                    size: Size(layout.viewBox.width, layout.viewBox.height),
                    painter: NativeMermaidKanbanPainter(layout),
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

class NativeMermaidKanbanPainter extends CustomPainter {
  const NativeMermaidKanbanPainter(this.layout);

  final NativeMermaidKanbanLayout layout;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.clipRect(Offset.zero & size);
    canvas.translate(-layout.viewBox.left, -layout.viewBox.top);
    for (final column in layout.columns) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(column.bounds, const Radius.circular(5)),
        Paint()..color = column.fill,
      );
      _paintText(
        canvas,
        column.labelSpan,
        Offset(column.bounds.left, column.labelTop),
        maxWidth: column.bounds.width,
        align: TextAlign.center,
      );
      for (final card in column.cards) {
        canvas.drawRRect(
          RRect.fromRectAndRadius(card.bounds, const Radius.circular(5)),
          Paint()..color = layout.background,
        );
        canvas.drawRRect(
          RRect.fromRectAndRadius(card.bounds, const Radius.circular(5)),
          Paint()
            ..color = layout.borderColor
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1,
        );
        final priorityColor = card.priorityColor;
        if (priorityColor != null) {
          // The source uses x = left + 2 and y = top + floor(rx / 2).
          // With the default radius 5, the vertical inset is 2px.
          canvas.drawLine(
            Offset(card.bounds.left + 2, card.bounds.top + 2),
            Offset(card.bounds.left + 2, card.bounds.bottom - 2),
            Paint()
              ..color = priorityColor
              ..strokeWidth = 4,
          );
        }
        _paintText(
          canvas,
          card.titleSpan,
          Offset(card.bounds.left + 10, card.titleTop),
          maxWidth: card.bounds.width - 20,
        );
        if (card.metadataHeight > 0) {
          if (card.ticketSpan != null) {
            _paintText(
              canvas,
              card.ticketSpan!,
              Offset(card.bounds.left + 10, card.metadataTop),
              maxWidth: card.bounds.width / 2 - 12,
            );
          }
          if (card.assignedSpan != null) {
            _paintText(
              canvas,
              card.assignedSpan!,
              Offset(card.bounds.center.dx, card.metadataTop),
              maxWidth: card.bounds.width / 2 - 12,
              align: TextAlign.right,
            );
          }
        }
      }
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant NativeMermaidKanbanPainter oldDelegate) =>
      oldDelegate.layout != layout;
}

TextSpan _markdownSpan(String source, TextStyle style, {required bool dark}) {
  final document = md.Document(
    encodeHtml: false,
    extensionSet: md.ExtensionSet.gitHubFlavored,
  );
  final htmlSource = md.renderToHtml(
    document.parseLines(source.replaceAll('\r\n', '\n').split('\n')),
  );
  final fragment = html_parser.parseFragment(htmlSource);

  List<InlineSpan> children(Iterable<html.Node> nodes) {
    final result = <InlineSpan>[];
    for (final node in nodes) {
      if (node is html.Text) {
        if (node.data.isNotEmpty) result.add(TextSpan(text: node.data));
        continue;
      }
      if (node is! html.Element) continue;
      final name = node.localName;
      if (name == 'br') {
        result.add(const TextSpan(text: '\n'));
        continue;
      }
      if (name == 'p') {
        if (result.isNotEmpty) result.add(const TextSpan(text: '\n'));
        result.add(TextSpan(children: children(node.nodes)));
        continue;
      }
      if (name == 'img') {
        throw FormatException(
          tr("Kanban Markdown images are not supported by the native renderer"),
        );
      }
      if (node.attributes['style']?.trim().isNotEmpty == true) {
        throw FormatException(
          tr("Inline HTML styles in Kanban labels are unsupported"),
        );
      }
      final decoration = switch (name) {
        'strong' || 'b' => const TextStyle(fontWeight: FontWeight.w700),
        'em' || 'i' => const TextStyle(fontStyle: FontStyle.italic),
        'code' => TextStyle(
          fontFamily: 'monospace',
          backgroundColor: dark
              ? const Color(0xff3a3a3a)
              : const Color(0xffeeeeee),
        ),
        'del' || 's' => const TextStyle(decoration: TextDecoration.lineThrough),
        'a' => const TextStyle(decoration: TextDecoration.underline),
        'span' => const TextStyle(),
        _ => throw FormatException(
          'Kanban Markdown element <$name> is not supported',
        ),
      };
      result.add(TextSpan(style: decoration, children: children(node.nodes)));
    }
    return result;
  }

  return TextSpan(style: style, children: children(fragment.nodes));
}

TextPainter _measure(
  TextSpan span, {
  required double maxWidth,
  TextAlign textAlign = TextAlign.left,
}) => TextPainter(
  text: span,
  textDirection: TextDirection.ltr,
  textAlign: textAlign,
)..layout(maxWidth: maxWidth);

void _paintText(
  Canvas canvas,
  TextSpan span,
  Offset offset, {
  required double maxWidth,
  TextAlign align = TextAlign.left,
}) {
  final painter = _measure(span, maxWidth: maxWidth, textAlign: align);
  painter.paint(canvas, offset);
  painter.dispose();
}

Color? _priorityColor(String? priority) => switch (priority) {
  'Very High' => const Color(0xffff0000),
  'High' => const Color(0xffffa500),
  'Medium' => null,
  'Low' => const Color(0xff0000ff),
  'Very Low' => const Color(0xffadd8e6),
  _ => null,
};

Color _columnFill(int index, bool dark) {
  final palette = dark ? _darkColumnPalette : _baseColumnPalette;
  final color = palette[index % palette.length];
  return _fromHsl(color.$1, color.$2, color.$3);
}

Color _fromHsl(double hue, double saturation, double lightness) {
  final h = (hue % 360) / 360;
  final s = saturation / 100;
  final l = lightness / 100;
  if (s == 0) {
    final gray = (l * 255).round();
    return Color.fromARGB(255, gray, gray, gray);
  }
  final q = l < .5 ? l * (1 + s) : l + s - l * s;
  final p = 2 * l - q;
  double channel(double t) {
    var value = t;
    if (value < 0) value += 1;
    if (value > 1) value -= 1;
    if (value < 1 / 6) return p + (q - p) * 6 * value;
    if (value < 1 / 2) return q;
    if (value < 2 / 3) return p + (q - p) * (2 / 3 - value) * 6;
    return p;
  }

  return Color.fromARGB(
    255,
    (channel(h + 1 / 3) * 255).round(),
    (channel(h) * 255).round(),
    (channel(h - 1 / 3) * 255).round(),
  );
}
