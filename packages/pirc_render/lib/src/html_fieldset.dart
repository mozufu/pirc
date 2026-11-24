import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_widget_from_html_core/flutter_widget_from_html_core.dart';

/// Registers the native fieldset frame while retaining its original child
/// placeholders. Call before `super.parse(tree)` in a `WidgetFactory.parse`
/// override and return when this reports a fieldset:
///
/// ```dart
/// if (registerNativeHtmlFieldset(tree, this)) return;
/// ```
///
/// Only the first direct `<legend>` is used as the border caption. Its child
/// placeholder is rendered unchanged, so links, rich text, controls, and
/// selection remain owned by their original builders. Later legends stay in
/// normal content flow.
///
/// This implements Chromium's default fieldset spacing and groove frame. It
/// does not interpret authored CSS selectors or custom `fieldset`/`legend`
/// border, display, margin, padding, sizing, or positioning declarations.
bool registerNativeHtmlFieldset(BuildTree tree, WidgetFactory factory) {
  final fieldset = tree.element;
  if (fieldset.localName != 'fieldset') return false;

  final firstLegend = fieldset.children
      .where((element) => element.localName == 'legend')
      .firstOrNull;

  tree.register(
    BuildOp(
      alwaysRenderBlock: true,
      debugLabel: 'nativeFieldset',
      priority: 1,
      onVisitChild: (fieldsetTree, childTree) {
        if (firstLegend == null ||
            childTree.element.parent != fieldsetTree.element ||
            childTree.element != firstLegend) {
          return;
        }

        childTree.register(
          BuildOp(
            alwaysRenderBlock: true,
            debugLabel: 'nativeFieldsetFirstLegend',
            priority: 1,
            onRenderedBlock: (legendTree, block) {
              _firstLegendTrees[block] = legendTree;
            },
          ),
        );
      },
      onRenderedChildren: (fieldsetTree, children) {
        WidgetPlaceholder? legend;
        final content = <WidgetPlaceholder>[];
        for (final child in children) {
          if (legend == null && child._nativeFieldsetLegendTree != null) {
            legend = child;
          } else {
            content.add(child);
          }
        }

        final body = factory.buildColumnPlaceholder(fieldsetTree, content);
        return WidgetPlaceholder(
          debugLabel: 'nativeFieldset--layout',
          builder: (context, _) {
            final resolved = fieldsetTree.inheritanceResolvers.resolve(context);
            final fontSize = resolved.prepareTextStyle().fontSize ?? 14;
            final direction =
                resolved.get<TextDirection>() ?? Directionality.of(context);
            final theme = Theme.of(context);
            return _NativeHtmlFieldset(
              legend: legend,
              content: body ?? const SizedBox.shrink(),
              hasLegend: legend != null,
              fontSize: fontSize,
              textDirection: direction,
              dark: theme.brightness == Brightness.dark,
            );
          },
        );
      },
    ),
  );
  return true;
}

final _firstLegendTrees = Expando<BuildTree>();

extension on Widget {
  BuildTree? get _nativeFieldsetLegendTree => _firstLegendTrees[this];
}

class _NativeHtmlFieldset extends MultiChildRenderObjectWidget {
  _NativeHtmlFieldset({
    required Widget? legend,
    required Widget content,
    required this.hasLegend,
    required this.fontSize,
    required this.textDirection,
    required this.dark,
  }) : super(
         children: [
           Padding(
             padding: const EdgeInsets.symmetric(horizontal: 2),
             child: legend == null
                 ? const SizedBox.shrink()
                 : IntrinsicWidth(child: legend),
           ),
           content,
         ],
       );

  final bool hasLegend;
  final double fontSize;
  final TextDirection textDirection;
  final bool dark;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderNativeHtmlFieldset(hasLegend, fontSize, textDirection, dark);

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderNativeHtmlFieldset renderObject,
  ) {
    renderObject
      ..hasLegend = hasLegend
      ..fontSize = fontSize
      ..textDirection = textDirection
      ..dark = dark;
  }
}

