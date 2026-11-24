import '../render_l10n.dart';
// Shape geometry ported from Mermaid 11.17.2 (MIT), classic mindmap renderer.
// Source: rendering-elements/shapes/{defaultMindmapNode,circle,squareRect,
// roundedRect,cloud,bang,hexagon}.ts. Layout is computed from real labels;
// no reference fixture coordinates or SVG document is used by the product.
// Copyright (c) 2014-2022 Knut Sveidqvist. Full MIT notice: MERMAID_MIT_LICENSE.txt.
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:html/dom.dart' as html;
import 'package:html/parser.dart' as html_parser;
import 'package:markdown/markdown.dart' as md;
import 'mindmap_model.dart';
import 'mindmap_cose.dart';
import 'state_style.dart';
import 'classic_palette.dart';

/// Typeface metadata for system fonts whose native font loader does not
/// activate the same built-in tracking as the browser's platform font path.
/// Values come from the real font's tracking table, never from diagram text.
/// Android's ordinary Roboto path keeps the default zero tracking.
class NativeMindmapTypography extends ThemeExtension<NativeMindmapTypography> {
  const NativeMindmapTypography({this.labelLetterSpacing = 0, this.fontFamily});
  final String? fontFamily;
  final double labelLetterSpacing;
  @override
  NativeMindmapTypography copyWith({
    double? labelLetterSpacing,
    String? fontFamily,
  }) => NativeMindmapTypography(
    labelLetterSpacing: labelLetterSpacing ?? this.labelLetterSpacing,
    fontFamily: fontFamily ?? this.fontFamily,
  );
  @override
  NativeMindmapTypography lerp(
    covariant NativeMindmapTypography? other,
    double t,
  ) => other == null
      ? this
      : NativeMindmapTypography(
          labelLetterSpacing:
              labelLetterSpacing +
              (other.labelLetterSpacing - labelLetterSpacing) * t,
          fontFamily: t < .5 ? fontFamily : other.fontFamily,
        );
}

class NativeMindmapNodeLayout {
  const NativeMindmapNodeLayout({
    required this.node,
    required this.label,
    required this.labelSize,
    required this.path,
    required this.localBounds,
    required this.center,
    required this.fill,
    required this.labelColor,
    this.underline,
  });
  final NativeMermaidMindmapNode node;
  final TextSpan label;
  final Size labelSize;
  final Path path;
  final Rect localBounds;
  final Offset center;
  final Color fill, labelColor;
  final Color? underline;
  Rect get bounds => localBounds.shift(center);
  Rect get labelBounds => Rect.fromCenter(
    center: center,
    width: labelSize.width,
    height: labelSize.height,
  );
}

class NativeMindmapEdgeLayout {
  const NativeMindmapEdgeLayout(
    this.source,
    this.target,
    this.start,
    this.end,
    this.color,
    this.width,
  );
  final int source, target;
  final Offset start, end;
  final Color color;
  final double width;
}

class NativeMermaidMindmapLayout {
  const NativeMermaidMindmapLayout({
    required this.nodes,
    required this.edges,
    required this.viewBox,
    required this.size,
    required this.scale,
  });
  final List<NativeMindmapNodeLayout> nodes;
  final List<NativeMindmapEdgeLayout> edges;
  final Rect viewBox;
  final Size size;
  final double scale;
}

