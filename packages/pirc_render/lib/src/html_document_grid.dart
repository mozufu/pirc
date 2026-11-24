import 'dart:math' as math;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

import 'html_grid_template.dart';
import 'html_document_flex.dart';

/// Native explicit grid tracks with ordinary placement and item stretch.
class NativeDocumentGrid extends MultiChildRenderObjectWidget {
  const NativeDocumentGrid({
    super.key,
    required super.children,
    this.fractions = const [],
    this.template,
    this.rowTemplate,
    this.textDirection,
    required this.spans,
    this.stretchColumns = const [],
    this.stretchRows = const [],
    this.columnGap = 0,
    this.rowGap = 0,
  });
  final List<double> fractions;
  final NativeGridTemplate? template;
  final NativeGridTemplate? rowTemplate;
  final TextDirection? textDirection;
  final List<int> spans;
  final List<bool> stretchColumns;
  final List<bool> stretchRows;
  final double columnGap, rowGap;
  @override
  RenderObject createRenderObject(BuildContext context) => _RenderDocumentGrid(
    fractions,
    template,
    rowTemplate,
    spans,
    stretchColumns,
    stretchRows,
    columnGap,
    rowGap,
    textDirection ?? Directionality.of(context),
  );
  @override
  void updateRenderObject(
    BuildContext context,
    covariant RenderBox renderObject,
  ) {
    (renderObject as _RenderDocumentGrid).update(
      fractions,
      template,
      rowTemplate,
      spans,
      stretchColumns,
      stretchRows,
      columnGap,
      rowGap,
      textDirection ?? Directionality.of(context),
    );
  }
}

class _GridParentData extends ContainerBoxParentData<RenderBox> {}

