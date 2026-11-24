import 'render_l10n.dart';
import 'dart:math' as math;

import 'package:csslib/parser.dart' as css_parser;
import 'package:csslib/visitor.dart' as css;
import 'package:flutter/material.dart';

enum NativeHtmlControlBoxSizing { contentBox, borderBox }

/// The browser-like starting box used when only part of a control is styled.
enum NativeHtmlControlBoxUaPreset {
  textInput,
  dateInput,
  textarea,
  select,
  none,
}

/// A parsed CSS length used by a native HTML control's box model.
///
/// Pixel and font-relative units are stored in logical pixels. Percentages
/// remain percentages until [NativeHtmlControlBoxStyle.resolveSize] receives
/// the control's actual parent constraints.
@immutable
class NativeHtmlControlBoxLength {
  const NativeHtmlControlBoxLength(this.value, this.unit);

  final double value;
  final String unit;

  double? resolve({required double? percentageBase}) => switch (unit) {
    'px' => value,
    '%' => percentageBase == null ? null : percentageBase * value / 100,
    _ => null,
  };

  @override
  String toString() => '$value$unit';
}

/// Widths for each side of CSS padding, retaining percentages lazily.
@immutable
class NativeHtmlControlBoxInsets {
  const NativeHtmlControlBoxInsets({
    required this.top,
    required this.right,
    required this.bottom,
    required this.left,
  });

  final NativeHtmlControlBoxLength top;
  final NativeHtmlControlBoxLength right;
  final NativeHtmlControlBoxLength bottom;
  final NativeHtmlControlBoxLength left;

  bool get hasPercentages =>
      top.unit == '%' ||
      right.unit == '%' ||
      bottom.unit == '%' ||
      left.unit == '%';

  EdgeInsets resolve({required double? percentageBase}) => EdgeInsets.fromLTRB(
    left.resolve(percentageBase: percentageBase) ?? 0,
    top.resolve(percentageBase: percentageBase) ?? 0,
    right.resolve(percentageBase: percentageBase) ?? 0,
    bottom.resolve(percentageBase: percentageBase) ?? 0,
  );
}

@immutable
class NativeHtmlControlBoxDiagnostic {
  const NativeHtmlControlBoxDiagnostic({
    required this.code,
    required this.property,
    required this.value,
    required this.message,
  });

  final String code;
  final String property;
  final String value;
  final String message;

  @override
  String toString() => '$code ($property: $value): $message';
}

@immutable
class NativeHtmlControlBoxLayout {
  const NativeHtmlControlBoxLayout({
    required this.size,
    required this.padding,
    required this.border,
    required this.borderStyleNames,
    required this.borderRadius,
    required this.backgroundColor,
    required this.diagnostics,
  });

  final Size size;
  final EdgeInsets padding;
  final Border border;
  final Map<String, String> borderStyleNames;
  final BorderRadius borderRadius;
  final Color? backgroundColor;
  final List<NativeHtmlControlBoxDiagnostic> diagnostics;
}

/// CSS box properties for native text inputs and textareas.
///
/// The caller supplies declarations in cascade order. This class preserves
/// `!important` precedence and source order among declarations in the same
/// cascade tier. It handles the box properties used by text inputs and
/// textareas; other CSS values are reported through [diagnostics].
@immutable
class NativeHtmlControlBoxStyle {
  const NativeHtmlControlBoxStyle._({
    required this.paddingLengths,
    required this.border,
    required this.borderStyleNames,
    required this.borderRadius,
    required this.backgroundColor,
    required this.boxSizing,
    required this.width,
    required this.height,
    required this.minWidth,
    required this.maxWidth,
    required this.minHeight,
    required this.maxHeight,
    required this.specifiedProperties,
    required this.diagnostics,
    required this.fontSize,
    required this.rootFontSize,
    required this._cornerRadii,
    required this._borderColorProperties,
  });

  factory NativeHtmlControlBoxStyle.fromDeclarations(
    Iterable<css.Declaration> declarations, {
    required double fontSize,
    double rootFontSize = 16,
    required bool dark,
    required bool multiline,
    bool applyUaDefaults = true,
    NativeHtmlControlBoxUaPreset? uaPreset,
    Color? currentColor,
  }) {
    return _ControlBoxStyleBuilder(
      fontSize: fontSize,
      rootFontSize: rootFontSize,
      dark: dark,
      multiline: multiline,
      applyUaDefaults: applyUaDefaults,
      uaPreset: uaPreset,
      currentColor: currentColor,
    ).build(declarations);
  }

  /// Padding lengths, including unresolved percentages.
  final NativeHtmlControlBoxInsets paddingLengths;

  /// Pixel padding for immediate inspection. Use [resolvePadding] in layout
  /// code so percentage padding receives the containing block width.
  EdgeInsets get padding => paddingLengths.resolve(percentageBase: null);

  /// The effective border widths/colors. Patterned styles are retained in
  /// [borderStyleNames] for native painting; unimplemented effects are diagnosed; `none` and `hidden` remain unpainted.
  final Border border;
  final Map<String, String> borderStyleNames;

  /// The effective radius without percentage corners. Use [resolveLayout] for
  /// percentage radius values.
  final BorderRadius borderRadius;

  /// The background color, or null when the overlay did not specify one and
  /// UA defaults are disabled.
  final Color? backgroundColor;

  final NativeHtmlControlBoxSizing boxSizing;
  final NativeHtmlControlBoxLength? width;
  final NativeHtmlControlBoxLength? height;
  final NativeHtmlControlBoxLength? minWidth;
  final NativeHtmlControlBoxLength? maxWidth;
  final NativeHtmlControlBoxLength? minHeight;
  final NativeHtmlControlBoxLength? maxHeight;

