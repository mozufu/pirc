import '../render_l10n.dart';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:csslib/parser.dart' as css;
import 'c4_model.dart';
import 'c4_layout.dart';

Color nativeC4Color(String? source, Color fallback) {
  if (source == null || source.trim().isEmpty) return fallback;
  try {
    final color = css.Color.css(source).rgba;
    return Color.fromRGBO(color.r, color.g, color.b, (color.a ?? 1).toDouble());
  } catch (_) {
    throw FormatException(tr("Unsupported C4 color: {0}", [source]));
  }
}

void validateNativeC4Styles(NativeC4Diagram diagram) {
  for (final shape in diagram.shapes) {
    nativeC4Fill(shape);
    nativeC4Stroke(shape);
    nativeC4Color(shape.fontColor, Colors.white);
  }
  for (final boundary in diagram.boundaries) {
    nativeC4Color(boundary.backgroundColor, Colors.transparent);
    nativeC4Color(boundary.borderColor, const Color(0xff444444));
    nativeC4Color(boundary.fontColor, const Color(0xff444444));
  }
  for (final rel in diagram.relations) {
    nativeC4Color(rel.lineColor, const Color(0xff444444));
    nativeC4Color(rel.textColor, const Color(0xff444444));
  }
}

Color nativeC4Fill(NativeC4Shape shape) {
  final base = shape.kind
      .replaceFirst(RegExp(r'^external_'), '')
      .replaceFirst(RegExp(r'_(db|queue)$'), '');
  final external = shape.kind.startsWith('external_');
  final fallback = switch (base) {
    'person' => external ? const Color(0xff686868) : const Color(0xff08427b),
    'system' => external ? const Color(0xff999999) : const Color(0xff1168bd),
    'container' => external ? const Color(0xffb3b3b3) : const Color(0xff438dd5),
    'component' => external ? const Color(0xffcccccc) : const Color(0xff85bbf0),
    _ => const Color(0xff1168bd),
  };
  return nativeC4Color(shape.backgroundColor, fallback);
}

Color nativeC4Stroke(NativeC4Shape shape) {
  final base = shape.kind
      .replaceFirst(RegExp(r'^external_'), '')
      .replaceFirst(RegExp(r'_(db|queue)$'), '');
  final external = shape.kind.startsWith('external_');
  final fallback = switch (base) {
    'person' => external ? const Color(0xff8a8a8a) : const Color(0xff073b6f),
    'system' => external ? const Color(0xff8a8a8a) : const Color(0xff3c7fc0),
    'container' => external ? const Color(0xffa6a6a6) : const Color(0xff3c7fc0),
    'component' => external ? const Color(0xffbfbfbf) : const Color(0xff78a8d8),
    _ => const Color(0xff3c7fc0),
  };
  return nativeC4Color(shape.borderColor, fallback);
}