NativeMermaidMindmapLayout layoutNativeMermaidMindmap(
  NativeMermaidMindmapDiagram diagram, {
  required double width,
  required bool dark,
  String? fontFamily,
  double letterSpacing = 0,
}) {
  if (!letterSpacing.isFinite) {
    throw FormatException(tr("Mindmap font tracking must be finite"));
  }
  if (!width.isFinite || width <= 0) {
    throw FormatException(tr("Mindmap viewport width must be positive"));
  }
  final shapes = <({TextSpan label, Size size, Path path, Rect bounds})>[];
  for (final node in diagram.nodes) {
    final color = _labelColor(node, dark);
    final label = _label(
      node.label,
      TextStyle(
        fontFamily: fontFamily,
        fontSize: 13,
        height: 1.5,
        letterSpacing: letterSpacing,
        color: color,
        fontWeight: FontWeight.w400,
        fontVariations: const [FontVariation('opsz', 13)],
      ),
    );
    final painter = TextPainter(
      text: label,
      textAlign: TextAlign.center,
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: 200);
    // HTML labels use the authored 13px * 1.5 CSS line box, including its
    // fractional half pixel. Paragraph.size rounds engine metrics; preserve
    // actual wrapping/glyph advances while using the source line-box rule.
    final size = Size(
      (painter.width * 64).ceil() / 64,
      painter.computeLineMetrics().length * 19.5,
    );
    painter.dispose();
    final geometry = nativeMindmapNodeShape(node.shape, size);
    final path = geometry.path;
    final bounds = _svgBounds(
      geometry.bounds.expandToInclude(
        Rect.fromCenter(
          center: Offset.zero,
          width: size.width,
          height: size.height,
        ),
      ),
    );
    shapes.add((label: label, size: size, path: path, bounds: bounds));
  }
  // Mermaid flattens the tree in preorder before passing it to Cytoscape.
  final order = <NativeMermaidMindmapNode>[];
  void visit(NativeMermaidMindmapNode node) {
    order.add(node);
    for (final id in node.childIds) {
      visit(diagram.nodeById(id)!);
    }
  }

  visit(diagram.root);
  final indices = {for (var i = 0; i < order.length; i++) order[i].id: i};
  final edges = <({int source, int target})>[];
  void connect(NativeMermaidMindmapNode node) {
    for (final id in node.childIds) {
      edges.add((source: indices[node.id]!, target: indices[id]!));
      connect(diagram.nodeById(id)!);
    }
  }

  connect(diagram.root);
  final byId = {
    for (var i = 0; i < diagram.nodes.length; i++)
      diagram.nodes[i].id: shapes[i],
  };
  final centers = layoutNativeMindmapCoseBilkent(
    nodeSizes: [for (final n in order) byId[n.id]!.bounds.size],
    edges: edges,
  );
  final nodes = <NativeMindmapNodeLayout>[];
  for (var i = 0; i < order.length; i++) {
    final node = order[i], shape = byId[node.id]!;
    nodes.add(
      NativeMindmapNodeLayout(
        node: node,
        label: shape.label,
        labelSize: shape.size,
        path: shape.path,
        localBounds: shape.bounds,
        center: centers[i],
        fill: _fill(node, dark),
        labelColor: _labelColor(node, dark),
        underline: node.shape == NativeMermaidMindmapShape.defaultNode
            ? _inverse(
                node.sectionIndex == null ? 0 : node.sectionIndex! + 1,
                dark,
              )
            : null,
      ),
    );
  }
  var bounds = nodes.first.bounds;
  for (final node in nodes.skip(1)) {
    bounds = bounds.expandToInclude(node.bounds);
  }
  final box = bounds.inflate(10);
  final scale = math.min(1.0, width / box.width);
  final lines = <NativeMindmapEdgeLayout>[];
  for (final edge in edges) {
    final parent = nodes[edge.source], child = nodes[edge.target];
    final vector = child.center - parent.center;
    // The source Cytoscape canvas retains default 30px ellipse geometry for
    // edge attachment. layoutDimensions affects CoSE nodes, not these anchors.
    final inset = vector.distance == 0
        ? Offset.zero
        : vector / vector.distance * 15;
    final stroke = 14.0 - (parent.node.level + 1) * 3;
    lines.add(
      NativeMindmapEdgeLayout(
        parent.node.id,
        child.node.id,
        parent.center + inset,
        child.center - inset,
        _fill(child.node, dark),
        stroke >= 0 ? stroke : 3,
      ),
    );
  }
  return NativeMermaidMindmapLayout(
    nodes: List.unmodifiable(nodes),
    edges: List.unmodifiable(lines),
    viewBox: box,
    size: Size(box.width * scale, box.height * scale),
    scale: scale,
  );
}