class _RenderNativeHtmlFieldset extends RenderBox
    with
        ContainerRenderObjectMixin<RenderBox, _FieldsetParentData>,
        RenderBoxContainerDefaultsMixin<RenderBox, _FieldsetParentData> {
  _RenderNativeHtmlFieldset(
    this._hasLegend,
    this._fontSize,
    this._textDirection,
    this._dark,
  );

  static const double _inlineMargin = 2;
  static const double _borderWidth = 2;
  static const double _legendInlinePadding = 2;

  bool _hasLegend;
  double _fontSize;
  TextDirection _textDirection;
  bool _dark;

  set hasLegend(bool value) {
    if (_hasLegend == value) return;
    _hasLegend = value;
    markNeedsLayout();
  }

  set fontSize(double value) {
    if (_fontSize == value) return;
    _fontSize = value;
    markNeedsLayout();
  }

  set textDirection(TextDirection value) {
    if (_textDirection == value) return;
    _textDirection = value;
    markNeedsLayout();
  }

  set dark(bool value) {
    if (_dark == value) return;
    _dark = value;
    markNeedsPaint();
  }

  RenderBox get _legend => firstChild!;
  RenderBox get _content => childAfter(_legend)!;

  double get _inlinePadding => _fontSize * 0.75;
  double get _blockStartPadding => _fontSize * 0.35;
  double get _blockEndPadding => _fontSize * 0.625;
  double get _horizontalInsets =>
      _inlineMargin * 2 + _borderWidth * 2 + _inlinePadding * 2;

  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! _FieldsetParentData) {
      child.parentData = _FieldsetParentData();
    }
  }

  @override
  double computeMinIntrinsicWidth(double height) {
    final minChildWidth = math.max(
      _content.getMinIntrinsicWidth(height),
      _hasLegend ? _legend.getMinIntrinsicWidth(height) : 0,
    );
    return minChildWidth + _horizontalInsets;
  }

  @override
  double computeMaxIntrinsicWidth(double height) {
    final maxChildWidth = math.max(
      _content.getMaxIntrinsicWidth(height),
      _hasLegend ? _legend.getMaxIntrinsicWidth(height) : 0,
    );
    return maxChildWidth + _horizontalInsets;
  }

  @override
  double computeMinIntrinsicHeight(double width) =>
      _intrinsicHeight(width, min: true);

  @override
  double computeMaxIntrinsicHeight(double width) =>
      _intrinsicHeight(width, min: false);

  double _intrinsicHeight(double width, {required bool min}) {
    final contentWidth = math.max(0.0, width - _horizontalInsets);
    final legendHeight = _hasLegend
        ? _legend.getMinIntrinsicHeight(contentWidth)
        : 0;
    final contentHeight = min
        ? _content.getMinIntrinsicHeight(contentWidth)
        : _content.getMaxIntrinsicHeight(contentWidth);
    final contentTop = _hasLegend
        ? legendHeight + _blockStartPadding
        : _borderWidth + _blockStartPadding;
    return contentTop + contentHeight + _blockEndPadding + _borderWidth;
  }

  @override
  Size computeDryLayout(BoxConstraints constraints) {
    final width = _outerWidth(constraints);
    final contentWidth = math.max(0.0, width - _horizontalInsets);
    final childConstraints = BoxConstraints(maxWidth: contentWidth);
    final legendSize = _hasLegend
        ? _legend.getDryLayout(
            BoxConstraints(maxWidth: contentWidth + _legendInlinePadding * 2),
          )
        : Size.zero;
    final contentSize = _content.getDryLayout(childConstraints);
    return constraints.constrain(
      Size(width, _outerHeight(legendSize.height, contentSize.height)),
    );
  }

  @override
  void performLayout() {
    final width = _outerWidth(constraints);
    final contentWidth = math.max(0.0, width - _horizontalInsets);
    final childConstraints = BoxConstraints(maxWidth: contentWidth);

    if (_hasLegend) {
      _legend.layout(
        BoxConstraints(maxWidth: contentWidth + _legendInlinePadding * 2),
        parentUsesSize: true,
      );
    } else {
      _legend.layout(const BoxConstraints(), parentUsesSize: true);
    }
    _content.layout(childConstraints, parentUsesSize: true);

    size = constraints.constrain(
      Size(width, _outerHeight(_legend.size.height, _content.size.height)),
    );

    final leadingContent = _inlineMargin + _borderWidth + _inlinePadding;
    final legendLeading = leadingContent - _legendInlinePadding;
    final legendParentData = _legend.parentData! as _FieldsetParentData;
    final contentParentData = _content.parentData! as _FieldsetParentData;
    legendParentData.offset = Offset(
      _textDirection == TextDirection.ltr
          ? legendLeading
          : size.width - legendLeading - _legend.size.width,
      0,
    );
    final contentTop = _hasLegend
        ? _legend.size.height + _blockStartPadding
        : _borderWidth + _blockStartPadding;
    contentParentData.offset = Offset(
      _textDirection == TextDirection.ltr
          ? leadingContent
          : size.width - leadingContent - _content.size.width,
      contentTop,
    );
  }

  double _outerWidth(BoxConstraints constraints) {
    if (constraints.hasBoundedWidth) return constraints.maxWidth;
    final intrinsic = computeMaxIntrinsicWidth(double.infinity);
    return constraints.constrainWidth(intrinsic);
  }

  double _outerHeight(double legendHeight, double contentHeight) {
    final contentTop = _hasLegend
        ? legendHeight + _blockStartPadding
        : _borderWidth + _blockStartPadding;
    return contentTop + contentHeight + _blockEndPadding + _borderWidth;
  }

  @override
  double? computeDryBaseline(
    BoxConstraints constraints,
    TextBaseline baseline,
  ) {
    final width = _outerWidth(constraints);
    final contentWidth = math.max(0.0, width - _horizontalInsets);
    final childConstraints = BoxConstraints(maxWidth: contentWidth);
    final legendHeight = _hasLegend
        ? _legend
              .getDryLayout(
                BoxConstraints(
                  maxWidth: contentWidth + _legendInlinePadding * 2,
                ),
              )
              .height
        : 0;
    final contentTop = _hasLegend
        ? legendHeight + _blockStartPadding
        : _borderWidth + _blockStartPadding;
    final contentBaseline = _content.getDryBaseline(childConstraints, baseline);
    return contentBaseline == null ? null : contentTop + contentBaseline;
  }

  @override
  double? computeDistanceToActualBaseline(TextBaseline baseline) {
    final parentData = _content.parentData! as _FieldsetParentData;
    final contentBaseline = _content.getDistanceToBaseline(baseline);
    return contentBaseline == null
        ? null
        : parentData.offset.dy + contentBaseline;
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    _paintBorder(context.canvas, offset);
    defaultPaint(context, offset);
  }

  void _paintBorder(Canvas canvas, Offset offset) {
    final left = offset.dx + _inlineMargin;
    final right = offset.dx + size.width - _inlineMargin;
    final top = offset.dy + (_hasLegend ? _legend.size.height / 2 : 0);
    final bottom = offset.dy + size.height - _borderWidth / 2;
    if (right <= left || bottom <= top) return;

    final gapStart = _hasLegend
        ? (_legend.parentData! as _FieldsetParentData).offset.dx + offset.dx
        : left;
    final gapEnd = _hasLegend ? gapStart + _legend.size.width : gapStart;
    final dark = _dark;
    final topLeft = dark ? const Color(0xFFB7B7B7) : const Color(0xFF767676);
    final bottomRight = dark
        ? const Color(0xFF656565)
        : const Color(0xFFD6D6D6);

    void line(Offset start, Offset end, Color color) {
      canvas.drawLine(
        start,
        end,
        Paint()
          ..color = color
          ..strokeWidth = 1,
      );
    }

    void horizontal(double y, Color color) {
      if (gapEnd <= left || gapStart >= right) {
        line(Offset(left, y), Offset(right, y), color);
        return;
      }
      if (gapStart > left) {
        line(Offset(left, y), Offset(gapStart - 1, y), color);
      }
      if (gapEnd < right) line(Offset(gapEnd + 1, y), Offset(right, y), color);
    }

    // CSS groove uses a darker upper/leading bevel and a lighter lower/trailing
    // bevel in light color schemes. Two one-pixel passes retain that relief.
    horizontal(top + 0.5, topLeft);
    line(Offset(left + 0.5, top + 1), Offset(left + 0.5, bottom), topLeft);
    line(
      Offset(right - 0.5, top + 1),
      Offset(right - 0.5, bottom),
      bottomRight,
    );
    horizontal(bottom - 0.5, bottomRight);
    horizontal(top + 1.5, bottomRight);
    line(
      Offset(left + 1.5, top + 2),
      Offset(left + 1.5, bottom - 1),
      bottomRight,
    );
    line(
      Offset(right - 1.5, top + 2),
      Offset(right - 1.5, bottom - 1),
      topLeft,
    );
    horizontal(bottom - 1.5, topLeft);
  }

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) =>
      defaultHitTestChildren(result, position: position);
}

class _FieldsetParentData extends ContainerBoxParentData<RenderBox> {}
