import '../render_l10n.dart';
import 'dart:math' as math;
import 'package:flutter/painting.dart';
import 'package:html/parser.dart' as html;
import 'c4_model.dart';
import 'c4_geometry.dart';

String nativeC4PlainText(String value) =>
    html
        .parseFragment(
          value.replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n'),
        )
        .text ??
    "";

class NativeC4Text {
  NativeC4Text(
    String source, {
    double fontSize = 14,
    bool bold = false,
    bool italic = false,
    bool svgLabel = false,
    String? fontFamily,
    double maxWidth = double.infinity,
    Color color = const Color(0xff444444),
  }) : text = nativeC4PlainText(source) {
    painter = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          fontFamily: fontFamily ?? 'sans-serif',
          fontSize: fontSize,
          fontWeight: bold ? FontWeight.bold : FontWeight.normal,
          fontStyle: italic ? FontStyle.italic : FontStyle.normal,
          color: color,
          height: svgLabel ? 1.1 : 1.4,
          letterSpacing: 0,
        ),
      ),
      textDirection: TextDirection.ltr,
      textAlign: TextAlign.center,
      textScaler: TextScaler.noScaling,
    )..layout(maxWidth: maxWidth);
    _size = Size(
      painter.width,
      painter.height + (svgLabel ? fontSize * .3 : 0),
    );
  }
  final String text;
  late final TextPainter painter;
  late final Size _size;
  Size get size => _size;
}

class NativeC4NodeLayout {
  NativeC4NodeLayout(this.shape, this.geometry, this.sections);
  final NativeC4Shape shape;
  final NativeC4NodeGeometry geometry;
  final List<NativeC4Text> sections;
  Rect bounds = Rect.zero;
  Size get labelSize => Size(
    sections.fold(0.0, (w, s) => math.max(w, s.size.width)),
    sections.fold(0.0, (h, s) => h + s.size.height) +
        math.max(0, sections.length - 1) * 3,
  );
}

class NativeC4BoundaryLayout {
  NativeC4BoundaryLayout(
    this.boundary,
    this.label,
    this.type,
    this.description,
    this.labelY,
    this.typeY,
    this.descriptionY,
    this.headerHeight,
  );
  final NativeC4Boundary boundary;
  final NativeC4Text label, type;
  final NativeC4Text? description;
  final double labelY, typeY, descriptionY, headerHeight;
  Rect bounds = Rect.zero;
}

class NativeC4RelationLayout {
  NativeC4RelationLayout(
    this.relation,
    this.start,
    this.end,
    this.label,
    this.technology,
    this.control,
    this.labelCenter,
    this.technologyCenter,
  );
  final NativeC4Relation relation;
  final Offset start, end, labelCenter, technologyCenter;
  final Offset? control;
  final NativeC4Text label;
  final NativeC4Text? technology;
}

class NativeC4Layout {
  NativeC4Layout({
    required this.diagram,
    required this.nodes,
    required this.boundaries,
    required this.relations,
    required this.paintOrder,
    required this.size,
    required this.viewBoxOffset,
    required this.title,
    required this.titleBaseline,
  });
  final NativeC4Diagram diagram;
  final Map<String, NativeC4NodeLayout> nodes;
  final Map<String, NativeC4BoundaryLayout> boundaries;
  final List<NativeC4RelationLayout> relations;
  final Size size;
  final List<String> paintOrder;
  final Offset viewBoxOffset, titleBaseline;
  final NativeC4Text? title;
}

String nativeC4NodeShape(String kind) {
  if (kind == 'person' || kind == 'external_person') return 'person';
  if (kind.endsWith('_db')) return 'cylinder';
  if (kind.endsWith('_queue')) return 'h-cyl';
  return 'rounded';
}

String nativeC4Stereotype(NativeC4Shape shape) {
  final base = shape.kind
      .replaceFirst(RegExp(r'^external_'), '')
      .replaceFirst(RegExp(r'_(db|queue)$'), '');
  final name = switch (base) {
    'person' => tr("Person"),
    'system' => tr("Software System"),
    'container' => tr("Container"),
    'component' => tr("Component"),
    _ => base.replaceAll('_', ' '),
  };
  final tech = shape.technology ?? '';
  return tech.isEmpty ? '[$name]' : '[$name: $tech]';
}