// SVG getBBox exposes single-precision geometry. Mermaid supplies these
// bounds to CoSE, so keep this numeric boundary before force iteration rather
// than feeding higher-precision analytic ellipse sizes to a different layout.
Rect _svgBounds(Rect bounds) {
  double scalar(double value) => Float32List.fromList([value]).single;
  return Rect.fromLTWH(
    scalar(bounds.left),
    scalar(bounds.top),
    scalar(bounds.width),
    scalar(bounds.height),
  );
}

/// Actual source shape paths in node-local coordinates. Path.getBounds and the
/// label union are passed to the layout, including asymmetric cloud/bang bounds.
({Path path, Rect bounds}) nativeMindmapNodeShape(
  NativeMermaidMindmapShape shape,
  Size label,
) {
  final lw = label.width, lh = label.height;
  final path = Path();
  switch (shape) {
    case NativeMermaidMindmapShape.defaultNode:
      final w = lw + 40, h = lh + 10;
      path.moveTo(-w / 2, h / 2 - 5);
      path.relativeLineTo(0, -h + 10);
      path.relativeQuadraticBezierTo(0, -5, 5, -5);
      path.relativeLineTo(w - 10, 0);
      path.relativeQuadraticBezierTo(5, 0, 5, 5);
      path.relativeLineTo(0, h - 10);
      path.relativeQuadraticBezierTo(0, 5, -5, 5);
      path.relativeLineTo(-w + 10, 0);
      path.relativeQuadraticBezierTo(-5, 0, -5, -5);
      path.close();
    case NativeMermaidMindmapShape.rectangle:
      path.addRect(
        Rect.fromCenter(center: Offset.zero, width: lw + 40, height: lh + 20),
      );
    case NativeMermaidMindmapShape.roundedRectangle:
      path.addRRect(
        RRect.fromRectAndRadius(
          Rect.fromCenter(center: Offset.zero, width: lw + 30, height: lh + 30),
          const Radius.circular(5),
        ),
      );
    case NativeMermaidMindmapShape.circle:
      path.addOval(Rect.fromCircle(center: Offset.zero, radius: lw / 2 + 10));
    case NativeMermaidMindmapShape.hexagon:
      final h = lh + 20, w = lw + 20 + (lh + 20) / 2;
      final m = h / 4;
      path.addPolygon([
        Offset(-w / 2 + m, h / 2),
        Offset(w / 2 - m, h / 2),
        Offset(w / 2, 0),
        Offset(w / 2 - m, -h / 2),
        Offset(-w / 2 + m, -h / 2),
        Offset(-w / 2, 0),
      ], true);
    case NativeMermaidMindmapShape.cloud:
    case NativeMermaidMindmapShape.bang:
      final cloud = shape == NativeMermaidMindmapShape.cloud;
      final w = cloud ? lw + 10 : lw + 50;
      final h = cloud ? lh + 10 : lh + 40;
      var point = Offset.zero;
      var tightBounds = Rect.zero;
      path.moveTo(0, 0);
      void arc(
        double rx,
        double ry,
        bool large,
        double dx,
        double dy, {
        double rotation = 1,
      }) {
        final target = point + Offset(dx, dy);
        tightBounds = tightBounds.expandToInclude(
          _svgArcBounds(point, target, rx, ry, large, cloud, rotation),
        );
        point = target;
        path.arcToPoint(
          point,
          radius: Radius.elliptical(rx, ry),
          largeArc: large,
          clockwise: cloud,
          rotation: rotation,
        );
      }
      if (cloud) {
        arc(w * .15, w * .15, false, w * .25, -w * .1, rotation: 0);
        arc(w * .35, w * .35, false, w * .4, -w * .1);
        arc(w * .25, w * .25, false, w * .35, w * .2);
        arc(w * .15, w * .15, false, w * .15, h * .35);
        arc(w * .2, w * .2, false, -w * .15, h * .65);
        arc(w * .25, w * .15, false, -w * .25, w * .15);
        arc(w * .35, w * .35, false, -w * .5, 0);
        arc(w * .15, w * .15, false, -w * .25, -w * .15);
        arc(w * .15, w * .15, false, -w * .1, -h * .35);
        arc(w * .2, w * .2, false, w * .1, -h * .65);
      } else {
        final r = w * .15;
        arc(r, r, false, w * .25, -h * .1);
        arc(r, r, false, w * .25, 0);
        arc(r, r, false, w * .25, 0);
        arc(r, r, false, w * .25, h * .1);
        arc(r, r, false, w * .15, h * .33);
        arc(r * .8, r * .8, false, 0, h * .34);
        arc(r, r, false, -w * .15, h * .33);
        arc(r, r, false, -w * .25, h * .15);
        arc(r, r, false, -w * .25, 0);
        arc(r, r, false, -w * .25, 0);
        arc(r, r, false, -w * .25, -h * .15);
        arc(r, r, false, -w * .1, -h * .33);
        arc(r * .8, r * .8, false, 0, -h * .34);
        arc(r, r, false, w * .1, -h * .33);
      }
      path.lineTo(0, point.dy);
      path.lineTo(0, 0);
      path.close();
      final shift = Offset(-w / 2, -h / 2);
      return (path: path.shift(shift), bounds: tightBounds.shift(shift));
  }
  return (path: path, bounds: path.getBounds());
}