  /// Properties accepted from the declarations. Shorthands are recorded along
  /// with the expanded longhands, for example `border` and `border-top-width`.
  final Set<String> specifiedProperties;

  final List<NativeHtmlControlBoxDiagnostic> diagnostics;
  final double fontSize;
  final double rootFontSize;
  final List<_CornerRadius> _cornerRadii;
  final Set<String> _borderColorProperties;

  bool get hasAuthoredBackground =>
      specifiedProperties.contains('background-color');

  EdgeInsets resolvePadding(BoxConstraints constraints) =>
      paddingLengths.resolve(
        percentageBase: constraints.hasBoundedWidth
            ? constraints.maxWidth
            : null,
      );

  /// Replaces only UA border colors with the existing disabled appearance.
  /// Authored side colors retain their CSS value.
  Border borderForEnabledState({
    required bool enabled,
    required Color disabledBorderColor,
  }) {
    if (enabled || _borderColorProperties.length == 4) return border;
    return Border(
      top: _borderColorProperties.contains('border-top-color')
          ? border.top
          : border.top.copyWith(color: disabledBorderColor),
      right: _borderColorProperties.contains('border-right-color')
          ? border.right
          : border.right.copyWith(color: disabledBorderColor),
      bottom: _borderColorProperties.contains('border-bottom-color')
          ? border.bottom
          : border.bottom.copyWith(color: disabledBorderColor),
      left: _borderColorProperties.contains('border-left-color')
          ? border.left
          : border.left.copyWith(color: disabledBorderColor),
    );
  }

  NativeHtmlControlBoxLayout resolveLayout({
    required Size intrinsicBorderBoxSize,
    required BoxConstraints constraints,
  }) {
    final layoutDiagnostics = <NativeHtmlControlBoxDiagnostic>[...diagnostics];
    final availableWidth = constraints.hasBoundedWidth
        ? constraints.maxWidth
        : null;
    final availableHeight = constraints.hasBoundedHeight
        ? constraints.maxHeight
        : null;
    final resolvedPadding = paddingLengths.resolve(
      percentageBase: availableWidth,
    );
    if (paddingLengths.hasPercentages && availableWidth == null) {
      layoutDiagnostics.add(
        NativeHtmlControlBoxDiagnostic(
          code: 'unresolved-percentage',
          property: 'padding',
          value: '%',
          message: tr(
            "Percentage padding needs a finite containing block width; zero is used.",
          ),
        ),
      );
    }

    final horizontalExtras =
        resolvedPadding.horizontal + border.left.width + border.right.width;
    final verticalExtras =
        resolvedPadding.vertical + border.top.width + border.bottom.width;
    final specifiedWidth = _resolveDimension(
      width,
      percentageBase: availableWidth,
      property: 'width',
      diagnostics: layoutDiagnostics,
    );
    final specifiedHeight = _resolveDimension(
      height,
      percentageBase: availableHeight,
      property: 'height',
      diagnostics: layoutDiagnostics,
    );
    final minimumWidth = _resolveDimension(
      minWidth,
      percentageBase: availableWidth,
      property: 'min-width',
      diagnostics: layoutDiagnostics,
    );
    final maximumWidth = _resolveDimension(
      maxWidth,
      percentageBase: availableWidth,
      property: 'max-width',
      diagnostics: layoutDiagnostics,
    );
    final minimumHeight = _resolveDimension(
      minHeight,
      percentageBase: availableHeight,
      property: 'min-height',
      diagnostics: layoutDiagnostics,
    );
    final maximumHeight = _resolveDimension(
      maxHeight,
      percentageBase: availableHeight,
      property: 'max-height',
      diagnostics: layoutDiagnostics,
    );

    double asBorderBox(double value, double extras) =>
        boxSizing == NativeHtmlControlBoxSizing.borderBox
        ? value
        : value + extras;

    var usedWidth = specifiedWidth == null
        ? intrinsicBorderBoxSize.width
        : asBorderBox(specifiedWidth, horizontalExtras);
    var usedHeight = specifiedHeight == null
        ? intrinsicBorderBoxSize.height
        : asBorderBox(specifiedHeight, verticalExtras);
    final minWidthBorderBox = minimumWidth == null
        ? null
        : asBorderBox(minimumWidth, horizontalExtras);
    final maxWidthBorderBox = maximumWidth == null
        ? null
        : asBorderBox(maximumWidth, horizontalExtras);
    final minHeightBorderBox = minimumHeight == null
        ? null
        : asBorderBox(minimumHeight, verticalExtras);
    final maxHeightBorderBox = maximumHeight == null
        ? null
        : asBorderBox(maximumHeight, verticalExtras);

    usedWidth = _clampUsedSize(usedWidth, minWidthBorderBox, maxWidthBorderBox);
    usedHeight = _clampUsedSize(
      usedHeight,
      minHeightBorderBox,
      maxHeightBorderBox,
    );
    final constrained = constraints.constrain(Size(usedWidth, usedHeight));
    final resolvedRadius = _resolveBorderRadius(
      constrained.width,
      constrained.height,
    );

    return NativeHtmlControlBoxLayout(
      size: constrained,
      padding: resolvedPadding,
      border: border,
      borderStyleNames: borderStyleNames,
      borderRadius: resolvedRadius,
      backgroundColor: backgroundColor,
      diagnostics: List.unmodifiable(layoutDiagnostics),
    );
  }

  /// Resolves CSS width, height, and min/max dimensions against constraints.
  Size resolveSize(Size intrinsicBorderBoxSize, BoxConstraints constraints) =>
      resolveLayout(
        intrinsicBorderBoxSize: intrinsicBorderBoxSize,
        constraints: constraints,
      ).size;