class _RenderDocumentGrid extends RenderBox
    with
        ContainerRenderObjectMixin<RenderBox, _GridParentData>,
        RenderBoxContainerDefaultsMixin<RenderBox, _GridParentData> {
  _RenderDocumentGrid(
    this.fractions,
    this.template,
    this.rowTemplate,
    this.spans,
    this.stretchColumns,
    this.stretchRows,
    this.columnGap,
    this.rowGap,
    this.direction,
  );
  List<double> fractions;
  NativeGridTemplate? template;
  NativeGridTemplate? rowTemplate;
  List<int> spans;
  List<bool> stretchColumns;
  List<bool> stretchRows;
  double columnGap, rowGap;
  TextDirection direction;
  void update(
    List<double> tracks,
    NativeGridTemplate? specification,
    NativeGridTemplate? rowSpecification,
    List<int> placements,
    List<bool> columnStretch,
    List<bool> rowStretch,
    double horizontal,
    double vertical,
    TextDirection textDirection,
  ) {
    fractions = tracks;
    template = specification;
    rowTemplate = rowSpecification;
    spans = placements;
    stretchColumns = columnStretch;
    stretchRows = rowStretch;
    columnGap = horizontal;
    rowGap = vertical;
    direction = textDirection;
    markNeedsLayout();
  }

  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! _GridParentData) {
      child.parentData = _GridParentData();
    }
  }

  List<(RenderBox, int, int, int)> _placements(int columns) {
    final result = <(RenderBox, int, int, int)>[];
    var child = firstChild, index = 0, column = 0, row = 0;
    while (child != null) {
      final authored = index < spans.length ? spans[index] : 1;
      final span = authored == -1 ? columns : authored.clamp(1, columns);
      if (column + span > columns) {
        column = 0;
        row++;
      }
      result.add((child, row, column, span));
      column += span;
      if (column >= columns) {
        column = 0;
        row++;
      }
      child = (child.parentData! as _GridParentData).nextSibling;
      index++;
    }
    return result;
  }

  List<double> _trackSizes(
    List<NativeGridTrack> tracks,
    double extent,
    double gap,
  ) {
    final sizes = List<double>.filled(tracks.length, 0);
    var free = extent - gap * math.max(0, tracks.length - 1);
    final flexible = <int>[];
    for (var i = 0; i < tracks.length; i++) {
      final track = tracks[i];
      if (track.fraction > 0) {
        flexible.add(i);
      } else {
        sizes[i] = track.fixedPx + extent * track.fixedPercent / 100;
        free -= sizes[i];
      }
    }
    // Freeze tracks whose declared floor exceeds their flex allocation, then
    // redistribute the remaining space. Fractions below a total of 1 retain
    // CSS's unfilled remainder instead of stretching to the whole container.
    while (flexible.isNotEmpty) {
      final factor = math.max(
        1.0,
        flexible.fold<double>(0, (sum, i) => sum + tracks[i].fraction),
      );
      final unit = math.max(0.0, free) / factor;
      final frozen = flexible
          .where((i) => tracks[i].minimumPx > unit * tracks[i].fraction)
          .toList();
      if (frozen.isEmpty) {
        for (final i in flexible) {
          sizes[i] = unit * tracks[i].fraction;
        }
        break;
      }
      for (final i in frozen) {
        sizes[i] = tracks[i].minimumPx;
        free -= sizes[i];
        flexible.remove(i);
      }
    }
    return sizes;
  }

  BoxConstraints _itemConstraints({
    required double width,
    required bool stretchWidth,
    double? height,
    required bool stretchHeight,
  }) {
    return BoxConstraints(
      minWidth: stretchWidth ? width : 0,
      maxWidth: width,
      minHeight: stretchHeight && height != null ? height : 0,
      maxHeight: height ?? double.infinity,
    );
  }

  Size _layout(BoxConstraints constraints, {required bool dry}) {
    final width = constraints.hasBoundedWidth
        ? constraints.maxWidth
        : math.max(constraints.minWidth, _intrinsicFallbackWidth());
    var tracks =
        template?.expand(width, columnGap) ??
        fractions.map((v) => NativeGridTrack.fraction(v)).toList();
    if (tracks.isEmpty) return constraints.constrain(Size(width, 0));
    final placement = _placements(tracks.length);
    if (template?.collapseEmpty == true) {
      final occupied = placement.fold<int>(
        0,
        (max, p) => math.max(max, p.$3 + p.$4),
      );
      tracks = tracks.take(occupied).toList();
      if (tracks.isEmpty) return constraints.constrain(Size(width, 0));
    }
    final widths = _trackSizes(tracks, width, columnGap);
    final heights = <int, double>{}, offsets = <double>[0];
    final autoHeightFixedRows = <int, double>{};
    for (final track in widths) {
      offsets.add(offsets.last + track + columnGap);
    }
    double cellWidth(int column, int span) =>
        widths.skip(column).take(span).fold<double>(0, (a, b) => a + b) +
        columnGap * (span - 1);

    // A finite maximum alone does not make an auto-height grid definite.
    // Resolve percentage/fractional row tracks only with a tight height. In an
    // auto-height grid, fixed rows retain their size and fractional minmax
    // rows retain their declared floor while their content can still grow it.
    List<double>? rowSizes;
    if (rowTemplate != null) {
      final definiteHeight = constraints.hasTightHeight;
      var rowTracks = rowTemplate!.expand(
        definiteHeight ? constraints.maxHeight : 0,
        rowGap,
      );
      if (rowTemplate!.collapseEmpty) {
        final occupiedRows = placement.fold<int>(
          0,
          (max, item) => math.max(max, item.$2 + 1),
        );
        rowTracks = rowTracks.take(occupiedRows).toList();
      }
      if (definiteHeight) {
        rowSizes = _trackSizes(rowTracks, constraints.maxHeight, rowGap);
        for (var row = 0; row < rowSizes.length; row++) {
          heights[row] = rowSizes[row];
        }
      } else {
        for (var row = 0; row < rowTracks.length; row++) {
          final track = rowTracks[row];
          if (track.isFixedPixel) {
            autoHeightFixedRows[row] = track.fixedPx;
            heights[row] = track.fixedPx;
          } else if (track.fraction > 0 && track.minimumPx > 0) {
            // This is only the minmax floor. The first child-measure pass is
            // unconstrained vertically, so max-content can grow the row.
            // Indefinite fractional space is not distributed among rows.
            heights[row] = track.minimumPx;
          }
        }
      }
    }

    var childIndex = 0;
    for (final (child, row, column, span) in placement) {
      final stretchWidth =
          childIndex >= stretchColumns.length || stretchColumns[childIndex];
      final stretchHeight =
          childIndex >= stretchRows.length || stretchRows[childIndex];
      final cellHeight = rowSizes != null && row < rowSizes.length
          ? rowSizes[row]
          : autoHeightFixedRows[row];
      final box = _itemConstraints(
        width: cellWidth(column, span),
        stretchWidth: stretchWidth,
        height: cellHeight,
        stretchHeight: stretchHeight,
      );
      final childSize = dry
          ? child.getDryLayout(box)
          : (() {
              child.layout(box, parentUsesSize: true);
              return child.size;
            })();
      if (cellHeight == null) {
        heights[row] = math.max(heights[row] ?? 0, childSize.height);
      }
      childIndex++;
    }
    final rowOffsets = <int, double>{};
    var y = 0.0;
    final rowCount = math.max(
      heights.isEmpty ? 0 : heights.keys.reduce(math.max) + 1,
      rowSizes?.length ?? 0,
    );
    for (var row = 0; row < rowCount; row++) {
      rowOffsets[row] = y;
      y += (heights[row] ?? 0) + rowGap;
    }
    if (heights.isNotEmpty) y -= rowGap;
    if (!dry) {
      childIndex = 0;
      for (final (child, row, column, span) in placement) {
        final cell = cellWidth(column, span);
        final stretchWidth =
            childIndex >= stretchColumns.length || stretchColumns[childIndex];
        final stretchHeight =
            childIndex >= stretchRows.length || stretchRows[childIndex];
        final rowArea = rowSizes != null && row < rowSizes.length
            ? rowSizes[row]
            : autoHeightFixedRows[row];
        // An explicit item height in an auto row must stay unconstrained so
        // its percentage remains unresolved. With an explicit row area, the
        // loose maximum is the percentage basis even when the item is smaller.
        final double? height =
            rowArea ?? (stretchHeight ? heights[row] ?? 0 : null);
        childIndex++;
        child.layout(
          _itemConstraints(
            width: cell,
            stretchWidth: stretchWidth,
            height: height,
            stretchHeight: stretchHeight && height != null,
          ),
          parentUsesSize: true,
        );
        final x = direction == TextDirection.ltr
            ? offsets[column]
            : width - offsets[column] - cell;
        (child.parentData! as _GridParentData).offset = Offset(
          x,
          rowOffsets[row] ?? 0,
        );
      }
    }
    return constraints.constrain(Size(width, y));
  }

  double _intrinsicFallbackWidth() {
    var widest = 0.0, child = firstChild;
    while (child != null) {
      widest = math.max(widest, child.getMaxIntrinsicWidth(double.infinity));
      child = (child.parentData! as _GridParentData).nextSibling;
    }
    // Browser intrinsic track sizing is a named separate scope; this maintains
    // a finite fallback for native intrinsic measurement outside documents.
    return widest * math.max(1, fractions.length);
  }

  @override
  Size computeDryLayout(BoxConstraints constraints) =>
      _layout(constraints, dry: true);
  @override
  void performLayout() => size = _layout(constraints, dry: false);
  @override
  void paint(PaintingContext context, Offset offset) =>
      defaultPaint(context, offset);
  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) =>
      defaultHitTestChildren(result, position: position);
}

/// Compatibility wrapper for the initial row-only document adapter.
class NativeDocumentFlexRow extends NativeDocumentFlex {
  const NativeDocumentFlexRow({
    super.key,
    required super.children,
    double gap = 0,
    super.align,
    super.justify,
  }) : super(mainGap: gap);
}
