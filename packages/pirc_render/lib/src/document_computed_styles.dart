import 'dart:collection';

import 'package:html/dom.dart' as dom;

import 'document_pointer_style.dart';
import 'document_transform.dart';

import 'html_background_gradient.dart' show parseNativeCssColor;

const _maxComputedStyleValueCount = 256;
const _maxCustomPropertyCount = 4096;
const _maxCustomPropertyNameLength = 128;
const _maxCustomPropertyValueLength = 4096;
const _maxCustomPropertyCharacters = 16 * 1024;

/// The supported computed-style surface for one scripted document element.
///
/// [values] contains canonical property names whose values this native layer
/// can compute without layout. [lengths] contains geometric longhands whose
/// used values need the containing block or a measured native box. Percentage
/// and calc() expressions stay unresolved in [lengths].
class NativeDocumentComputedStyleSpec {
  NativeDocumentComputedStyleSpec({
    required Map<String, String> values,
    required Map<String, String> lengths,
    required this.fontSize,
    required this.rootFontSize,
    this.transform,
    this.transformOrigin,
    this.available = true,
    this.textContentSelectorsIndependent = false,
    this.isReplaced = false,
    this.resizeSupported = true,
    this.scrollTranslationSupported = false,
    this.canvasBitmapSizeIndependent = false,
    this.canvasEquivalentStyleWrites = false,
    this.clientWidthIndependentOfDescendantSizes = false,
    this.replacedBoxStyleProjection = false,
    this.canvasSizingProjection = false,
    this.canvasIntrinsicSize,
    this.fixedBlockChildId,
  }) : values = Map<String, String>.unmodifiable(values),
       lengths = Map<String, String>.unmodifiable(lengths);

  final Map<String, String> values;
  final Map<String, String> lengths;
  final double fontSize;
  final double rootFontSize;

  /// Winning author values; percentages resolve against the owned native border
  /// box only after layout. Unsupported reference-box variants stay absent.
  final String? transform, transformOrigin;

  /// Atomic image/canvas/SVG roots have used dimensions even when inline.
  final bool isReplaced;

  /// The current native observer supports single-fragment horizontal HTML boxes.
  final bool resizeSupported;

  /// The DOM positioning ancestry has no sticky/unknown position whose layout
  /// may depend on scrolling. Paint ancestry/matrices still need native proof.
  final bool scrollTranslationSupported;

  /// True for fixed-pixel CSS dimensions, or a proved percentage-width block
  /// path, when the document-wide CSS cascade excludes backing-attribute
  /// dependencies.
  final bool canvasBitmapSizeIndependent;

  /// Allows the runtime to consider only equivalent writes to display,
  /// box-sizing, and numeric-pixel width/height. It does not authorize arbitrary
  /// style mutations: those values must still match the native computed style.
  final bool canvasEquivalentStyleWrites;

  /// A fixed-width ordinary block without scrollbar/intrinsic sizing can retain
  /// its measured clientWidth when only strict descendants' dimensions change.
  final bool clientWidthIndependentOfDescendantSizes;

  /// Both used dimensions are fixed independently of bitmap, inline/block
  /// display and box-sizing changes, with no edges or important overrides.
  final bool replacedBoxStyleProjection;

  /// A measured fixed parent and edgeless zero-margin Canvas allow CSS sizes to
  /// be calculated from px/percent/auto and natural bitmap dimensions. The
  /// serializer must verify the original calculation against real native sizes.
  final bool canvasSizingProjection;
  final ({double width, double height})? canvasIntrinsicSize;

  /// Candidate single replaced child; the packet builder verifies its proof
  /// and actual native measurements before attaching this relationship.
  final String? fixedBlockChildId;

  /// False when custom-property data exceeded the helper's memory budget.
  /// Consumers should treat the computed-style declaration as unavailable.
  final bool available;

  /// [values] stay valid after ordinary text-only changes when the native
  /// cascade proves no text-sensitive matching. [lengths] remain layout backed.
  final bool textContentSelectorsIndependent;
}