  BorderRadius resolveBorderRadius(BoxConstraints constraints) =>
      _resolveBorderRadius(
        constraints.hasBoundedWidth ? constraints.maxWidth : 0,
        constraints.hasBoundedHeight ? constraints.maxHeight : 0,
      );

  BorderRadius _resolveBorderRadius(double width, double height) {
    Radius resolve(_CornerRadius radius) => Radius.elliptical(
      radius.horizontal.resolve(percentageBase: width) ?? 0,
      radius.vertical.resolve(percentageBase: height) ?? 0,
    );

    return BorderRadius.only(
      topLeft: resolve(_cornerRadii[0]),
      topRight: resolve(_cornerRadii[1]),
      bottomRight: resolve(_cornerRadii[2]),
      bottomLeft: resolve(_cornerRadii[3]),
    );
  }

  double? _resolveDimension(
    NativeHtmlControlBoxLength? length, {
    required double? percentageBase,
    required String property,
    required List<NativeHtmlControlBoxDiagnostic> diagnostics,
  }) {
    if (length == null) return null;
    final resolved = length.resolve(percentageBase: percentageBase);
    if (resolved == null) {
      diagnostics.add(
        NativeHtmlControlBoxDiagnostic(
          code: 'unresolved-percentage',
          property: property,
          value: length.toString(),
          message: tr(
            "A finite containing block is required; the intrinsic size is used.",
          ),
        ),
      );
    }
    return resolved;
  }

  static double _clampUsedSize(double value, double? min, double? max) {
    final lowerBounded = min == null ? value : math.max(value, min);
    if (max == null || (min != null && min > max)) return lowerBounded;
    return math.min(lowerBounded, max);
  }
}

class _ControlBoxStyleBuilder {
  _ControlBoxStyleBuilder({
    required this.fontSize,
    required this.rootFontSize,
    required this.dark,
    required this.multiline,
    required this.applyUaDefaults,
    required NativeHtmlControlBoxUaPreset? uaPreset,
    Color? currentColor,
  }) : currentColor =
           currentColor ??
           (dark ? const Color(0xffffffff) : const Color(0xff000000)),
       defaultBorderColor = dark
           ? const Color(0xff858585)
           : const Color(0xff767676),
       defaultBackground = dark
           ? const Color(0xff3b3b3b)
           : const Color(0xffffffff),
       uaPreset =
           uaPreset ??
           (multiline
               ? NativeHtmlControlBoxUaPreset.textarea
               : NativeHtmlControlBoxUaPreset.textInput);

  final double fontSize;
  final double rootFontSize;
  final bool dark;
  final bool multiline;
  final bool applyUaDefaults;
  final NativeHtmlControlBoxUaPreset uaPreset;
  final Color currentColor;
  final Color defaultBorderColor;
  final Color defaultBackground;
  final Map<String, _CascadeBoxValue> winners = {};
  final Set<String> specified = {};
  final List<NativeHtmlControlBoxDiagnostic> diagnostics = [];
  var order = 0;

