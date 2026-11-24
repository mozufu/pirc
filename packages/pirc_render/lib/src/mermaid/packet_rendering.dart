import '../render_l10n.dart';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'packet_model.dart';

enum NativeMermaidPacketTextAnchor { start, middle, end }

enum NativeMermaidPacketTextBaseline { alphabetic, middle }

class NativeMermaidPacketText {
  const NativeMermaidPacketText({
    required this.text,
    required this.position,
    required this.paintRect,
    required this.fontSize,
    required this.color,
    required this.anchor,
    required this.baseline,
    required this.role,
  });

  final String text;
  final Offset position;
  final Rect paintRect;
  final double fontSize;
  final Color color;
  final NativeMermaidPacketTextAnchor anchor;
  final NativeMermaidPacketTextBaseline baseline;
  final String role;
}

/// Geometry for one Mermaid PacketDB segment in a row.
class NativeMermaidPacketFieldLayout {
  const NativeMermaidPacketFieldLayout({
    required this.segment,
    required this.sourceField,
    required this.paintRect,
    required this.labelText,
    required this.startBitText,
    required this.endBitText,
  });

  final NativeMermaidPacketSegment segment;
  final NativeMermaidPacketField sourceField;

  /// Rectangle passed to Mermaid's SVG `rect` for this row-local range.
  final Rect paintRect;
  final NativeMermaidPacketText labelText;
  final NativeMermaidPacketText? startBitText;
  final NativeMermaidPacketText? endBitText;

  int get startBit => segment.startBit;
  int get endBit => segment.endBit;
  String get label => segment.label;
}

class NativeMermaidPacketRowLayout {
  NativeMermaidPacketRowLayout({
    required this.rowIndex,
    required Iterable<NativeMermaidPacketFieldLayout> fields,
  }) : fields = List.unmodifiable(fields);

  final int rowIndex;
  final List<NativeMermaidPacketFieldLayout> fields;
}

/// Mermaid 11.17.2's packet SVG geometry, scaled to the available width.
class NativeMermaidPacketLayout {
  NativeMermaidPacketLayout({
    required this.viewBoxSize,
    required this.size,
    required this.scale,
    required this.backgroundColor,
    required this.blockFillColor,
    required this.blockStrokeColor,
    required this.textColor,
    required Iterable<NativeMermaidPacketRowLayout> rows,
    required Iterable<NativeMermaidPacketText> texts,
    required this.title,
    required this.fontFamily,
    required this.dark,
  }) : rows = List.unmodifiable(rows),
       texts = List.unmodifiable(texts);

  final Size viewBoxSize;
  final Size size;
  final double scale;
  final Color backgroundColor;
  final Color blockFillColor;
  final Color blockStrokeColor;
  final Color textColor;
  final List<NativeMermaidPacketRowLayout> rows;
  final List<NativeMermaidPacketText> texts;
  final NativeMermaidPacketText title;
  final String? fontFamily;
  final bool dark;

  Iterable<NativeMermaidPacketFieldLayout> get fields sync* {
    for (final row in rows) {
      yield* row.fields;
    }
  }
}

