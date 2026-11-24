import '../render_l10n.dart';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:csslib/parser.dart' as css;
import 'package:html/parser.dart' as html;
import 'package:html/dom.dart' as dom;
import 'package:markdown/markdown.dart' as md;
import 'requirement_model.dart';
import 'flowchart.dart';

String nativeRequirementPlainText(String source) =>
    html
        .parseFragment(
          source.replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n'),
        )
        .text ??
    '';

class NativeRequirementStyle {
  NativeRequirementStyle({
    required this.fill,
    required this.stroke,
    required this.ink,
  });
  Color fill, stroke, ink;
  double strokeWidth = 1, fontSize = 13;
  FontWeight weight = FontWeight.normal;
  FontStyle fontStyle = FontStyle.normal;
  List<double> dash = [];
}

Color _color(String value, Color current) {
  if (value == 'none' || value == 'transparent') return Colors.transparent;
  if (value == 'currentColor') return current;
  try {
    final c = css.Color.css(value).rgba;
    return Color.fromRGBO(c.r, c.g, c.b, (c.a ?? 1).toDouble());
  } catch (_) {
    throw FormatException(tr("Unsupported requirement color: {0}", [value]));
  }
}

NativeRequirementStyle nativeRequirementStyle(
  NativeRequirementDiagram diagram,
  NativeRequirementNode node,
  bool dark,
) {
  final out = NativeRequirementStyle(
    fill: dark ? const Color(0xff1f2020) : const Color(0xffedf3fe),
    stroke: dark ? const Color(0xffcccccc) : const Color(0xff4176e6),
    ink: dark ? const Color(0xffcccccc) : const Color(0xff0f1115),
  );
  String? fillValue, strokeValue;
  // The pinned renderer consumes styles copied into the node by the DB.
  // Class definitions made before a default node do not style that node.
  final declarations = node.cssStyles;
  double number(String value) {
    final parsed = double.tryParse(value.replaceFirst(RegExp(r'px$'), ''));
    if (parsed == null || !parsed.isFinite || parsed < 0) {
      throw FormatException(tr("Unsupported requirement size: {0}", [value]));
    }
    return parsed;
  }

  for (final declaration in declarations) {
    final separator = declaration.indexOf(':');
    if (separator < 0) {
      continue; // Invalid CSS fragments have no browser effect.
    }
    final property = declaration.substring(0, separator).trim().toLowerCase();
    final value = declaration.substring(separator + 1).trim();
    switch (property) {
      case 'fill':
        fillValue = value;
      case 'stroke':
        strokeValue = value;
      case 'color':
        out.ink = _color(value, out.ink);
      case 'stroke-width':
        out.strokeWidth = number(value);
      case 'font-size':
        out.fontSize = number(value);
        if (out.fontSize == 0 || out.fontSize > 256) {
          throw const FormatException('Requirement font size out of range');
        }
      case 'font-weight':
        out.weight = switch (value) {
          'normal' => FontWeight.normal,
          'bold' || 'bolder' => FontWeight.bold,
          _ => FontWeight.values[(number(value) / 100 - 1).round().clamp(0, 8)],
        };
      case 'font-style':
        if (!const {'normal', 'italic', 'oblique'}.contains(value)) {
          throw FormatException('Unsupported font style: $value');
        }
        out.fontStyle = value == 'normal' ? FontStyle.normal : FontStyle.italic;
      case 'stroke-dasharray':
        out.dash = value == 'none'
            ? []
            : value
                  .split(RegExp(r'[,\s]+'))
                  .where((v) => v.isNotEmpty)
                  .map(number)
                  .toList();
        if (out.dash.isNotEmpty && out.dash.every((n) => n == 0)) out.dash = [];
        if (out.dash.isNotEmpty && out.dash.reduce((a, b) => a + b) < .25) {
          throw const FormatException('Requirement dash pattern too dense');
        }
      case 'label': // The pinned requirementBox still paints its source name.
      case 'rx': // Rough rectangle paths do not consume CSS rectangle radii.
      case 'ry':
        break;
      default:
        throw FormatException(
          tr("Unsupported requirement style: {0}", [property]),
        );
    }
  }
  if (fillValue != null) out.fill = _color(fillValue, out.ink);
  if (strokeValue != null) out.stroke = _color(strokeValue, out.ink);
  return out;
}

String _markdownLabel(String source) {
  String convert(dom.Node node) {
    if (node is dom.Text) return node.data;
    if (node is! dom.Element) return '';
    final body = node.nodes.map(convert).join();
    return switch (node.localName) {
      'br' => '\n',
      'b' || 'strong' => '**$body**',
      'i' || 'em' => '*$body*',
      'code' => '`$body`',
      'del' || 's' => '~~$body~~',
      'script' || 'style' => '',
      _ => body,
    };
  }

  return html.parseFragment(source).nodes.map(convert).join();
}