  NativeHtmlControlBoxStyle build(Iterable<css.Declaration> declarations) {
    for (final declaration in declarations) {
      _addDeclaration(declaration);
      order++;
    }

    final defaultPadding = applyUaDefaults
        ? uaPreset == NativeHtmlControlBoxUaPreset.textarea
              ? const NativeHtmlControlBoxInsets(
                  top: NativeHtmlControlBoxLength(2, 'px'),
                  right: NativeHtmlControlBoxLength(2, 'px'),
                  bottom: NativeHtmlControlBoxLength(2, 'px'),
                  left: NativeHtmlControlBoxLength(2, 'px'),
                )
              : uaPreset == NativeHtmlControlBoxUaPreset.textInput
              ? const NativeHtmlControlBoxInsets(
                  top: NativeHtmlControlBoxLength(1, 'px'),
                  right: NativeHtmlControlBoxLength(2, 'px'),
                  bottom: NativeHtmlControlBoxLength(1, 'px'),
                  left: NativeHtmlControlBoxLength(2, 'px'),
                )
              : uaPreset == NativeHtmlControlBoxUaPreset.dateInput
              ? const NativeHtmlControlBoxInsets(
                  top: NativeHtmlControlBoxLength(0, 'px'),
                  right: NativeHtmlControlBoxLength(0, 'px'),
                  bottom: NativeHtmlControlBoxLength(0, 'px'),
                  left: NativeHtmlControlBoxLength(1, 'px'),
                )
              : uaPreset == NativeHtmlControlBoxUaPreset.select
              ? const NativeHtmlControlBoxInsets(
                  top: NativeHtmlControlBoxLength(0, 'px'),
                  right: NativeHtmlControlBoxLength(2, 'px'),
                  bottom: NativeHtmlControlBoxLength(0, 'px'),
                  left: NativeHtmlControlBoxLength(2, 'px'),
                )
              : const NativeHtmlControlBoxInsets(
                  top: NativeHtmlControlBoxLength(0, 'px'),
                  right: NativeHtmlControlBoxLength(0, 'px'),
                  bottom: NativeHtmlControlBoxLength(0, 'px'),
                  left: NativeHtmlControlBoxLength(0, 'px'),
                )
        : const NativeHtmlControlBoxInsets(
            top: NativeHtmlControlBoxLength(0, 'px'),
            right: NativeHtmlControlBoxLength(0, 'px'),
            bottom: NativeHtmlControlBoxLength(0, 'px'),
            left: NativeHtmlControlBoxLength(0, 'px'),
          );
    NativeHtmlControlBoxLength resolvePadding(String property) =>
        winners[property]?.value as NativeHtmlControlBoxLength? ??
        _paddingSide(defaultPadding, property);
    final padding = NativeHtmlControlBoxInsets(
      top: resolvePadding('padding-top'),
      right: resolvePadding('padding-right'),
      bottom: resolvePadding('padding-bottom'),
      left: resolvePadding('padding-left'),
    );

    final uaBorderWidth = switch (uaPreset) {
      NativeHtmlControlBoxUaPreset.textInput ||
      NativeHtmlControlBoxUaPreset.dateInput => 2.0,
      NativeHtmlControlBoxUaPreset.textarea ||
      NativeHtmlControlBoxUaPreset.select => 1.0,
      NativeHtmlControlBoxUaPreset.none => 0.0,
    };
    final defaultWidth = NativeHtmlControlBoxLength(
      applyUaDefaults ? uaBorderWidth : 0,
      'px',
    );
    final defaultStyle =
        applyUaDefaults && uaPreset != NativeHtmlControlBoxUaPreset.none
        ? uaPreset == NativeHtmlControlBoxUaPreset.dateInput
              ? 'inset'
              : 'solid'
        : 'none';
    final defaultColor = applyUaDefaults
        ? defaultBorderColor
        : const Color(0x00000000);
    final borderColorProperties = <String>{};
    BorderSide side(String side) {
      final width =
          (winners['border-$side-width']?.value as NativeHtmlControlBoxLength?)
              ?.value ??
          defaultWidth.value;
      final borderStyle =
          winners['border-$side-style']?.value as String? ?? defaultStyle;
      final color =
          winners['border-$side-color']?.value as Color? ?? defaultColor;
      if (winners.containsKey('border-$side-color')) {
        borderColorProperties.add('border-$side-color');
      }
      if (borderStyle == 'none' || borderStyle == 'hidden') {
        return BorderSide.none;
      }
      return BorderSide(color: color, width: width);
    }

    final border = Border(
      top: side('top'),
      right: side('right'),
      bottom: side('bottom'),
      left: side('left'),
    );
    final borderRadiusValues = <_CornerRadius>[
      for (final property in const [
        'border-top-left-radius',
        'border-top-right-radius',
        'border-bottom-right-radius',
        'border-bottom-left-radius',
      ])
        winners[property]?.value as _CornerRadius? ??
            const _CornerRadius(
              NativeHtmlControlBoxLength(0, 'px'),
              NativeHtmlControlBoxLength(0, 'px'),
            ),
    ];
    final borderRadius = BorderRadius.only(
      topLeft: Radius.elliptical(
        borderRadiusValues[0].horizontal.resolve(percentageBase: null) ?? 0,
        borderRadiusValues[0].vertical.resolve(percentageBase: null) ?? 0,
      ),
      topRight: Radius.elliptical(
        borderRadiusValues[1].horizontal.resolve(percentageBase: null) ?? 0,
        borderRadiusValues[1].vertical.resolve(percentageBase: null) ?? 0,
      ),
      bottomRight: Radius.elliptical(
        borderRadiusValues[2].horizontal.resolve(percentageBase: null) ?? 0,
        borderRadiusValues[2].vertical.resolve(percentageBase: null) ?? 0,
      ),
      bottomLeft: Radius.elliptical(
        borderRadiusValues[3].horizontal.resolve(percentageBase: null) ?? 0,
        borderRadiusValues[3].vertical.resolve(percentageBase: null) ?? 0,
      ),
    );
    final boxSizing =
        winners['box-sizing']?.value as NativeHtmlControlBoxSizing? ??
        (applyUaDefaults
            ? NativeHtmlControlBoxSizing.borderBox
            : NativeHtmlControlBoxSizing.contentBox);
    final width = winners['width']?.value as NativeHtmlControlBoxLength?;
    final height = winners['height']?.value as NativeHtmlControlBoxLength?;
    final minWidth =
        winners['min-width']?.value as NativeHtmlControlBoxLength? ??
        (applyUaDefaults ? const NativeHtmlControlBoxLength(0, 'px') : null);
    final maxWidth = winners['max-width']?.value as NativeHtmlControlBoxLength?;
    final minHeight =
        winners['min-height']?.value as NativeHtmlControlBoxLength? ??
        (applyUaDefaults ? const NativeHtmlControlBoxLength(0, 'px') : null);
    final maxHeight =
        winners['max-height']?.value as NativeHtmlControlBoxLength?;

    return NativeHtmlControlBoxStyle._(
      paddingLengths: padding,
      border: border,
      borderStyleNames: Map.unmodifiable({
        for (final side in _borderSides)
          side: winners['border-$side-style']?.value as String? ?? defaultStyle,
      }),
      borderRadius: borderRadius,
      backgroundColor:
          winners['background-color']?.value as Color? ??
          (applyUaDefaults && uaPreset != NativeHtmlControlBoxUaPreset.select
              ? defaultBackground
              : null),
      boxSizing: boxSizing,
      width: width,
      height: height,
      minWidth: minWidth,
      maxWidth: maxWidth,
      minHeight: minHeight,
      maxHeight: maxHeight,
      specifiedProperties: Set.unmodifiable(specified),
      diagnostics: List.unmodifiable(diagnostics),
      fontSize: fontSize,
      rootFontSize: rootFontSize,
      cornerRadii: List.unmodifiable(borderRadiusValues),
      borderColorProperties: Set.unmodifiable(borderColorProperties),
    );
  }

  NativeHtmlControlBoxLength _paddingSide(
    NativeHtmlControlBoxInsets padding,
    String property,
  ) => switch (property) {
    'padding-top' => padding.top,
    'padding-right' => padding.right,
    'padding-bottom' => padding.bottom,
    _ => padding.left,
  };

