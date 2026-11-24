import 'dart:math' as math;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// A definite flex length, or a percentage that requires a definite axis.
class NativeFlexLength {
  const NativeFlexLength.pixels(this.value) : percentage = false;
  const NativeFlexLength.percent(this.value) : percentage = true;
  final double value;
  final bool percentage;
  double? resolve(double? extent) => percentage
      ? extent == null
            ? null
            : extent * value / 100
      : value;
}

/// Layout metadata for one flex item; sizes include its CSS box edges only
/// after the appropriate content-box/border-box conversion.
class NativeFlexItem {
  const NativeFlexItem({
    this.grow = 0,
    this.shrink = 1,
    this.basis,
    this.preferredMain,
    this.minimumMain,
    this.maximumMain,
    this.automaticMinimum = true,
    this.mainEdges = 0,
    this.crossEdges = 0,
    this.mainMargins = 0,
    this.crossMargins = 0,
    this.mainMarginPercentage = 0,
    this.crossMarginPercentage = 0,
    this.borderBox = false,
    this.stretchCross = true,
    this.preferredCross,
    this.minimumCross,
    this.maximumCross,
    this.align,
    this.order = 0,
  });
  final double grow, shrink, mainEdges, crossEdges;
  final double mainMargins, crossMargins;

  /// Percentage margin sums as fractions of the flex container's inline
  /// content width, regardless of whether they lie on its main or cross axis.
  final double mainMarginPercentage, crossMarginPercentage;
  final NativeFlexLength? basis, preferredMain, minimumMain, maximumMain;
  final NativeFlexLength? preferredCross, minimumCross, maximumCross;
  final bool automaticMinimum, borderBox, stretchCross;
  final CrossAxisAlignment? align;
  final int order;

  NativeFlexItem _resolvePercentageMargins(double? inlineContentWidth) {
    final width = inlineContentWidth;
    if (width == null || !width.isFinite || width < 0) return this;
    double resolve(double fixed, double fraction) {
      if (!fraction.isFinite) return fixed;
      final value = fixed + width * fraction;
      return value.isFinite ? value : fixed;
    }

    final resolvedMainMargins = resolve(mainMargins, mainMarginPercentage);
    final resolvedCrossMargins = resolve(crossMargins, crossMarginPercentage);
    if (resolvedMainMargins == mainMargins &&
        resolvedCrossMargins == crossMargins) {
      return this;
    }
    return NativeFlexItem(
      grow: grow,
      shrink: shrink,
      basis: basis,
      preferredMain: preferredMain,
      minimumMain: minimumMain,
      maximumMain: maximumMain,
      automaticMinimum: automaticMinimum,
      mainEdges: mainEdges,
      crossEdges: crossEdges,
      mainMargins: resolvedMainMargins,
      crossMargins: resolvedCrossMargins,
      mainMarginPercentage: 0,
      crossMarginPercentage: 0,
      borderBox: borderBox,
      stretchCross: stretchCross,
      preferredCross: preferredCross,
      minimumCross: minimumCross,
      maximumCross: maximumCross,
      align: align,
      order: order,
    );
  }
}

enum NativeFlexWrap { nowrap, wrap, wrapReverse }

enum NativeFlexContent {
  start,
  end,
  center,
  stretch,
  spaceBetween,
  spaceAround,
  spaceEvenly,
}