/// Mirrors the pinned C4 renderer's Bounds and recursive boundary row algorithm.
NativeC4Layout layoutNativeMermaidC4(
  NativeC4Diagram diagram, {
  required double screenWidth,
  String? fontFamily,
  Color Function(String? value, Color fallback)? resolveColor,
  Color titleColor = const Color(0xff0f1115),
}) {
  if (!screenWidth.isFinite ||
      screenWidth <= 0 ||
      diagram.shapes.length > 512 ||
      diagram.boundaries.length > 128 ||
      diagram.shapeInRow < 1 ||
      diagram.boundaryInRow < 1) {
    throw FormatException(tr("C4 diagram exceeds native layout bounds."));
  }
  Color color(String? value, Color fallback) =>
      resolveColor?.call(value, fallback) ?? fallback;
  final nodes = <String, NativeC4NodeLayout>{};
  for (final shape in diagram.shapes) {
    final type = nativeC4NodeShape(shape.kind);
    final wrapWidth = !diagram.wrap
        ? double.infinity
        : type == 'cylinder'
        ? 156.0
        : type == 'h-cyl'
        ? 166.0
        : 176.0;
    final fontColor = color(shape.fontColor, const Color(0xffffffff));
    final sections = <NativeC4Text>[
      NativeC4Text(
        shape.label,
        bold: true,
        fontFamily: fontFamily,
        svgLabel: true,
        maxWidth: wrapWidth,
        color: fontColor,
      ),
      NativeC4Text(
        nativeC4Stereotype(shape),
        fontSize: 10.5,
        fontFamily: fontFamily,
        svgLabel: true,
        maxWidth: wrapWidth,
        color: fontColor,
      ),
      if (shape.description?.isNotEmpty == true)
        NativeC4Text(
          shape.description!,
          fontSize: 11.48,
          fontFamily: fontFamily,
          svgLabel: true,
          maxWidth: wrapWidth,
          color: fontColor,
        ),
    ];
    final labelSize = Size(
      sections.fold(0.0, (w, s) => math.max(w, s.size.width)),
      sections.fold(0.0, (h, s) => h + s.size.height) +
          (sections.length - 1) * 3,
    );
    nodes[shape.alias] = NativeC4NodeLayout(
      shape,
      nativeC4NodeGeometry(type, labelSize, minWidth: 216, padding: 20),
      sections,
    );
  }
  final boundaries = <String, NativeC4BoundaryLayout>{};
  final paintOrder = <String>[];
  final screen = _C4Bounds(screenWidth)..setData(50, 50, 10, 10);
  var maxX = 50.0, maxY = 10.0;
  final visiting = <String>{};
  void drawInside(String parentAlias, _C4Bounds parent, int depth) {
    final groups = diagram.boundaries
        .where((b) => b.parentBoundary == parentAlias)
        .toList();
    if (groups.isEmpty) return;
    final current = _C4Bounds(
      parent.widthLimit / math.min(diagram.boundaryInRow, groups.length),
    );
    for (var i = 0; i < groups.length; i++) {
      final boundary = groups[i];
      if (depth > 64 || !visiting.add(boundary.alias)) {
        throw FormatException(
          tr("C4 boundaries contain a cycle or exceed nesting limits."),
        );
      }
      final fontColor = color(boundary.fontColor, const Color(0xff444444));
      final label = NativeC4Text(
        boundary.label,
        fontSize: 16,
        bold: true,
        fontFamily: fontFamily,
        maxWidth: boundary.wrap && diagram.wrap
            ? current.widthLimit
            : double.infinity,
        color: fontColor,
      );
      final type = NativeC4Text(
        boundary.type.isEmpty ? '' : '[${boundary.type}]',
        fontFamily: fontFamily,
        maxWidth: boundary.wrap && diagram.wrap
            ? current.widthLimit
            : double.infinity,
        color: fontColor,
      );
      final description = boundary.description?.isNotEmpty == true
          ? NativeC4Text(
              boundary.description!,
              fontSize: 12,
              fontFamily: fontFamily,
              maxWidth: boundary.wrap && diagram.wrap
                  ? current.widthLimit
                  : double.infinity,
              color: fontColor,
            )
          : null;
      const labelY = 8.0;
      final typeY =
          labelY + label.size.height + (boundary.type.isEmpty ? 0 : 5);
      final descriptionY =
          typeY + (boundary.type.isEmpty ? 0 : type.size.height) + 20;
      final headerHeight = description == null
          ? typeY + (boundary.type.isEmpty ? 0 : type.size.height)
          : descriptionY + description.size.height;
      final item = NativeC4BoundaryLayout(
        boundary,
        label,
        type,
        description,
        labelY,
        typeY,
        descriptionY,
        headerHeight,
      );
      boundaries[boundary.alias] = item;
      if (i == 0 || i % diagram.boundaryInRow == 0) {
        final x = parent.startX + 50, y = parent.stopY + 10 + headerHeight;
        current.setData(x, x, y, y);
      } else {
        final x = current.stopX != current.startX
            ? current.stopX + 50
            : current.startX;
        current.setData(x, x, current.startY, current.startY);
      }
      final children = nodes.values
          .where((n) => n.shape.parentBoundary == boundary.alias)
          .toList();
      for (final node in children) {
        current.insert(node, diagram.shapeInRow);
        paintOrder.add('n:${node.shape.alias}');
      }
      if (children.isNotEmpty) {
        current.stopX += 50;
        current.stopY += 50;
      }
      drawInside(boundary.alias, current, depth + 1);
      item.bounds = Rect.fromLTRB(
        current.startX,
        current.startY,
        current.stopX,
        current.stopY,
      );
      if (boundary.alias != 'global') paintOrder.add('b:${boundary.alias}');
      parent.stopY = math.max(current.stopY + 50, parent.stopY);
      parent.stopX = math.max(current.stopX + 50, parent.stopX);
      maxX = math.max(maxX, parent.stopX);
      maxY = math.max(maxY, parent.stopY);
      visiting.remove(boundary.alias);
    }
  }

  drawInside('', screen, 0);
  if (nodes.values.any((n) => n.bounds.isEmpty)) {
    throw FormatException(tr("C4 nodes reference an unreachable boundary."));
  }
  final relations = <NativeC4RelationLayout>[];
  for (var i = 0; i < diagram.relations.length; i++) {
    final rel = diagram.relations[i],
        from = nodes[rel.from],
        to = nodes[rel.to];
    if (from == null || to == null) {
      throw FormatException(
        tr("C4 relationship references an unknown shape: {0} → {1}.", [
          rel.from,
          rel.to,
        ]),
      );
    }
    final start =
        from.bounds.topLeft +
        from.geometry.intersect(to.bounds.center - from.bounds.topLeft);
    final end =
        to.bounds.topLeft +
        to.geometry.intersect(from.bounds.center - to.bounds.topLeft);
    if (!start.dx.isFinite ||
        !start.dy.isFinite ||
        !end.dx.isFinite ||
        !end.dy.isFinite) {
      throw FormatException(
        tr("C4 relationship has unsupported intersection geometry."),
      );
    }
    final dynamicPrefix = diagram.kind == 'C4Dynamic' ? '${i + 1}: ' : '';
    final label = NativeC4Text(
      '$dynamicPrefix${rel.label}',
      fontSize: 12,
      fontFamily: fontFamily,
      color: color(rel.textColor, const Color(0xff444444)),
    );
    final technology = rel.technology.isEmpty
        ? null
        : NativeC4Text(
            '[${rel.technology}]',
            fontSize: 12,
            italic: true,
            fontFamily: fontFamily,
            color: color(rel.textColor, const Color(0xff444444)),
          );
    final mid = Offset(
      (start.dx + end.dx) / 2 + (rel.offsetX ?? 0),
      (start.dy + end.dy) / 2 + (rel.offsetY ?? 0),
    );
    final control = i == 0
        ? null
        : Offset(start.dx + (end.dx - start.dx) / 4, (start.dy + end.dy) / 2);
    relations.add(
      NativeC4RelationLayout(
        rel,
        start,
        end,
        label,
        technology,
        control,
        mid + Offset(label.size.width / 2, 0),
        mid +
            Offset(
              math.max(label.size.width, technology?.size.width ?? 0) / 2,
              17,
            ),
      ),
    );
  }
  final title = diagram.title?.isNotEmpty == true
      ? NativeC4Text(
          diagram.title!,
          fontSize: 13,
          fontFamily: fontFamily,
          color: titleColor,
        )
      : null;
  final extra = title == null ? 0.0 : 60.0;
  return NativeC4Layout(
    diagram: diagram,
    nodes: Map.unmodifiable(nodes),
    boundaries: Map.unmodifiable(boundaries),
    relations: List.unmodifiable(relations),
    paintOrder: List.unmodifiable(paintOrder),
    size: Size(math.max(100, maxX + 50), math.max(20, maxY + 10 + extra)),
    viewBoxOffset: Offset(0, 10 + extra),
    title: title,
    titleBaseline: Offset((maxX - 50) / 2 - 200, 20),
  );
}