  void _addDeclaration(css.Declaration declaration) {
    final property = declaration.property.toLowerCase();
    final expression = declaration.expression;
    if (expression == null) {
      _diagnose(
        'invalid-declaration',
        property,
        '',
        tr("The declaration has no value."),
      );
      return;
    }
    final valueText = _expressionText(expression);

    if (property == 'padding') {
      final values = _parseBoxLengths(
        expression,
        property,
        allowPercent: true,
        nonNegative: true,
      );
      if (values == null) return;
      final names = const [
        'padding-top',
        'padding-right',
        'padding-bottom',
        'padding-left',
      ];
      for (var index = 0; index < names.length; index++) {
        _offer(
          names[index],
          values[_fourSideIndex(values.length, index)],
          declaration.important,
        );
      }
      specified.add(property);
      return;
    }
    if (const {
      'padding-top',
      'padding-right',
      'padding-bottom',
      'padding-left',
    }.contains(property)) {
      final length = _parseLength(
        expression,
        property,
        allowPercent: true,
        nonNegative: true,
      );
      if (length != null) _offer(property, length, declaration.important);
      return;
    }

    if (property == 'border' || _borderSideNames.containsKey(property)) {
      final components = _parseBorderShorthand(expression, property);
      if (components == null) return;
      final sides = property == 'border'
          ? _borderSides
          : [_borderSideNames[property]!];
      for (final side in sides) {
        _offer('border-$side-width', components.width, declaration.important);
        _offer('border-$side-style', components.style, declaration.important);
        _offer('border-$side-color', components.color, declaration.important);
      }
      specified.add(property);
      return;
    }
    if (property == 'border-width' ||
        _borderWidthProperties.contains(property)) {
      final values = _parseBoxLengths(
        expression,
        property,
        allowPercent: false,
        nonNegative: true,
        allowBorderWidthKeywords: true,
      );
      if (values == null) return;
      final properties = property == 'border-width'
          ? _borderSides.map((side) => 'border-$side-width').toList()
          : [property];
      for (var index = 0; index < properties.length; index++) {
        _offer(
          properties[index],
          values[property == 'border-width'
              ? _fourSideIndex(values.length, index)
              : 0],
          declaration.important,
        );
      }
      specified.add(property);
      return;
    }
    if (property == 'border-style' ||
        _borderStyleProperties.contains(property)) {
      final values = _parseStyleValues(expression, property);
      if (values == null) return;
      final properties = property == 'border-style'
          ? _borderSides.map((side) => 'border-$side-style').toList()
          : [property];
      for (var index = 0; index < properties.length; index++) {
        _offer(
          properties[index],
          values[property == 'border-style'
              ? _fourSideIndex(values.length, index)
              : 0],
          declaration.important,
        );
      }
      specified.add(property);
      return;
    }
    if (property == 'border-color' ||
        _borderColorProperties.contains(property)) {
      final values = _parseColorValues(expression, property);
      if (values == null) return;
      final properties = property == 'border-color'
          ? _borderSides.map((side) => 'border-$side-color').toList()
          : [property];
      for (var index = 0; index < properties.length; index++) {
        _offer(
          properties[index],
          values[property == 'border-color'
              ? _fourSideIndex(values.length, index)
              : 0],
          declaration.important,
        );
      }
      specified.add(property);
      return;
    }
    if (property == 'border-radius') {
      final radii = _parseRadii(expression, property);
      if (radii == null) return;
      final properties = _borderRadiusProperties.toList();
      for (var index = 0; index < properties.length; index++) {
        _offer(properties[index], radii[index], declaration.important);
      }
      specified.add(property);
      return;
    }
    if (_borderRadiusProperties.contains(property)) {
      final radius = _parseCornerRadius(expression, property);
      if (radius == null) return;
      _offer(property, radius, declaration.important);
      specified.add(property);
      return;
    }

    if (property == 'background' || property == 'background-color') {
      final color = _parseColor(
        expression,
        property,
        allowNone: property == 'background',
      );
      if (color != null) {
        _offer('background-color', color, declaration.important);
        specified.add(property);
      }
      return;
    }
    if (_dimensionProperties.contains(property)) {
      final allowNone = property.startsWith('max-');
      final length = _parseOptionalDimension(
        expression,
        property,
        allowPercent: true,
        allowAuto: true,
        allowNone: allowNone,
      );
      if (length.$1) _offer(property, length.$2, declaration.important);
      return;
    }
    if (property == 'box-sizing') {
      final word = valueText.toLowerCase();
      final sizing = switch (word) {
        'border-box' => NativeHtmlControlBoxSizing.borderBox,
        'content-box' => NativeHtmlControlBoxSizing.contentBox,
        _ => null,
      };
      if (sizing == null) {
        _diagnose(
          'unsupported-value',
          property,
          valueText,
          tr("Expected content-box or border-box."),
        );
      } else {
        _offer(property, sizing, declaration.important);
      }
    }
  }

  void _offer(String property, Object? value, bool important) {
    final current = winners[property];
    if (current == null ||
        (important && !current.important) ||
        (important == current.important && order >= current.order)) {
      winners[property] = _CascadeBoxValue(
        value: value,
        important: important,
        order: order,
      );
    }
    specified.add(property);
  }