/// CSS flex lines rendered directly by Flutter. The parent still owns its
/// ordinary CSS border/padding/size; this box lays out its content area.
class NativeDocumentFlex extends MultiChildRenderObjectWidget {
  const NativeDocumentFlex({
    super.key,
    required super.children,
    this.items = const [],
    this.axis = Axis.horizontal,
    this.reverse = false,
    this.wrap = NativeFlexWrap.nowrap,
    this.mainGap = 0,
    this.crossGap = 0,
    this.align = CrossAxisAlignment.stretch,
    this.justify = MainAxisAlignment.start,
    this.alignContent = NativeFlexContent.stretch,
    this.textDirection,
    this.group,
    this.containerHeight,
    this.containerHeightEdges = 0,
    this.containerBorderBox = false,
  });
  final List<NativeFlexItem> items;
  final Axis axis;
  final bool reverse;
  final NativeFlexWrap wrap;
  final double mainGap, crossGap;
  final CrossAxisAlignment align;
  final MainAxisAlignment justify;
  final NativeFlexContent alignContent;
  final TextDirection? textDirection;
  final Object? group;
  final NativeFlexLength? containerHeight;
  final double containerHeightEdges;
  final bool containerBorderBox;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderDocumentFlex(this, textDirection ?? Directionality.of(context));
  @override
  void updateRenderObject(
    BuildContext context,
    covariant RenderBox renderObject,
  ) => (renderObject as _RenderDocumentFlex).update(
    this,
    textDirection ?? Directionality.of(context),
  );
}

/// Preserves the DOM association of a blockified flex item, including when
/// anonymous text runs sit beside elements. This proxy does not change layout.
class NativeFlexItemMarker extends SingleChildRenderObjectWidget {
  const NativeFlexItemMarker({
    super.key,
    required this.group,
    required this.item,
    required super.child,
  });
  final Object group;
  final NativeFlexItem item;
  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderFlexItemMarker(group, item);
  @override
  void updateRenderObject(
    BuildContext context,
    covariant RenderObject renderObject,
  ) {
    final marker = renderObject as _RenderFlexItemMarker;
    marker.group = group;
    marker.item = item;
    marker.markNeedsLayout();
  }
}

class _RenderFlexItemMarker extends RenderProxyBox {
  _RenderFlexItemMarker(this.group, this.item);
  Object group;
  NativeFlexItem item;
}

class _FlexParentData extends ContainerBoxParentData<RenderBox> {}

class _FlexChild {
  _FlexChild(
    this.box,
    this.spec,
    this.index,
    this.base,
    this.minimum,
    this.maximum,
  ) : target = base.clamp(minimum, maximum).toDouble();
  final RenderBox box;
  final NativeFlexItem spec;
  final int index;
  final double base, minimum, maximum;
  double target;
  bool frozen = false;
  double get hypothetical => base.clamp(minimum, maximum).toDouble();
}

class _FlexLine {
  final items = <_FlexChild>[];
  double cross = 0;
}

