import '../render_l10n.dart';

enum NativeMermaidRadarGraticule { circle, polygon }

class NativeMermaidRadarConfig {
  const NativeMermaidRadarConfig({
    this.width = 600,
    this.height = 600,
    this.marginTop = 50,
    this.marginRight = 50,
    this.marginBottom = 50,
    this.marginLeft = 50,
    this.axisScaleFactor = 1,
    this.axisLabelFactor = 1.05,
    this.curveTension = .17,
    this.useMaxWidth = true,
  });

  final double width;
  final double height;
  final double marginTop;
  final double marginRight;
  final double marginBottom;
  final double marginLeft;
  final double axisScaleFactor;
  final double axisLabelFactor;
  final double curveTension;
  final bool useMaxWidth;

  double get totalWidth => width + marginLeft + marginRight;
  double get totalHeight => height + marginTop + marginBottom;
}

class NativeMermaidRadarOptions {
  const NativeMermaidRadarOptions({
    this.showLegend = true,
    this.ticks = 5,
    this.max,
    this.min = 0,
    this.graticule = NativeMermaidRadarGraticule.circle,
  });

  final bool showLegend;
  final int ticks;
  final double? max;
  final double min;
  final NativeMermaidRadarGraticule graticule;
}

class NativeMermaidRadarAxis {
  const NativeMermaidRadarAxis({required this.name, required this.label});

  final String name;
  final String label;
}

class NativeMermaidRadarCurve {
  NativeMermaidRadarCurve({
    required this.name,
    required this.label,
    required Iterable<double> entries,
  }) : entries = List.unmodifiable(entries);

  final String name;
  final String label;

  /// Numeric values in the same order as [NativeMermaidRadarDiagram.axes].
  final List<double> entries;
}

class NativeMermaidRadarDiagram {
  NativeMermaidRadarDiagram({
    this.title = '',
    this.accessibleTitle = '',
    this.accessibleDescription = '',
    required Iterable<NativeMermaidRadarAxis> axes,
    required Iterable<NativeMermaidRadarCurve> curves,
    this.options = const NativeMermaidRadarOptions(),
    this.config = const NativeMermaidRadarConfig(),
  }) : axes = List.unmodifiable(axes),
       curves = List.unmodifiable(curves);

  final String title;
  final String accessibleTitle;
  final String accessibleDescription;
  final List<NativeMermaidRadarAxis> axes;
  final List<NativeMermaidRadarCurve> curves;
  final NativeMermaidRadarOptions options;
  final NativeMermaidRadarConfig config;

  String get semanticsLabel {
    final parts = <String>[tr("Radar chart")];
    if (accessibleTitle.isNotEmpty) parts.add(accessibleTitle);
    if (accessibleDescription.isNotEmpty) parts.add(accessibleDescription);
    if (title.isNotEmpty) parts.add(title);
    parts.add('Axes: ${axes.map((axis) => axis.label).join(', ')}');
    for (final curve in curves) {
      final values = <String>[];
      for (var i = 0; i < axes.length && i < curve.entries.length; i++) {
        values.add('${axes[i].label} ${_formatValue(curve.entries[i])}');
      }
      parts.add('${curve.label}: ${values.join(', ')}');
    }
    return parts.join('. ');
  }
}

String _formatValue(double value) =>
    value == value.truncateToDouble() ? value.toInt().toString() : '$value';