TextSpan _span(String source, TextStyle style, {bool markup = true}) {
  if (!markup) return TextSpan(text: source, style: style);
  final plain = _markdownLabel(source);
  InlineSpan visit(md.Node node, TextStyle inherited) {
    if (node is md.Text) {
      return TextSpan(
        text: html.parseFragment(node.text).text,
        style: inherited,
      );
    }
    final element = node as md.Element;
    final next = switch (element.tag) {
      'strong' => inherited.copyWith(fontWeight: FontWeight.bold),
      'em' => inherited.copyWith(fontStyle: FontStyle.italic),
      'code' => inherited.copyWith(fontFamily: 'monospace'),
      'del' => inherited.copyWith(decoration: TextDecoration.lineThrough),
      _ => inherited,
    };
    return TextSpan(
      text: element.tag == 'br' ? '\n' : null,
      style: next,
      children: element.children?.map((n) => visit(n, next)).toList(),
    );
  }

  return TextSpan(
    style: style,
    children: md.Document(
      encodeHtml: false,
      extensionSet: md.ExtensionSet.gitHubFlavored,
    ).parseInline(plain).map((n) => visit(n, style)).toList(),
  );
}

class NativeRequirementText {
  NativeRequirementText(
    String value,
    NativeRequirementStyle style, {
    String? fontFamily,
    bool bold = false,
    bool markup = true,
  }) {
    final span = _span(
      value,
      TextStyle(
        fontFamily: fontFamily ?? 'sans-serif',
        fontSize: style.fontSize,
        height: 1.5,
        color: style.ink,
        fontWeight: bold ? FontWeight.bold : style.weight,
        fontStyle: style.fontStyle,
        letterSpacing: 0,
      ),
      markup: markup,
    );
    text = span.toPlainText();
    painter = TextPainter(
      text: span,
      textDirection: TextDirection.ltr,
      textAlign: TextAlign.center,
      textScaler: TextScaler.noScaling,
    )..layout();
  }
  late final String text;
  late final TextPainter painter;
  Size get size => painter.size;
}

class NativeRequirementField {
  NativeRequirementField(this.label, this.centerY, this.header);
  final NativeRequirementText label;
  final double centerY;
  final bool header;
}

class NativeRequirementNodeLayout {
  NativeRequirementNodeLayout(
    this.node,
    this.style,
    this.fields,
    this.size,
    this.divider,
  );
  final NativeRequirementNode node;
  final NativeRequirementStyle style;
  final List<NativeRequirementField> fields;
  final Size size;
  final double? divider;
  Rect bounds = Rect.zero;
  Rect fieldBounds(NativeRequirementField field) => Rect.fromLTWH(
    field.header
        ? bounds.center.dx - field.label.size.width / 2
        : bounds.left + 10,
    bounds.top + 20 + field.centerY - field.label.size.height / 2,
    field.label.size.width,
    field.label.size.height,
  );
}

class NativeRequirementEdgeLayout {
  NativeRequirementEdgeLayout(
    this.relation,
    this.path,
    this.labelCenter,
    this.label,
  );
  final NativeRequirementRelation relation;
  final Path path;
  final Offset labelCenter;
  final NativeRequirementText label;
}

class NativeRequirementLayout {
  NativeRequirementLayout(
    this.diagram,
    this.size,
    this.nodes,
    this.edges,
    this.title,
    this.titleCenter,
  );
  final NativeRequirementDiagram diagram;
  final Size size;
  final List<NativeRequirementNodeLayout> nodes;
  final List<NativeRequirementEdgeLayout> edges;
  final NativeRequirementText? title;
  final Offset? titleCenter;
}