/// Builds the native computed-style base from the already-applied author
/// cascade. Geometry is deliberately left for the layout-backed serializer.
///
/// The cascade result has one entry per element only when it has declarations;
/// this function walks the full DOM so inherited values also reach unstyled
/// descendants. Only elements with a `data-pirc-script-id` are returned.
Map<String, NativeDocumentComputedStyleSpec> nativeDocumentComputedStyleSpecs({
  required dom.Document document,
  required Map<dom.Element, Map<String, String>> stylesByElement,
  required double viewportWidth,
  required double viewportHeight,
  bool canvasBitmapAttributesIndependent = false,
  bool textContentSelectorsIndependent = false,
  bool inlineBoxStyleOverridesIndependent = false,
  bool dark = false,
}) {
  // `dark` is already reflected in stylesByElement by media-query evaluation.
  // The native document's inherited base text color also follows its theme.
  final root = document.documentElement;
  if (root == null) return const {};

  final byElement =
      HashMap<dom.Element, NativeDocumentComputedStyleSpec>.identity();
  final fontSizeReliableByElement = HashMap<dom.Element, bool>.identity();
  final result = <String, NativeDocumentComputedStyleSpec>{};
  final initialTextColor = dark ? 'rgb(255, 255, 255)' : 'rgb(0, 0, 0)';
  final elements = document.querySelectorAll('*');
  for (final element in elements) {
    final parent = element.parent;
    final parentSpec = parent is dom.Element ? byElement[parent] : null;
    var available = parentSpec?.available ?? true;
    final author = stylesByElement[element] ?? const <String, String>{};
    final isRoot = identical(element, root);
    final name = element.localName?.toLowerCase() ?? '';
    final parentFontSize = parentSpec?.fontSize ?? 16.0;
    final inheritedFontSizeReliable =
        parent is! dom.Element || fontSizeReliableByElement[parent] == true;
    final rootFontSizeReliable = isRoot
        ? true
        : (fontSizeReliableByElement[root] ?? true);
    final rootFontBasis = isRoot ? 16.0 : (parentSpec?.rootFontSize ?? 16.0);
    final direction = _resolveKeyword(
      author['direction'],
      inheritedValue: parentSpec?.values['direction'] ?? 'ltr',
      initialValue: 'ltr',
      inherited: true,
      accepted: const {'ltr', 'rtl'},
    );
    final fontSizeResult = _fontSizeFor(
      element: element,
      authorValue: author['font-size'],
      inheritedFontSize: parentFontSize,
      inheritedFontSizeReliable: inheritedFontSizeReliable,
      rootFontSize: rootFontBasis,
      rootFontSizeReliable: rootFontSizeReliable,
      viewportWidth: viewportWidth,
      viewportHeight: viewportHeight,
    );
    final fontSize = fontSizeResult.value;
    final rootFontSize = isRoot ? fontSize : rootFontBasis;
    final color = _computedColor(
      author['color'],
      parentSpec?.values['color'] ?? initialTextColor,
      initial: initialTextColor,
    );
    final uaFamily = _uaFontFamily(name);
    final fontFamily = _computedFontFamily(
      author['font-family'],
      parentSpec?.values['font-family'] ?? 'serif',
      initial: 'serif',
    );
    final effectiveFontFamily = _effectiveFontFamily(
      authorValue: author['font-family'],
      normalizedAuthorValue: fontFamily,
      uaValue: uaFamily,
      parentValue: parentSpec?.values['font-family'],
    );
    final uaWeight = _uaFontWeight(name);
    final fontWeight = _computedFontWeight(
      author['font-weight'],
      uaValue: uaWeight,
      parentWeight: parentSpec?.values['font-weight'] ?? '400',
    );
    final uaStyle = _uaFontStyle(name);
    final fontStyle = _resolveKeyword(
      author['font-style'],
      inheritedValue: parentSpec?.values['font-style'] ?? 'normal',
      uaValue: uaStyle,
      initialValue: 'normal',
      inherited: true,
      accepted: const {'normal', 'italic', 'oblique'},
    );
    final lineHeight = _lineHeightFor(
      element: element,
      stylesByElement: stylesByElement,
      computedByElement: byElement,
      fontSizeReliableByElement: fontSizeReliableByElement,
      fontSizeReliable: fontSizeResult.supported,
      rootFontSizeReliable: rootFontSizeReliable,
      currentFontSize: fontSize,
      rootFontSize: rootFontSize,
      viewportWidth: viewportWidth,
      viewportHeight: viewportHeight,
    );

    final values = <String, String>{};
    final display = author.containsKey('display')
        ? _resolveKeyword(
            author['display'],
            inheritedValue: parentSpec?.values['display'] ?? 'inline',
            initialValue: 'inline',
            accepted: _displayKeywords,
          )
        : name == 'dialog' && !element.attributes.containsKey('open')
        ? 'none'
        : _uaDisplay(name);
    if (display != null) {
      final parentDisplay = parentSpec?.values['display'];
      values['display'] =
          const {
            'flex',
            'inline-flex',
            'grid',
            'inline-grid',
          }.contains(parentDisplay)
          ? switch (display) {
              'inline' || 'inline-block' => 'block',
              'inline-flex' => 'flex',
              'inline-grid' => 'grid',
              'inline-table' => 'table',
              _ => display,
            }
          : display;
    }

    final position = _resolveKeyword(
      author['position'],
      inheritedValue: parentSpec?.values['position'] ?? 'static',
      initialValue: 'static',
      accepted: const {'static', 'relative', 'absolute', 'fixed', 'sticky'},
    );
    if (position != null) values['position'] = position;
    if (direction != null) values['direction'] = direction;

    final scrollBehavior = _resolveKeyword(
      author['scroll-behavior'],
      inheritedValue: parentSpec?.values['scroll-behavior'] ?? 'auto',
      initialValue: 'auto',
      accepted: const {'auto', 'smooth'},
    );
    // Invalid-at-computed-value-time variables fall back to this property's
    // non-inherited initial value, rather than omitting a known scalar.
    values['scroll-behavior'] = scrollBehavior ?? 'auto';

    final writingMode = _resolveKeyword(
      author['writing-mode'],
      inheritedValue: parentSpec?.values['writing-mode'] ?? 'horizontal-tb',
      initialValue: 'horizontal-tb',
      inherited: true,
      accepted: const {
        'horizontal-tb',
        'vertical-rl',
        'vertical-lr',
        'sideways-rl',
        'sideways-lr',
      },
    );
    if (writingMode != null) values['writing-mode'] = writingMode;

    final visibility = _resolveKeyword(
      author['visibility'],
      inheritedValue: parentSpec?.values['visibility'] ?? 'visible',
      initialValue: 'visible',
      inherited: true,
      accepted: const {'visible', 'hidden', 'collapse'},
    );
    if (visibility != null) values['visibility'] = visibility;
    final pointerEvents = _resolveKeyword(
      author['pointer-events'],
      inheritedValue: parentSpec?.values['pointer-events'] ?? 'auto',
      initialValue: 'auto',
      inherited: true,
      accepted: nativeDocumentPointerKeywords,
    );
    if (pointerEvents != null) values['pointer-events'] = pointerEvents;

    final boxSizing = author.containsKey('box-sizing')
        ? _resolveKeyword(
            author['box-sizing'],
            inheritedValue: parentSpec?.values['box-sizing'] ?? 'content-box',
            initialValue: 'content-box',
            accepted: const {'content-box', 'border-box'},
          )
        : _uaBoxSizing(name) ?? 'content-box';
    if (boxSizing != null) values['box-sizing'] = boxSizing;

    final overflowX = _resolveKeyword(
      author['overflow-x'],
      inheritedValue: parentSpec?.values['overflow-x'] ?? 'visible',
      initialValue: 'visible',
      accepted: _overflowKeywords,
    );
    final overflowY = _resolveKeyword(
      author['overflow-y'],
      inheritedValue: parentSpec?.values['overflow-y'] ?? 'visible',
      initialValue: 'visible',
      accepted: _overflowKeywords,
    );
    if (overflowX != null) values['overflow-x'] = overflowX;
    if (overflowY != null) values['overflow-y'] = overflowY;
    if (overflowX != null && overflowY != null) {
      values['overflow'] = overflowX == overflowY
          ? overflowX
          : '$overflowX $overflowY';
    }

    final backgroundColor = _computedColor(
      author['background-color'],
      parentSpec?.values['background-color'] ?? 'rgba(0, 0, 0, 0)',
      initial: 'rgba(0, 0, 0, 0)',
      currentColor: color ?? initialTextColor,
      inheritedByDefault: false,
    );
    if (color != null) values['color'] = color;
    if (backgroundColor != null &&
        (!_formControls.contains(name) ||
            author.containsKey('background-color'))) {
      values['background-color'] = backgroundColor;
    }
    if (fontSizeResult.supported &&
        (!_formControls.contains(name) || author.containsKey('font-size'))) {
      values['font-size'] = '${_formatNumber(fontSize)}px';
    }
    if (effectiveFontFamily != null &&
        (!_formControls.contains(name) || author.containsKey('font-family'))) {
      values['font-family'] = effectiveFontFamily;
    }
    if (fontWeight != null &&
        (!_formControls.contains(name) || author.containsKey('font-weight'))) {
      values['font-weight'] = fontWeight;
    }
    if (fontStyle != null &&
        (!_formControls.contains(name) || author.containsKey('font-style'))) {
      values['font-style'] = fontStyle;
    }
    if (lineHeight != null &&
        (!_formControls.contains(name) || author.containsKey('line-height'))) {
      values['line-height'] = lineHeight;
    }

    final specifiedFontStretch = _resolveKeyword(
      author['font-stretch'],
      inheritedValue: parentSpec?.values['font-stretch'] ?? '100%',
      initialValue: '100%',
      inherited: true,
      accepted: _fontStretchKeywords,
    );
    final fontStretch = _computedFontStretch(specifiedFontStretch);
    if (fontStretch != null) values['font-stretch'] = fontStretch;
    final fontVariant = _resolveKeyword(
      author['font-variant'],
      inheritedValue: parentSpec?.values['font-variant'] ?? 'normal',
      initialValue: 'normal',
      inherited: true,
      accepted: _fontVariantKeywords,
    );
    if (fontVariant != null) values['font-variant'] = fontVariant;

    final letterSpacing = _computedSpacing(
      author['letter-spacing'],
      inheritedValue: parentSpec?.values['letter-spacing'] ?? 'normal',
      initialValue: 'normal',
      fontSize: fontSize,
      rootFontSize: rootFontSize,
      viewportWidth: viewportWidth,
      viewportHeight: viewportHeight,
      allowNormal: true,
      normalValue: 'normal',
    );
    if (letterSpacing != null) values['letter-spacing'] = letterSpacing;
    final wordSpacing = _computedSpacing(
      author['word-spacing'],
      inheritedValue: parentSpec?.values['word-spacing'] ?? '0px',
      initialValue: '0px',
      fontSize: fontSize,
      rootFontSize: rootFontSize,
      viewportWidth: viewportWidth,
      viewportHeight: viewportHeight,
      allowNormal: true,
      normalValue: '0px',
    );
    if (wordSpacing != null) values['word-spacing'] = wordSpacing;

    final whiteSpace = author.containsKey('white-space')
        ? _resolveKeyword(
            author['white-space'],
            inheritedValue: parentSpec?.values['white-space'] ?? 'normal',
            initialValue: 'normal',
            inherited: true,
            accepted: _whiteSpaceKeywords,
          )
        : _uaWhiteSpace(name) ?? parentSpec?.values['white-space'] ?? 'normal';
    if (whiteSpace != null) values['white-space'] = whiteSpace;
    final listStyle = _resolveKeyword(
      author['list-style-type'],
      inheritedValue: parentSpec?.values['list-style-type'] ?? 'disc',
      uaValue: name == 'ol' ? 'decimal' : null,
      initialValue: 'disc',
      inherited: true,
      accepted: _listStyleKeywords,
    );
    if (listStyle != null) values['list-style-type'] = listStyle;
    final textTransform = _resolveKeyword(
      author['text-transform'],
      inheritedValue: parentSpec?.values['text-transform'] ?? 'none',
      initialValue: 'none',
      inherited: true,
      accepted: const {
        'none',
        'capitalize',
        'uppercase',
        'lowercase',
        'full-width',
        'full-size-kana',
      },
    );
    if (textTransform != null) values['text-transform'] = textTransform;

    final opacity = _computedOpacity(
      author['opacity'],
      inheritedValue: parentSpec?.values['opacity'] ?? '1',
    );
    if (opacity != null) values['opacity'] = opacity;

    for (final side in _sides) {
      final borderStyle = _resolveKeyword(
        author['border-$side-style'],
        inheritedValue: parentSpec?.values['border-$side-style'] ?? 'none',
        initialValue: _uaBorderStyle(name) ?? 'none',
        accepted: _borderStyleKeywords,
      );
      if (borderStyle != null && _supportsUaBorders(name, author)) {
        values['border-$side-style'] = borderStyle;
      }
      final borderColor = _computedColor(
        author['border-$side-color'],
        parentSpec?.values['border-$side-color'] ?? color ?? 'rgb(0, 0, 0)',
        initial: color ?? 'rgb(0, 0, 0)',
        currentColor: color ?? initialTextColor,
        inheritedByDefault: false,
      );
      if (borderColor != null && _supportsUaBorders(name, author)) {
        values['border-$side-color'] = borderColor;
      }
    }

    final customValues = <String, String>{};
    var customCharacters = 0;
    bool addCustomValue(String name, String value) {
      final previousValue = customValues[name];
      final nextCount = customValues.length + (previousValue == null ? 1 : 0);
      final previousCharacters = previousValue == null
          ? 0
          : name.length + previousValue.length;
      final nextCharacters =
          customCharacters - previousCharacters + name.length + value.length;
      if (name.length > _maxCustomPropertyNameLength ||
          value.length > _maxCustomPropertyValueLength ||
          nextCount > _maxCustomPropertyCount ||
          values.length + nextCount > _maxComputedStyleValueCount ||
          nextCharacters > _maxCustomPropertyCharacters) {
        return false;
      }
      customValues[name] = value;
      customCharacters = nextCharacters;
      return true;
    }

    if (available && parentSpec != null) {
      for (final entry in parentSpec.values.entries) {
        if (!entry.key.startsWith('--')) continue;
        if (!addCustomValue(entry.key, entry.value)) {
          available = false;
          break;
        }
      }
    }
    if (available) {
      for (final entry in author.entries) {
        if (!entry.key.startsWith('--')) continue;
        final value = entry.value.trim();
        if (value.isEmpty || _cssWideKeywords.contains(value.toLowerCase())) {
          continue;
        }
        if (value.toLowerCase().contains('var(')) continue;
        if (!addCustomValue(entry.key, value)) {
          available = false;
          break;
        }
      }
    }
    if (available) {
      values.addAll(customValues);
    } else {
      values.removeWhere((name, _) => name.startsWith('--'));
    }

    final lengths = _lengthsFor(
      author: author,
      fontSize: fontSize,
      fontSizeReliable: fontSizeResult.supported,
      rootFontSize: rootFontSize,
      rootFontSizeReliable: isRoot
          ? fontSizeResult.supported
          : rootFontSizeReliable,
      viewportWidth: viewportWidth,
      viewportHeight: viewportHeight,
      direction: direction ?? 'ltr',
      parentSpec: parentSpec,
      borderStyles: {
        for (final side in _sides) side: values['border-$side-style'] ?? 'none',
      },
      tagName: name,
    );
    final resizeSupported =
        (parentSpec?.resizeSupported ?? true) &&
        element.namespaceUri == 'http://www.w3.org/1999/xhtml' &&
        const {
          '',
          'horizontal-tb',
          'inherit',
          'initial',
          'unset',
        }.contains((author['writing-mode'] ?? '').trim().toLowerCase());
    final isHtmlCanvas =
        name == 'canvas' &&
        element.namespaceUri == 'http://www.w3.org/1999/xhtml';
    final authoredWidth = author['width'];
    final authoredHeight = author['height'];
    final hasFixedPixelCanvasSize =
        _isNonNegativePixelLength(authoredWidth) &&
        _isNonNegativePixelLength(authoredHeight);
    final hasPercentWidthPixelHeight =
        _isNonNegativePercentage(authoredWidth) &&
        _isNonNegativePixelLength(authoredHeight);
    final simpleCanvasPath =
        isHtmlCanvas &&
        available &&
        resizeSupported &&
        _hasOrdinaryBlockCanvasSizingPath(
          canvas: element,
          canvasAuthor: author,
          canvasDisplay: values['display'],
          canvasPosition: values['position'],
          computedStylesByElement: byElement,
          stylesByElement: stylesByElement,
        );
    final ordinaryBlockCanvasPath =
        simpleCanvasPath &&
        (hasFixedPixelCanvasSize || hasPercentWidthPixelHeight);
    double bitmapDimension(String name, int fallback) {
      final raw = element.attributes[name];
      if (raw == null ||
          !RegExp(r'^[\t\n\f\r ]*\d+[\t\n\f\r ]*$').hasMatch(raw)) {
        return fallback.toDouble();
      }
      return (double.tryParse(raw.trim()) ?? fallback.toDouble())
          .clamp(0, 0xffffffff)
          .toDouble();
    }

    final transform = author['transform'] ?? 'none';
    if (transform == 'none') values['transform'] = 'none';
    final transformBoxSupported =
        fontSizeResult.supported &&
        element.namespaceUri == 'http://www.w3.org/1999/xhtml' &&
        const {
          '',
          'view-box',
          'border-box',
        }.contains(author['transform-box'] ?? '');
    final spec = NativeDocumentComputedStyleSpec(
      transform: transformBoxSupported ? transform : null,
      transformOrigin: transformBoxSupported
          ? (author['transform-origin'] ?? '50% 50%')
          : null,
      values: values,
      lengths: lengths,
      fontSize: fontSize,
      rootFontSize: rootFontSize,
      available: available,
      textContentSelectorsIndependent: textContentSelectorsIndependent,
      isReplaced: const {'img', 'canvas', 'svg'}.contains(name),
      resizeSupported: resizeSupported,
      scrollTranslationSupported:
          (parentSpec?.scrollTranslationSupported ?? true) &&
          const {
            'static',
            'relative',
            'absolute',
            'fixed',
          }.contains(position) &&
          (const {'none', ''}.contains(author['transform'] ?? '') ||
              NativeDocumentTransformSpec.parse(
                    author['transform'],
                    origin: author['transform-origin'],
                  ) !=
                  null) &&
          const [
            'translate',
            'rotate',
            'scale',
            'perspective',
          ].every((name) => const {'none', ''}.contains(author[name] ?? '')),
      canvasBitmapSizeIndependent:
          canvasBitmapAttributesIndependent &&
          isHtmlCanvas &&
          (hasFixedPixelCanvasSize ||
              (hasPercentWidthPixelHeight && ordinaryBlockCanvasPath)),
      canvasEquivalentStyleWrites:
          canvasBitmapAttributesIndependent && ordinaryBlockCanvasPath,
      canvasIntrinsicSize: isHtmlCanvas
          ? (
              width: bitmapDimension('width', 300),
              height: bitmapDimension('height', 150),
            )
          : null,
      canvasSizingProjection:
          canvasBitmapAttributesIndependent &&
          inlineBoxStyleOverridesIndependent &&
          simpleCanvasPath &&
          _hasStableOverflowAncestors(element, byElement) &&
          _hasViewportIndependentCanvasParent(
            element,
            byElement,
            stylesByElement,
          ) &&
          const [
            'padding-left',
            'padding-right',
            'padding-top',
            'padding-bottom',
            'border-left-width',
            'border-right-width',
            'border-top-width',
            'border-bottom-width',
            'margin-left',
            'margin-right',
            'margin-top',
            'margin-bottom',
          ].every((name) => lengths[name] == '0px'),
      replacedBoxStyleProjection:
          canvasBitmapAttributesIndependent &&
          inlineBoxStyleOverridesIndependent &&
          available &&
          resizeSupported &&
          isHtmlCanvas &&
          ordinaryBlockCanvasPath &&
          _hasStableOverflowAncestors(element, byElement) &&
          (hasFixedPixelCanvasSize || hasPercentWidthPixelHeight) &&
          const [
            'padding-left',
            'padding-right',
            'padding-top',
            'padding-bottom',
            'border-left-width',
            'border-right-width',
            'border-top-width',
            'border-bottom-width',
          ].every((name) => lengths[name] == '0px'),
      fixedBlockChildId:
          canvasBitmapAttributesIndependent &&
              available &&
              resizeSupported &&
              values['display'] == 'block' &&
              _isNormalFlowPosition(values['position']) &&
              _isNonNegativePixelLength(author['width']) &&
              _isNonNegativePixelLength(author['height']) &&
              _hasNonFloatingCanvasAuthor(author) &&
              !_hasUnsupportedCanvasSizingDeclarations(author) &&
              _hasOrdinaryBlockAncestors(element, byElement, stylesByElement) &&
              element.children.length == 1 &&
              element.nodes.every(
                (node) => node is! dom.Text || node.text.trim().isEmpty,
              )
          ? element.children.single.attributes['data-pirc-script-id']
          : null,
      clientWidthIndependentOfDescendantSizes:
          canvasBitmapAttributesIndependent &&
          available &&
          resizeSupported &&
          element.namespaceUri == 'http://www.w3.org/1999/xhtml' &&
          !_canvasSpecialLayoutAncestors.contains(name) &&
          !const {
            'html',
            'body',
            'progress',
            'meter',
            'marquee',
          }.contains(name) &&
          values['display'] == 'block' &&
          _isNormalFlowPosition(values['position']) &&
          _isNonNegativePixelLength(author['width']) &&
          _hasNonFloatingCanvasAuthor(author) &&
          !_hasUnsupportedCanvasSizingDeclarations(author) &&
          _hasSimplePreferredCanvasSizes(author) &&
          const {'visible', 'hidden', 'clip'}.contains(values['overflow-x']) &&
          values['overflow-x'] == values['overflow-y'] &&
          const [
            'padding-left',
            'padding-right',
            'border-left-width',
            'border-right-width',
          ].every((property) => _isNonNegativePixelLength(lengths[property])) &&
          _hasOrdinaryBlockAncestors(element, byElement, stylesByElement),
    );
    byElement[element] = spec;
    fontSizeReliableByElement[element] = fontSizeResult.supported;
    final id = element.attributes['data-pirc-script-id'];
    if (id != null) result[id] = spec;
  }
  return Map<String, NativeDocumentComputedStyleSpec>.unmodifiable(result);
}