/// Computes packet field rectangles and labels in the pinned SVG's user units.
NativeMermaidPacketLayout layoutNativeMermaidPacket(
  NativeMermaidPacketDiagram diagram, {
  required double width,
  required bool dark,
  String? fontFamily,
}) {
  if (!width.isFinite || width <= 0) {
    throw FormatException(tr("Native packet viewport width must be positive"));
  }
  final config = diagram.config;
  if (config.bitsPerRow <= 0 ||
      !config.bitWidth.isFinite ||
      config.bitWidth <= 0 ||
      !config.rowHeight.isFinite ||
      config.rowHeight <= 0 ||
      !config.paddingX.isFinite ||
      config.paddingX < 0 ||
      !config.paddingY.isFinite ||
      config.paddingY < 0 ||
      config.paddingX >= config.bitWidth ||
      config.bitsPerRow > 256 ||
      config.bitWidth > 512 ||
      config.rowHeight > 512 ||
      config.paddingX > 512 ||
      config.paddingY > 512) {
    throw FormatException(tr("Invalid native packet geometry config"));
  }

  final viewBoxWidth = config.bitWidth * config.bitsPerRow + 2;
  final totalRowHeight = config.rowHeight + config.effectivePaddingY;
  final height =
      totalRowHeight * (diagram.rows.length + 1) -
      (diagram.title.isEmpty ? config.rowHeight : 0);
  final resolvedViewBox = Size(viewBoxWidth, height);
  final scale = config.useMaxWidth
      ? math.min(1.0, width / resolvedViewBox.width)
      : 1.0;
  final palette = _NativeMermaidPacketPalette(dark);
  final textColor = palette.text;

  NativeMermaidPacketText makeText({
    required String text,
    required Offset position,
    required double fontSize,
    required NativeMermaidPacketTextAnchor anchor,
    required NativeMermaidPacketTextBaseline baseline,
    required String role,
  }) {
    final painter = _packetTextPainter(
      text,
      fontSize: fontSize,
      color: textColor,
      fontFamily: fontFamily,
    );
    final left = switch (anchor) {
      NativeMermaidPacketTextAnchor.start => position.dx,
      NativeMermaidPacketTextAnchor.middle => position.dx - painter.width / 2,
      NativeMermaidPacketTextAnchor.end => position.dx - painter.width,
    };
    final top = baseline == NativeMermaidPacketTextBaseline.middle
        ? position.dy - painter.height / 2
        : position.dy -
              painter.computeDistanceToActualBaseline(TextBaseline.alphabetic);
    return NativeMermaidPacketText(
      text: text,
      position: position,
      paintRect: Rect.fromLTWH(left, top, painter.width, painter.height),
      fontSize: fontSize,
      color: textColor,
      anchor: anchor,
      baseline: baseline,
      role: role,
    );
  }

  final rowLayouts = <NativeMermaidPacketRowLayout>[];
  final diagramTexts = <NativeMermaidPacketText>[];
  for (var rowIndex = 0; rowIndex < diagram.rows.length; rowIndex++) {
    final rowY = rowIndex * totalRowHeight + config.effectivePaddingY;
    final fieldLayouts = <NativeMermaidPacketFieldLayout>[];
    for (final segment in diagram.rows[rowIndex].fields) {
      final blockX =
          (segment.startBit % config.bitsPerRow) * config.bitWidth + 1;
      final blockWidth =
          (segment.endBit - segment.startBit + 1) * config.bitWidth -
          config.paddingX;
      final rect = Rect.fromLTWH(blockX, rowY, blockWidth, config.rowHeight);
      final label = makeText(
        text: segment.label,
        position: Offset(rect.center.dx, rowY + config.rowHeight / 2),
        fontSize: config.labelFontSize,
        anchor: NativeMermaidPacketTextAnchor.middle,
        baseline: NativeMermaidPacketTextBaseline.middle,
        role: 'packetLabel',
      );
      NativeMermaidPacketText? startBitText;
      NativeMermaidPacketText? endBitText;
      if (config.showBits) {
        final isSingleBit = segment.startBit == segment.endBit;
        startBitText = makeText(
          text: '${segment.startBit}',
          position: Offset(isSingleBit ? rect.center.dx : blockX, rowY - 2),
          fontSize: config.bitFontSize,
          anchor: isSingleBit
              ? NativeMermaidPacketTextAnchor.middle
              : NativeMermaidPacketTextAnchor.start,
          baseline: NativeMermaidPacketTextBaseline.alphabetic,
          role: isSingleBit ? 'packetByte' : tr("packetByte start"),
        );
        if (!isSingleBit) {
          endBitText = makeText(
            text: '${segment.endBit}',
            position: Offset(blockX + blockWidth, rowY - 2),
            fontSize: config.bitFontSize,
            anchor: NativeMermaidPacketTextAnchor.end,
            baseline: NativeMermaidPacketTextBaseline.alphabetic,
            role: tr("packetByte end"),
          );
        }
      }
      final fieldLayout = NativeMermaidPacketFieldLayout(
        segment: segment,
        sourceField: diagram.fields[segment.fieldIndex],
        paintRect: rect,
        labelText: label,
        startBitText: startBitText,
        endBitText: endBitText,
      );
      fieldLayouts.add(fieldLayout);
      diagramTexts.add(label);
      if (startBitText != null) diagramTexts.add(startBitText);
      if (endBitText != null) diagramTexts.add(endBitText);
    }
    rowLayouts.add(
      NativeMermaidPacketRowLayout(rowIndex: rowIndex, fields: fieldLayouts),
    );
  }

  final title = makeText(
    text: diagram.title,
    position: Offset(resolvedViewBox.width / 2, height - totalRowHeight / 2),
    fontSize: config.titleFontSize,
    anchor: NativeMermaidPacketTextAnchor.middle,
    baseline: NativeMermaidPacketTextBaseline.middle,
    role: 'packetTitle',
  );
  diagramTexts.add(title);

  return NativeMermaidPacketLayout(
    viewBoxSize: resolvedViewBox,
    size: Size(resolvedViewBox.width * scale, resolvedViewBox.height * scale),
    scale: scale,
    backgroundColor: Colors.transparent,
    blockFillColor: palette.blockFill,
    blockStrokeColor: palette.blockStroke,
    textColor: textColor,
    rows: rowLayouts,
    texts: diagramTexts,
    title: title,
    fontFamily: fontFamily,
    dark: dark,
  );
}