  List<NativeHtmlControlBoxLength>? _parseBoxLengths(
    css.Expression expression,
    String property, {
    required bool allowPercent,
    required bool nonNegative,
    bool allowBorderWidthKeywords = false,
  }) {
    final terms = _terms(expression);
    if (terms.isEmpty || terms.length > 4) {
      _diagnose(
        'unsupported-value',
        property,
        _expressionText(expression),
        tr("Expected one to four lengths."),
      );
      return null;
    }
    final values = <NativeHtmlControlBoxLength>[];
    for (final term in terms) {
      final value = _parseLength(
        term,
        property,
        allowPercent: allowPercent,
        nonNegative: nonNegative,
        allowBorderWidthKeywords: allowBorderWidthKeywords,
      );
      if (value == null) return null;
      values.add(value);
    }
    return values;
  }

  NativeHtmlControlBoxLength? _parseLength(
    css.Expression expression,
    String property, {
    required bool allowPercent,
    required bool nonNegative,
    bool allowBorderWidthKeywords = false,
    bool diagnoseFailure = true,
  }) {
    final term = _singleTerm(expression);
    final text = _expressionText(expression);
    if (term == null) {
      if (diagnoseFailure) {
        _diagnose(
          'unsupported-value',
          property,
          text,
          tr("Expected a single CSS length."),
        );
      }
      return null;
    }
    if (allowBorderWidthKeywords) {
      final keyword = text.toLowerCase();
      final keywordWidth = switch (keyword) {
        'thin' => 1.0,
        'medium' => 3.0,
        'thick' => 5.0,
        _ => null,
      };
      if (keywordWidth != null) {
        return NativeHtmlControlBoxLength(keywordWidth, 'px');
      }
    }

    double? value;
    String? unit;
    if (term is css.PercentageTerm && term.value is num) {
      value = (term.value as num).toDouble();
      unit = '%';
      if (!allowPercent) {
        if (diagnoseFailure) {
          _diagnose(
            'unsupported-value',
            property,
            text,
            tr("Percentages are not valid for this property."),
          );
        }
        return null;
      }
    } else if (term is css.EmTerm && term.value is num) {
      value = (term.value as num).toDouble() * fontSize;
      unit = 'px';
    } else if (term is css.RemTerm && term.value is num) {
      value = (term.value as num).toDouble() * rootFontSize;
      unit = 'px';
    } else if (term is css.UnitTerm && term.value is num) {
      final amount = (term.value as num).toDouble();
      final factor = switch (term.unitToString()?.toLowerCase()) {
        'px' => 1.0,
        'in' => 96.0,
        'cm' => 96 / 2.54,
        'mm' => 96 / 25.4,
        'pt' => 96 / 72,
        'pc' => 16.0,
        _ => null,
      };
      if (factor == null) {
        if (diagnoseFailure) {
          _diagnose(
            'unsupported-unit',
            property,
            text,
            tr("This CSS length unit is not supported."),
          );
        }
        return null;
      }
      value = amount * factor;
      unit = 'px';
    } else if (term is css.NumberTerm && term.value is num && term.value == 0) {
      value = 0;
      unit = 'px';
    }
    if (value == null || unit == null) {
      if (diagnoseFailure) {
        _diagnose(
          'unsupported-value',
          property,
          text,
          tr("This CSS value is not a supported length."),
        );
      }
      return null;
    }
    if (nonNegative && value < 0) {
      if (diagnoseFailure) {
        _diagnose(
          'invalid-value',
          property,
          text,
          tr("Negative lengths are invalid here."),
        );
      }
      return null;
    }
    return NativeHtmlControlBoxLength(value, unit);
  }

  (bool, NativeHtmlControlBoxLength?) _parseOptionalDimension(
    css.Expression expression,
    String property, {
    required bool allowPercent,
    required bool allowAuto,
    required bool allowNone,
  }) {
    final text = _expressionText(expression);
    final lower = text.toLowerCase();
    if ((allowAuto && lower == 'auto') || (allowNone && lower == 'none')) {
      return (true, null);
    }
    final parsed = _parseLength(
      expression,
      property,
      allowPercent: allowPercent,
      nonNegative: true,
    );
    return (parsed != null, parsed);
  }

  _BorderComponents? _parseBorderShorthand(
    css.Expression expression,
    String property,
  ) {
    final terms = _terms(expression);
    if (terms.length == 1) {
      final keyword = _expressionText(terms.single).toLowerCase();
      if (_cssWideKeywords.contains(keyword)) {
        _diagnose(
          'unsupported-css-wide-keyword',
          property,
          keyword,
          tr("CSS-wide border values require parent box values."),
        );
        return null;
      }
    }
    if (terms.isEmpty || terms.length > 3) {
      _diagnose(
        'unsupported-value',
        property,
        _expressionText(expression),
        tr("Expected a border width, style, and color."),
      );
      return null;
    }

    NativeHtmlControlBoxLength? width;
    String? style;
    Color? color;
    for (final term in terms) {
      final text = _expressionText(term).toLowerCase();
      final widthValue = _parseLength(
        term,
        property,
        allowPercent: false,
        nonNegative: true,
        allowBorderWidthKeywords: true,
        diagnoseFailure: false,
      );
      if (widthValue != null) {
        if (width != null) {
          _diagnose(
            'invalid-value',
            property,
            text,
            tr("Border width is repeated."),
          );
          return null;
        }
        width = widthValue;
        continue;
      }
      final styleValue = _parseBorderStyle(
        term,
        property,
        diagnoseFailure: false,
      );
      if (styleValue != null) {
        if (style != null) {
          _diagnose(
            'invalid-value',
            property,
            text,
            tr("Border style is repeated."),
          );
          return null;
        }
        style = styleValue.value;
        continue;
      }
      final colorValue = _parseColor(term, property, diagnoseFailure: false);
      if (colorValue != null) {
        if (color != null) {
          _diagnose(
            'invalid-value',
            property,
            text,
            tr("Border color is repeated."),
          );
          return null;
        }
        color = colorValue;
        continue;
      }
      _diagnose(
        'unsupported-value',
        property,
        text,
        tr("This border component is unsupported."),
      );
      return null;
    }

    return _BorderComponents(
      width: width ?? const NativeHtmlControlBoxLength(3, 'px'),
      style: style ?? 'none',
      color: color ?? currentColor,
    );
  }