bool _isNonNegativePixelLength(String? source) {
  if (source == null) return false;
  final value = source.trim().toLowerCase();
  if (!RegExp(r'^(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)px$').hasMatch(value)) {
    return false;
  }
  final number = double.tryParse(value.substring(0, value.length - 2));
  return number != null && number.isFinite && number >= 0;
}

bool _hasStableOverflowAncestors(
  dom.Element element,
  Map<dom.Element, NativeDocumentComputedStyleSpec> computed,
) {
  var ancestor = element.parent;
  while (ancestor is dom.Element) {
    final values = computed[ancestor]?.values;
    if (values == null ||
        !const {'visible', 'hidden', 'clip'}.contains(values['overflow-x']) ||
        values['overflow-x'] != values['overflow-y']) {
      return false;
    }
    ancestor = ancestor.parent;
  }
  return true;
}

// A visible overflow change can introduce a classic root scrollbar. Only a
// first-flow, left-anchored path with fixed edges keeps the parent's position
// and percentage content-box bases independent of that viewport-width change.
bool _hasViewportIndependentCanvasParent(
  dom.Element canvas,
  Map<dom.Element, NativeDocumentComputedStyleSpec> computed,
  Map<dom.Element, Map<String, String>> styles,
) {
  var current = canvas.parent;
  while (current is dom.Element) {
    final spec = computed[current];
    final author = styles[current] ?? const <String, String>{};
    if (spec == null ||
        spec.values['direction'] != 'ltr' ||
        const [
          'transform',
          'translate',
          'rotate',
          'scale',
          'perspective',
        ].any((key) => author[key] != null && author[key] != 'none')) {
      return false;
    }
    for (final side in _sides) {
      if (!_isNonNegativePixelLength(spec.lengths['padding-$side']) ||
          !_isNonNegativePixelLength(spec.lengths['border-$side-width']) ||
          !_isNonNegativePixelLength(spec.lengths['margin-$side'])) {
        return false;
      }
      final offset = author[side]?.trim().toLowerCase() ?? 'auto';
      if (offset != 'auto' &&
          !_isNonNegativePixelLength(offset) &&
          offset != '0') {
        return false;
      }
    }
    final parent = current.parent;
    if (parent is dom.Element) {
      for (final sibling in parent.nodes) {
        if (identical(sibling, current)) break;
        if (sibling is dom.Text && sibling.text.trim().isNotEmpty) return false;
        if (sibling is dom.Element &&
            !const {
              'head',
              'style',
              'script',
              'template',
            }.contains(sibling.localName) &&
            computed[sibling]?.values['display'] != 'none') {
          return false;
        }
      }
    }
    current = parent;
  }
  return true;
}