NativeRequirementLayout layoutNativeMermaidRequirement(
  NativeRequirementDiagram diagram, {
  bool dark = false,
  String? fontFamily,
}) {
  final byId = <String, NativeRequirementNode>{};
  for (final node in diagram.nodes) {
    byId[node.name] = node;
  }
  final metrics = <String, NativeRequirementNodeLayout>{};
  for (final node in byId.values) {
    final style = nativeRequirementStyle(diagram, node, dark);
    final type = NativeRequirementText(
      '<<${node.isElement ? 'Element' : node.type}>>',
      style,
      fontFamily: fontFamily,
      markup: false,
    );
    final name = NativeRequirementText(
      node.name,
      style,
      fontFamily: fontFamily,
      bold: true,
    );
    final fields = [
      NativeRequirementField(type, 0, true),
      NativeRequirementField(name, type.size.height, true),
    ];
    var offset = type.size.height + name.size.height + 20;
    final body = node.isElement
        ? [
            node.type.isEmpty ? '' : 'Type: ${node.type}',
            node.docRef.isEmpty ? '' : tr("Doc Ref: {0}", [node.docRef]),
          ]
        : [
            node.requirementId.isEmpty ? '' : 'ID: ${node.requirementId}',
            node.text.isEmpty ? '' : 'Text: ${node.text}',
            node.risk.isEmpty ? '' : 'Risk: ${node.risk}',
            node.verifyMethod.isEmpty
                ? ''
                : 'Verification: ${node.verifyMethod}',
          ];
    var divided = false;
    for (var i = 0; i < body.length; i++) {
      if (body[i].isEmpty) continue;
      final text = NativeRequirementText(
        body[i],
        style,
        fontFamily: fontFamily,
      );
      fields.add(NativeRequirementField(text, offset, false));
      if (i < body.length - 1) {
        offset += text.size.height;
        divided = true;
      }
    }
    var minY = double.infinity, maxY = double.negativeInfinity, width = 0.0;
    for (final field in fields) {
      minY = math.min(minY, field.centerY - field.label.size.height / 2);
      maxY = math.max(maxY, field.centerY + field.label.size.height / 2);
      width = math.max(width, field.label.size.width);
    }
    metrics[node.name] = NativeRequirementNodeLayout(
      node,
      style,
      fields,
      Size(width + 20, maxY - minY + 20),
      divided ? type.size.height + name.size.height + 20 : null,
    );
  }
  for (final rel in diagram.relations) {
    if (!metrics.containsKey(rel.from) || !metrics.containsKey(rel.to)) {
      throw FormatException(
        tr("Unknown requirement relation endpoint: {0} → {1}", [
          rel.from,
          rel.to,
        ]),
      );
    }
  }
  final edgeStyle = NativeRequirementStyle(
    fill: Colors.transparent,
    stroke: Colors.transparent,
    ink: dark ? const Color(0xffcccccc) : const Color(0xff0f1115),
  );
  final labels = [
    for (final rel in diagram.relations)
      NativeRequirementText(
        '<<${rel.type}>>',
        edgeStyle,
        fontFamily: fontFamily,
        markup: false,
      ),
  ];
  final graph = MermaidFlowchartGraph(
    diagram.direction ?? 'TB',
    byId.values.map(
      (n) => MermaidFlowNode(n.name, n.name, MermaidFlowNodeShape.rectangle),
    ),
    diagram.relations.map(
      (e) => MermaidFlowEdge(
        e.from,
        e.to,
        '<<${e.type}>>',
        MermaidFlowLineStyle.solid,
        MermaidFlowMarker.none,
        MermaidFlowMarker.none,
      ),
    ),
  );
  final flow = layoutNativeMermaidFlowchart(
    graph,
    fontFamily: fontFamily,
    nodeSizes: metrics.map((id, item) => MapEntry(id, item.size)),
    measureEdgeLabel: (label) => NativeRequirementText(
      label,
      edgeStyle,
      fontFamily: fontFamily,
      markup: false,
    ).size,
  );
  NativeRequirementText? title;
  var shift = Offset.zero;
  if (diagram.title?.isNotEmpty == true) {
    edgeStyle.fontSize = 18;
    title = NativeRequirementText(
      diagram.title!,
      edgeStyle,
      fontFamily: fontFamily,
    );
    shift = Offset(0, title.size.height + 25);
  }
  final placed = {for (final n in flow.nodes) n.node.id: n.bounds};
  final nodes = [
    for (final id in byId.keys) metrics[id]!..bounds = placed[id]!.shift(shift),
  ];
  final edges = [
    for (var i = 0; i < flow.edges.length; i++)
      NativeRequirementEdgeLayout(
        diagram.relations[i],
        flow.edges[i].path.shift(shift),
        flow.edges[i].labelCenter + shift,
        labels[i],
      ),
  ];
  final width = math.max(flow.size.width, (title?.size.width ?? 0) + 16);
  return NativeRequirementLayout(
    diagram,
    Size(width, flow.size.height + shift.dy),
    nodes,
    edges,
    title,
    title == null ? null : Offset(width / 2, title.size.height / 2 + 8),
  );
}

