import '../render_l10n.dart';

/// A point or class style understood by Mermaid 11.17.2 quadrant charts.
///
/// Colors retain their authored hex spelling (with or without `#`) and
/// `strokeWidth` retains Mermaid's required `<integer>px` spelling.
class NativeMermaidQuadrantStyle {
  const NativeMermaidQuadrantStyle({
    this.radius,
    this.color,
    this.strokeColor,
    this.strokeWidth,
  });

  final int? radius;
  final String? color;
  final String? strokeColor;
  final String? strokeWidth;

  NativeMermaidQuadrantStyle merge(NativeMermaidQuadrantStyle override) =>
      NativeMermaidQuadrantStyle(
        radius: override.radius ?? radius,
        color: override.color ?? color,
        strokeColor: override.strokeColor ?? strokeColor,
        strokeWidth: override.strokeWidth ?? strokeWidth,
      );
}

class NativeMermaidQuadrantPoint {
  const NativeMermaidQuadrantPoint({
    required this.label,
    required this.x,
    required this.y,
    this.className,
    this.style = const NativeMermaidQuadrantStyle(),
  });

  final String label;

  /// Mermaid's normalized coordinate, in the inclusive range [0, 1].
  final double x;
  final double y;
  final String? className;
  final NativeMermaidQuadrantStyle style;
}

/// Layout settings implemented from Mermaid 11.17.2's quadrant chart builder.
/// Values are SVG user units; the surrounding widget scales the complete
/// viewBox to fit its available width.
class NativeMermaidQuadrantConfig {
  const NativeMermaidQuadrantConfig({
    this.chartWidth = 500,
    this.chartHeight = 500,
    this.titlePadding = 10,
    this.titleFontSize = 20,
    this.quadrantPadding = 5,
    this.xAxisLabelPadding = 5,
    this.yAxisLabelPadding = 5,
    this.xAxisLabelFontSize = 16,
    this.yAxisLabelFontSize = 16,
    this.quadrantLabelFontSize = 16,
    this.quadrantTextTopPadding = 5,
    this.pointTextPadding = 5,
    this.pointLabelFontSize = 12,
    this.pointRadius = 5,
    this.xAxisPosition = 'top',
    this.yAxisPosition = 'left',
    this.quadrantInternalBorderStrokeWidth = 1,
    this.quadrantExternalBorderStrokeWidth = 2,
    this.showXAxis = true,
    this.showYAxis = true,
    this.showTitle = true,
  });

  final double chartWidth;
  final double chartHeight;
  final double titlePadding;
  final double titleFontSize;
  final double quadrantPadding;
  final double xAxisLabelPadding;
  final double yAxisLabelPadding;
  final double xAxisLabelFontSize;
  final double yAxisLabelFontSize;
  final double quadrantLabelFontSize;
  final double quadrantTextTopPadding;
  final double pointTextPadding;
  final double pointLabelFontSize;
  final double pointRadius;
  final String xAxisPosition;
  final String yAxisPosition;
  final double quadrantInternalBorderStrokeWidth;
  final double quadrantExternalBorderStrokeWidth;
  final bool showXAxis;
  final bool showYAxis;
  final bool showTitle;
}

/// Parsed, immutable content for the supported Mermaid quadrant grammar.
///
/// Quadrant text is stored in Mermaid's numeric order: 1 is upper-right, 2 is
/// upper-left, 3 is lower-left, and 4 is lower-right.
class NativeMermaidQuadrantDiagram {
  NativeMermaidQuadrantDiagram({
    this.title,
    this.xAxisLeftText = '',
    this.xAxisRightText = '',
    this.yAxisBottomText = '',
    this.yAxisTopText = '',
    required List<String> quadrants,
    Iterable<NativeMermaidQuadrantPoint> points = const [],
    Map<String, NativeMermaidQuadrantStyle> classes = const {},
    this.config = const NativeMermaidQuadrantConfig(),
    this.accessibleTitle = '',
    this.accessibleDescription = '',
  }) : quadrants = List.unmodifiable(quadrants),
       points = List.unmodifiable(points),
       classes = Map.unmodifiable(classes) {
    if (this.quadrants.length != 4) {
      throw ArgumentError.value(
        quadrants,
        'quadrants',
        'Requires four labels.',
      );
    }
  }

  final String? title;
  final String xAxisLeftText;
  final String xAxisRightText;
  final String yAxisBottomText;
  final String yAxisTopText;
  final List<String> quadrants;
  final List<NativeMermaidQuadrantPoint> points;
  final Map<String, NativeMermaidQuadrantStyle> classes;
  final NativeMermaidQuadrantConfig config;
  final String accessibleTitle;
  final String accessibleDescription;

  String get semanticsLabel {
    final parts = <String>[tr("Quadrant chart")];
    if (accessibleTitle.isNotEmpty) parts.add(accessibleTitle);
    if (accessibleDescription.isNotEmpty) parts.add(accessibleDescription);
    if ((title ?? '').isNotEmpty) parts.add(title!);
    if (xAxisLeftText.isNotEmpty || xAxisRightText.isNotEmpty) {
      parts.add(
        tr("X axis: {0}{1}", [
          xAxisLeftText,
          xAxisRightText.isEmpty ? '' : ' to $xAxisRightText',
        ]),
      );
    }
    if (yAxisBottomText.isNotEmpty || yAxisTopText.isNotEmpty) {
      parts.add(
        tr("Y axis: {0}{1}", [
          yAxisBottomText,
          yAxisTopText.isEmpty ? '' : ' to $yAxisTopText',
        ]),
      );
    }
    for (var i = 0; i < quadrants.length; i++) {
      final label = quadrants[i];
      if (label.isNotEmpty) parts.add(tr("Quadrant {0}: {1}", [i + 1, label]));
    }
    for (final point in points) {
      parts.add('${point.label}: ${point.x}, ${point.y}');
    }
    return parts.join('. ');
  }
}