bool _hasOrdinaryBlockAncestors(
  dom.Element element,
  Map<dom.Element, NativeDocumentComputedStyleSpec> computed,
  Map<dom.Element, Map<String, String>> styles,
) {
  var ancestor = element.parent;
  while (ancestor is dom.Element) {
    final spec = computed[ancestor];
    final author = styles[ancestor] ?? const <String, String>{};
    if (_canvasSpecialLayoutAncestors.contains(ancestor.localName) ||
        const {'progress', 'meter', 'marquee'}.contains(ancestor.localName) ||
        ancestor.namespaceUri != 'http://www.w3.org/1999/xhtml' ||
        spec == null ||
        !spec.available ||
        !spec.resizeSupported ||
        spec.values['display'] != 'block' ||
        !_isNormalFlowPosition(spec.values['position']) ||
        !_hasNonFloatingCanvasAuthor(author) ||
        _hasUnsupportedCanvasSizingDeclarations(author) ||
        !_hasSimplePreferredCanvasSizes(author)) {
      return false;
    }
    ancestor = ancestor.parent;
  }
  return true;
}

bool _isNonNegativePercentage(String? source) {
  if (source == null) return false;
  final value = source.trim().toLowerCase();
  if (!RegExp(r'^(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)%$').hasMatch(value)) {
    return false;
  }
  final number = double.tryParse(value.substring(0, value.length - 1));
  return number != null && number.isFinite && number >= 0;
}

const _canvasUnsupportedSizingProperties = {
  'min-width',
  'max-width',
  'min-height',
  'max-height',
  'inline-size',
  'block-size',
  'min-inline-size',
  'max-inline-size',
  'min-block-size',
  'max-block-size',
  'aspect-ratio',
  'contain',
  'contain-intrinsic-size',
  'contain-intrinsic-width',
  'contain-intrinsic-height',
  'contain-intrinsic-inline-size',
  'contain-intrinsic-block-size',
  'content-visibility',
  'columns',
  'column-count',
  'column-width',
  'column-span',
};

// UA fieldset minimum sizing and native form/table/replaced widgets can have
// intrinsic sizing even when an authored display value says ordinary block.
const _canvasSpecialLayoutAncestors = {
  'fieldset',
  'legend',
  'table',
  'caption',
  'thead',
  'tbody',
  'tfoot',
  'tr',
  'td',
  'th',
  'col',
  'colgroup',
  'button',
  'input',
  'textarea',
  'select',
  'optgroup',
  'option',
  'img',
  'video',
  'audio',
  'iframe',
  'object',
  'embed',
  'canvas',
  'dialog',
};