class NativeMermaidPacket extends StatelessWidget {
  const NativeMermaidPacket({
    super.key,
    required this.diagram,
    required this.dark,
  });

  final NativeMermaidPacketDiagram diagram;
  final bool dark;

  @override
  Widget build(BuildContext context) {
    RenderL10n.watch(context);
    final fontFamily = Theme.of(context).textTheme.bodyMedium?.fontFamily;
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.hasBoundedWidth
            ? constraints.maxWidth
            : MediaQuery.sizeOf(context).width;
        if (!width.isFinite || width <= 0) return const SizedBox.shrink();
        final layout = layoutNativeMermaidPacket(
          diagram,
          width: width,
          dark: dark,
          fontFamily: fontFamily,
        );
        return Semantics(
          container: true,
          excludeSemantics: true,
          label: diagram.semanticsLabel,
          child: Center(
            child: diagram.config.useMaxWidth
                ? CustomPaint(
                    size: layout.size,
                    painter: _NativeMermaidPacketPainter(layout),
                  )
                : OverflowBox(
                    alignment: Alignment.center,
                    minWidth: layout.size.width,
                    maxWidth: layout.size.width,
                    minHeight: layout.size.height,
                    maxHeight: layout.size.height,
                    child: CustomPaint(
                      size: layout.size,
                      painter: _NativeMermaidPacketPainter(layout),
                    ),
                  ),
          ),
        );
      },
    );
  }
}

class _NativeMermaidPacketPainter extends CustomPainter {
  const _NativeMermaidPacketPainter(this.layout);

  final NativeMermaidPacketLayout layout;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(layout.scale);
    final fill = Paint()..color = layout.blockFillColor;
    final stroke = Paint()
      ..color = layout.blockStrokeColor
      ..strokeWidth = 1
      ..style = PaintingStyle.stroke;
    for (final field in layout.fields) {
      canvas.drawRect(field.paintRect, fill);
      canvas.drawRect(field.paintRect, stroke);
    }
    for (final text in layout.texts) {
      if (text.text.isEmpty) continue;
      final painter = _packetTextPainter(
        text.text,
        fontSize: text.fontSize,
        color: text.color,
        fontFamily: layout.fontFamily,
      );
      painter.paint(canvas, text.paintRect.topLeft);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _NativeMermaidPacketPainter oldDelegate) =>
      oldDelegate.layout != layout;
}

TextPainter _packetTextPainter(
  String text, {
  required double fontSize,
  required Color color,
  required String? fontFamily,
}) {
  final painter = TextPainter(
    text: TextSpan(
      text: text,
      style: TextStyle(
        fontFamily: fontFamily,
        fontSize: fontSize,
        color: color,
      ),
    ),
    textDirection: TextDirection.ltr,
    maxLines: 1,
    textScaler: TextScaler.noScaling,
  )..layout();
  return painter;
}

class _NativeMermaidPacketPalette {
  const _NativeMermaidPacketPalette(this.dark);

  final bool dark;

  Color get blockFill =>
      dark ? const Color(0xff333333) : const Color(0xffefefef);
  Color get blockStroke => dark ? const Color(0xffe0dfdf) : Colors.black;
  Color get text => dark ? const Color(0xffe0dfdf) : Colors.black;
}
