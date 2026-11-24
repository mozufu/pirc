import 'dart:math' as math;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_math_fork/flutter_math.dart' show Math;
import 'package:flutter_math_fork/src/ast/options.dart' show MathOptions;
import 'package:flutter_math_fork/src/ast/nodes/space.dart' show SpaceNode;
import 'package:flutter_math_fork/src/ast/size.dart' show Measurement;
import 'package:flutter_math_fork/src/ast/syntax_tree.dart'
    show
        AtomType,
        BuildResult,
        EquationRowNode,
        GreenNode,
        LeafNode,
        SyntaxTree;
import 'package:flutter_math_fork/src/ast/types.dart' show Mode;

// ignore_for_file: implementation_imports

/// Lays out a TeX expression as inline math that can wrap at TeX breakpoints.
///
/// [math] remains the original, complete Math model. The rendered children are
/// its breakable parts, so callers can still retain the original AST for
/// diagnostics and document state.
class NativeInlineMath extends StatelessWidget {
  const NativeInlineMath({
    super.key,
    required this.math,
    required this.bodyFontSize,
    required this.lineHeight,
  });

  final Math math;
  final double bodyFontSize;
  final double lineHeight;

  @override
  Widget build(BuildContext context) {
    final breaks = math.texBreak();
    final scaledBodyFontSize = MediaQuery.textScalerOf(
      context,
    ).scale(bodyFontSize);
    final parts = breaks.parts;
    final renderedParts = [
      for (var index = 0; index < parts.length; index++)
        index + 1 < parts.length
            ? _withTrailingBoundary(parts[index], parts[index + 1])
            : parts[index],
    ];
    return _NativeInlineMathLayout(
      penalties: breaks.penalties,
      lineAdvance: scaledBodyFontSize * lineHeight,
      children: renderedParts,
    );
  }
}

/// Renders one Math widget at its natural width while reporting a size
/// constrained by the surrounding inline placeholder.
///
/// A RichText `WidgetSpan` gives its child the paragraph's maximum width.
/// flutter_math_fork's row layout can otherwise constrain an unbreakable TeX
/// expression to that width, which either shrinks or asserts. This wrapper
/// lays the Math child out with unconstrained dimensions and lets the natural
/// paint overflow the placeholder's reported width.
class NativeMathInlinePart extends StatelessWidget {
  const NativeMathInlinePart({
    super.key,
    required this.math,
    this.semanticsLabel,
    this.excludeSemantics = false,
  });

  final Math math;
  final String? semanticsLabel;
  final bool excludeSemantics;

  @override
  Widget build(BuildContext context) {
    Widget child = math;
    if (excludeSemantics) {
      child = ExcludeSemantics(child: child);
    } else if (semanticsLabel != null) {
      child = Semantics(label: semanticsLabel, child: child);
    }
    return _NativeInlineMathLayout(
      penalties: const [10000],
      // The enclosing RichText strut owns the paragraph's minimum line
      // advance. Adding it here too would inflate every wrapped line twice.
      lineAdvance: 0,
      children: [child],
    );
  }
}

/// Breakable, baseline-ready Math widgets for embedding in a RichText
/// paragraph. Boundaries with a penalty of 10000 or higher are folded into
/// their neighboring slice, because Flutter's paragraph line breaker may
/// otherwise wrap at every WidgetSpan boundary.
///
/// Each returned slice has the spacing boundary needed to retain the source
/// TeX glue when a legal line break separates it from the following slice.
List<Math> nativeMathParagraphBreakParts(Math mathWidget) {
  final breaks = mathWidget.texBreak();
  if (breaks.parts.length < 2) {
    return List<Math>.unmodifiable(
      breaks.parts.where((part) => !_isEmptyBreakPenaltyOnly(part)),
    );
  }

  final groups = <List<Math>>[];
  var current = <Math>[];
  for (var index = 0; index < breaks.parts.length; index++) {
    current.add(breaks.parts[index]);
    final isLast = index == breaks.parts.length - 1;
    final penalty = index < breaks.penalties.length
        ? breaks.penalties[index]
        : 10000;
    if (isLast || penalty < 10000) {
      groups.add(current);
      current = <Math>[];
    }
  }
  if (current.isNotEmpty) groups.add(current);

  // `texBreak` emits a part for each explicit `\\allowbreak`. That part can
  // contain only a zero-size penalty SpaceNode, which has no visible math but
  // becomes a zero-size WidgetSpan and can perturb Flutter's line metrics.
  // Drop only those penalty-only groups; any real spacing, rule, or height
  // node keeps the group intact. Boundaries are attached after filtering so
  // each retained part sees the next retained atom for binary glue.
  final merged = <Math>[
    for (final group in groups)
      if (group.isNotEmpty) _mergeMathParts(group),
  ].where((part) => !_isEmptyBreakPenaltyOnly(part)).toList();
  if (merged.isEmpty) return const <Math>[];
  return List<Math>.unmodifiable([
    for (var index = 0; index < merged.length; index++)
      index + 1 < merged.length
          ? _withTrailingBoundary(merged[index], merged[index + 1])
          : merged[index],
  ]);
}