/// SVG getBBox uses tight ellipse extrema; Flutter Path.getBounds also
/// contains the rational curve control points. Keep shape measurement faithful
/// to the SVG algorithm without altering the actual Flutter-painted arc.
Rect _svgArcBounds(
  Offset start,
  Offset end,
  double rx,
  double ry,
  bool largeArc,
  bool clockwise,
  double rotation,
) {
  var bounds = Rect.fromPoints(start, end);
  if (start == end || rx == 0 || ry == 0) return bounds;
  final phi = rotation * math.pi / 180;
  final cosine = math.cos(phi), sine = math.sin(phi);
  final half = (start - end) / 2;
  final x = cosine * half.dx + sine * half.dy;
  final y = -sine * half.dx + cosine * half.dy;
  final ratio = x * x / (rx * rx) + y * y / (ry * ry);
  if (ratio > 1) {
    final factor = math.sqrt(ratio);
    rx *= factor;
    ry *= factor;
  }
  final denominator = rx * rx * y * y + ry * ry * x * x;
  final coefficient =
      (largeArc == clockwise ? -1 : 1) *
      math.sqrt(math.max(0, (rx * rx * ry * ry - denominator) / denominator));
  final cx = coefficient * rx * y / ry;
  final cy = -coefficient * ry * x / rx;
  final center =
      (start + end) / 2 +
      Offset(cosine * cx - sine * cy, sine * cx + cosine * cy);
  final first = math.atan2((y - cy) / ry, (x - cx) / rx);
  final last = math.atan2((-y - cy) / ry, (-x - cx) / rx);
  var sweep = last - first;
  final turn = 2 * math.pi;
  if (clockwise && sweep < 0) sweep += turn;
  if (!clockwise && sweep > 0) sweep -= turn;
  final xExtreme = math.atan2(-ry * sine, rx * cosine);
  final yExtreme = math.atan2(ry * cosine, rx * sine);
  for (final angle in [
    xExtreme,
    xExtreme + math.pi,
    yExtreme,
    yExtreme + math.pi,
  ]) {
    final progress = clockwise
        ? (angle - first) % turn
        : (first - angle) % turn;
    if (progress > sweep.abs() + 1e-10) continue;
    final point =
        center +
        Offset(
          rx * math.cos(angle) * cosine - ry * math.sin(angle) * sine,
          rx * math.cos(angle) * sine + ry * math.sin(angle) * cosine,
        );
    bounds = bounds.expandToInclude(Rect.fromPoints(point, point));
  }
  return bounds;
}