bool _hasOrdinaryBlockCanvasSizingPath({
  required dom.Element canvas,
  required Map<String, String> canvasAuthor,
  required String? canvasDisplay,
  required String? canvasPosition,
  required Map<dom.Element, NativeDocumentComputedStyleSpec>
  computedStylesByElement,
  required Map<dom.Element, Map<String, String>> stylesByElement,
}) {
  if (!const {'inline', 'block'}.contains(canvasDisplay) ||
      !_isNormalFlowPosition(canvasPosition) ||
      _hasUnsupportedCanvasSizingDeclarations(canvasAuthor) ||
      !_hasNonFloatingCanvasAuthor(canvasAuthor) ||
      !_hasSimplePreferredCanvasSizes(canvasAuthor)) {
    return false;
  }

  final parentNode = canvas.parent;
  if (parentNode is! dom.Element) return false;
  final directParentAuthor =
      stylesByElement[parentNode] ?? const <String, String>{};
  if (!_isNonNegativePixelLength(directParentAuthor['width'])) return false;

  var ancestor = parentNode;
  var isDirectParent = true;
  while (true) {
    final ancestorSpec = computedStylesByElement[ancestor];
    final ancestorAuthor =
        stylesByElement[ancestor] ?? const <String, String>{};
    if (_canvasSpecialLayoutAncestors.contains(ancestor.localName) ||
        ancestor.namespaceUri != 'http://www.w3.org/1999/xhtml' ||
        ancestorSpec == null ||
        !ancestorSpec.available ||
        !ancestorSpec.resizeSupported ||
        ancestorSpec.values['display'] != 'block' ||
        !_isNormalFlowPosition(ancestorSpec.values['position']) ||
        _hasUnsupportedCanvasSizingDeclarations(ancestorAuthor) ||
        !_hasNonFloatingCanvasAuthor(ancestorAuthor) ||
        !_hasSimplePreferredCanvasSizes(ancestorAuthor)) {
      return false;
    }
    if (isDirectParent &&
        (ancestor.namespaceUri != 'http://www.w3.org/1999/xhtml' ||
            !_isNonNegativePixelLength(ancestorAuthor['width']))) {
      return false;
    }

    isDirectParent = false;
    final parent = ancestor.parent;
    if (parent is! dom.Element) break;
    ancestor = parent;
  }
  return true;
}

bool _isNormalFlowPosition(String? value) =>
    value == 'static' || value == 'relative';

bool _hasNonFloatingCanvasAuthor(Map<String, String> author) {
  final float = author['float']?.trim().toLowerCase();
  return float == null || float == 'none';
}

bool _hasUnsupportedCanvasSizingDeclarations(Map<String, String> author) =>
    _canvasUnsupportedSizingProperties.any(author.containsKey);

bool _hasSimplePreferredCanvasSizes(Map<String, String> author) {
  for (final property in const {'width', 'height'}) {
    final value = author[property]?.trim().toLowerCase();
    if (value == null || value == 'auto' || value == '0') continue;
    if (!_isNonNegativePixelLength(value) && !_isNonNegativePercentage(value)) {
      return false;
    }
  }
  return true;
}

/// Resolves common CSS lengths without guessing at unsupported expressions.
/// Percentages need a known [percentageBasis]; calc(), named sizes and units
/// outside px/em/rem/vw/vh intentionally return null.
double? nativeComputedCssLength(
  String cssLength, {
  required double fontSize,
  required double rootFontSize,
  required double viewportWidth,
  required double viewportHeight,
  double? percentageBasis,
}) {
  final match = RegExp(
    r'^([+-]?(?:\d+(?:\.\d*)?|\.\d+)(?:e[+-]?\d+)?)(px|em|rem|%|vw|vh)?$',
    caseSensitive: false,
  ).firstMatch(cssLength.trim());
  if (match == null) return null;
  final amount = double.tryParse(match.group(1)!);
  if (amount == null || !amount.isFinite) return null;
  final unit = match.group(2)?.toLowerCase();
  if (unit == null) return amount == 0 ? 0 : null;
  final value = switch (unit) {
    'px' => amount,
    'em' => amount * fontSize,
    'rem' => amount * rootFontSize,
    '%' => percentageBasis == null ? null : amount * percentageBasis / 100,
    'vw' => amount * viewportWidth / 100,
    'vh' => amount * viewportHeight / 100,
    _ => null,
  };
  return value != null && value.isFinite ? value : null;
}