class _C4Bounds {
  _C4Bounds(this.widthLimit);
  final double widthLimit;
  double startX = 0,
      stopX = 0,
      startY = 0,
      stopY = 0,
      nextStartX = 0,
      nextStopX = 0,
      nextStartY = 0,
      nextStopY = 0;
  int count = 0;
  void setData(double x, double xx, double y, double yy) {
    nextStartX = startX = x;
    nextStopX = stopX = xx;
    nextStartY = startY = y;
    nextStopY = stopY = yy;
  }

  void insert(NativeC4NodeLayout node, int columns) {
    count++;
    var x = nextStopX + (nextStartX == nextStopX ? 50 : 100),
        xx = x + node.geometry.size.width;
    var y = nextStartY + 100, yy = y + node.geometry.size.height;
    if (x >= widthLimit || xx >= widthLimit || count > columns) {
      x = nextStartX + 50;
      y = nextStopY + 100;
      nextStopX = xx = x + node.geometry.size.width;
      nextStartY = nextStopY;
      nextStopY = yy = y + node.geometry.size.height;
      count = 1;
    }
    node.bounds = Rect.fromLTWH(
      x,
      y,
      node.geometry.size.width,
      node.geometry.size.height,
    );
    startX = math.min(startX, x);
    startY = math.min(startY, y);
    stopX = math.max(stopX, xx);
    stopY = math.max(stopY, yy);
    nextStartX = math.min(nextStartX, x);
    nextStartY = math.min(nextStartY, y);
    nextStopX = math.max(nextStopX, xx);
    nextStopY = math.max(nextStopY, yy);
  }
}