Path nativeMindmapNodePath(NativeMermaidMindmapShape shape, Size label) =>
    nativeMindmapNodeShape(shape, label).path;

TextSpan _label(String source, TextStyle style) {
  final fragment = html_parser.parseFragment(
    md.renderToHtml(
      md.Document(
        encodeHtml: false,
        inlineSyntaxes: [_MindmapLiteralMarkdownSyntax()],
        extensionSet: md.ExtensionSet.gitHubWeb,
      ).parseInline(source),
    ),
  );
  List<InlineSpan> spans(Iterable<html.Node> nodes) => nodes.map<InlineSpan>((
    node,
  ) {
    if (node is html.Text) {
      return TextSpan(text: node.data);
    }
    if (node is! html.Element) {
      return const TextSpan();
    }
    if (node.localName == 'br') {
      return const TextSpan(text: '\n');
    }
    final own = switch (node.localName) {
      'strong' || 'b' => const TextStyle(fontWeight: FontWeight.w700),
      'em' || 'i' => const TextStyle(fontStyle: FontStyle.italic),
      'code' => const TextStyle(fontFamily: 'monospace'),
      'del' || 's' => const TextStyle(decoration: TextDecoration.lineThrough),
      'span' || 'p' => const TextStyle(),
      _ => throw FormatException(
        tr("Native mindmap label element {0} is not yet supported", [
          node.localName,
        ]),
      ),
    };
    final inline = _inlineStyle(node.attributes['style']);
    return TextSpan(style: own.merge(inline), children: spans(node.nodes));
  }).toList();
  return TextSpan(style: style, children: spans(fragment.nodes));
}

/// Mermaid's pinned markdownToHTML emits unknown marked tokens as raw
/// source. Code, links/images and deletion syntax therefore stay literal.
class _MindmapLiteralMarkdownSyntax extends md.InlineSyntax {
  _MindmapLiteralMarkdownSyntax()
    : super(
        r'(`+)[\s\S]*?\1|!?\[(?:[^\]\\]|\\.)*\]\((?:[^()]|\([^()]*\))*\)|~~[\s\S]*?~~',
      );
  @override
  bool onMatch(md.InlineParser parser, Match match) {
    parser.addNode(md.Text(match[0]!));
    return true;
  }
}

TextStyle _inlineStyle(String? declarations) {
  var style = const TextStyle();
  for (final declaration in (declarations ?? '').split(';')) {
    if (declaration.trim().isEmpty) continue;
    final colon = declaration.indexOf(':');
    if (colon < 0) continue;
    final property = declaration.substring(0, colon).trim().toLowerCase();
    final value = declaration.substring(colon + 1).trim();
    switch (property) {
      case 'color':
      case 'background-color':
        final color = parseNativeMermaidStateColor(value);
        if (color == null) {
          throw FormatException(
            'Native mindmap label CSS color $value is not yet supported',
          );
        }
        style = property == 'color'
            ? style.copyWith(color: color)
            : style.copyWith(backgroundColor: color);
      case 'font-weight':
        final weight = value == 'bold'
            ? 700
            : value == 'normal'
            ? 400
            : int.tryParse(value);
        if (weight == null || weight < 100 || weight > 900) {
          throw FormatException(
            'Native mindmap label font-weight $value is not yet supported',
          );
        }
        style = style.copyWith(
          fontWeight: FontWeight.values[(weight / 100).round() - 1],
        );
      case 'font-style':
        if (value != 'normal' && value != 'italic') {
          throw FormatException(
            'Native mindmap label font-style $value is not yet supported',
          );
        }
        style = style.copyWith(
          fontStyle: value == 'italic' ? FontStyle.italic : FontStyle.normal,
        );
      default:
        throw FormatException(
          tr("Native mindmap label CSS {0} is not yet supported", [property]),
        );
    }
  }
  return style;
}