/// Flutter shapes and text; neither a browser nor an SVG/bitmap image is used.
class NativeMermaidC4 extends StatelessWidget {
  const NativeMermaidC4({
    super.key,
    required this.diagram,
    required this.dark,
    this.fontFamily,
  });
  final NativeC4Diagram diagram;
  final bool dark;
  final String? fontFamily;
  @override
  Widget build(BuildContext context) {
    RenderL10n.watch(context);
    final layout = layoutNativeMermaidC4(
      diagram,
      screenWidth: MediaQuery.sizeOf(context).width,
      fontFamily: fontFamily,
      resolveColor: nativeC4Color,
      titleColor: dark ? const Color(0xffcccccc) : const Color(0xff0f1115),
    );
    final summary = [
      diagram.kind,
      if (diagram.title?.isNotEmpty == true) diagram.title!,
      for (final node in layout.nodes.values)
        '${node.sections.map((s) => s.text).join('. ')}.',
      for (final b in layout.boundaries.values.where(
        (b) => b.boundary.alias != 'global',
      ))
        '${b.label.text}. ${b.type.text}. ${b.description?.text ?? ''}',
      for (final r in layout.relations)
        '${r.relation.from} → ${r.relation.to}: ${r.label.text}. ${r.technology?.text ?? ''}',
    ].join(' ');
    return Semantics(
      image: true,
      label: summary,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final scale = constraints.hasBoundedWidth
              ? math.min(1.0, constraints.maxWidth / layout.size.width)
              : 1.0;
          return Align(
            alignment: Alignment.topCenter,
            child: SizedBox(
              key: const ValueKey('native-mermaid-c4-chart'),
              width: layout.size.width * scale,
              height: layout.size.height * scale,
              child: FittedBox(
                fit: BoxFit.contain,
                alignment: Alignment.topLeft,
                clipBehavior: Clip.hardEdge,
                child: SizedBox.fromSize(
                  size: layout.size,
                  child: CustomPaint(
                    size: layout.size,
                    painter: NativeC4Painter(layout, dark: dark),
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

class NativeC4Painter extends CustomPainter {
  NativeC4Painter(this.layout, {this.dark = false});
  final bool dark;
  final NativeC4Layout layout;
  void _text(Canvas canvas, NativeC4Text text, Offset center) {
    text.painter.paint(
      canvas,
      center - Offset(text.size.width / 2, text.size.height / 2),
    );
  }

  void _boundary(Canvas canvas, NativeC4BoundaryLayout boundary) {
    final model = boundary.boundary, rect = boundary.bounds;
    final border = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = nativeC4Color(model.borderColor, const Color(0xff444444));
    final path = Path()
      ..addRRect(RRect.fromRectAndRadius(rect, const Radius.circular(2.5)));
    if (model.backgroundColor?.isNotEmpty == true) {
      canvas.drawPath(
        path,
        Paint()
          ..color = nativeC4Color(model.backgroundColor, Colors.transparent),
      );
    }
    if (model.nodeType != null) {
      canvas.drawPath(path, border);
    } else {
      for (final metric in path.computeMetrics()) {
        for (var distance = 0.0; distance < metric.length; distance += 14) {
          canvas.drawPath(
            metric.extractPath(distance, math.min(distance + 7, metric.length)),
            border,
          );
        }
      }
    }
    _text(
      canvas,
      boundary.label,
      Offset(rect.center.dx, rect.top + boundary.labelY),
    );
    if (model.type.isNotEmpty) {
      _text(
        canvas,
        boundary.type,
        Offset(rect.center.dx, rect.top + boundary.typeY),
      );
    }
    if (boundary.description != null) {
      _text(
        canvas,
        boundary.description!,
        Offset(rect.center.dx, rect.top + boundary.descriptionY),
      );
    }
  }

  void _node(Canvas canvas, NativeC4NodeLayout node) {
    canvas.save();
    canvas.translate(node.bounds.left, node.bounds.top);
    final fill = Paint()..color = nativeC4Fill(node.shape);
    final stroke = Paint()
      ..color = nativeC4Stroke(node.shape)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;
    canvas.drawPath(node.geometry.outline, fill);
    canvas.drawPath(node.geometry.outline, stroke);
    for (final accent in node.geometry.accentPaths) {
      canvas.drawPath(accent, stroke);
    }
    final labelRect = node.geometry.labelRect;
    var y = labelRect.top;
    for (final section in node.sections) {
      section.painter.paint(
        canvas,
        Offset(
          labelRect.center.dx - section.size.width / 2,
          y + (section.size.height - section.painter.height) / 2,
        ),
      );
      y += section.size.height + 3;
    }
    canvas.restore();
  }

  void _arrow(Canvas canvas, Offset tip, Offset previous, Color color) {
    final delta = tip - previous;
    if (delta.distance < .001) return;
    final direction = delta / delta.distance,
        normal = Offset(-direction.dy, direction.dx);
    canvas.drawPath(
      Path()
        ..moveTo(tip.dx, tip.dy)
        ..lineTo(
          (tip - direction * 10 + normal * 5).dx,
          (tip - direction * 10 + normal * 5).dy,
        )
        ..lineTo(
          (tip - direction * 10 - normal * 5).dx,
          (tip - direction * 10 - normal * 5).dy,
        )
        ..close(),
      Paint()..color = color,
    );
  }

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.translate(layout.viewBoxOffset.dx, layout.viewBoxOffset.dy);
    for (final entry in layout.paintOrder) {
      final alias = entry.substring(2);
      if (entry.startsWith('n:')) {
        _node(canvas, layout.nodes[alias]!);
      } else {
        _boundary(canvas, layout.boundaries[alias]!);
      }
    }
    for (final rel in layout.relations) {
      final color = nativeC4Color(
        rel.relation.lineColor,
        const Color(0xff444444),
      );
      final path = Path()..moveTo(rel.start.dx, rel.start.dy);
      if (rel.control == null) {
        path.lineTo(rel.end.dx, rel.end.dy);
      } else {
        path.quadraticBezierTo(
          rel.control!.dx,
          rel.control!.dy,
          rel.end.dx,
          rel.end.dy,
        );
      }
      canvas.drawPath(
        path,
        Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1,
      );
      final markerColor = dark
          ? const Color(0xffcccccc)
          : const Color(0xff0f1115);
      if (rel.relation.kind != 'rel_b') {
        _arrow(canvas, rel.end, rel.control ?? rel.start, markerColor);
      }
      if (rel.relation.kind == 'birel' || rel.relation.kind == 'rel_b') {
        _arrow(canvas, rel.start, rel.control ?? rel.end, markerColor);
      }
      _text(canvas, rel.label, rel.labelCenter);
      if (rel.technology != null) {
        _text(canvas, rel.technology!, rel.technologyCenter);
      }
    }
    final title = layout.title;
    if (title != null) {
      title.painter.paint(
        canvas,
        layout.titleBaseline -
            Offset(
              0,
              title.painter.computeDistanceToActualBaseline(
                TextBaseline.alphabetic,
              ),
            ),
      );
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant NativeC4Painter oldDelegate) =>
      oldDelegate.layout != layout;
}