  _ParsedBorderStyle? _parseBorderStyle(
    css.Expression expression,
    String property, {
    bool diagnoseFailure = true,
  }) {
    final word = _expressionText(expression).toLowerCase();
    if (!_borderStyleWords.contains(word)) {
      if (diagnoseFailure) {
        _diagnose(
          'unsupported-value',
          property,
          word,
          tr("Unknown CSS border style."),
        );
      }
      return null;
    }
    if (const {
      'none',
      'hidden',
      'solid',
      'dashed',
      'dotted',
      'double',
    }.contains(word)) {
      return _ParsedBorderStyle(word);
    }
    _diagnose(
      'unsupported-border-style',
      property,
      word,
      tr(
        "Flutter control borders support solid/none; this style is approximated as solid.",
      ),
    );
    return _ParsedBorderStyle(word);
  }

  List<String>? _parseStyleValues(css.Expression expression, String property) {
    final terms = _terms(expression);
    if (terms.isEmpty || terms.length > 4) {
      _diagnose(
        'unsupported-value',
        property,
        _expressionText(expression),
        tr("Expected one to four border styles."),
      );
      return null;
    }
    final result = <String>[];
    for (final term in terms) {
      final parsed = _parseBorderStyle(term, property);
      if (parsed == null) return null;
      result.add(parsed.value);
    }
    return result;
  }

  List<Color>? _parseColorValues(css.Expression expression, String property) {
    final terms = _terms(expression);
    if (terms.isEmpty || terms.length > 4) {
      _diagnose(
        'unsupported-value',
        property,
        _expressionText(expression),
        tr("Expected one to four colors."),
      );
      return null;
    }
    final result = <Color>[];
    for (final term in terms) {
      final parsed = _parseColor(term, property);
      if (parsed == null) return null;
      result.add(parsed);
    }
    return result;
  }

  Color? _parseColor(
    css.Expression expression,
    String property, {
    bool allowNone = false,
    bool diagnoseFailure = true,
  }) {
    final text = _expressionText(expression);
    final lower = text.toLowerCase();
    if (lower == 'currentcolor') return currentColor;
    if (lower == 'transparent' || (allowNone && lower == 'none')) {
      return const Color(0x00000000);
    }
    final namedColor = _namedCssColors[lower];
    if (namedColor != null) return Color(namedColor);
    if (lower.startsWith('#')) {
      final hex = lower.substring(1);
      if (!const {3, 4, 6, 8}.contains(hex.length)) {
        if (diagnoseFailure) {
          _diagnose(
            'unsupported-color',
            property,
            text,
            tr("Hex colors must contain 3, 4, 6, or 8 digits."),
          );
        }
        return null;
      }
      try {
        switch (hex.length) {
          case 3:
            final rgb = hex.split('').map((digit) => '$digit$digit').join();
            return Color(0xff000000 | int.parse(rgb, radix: 16));
          case 4:
            final rgba = hex.split('').map((digit) => '$digit$digit').join();
            final red = rgba.substring(0, 2);
            final green = rgba.substring(2, 4);
            final blue = rgba.substring(4, 6);
            final alpha = rgba.substring(6, 8);
            return Color(int.parse('$alpha$red$green$blue', radix: 16));
          case 6:
            return Color(0xff000000 | int.parse(hex, radix: 16));
          case 8:
            final red = hex.substring(0, 2);
            final green = hex.substring(2, 4);
            final blue = hex.substring(4, 6);
            final alpha = hex.substring(6, 8);
            return Color(int.parse('$alpha$red$green$blue', radix: 16));
        }
      } on FormatException {
        // Let csslib's parser produce a consistent unsupported-color diagnostic.
      }
    }
    try {
      final parsed = css_parser.Color.css(text);
      final hex = parsed.toHexArgbString();
      final argb = parsed.argbValue;
      return Color(hex.length == 6 ? argb | 0xff000000 : argb);
    } on Object {
      if (diagnoseFailure) {
        _diagnose(
          'unsupported-color',
          property,
          text,
          tr("This CSS color is not supported by the local color parser."),
        );
      }
      return null;
    }
  }

  List<_CornerRadius>? _parseRadii(css.Expression expression, String property) {
    final groups = <List<css.Expression>>[[]];
    for (final term in _terms(expression)) {
      if (term is css.OperatorSlash) {
        if (groups.length == 2) {
          _diagnose(
            'unsupported-value',
            property,
            _expressionText(expression),
            tr("A border-radius value can contain one slash."),
          );
          return null;
        }
        groups.add([]);
      } else {
        groups.last.add(term);
      }
    }
    final horizontal = _parseRadiusList(groups[0], property);
    if (horizontal == null) return null;
    final vertical = groups.length == 1
        ? horizontal
        : _parseRadiusList(groups[1], property);
    if (vertical == null) return null;
    return [
      _CornerRadius(horizontal[0], vertical[0]),
      _CornerRadius(horizontal[1], vertical[1]),
      _CornerRadius(horizontal[2], vertical[2]),
      _CornerRadius(horizontal[3], vertical[3]),
    ];
  }