Color _fill(NativeMermaidMindmapNode node, bool dark) {
  // The fixed unified renderer preserves icon metadata without drawing an
  // icon or changing dimensions. Unknown classes have no user CSS. The
  // built-in disabled circle rule is visible; root styling overrides it.
  if (node.sectionIndex != null &&
      node.shape == NativeMermaidMindmapShape.circle &&
      (node.className ?? '').split(RegExp(r'\s+')).contains('disabled')) {
    return const Color(0xffd3d3d3);
  }
  if (node.sectionIndex == null) {
    return dark ? const Color(0xff797d7d) : _section(0, false);
  }
  return _section(node.sectionIndex! + 1, dark);
}

Color _labelColor(NativeMermaidMindmapNode node, bool dark) => !dark
    ? const Color(0xff0f1115)
    : node.sectionIndex == null
    ? const Color(0xff2c2c2c)
    : const Color(0xffd3d3d3);
Color _section(int index, bool dark) => mermaidClassicSectionColor(index, dark);
Color _inverse(int index, bool dark) => mermaidClassicInverseColor(index, dark);

class NativeMermaidMindmap extends StatelessWidget {
  const NativeMermaidMindmap({
    super.key,
    required this.diagram,
    required this.dark,
  });
  final NativeMermaidMindmapDiagram diagram;
  final bool dark;
  @override
  Widget build(BuildContext context) {
    RenderL10n.watch(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final layout = layoutNativeMermaidMindmap(
          diagram,
          width: constraints.maxWidth,
          dark: dark,
          fontFamily:
              Theme.of(
                context,
              ).extension<NativeMindmapTypography>()?.fontFamily ??
              Theme.of(context).textTheme.bodyMedium?.fontFamily,
          letterSpacing:
              Theme.of(
                context,
              ).extension<NativeMindmapTypography>()?.labelLetterSpacing ??
              0,
        );
        return Center(
          child: SizedBox(
            width: layout.size.width,
            height: layout.size.height,
            child: FittedBox(
              fit: BoxFit.contain,
              child: SizedBox(
                width: layout.viewBox.width,
                height: layout.viewBox.height,
                child: SelectionArea(
                  child: Stack(
                    children: [
                      Positioned.fill(
                        child: CustomPaint(
                          painter: NativeMindmapPainter(layout),
                        ),
                      ),
                      for (final node in layout.nodes)
                        Positioned(
                          left: node.labelBounds.left - layout.viewBox.left,
                          top: node.labelBounds.top - layout.viewBox.top,
                          width: node.labelSize.width,
                          height: node.labelSize.height,
                          child: Text.rich(
                            node.label,
                            textScaler: TextScaler.noScaling,
                            textAlign: TextAlign.center,
                            textDirection: TextDirection.ltr,
                          ),
                        ),
                    ],
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

class NativeMindmapPainter extends CustomPainter {
  const NativeMindmapPainter(this.layout);
  final NativeMermaidMindmapLayout layout;
  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.translate(-layout.viewBox.left, -layout.viewBox.top);
    for (final edge in layout.edges) {
      canvas.drawLine(
        edge.start,
        edge.end,
        Paint()
          ..color = edge.color
          ..strokeWidth = edge.width
          ..style = PaintingStyle.stroke,
      );
    }
    for (final node in layout.nodes) {
      canvas.save();
      canvas.translate(node.center.dx, node.center.dy);
      canvas.drawPath(node.path, Paint()..color = node.fill);
      if (node.underline != null) {
        final w = node.labelSize.width + 40, h = node.labelSize.height + 10;
        canvas.drawLine(
          Offset(-w / 2, h / 2),
          Offset(w / 2, h / 2),
          Paint()
            ..color = node.underline!
            ..strokeWidth = 3,
        );
      }
      canvas.restore();
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant NativeMindmapPainter oldDelegate) =>
      oldDelegate.layout != layout;
}