bool _isEmptyBreakPenaltyOnly(Math part) {
  final root = part.ast?.greenRoot;
  if (root == null) return false;
  final children = root.flattenedChildList;
  if (children.isEmpty) return false;
  return children.every(
    (child) =>
        child is SpaceNode &&
        child.breakPenalty != null &&
        child.width == Measurement.zero &&
        child.height == Measurement.zero &&
        child.depth == Measurement.zero &&
        child.shift == Measurement.zero,
  );
}

Math _mergeMathParts(List<Math> parts) {
  if (parts.length == 1) return parts.single;
  final template = parts.first;
  final children = <GreenNode>[];
  for (final part in parts) {
    final root = part.ast?.greenRoot;
    if (root != null) children.addAll(root.children);
  }
  final firstRoot = template.ast!.greenRoot;
  return Math(
    ast: SyntaxTree(
      greenRoot: EquationRowNode(
        children: children,
        overrideType: firstRoot.overrideType,
      ),
    ),
    mathStyle: template.mathStyle,
    logicalPpi: template.logicalPpi,
    onErrorFallback: template.onErrorFallback,
    options: template.options,
    parseError: template.parseError,
    textScaleFactor: template.textScaleFactor,
    textStyle: template.textStyle,
  );
}

/// Keeps the original row's spacing after a break-part's final atom.
///
/// flutter_math_fork normalizes a binary atom at the end of a whole row to an
/// ordinary atom. A split-part is an artificial row boundary, though, and its
/// following atom still determines the binary atom's class and trailing glue.
Math _withTrailingBoundary(Math part, Math nextPart) {
  final ast = part.ast;
  final nextAst = nextPart.ast;
  if (ast == null || nextAst == null) return part;

  final root = ast.greenRoot;
  final boundary = _MathSpacingBoundary(
    leftType: _leftAtomType(nextAst.greenRoot),
    rightType: AtomType.ord,
  );
  return Math(
    ast: SyntaxTree(
      greenRoot: EquationRowNode(
        children: [...root.children, boundary],
        overrideType: root.overrideType,
      ),
    ),
    mathStyle: part.mathStyle,
    logicalPpi: part.logicalPpi,
    onErrorFallback: part.onErrorFallback,
    options: part.options,
    parseError: part.parseError,
    textScaleFactor: part.textScaleFactor,
    textStyle: part.textStyle,
  );
}

AtomType _leftAtomType(EquationRowNode row) {
  final overrideType = row.overrideType;
  if (overrideType != null) return overrideType;
  for (final child in row.flattenedChildList) {
    if (child.leftType != AtomType.spacing &&
        child.rightType != AtomType.spacing) {
      return child.leftType;
    }
  }
  return AtomType.ord;
}

/// Zero-size AST atom that supplies the right-side class at a synthetic row
/// edge without drawing content or changing the retained original Math model.
class _MathSpacingBoundary extends LeafNode {
  _MathSpacingBoundary({required this.leftType, required this.rightType});

  @override
  final AtomType leftType;

  @override
  final AtomType rightType;

  @override
  Mode get mode => Mode.math;

  @override
  BuildResult buildWidget(
    MathOptions options,
    List<BuildResult?> childBuildResults,
  ) => BuildResult(widget: const SizedBox.shrink(), options: options);

  @override
  bool shouldRebuildWidget(MathOptions oldOptions, MathOptions newOptions) =>
      false;

  @override
  int get editingWidth => 0;
}