const _sides = ['top', 'right', 'bottom', 'left'];
const _overflowKeywords = {'visible', 'hidden', 'clip', 'scroll', 'auto'};
const _displayKeywords = {
  'none',
  'contents',
  'block',
  'flow-root',
  'inline',
  'inline-block',
  'inline-flex',
  'flex',
  'inline-grid',
  'grid',
  'list-item',
  'table',
  'inline-table',
  'table-row-group',
  'table-header-group',
  'table-footer-group',
  'table-row',
  'table-cell',
  'table-column-group',
  'table-column',
  'table-caption',
  'ruby',
  'ruby-base',
  'ruby-text',
};
const _borderStyleKeywords = {
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
const _fontStretchKeywords = {
  'ultra-condensed',
  'extra-condensed',
  'condensed',
  'semi-condensed',
  'normal',
  'semi-expanded',
  'expanded',
  'extra-expanded',
  'ultra-expanded',
  '50%',
  '62.5%',
  '75%',
  '87.5%',
  '100%',
  '112.5%',
  '125%',
  '150%',
  '200%',
};
const _fontVariantKeywords = {
  'normal',
  'none',
  'small-caps',
  'all-small-caps',
  'petite-caps',
  'all-petite-caps',
  'unicase',
  'titling-caps',
};
const _whiteSpaceKeywords = {
  'normal',
  'nowrap',
  'pre',
  'pre-wrap',
  'pre-line',
  'break-spaces',
};
const _listStyleKeywords = {
  'none',
  'disc',
  'circle',
  'square',
  'decimal',
  'decimal-leading-zero',
  'lower-roman',
  'upper-roman',
  'lower-greek',
  'lower-latin',
  'upper-latin',
  'lower-alpha',
  'upper-alpha',
  'arabic-indic',
  'armenian',
  'bengali',
  'cambodian',
  'cjk-decimal',
  'cjk-earthly-branch',
  'cjk-heavenly-stem',
  'cjk-ideographic',
  'devanagari',
  'georgian',
  'gujarati',
  'gurmukhi',
  'hebrew',
  'hiragana',
  'hiragana-iroha',
  'japanese-formal',
  'japanese-informal',
  'kannada',
  'katakana',
  'katakana-iroha',
  'khmer',
  'korean-hangul-formal',
  'korean-hanja-formal',
  'lao',
  'malayalam',
  'mongolian',
  'myanmar',
  'oriya',
  'persian',
  'simp-chinese-formal',
  'simp-chinese-informal',
  'tamil',
  'telugu',
  'thai',
  'tibetan',
  'trad-chinese-formal',
  'trad-chinese-informal',
  'urdu',
};
const _cssWideKeywords = {
  'inherit',
  'initial',
  'unset',
  'revert',
  'revert-layer',
};
const _fontSizeKeywords = <String, double>{
  'xx-small': 9,
  'x-small': 10,
  'small': 13.3333333333,
  'medium': 16,
  'large': 18,
  'x-large': 24,
  'xx-large': 32,
  'xxx-large': 48,
};
const _htmlBlockElements = {
  'address',
  'article',
  'aside',
  'blockquote',
  'body',
  'dd',
  'details',
  'dialog',
  'div',
  'dl',
  'dt',
  'fieldset',
  'figcaption',
  'figure',
  'footer',
  'form',
  'h1',
  'h2',
  'h3',
  'h4',
  'h5',
  'h6',
  'header',
  'hgroup',
  'hr',
  'html',
  'main',
  'menu',
  'nav',
  'p',
  'pre',
  'search',
  'section',
  'summary',
  'ul',
};
const _htmlHiddenElements = {
  'head',
  'link',
  'meta',
  'script',
  'style',
  'template',
  'title',
};
const _htmlInlineBlockElements = {'button', 'input', 'select', 'textarea'};
const _htmlMonospaceElements = {'code', 'kbd', 'pre', 'samp', 'tt'};
const _formControls = {'button', 'input', 'select', 'textarea'};

String _uaDisplay(String tag) {
  if (_htmlHiddenElements.contains(tag)) return 'none';
  if (tag == 'li' || tag == 'summary') return 'list-item';
  if (tag == 'table') return 'table';
  if (tag == 'caption') return 'table-caption';
  if (tag == 'colgroup') return 'table-column-group';
  if (tag == 'col') return 'table-column';
  if (tag == 'thead') return 'table-header-group';
  if (tag == 'tbody') return 'table-row-group';
  if (tag == 'tfoot') return 'table-footer-group';
  if (tag == 'tr') return 'table-row';
  if (tag == 'td' || tag == 'th') return 'table-cell';
  if (_htmlBlockElements.contains(tag)) return 'block';
  if (_htmlInlineBlockElements.contains(tag)) return 'inline-block';
  return 'inline';
}

String? _uaFontFamily(String tag) =>
    _htmlMonospaceElements.contains(tag) ? 'monospace' : null;

String? _uaFontWeight(String tag) =>
    const {'b', 'strong', 'th'}.contains(tag) ||
        const {'h1', 'h2', 'h3', 'h4', 'h5', 'h6'}.contains(tag)
    ? '700'
    : null;

String? _uaFontStyle(String tag) =>
    const {'i', 'em', 'cite', 'dfn', 'var'}.contains(tag) ? 'italic' : null;

String? _uaBoxSizing(String tag) =>
    _formControls.contains(tag) ? 'border-box' : 'content-box';

String? _uaBorderStyle(String tag) =>
    _formControls.contains(tag) ? null : 'none';

bool _supportsUaBorders(String tag, Map<String, String> author) =>
    !_formControls.contains(tag) ||
    _sides.any(
      (side) =>
          author.containsKey('border-$side-style') ||
          author.containsKey('border-$side-color') ||
          author.containsKey('border-$side-width'),
    );

String? _computedFontStretch(String? value) {
  if (value == null) return null;
  return const {
        'ultra-condensed': '50%',
        'extra-condensed': '62.5%',
        'condensed': '75%',
        'semi-condensed': '87.5%',
        'normal': '100%',
        'semi-expanded': '112.5%',
        'expanded': '125%',
        'extra-expanded': '150%',
        'ultra-expanded': '200%',
      }[value] ??
      value;
}

class _FontSizeResult {
  const _FontSizeResult(this.value, this.supported);
  final double value;
  final bool supported;
}

_FontSizeResult _fontSizeFor({
  required dom.Element element,
  required String? authorValue,
  required double inheritedFontSize,
  required bool inheritedFontSizeReliable,
  required double rootFontSize,
  required bool rootFontSizeReliable,
  required double viewportWidth,
  required double viewportHeight,
}) {
  final tag = element.localName?.toLowerCase() ?? '';
  final initial = _uaFontSize(tag, inheritedFontSize);
  final raw = authorValue?.trim().toLowerCase();
  if (raw == null || raw.isEmpty) {
    return _FontSizeResult(
      initial,
      inheritedFontSizeReliable && !_formControls.contains(tag),
    );
  }
  if (_cssWideKeywords.contains(raw)) {
    if (raw == 'revert' || raw == 'revert-layer') {
      return _FontSizeResult(inheritedFontSize, false);
    }
    if (raw == 'initial') return const _FontSizeResult(16, true);
    if (raw == 'inherit' || raw == 'unset') {
      return _FontSizeResult(inheritedFontSize, inheritedFontSizeReliable);
    }
  }
  final keyword = _fontSizeKeywords[raw];
  if (keyword != null) return _FontSizeResult(keyword, true);
  if (raw == 'larger' || raw == 'smaller') {
    return _FontSizeResult(inheritedFontSize, false);
  }
  final resolved = nativeComputedCssLength(
    raw,
    fontSize: inheritedFontSize,
    rootFontSize: rootFontSize,
    viewportWidth: viewportWidth,
    viewportHeight: viewportHeight,
    percentageBasis: inheritedFontSize,
  );
  if (resolved == null || resolved < 0) {
    return _FontSizeResult(inheritedFontSize, false);
  }
  final unit = RegExp(r'(px|em|rem|%|vw|vh)$').firstMatch(raw)?.group(1);
  final dependsOnInherited = unit == 'em' || unit == '%';
  final dependsOnRoot = raw.endsWith('rem');
  return _FontSizeResult(
    resolved,
    (!dependsOnInherited || inheritedFontSizeReliable) &&
        (!dependsOnRoot || rootFontSizeReliable),
  );
}

double _uaFontSize(String tag, double inherited) {
  final factor = switch (tag) {
    'h1' => 2.0,
    'h2' => 1.5,
    'h3' => 1.17,
    'h5' => 0.83,
    'h6' => 0.67,
    'small' => 0.8333333333,
    'big' => 1.2,
    _ => 1.0,
  };
  return inherited * factor;
}

String? _resolveKeyword(
  String? authored, {
  String? inheritedValue,
  String? uaValue,
  required String initialValue,
  bool inherited = false,
  required Set<String> accepted,
}) {
  final raw = authored?.trim().toLowerCase();
  if (raw == null || raw.isEmpty) {
    return uaValue ??
        (inherited ? (inheritedValue ?? initialValue) : initialValue);
  }
  if (raw == 'inherit' || (raw == 'unset' && inherited)) {
    return inheritedValue ?? initialValue;
  }
  if (raw == 'initial' || raw == 'unset') return initialValue;
  if (raw == 'revert' || raw == 'revert-layer') return null;
  if (!accepted.contains(raw)) return null;
  return raw;
}

String? _computedColor(
  String? authored,
  String inherited, {
  required String initial,
  String? currentColor,
  bool inheritedByDefault = true,
}) {
  final raw = authored?.trim();
  if (raw == null || raw.isEmpty) {
    return inheritedByDefault ? inherited : initial;
  }
  final keyword = raw.toLowerCase();
  if (keyword == 'inherit' || (keyword == 'unset' && inheritedByDefault)) {
    return inherited;
  }
  if (keyword == 'initial') return initial;
  if (keyword == 'unset') return initial;
  if (keyword == 'revert' || keyword == 'revert-layer') return null;
  if (keyword == 'currentcolor') return currentColor ?? inherited;
  return _normalizeColor(raw);
}

String? _normalizeColor(String raw) {
  final color = parseNativeCssColor(raw);
  if (color == null) return null;
  final functional = _functionalColor(raw);
  if (functional != null) return functional;
  final argb = color.toARGB32();
  final alpha = (argb >> 24) & 0xff;
  final red = (argb >> 16) & 0xff;
  final green = (argb >> 8) & 0xff;
  final blue = argb & 0xff;
  if (alpha == 255) return 'rgb($red, $green, $blue)';
  return 'rgba($red, $green, $blue, ${_formatNumber(alpha / 255)})';
}

String? _functionalColor(String raw) {
  final match = RegExp(
    r'^(rgb|rgba)\((.*)\)$',
    caseSensitive: false,
  ).firstMatch(raw.trim());
  if (match == null) return null;
  var body = match.group(2)!.trim();
  final slash = body.split('/');
  if (slash.length > 2) return null;
  final channels = slash.first.contains(',')
      ? slash.first.split(',').map((part) => part.trim()).toList()
      : slash.first.trim().split(RegExp(r'\s+'));
  String? alpha;
  if (slash.length == 2) alpha = slash.last.trim();
  if (channels.length == 4 && alpha == null) alpha = channels.removeLast();
  if (channels.length != 3) return null;
  final rgb = <int>[];
  for (final channel in channels) {
    final parsed = _rgbChannel(channel);
    if (parsed == null) return null;
    rgb.add(parsed);
  }
  if (alpha == null) return 'rgb(${rgb[0]}, ${rgb[1]}, ${rgb[2]})';
  final alphaValue = _alphaChannel(alpha);
  if (alphaValue == null) return null;
  return 'rgba(${rgb[0]}, ${rgb[1]}, ${rgb[2]}, ${_formatNumber(alphaValue)})';
}

int? _rgbChannel(String raw) {
  final text = raw.trim();
  final percent = text.endsWith('%');
  final number = double.tryParse(
    percent ? text.substring(0, text.length - 1) : text,
  );
  if (number == null || !number.isFinite) return null;
  final channel = (percent ? number * 2.55 : number).clamp(0, 255);
  return channel.round();
}

double? _alphaChannel(String raw) {
  final text = raw.trim();
  final percent = text.endsWith('%');
  final number = double.tryParse(
    percent ? text.substring(0, text.length - 1) : text,
  );
  if (number == null || !number.isFinite) return null;
  return (percent ? number / 100 : number).clamp(0, 1);
}

String? _computedFontFamily(
  String? authored,
  String inherited, {
  required String initial,
}) {
  final raw = authored?.trim();
  if (raw == null || raw.isEmpty) return inherited;
  final keyword = raw.toLowerCase();
  if (keyword == 'inherit' || keyword == 'unset') return inherited;
  if (keyword == 'initial') return initial;
  if (keyword == 'revert' || keyword == 'revert-layer') return null;
  if (raw.toLowerCase().contains('var(')) return null;
  return raw.replaceAll(RegExp(r'\s*,\s*'), ', ');
}

String? _effectiveFontFamily({
  required String? authorValue,
  required String? normalizedAuthorValue,
  required String? uaValue,
  required String? parentValue,
}) {
  if (authorValue == null) return uaValue ?? parentValue ?? 'serif';
  final keyword = authorValue.trim().toLowerCase();
  if (keyword == 'inherit' || keyword == 'unset') return parentValue;
  if (keyword == 'initial') return 'serif';
  if (keyword == 'revert' || keyword == 'revert-layer') return null;
  return normalizedAuthorValue;
}

String? _computedFontWeight(
  String? authored, {
  required String? uaValue,
  required String parentWeight,
}) {
  final raw = authored?.trim().toLowerCase();
  if (raw == null || raw.isEmpty) return uaValue ?? parentWeight;
  if (raw == 'inherit' || raw == 'unset') return parentWeight;
  if (raw == 'initial') return '400';
  if (raw == 'revert' || raw == 'revert-layer') return null;
  if (raw == 'normal') return '400';
  if (raw == 'bold') return '700';
  if (raw == 'bolder' || raw == 'lighter') {
    final weight = int.tryParse(parentWeight) ?? 400;
    if (raw == 'bolder') {
      return weight < 350
          ? '400'
          : weight < 550
          ? '700'
          : weight < 750
          ? '900'
          : '900';
    }
    return weight < 550
        ? '100'
        : weight < 750
        ? '400'
        : '700';
  }
  final value = int.tryParse(raw);
  if (value == null || value < 1 || value > 1000) return null;
  return '$value';
}

String? _lineHeightFor({
  required dom.Element element,
  required Map<dom.Element, Map<String, String>> stylesByElement,
  required Map<dom.Element, NativeDocumentComputedStyleSpec> computedByElement,
  required Map<dom.Element, bool> fontSizeReliableByElement,
  required bool fontSizeReliable,
  required bool rootFontSizeReliable,
  required double currentFontSize,
  required double rootFontSize,
  required double viewportWidth,
  required double viewportHeight,
}) {
  dom.Element? owner = element;
  String? raw;
  while (owner != null) {
    final candidate = stylesByElement[owner]?['line-height']?.trim();
    if (candidate != null && candidate.isNotEmpty) {
      final keyword = candidate.toLowerCase();
      if (keyword == 'inherit' || keyword == 'unset') {
        owner = owner.parent;
        continue;
      }
      if (keyword == 'initial') return 'normal';
      if (keyword == 'revert' || keyword == 'revert-layer') return null;
      raw = candidate;
      break;
    }
    owner = owner.parent;
  }
  if (raw == null) return 'normal';
  final value = raw.toLowerCase();
  if (value == 'normal') return 'normal';
  final lineHeightOwner = owner;
  if (lineHeightOwner == null) return null;
  final number = double.tryParse(value);
  if (number != null && number.isFinite && number >= 0) {
    if (!fontSizeReliable) return null;
    return '${_formatNumber(number * currentFontSize)}px';
  }
  final referenceSize = identical(lineHeightOwner, element)
      ? currentFontSize
      : computedByElement[lineHeightOwner]?.fontSize ?? currentFontSize;
  final ownerFontSizeReliable = identical(lineHeightOwner, element)
      ? fontSizeReliable
      : fontSizeReliableByElement[lineHeightOwner] ?? false;
  final unit = RegExp(r'(px|em|rem|%|vw|vh)$').firstMatch(value)?.group(1);
  if ((unit == 'em' || unit == '%') && !ownerFontSizeReliable) return null;
  if (unit == 'rem' && !rootFontSizeReliable) return null;
  final resolved = nativeComputedCssLength(
    value,
    fontSize: referenceSize,
    rootFontSize: rootFontSize,
    viewportWidth: viewportWidth,
    viewportHeight: viewportHeight,
    percentageBasis: referenceSize,
  );
  if (resolved == null || resolved < 0) return null;
  return '${_formatNumber(resolved)}px';
}

String? _computedSpacing(
  String? authored, {
  required String inheritedValue,
  required String initialValue,
  required double fontSize,
  required double rootFontSize,
  required double viewportWidth,
  required double viewportHeight,
  required bool allowNormal,
  required String normalValue,
}) {
  final raw = authored?.trim().toLowerCase();
  if (raw == null || raw.isEmpty) return inheritedValue;
  if (raw == 'inherit' || raw == 'unset') return inheritedValue;
  if (raw == 'initial') return initialValue;
  if (raw == 'revert' || raw == 'revert-layer') return null;
  if (allowNormal && raw == 'normal') return normalValue;
  final resolved = nativeComputedCssLength(
    raw,
    fontSize: fontSize,
    rootFontSize: rootFontSize,
    viewportWidth: viewportWidth,
    viewportHeight: viewportHeight,
  );
  if (resolved == null) return null;
  return '${_formatNumber(resolved)}px';
}

String? _computedOpacity(String? authored, {required String inheritedValue}) {
  final raw = authored?.trim().toLowerCase();
  if (raw == null || raw.isEmpty) return '1';
  if (raw == 'initial' || raw == 'unset') return '1';
  if (raw == 'inherit') return inheritedValue;
  if (raw == 'revert' || raw == 'revert-layer') return null;
  final value = double.tryParse(raw);
  if (value == null || !value.isFinite) return null;
  return _formatNumber(value.clamp(0, 1));
}

Map<String, String> _lengthsFor({
  required Map<String, String> author,
  required double fontSize,
  required bool fontSizeReliable,
  required double rootFontSize,
  required bool rootFontSizeReliable,
  required double viewportWidth,
  required double viewportHeight,
  required String direction,
  required NativeDocumentComputedStyleSpec? parentSpec,
  required Map<String, String> borderStyles,
  required String tagName,
}) {
  final result = <String, String>{};
  final ua = _uaGeometry(
    tagName,
    fontSize,
    direction,
    fontSizeReliable: fontSizeReliable,
  );
  final defaults = <String, String?>{
    'width': 'auto',
    'height': 'auto',
    'min-width': '0px',
    'max-width': 'none',
    'min-height': '0px',
    'max-height': 'none',
    'top': 'auto',
    'right': 'auto',
    'bottom': 'auto',
    'left': 'auto',
    for (final side in _sides)
      'margin-$side': ua.containsKey('margin-$side')
          ? ua['margin-$side']
          : '0px',
    for (final side in _sides) 'padding-$side': ua['padding-$side'] ?? '0px',
    for (final side in _sides) 'scroll-margin-$side': '0px',
    for (final side in _sides) 'scroll-padding-$side': 'auto',
    for (final side in _sides) 'border-$side-width': 'medium',
  };
  final initials = <String, String>{
    'width': 'auto',
    'height': 'auto',
    'min-width': '0px',
    'max-width': 'none',
    'min-height': '0px',
    'max-height': 'none',
    'top': 'auto',
    'right': 'auto',
    'bottom': 'auto',
    'left': 'auto',
    for (final side in _sides) 'margin-$side': '0px',
    for (final side in _sides) 'padding-$side': '0px',
    for (final side in _sides) 'scroll-margin-$side': '0px',
    for (final side in _sides) 'scroll-padding-$side': 'auto',
    for (final side in _sides) 'border-$side-width': 'medium',
  };
  for (final property in defaults.keys) {
    final authored = author[property]?.trim();
    final defaultValue = defaults[property];
    if (authored == null && defaultValue == null) continue;
    var value = authored ?? defaultValue!;
    if (authored != null) {
      final keyword = authored.toLowerCase();
      if (keyword == 'inherit') {
        final parentValue = parentSpec?.lengths[property];
        if (parentValue == null) continue;
        value = parentValue;
      } else if (keyword == 'initial' || keyword == 'unset') {
        value = initials[property]!;
      } else if (keyword == 'revert' || keyword == 'revert-layer') {
        continue;
      }
    }
    final normalizedRelativeValue = _normalizeRelativeGeometryUnits(
      value,
      fontSize: fontSize,
      fontSizeReliable: fontSizeReliable,
      rootFontSize: rootFontSize,
      rootFontSizeReliable: rootFontSizeReliable,
      viewportWidth: viewportWidth,
      viewportHeight: viewportHeight,
    );
    if (normalizedRelativeValue == null) continue;
    value = normalizedRelativeValue;
    if (property.startsWith('border-') && property.endsWith('-width')) {
      final side = property.substring(
        'border-'.length,
        property.length - '-width'.length,
      );
      final style = borderStyles[side] ?? 'none';
      if (style == 'none' || style == 'hidden') {
        value = '0px';
      } else if (authored == null) {
        value = '3px';
      }
      final borderSize = _borderWidthValue(value);
      if (borderSize != null) value = '${_formatNumber(borderSize)}px';
    }
    final allowNegative =
        property.startsWith('margin-') ||
        property.startsWith('scroll-margin-') ||
        const {'top', 'right', 'bottom', 'left'}.contains(property);
    final normalized = _normalizeGeometryLength(
      value,
      property: property,
      allowNegative: allowNegative,
    );
    if (normalized != null) result[property] = normalized;
  }
  return result;
}

String? _normalizeRelativeGeometryUnits(
  String value, {
  required double fontSize,
  required bool fontSizeReliable,
  required double rootFontSize,
  required bool rootFontSizeReliable,
  required double viewportWidth,
  required double viewportHeight,
}) {
  final unitPattern = RegExp(
    r'([+-]?(?:\d+(?:\.\d*)?|\.\d+))(em|rem|vw|vh)\b',
    caseSensitive: false,
  );
  final matches = unitPattern.allMatches(value).toList();
  if (matches.any((match) => match.group(2)!.toLowerCase() == 'em') &&
      !fontSizeReliable) {
    return null;
  }
  if (matches.any((match) => match.group(2)!.toLowerCase() == 'rem') &&
      !rootFontSizeReliable) {
    return null;
  }
  if (matches.isEmpty) return value;

  var unresolved = false;
  final normalized = value.replaceAllMapped(unitPattern, (match) {
    final resolved = nativeComputedCssLength(
      match[0]!,
      fontSize: fontSize,
      rootFontSize: rootFontSize,
      viewportWidth: viewportWidth,
      viewportHeight: viewportHeight,
    );
    if (resolved == null) {
      unresolved = true;
      return match[0]!;
    }
    return '${_formatNumber(resolved)}px';
  });
  return unresolved ? null : normalized;
}

String? _uaWhiteSpace(String tag) => tag == 'pre' ? 'pre' : null;

Map<String, String?> _uaGeometry(
  String tag,
  double fontSize,
  String direction, {
  required bool fontSizeReliable,
}) {
  final result = <String, String?>{};
  String? blockMargin([double factor = 1]) =>
      fontSizeReliable ? '${_formatNumber(fontSize * factor)}px' : null;
  if (tag == 'body') {
    for (final side in _sides) {
      result['margin-$side'] = '8px';
    }
  } else if (tag == 'p' ||
      const {
        'ul',
        'ol',
        'menu',
        'dl',
        'pre',
        'blockquote',
        'figure',
      }.contains(tag)) {
    result['margin-top'] = blockMargin();
    result['margin-bottom'] = blockMargin();
  } else if (const {'h1', 'h2', 'h3', 'h4', 'h5', 'h6'}.contains(tag)) {
    final factor = switch (tag) {
      'h1' || 'h6' => .67,
      'h2' || 'h5' => .83,
      'h3' => 1.17,
      _ => 1.33,
    };
    result['margin-top'] = blockMargin(factor);
    result['margin-bottom'] = blockMargin(factor);
  }
  if (_formControls.contains(tag)) {
    result['margin-top'] = '0px';
    result['margin-right'] = '0px';
    result['margin-bottom'] = '0px';
    result['margin-left'] = '0px';
  }
  if (const {'ul', 'ol', 'menu'}.contains(tag)) {
    result['padding-${direction == 'rtl' ? 'right' : 'left'}'] = '40px';
  }
  if (const {'blockquote', 'figure'}.contains(tag)) {
    result['margin-${direction == 'rtl' ? 'right' : 'left'}'] = '40px';
    result['margin-${direction == 'rtl' ? 'left' : 'right'}'] = '40px';
  }
  if (tag == 'dd') {
    result['margin-${direction == 'rtl' ? 'right' : 'left'}'] = '40px';
  }
  return result;
}

String? _normalizeGeometryLength(
  String raw, {
  required String property,
  required bool allowNegative,
}) {
  final value = raw.trim();
  final lower = value.toLowerCase();
  final zero = RegExp(r'^[+-]?(?:0+(?:\.0*)?|\.0+)$').hasMatch(lower);
  if (zero) return '0px';
  if (const {'auto', 'none'}.contains(lower)) return lower;
  if (property.startsWith('border-') && property.endsWith('-width')) {
    final mapped = _borderWidthValue(lower);
    if (mapped != null) return '${_formatNumber(mapped)}px';
  }
  if (RegExp(
    r'^[+-]?(?:\d+(?:\.\d*)?|\.\d+)(?:px|em|rem|%|vw|vh)$',
    caseSensitive: false,
  ).hasMatch(value)) {
    final number = double.tryParse(
      value.replaceAll(
        RegExp(r'(px|em|rem|%|vw|vh)$', caseSensitive: false),
        '',
      ),
    );
    if (number == null || !number.isFinite || (!allowNegative && number < 0)) {
      return null;
    }
    final unit = RegExp(
      r'(px|em|rem|%|vw|vh)$',
      caseSensitive: false,
    ).firstMatch(value)!.group(1)!.toLowerCase();
    return '${_formatNumber(number)}$unit';
  }
  if (RegExp(
    r'^(calc|min|max|clamp)\(',
    caseSensitive: false,
  ).hasMatch(lower)) {
    return value;
  }
  if (const {
        'width',
        'height',
        'min-width',
        'max-width',
        'min-height',
        'max-height',
      }.contains(property) &&
      const {
        'min-content',
        'max-content',
        'fit-content',
        'stretch',
      }.contains(lower)) {
    return lower;
  }
  return null;
}

double? _borderWidthValue(String raw) {
  final value = raw.trim().toLowerCase();
  return switch (value) {
    'thin' => 1,
    'medium' => 3,
    'thick' => 5,
    _ => null,
  };
}

String _formatNumber(double value) {
  if (value == 0) return '0';
  if (!value.isFinite) return value.toString();
  var normalized = value.toStringAsFixed(6);
  if (normalized.contains('.')) {
    while (normalized.endsWith('0')) {
      normalized = normalized.substring(0, normalized.length - 1);
    }
    if (normalized.endsWith('.')) {
      normalized = normalized.substring(0, normalized.length - 1);
    }
  }
  return normalized == '-0' ? '0' : normalized;
}