class _RenderDocumentFlex extends RenderBox
    with
        ContainerRenderObjectMixin<RenderBox, _FlexParentData>,
        RenderBoxContainerDefaultsMixin<RenderBox, _FlexParentData> {
  _RenderDocumentFlex(this.configuration, this.direction);
  NativeDocumentFlex configuration;
  TextDirection direction;
  void update(NativeDocumentFlex next, TextDirection nextDirection) {
    configuration = next;
    direction = nextDirection;
    markNeedsLayout();
  }

  bool get horizontal => configuration.axis == Axis.horizontal;
  double main(Size size) => horizontal ? size.width : size.height;
  double cross(Size size) => horizontal ? size.height : size.width;
  Size dimensions(double main, double cross) =>
      horizontal ? Size(main, cross) : Size(cross, main);
  double nonnegative(double value) => value.isFinite ? math.max(0.0, value) : 0;
  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! _FlexParentData) {
      child.parentData = _FlexParentData();
    }
  }

  double outer(double value, NativeFlexItem spec, {bool cross = false}) {
    final edges = cross ? spec.crossEdges : spec.mainEdges;
    final margins = cross ? spec.crossMargins : spec.mainMargins;
    return math.max(
      0,
      math.max(edges, value + (spec.borderBox ? 0 : edges)) + margins,
    );
  }

  BoxConstraints childConstraints(
    double mainSize,
    double? crossSize,
    double crossLimit,
  ) {
    if (horizontal) {
      return BoxConstraints.tightFor(width: mainSize, height: crossSize);
    }
    return BoxConstraints(
      minHeight: mainSize,
      maxHeight: mainSize,
      minWidth: crossSize ?? 0,
      maxWidth: crossSize ?? crossLimit,
    );
  }

  NativeFlexItem specification(RenderBox box, int index) {
    NativeFlexItem? found;
    void visit(RenderObject node) {
      if (found != null) return;
      if (node is _RenderFlexItemMarker &&
          identical(node.group, configuration.group)) {
        found = node.item;
        return;
      }
      // Descendants of another flex container have their own item association.
      if (node != box && node is _RenderDocumentFlex) return;
      node.visitChildren(visit);
    }

    if (configuration.group != null) visit(box);
    return found ??
        (index < configuration.items.length
            ? configuration.items[index]
            : const NativeFlexItem());
  }

  double intrinsicAxis(bool width, bool maximum, double extent) {
    final sameAxis = width == horizontal;
    final contributions = <double>[];
    var child = firstChild, index = 0;
    while (child != null) {
      final spec = specification(
        child,
        index,
      )._resolvePercentageMargins(width ? null : extent);
      final intrinsic = width
          ? maximum
                ? child.getMaxIntrinsicWidth(extent)
                : child.getMinIntrinsicWidth(extent)
          : maximum
          ? child.getMaxIntrinsicHeight(extent)
          : child.getMinIntrinsicHeight(extent);
      final preferred = (sameAxis ? spec.preferredMain : spec.preferredCross)
          ?.resolve(null);
      final basis = sameAxis ? spec.basis?.resolve(null) : null;
      final minimum = (sameAxis ? spec.minimumMain : spec.minimumCross)
          ?.resolve(null);
      final maximumValue = (sameAxis ? spec.maximumMain : spec.maximumCross)
          ?.resolve(null);
      var contribution = preferred == null
          ? nonnegative(intrinsic)
          : outer(preferred, spec, cross: !sameAxis);
      if (basis != null && (maximum || spec.shrink == 0)) {
        contribution = math.max(contribution, outer(basis, spec));
      }
      final floor = minimum == null
          ? 0.0
          : outer(minimum, spec, cross: !sameAxis);
      final ceiling = math.max(
        floor,
        maximumValue == null
            ? double.infinity
            : outer(maximumValue, spec, cross: !sameAxis),
      );
      contribution = contribution.clamp(floor, ceiling).toDouble();
      contributions.add(contribution);
      child = (child.parentData! as _FlexParentData).nextSibling;
      index++;
    }
    if (contributions.isEmpty) return 0;
    if (!sameAxis ||
        (!maximum && configuration.wrap != NativeFlexWrap.nowrap)) {
      return contributions.reduce(math.max);
    }
    return contributions.fold<double>(
      configuration.mainGap * (contributions.length - 1),
      (sum, value) => sum + value,
    );
  }

  @override
  double computeMaxIntrinsicWidth(double height) =>
      intrinsicAxis(true, true, height);
  @override
  double computeMinIntrinsicWidth(double height) =>
      intrinsicAxis(true, false, height);
  @override
  double computeMaxIntrinsicHeight(double width) =>
      intrinsicAxis(false, true, width);
  @override
  double computeMinIntrinsicHeight(double width) =>
      intrinsicAxis(false, false, width);

  // Resolve flexible lengths using the CSS freeze / distribute / clamp loop.
  // Shrink weights use the inner flex base size, excluding border/padding.
  void resolveLine(_FlexLine line, double available) {
    final items = line.items;
    final gaps = configuration.mainGap * math.max(0, items.length - 1);
    final grow =
        items.fold<double>(gaps, (sum, item) => sum + item.hypothetical) <
        available;
    for (final item in items) {
      item.frozen =
          (grow ? item.spec.grow : item.spec.shrink) == 0 ||
          (grow
              ? item.base > item.hypothetical
              : item.base < item.hypothetical);
      item.target = item.frozen ? item.hypothetical : item.base;
    }
    double remaining() =>
        available -
        gaps -
        items.fold<double>(
          0,
          (sum, item) => sum + (item.frozen ? item.target : item.base),
        );
    final initial = remaining();
    for (var pass = 0; pass <= items.length; pass++) {
      final active = items.where((item) => !item.frozen).toList();
      if (active.isEmpty) break;
      var free = remaining();
      final factors = active.fold<double>(
        0,
        (sum, item) => sum + (grow ? item.spec.grow : item.spec.shrink),
      );
      if (factors < 1 && (initial * factors).abs() < free.abs()) {
        free = initial * factors;
      }
      final weights = active.fold<double>(
        0,
        (sum, item) =>
            sum +
            (grow
                ? item.spec.grow
                : item.spec.shrink *
                      math.max(
                        0,
                        item.base - item.spec.mainEdges - item.spec.mainMargins,
                      )),
      );
      final violations = <_FlexChild, double>{};
      var total = 0.0;
      for (final item in active) {
        final weight = grow
            ? item.spec.grow
            : item.spec.shrink *
                  math.max(
                    0,
                    item.base - item.spec.mainEdges - item.spec.mainMargins,
                  );
        final raw = item.base + (weights > 0 ? free * weight / weights : 0);
        item.target = raw.clamp(item.minimum, item.maximum).toDouble();
        final violation = item.target - raw;
        violations[item] = violation;
        total += violation;
      }
      if (total.abs() < .0000001) {
        for (final item in active) {
          item.frozen = true;
        }
      } else {
        for (final item in active) {
          if (total > 0 ? violations[item]! > 0 : violations[item]! < 0) {
            item.frozen = true;
          }
        }
      }
    }
  }

  (double, double) distribute(
    MainAxisAlignment alignment,
    double free,
    int count,
    double gap,
  ) {
    if (count == 0) return (0, gap);
    return switch (alignment) {
      MainAxisAlignment.start => (0, gap),
      MainAxisAlignment.end => (free, gap),
      MainAxisAlignment.center => (free / 2, gap),
      MainAxisAlignment.spaceBetween => (
        0,
        gap + (free > 0 && count > 1 ? free / (count - 1) : 0),
      ),
      MainAxisAlignment.spaceAround =>
        free > 0 ? (free / (count * 2), gap + free / count) : (0, gap),
      MainAxisAlignment.spaceEvenly =>
        free > 0 ? (free / (count + 1), gap + free / (count + 1)) : (0, gap),
    };
  }

  Size layoutFlex(BoxConstraints constraints, {required bool dry}) {
    // A core HtmlColumn can loosen a definite CSS height before reaching the
    // content. Retain that authored height; a tight flex-item allocation still
    // wins through BoxConstraints.tighten's clamping.
    final authoredHeight = configuration.containerHeight?.resolve(
      constraints.hasBoundedHeight ? constraints.maxHeight : null,
    );
    if (authoredHeight != null) {
      constraints = constraints.tighten(
        height: math.max(
          0,
          authoredHeight -
              (configuration.containerBorderBox
                  ? configuration.containerHeightEdges
                  : 0),
        ),
      );
    }
    // NativeDocumentFlex receives the flex container's content box after its
    // border and padding have been applied by the surrounding document boxes.
    // CSS percentage margins on every side resolve against this inline width.
    final inlineContentWidth = constraints.maxWidth.isFinite
        ? constraints.maxWidth
        : null;
    final maxMain = horizontal ? constraints.maxWidth : constraints.maxHeight;
    final maxCross = horizontal ? constraints.maxHeight : constraints.maxWidth;
    final definiteMain = horizontal
        ? (constraints.hasBoundedWidth ? maxMain : null)
        : (constraints.hasTightHeight ? maxMain : null);
    final definiteCross = horizontal
        ? (constraints.hasTightHeight ? maxCross : null)
        : (constraints.hasBoundedWidth ? maxCross : null);
    final all = <_FlexChild>[];
    var child = firstChild, index = 0;
    final sizes = <RenderBox, Size>{};
    Size measure(RenderBox box, BoxConstraints c) {
      if (dry) return sizes[box] = box.getDryLayout(c);
      box.layout(c, parentUsesSize: true);
      return sizes[box] = box.size;
    }

    while (child != null) {
      final spec = specification(
        child,
        index,
      )._resolvePercentageMargins(inlineContentWidth);
      final preferredCross = spec.preferredCross?.resolve(definiteCross);
      final probeCross = preferredCross == null
          ? null
          : outer(preferredCross, spec, cross: true);
      final probeConstraints = horizontal
          ? BoxConstraints(
              maxWidth: maxMain,
              minHeight: probeCross ?? 0,
              maxHeight: probeCross ?? double.infinity,
            )
          : BoxConstraints(
              minWidth: probeCross ?? 0,
              maxWidth: probeCross ?? maxCross,
            );
      final probe = measure(child, probeConstraints);
      final intrinsic = horizontal
          ? child.getMaxIntrinsicWidth(double.infinity)
          : main(probe);
      final preferred = spec.preferredMain?.resolve(definiteMain);
      final basis = spec.basis?.resolve(definiteMain) ?? preferred;
      final base = basis == null ? nonnegative(intrinsic) : outer(basis, spec);
      final minValue = spec.minimumMain?.resolve(definiteMain);
      final intrinsicMinimum = horizontal
          ? child.getMinIntrinsicWidth(double.infinity)
          : child.getMinIntrinsicHeight(definiteCross ?? cross(probe));
      var minimum = minValue != null
          ? outer(minValue, spec)
          : spec.automaticMinimum
          ? math.max(
              math.max(0.0, spec.mainEdges + spec.mainMargins),
              math.min(
                nonnegative(intrinsicMinimum),
                preferred == null ? double.infinity : outer(preferred, spec),
              ),
            )
          : math.max(0.0, spec.mainEdges + spec.mainMargins);
      final maxValue = spec.maximumMain?.resolve(definiteMain);
      if (minValue == null && spec.automaticMinimum && maxValue != null) {
        minimum = math.min(minimum, outer(maxValue, spec));
      }
      final maximum = math.max(
        minimum,
        maxValue == null ? double.infinity : outer(maxValue, spec),
      );
      all.add(_FlexChild(child, spec, index, base, minimum, maximum));
      child = (child.parentData! as _FlexParentData).nextSibling;
      index++;
    }
    all.sort((a, b) {
      final order = a.spec.order.compareTo(b.spec.order);
      return order != 0 ? order : a.index.compareTo(b.index);
    });
    final naturalMain = all.fold<double>(
      configuration.mainGap * math.max(0, all.length - 1),
      (sum, item) => sum + item.hypothetical,
    );
    final availableMain =
        definiteMain ??
        (horizontal
            ? constraints.constrainWidth(naturalMain)
            : constraints.constrainHeight(naturalMain));
    final lines = <_FlexLine>[];
    var line = _FlexLine(), used = 0.0;
    for (final item in all) {
      final next =
          used +
          (line.items.isEmpty ? 0 : configuration.mainGap) +
          item.hypothetical;
      if (configuration.wrap != NativeFlexWrap.nowrap &&
          line.items.isNotEmpty &&
          next > availableMain + .0000001) {
        lines.add(line);
        line = _FlexLine();
        used = 0;
      }
      used +=
          (line.items.isEmpty ? 0 : configuration.mainGap) + item.hypothetical;
      line.items.add(item);
    }
    if (line.items.isNotEmpty) lines.add(line);
    for (final line in lines) {
      resolveLine(line, availableMain);
      for (final item in line.items) {
        final preferredCross = item.spec.preferredCross?.resolve(definiteCross);
        final measured = measure(
          item.box,
          childConstraints(
            item.target,
            preferredCross == null
                ? null
                : outer(preferredCross, item.spec, cross: true),
            maxCross,
          ),
        );
        line.cross = math.max(line.cross, cross(measured));
      }
    }
    final naturalCross = lines.fold<double>(
      configuration.crossGap * math.max(0, lines.length - 1),
      (sum, line) => sum + line.cross,
    );
    final result = constraints.constrain(
      dimensions(availableMain, definiteCross ?? naturalCross),
    );
    final availableCross = cross(result);
    if (configuration.wrap == NativeFlexWrap.nowrap && lines.isNotEmpty) {
      lines.single.cross = availableCross;
    }
    var crossFree =
        availableCross -
        lines.fold<double>(
          configuration.crossGap * math.max(0, lines.length - 1),
          (sum, line) => sum + line.cross,
        );
    if (configuration.wrap != NativeFlexWrap.nowrap &&
        configuration.alignContent == NativeFlexContent.stretch &&
        crossFree > 0 &&
        lines.isNotEmpty) {
      for (final line in lines) {
        line.cross += crossFree / lines.length;
      }
      crossFree = 0;
    }
    final contentAlignment = switch (configuration.alignContent) {
      NativeFlexContent.end => MainAxisAlignment.end,
      NativeFlexContent.center => MainAxisAlignment.center,
      NativeFlexContent.spaceBetween => MainAxisAlignment.spaceBetween,
      NativeFlexContent.spaceAround => MainAxisAlignment.spaceAround,
      NativeFlexContent.spaceEvenly => MainAxisAlignment.spaceEvenly,
      _ => MainAxisAlignment.start,
    };
    final crossDistribution = distribute(
      contentAlignment,
      crossFree,
      lines.length,
      configuration.crossGap,
    );
    var crossPosition = configuration.wrap == NativeFlexWrap.nowrap
        ? 0.0
        : crossDistribution.$1;
    final reverseMain = horizontal
        ? (direction == TextDirection.rtl) != configuration.reverse
        : configuration.reverse;
    final reverseCross =
        (horizontal ? false : direction == TextDirection.rtl) !=
        (configuration.wrap == NativeFlexWrap.wrapReverse);
    for (final line in lines) {
      final free =
          availableMain -
          line.items.fold<double>(
            configuration.mainGap * math.max(0, line.items.length - 1),
            (sum, item) => sum + item.target,
          );
      final distribution = distribute(
        configuration.justify,
        free,
        line.items.length,
        configuration.mainGap,
      );
      var position = distribution.$1;
      for (final item in line.items) {
        final alignment = item.spec.align ?? configuration.align;
        if (alignment == CrossAxisAlignment.stretch && item.spec.stretchCross) {
          final minimum = item.spec.minimumCross?.resolve(definiteCross);
          final maximum = item.spec.maximumCross?.resolve(definiteCross);
          final minCross = minimum == null
              ? math.max(0.0, item.spec.crossEdges + item.spec.crossMargins)
              : outer(minimum, item.spec, cross: true);
          final maxCross = math.max(
            minCross,
            maximum == null
                ? double.infinity
                : outer(maximum, item.spec, cross: true),
          );
          measure(
            item.box,
            childConstraints(
              item.target,
              line.cross.clamp(minCross, maxCross).toDouble(),
              maxCross,
            ),
          );
        }
        final actual = sizes[item.box]!;
        final crossOffset = switch (alignment) {
          CrossAxisAlignment.end => line.cross - cross(actual),
          CrossAxisAlignment.center => (line.cross - cross(actual)) / 2,
          _ => 0.0,
        };
        final mainOffset = reverseMain
            ? availableMain - position - main(actual)
            : position;
        final crossOffsetInBox = reverseCross
            ? availableCross - crossPosition - crossOffset - cross(actual)
            : crossPosition + crossOffset;
        if (!dry) {
          (item.box.parentData! as _FlexParentData).offset = horizontal
              ? Offset(mainOffset, crossOffsetInBox)
              : Offset(crossOffsetInBox, mainOffset);
        }
        position += item.target + distribution.$2;
      }
      crossPosition += line.cross + crossDistribution.$2;
    }
    return result;
  }

  @override
  void performLayout() {
    size = layoutFlex(constraints, dry: false);
  }

  @override
  Size computeDryLayout(BoxConstraints constraints) =>
      layoutFlex(constraints, dry: true);
  @override
  void paint(PaintingContext context, Offset offset) =>
      defaultPaint(context, offset);
  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) =>
      defaultHitTestChildren(result, position: position);
}
