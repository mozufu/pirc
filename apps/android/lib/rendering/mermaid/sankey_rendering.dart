import '../render_l10n.dart';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';

import 'd3_sankey_layout.dart';
import 'sankey_model.dart';

/// Native Flutter rendering for Mermaid Sankey diagrams.
///
/// The graph uses Mermaid's pinned d3-sankey defaults, then the complete
/// diagram is uniformly scaled down to fit the available width, matching the
/// source SVG's `max-width: 100%; height: auto` behavior.
class NativeMermaidSankey extends StatelessWidget {
  const NativeMermaidSankey({
    super.key,
    required this.diagram,
    required this.dark,
    this.prefix = '',
    this.suffix = '',
  });

  final NativeSankeyDiagram diagram;
  final bool dark;
  final String prefix;
  final String suffix;

  @override
  Widget build(BuildContext context) {
    RenderL10n.watch(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final viewportWidth = constraints.maxWidth.isFinite
            ? constraints.maxWidth
            : MediaQuery.sizeOf(context).width;
        final layout = layoutNativeMermaidSankey(
          diagram,
          dark: dark,
          fontFamily: Theme.of(context).textTheme.bodyMedium?.fontFamily,
          prefix: prefix,
          suffix: suffix,
        );
        final scale = math.min(1.0, viewportWidth / layout.size.width);
        final fittedSize = Size(
          layout.size.width * scale,
          layout.size.height * scale,
        );
        final semanticValue = [
          for (final node in layout.nodes) '${node.node.id}: ${node.value}',
          for (final flow in layout.flows)
            '${flow.flow.sourceId} to ${flow.flow.targetId}: ${flow.flow.value}',
        ].join('. ');
        return Semantics(
          container: true,
          explicitChildNodes: true,
          label: tr("Sankey diagram"),
          value: semanticValue,
          child: SizedBox.fromSize(
            size: fittedSize,
            child: ClipRect(
              child: FittedBox(
                fit: BoxFit.contain,
                alignment: Alignment.topLeft,
                child: SizedBox.fromSize(
                  size: layout.size,
                  child: CustomPaint(
                    size: layout.size,
                    painter: NativeMermaidSankeyPainter(layout),
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

class NativeMermaidSankeyPainter extends CustomPainter {
  const NativeMermaidSankeyPainter(this.layout);

  final NativeSankeyLayout layout;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.clipRect(Offset.zero & size);

    for (final flow in layout.flows) {
      final startX = flow.path.getBounds().left;
      final endX = flow.path.getBounds().right;
      final start = flow.sourceColor.withValues(alpha: 0.5);
      final end = flow.targetColor.withValues(alpha: 0.5);
      final paint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = math.max(1, flow.width)
        ..blendMode = BlendMode.multiply
        ..shader = LinearGradient(
          begin: Alignment.centerLeft,
          end: Alignment.centerRight,
          colors: [start, end],
        ).createShader(Rect.fromLTRB(startX, 0, endX, size.height));
      canvas.drawPath(flow.path, paint);
    }

    final nodePaint = Paint()
      ..style = PaintingStyle.fill
      ..isAntiAlias = false;
    for (final node in layout.nodes) {
      nodePaint.color = node.color;
      canvas.drawRect(node.bounds, nodePaint);
    }

    for (final node in layout.nodes) {
      final painter = TextPainter(
        text: TextSpan(
          text: node.label,
          style: layout.labelStyle.copyWith(color: layout.labelColor),
        ),
        textAlign: node.labelAnchor,
        textDirection: TextDirection.ltr,
        textScaler: TextScaler.noScaling,
      )..layout();
      painter.paint(canvas, node.labelBounds.topLeft);
      painter.dispose();
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant NativeMermaidSankeyPainter oldDelegate) =>
      oldDelegate.layout != layout;

  @override
  SemanticsBuilderCallback get semanticsBuilder =>
      (size) => [
        for (var index = 0; index < layout.nodes.length; index++)
          CustomPainterSemantics(
            key: ValueKey('sankey-node-$index'),
            rect: layout.nodes[index].bounds,
            properties: SemanticsProperties(
              label:
                  '${layout.nodes[index].node.id}, ${layout.nodes[index].value}',
              textDirection: TextDirection.ltr,
            ),
          ),
      ];

  @override
  bool shouldRebuildSemantics(
    covariant NativeMermaidSankeyPainter oldDelegate,
  ) => oldDelegate.layout != layout;
}