  _CornerRadius? _parseCornerRadius(
    css.Expression expression,
    String property,
  ) {
    final terms = _terms(expression);
    if (terms.isEmpty || terms.length > 2) {
      _diagnose(
        'unsupported-value',
        property,
        _expressionText(expression),
        tr("Expected one or two radius lengths."),
      );
      return null;
    }
    final horizontal = _parseLength(
      terms.first,
      property,
      allowPercent: true,
      nonNegative: true,
    );
    if (horizontal == null) return null;
    final vertical = terms.length == 1
        ? horizontal
        : _parseLength(
            terms[1],
            property,
            allowPercent: true,
            nonNegative: true,
          );
    if (vertical == null) return null;
    return _CornerRadius(horizontal, vertical);
  }

  List<NativeHtmlControlBoxLength>? _parseRadiusList(
    List<css.Expression> terms,
    String property,
  ) {
    if (terms.isEmpty || terms.length > 4) {
      _diagnose(
        'unsupported-value',
        property,
        '',
        tr("Expected one to four radius lengths."),
      );
      return null;
    }
    final lengths = <NativeHtmlControlBoxLength>[];
    for (final term in terms) {
      final length = _parseLength(
        term,
        property,
        allowPercent: true,
        nonNegative: true,
      );
      if (length == null) return null;
      lengths.add(length);
    }
    return [
      for (var index = 0; index < 4; index++)
        lengths[_fourSideIndex(lengths.length, index)],
    ];
  }

  void _diagnose(String code, String property, String value, String message) {
    diagnostics.add(
      NativeHtmlControlBoxDiagnostic(
        code: code,
        property: property,
        value: value,
        message: message,
      ),
    );
  }
}

class _CascadeBoxValue {
  const _CascadeBoxValue({
    required this.value,
    required this.important,
    required this.order,
  });

  final Object? value;
  final bool important;
  final int order;
}

class _BorderComponents {
  const _BorderComponents({
    required this.width,
    required this.style,
    required this.color,
  });

  final NativeHtmlControlBoxLength width;
  final String style;
  final Color color;
}

class _ParsedBorderStyle {
  const _ParsedBorderStyle(this.value);
  final String value;
}

@immutable
class _CornerRadius {
  const _CornerRadius(this.horizontal, this.vertical);
  final NativeHtmlControlBoxLength horizontal;
  final NativeHtmlControlBoxLength vertical;
}

const _borderSides = <String>['top', 'right', 'bottom', 'left'];
const _borderSideNames = <String, String>{
  'border-top': 'top',
  'border-right': 'right',
  'border-bottom': 'bottom',
  'border-left': 'left',
};
const _borderWidthProperties = <String>{
  'border-top-width',
  'border-right-width',
  'border-bottom-width',
  'border-left-width',
};
const _borderStyleProperties = <String>{
  'border-top-style',
  'border-right-style',
  'border-bottom-style',
  'border-left-style',
};
const _borderColorProperties = <String>{
  'border-top-color',
  'border-right-color',
  'border-bottom-color',
  'border-left-color',
};
const _borderRadiusProperties = <String>{
  'border-top-left-radius',
  'border-top-right-radius',
  'border-bottom-right-radius',
  'border-bottom-left-radius',
};
const _dimensionProperties = <String>{
  'width',
  'height',
  'min-width',
  'max-width',
  'min-height',
  'max-height',
};
const _borderStyleWords = <String>{
  'none',
  'hidden',
  'dotted',
  'dashed',
  'solid',
  'double',
  'groove',
  'ridge',
  'inset',
  'outset',
};
const _cssWideKeywords = <String>{
  'inherit',
  'initial',
  'revert',
  'revert-layer',
  'unset',
};

// csslib's Color.css accepts hex and legacy rgb/hsl functions, but not names.
// Keep the common named colors used by authored control styles explicit; other
// names are diagnosed instead of being mistaken for a different color.
const _namedCssColors = <String, int>{
  'black': 0xff000000,
  'silver': 0xffc0c0c0,
  'gray': 0xff808080,
  'grey': 0xff808080,
  'white': 0xffffffff,
  'maroon': 0xff800000,
  'red': 0xffff0000,
  'purple': 0xff800080,
  'fuchsia': 0xffff00ff,
  'magenta': 0xffff00ff,
  'green': 0xff008000,
  'lime': 0xff00ff00,
  'olive': 0xff808000,
  'yellow': 0xffffff00,
  'navy': 0xff000080,
  'blue': 0xff0000ff,
  'teal': 0xff008080,
  'aqua': 0xff00ffff,
  'cyan': 0xff00ffff,
  'orange': 0xffffa500,
  'rebeccapurple': 0xff663399,
  'tomato': 0xffff6347,
  'coral': 0xffff7f50,
  'gold': 0xffffd700,
  'pink': 0xffffc0cb,
  'brown': 0xffa52a2a,
  'indigo': 0xff4b0082,
  'darkgray': 0xffa9a9a9,
  'darkgrey': 0xffa9a9a9,
  'lightgray': 0xffd3d3d3,
  'lightgrey': 0xffd3d3d3,
};

List<css.Expression> _terms(css.Expression expression) =>
    expression is css.Expressions
    ? expression.expressions
    : <css.Expression>[expression];

css.Expression? _singleTerm(css.Expression expression) {
  if (expression is css.Expressions) {
    return expression.expressions.length == 1
        ? expression.expressions.single
        : null;
  }
  return expression;
}

String _expressionText(css.Expression expression) {
  final printer = css.CssPrinter();
  expression.visit(printer);
  return printer.toString().trim();
}

int _fourSideIndex(int count, int side) => switch ((count, side)) {
  (1, _) => 0,
  (2, 0) => 0,
  (2, 1) => 1,
  (2, 2) => 0,
  (2, 3) => 1,
  (3, 0) => 0,
  (3, 1) => 1,
  (3, 2) => 2,
  (3, 3) => 1,
  (4, _) => side,
  _ => 0,
};