class _NativeInlineMathLayout extends MultiChildRenderObjectWidget {
  const _NativeInlineMathLayout({
    required super.children,
    required this.penalties,
    required this.lineAdvance,
  });

  final List<int> penalties;
  final double lineAdvance;

  @override
  RenderNativeInlineMath createRenderObject(BuildContext context) =>
      RenderNativeInlineMath(penalties: penalties, lineAdvance: lineAdvance);

  @override
  void updateRenderObject(
    BuildContext context,
    RenderNativeInlineMath renderObject,
  ) {
    renderObject
      ..penalties = penalties
      ..lineAdvance = lineAdvance;
  }
}

/// Positions TeX break-parts in rows while preserving their natural size.
///
/// A single over-wide part keeps its natural child width and paints outside the
/// constrained parent, matching an unbreakable token in an inline run.
class RenderNativeInlineMath extends RenderBox
    with
        ContainerRenderObjectMixin<
          RenderBox,
          ContainerBoxParentData<RenderBox>
        >,
        RenderBoxContainerDefaultsMixin<
          RenderBox,
          ContainerBoxParentData<RenderBox>
        > {
  RenderNativeInlineMath({
    required List<int> penalties,
    required this._lineAdvance,
  }) : _penalties = List<int>.unmodifiable(penalties),
       super();

  List<int> _penalties;
  set penalties(List<int> value) {
    if (_sameInts(_penalties, value)) return;
    _penalties = List<int>.unmodifiable(value);
    markNeedsLayout();
  }

  double _lineAdvance;
  set lineAdvance(double value) {
    if (_lineAdvance == value) return;
    _lineAdvance = value;
    markNeedsLayout();
  }

  double _firstBaseline = 0;

  /// Alphabetic baseline from the first laid-out row.
  ///
  /// Read after layout; unlike `getDistanceToBaseline`, this only exposes the
  /// baseline already cached by this renderer and does not trigger a layout
  /// query from capture tooling.
  double get baseline => _firstBaseline;

  static bool _sameInts(List<int> first, List<int> second) {
    if (identical(first, second)) return true;
    if (first.length != second.length) return false;
    for (var index = 0; index < first.length; index++) {
      if (first[index] != second[index]) return false;
    }
    return true;
  }

  List<RenderBox> get _childList {
    final result = <RenderBox>[];
    for (
      var child = firstChild;
      child != null;
      child =
          (child.parentData! as ContainerBoxParentData<RenderBox>).nextSibling
    ) {
      result.add(child);
    }
    return result;
  }

  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! ContainerBoxParentData<RenderBox>) {
      child.parentData = _NativeInlineMathParentData();
    }
  }

  int _penaltyAfter(int index) =>
      index < _penalties.length ? _penalties[index] : 10000;

  List<List<int>> _rows(List<double> widths, double availableWidth) {
    if (widths.isEmpty) return const [];
    if (!availableWidth.isFinite) {
      return [List<int>.generate(widths.length, (index) => index)];
    }

    final rows = <List<int>>[];
    var start = 0;
    while (start < widths.length) {
      var end = start;
      var usedWidth = 0.0;
      while (end < widths.length) {
        final nextWidth = usedWidth + widths[end];
        if (end > start &&
            nextWidth > availableWidth &&
            _penaltyAfter(end - 1) < 10000) {
          break;
        }

        usedWidth = nextWidth;
        end++;
      }
      if (end == start) end++;
      rows.add(List<int>.generate(end - start, (offset) => start + offset));
      start = end;
    }
    return rows;
  }

  List<Size> _dryChildSizes(List<RenderBox> items) =>
      items.map((child) => child.getDryLayout(const BoxConstraints())).toList();

  List<List<int>> _rowsForSizes(List<Size> sizes, double availableWidth) =>
      _rows(sizes.map((size) => size.width).toList(), availableWidth);

  @override
  void performLayout() {
    final items = _childList;
    for (final child in items) {
      child.layout(const BoxConstraints(), parentUsesSize: true);
    }

    final sizes = items.map((child) => child.size).toList(growable: false);
    final rows = _rowsForSizes(sizes, constraints.maxWidth);
    var maxRowWidth = 0.0;
    var y = 0.0;
    var previousRowHeight = 0.0;
    var baselineY = 0.0;
    _firstBaseline = 0;

    for (var rowIndex = 0; rowIndex < rows.length; rowIndex++) {
      final row = rows[rowIndex];
      var ascent = 0.0;
      var descent = 0.0;
      final childBaselines = <int, double>{};
      var rowWidth = 0.0;
      for (final index in row) {
        final child = items[index];
        final baseline =
            child.getDistanceToBaseline(
              TextBaseline.alphabetic,
              onlyReal: true,
            ) ??
            child.size.height;
        childBaselines[index] = baseline;
        ascent = math.max(ascent, baseline);
        descent = math.max(descent, child.size.height - baseline);
        rowWidth += child.size.width;
      }

      final rowHeight = math.max(_lineAdvance, ascent + descent);
      if (rowIndex == 0) {
        y = 0;
        baselineY = ascent;
        _firstBaseline = baselineY;
      } else {
        baselineY += math.max(
          _lineAdvance,
          math.max(previousRowHeight, rowHeight),
        );
        y = baselineY - ascent;
      }

      var x = 0.0;
      for (final index in row) {
        final parentData =
            items[index].parentData! as ContainerBoxParentData<RenderBox>;
        parentData.offset = Offset(x, y + ascent - childBaselines[index]!);
        x += items[index].size.width;
      }

      maxRowWidth = math.max(maxRowWidth, rowWidth);
      previousRowHeight = rowHeight;
    }

    final contentHeight = rows.isEmpty ? _lineAdvance : y + previousRowHeight;
    size = constraints.constrain(Size(maxRowWidth, contentHeight));
  }

  @override
  Size computeDryLayout(BoxConstraints constraints) {
    final sizes = _dryChildSizes(_childList);
    final rows = _rowsForSizes(sizes, constraints.maxWidth);
    var maxRowWidth = 0.0;
    var height = 0.0;
    for (final row in rows) {
      var rowWidth = 0.0;
      var rowHeight = _lineAdvance;
      for (final index in row) {
        rowWidth += sizes[index].width;
        rowHeight = math.max(rowHeight, sizes[index].height);
      }
      maxRowWidth = math.max(maxRowWidth, rowWidth);
      height += rowHeight;
    }
    if (rows.isEmpty) height = _lineAdvance;
    return constraints.constrain(Size(maxRowWidth, height));
  }

  @override
  double computeMinIntrinsicWidth(double height) {
    final items = _childList;
    if (items.isEmpty) return 0;
    return items
        .map((child) => child.getMinIntrinsicWidth(height))
        .reduce(math.max);
  }

  @override
  double computeMaxIntrinsicWidth(double height) => _childList.fold<double>(
    0,
    (width, child) => width + child.getMaxIntrinsicWidth(height),
  );

  double _intrinsicHeight(double width) {
    final items = _childList;
    if (items.isEmpty) return _lineAdvance;
    final widths = items
        .map((child) => child.getMaxIntrinsicWidth(double.infinity))
        .toList(growable: false);
    final heights = List<double>.generate(
      items.length,
      (index) => items[index].getMaxIntrinsicHeight(widths[index]),
      growable: false,
    );
    final rows = _rows(widths, width);
    var result = 0.0;
    for (final row in rows) {
      var rowHeight = _lineAdvance;
      for (final index in row) {
        rowHeight = math.max(rowHeight, heights[index]);
      }
      result += rowHeight;
    }
    return result;
  }

  @override
  double computeMinIntrinsicHeight(double width) => _intrinsicHeight(width);

  @override
  double computeMaxIntrinsicHeight(double width) => _intrinsicHeight(width);

  @override
  double? computeDryBaseline(
    BoxConstraints constraints,
    TextBaseline baseline,
  ) =>
      // flutter_math_fork's RenderLine does not implement dry-baseline
      // queries. Parents that probe dry layout (notably intrinsic tables) can
      // safely treat this wrapper as baseline-less; actual layout stores the
      // natural child baseline in [_firstBaseline] below.
      null;

  @override
  double? computeDistanceToActualBaseline(TextBaseline baseline) =>
      baseline == TextBaseline.alphabetic ? _firstBaseline : null;

  @override
  void paint(PaintingContext context, Offset offset) =>
      defaultPaint(context, offset);

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) =>
      defaultHitTestChildren(result, position: position);
}

class _NativeInlineMathParentData extends ContainerBoxParentData<RenderBox> {}