class NativeMermaidRequirement extends StatelessWidget {
  const NativeMermaidRequirement({
    super.key,
    required this.diagram,
    required this.dark,
    this.fontFamily,
  });
  final NativeRequirementDiagram diagram;
  final bool dark;
  final String? fontFamily;
  @override
  Widget build(BuildContext context) {
    RenderL10n.watch(context);
    final layout = layoutNativeMermaidRequirement(
      diagram,
      dark: dark,
      fontFamily: fontFamily,
    );
    final chart = SizedBox.fromSize(
      size: layout.size,
      child: CustomPaint(painter: NativeRequirementPainter(layout, dark: dark)),
    );
    return Semantics(
      image: true,
      label: [
        if (diagram.accTitle != null) diagram.accTitle!,
        if (diagram.accDescription != null) diagram.accDescription!,
        for (final n in layout.nodes)
          for (final field in n.fields) field.label.text,
        for (final e in layout.edges)
          '${e.relation.from} ${e.relation.type} ${e.relation.to}',
      ].join('. '),
      child: LayoutBuilder(
        builder: (context, limits) =>
            limits.hasBoundedWidth && limits.maxWidth < layout.size.width
            ? FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.topLeft,
                child: chart,
              )
            : Align(alignment: Alignment.topCenter, child: chart),
      ),
    );
  }
}

class NativeRequirementPainter extends CustomPainter {
  const NativeRequirementPainter(this.layout, {required this.dark});
  final NativeRequirementLayout layout;
  final bool dark;
  Color get line => dark ? const Color(0xffd3d3d3) : const Color(0xff81858c);
  void _stroke(Canvas canvas, Path path, Paint paint, List<double> pattern) {
    if (pattern.isEmpty) {
      canvas.drawPath(path, paint);
      return;
    }
    for (final metric in path.computeMetrics()) {
      var offset = 0.0, i = 0;
      while (offset < metric.length) {
        final length = pattern[i % pattern.length];
        if (i.isEven && length > 0) {
          canvas.drawPath(
            metric.extractPath(
              offset,
              math.min(offset + length, metric.length),
            ),
            paint,
          );
        }
        offset += length;
        i++;
      }
    }
  }

  @override
  void paint(Canvas canvas, Size size) {
    final edgePaint = Paint()
      ..color = line
      ..strokeWidth = 1
      ..style = PaintingStyle.stroke;
    for (final edge in layout.edges) {
      _stroke(
        canvas,
        edge.path,
        edgePaint,
        edge.relation.type == 'contains' ? [] : [10, 7],
      );
      final metric = edge.path.computeMetrics().firstOrNull;
      if (metric != null && metric.length > 0) {
        final point = metric.getTangentForOffset(
          edge.relation.type == 'contains' ? 0 : metric.length,
        );
        if (point != null) {
          final v = point.vector / point.vector.distance,
              normal = Offset(-v.dy, v.dx);
          if (edge.relation.type == 'contains') {
            final center = point.position + v * 10;
            canvas.drawCircle(center, 9, edgePaint);
            canvas.drawLine(center - v * 9, center + v * 9, edgePaint);
            canvas.drawLine(
              center - normal * 9,
              center + normal * 9,
              edgePaint,
            );
          } else {
            canvas.drawPath(
              Path()
                ..moveTo(
                  (point.position - v * 20 + normal * 10).dx,
                  (point.position - v * 20 + normal * 10).dy,
                )
                ..lineTo(point.position.dx, point.position.dy)
                ..lineTo(
                  (point.position - v * 20 - normal * 10).dx,
                  (point.position - v * 20 - normal * 10).dy,
                ),
              edgePaint,
            );
          }
        }
      }
      final box = Rect.fromCenter(
        center: edge.labelCenter,
        width: edge.label.size.width,
        height: edge.label.size.height,
      );
      canvas.drawRect(
        box,
        Paint()
          ..color = dark ? const Color(0xff585858) : const Color(0xfff1f3f5),
      );
      edge.label.painter.paint(canvas, box.topLeft);
    }
    for (final node in layout.nodes) {
      final border = Paint()
        ..color = node.style.stroke
        ..strokeWidth = node.style.strokeWidth
        ..style = PaintingStyle.stroke;
      canvas.drawRect(node.bounds, Paint()..color = node.style.fill);
      _stroke(canvas, Path()..addRect(node.bounds), border, node.style.dash);
      if (node.divider != null) {
        canvas.drawLine(
          Offset(node.bounds.left, node.bounds.top + node.divider!),
          Offset(node.bounds.right, node.bounds.top + node.divider!),
          border,
        );
      }
      for (final field in node.fields) {
        field.label.painter.paint(canvas, node.fieldBounds(field).topLeft);
      }
    }
    if (layout.title != null) {
      layout.title!.painter.paint(
        canvas,
        layout.titleCenter! -
            Offset(layout.title!.size.width / 2, layout.title!.size.height / 2),
      );
    }
  }

  @override
  bool shouldRepaint(NativeRequirementPainter oldDelegate) =>
      oldDelegate.layout != layout || oldDelegate.dark != dark;
}
