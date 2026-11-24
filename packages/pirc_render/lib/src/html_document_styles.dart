import 'render_l10n.dart';
import 'document_pointer_style.dart';
import 'dart:collection';

import 'package:csslib/parser.dart' as css_parser;
import 'package:csslib/visitor.dart' as css;
import 'package:html/dom.dart' as dom;

import 'html_document_urls.dart';
import 'html_background_gradient.dart';

/// One stylesheet in document order. The caller owns fetching and decoding CSS.
class NativeDocumentStylesheet {
  const NativeDocumentStylesheet(
    this.cssText, {
    required this.baseUrl,
    this.media,
  });

  final String cssText;
  final String baseUrl;

  /// The `<link media>` or other outer media condition, if any.
  final String? media;
}

/// Import information for a caller that fetches and flattens CSS sources.
class NativeDocumentStyleImport {
  const NativeDocumentStyleImport({
    required this.href,
    required this.url,
    required this.baseUrl,
    required this.media,
    required this.supported,
    required this.sourceOrder,
    required this.sourceIndex,
    this.reason,
  });

  /// The URL token as written in the `@import` rule.
  final String href;

  /// The resolved HTTP(S) URL, or null when it could not be resolved.
  final String? url;
  final String baseUrl;

  /// Combined outer stylesheet and `@import` media conditions.
  final String? media;

  /// False for late imports or media conditions the caller cannot represent.
  /// A null [url] means only that the local HTTP(S)-only helper could not
  /// resolve it; the native resolver remains authoritative for loading.
  final bool supported;
  final String? reason;

  /// Position among top-level productions in this source stylesheet.
  final int sourceOrder;

  /// Position of the source in the engine's ordered stylesheet list.
  final int sourceIndex;
}

/// A CSS cascade limitation or parse/matching problem that was not applied.
class NativeDocumentStyleDiagnostic {
  const NativeDocumentStyleDiagnostic({
    required this.code,
    required this.message,
    required this.baseUrl,
    this.selector,
    this.property,
  });

  final String code;
  final String message;
  final String baseUrl;
  final String? selector;
  final String? property;

  @override
  String toString() => '$code: $message ($baseUrl)';
}

/// Result from applying the supported author cascade to a parsed HTML DOM.
class NativeDocumentStylesResult {
  NativeDocumentStylesResult._({
    required this.stylesByElement,
    required this.styleAttributesByElement,
    required this.imports,
    required this.diagnostics,
    required this.canvasBitmapAttributesIndependent,
    required this.inlineBoxStyleOverridesIndependent,
    required this.textContentSelectorsIndependent,
  });

  /// Winning values in emitted CSS order. Values exclude `!important`.
  ///
  /// The engine also writes these declarations to each element's `style`
  /// attribute, retaining `!important` there so downstream HTML rendering sees
  /// the same winner. This map is useful when callers need specific computed
  /// declarations for document-level propagation.
  final Map<dom.Element, Map<String, String>> stylesByElement;

  /// Serialized style attributes written to the DOM by [apply].
  final Map<dom.Element, String> styleAttributesByElement;
  final List<NativeDocumentStyleImport> imports;
  final List<NativeDocumentStyleDiagnostic> diagnostics;

  /// True only when the complete parsed CSS set has no attribute-selector or
  /// `attr()` dependency, and its relevant syntax was understood. This lets a
  /// caller prove that changing a canvas backing-store attribute cannot change
  /// CSS matching anywhere in the document.
  final bool canvasBitmapAttributesIndependent;

  /// No important box declaration can outrank a normal inline box assignment.
  final bool inlineBoxStyleOverridesIndependent;

  /// The complete parsed selector set cannot change matches when only ordinary
  /// text nodes change. Structural element/attribute/style mutations are separate.
  final bool textContentSelectorsIndependent;
}

/// Applies a deliberately bounded CSS author cascade to a full parsed DOM.
///
/// Selectors are passed as complete selector strings to `package:html`'s
/// `querySelectorAll`; specificity and cascade order are computed separately.
/// The engine supports CSS selector forms accepted by that matcher (with
/// diagnostics for its unsupported dynamic pseudo-classes/elements), ordinary
/// declarations, `!important`, inline style attributes, common 1-to-4-value
/// box shorthands, border width/style/color/radius shorthands, common CSS font
/// shorthand values, `gap`, `flex`, and `flex-flow` shorthand values, layered
/// URL and CSS gradient background images,
/// supported background shorthand components, integer and `span N` grid
/// row/column placements, common Media Queries Level 3 conditions, and custom
/// properties with
/// inheritance and `var()` fallbacks.
///
/// Background shorthand forms outside the supported URL/gradient subset,
/// system font keywords, `grid`, and `grid-template`, named grid lines,
/// CSS cascade layers, animation/presentation origins, pseudo-elements,
/// unsupported media features, Media Queries Level 4 range/or/nested boolean
/// syntax, and general CSS-wide keyword computation are not implemented.
/// Unsupported at-rules/selectors/shorthands produce diagnostics instead of
/// being silently treated as applied.
class NativeDocumentStyleEngine {
  NativeDocumentStyleEngine({
    required Iterable<NativeDocumentStylesheet> stylesheets,
    required this.viewportWidth,
    required this.dark,
    this.viewportHeight = 844,
    this.devicePixelRatio = 1,
    this.reducedMotion = false,
    this.pointer = 'coarse',
    this.hover = 'none',
    this.documentBaseUrl,
    this.fragmentTarget,
    this.dialogDefaults = false,
  }) : stylesheets = List<NativeDocumentStylesheet>.unmodifiable(stylesheets);

  final List<NativeDocumentStylesheet> stylesheets;
  final double viewportWidth;
  final double viewportHeight;
  final double devicePixelRatio;
  final bool dark;

  /// Include normal-origin dialog UA rules for full native documents.
  final bool dialogDefaults;
  final bool reducedMotion;

  /// The primary pointer capability, as exposed by the document environment.
  final String pointer;

  /// The primary hover capability, as exposed by the document environment.
  final String hover;

  /// Effective document URL used for inline style attributes. This includes
  /// the document's `<base href>` when present.
  final String? documentBaseUrl;

  /// The retained target element in this DOM clone, independent of URL rewrites.
  final dom.Element? fragmentTarget;

  /// Applies the cascade to [document] in place and returns the effective
  /// inline declarations, import metadata, and diagnostics.
  NativeDocumentStylesResult apply(dom.Document document) =>
      _Cascade(this, document).apply();

  /// Extracts imports without fetching them. Only leading top-level imports
  /// are loadable; a later import is marked unsupported with a reason.
  static List<NativeDocumentStyleImport> importsOf(
    NativeDocumentStylesheet stylesheet, {
    int sourceIndex = 0,
  }) {
    final parsed = _parseCss(stylesheet.cssText, stylesheet.baseUrl);
    final sheet = parsed.stylesheet;
    if (sheet == null) return const [];
    return List<NativeDocumentStyleImport>.unmodifiable(
      _importsFromAst(sheet, stylesheet, sourceIndex),
    );
  }
}

const _supportedBoxShorthands = <String, List<String>>{
  'inset': ['top', 'right', 'bottom', 'left'],
  'scroll-margin': [
    'scroll-margin-top',
    'scroll-margin-right',
    'scroll-margin-bottom',
    'scroll-margin-left',
  ],
  'scroll-padding': [
    'scroll-padding-top',
    'scroll-padding-right',
    'scroll-padding-bottom',
    'scroll-padding-left',
  ],
  'margin': ['margin-top', 'margin-right', 'margin-bottom', 'margin-left'],
  'padding': ['padding-top', 'padding-right', 'padding-bottom', 'padding-left'],
  'border-color': [
    'border-top-color',
    'border-right-color',
    'border-bottom-color',
    'border-left-color',
  ],
  'border-style': [
    'border-top-style',
    'border-right-style',
    'border-bottom-style',
    'border-left-style',
  ],
  'border-width': [
    'border-top-width',
    'border-right-width',
    'border-bottom-width',
    'border-left-width',
  ],
};

const _borderSides = <String>['top', 'right', 'bottom', 'left'];
const _borderKinds = <String>['width', 'style', 'color'];
const _borderSideShorthands = <String, List<String>>{
  'border-top': ['border-top-width', 'border-top-style', 'border-top-color'],
  'border-right': [
    'border-right-width',
    'border-right-style',
    'border-right-color',
  ],
  'border-bottom': [
    'border-bottom-width',
    'border-bottom-style',
    'border-bottom-color',
  ],
  'border-left': [
    'border-left-width',
    'border-left-style',
    'border-left-color',
  ],
};
const _fontInheritanceLonghands = <String>[
  'font-family',
  'font-size',
  'font-size-adjust',
  'font-style',
  'font-weight',
  'font-stretch',
  'font-variant',
  'font-variant-alternates',
  'font-variant-caps',
  'font-variant-east-asian',
  'font-variant-emoji',
  'font-variant-ligatures',
  'font-variant-numeric',
  'font-variant-position',
  'line-height',
  'font-kerning',
  'font-optical-sizing',
  'font-feature-settings',
  'font-variation-settings',
  'font-language-override',
];
const _fontInitialValues = <String, String>{
  'font-family': '',
  'font-size': '',
  'font-size-adjust': 'none',
  'font-style': 'normal',
  'font-weight': 'normal',
  'font-stretch': 'normal',
  'font-variant': 'normal',
  'font-variant-alternates': 'normal',
  'font-variant-caps': 'normal',
  'font-variant-east-asian': 'normal',
  'font-variant-emoji': 'normal',
  'font-variant-ligatures': 'normal',
  'font-variant-numeric': 'normal',
  'font-variant-position': 'normal',
  'line-height': 'normal',
  'font-kerning': 'auto',
  'font-optical-sizing': 'auto',
  'font-feature-settings': 'normal',
  'font-variation-settings': 'normal',
  'font-language-override': 'normal',
};
const _fontSizeKeywords = <String>{
  'xx-small',
  'x-small',
  'small',
  'medium',
  'large',
  'x-large',
  'xx-large',
  'xxx-large',
  'larger',
  'smaller',
};
const _fontLengthUnits = <String>{
  'px',
  'em',
  'rem',
  'ex',
  'ch',
  'cap',
  'ic',
  'lh',
  'rlh',
  'vw',
  'vh',
  'vi',
  'vb',
  'vmin',
  'vmax',
  'svw',
  'svh',
  'svi',
  'svb',
  'svmin',
  'svmax',
  'lvw',
  'lvh',
  'lvi',
  'lvb',
  'lvmin',
  'lvmax',
  'dvw',
  'dvh',
  'dvi',
  'dvb',
  'dvmin',
  'dvmax',
  'cm',
  'mm',
  'q',
  'in',
  'pt',
  'pc',
};
const _flexBasisLengthUnits = <String>{
  'px',
  'em',
  'rem',
  'ex',
  'rex',
  'ch',
  'rch',
  'cap',
  'rcap',
  'ic',
  'ric',
  'lh',
  'rlh',
  'vw',
  'vh',
  'vi',
  'vb',
  'vmin',
  'vmax',
  'svw',
  'svh',
  'svi',
  'svb',
  'svmin',
  'svmax',
  'lvw',
  'lvh',
  'lvi',
  'lvb',
  'lvmin',
  'lvmax',
  'dvw',
  'dvh',
  'dvi',
  'dvb',
  'dvmin',
  'dvmax',
  'cm',
  'mm',
  'q',
  'in',
  'pt',
  'pc',
};
const _fontStretchKeywords = <String>{
  'ultra-condensed',
  'extra-condensed',
  'condensed',
  'semi-condensed',
  'semi-expanded',
  'expanded',
  'extra-expanded',
  'ultra-expanded',
};
const _reservedFontFamilyWords = <String>{
  ..._cssWideKeywords,
  ..._fontSizeKeywords,
  ..._fontStretchKeywords,
  'normal',
  'italic',
  'oblique',
  'small-caps',
  'bold',
  'bolder',
  'lighter',
  'caption',
  'icon',
  'menu',
  'message-box',
  'small-caption',
  'status-bar',
};
const _cssColorProperties = <String>{
  'accent-color',
  'background-color',
  'border-color',
  'border-bottom-color',
  'border-left-color',
  'border-right-color',
  'border-top-color',
  'caret-color',
  'color',
  'column-rule-color',
  'outline-color',
  'text-decoration-color',
};
const _cssWideKeywords = <String>{
  'inherit',
  'initial',
  'revert',
  'revert-layer',
  'unset',
};
const _borderStyleKeywords = <String>{
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
const _borderWidthKeywords = <String>{'thin', 'medium', 'thick'};
const _defaultBorderValues = <String, String>{
  'width': 'medium',
  'style': 'none',
  'color': 'currentcolor',
};
// `border` resets these longhands even though they cannot be set by its
// syntax. Side-specific border shorthands leave them alone.
const _initialBorderImageValues = <String, String>{
  'border-image-source': 'none',
  'border-image-slice': '100%',
  'border-image-width': '1',
  'border-image-outset': '0',
  'border-image-repeat': 'stretch',
};
const _cssSystemColors = <String>{
  'accentcolor',
  'accentcolortext',
  'activetext',
  'buttonborder',
  'buttonface',
  'buttontext',
  'canvas',
  'canvastext',
  'field',
  'fieldtext',
  'graytext',
  'highlight',
  'highlighttext',
  'linktext',
  'mark',
  'marktext',
  'selecteditem',
  'selecteditemtext',
  'visitedtext',
};
const _backgroundGradientFunctions = <String>{
  'conic-gradient',
  'linear-gradient',
  'radial-gradient',
  'repeating-conic-gradient',
  'repeating-linear-gradient',
  'repeating-radial-gradient',
};
const _modernCssColorFunctions = <String>{
  'color',
  'color-mix',
  'hwb',
  'lab',
  'lch',
  'light-dark',
  'oklab',
  'oklch',
};

const _unsupportedShorthands = <String>{
  'all',
  'animation',
  'background',
  'border-block',
  'border-block-color',
  'border-block-style',
  'border-block-width',
  'border-image',
  'border-inline',
  'border-inline-color',
  'border-inline-style',
  'border-inline-width',
  'column-rule',
  'columns',
  'grid',
  'grid-area',
  'grid-template',
  'list-style',
  'mask',
  'outline',
  'padding-block',
  'padding-inline',
  'place-content',
  'place-items',
  'place-self',
  'text-decoration',
  'text-emphasis',
  'transition',
};

class _Candidate {
  const _Candidate({
    required this.valueExpression,
    required this.value,
    required this.important,
    required this.isInline,
    required this.specificity,
    required this.order,
    required this.suborder,
    required this.baseUrl,
    this.userAgent = false,
    this.backgroundGroup,
    this.backgroundComponent,
  });

  final css.Expression? valueExpression;
  final String value;
  final bool important;
  final bool userAgent;
  final bool isInline;
  final _Specificity specificity;
  final int order;
  final int suborder;
  final String baseUrl;
  final Object? backgroundGroup;
  final String? backgroundComponent;

  bool outranks(_Candidate other) {
    // Only normal UA declarations are seeded here; every author origin wins.
    if (userAgent != other.userAgent) return !userAgent;
    if (important != other.important) return important;
    if (isInline != other.isInline) return isInline;
    final specificityOrder = specificity.compareTo(other.specificity);
    if (specificityOrder != 0) return specificityOrder > 0;
    if (order != other.order) return order > other.order;
    return suborder > other.suborder;
  }
}

class _ParsedFontShorthand {
  _ParsedFontShorthand(
    Map<String, String> values,
    Map<String, css.Expression> expressions,
  ) : values = Map<String, String>.unmodifiable(values),
      expressions = Map<String, css.Expression>.unmodifiable(expressions);

  final Map<String, String> values;
  final Map<String, css.Expression> expressions;
}

class _GridPlacementParts {
  const _GridPlacementParts({required this.start, required this.end});

  final _GridPlacementValue start;
  final _GridPlacementValue end;
}

class _GridPlacementValue {
  const _GridPlacementValue({this.expression, required this.value});

  final css.Expression? expression;
  final String value;
}

class _BorderRadiusValue {
  const _BorderRadiusValue({this.expression, required this.value});

  final css.Expression? expression;
  final String value;
}

class _PreservedInlineDeclaration {
  const _PreservedInlineDeclaration({
    required this.property,
    required this.value,
    required this.important,
    required this.order,
  });

  final String property;
  final String value;
  final bool important;
  final int order;
}

class _Specificity implements Comparable<_Specificity> {
  const _Specificity(this.ids, this.classes, this.types);

  static const zero = _Specificity(0, 0, 0);
  final int ids;
  final int classes;
  final int types;

  _Specificity operator +(_Specificity other) => _Specificity(
    ids + other.ids,
    classes + other.classes,
    types + other.types,
  );

  @override
  int compareTo(_Specificity other) {
    if (ids != other.ids) return ids.compareTo(other.ids);
    if (classes != other.classes) return classes.compareTo(other.classes);
    return types.compareTo(other.types);
  }
}

enum _ColorValueStatus { valid, invalid, unvalidated }

class _VariableScope {
  _VariableScope(this.local, this.parent);

  final Map<String, _Candidate> local;
  final _VariableScope? parent;
  final Map<String, String?> cache = {};
}

class _VariableKey {
  const _VariableKey(this.scope, this.name);

  final _VariableScope scope;
  final String name;

  @override
  bool operator ==(Object other) =>
      other is _VariableKey &&
      identical(other.scope, scope) &&
      other.name == name;

  @override
  int get hashCode => Object.hash(identityHashCode(scope), name);
}

class _Cascade {
  _Cascade(this.engine, this.document);

  final NativeDocumentStyleEngine engine;
  final dom.Document document;
  final _winners = HashMap<dom.Element, Map<String, _Candidate>>.identity();
  final _preservedInline =
      HashMap<dom.Element, List<_PreservedInlineDeclaration>>.identity();
  final _diagnostics = <NativeDocumentStyleDiagnostic>[];
  final _cyclicVariables = <_VariableKey>{};
  final _reportedCycles = <String>{};
  bool _canvasBitmapDependenciesInspectable = true;
  bool _textContentSelectorsInspectable = true;
  bool _hasImportantBoxDeclaration = false;
  int _order = 0;
  int _selectorProbeOrder = 0;

  NativeDocumentStylesResult apply() {
    if (engine.dialogDefaults) {
      for (final element in document.querySelectorAll('dialog')) {
        final modal = element.attributes.containsKey('data-pirc-dialog-modal');
        final defaults = <String, String>{
          'display': element.attributes.containsKey('open') ? 'block' : 'none',
          'position': modal ? 'fixed' : 'absolute',
          'left': '0px',
          'right': '0px',
          'top': modal ? '0px' : 'auto',
          'bottom': modal ? '0px' : 'auto',
          'width': 'fit-content',
          'height': 'fit-content',
          if (modal) ...{
            'max-width':
                '${(engine.viewportWidth - 32).clamp(0, double.infinity)}px',
            'max-height':
                '${(engine.viewportHeight - 32).clamp(0, double.infinity)}px',
          },
          'color': 'CanvasText',
          'background-color': tr("Canvas"),
          for (final side in ['top', 'right', 'bottom', 'left']) ...{
            'margin-$side': 'auto',
            'padding-$side': '1em',
            'border-$side-width': '3px',
            'border-$side-style': 'solid',
            'border-$side-color': 'currentColor',
          },
        };
        for (final entry in defaults.entries) {
          _offer(
            element,
            entry.key,
            _Candidate(
              valueExpression: null,
              value: entry.value,
              important: false,
              isInline: false,
              userAgent: true,
              specificity: _Specificity.zero,
              order: -1,
              suborder: 0,
              baseUrl: engine.documentBaseUrl ?? '',
            ),
          );
        }
      }
    }
    final imports = <NativeDocumentStyleImport>[];
    for (
      var sourceIndex = 0;
      sourceIndex < engine.stylesheets.length;
      sourceIndex++
    ) {
      final source = engine.stylesheets[sourceIndex];
      final sourceImports = NativeDocumentStyleEngine.importsOf(
        source,
        sourceIndex: sourceIndex,
      );
      imports.addAll(sourceImports);
      for (final item in sourceImports.where((item) => !item.supported)) {
        _diagnostics.add(
          NativeDocumentStyleDiagnostic(
            code: 'invalid-import',
            message: item.reason ?? tr("The CSS import cannot be loaded."),
            baseUrl: source.baseUrl,
          ),
        );
      }

      final mediaPrepared = _prepareUnsupportedMediaHeaders(
        source.cssText,
        source.baseUrl,
      );
      for (var index = 0; index < mediaPrepared.quarantinedCount; index++) {
        _unsupportedMediaSyntax(source.baseUrl);
      }
      final parsed = _parseCss(mediaPrepared.cssText, source.baseUrl);
      _addParseMessages(parsed.messages, source.baseUrl);
      final stylesheet = parsed.stylesheet;
      if (stylesheet == null) {
        _canvasBitmapDependenciesInspectable = false;
        _textContentSelectorsInspectable = false;
        continue;
      }
      if (parsed.messages.isNotEmpty) {
        _textContentSelectorsInspectable = false;
        _canvasBitmapDependenciesInspectable = false;
      }
      _inspectCanvasBitmapDependencies(stylesheet);

      var sourceIsActive = true;
      final sourceMedia = source.media?.trim();
      if (sourceMedia != null && sourceMedia.isNotEmpty) {
        final media = _parseMediaText(sourceMedia, source.baseUrl);
        _addParseMessages(media.messages, source.baseUrl);
        if (media.queries == null) {
          sourceIsActive = false;
          _diagnostics.add(
            NativeDocumentStyleDiagnostic(
              code: 'unsupported-media',
              message: tr("Could not parse the stylesheet media condition."),
              baseUrl: source.baseUrl,
            ),
          );
        } else {
          sourceIsActive = _mediaQueriesMatch(
            media.queries!,
            source.baseUrl,
            sourceText: sourceMedia,
          );
        }
      }
      _processRules(stylesheet.topLevels, source, active: sourceIsActive);
    }

    final elements = document.querySelectorAll('*');
    for (final element in elements) {
      final inlineStyle = element.attributes['style'];
      if (inlineStyle == null || inlineStyle.trim().isEmpty) continue;
      _addInlineStyle(element, inlineStyle);
    }

    final scopes = HashMap<dom.Element, _VariableScope>.identity();
    final stylesByElement =
        HashMap<dom.Element, Map<String, String>>.identity();
    final styleAttributesByElement = HashMap<dom.Element, String>.identity();

    for (final element in elements) {
      final localWinners = _winners[element] ?? const <String, _Candidate>{};
      final localCustom = <String, _Candidate>{
        for (final entry in localWinners.entries)
          if (entry.key.startsWith('--')) entry.key: entry.value,
      };
      final parent = element.parent;
      final parentScope = parent is dom.Element ? scopes[parent] : null;
      final scope = _VariableScope(localCustom, parentScope);
      scopes[element] = scope;

      // A shorthand containing var() cannot be classified until its custom
      // properties have been selected and inherited. Resolve it here, then
      // offer all of its longhands with the shorthand's original cascade rank.
      final computedWinners = Map<String, _Candidate>.from(localWinners);
      for (final shorthand in const ['flex', 'flex-flow', 'gap', 'overflow']) {
        final shorthandCandidate = computedWinners.remove(shorthand);
        if (shorthandCandidate == null) continue;
        final raw = shorthandCandidate.valueExpression == null
            ? shorthandCandidate.value
            : _resolveExpression(
                shorthandCandidate.valueExpression!,
                scope,
                const {},
                shorthandCandidate.baseUrl,
                shorthand,
              );
        final resolvedKeyword = raw?.trim().toLowerCase();
        if (resolvedKeyword != null &&
            _cssWideKeywords.contains(resolvedKeyword) &&
            (resolvedKeyword != 'initial' || shorthand == 'gap') &&
            !(shorthand == 'overflow' &&
                const {
                  'initial',
                  'unset',
                  'inherit',
                }.contains(resolvedKeyword))) {
          _diagnostics.add(
            NativeDocumentStyleDiagnostic(
              code: 'unsupported-css-wide-keyword',
              message: tr(
                "CSS-wide keyword computation is not implemented for the {0} shorthand; it was not applied.",
                [shorthand],
              ),
              baseUrl: shorthandCandidate.baseUrl,
              property: shorthand,
            ),
          );
          continue;
        }
        final resolvedExpression = raw == null
            ? null
            : _parseResolvedShorthandExpression(
                shorthand,
                raw,
                shorthandCandidate.baseUrl,
              );
        final expansion = resolvedExpression == null
            ? null
            : switch (shorthand) {
                'gap' => _parseGapShorthand(resolvedExpression),
                'overflow' => _parseOverflowShorthand(resolvedExpression),
                _ => _parseFlexShorthand(shorthand, resolvedExpression),
              };
        if (expansion == null) {
          if (raw != null) {
            _diagnostics.add(
              NativeDocumentStyleDiagnostic(
                code: 'unsupported-shorthand',
                message: tr(
                  "The {0} shorthand is invalid after variable substitution; its initial longhand values are used.",
                  [shorthand],
                ),
                baseUrl: shorthandCandidate.baseUrl,
                property: shorthand,
              ),
            );
          }
          _offerExpandedShorthand(
            computedWinners,
            _initialShorthandExpansion(shorthand),
            shorthandCandidate,
          );
        } else {
          _offerExpandedShorthand(
            computedWinners,
            expansion,
            shorthandCandidate,
          );
        }
      }

      final orderedWinners = computedWinners.entries.toList()
        ..sort((a, b) {
          if (a.key == 'background' && b.key != 'background') {
            return -1;
          }
          if (b.key == 'background' && a.key != 'background') {
            return 1;
          }
          final byOrder = a.value.order.compareTo(b.value.order);
          if (byOrder != 0) return byOrder;
          final bySuborder = a.value.suborder.compareTo(b.value.suborder);
          if (bySuborder != 0) return bySuborder;
          return a.key.compareTo(b.key);
        });
      final effective = <String, String>{};
      final rendered =
          <({int order, int suborder, String property, String text})>[];
      final backgroundCache = HashMap<Object, _BackgroundAnalysis?>.identity();

      String inheritedScheme() {
        final own = computedWinners['color-scheme'];
        if (own != null) {
          final value = own.valueExpression == null
              ? own.value
              : _resolveExpression(
                  own.valueExpression!,
                  scope,
                  const {},
                  own.baseUrl,
                  'color-scheme',
                );
          if (value != null &&
              !const {'inherit', 'unset'}.contains(value.trim())) {
            return value;
          }
        }
        for (
          var ancestor = element.parent;
          ancestor != null;
          ancestor = ancestor.parent
        ) {
          final value = stylesByElement[ancestor]?['color-scheme'];
          if (value != null &&
              !const {'inherit', 'unset'}.contains(value.trim())) {
            return value;
          }
        }
        return 'normal';
      }

      final scheme = engine.dialogDefaults && element.localName == 'dialog'
          ? inheritedScheme().toLowerCase().split(RegExp(r'\s+'))
          : const <String>[];
      final dialogDark =
          scheme.contains('dark') && (engine.dark || !scheme.contains('light'));
      for (final entry in orderedWinners) {
        final property = entry.key;
        final candidate = entry.value;
        String? value;
        if (candidate.backgroundGroup case final group?) {
          if (!backgroundCache.containsKey(group)) {
            final raw = candidate.valueExpression == null
                ? candidate.value
                : _resolveExpression(
                    candidate.valueExpression!,
                    scope,
                    const {},
                    candidate.baseUrl,
                    'background',
                  );
            backgroundCache[group] = raw == null
                ? null
                : _analyzeBackgroundShorthand(raw, candidate.baseUrl);
          }
          final analysis = backgroundCache[group];
          value = candidate.backgroundComponent == null
              ? analysis?.backgroundValue
              : analysis?.components[candidate.backgroundComponent];
        } else if (property.startsWith('--')) {
          value = _resolveCustomProperty(scope, property, const {});
        } else {
          value = candidate.valueExpression == null
              ? candidate.value
              : _resolveExpression(
                  candidate.valueExpression!,
                  scope,
                  const {},
                  candidate.baseUrl,
                  property,
                );
        }
        if (candidate.userAgent && value == 'Canvas') {
          value = dialogDark ? '#121212' : '#ffffff';
        }
        if (candidate.userAgent && value == 'CanvasText') {
          value = dialogDark ? '#ffffff' : '#000000';
        }
        if (value != null && property == 'background-image') {
          value = _normalizeBackgroundValue(
            value,
            baseUrl: candidate.baseUrl,
            property: property,
          );
        }
        if (property == 'pointer-events') {
          var ancestor = parent;
          var inherited = 'auto';
          while (ancestor is dom.Element) {
            final previous = stylesByElement[ancestor]?['pointer-events'];
            if (previous != null) {
              inherited = previous;
              break;
            }
            ancestor = ancestor.parent;
          }
          value = nativeDocumentPointerValue(value, inherited);
        }
        if (const {'overflow-x', 'overflow-y'}.contains(property)) {
          final keyword = value?.trim().toLowerCase();
          value = switch (keyword) {
            'inherit' =>
              (parent is dom.Element)
                  ? (stylesByElement[parent]?[property] ?? 'visible')
                  : 'visible',
            'initial' || 'unset' => 'visible',
            _ => _overflowKeywords.contains(keyword) ? keyword : 'visible',
          };
        }
        if (value == null) continue;
        final trimmed = value.trim();
        if (trimmed.isEmpty) continue;
        if (!property.startsWith('--') &&
            _cssWideKeywords.contains(trimmed.toLowerCase())) {
          _diagnostics.add(
            NativeDocumentStyleDiagnostic(
              code: 'unsupported-css-wide-keyword',
              message: tr(
                "CSS-wide keyword computation is not implemented; the value is passed through to the HTML renderer.",
              ),
              baseUrl: candidate.baseUrl,
              property: property,
            ),
          );
        }
        effective[property] = trimmed;
        rendered.add((
          order: candidate.order,
          suborder: candidate.suborder,
          property: property,
          text:
              '$property: $trimmed${candidate.important ? ' !important' : ''};',
        ));
      }

      for (final declaration
          in _preservedInline[element] ??
              const <_PreservedInlineDeclaration>[]) {
        effective[declaration.property] = declaration.value;
        rendered.add((
          order: declaration.order,
          suborder: 0,
          property: declaration.property,
          text:
              '${declaration.property}: ${declaration.value}'
              '${declaration.important ? ' !important' : ''};',
        ));
      }
      if (engine.dialogDefaults &&
          element.localName == 'dialog' &&
          element.attributes.containsKey('data-pirc-dialog-modal') &&
          !const {'fixed', 'absolute'}.contains(effective['position'])) {
        // A modal's top-layer used position is absolute unless its computed
        // position is fixed. This also applies to author !important values;
        // the snapshot is private, so its serialized style may carry the used
        // value while the script DOM retains the authored declaration.
        effective['position'] = 'absolute';
        rendered.removeWhere((item) => item.property == 'position');
        rendered.add((
          order: _order++,
          suborder: 0,
          property: 'position',
          text: 'position: absolute !important;',
        ));
      }
      if (effective.containsKey('overflow-x') ||
          effective.containsKey('overflow-y')) {
        final x = effective['overflow-x'] ?? 'visible';
        final y = effective['overflow-y'] ?? 'visible';
        String computed(String value, String other) =>
            !const {'visible', 'clip'}.contains(other)
            ? switch (value) {
                'visible' => 'auto',
                'clip' => 'hidden',
                _ => value,
              }
            : value;
        effective['overflow-x'] = computed(x, y);
        effective['overflow-y'] = computed(y, x);
        rendered.removeWhere(
          (item) => const {'overflow-x', 'overflow-y'}.contains(item.property),
        );
        for (final axis in ['overflow-x', 'overflow-y']) {
          rendered.add((
            order: _order++,
            suborder: 0,
            property: axis,
            text: '$axis: ${effective[axis]};',
          ));
        }
      }
      if (rendered.isEmpty) continue;
      rendered.sort((a, b) {
        if (a.property == 'background' && b.property != 'background') {
          return -1;
        }
        if (b.property == 'background' && a.property != 'background') {
          return 1;
        }
        final byOrder = a.order.compareTo(b.order);
        if (byOrder != 0) return byOrder;
        return a.suborder.compareTo(b.suborder);
      });
      final serialized = rendered.map((item) => item.text).join(' ');
      element.attributes['style'] = serialized;
      styleAttributesByElement[element] = serialized;
      if (effective.isNotEmpty) {
        stylesByElement[element] = Map<String, String>.unmodifiable(effective);
      }
    }

    return NativeDocumentStylesResult._(
      stylesByElement: Map<dom.Element, Map<String, String>>.unmodifiable(
        stylesByElement,
      ),
      styleAttributesByElement: Map<dom.Element, String>.unmodifiable(
        styleAttributesByElement,
      ),
      imports: List<NativeDocumentStyleImport>.unmodifiable(imports),
      diagnostics: List<NativeDocumentStyleDiagnostic>.unmodifiable(
        _diagnostics,
      ),
      inlineBoxStyleOverridesIndependent: !_hasImportantBoxDeclaration,
      textContentSelectorsIndependent:
          _textContentSelectorsInspectable &&
          !_diagnostics.any(_blocksCanvasBitmapIndependenceProof),
      canvasBitmapAttributesIndependent:
          _canvasBitmapDependenciesInspectable &&
          !_diagnostics.any(_blocksCanvasBitmapIndependenceProof),
    );
  }

  void _inspectCanvasBitmapDependencies(css.StyleSheet stylesheet) {
    final dependencies = _CanvasBitmapDependencyCollector();
    try {
      stylesheet.visit(dependencies);
    } on Object {
      // Some csslib AST nodes have incomplete visitor implementations. A proof
      // must fail closed instead of assuming they contain no relevant syntax.
      _canvasBitmapDependenciesInspectable = false;
      _textContentSelectorsInspectable = false;
      return;
    }
    if (dependencies.hasTextDependentSelector ||
        dependencies.hasUnsupportedSelector ||
        dependencies.hasUnsupportedRule) {
      _textContentSelectorsInspectable = false;
    }
    _hasImportantBoxDeclaration |= dependencies.hasImportantBoxDeclaration;
    if (dependencies.hasAttributeSelector || dependencies.hasAttrFunction) {
      _canvasBitmapDependenciesInspectable = false;
    }
    if (dependencies.hasUnsupportedSelector ||
        dependencies.hasUnsupportedRule) {
      _canvasBitmapDependenciesInspectable = false;
    }
  }

  bool _blocksCanvasBitmapIndependenceProof(
    NativeDocumentStyleDiagnostic diagnostic,
  ) =>
      diagnostic.code == 'css-parse-error' ||
      diagnostic.code.startsWith('unsupported-') ||
      diagnostic.code.startsWith('invalid-') ||
      diagnostic.code.startsWith('unresolved-') ||
      diagnostic.code.startsWith('unvalidated-') ||
      diagnostic.code.startsWith('cyclic-') ||
      diagnostic.code.startsWith('partial-');

  void _processRules(
    List<css.TreeNode> rules,
    NativeDocumentStylesheet source, {
    required bool active,
  }) {
    for (final rule in rules) {
      if (rule is css.RuleSet) {
        if (active) _applyRuleSet(rule, source);
      } else if (rule is css.MediaDirective) {
        // Every stylesheet is scanned before parsing, and any MQ4 condition
        // unsupported by csslib is quarantined as `@media not all` there.
        // Reconstructing a condition from csslib's directive/query spans is
        // lossy, so evaluate its parsed MQ3 tree directly here.
        final match = active
            ? _mediaQueriesMatch(
                rule.mediaQueries,
                source.baseUrl,
                sourceText: '',
              )
            : false;
        _processRules(rule.rules, source, active: active && match);
      } else if (rule is css.ImportDirective ||
          rule is css.CharsetDirective ||
          rule is css.CssComment ||
          rule is css.NoOp) {
        continue;
      } else {
        _diagnostics.add(
          NativeDocumentStyleDiagnostic(
            code: 'unsupported-at-rule',
            message: tr(
              "Ignored CSS construct {0}; its semantics are not implemented.",
              [rule.runtimeType],
            ),
            baseUrl: source.baseUrl,
          ),
        );
      }
    }
  }

  void _applyRuleSet(css.RuleSet rule, NativeDocumentStylesheet source) {
    final group = rule.selectorGroup;
    if (group == null || group.selectors.isEmpty) {
      _diagnostics.add(
        NativeDocumentStyleDiagnostic(
          code: 'unsupported-selector',
          message: tr("The CSS rule has no selector group."),
          baseUrl: source.baseUrl,
        ),
      );
      return;
    }

    final declarations = <css.Declaration>[];
    for (final node in rule.declarationGroup.declarations) {
      if (node is css.Declaration) {
        declarations.add(node);
      } else {
        _diagnostics.add(
          NativeDocumentStyleDiagnostic(
            code: 'unsupported-nested-rule',
            message: tr(
              "Nested rules or declaration constructs are not supported.",
            ),
            baseUrl: source.baseUrl,
          ),
        );
      }
    }

    for (final selector in group.selectors) {
      final selectorSource = selector.span?.text ?? '';
      final selectorText = selectorSource.trim();
      if (selectorText.isEmpty) {
        _diagnostics.add(
          NativeDocumentStyleDiagnostic(
            code: 'unsupported-selector',
            message: tr("The CSS selector has no source text."),
            baseUrl: source.baseUrl,
          ),
        );
        continue;
      }
      final unsupported = _selectorUnsupportedReason(selector);
      if (unsupported != null) {
        _diagnostics.add(
          NativeDocumentStyleDiagnostic(
            code: 'unsupported-selector',
            message: unsupported,
            baseUrl: source.baseUrl,
            selector: selectorText,
          ),
        );
        continue;
      }

      final specificity = _specificity(selector);
      List<dom.Element> matches;
      try {
        // Keep the complete selector intact. package:html supports numeric
        // :nth-child(), but its matcher counts text nodes and uses a zero-based
        // index. Temporarily replace those pseudos with equivalent element
        // sibling-index attributes so whitespace and one-based CSS indexing
        // do not change the result.
        matches = _querySelectorMatches(
          selector,
          selectorText,
          selectorSource.indexOf(selectorText),
        );
      } catch (error) {
        _diagnostics.add(
          NativeDocumentStyleDiagnostic(
            code: 'unsupported-selector',
            message: tr("Selector matching failed: {0}", [error]),
            baseUrl: source.baseUrl,
            selector: selectorText,
          ),
        );
        continue;
      }

      for (final match in matches) {
        for (final declaration in declarations) {
          _addDeclaration(
            match,
            declaration,
            source.baseUrl,
            specificity,
            isInline: false,
          );
        }
      }
    }
  }

  List<dom.Element> _querySelectorMatches(
    css.Selector selector,
    String selectorText,
    int trimOffset,
  ) {
    final collector = _NthChildSelectorCollector();
    selector.visit(collector);
    final roots = _RootSelectorCollector();
    selector.visit(roots);
    final targets = _RootSelectorCollector('target');
    selector.visit(targets);
    if (collector.selectors.isEmpty &&
        roots.selectors.isEmpty &&
        targets.selectors.isEmpty) {
      return document.querySelectorAll(selectorText);
    }

    final selectorSpan = selector.span;
    if (selectorSpan == null) {
      throw FormatException(tr("The selector has no source span."));
    }
    late String attribute, rootAttribute, targetAttribute;
    do {
      attribute = 'data-native-css-nth-${_selectorProbeOrder++}';
      rootAttribute = '$attribute-root';
      targetAttribute = '$attribute-target';
    } while (document
        .querySelectorAll('*')
        .any(
          (element) =>
              element.attributes.containsKey(attribute) ||
              element.attributes.containsKey(rootAttribute) ||
              element.attributes.containsKey(targetAttribute),
        ));

    final replacements = <_SelectorRangeReplacement>[];
    for (final pseudo in [...roots.selectors, ...targets.selectors]) {
      final span = pseudo.span;
      if (span == null) {
        throw FormatException(tr("The state selector has no source span."));
      }
      final start = span.start.offset - selectorSpan.start.offset - trimOffset;
      final end = span.end.offset - selectorSpan.start.offset - trimOffset;
      if (start < 0 ||
          end > selectorText.length ||
          start >= end ||
          selectorText.substring(start, end) != span.text) {
        throw FormatException(
          tr("The state selector source range could not be mapped."),
        );
      }
      replacements.add(
        _SelectorRangeReplacement(
          start: start,
          end: end,
          text:
              '[${pseudo.name.toLowerCase() == 'target' ? targetAttribute : rootAttribute}]',
        ),
      );
    }
    for (final pseudo in collector.selectors) {
      final index = _numericNthChildIndex(pseudo);
      final span = pseudo.span;
      if (index == null || span == null) {
        throw FormatException(
          tr("The selector has an unsupported :nth-child() expression."),
        );
      }
      final start = span.start.offset - selectorSpan.start.offset - trimOffset;
      // csslib's span can stop after the function name when preceded by
      // another pseudo-class. Match the complete validated numeric function,
      // so its argument and closing parenthesis are never left in the selector.
      if (start < 0 || start >= selectorText.length) {
        throw FormatException(
          tr("The :nth-child() source range could not be mapped."),
        );
      }
      final function = RegExp(
        r'^:nth-child\(\s*\+?([0-9]+)\s*\)',
        caseSensitive: false,
      ).firstMatch(selectorText.substring(start));
      if (function == null || int.tryParse(function.group(1)!) != index) {
        throw FormatException(
          tr("The :nth-child() source did not match its numeric AST."),
        );
      }
      final end = start + function.end;
      replacements.add(
        _SelectorRangeReplacement(
          start: start,
          end: end,
          text: '[$attribute="$index"]',
        ),
      );
    }

    var matcherSelector = selectorText;
    for (final replacement
        in replacements..sort((a, b) => b.start.compareTo(a.start))) {
      matcherSelector = matcherSelector.replaceRange(
        replacement.start,
        replacement.end,
        replacement.text,
      );
    }

    final originalAttributes = <dom.Element, String?>{};
    final root = document.nodes.whereType<dom.Element>().firstOrNull;
    final originalRootAttribute = root?.attributes[rootAttribute];
    final target = engine.fragmentTarget;
    final originalTargetAttribute = target?.attributes[targetAttribute];
    if (targets.selectors.isNotEmpty) target?.attributes[targetAttribute] = '';
    if (roots.selectors.isNotEmpty) root?.attributes[rootAttribute] = '';
    for (final element
        in collector.selectors.isEmpty
            ? const <dom.Element>[]
            : document.querySelectorAll('*')) {
      final parent = element.parentNode;
      if (parent == null) continue;
      final elementSiblings = parent.nodes.whereType<dom.Element>().toList();
      final siblingIndex = elementSiblings.indexOf(element);
      if (siblingIndex < 0) continue;
      originalAttributes[element] = element.attributes[attribute];
      element.attributes[attribute] = '${siblingIndex + 1}';
    }

    try {
      return document.querySelectorAll(matcherSelector);
    } finally {
      if (targets.selectors.isNotEmpty && target != null) {
        if (originalTargetAttribute == null) {
          target.attributes.remove(targetAttribute);
        } else {
          target.attributes[targetAttribute] = originalTargetAttribute;
        }
      }
      if (roots.selectors.isNotEmpty && root != null) {
        if (originalRootAttribute == null) {
          root.attributes.remove(rootAttribute);
        } else {
          root.attributes[rootAttribute] = originalRootAttribute;
        }
      }
      for (final entry in originalAttributes.entries) {
        final previousValue = entry.value;
        if (previousValue == null) {
          entry.key.attributes.remove(attribute);
        } else {
          entry.key.attributes[attribute] = previousValue;
        }
      }
    }
  }

  void _addInlineStyle(dom.Element element, String text) {
    final baseUrl = engine.documentBaseUrl ?? tr("inline style attribute");
    final parsed = _parseCss('* { $text }', baseUrl);
    _addParseMessages(parsed.messages, baseUrl);
    final sheet = parsed.stylesheet;
    if (sheet == null) {
      _canvasBitmapDependenciesInspectable = false;
      _textContentSelectorsInspectable = false;
      return;
    }
    if (parsed.messages.isNotEmpty) {
      _textContentSelectorsInspectable = false;
      _canvasBitmapDependenciesInspectable = false;
    }
    _inspectCanvasBitmapDependencies(sheet);
    for (final node in sheet.topLevels.whereType<css.RuleSet>()) {
      for (final declaration in node.declarationGroup.declarations) {
        if (declaration is css.Declaration) {
          _addDeclaration(
            element,
            declaration,
            baseUrl,
            _Specificity.zero,
            isInline: true,
          );
        } else {
          _diagnostics.add(
            NativeDocumentStyleDiagnostic(
              code: 'unsupported-inline-style',
              message: tr("Nested inline style constructs are not supported."),
              baseUrl: baseUrl,
            ),
          );
        }
      }
    }
  }

  void _addDeclaration(
    dom.Element element,
    css.Declaration declaration,
    String baseUrl,
    _Specificity specificity, {
    required bool isInline,
  }) {
    final sourceProperty = declaration.property;
    if (declaration.isIE7 || sourceProperty.startsWith('*')) {
      _diagnostics.add(
        NativeDocumentStyleDiagnostic(
          code: 'unsupported-property-hack',
          message: tr("Legacy IE property hacks are ignored."),
          baseUrl: baseUrl,
          property: sourceProperty,
        ),
      );
      return;
    }
    final property = sourceProperty.startsWith('--')
        ? sourceProperty
        : sourceProperty.toLowerCase();
    final expression = declaration.expression;
    if (expression == null) {
      _diagnostics.add(
        NativeDocumentStyleDiagnostic(
          code: 'invalid-declaration',
          message: tr("The declaration has no value expression."),
          baseUrl: baseUrl,
          property: property,
        ),
      );
      return;
    }

    if (property == 'scroll-behavior' && !_containsVarUsage(expression)) {
      final keyword = _expressionText(expression).trim().toLowerCase();
      if (!const {'auto', 'smooth'}.contains(keyword) &&
          !_cssWideKeywords.contains(keyword)) {
        return;
      }
    }

    if (property == 'pointer-events' && !_containsVarUsage(expression)) {
      final keyword = _expressionText(expression).trim().toLowerCase();
      if (!nativeDocumentPointerKeywords.contains(keyword) &&
          !_cssWideKeywords.contains(keyword)) {
        return;
      }
    }

    if (const {'overflow-x', 'overflow-y'}.contains(property) &&
        !_containsVarUsage(expression)) {
      final keyword = _expressionText(expression).trim().toLowerCase();
      if (!_overflowKeywords.contains(keyword) &&
          !_cssWideKeywords.contains(keyword)) {
        _diagnostics.add(
          NativeDocumentStyleDiagnostic(
            code: 'invalid-overflow-value',
            message: tr("Ignored invalid value for {0}.", [property]),
            baseUrl: baseUrl,
            property: property,
          ),
        );
        return;
      }
    }

    if ((_isFlexLonghand(property) || _isGapLonghand(property)) &&
        !_containsVarUsage(expression)) {
      final value = _expressionText(expression).trim().toLowerCase();
      if (!_cssWideKeywords.contains(value) &&
          !(_isFlexLonghand(property)
              ? _isValidFlexLonghand(property, expression)
              : _isGapValue(expression))) {
        _diagnostics.add(
          NativeDocumentStyleDiagnostic(
            code: _isFlexLonghand(property)
                ? 'invalid-flex-value'
                : 'invalid-gap-value',
            message: tr("Ignored invalid value for {0}.", [property]),
            baseUrl: baseUrl,
            property: property,
          ),
        );
        return;
      }
    }

    if (_cssColorProperties.contains(property) &&
        !_containsVarUsage(expression)) {
      final colorValues = property == 'border-color'
          ? _boxShorthandValues(expression)
          : <css.Expression>[expression];
      final colorStatus = colorValues == null
          ? _ColorValueStatus.invalid
          : colorValues
                .map(_colorValueStatus)
                .fold<_ColorValueStatus>(
                  _ColorValueStatus.valid,
                  (current, next) => switch ((current, next)) {
                    (_ColorValueStatus.invalid, _) ||
                    (_, _ColorValueStatus.invalid) => _ColorValueStatus.invalid,
                    (_ColorValueStatus.unvalidated, _) ||
                    (
                      _,
                      _ColorValueStatus.unvalidated,
                    ) => _ColorValueStatus.unvalidated,
                    _ => _ColorValueStatus.valid,
                  },
                );
      if (colorStatus == _ColorValueStatus.invalid) {
        _diagnostics.add(
          NativeDocumentStyleDiagnostic(
            code: 'invalid-color-value',
            message: tr("Ignored invalid CSS color value \"{0}\".", [
              _expressionText(expression),
            ]),
            baseUrl: baseUrl,
            property: property,
          ),
        );
        return;
      }
      if (colorStatus == _ColorValueStatus.unvalidated) {
        _diagnostics.add(
          NativeDocumentStyleDiagnostic(
            code: 'unvalidated-color-value',
            message: tr(
              "The CSS color function is passed through without validation.",
            ),
            baseUrl: baseUrl,
            property: property,
          ),
        );
      }
    }

    final order = _order++;
    if (const {'flex', 'flex-flow', 'gap', 'overflow'}.contains(property)) {
      if (_containsVarUsage(expression)) {
        // Its grammar can only be checked after var() substitution, so retain
        // the authored declaration until the element's custom-property scope
        // is available. The shorthand key is removed before style emission.
        _offer(
          element,
          property,
          _Candidate(
            valueExpression: expression,
            value: _expressionText(expression),
            important: declaration.important,
            isInline: isInline,
            specificity: specificity,
            order: order,
            suborder: 0,
            baseUrl: baseUrl,
          ),
        );
        return;
      }
      final expansion = switch (property) {
        'gap' => _parseGapShorthand(expression),
        'overflow' => _parseOverflowShorthand(expression),
        _ => _parseFlexShorthand(property, expression),
      };
      if (expansion == null) {
        _diagnostics.add(
          NativeDocumentStyleDiagnostic(
            code: 'unsupported-shorthand',
            message: property == 'overflow'
                ? tr(
                    "The overflow shorthand requires one or two supported overflow keywords.",
                  )
                : property == 'gap'
                ? tr(
                    "The gap shorthand must use one or two supported nonnegative length or percentage values, or normal.",
                  )
                : _invalidFlexShorthandMessage(property),
            baseUrl: baseUrl,
            property: property,
          ),
        );
        return;
      }
      _offerExpandedShorthand(
        _winners.putIfAbsent(element, () => {}),
        expansion,
        _Candidate(
          valueExpression: null,
          value: '',
          important: declaration.important,
          isInline: isInline,
          specificity: specificity,
          order: order,
          suborder: 0,
          baseUrl: baseUrl,
        ),
      );
      return;
    }
    final expansion = _supportedBoxShorthands[property];
    if (expansion != null) {
      final values = _boxShorthandValues(expression);
      if (values == null &&
          const {'scroll-margin', 'scroll-padding'}.contains(property)) {
        for (var index = 0; index < expansion.length; index++) {
          _offer(
            element,
            expansion[index],
            _Candidate(
              valueExpression: expression,
              value: _expressionText(expression),
              important: declaration.important,
              isInline: isInline,
              specificity: specificity,
              order: order,
              suborder: index,
              baseUrl: baseUrl,
            ),
          );
        }
        return;
      }
      if (values == null) {
        _preserveInlineShorthand(
          element,
          property,
          expression,
          declaration.important,
          order,
          isInline,
        );
        _diagnostics.add(
          NativeDocumentStyleDiagnostic(
            code: 'unsupported-shorthand',
            message: tr(
              "Could not expand this 1-to-4 component value without changing its meaning.",
            ),
            baseUrl: baseUrl,
            property: property,
          ),
        );
        return;
      }
      final expanded = _expandFourSides(values);
      for (var index = 0; index < expansion.length; index++) {
        _offer(
          element,
          expansion[index],
          _Candidate(
            valueExpression: values[_fourSideValueIndex(values.length, index)],
            value: expanded[index],
            important: declaration.important,
            isInline: isInline,
            specificity: specificity,
            order: order,
            suborder: index,
            baseUrl: baseUrl,
          ),
        );
      }
      return;
    }
    if (property == 'border' || _borderSideShorthands.containsKey(property)) {
      final components = _borderComponents(expression, baseUrl, property);
      if (components == null) {
        _preserveInlineShorthand(
          element,
          property,
          expression,
          declaration.important,
          order,
          isInline,
        );
        _diagnostics.add(
          NativeDocumentStyleDiagnostic(
            code: 'unsupported-shorthand',
            message: tr(
              "Could not safely expand the border width, style, and color components.",
            ),
            baseUrl: baseUrl,
            property: property,
          ),
        );
        return;
      }
      final targets = property == 'border'
          ? [
              for (final side in _borderSides)
                for (final kind in _borderKinds) 'border-$side-$kind',
            ]
          : _borderSideShorthands[property]!;
      for (var index = 0; index < targets.length; index++) {
        final target = targets[index];
        final kind = target.substring(target.lastIndexOf('-') + 1);
        final component = components[kind];
        _offer(
          element,
          target,
          _Candidate(
            valueExpression: component,
            value: component == null
                ? _defaultBorderValues[kind]!
                : _expressionText(component),
            important: declaration.important,
            isInline: isInline,
            specificity: specificity,
            order: order,
            suborder: index,
            baseUrl: baseUrl,
          ),
        );
      }
      if (property == 'border') {
        final keyword = _expressionText(expression).toLowerCase();
        final cssWide = _cssWideKeywords.contains(keyword);
        for (final (index, entry)
            in _initialBorderImageValues.entries.indexed) {
          _offer(
            element,
            entry.key,
            _Candidate(
              valueExpression: cssWide ? expression : null,
              value: cssWide ? keyword : entry.value,
              important: declaration.important,
              isInline: isInline,
              specificity: specificity,
              order: order,
              suborder: targets.length + index,
              baseUrl: baseUrl,
            ),
          );
        }
      }
      return;
    }
    if (property == 'font') {
      final keyword = _expressionText(expression).toLowerCase();
      if (_cssWideKeywords.contains(keyword) &&
          _boxShorthandValues(expression)?.length == 1) {
        for (var index = 0; index < _fontInheritanceLonghands.length; index++) {
          final longhand = _fontInheritanceLonghands[index];
          _offer(
            element,
            longhand,
            _Candidate(
              valueExpression: expression,
              value: keyword,
              important: declaration.important,
              isInline: isInline,
              specificity: specificity,
              order: order,
              suborder: index,
              baseUrl: baseUrl,
            ),
          );
        }
        return;
      }

      final parsed = _parseFontShorthand(expression);
      if (parsed == null) {
        _diagnostics.add(
          NativeDocumentStyleDiagnostic(
            code: 'unsupported-shorthand',
            message: tr(
              "This font shorthand is invalid or outside the supported CSS font grammar.",
            ),
            baseUrl: baseUrl,
            property: property,
          ),
        );
        return;
      }

      for (var index = 0; index < _fontInheritanceLonghands.length; index++) {
        final longhand = _fontInheritanceLonghands[index];
        final value = parsed.values[longhand] ?? _fontInitialValues[longhand];
        if (value == null) continue;
        _offer(
          element,
          longhand,
          _Candidate(
            valueExpression: parsed.expressions[longhand],
            value: value,
            important: declaration.important,
            isInline: isInline,
            specificity: specificity,
            order: order,
            suborder: index,
            baseUrl: baseUrl,
          ),
        );
      }
      return;
    }
    if (property == 'grid-column' || property == 'grid-row') {
      final parts = _gridPlacementParts(expression);
      if (parts == null) {
        _preserveInlineShorthand(
          element,
          property,
          expression,
          declaration.important,
          order,
          isInline,
        );
        _diagnostics.add(
          NativeDocumentStyleDiagnostic(
            code: 'unsupported-shorthand',
            message: tr(
              "The {0} shorthand must use auto, a nonzero integer line, or span with a positive integer.",
              [property],
            ),
            baseUrl: baseUrl,
            property: property,
          ),
        );
        return;
      }
      final longhandPrefix = property;
      final candidates = <(String, _GridPlacementValue)>[
        ('$longhandPrefix-start', parts.start),
        ('$longhandPrefix-end', parts.end),
      ];
      for (var index = 0; index < candidates.length; index++) {
        final (longhand, component) = candidates[index];
        _offer(
          element,
          longhand,
          _Candidate(
            valueExpression: component.expression,
            value: component.value,
            important: declaration.important,
            isInline: isInline,
            specificity: specificity,
            order: order,
            suborder: index,
            baseUrl: baseUrl,
          ),
        );
      }
      return;
    }
    if (property == 'border-radius') {
      final radii = _borderRadiusValues(expression);
      if (radii == null) {
        _diagnostics.add(
          NativeDocumentStyleDiagnostic(
            code: 'unsupported-shorthand',
            message: tr(
              "The border-radius shorthand must use one to four supported nonnegative lengths on each side of at most one slash.",
            ),
            baseUrl: baseUrl,
            property: property,
          ),
        );
        return;
      }
      const cornerProperties = <String>[
        'border-top-left-radius',
        'border-top-right-radius',
        'border-bottom-right-radius',
        'border-bottom-left-radius',
      ];
      for (var index = 0; index < cornerProperties.length; index++) {
        final radius = radii[index];
        _offer(
          element,
          cornerProperties[index],
          _Candidate(
            valueExpression: radius.expression,
            value: radius.value,
            important: declaration.important,
            isInline: isInline,
            specificity: specificity,
            order: order,
            suborder: index,
            baseUrl: baseUrl,
          ),
        );
      }
      return;
    }
    if (property == 'background') {
      final group = Object();
      _offer(
        element,
        property,
        _Candidate(
          valueExpression: expression,
          value: _expressionText(expression),
          important: declaration.important,
          isInline: isInline,
          specificity: specificity,
          order: order,
          suborder: 0,
          baseUrl: baseUrl,
          backgroundGroup: group,
        ),
      );
      const components = <(String, String)>[
        ('background-image', 'image'),
        ('background-color', 'color'),
        ('background-position', 'position'),
        ('background-size', 'size'),
        ('background-repeat', 'repeat'),
        ('background-attachment', 'attachment'),
        ('background-origin', 'origin'),
        ('background-clip', 'clip'),
      ];
      for (var index = 0; index < components.length; index++) {
        final (longhand, component) = components[index];
        _offer(
          element,
          longhand,
          _Candidate(
            valueExpression: expression,
            value: _expressionText(expression),
            important: declaration.important,
            isInline: isInline,
            specificity: specificity,
            order: order,
            suborder: index + 1,
            baseUrl: baseUrl,
            backgroundGroup: group,
            backgroundComponent: component,
          ),
        );
      }
      return;
    }
    if (property == 'background-image') {
      _offer(
        element,
        property,
        _Candidate(
          valueExpression: expression,
          value: _expressionText(expression),
          important: declaration.important,
          isInline: isInline,
          specificity: specificity,
          order: order,
          suborder: 0,
          baseUrl: baseUrl,
        ),
      );
      return;
    }
    if (_unsupportedShorthands.contains(property)) {
      _preserveInlineShorthand(
        element,
        property,
        expression,
        declaration.important,
        order,
        isInline,
      );
      _diagnostics.add(
        NativeDocumentStyleDiagnostic(
          code: 'unsupported-shorthand',
          message: tr(
            "The {0} shorthand is not expanded; it was not applied.",
            [property],
          ),
          baseUrl: baseUrl,
          property: property,
        ),
      );
      return;
    }

    _offer(
      element,
      property,
      _Candidate(
        valueExpression: expression,
        value: _expressionText(expression),
        important: declaration.important,
        isInline: isInline,
        specificity: specificity,
        order: order,
        suborder: 0,
        baseUrl: baseUrl,
      ),
    );
  }

  Map<String, ({String value, css.Expression? expression})>?
  _parseFlexShorthand(String shorthand, css.Expression expression) {
    final terms = expression is css.Expressions
        ? expression.expressions
        : <css.Expression>[expression];
    if (terms.isEmpty ||
        terms.any(
          (term) => term is css.OperatorComma || term is css.OperatorSlash,
        )) {
      return null;
    }

    final keyword = terms.length == 1
        ? _expressionText(terms.single).trim().toLowerCase()
        : '';
    if (shorthand == 'flex') {
      switch (keyword) {
        case 'none':
          return _flexExpansion(grow: '0', shrink: '0', basis: 'auto');
        case 'auto':
          return _flexExpansion(grow: '1', shrink: '1', basis: 'auto');
        case 'initial':
          return _flexExpansion(grow: '0', shrink: '1', basis: 'auto');
      }

      final factors = <css.Expression>[];
      css.Expression? basis;
      for (final term in terms) {
        if (_isFlexFactor(term) &&
            !(factors.length == 2 && basis == null && _isFlexBasis(term))) {
          factors.add(term);
        } else if (basis == null && _isFlexBasis(term)) {
          basis = term;
        } else {
          return null;
        }
      }
      if (factors.isEmpty) {
        if (basis == null || terms.length != 1) return null;
        return _flexExpansion(
          grow: '1',
          shrink: '1',
          basis: _expressionText(basis),
          basisExpression: basis,
        );
      }
      if (factors.length > 2) return null;
      if (basis == null && factors.length == 1) {
        return _flexExpansion(
          grow: _expressionText(factors[0]),
          shrink: '1',
          basis: '0%',
          growExpression: factors[0],
        );
      }
      if (basis == null && factors.length == 2) {
        return _flexExpansion(
          grow: _expressionText(factors[0]),
          shrink: _expressionText(factors[1]),
          basis: '0%',
          growExpression: factors[0],
          shrinkExpression: factors[1],
        );
      }
      return _flexExpansion(
        grow: _expressionText(factors[0]),
        shrink: factors.length == 2 ? _expressionText(factors[1]) : '1',
        basis: _expressionText(basis!),
        growExpression: factors[0],
        shrinkExpression: factors.length == 2 ? factors[1] : null,
        basisExpression: basis,
      );
    }

    if (shorthand != 'flex-flow') return null;
    if (keyword == 'initial') return _initialFlexExpansion('flex-flow');

    const directions = {'row', 'row-reverse', 'column', 'column-reverse'};
    const wraps = {'nowrap', 'wrap', 'wrap-reverse'};
    var direction = 'row';
    var wrap = 'nowrap';
    css.Expression? directionExpression;
    css.Expression? wrapExpression;
    for (final term in terms) {
      if (term is! css.LiteralTerm || term is css.FunctionTerm) return null;
      final value = _expressionText(term).trim().toLowerCase();
      if (directions.contains(value) && directionExpression == null) {
        direction = value;
        directionExpression = term;
      } else if (wraps.contains(value) && wrapExpression == null) {
        wrap = value;
        wrapExpression = term;
      } else {
        return null;
      }
    }
    return _flexFlowExpansion(
      direction: direction,
      wrap: wrap,
      directionExpression: directionExpression,
      wrapExpression: wrapExpression,
    );
  }

  Map<String, ({String value, css.Expression? expression})> _flexExpansion({
    required String grow,
    required String shrink,
    required String basis,
    css.Expression? growExpression,
    css.Expression? shrinkExpression,
    css.Expression? basisExpression,
  }) => {
    'flex-grow': (value: grow, expression: growExpression),
    'flex-shrink': (value: shrink, expression: shrinkExpression),
    'flex-basis': (value: basis, expression: basisExpression),
  };

  Map<String, ({String value, css.Expression? expression})> _flexFlowExpansion({
    required String direction,
    required String wrap,
    css.Expression? directionExpression,
    css.Expression? wrapExpression,
  }) => {
    'flex-direction': (value: direction, expression: directionExpression),
    'flex-wrap': (value: wrap, expression: wrapExpression),
  };

  static const _overflowKeywords = {
    'visible',
    'hidden',
    'clip',
    'scroll',
    'auto',
  };

  Map<String, ({String value, css.Expression? expression})>?
  _parseOverflowShorthand(css.Expression expression) {
    final terms = expression is css.Expressions
        ? expression.expressions
        : <css.Expression>[expression];
    final values = terms
        .map((term) => _expressionText(term).trim().toLowerCase())
        .toList();
    if (values.length == 1 &&
        const {'initial', 'unset', 'inherit'}.contains(values.single)) {
      final value = values.single == 'inherit' ? 'inherit' : 'visible';
      return {
        'overflow-x': (value: value, expression: null),
        'overflow-y': (value: value, expression: null),
      };
    }
    if (values.isEmpty ||
        values.length > 2 ||
        values.any((value) => !_overflowKeywords.contains(value))) {
      return null;
    }
    return {
      'overflow-x': (value: values.first, expression: null),
      'overflow-y': (
        value: values.length == 1 ? values.first : values[1],
        expression: null,
      ),
    };
  }

  Map<String, ({String value, css.Expression? expression})>? _parseGapShorthand(
    css.Expression expression,
  ) {
    final terms = expression is css.Expressions
        ? expression.expressions
        : <css.Expression>[expression];
    if (terms.isEmpty ||
        terms.length > 2 ||
        terms.any(
          (term) => term is css.OperatorComma || term is css.OperatorSlash,
        ) ||
        terms.any((term) => !_isGapValue(term))) {
      return null;
    }
    final first = terms.first;
    final second = terms.length == 1 ? first : terms[1];
    return {
      'row-gap': (value: _expressionText(first), expression: first),
      'column-gap': (value: _expressionText(second), expression: second),
    };
  }

  Map<String, ({String value, css.Expression? expression})>
  _gapInitialExpansion() => {
    'row-gap': (value: 'normal', expression: null),
    'column-gap': (value: 'normal', expression: null),
  };

  Map<String, ({String value, css.Expression? expression})>
  _initialShorthandExpansion(String shorthand) => shorthand == 'overflow'
      ? {
          'overflow-x': (value: 'visible', expression: null),
          'overflow-y': (value: 'visible', expression: null),
        }
      : shorthand == 'gap'
      ? _gapInitialExpansion()
      : _initialFlexExpansion(shorthand);

  bool _isGapLonghand(String property) =>
      property == 'row-gap' || property == 'column-gap';

  bool _isGapValue(css.Expression expression) {
    final terms = expression is css.Expressions
        ? expression.expressions
        : <css.Expression>[expression];
    if (terms.length != 1) return false;
    final term = terms.single;
    if (term is css.LiteralTerm &&
        term is! css.FunctionTerm &&
        _expressionText(term).trim().toLowerCase() == 'normal') {
      return true;
    }
    if (term is css.PercentageTerm && term.value is num) {
      final value = (term.value as num).toDouble();
      return value.isFinite && value >= 0;
    }
    if (term is css.UnitTerm && term.value is num) {
      final value = (term.value as num).toDouble();
      return value.isFinite &&
          value >= 0 &&
          _flexBasisLengthUnits.contains(term.unitToString()?.toLowerCase());
    }
    if (term is css.EmTerm) {
      final value = double.tryParse('${term.value}');
      return value != null && value.isFinite && value >= 0;
    }
    if (term is css.ExTerm) {
      final value = double.tryParse('${term.value}');
      return value != null && value.isFinite && value >= 0;
    }
    if (term is css.NumberTerm && term.value is num) {
      return (term.value as num) == 0;
    }
    return false;
  }

  Map<String, ({String value, css.Expression? expression})>
  _initialFlexExpansion(String shorthand) => shorthand == 'flex'
      ? _flexExpansion(grow: '0', shrink: '1', basis: 'auto')
      : _flexFlowExpansion(direction: 'row', wrap: 'nowrap');

  bool _isFlexFactor(css.Expression expression) =>
      expression is css.NumberTerm &&
      expression.value is num &&
      (expression.value as num).isFinite &&
      (expression.value as num) >= 0;

  bool _isFlexBasis(css.Expression expression) {
    if (expression is css.PercentageTerm && expression.value is num) {
      final value = (expression.value as num).toDouble();
      return value.isFinite && value >= 0;
    }
    if (expression is css.UnitTerm && expression.value is num) {
      final value = (expression.value as num).toDouble();
      return value.isFinite &&
          value >= 0 &&
          _flexBasisLengthUnits.contains(
            expression.unitToString()?.toLowerCase(),
          );
    }
    if ((expression is css.EmTerm ||
            expression is css.ExTerm ||
            expression is css.RemTerm) &&
        expression is css.LiteralTerm &&
        expression.value is num) {
      final value = (expression.value as num).toDouble();
      return value.isFinite && value >= 0;
    }
    if (expression is css.NumberTerm && expression.value is num) {
      final value = (expression.value as num).toDouble();
      return value == 0;
    }
    if (expression is! css.LiteralTerm) return false;
    return const {
      'auto',
      'content',
      'fit-content',
      'max-content',
      'min-content',
    }.contains(_expressionText(expression).trim().toLowerCase());
  }

  bool _isFlexLonghand(String property) => const {
    'flex-grow',
    'flex-shrink',
    'flex-basis',
    'flex-direction',
    'flex-wrap',
  }.contains(property);

  bool _isValidFlexLonghand(String property, css.Expression expression) {
    final terms = expression is css.Expressions
        ? expression.expressions
        : <css.Expression>[expression];
    if (terms.length != 1) return false;
    final term = terms.single;
    switch (property) {
      case 'flex-grow':
      case 'flex-shrink':
        return _isFlexFactor(term);
      case 'flex-basis':
        return _isFlexBasis(term);
      case 'flex-direction':
        return term is css.LiteralTerm &&
            term is! css.FunctionTerm &&
            const {
              'row',
              'row-reverse',
              'column',
              'column-reverse',
            }.contains(_expressionText(term).trim().toLowerCase());
      case 'flex-wrap':
        return term is css.LiteralTerm &&
            term is! css.FunctionTerm &&
            const {
              'nowrap',
              'wrap',
              'wrap-reverse',
            }.contains(_expressionText(term).trim().toLowerCase());
      default:
        return true;
    }
  }

  String _invalidFlexShorthandMessage(String property) => property == 'flex'
      ? tr(
          "The flex shorthand must use none, auto, initial, or one to three supported nonnegative flex factors and basis values.",
        )
      : tr(
          "The flex-flow shorthand must use at most one direction and one wrap value.",
        );

  css.Expression? _parseResolvedShorthandExpression(
    String property,
    String value,
    String baseUrl,
  ) {
    if (value.trim().isEmpty) return null;
    final parsed = _parseCss('* { $property: $value; }', baseUrl);
    _addParseMessages(parsed.messages, baseUrl);
    final rules = parsed.stylesheet?.topLevels.whereType<css.RuleSet>();
    if (rules == null) return null;
    final declarations = [
      for (final rule in rules)
        for (final declaration in rule.declarationGroup.declarations)
          if (declaration is css.Declaration &&
              declaration.property.toLowerCase() == property)
            declaration,
    ];
    return declarations.length == 1 ? declarations.single.expression : null;
  }

  void _offerExpandedShorthand(
    Map<String, _Candidate> winners,
    Map<String, ({String value, css.Expression? expression})> expansion,
    _Candidate shorthand,
  ) {
    var suborder = 0;
    for (final entry in expansion.entries) {
      final candidate = _Candidate(
        valueExpression: entry.value.expression,
        value: entry.value.value,
        important: shorthand.important,
        isInline: shorthand.isInline,
        specificity: shorthand.specificity,
        order: shorthand.order,
        suborder: suborder++,
        baseUrl: shorthand.baseUrl,
      );
      final current = winners[entry.key];
      if (current == null || candidate.outranks(current)) {
        winners[entry.key] = candidate;
      }
    }
  }

  _ParsedFontShorthand? _parseFontShorthand(css.Expression expression) {
    if (_containsVarUsage(expression)) return null;
    final terms = expression is css.Expressions
        ? expression.expressions
        : <css.Expression>[expression];
    if (terms.isEmpty) return null;

    final authoredValues = <String, String>{};
    final authoredExpressions = <String, css.Expression>{};
    var optionalCount = 0;
    var fontSizeIndex = -1;
    for (var index = 0; index < terms.length; index++) {
      final term = terms[index];
      if (term is css.OperatorSlash || term is css.OperatorComma) return null;
      if (_isFontSizeTerm(term)) {
        fontSizeIndex = index;
        break;
      }

      final text = _expressionText(term).trim();
      final keyword = text.toLowerCase();
      if (keyword == 'normal') {
        // `normal` can fill any unset optional slot; their initial values are
        // already normal, so only the number of occupied slots matters here.
        optionalCount++;
        if (optionalCount > 4) return null;
        continue;
      }
      if (keyword == 'italic' || keyword == 'oblique') {
        if (authoredValues.containsKey('font-style')) return null;
        var styleExpression = term;
        var styleValue = text;
        if (keyword == 'oblique' &&
            index + 1 < terms.length &&
            terms[index + 1] is css.AngleTerm) {
          final angle = terms[++index];
          styleExpression = css.Expressions(expression.span)
            ..expressions.addAll([term, angle]);
          styleValue = _expressionText(styleExpression);
        }
        authoredValues['font-style'] = styleValue;
        authoredExpressions['font-style'] = styleExpression;
        optionalCount++;
        if (optionalCount > 4) return null;
        continue;
      }
      if (keyword == 'small-caps') {
        if (authoredValues.containsKey('font-variant')) return null;
        authoredValues['font-variant'] = 'small-caps';
        authoredExpressions['font-variant'] = term;
        authoredValues['font-variant-caps'] = 'small-caps';
        authoredExpressions['font-variant-caps'] = term;
        optionalCount++;
        if (optionalCount > 4) return null;
        continue;
      }
      if (const {'bold', 'bolder', 'lighter'}.contains(keyword) ||
          _isNumericFontWeight(term)) {
        if (authoredValues.containsKey('font-weight')) return null;
        authoredValues['font-weight'] = text;
        authoredExpressions['font-weight'] = term;
        optionalCount++;
        if (optionalCount > 4) return null;
        continue;
      }
      if (_fontStretchKeywords.contains(keyword)) {
        if (authoredValues.containsKey('font-stretch')) return null;
        authoredValues['font-stretch'] = text;
        authoredExpressions['font-stretch'] = term;
        optionalCount++;
        if (optionalCount > 4) return null;
        continue;
      }
      return null;
    }

    if (fontSizeIndex < 0) return null;
    final fontSize = terms[fontSizeIndex];
    authoredValues['font-size'] = _expressionText(fontSize);
    authoredExpressions['font-size'] = fontSize;

    var familyIndex = fontSizeIndex + 1;
    var lineHeight = 'normal';
    css.Expression? lineHeightExpression;
    if (familyIndex < terms.length && terms[familyIndex] is css.OperatorSlash) {
      familyIndex++;
      if (familyIndex >= terms.length ||
          !_isFontLineHeightTerm(terms[familyIndex])) {
        return null;
      }
      lineHeightExpression = terms[familyIndex];
      lineHeight = _expressionText(lineHeightExpression);
      familyIndex++;
    }
    if (familyIndex >= terms.length) return null;

    final familyTerms = terms.sublist(familyIndex);
    if (!_validFontFamilyTerms(familyTerms)) return null;
    final printableFamilyTerms = familyTerms.map((term) {
      if (term is css.HexColorTerm) {
        final source = term.span?.text.trim() ?? '';
        return css.LiteralTerm(
          css.Identifier(source, term.span),
          source,
          term.span,
        );
      }
      return term;
    });
    final familyExpression = css.Expressions(expression.span)
      ..expressions.addAll(printableFamilyTerms);
    authoredValues['font-family'] = _expressionText(familyExpression);
    authoredExpressions['font-family'] = familyExpression;
    authoredValues['line-height'] = lineHeight;
    if (lineHeightExpression != null) {
      authoredExpressions['line-height'] = lineHeightExpression;
    }

    return _ParsedFontShorthand(authoredValues, authoredExpressions);
  }

  bool _isFontSizeTerm(css.Expression term) {
    final text = _expressionText(term).toLowerCase();
    if (_fontSizeKeywords.contains(text)) return true;
    if (term is css.PercentageTerm && term.value is num) return true;
    if ((term is css.EmTerm || term is css.ExTerm || term is css.CalcTerm) &&
        term is css.LiteralTerm) {
      return true;
    }
    if (term is css.UnitTerm) {
      return _fontLengthUnits.contains(term.unitToString()?.toLowerCase());
    }
    return term is css.NumberTerm && term.value is num && term.value == 0;
  }

  bool _isFontLineHeightTerm(css.Expression term) {
    final text = _expressionText(term).toLowerCase();
    if (text == 'normal') return true;
    if (term is css.PercentageTerm && term.value is num) {
      return (term.value as num) >= 0;
    }
    if (term is css.NumberTerm && term.value is num) {
      return (term.value as num) >= 0;
    }
    if ((term is css.EmTerm || term is css.ExTerm || term is css.CalcTerm) &&
        term is css.LiteralTerm) {
      return true;
    }
    if (term is css.UnitTerm) {
      return _fontLengthUnits.contains(term.unitToString()?.toLowerCase());
    }
    return false;
  }

  bool _isNumericFontWeight(css.Expression term) =>
      term is css.NumberTerm &&
      term.value is num &&
      (term.value as num) >= 1 &&
      (term.value as num) <= 1000;

  bool _validFontFamilyTerms(List<css.Expression> terms) {
    var partsSinceComma = 0;
    for (final term in terms) {
      if (term is css.OperatorComma) {
        if (partsSinceComma == 0) return false;
        partsSinceComma = 0;
        continue;
      }
      final isColorNamedFamily =
          term is css.HexColorTerm &&
          term.value is! css.BAD_HEX_VALUE &&
          !(term.span?.text.trim().startsWith('#') ?? false);
      if ((!isColorNamedFamily && term is! css.LiteralTerm) ||
          term is css.FunctionTerm ||
          term is css.UnitTerm ||
          term is css.PercentageTerm ||
          term is css.NumberTerm ||
          (term is css.HexColorTerm && !isColorNamedFamily) ||
          term is css.UriTerm ||
          term is css.CalcTerm) {
        return false;
      }
      final text =
          (isColorNamedFamily ? term.span?.text : _expressionText(term))
              ?.trim() ??
          '';
      if (text.isEmpty) return false;
      final quoted =
          (text.startsWith('"') && text.endsWith('"')) ||
          (text.startsWith("'") && text.endsWith("'"));
      if (!quoted &&
          term is css.LiteralTerm &&
          term.value is css.Identifier &&
          _reservedFontFamilyWords.contains(text.toLowerCase())) {
        return false;
      }
      partsSinceComma++;
    }
    return partsSinceComma > 0;
  }

  _GridPlacementParts? _gridPlacementParts(css.Expression expression) {
    if (_containsVarUsage(expression)) return null;
    final terms = expression is css.Expressions
        ? expression.expressions
        : <css.Expression>[expression];
    if (terms.isEmpty) return null;

    final keyword = _expressionText(expression).trim().toLowerCase();
    if (_cssWideKeywords.contains(keyword) && terms.length == 1) {
      final same = _GridPlacementValue(expression: expression, value: keyword);
      return _GridPlacementParts(start: same, end: same);
    }

    final slashIndices = <int>[
      for (var index = 0; index < terms.length; index++)
        if (terms[index] is css.OperatorSlash) index,
    ];
    if (slashIndices.length > 1) return null;

    final slashIndex = slashIndices.isEmpty ? -1 : slashIndices.single;
    final startTerms = slashIndex < 0 ? terms : terms.sublist(0, slashIndex);
    final endTerms = slashIndex < 0
        ? const <css.Expression>[]
        : terms.sublist(slashIndex + 1);
    if (startTerms.isEmpty || (slashIndex >= 0 && endTerms.isEmpty)) {
      return null;
    }

    final startExpression = _gridLineExpression(startTerms);
    if (startExpression == null || !_isGridLine(startTerms)) return null;
    if (slashIndex < 0) {
      return _GridPlacementParts(
        start: _GridPlacementValue(
          expression: startExpression,
          value: _expressionText(startExpression),
        ),
        end: const _GridPlacementValue(value: 'auto'),
      );
    }

    final endExpression = _gridLineExpression(endTerms);
    if (endExpression == null || !_isGridLine(endTerms)) return null;
    return _GridPlacementParts(
      start: _GridPlacementValue(
        expression: startExpression,
        value: _expressionText(startExpression),
      ),
      end: _GridPlacementValue(
        expression: endExpression,
        value: _expressionText(endExpression),
      ),
    );
  }

  css.Expression? _gridLineExpression(List<css.Expression> terms) {
    if (terms.isEmpty) return null;
    if (terms.length == 1) return terms.single;
    final expression = css.Expressions(terms.first.span)
      ..expressions.addAll(terms);
    return expression;
  }

  bool _isGridLine(List<css.Expression> terms) {
    if (terms.length == 1) {
      final term = terms.single;
      final text = _expressionText(term).trim().toLowerCase();
      if (text == 'auto') return true;
      return _isGridInteger(term, allowZero: false);
    }
    if (terms.length == 2) {
      final word = _expressionText(terms[0]).trim().toLowerCase();
      return word == 'span' &&
          _isGridInteger(terms[1], allowZero: false, positiveOnly: true);
    }
    return false;
  }

  bool _isGridInteger(
    css.Expression term, {
    required bool allowZero,
    bool positiveOnly = false,
  }) {
    if (term is! css.NumberTerm || term.value is! num) return false;
    final value = term.value as num;
    final doubleValue = value.toDouble();
    if (!doubleValue.isFinite ||
        doubleValue != doubleValue.truncateToDouble()) {
      return false;
    }
    if (positiveOnly) return value > 0;
    return allowZero || value != 0;
  }

  List<_BorderRadiusValue>? _borderRadiusValues(css.Expression expression) {
    // Variable substitution can change the shorthand's token count and slash
    // placement, so it must be resolved before this expansion to preserve the
    // shorthand's CSS grammar. This engine resolves custom properties after
    // cascade selection and therefore reports such shorthands as unsupported.
    if (_containsVarUsage(expression)) return null;
    final allTerms = expression is css.Expressions
        ? expression.expressions
        : <css.Expression>[expression];
    if (allTerms.isEmpty) return null;

    if (allTerms.length == 1 &&
        _cssWideKeywords.contains(_expressionText(expression).toLowerCase())) {
      final value = _expressionText(expression);
      return List<_BorderRadiusValue>.filled(
        4,
        _BorderRadiusValue(expression: expression, value: value),
      );
    }

    final groups = <List<css.Expression>>[[]];
    for (final term in allTerms) {
      if (term is css.OperatorSlash) {
        if (groups.length == 2) return null;
        groups.add([]);
      } else {
        groups.last.add(term);
      }
    }
    final horizontal = _expandedRadiusList(groups.first);
    if (horizontal == null) return null;
    final vertical = groups.length == 1
        ? horizontal
        : _expandedRadiusList(groups.last);
    if (vertical == null) return null;

    return [
      for (var index = 0; index < 4; index++)
        _BorderRadiusValue(
          expression: groups.length == 1
              ? horizontal[index].expression
              : _pairExpressions(horizontal[index], vertical[index]),
          value: groups.length == 1
              ? horizontal[index].value
              : '${horizontal[index].value} ${vertical[index].value}',
        ),
    ];
  }

  List<_BorderRadiusValue>? _expandedRadiusList(List<css.Expression> terms) {
    if (terms.isEmpty || terms.length > 4) return null;
    for (final term in terms) {
      if (!_isSupportedRadiusLength(term)) return null;
    }
    final expressions = <css.Expression>[
      for (var index = 0; index < 4; index++)
        terms[_fourSideValueIndex(terms.length, index)],
    ];
    return [
      for (final term in expressions)
        _BorderRadiusValue(expression: term, value: _expressionText(term)),
    ];
  }

  css.Expression _pairExpressions(
    _BorderRadiusValue horizontal,
    _BorderRadiusValue vertical,
  ) {
    final expression = css.Expressions(
      horizontal.expression?.span ?? vertical.expression?.span,
    );
    if (horizontal.expression != null) {
      expression.expressions.add(horizontal.expression!);
    }
    if (vertical.expression != null) {
      expression.expressions.add(vertical.expression!);
    }
    return expression;
  }

  bool _isSupportedRadiusLength(css.Expression term) {
    if (term is css.PercentageTerm && term.value is num) {
      return (term.value as num) >= 0;
    }
    if ((term is css.EmTerm || term is css.RemTerm) &&
        term is css.LiteralTerm &&
        term.value is num) {
      return (term.value as num) >= 0;
    }
    if (term is css.UnitTerm && term.value is num) {
      final unit = term.unitToString()?.toLowerCase();
      const units = {'px', 'in', 'cm', 'mm', 'pt', 'pc'};
      return units.contains(unit) && (term.value as num) >= 0;
    }
    return term is css.NumberTerm && term.value is num && term.value == 0;
  }

  void _preserveInlineShorthand(
    dom.Element element,
    String property,
    css.Expression expression,
    bool important,
    int order,
    bool isInline,
  ) {
    if (!isInline) return;
    final value = _expressionText(expression);
    if (value.isEmpty) return;
    _preservedInline
        .putIfAbsent(element, () => [])
        .add(
          _PreservedInlineDeclaration(
            property: property,
            value: value,
            important: important,
            order: order,
          ),
        );
  }

  Map<String, css.Expression?>? _borderComponents(
    css.Expression expression,
    String baseUrl,
    String property,
  ) {
    final terms = expression is css.Expressions
        ? expression.expressions
        : <css.Expression>[expression];
    if (terms.length == 1 &&
        _cssWideKeywords.contains(
          _expressionText(terms.single).toLowerCase(),
        )) {
      return {for (final kind in _borderKinds) kind: terms.single};
    }
    if (terms.isEmpty || terms.length > 3) return null;
    final components = <String, css.Expression?>{
      'width': null,
      'style': null,
      'color': null,
    };
    for (final term in terms) {
      final kind = _borderComponentKind(term);
      if (kind == null || components[kind] != null) {
        _diagnostics.add(
          NativeDocumentStyleDiagnostic(
            code: 'invalid-border-component',
            message: tr(
              "The border shorthand contains an unsupported or repeated component.",
            ),
            baseUrl: baseUrl,
            property: property,
          ),
        );
        return null;
      }
      if (kind == 'color' &&
          _colorValueStatus(term) == _ColorValueStatus.invalid) {
        _diagnostics.add(
          NativeDocumentStyleDiagnostic(
            code: 'invalid-color-value',
            message: tr("The border shorthand has an invalid color component."),
            baseUrl: baseUrl,
            property: property,
          ),
        );
        return null;
      }
      if (kind == 'color' &&
          _colorValueStatus(term) == _ColorValueStatus.unvalidated) {
        _diagnostics.add(
          NativeDocumentStyleDiagnostic(
            code: 'unvalidated-color-value',
            message: tr(
              "The CSS color function is passed through without validation.",
            ),
            baseUrl: baseUrl,
            property: property,
          ),
        );
      }
      components[kind] = term;
    }
    return components;
  }

  String? _borderComponentKind(css.Expression expression) {
    if (_containsVarUsage(expression)) return null;
    final term =
        expression is css.Expressions && expression.expressions.length == 1
        ? expression.expressions.single
        : expression;
    if (term is css.UnitTerm) {
      const lengthUnits = {
        'px',
        'em',
        'ex',
        'ch',
        'rem',
        'lh',
        'rlh',
        'vw',
        'vh',
        'vmin',
        'vmax',
        'cm',
        'mm',
        'in',
        'pt',
        'pc',
      };
      final unit = term.unitToString()?.toLowerCase();
      if (lengthUnits.contains(unit) &&
          term.value is num &&
          (term.value as num) >= 0) {
        return 'width';
      }
    }
    if (term is css.NumberTerm && term.value is num && term.value == 0) {
      return 'width';
    }
    if (term is css.LiteralTerm && term is! css.FunctionTerm) {
      // csslib stores identifier tokens in an Identifier object, not as a
      // String. The printed token handles both that representation and string
      // values while keeping function terms out of keyword classification.
      final keyword = _expressionText(term).toLowerCase();
      if (_borderWidthKeywords.contains(keyword)) return 'width';
      if (_borderStyleKeywords.contains(keyword)) return 'style';
    }
    final colorStatus = _colorValueStatus(term);
    if (colorStatus != _ColorValueStatus.invalid) return 'color';
    return null;
  }

  List<css.Expression>? _boxShorthandValues(css.Expression expression) {
    final values = expression is css.Expressions
        ? expression.expressions
        : <css.Expression>[expression];
    if (values.isEmpty || values.length > 4) return null;
    for (final value in values) {
      if (value is! css.LiteralTerm || _containsVarUsage(value)) return null;
    }
    return values;
  }

  List<String> _expandFourSides(List<css.Expression> values) {
    final top = _expressionText(values[0]);
    final right = values.length == 1 ? top : _expressionText(values[1]);
    final bottom = values.length < 3 ? top : _expressionText(values[2]);
    final left = values.length < 4 ? right : _expressionText(values[3]);
    return [top, right, bottom, left];
  }

  int _fourSideValueIndex(int count, int side) => switch ((count, side)) {
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

  void _offer(dom.Element element, String property, _Candidate candidate) {
    final declarations = _winners.putIfAbsent(element, () => {});
    final current = declarations[property];
    if (current == null || candidate.outranks(current)) {
      declarations[property] = candidate;
    }
  }

  bool _mediaQueriesMatch(
    List<css.MediaQuery> queries,
    String baseUrl, {
    required String sourceText,
  }) {
    if (queries.isEmpty) return sourceText.trim().isEmpty;
    // csslib's MediaQuery spans do not round-trip all accepted source forms
    // (notably the media type and unary operator can be outside the span).
    // Use the source text only to reject MQ4 boolean syntax that this evaluator
    // cannot represent; comparing a reconstructed AST string here incorrectly
    // disabled ordinary MQ3 queries such as `screen` and `(min-width: 600px)`.
    if (_hasUnsupportedMediaBooleanSyntax(sourceText)) {
      _unsupportedMediaSyntax(baseUrl);
      return false;
    }
    var anyMatch = false;
    for (final query in queries) {
      final match = _mediaQueryMatches(query, baseUrl);
      if (match == true) anyMatch = true;
    }
    return anyMatch;
  }

  bool? _mediaQueryMatches(css.MediaQuery query, String baseUrl) {
    var result = true;
    if (query.hasMediaType) {
      final type = query.mediaType.toLowerCase();
      if (type == 'print') {
        result = false;
      } else if (type != 'all' && type != 'screen') {
        _diagnostics.add(
          NativeDocumentStyleDiagnostic(
            code: 'unsupported-media-type',
            message: tr(
              "Unknown media type \"{0}\" does not match this screen environment.",
              [type],
            ),
            baseUrl: baseUrl,
          ),
        );
        // An unknown media type is a valid, non-matching query. In particular,
        // `not unknown-type` matches, as it does in Chrome.
        result = false;
      }
    }
    for (final expression in query.expressions) {
      final feature = _mediaExpressionMatches(expression, baseUrl);
      if (feature == null) return null;
      result = result && feature;
    }
    if (query.hasUnary && query.unary.toLowerCase() == 'not') {
      result = !result;
    } else if (query.hasUnary && query.unary.toLowerCase() != 'only') {
      _diagnostics.add(
        NativeDocumentStyleDiagnostic(
          code: 'unsupported-media-unary',
          message: tr("Media operator \"{0}\" is not supported.", [
            query.unary,
          ]),
          baseUrl: baseUrl,
        ),
      );
      return null;
    }
    return result;
  }

  bool? _mediaExpressionMatches(
    css.MediaExpression expression,
    String baseUrl,
  ) {
    final feature = expression.mediaFeature.toLowerCase();
    final value = expression.exprs.span?.text.trim() ?? '';
    if (feature == 'prefers-color-scheme') {
      final scheme = value.toLowerCase();
      if (scheme == 'dark' || scheme == 'light') {
        return (scheme == 'dark') == engine.dark;
      }
      return _unsupportedMediaFeature(feature, baseUrl);
    }
    if (feature == 'width' ||
        feature == 'min-width' ||
        feature == 'max-width' ||
        feature == 'height' ||
        feature == 'min-height' ||
        feature == 'max-height') {
      final pixels = _mediaLengthPixels(expression.exprs);
      final dimension = feature.endsWith('height')
          ? engine.viewportHeight
          : engine.viewportWidth;
      if (pixels == null || !dimension.isFinite || dimension < 0) {
        return _unsupportedMediaFeature(feature, baseUrl);
      }
      if (feature.startsWith('min-')) {
        return dimension >= pixels || _mediaNumbersEqual(dimension, pixels);
      }
      if (feature.startsWith('max-')) {
        return dimension <= pixels || _mediaNumbersEqual(dimension, pixels);
      }
      return _mediaNumbersEqual(dimension, pixels);
    }
    if (feature == 'orientation') {
      final orientation = value.toLowerCase();
      if (orientation != 'portrait' && orientation != 'landscape') {
        return _unsupportedMediaFeature(feature, baseUrl);
      }
      if (!engine.viewportWidth.isFinite ||
          !engine.viewportHeight.isFinite ||
          engine.viewportWidth < 0 ||
          engine.viewportHeight < 0) {
        return _unsupportedMediaFeature(feature, baseUrl);
      }
      final isPortrait = engine.viewportHeight >= engine.viewportWidth;
      return (orientation == 'portrait') == isPortrait;
    }
    if (feature == 'resolution' ||
        feature == 'min-resolution' ||
        feature == 'max-resolution') {
      final dppx = _mediaResolutionDppx(expression.exprs);
      if (dppx == null ||
          !engine.devicePixelRatio.isFinite ||
          engine.devicePixelRatio <= 0) {
        return _unsupportedMediaFeature(feature, baseUrl);
      }
      if (feature.startsWith('min-')) {
        return engine.devicePixelRatio >= dppx ||
            _mediaNumbersEqual(engine.devicePixelRatio, dppx);
      }
      if (feature.startsWith('max-')) {
        return engine.devicePixelRatio <= dppx ||
            _mediaNumbersEqual(engine.devicePixelRatio, dppx);
      }
      return _mediaNumbersEqual(engine.devicePixelRatio, dppx);
    }
    if (feature == 'aspect-ratio' ||
        feature == 'min-aspect-ratio' ||
        feature == 'max-aspect-ratio') {
      final ratio = _mediaAspectRatio(expression.exprs);
      if (ratio == null ||
          !engine.viewportWidth.isFinite ||
          !engine.viewportHeight.isFinite ||
          engine.viewportWidth <= 0 ||
          engine.viewportHeight <= 0) {
        return _unsupportedMediaFeature(feature, baseUrl);
      }
      final viewportRatio = engine.viewportWidth / engine.viewportHeight;
      if (!viewportRatio.isFinite) {
        return _unsupportedMediaFeature(feature, baseUrl);
      }
      if (feature.startsWith('min-')) {
        return viewportRatio >= ratio ||
            _mediaNumbersEqual(viewportRatio, ratio);
      }
      if (feature.startsWith('max-')) {
        return viewportRatio <= ratio ||
            _mediaNumbersEqual(viewportRatio, ratio);
      }
      return _mediaNumbersEqual(viewportRatio, ratio);
    }
    if (feature == 'prefers-reduced-motion') {
      final preference = value.toLowerCase();
      if (preference == 'reduce' || preference == 'no-preference') {
        return (preference == 'reduce') == engine.reducedMotion;
      }
      return _unsupportedMediaFeature(feature, baseUrl);
    }
    if (feature == 'pointer' || feature == 'any-pointer') {
      final capability = value.toLowerCase();
      if (capability != 'none' &&
          capability != 'coarse' &&
          capability != 'fine') {
        return _unsupportedMediaFeature(feature, baseUrl);
      }
      final configured = engine.pointer.toLowerCase();
      if (configured != 'none' &&
          configured != 'coarse' &&
          configured != 'fine') {
        return _unsupportedMediaFeature(feature, baseUrl);
      }
      // The renderer receives one primary pointer value, so any-pointer uses
      // that same environment value rather than modeling multiple devices.
      return capability == configured;
    }
    if (feature == 'hover' || feature == 'any-hover') {
      final capability = value.toLowerCase();
      if (capability != 'none' && capability != 'hover') {
        return _unsupportedMediaFeature(feature, baseUrl);
      }
      final configured = engine.hover.toLowerCase();
      if (configured != 'none' && configured != 'hover') {
        return _unsupportedMediaFeature(feature, baseUrl);
      }
      // Like any-pointer above, any-hover shares the supplied single-device
      // environment value.
      return capability == configured;
    }
    return _unsupportedMediaFeature(feature, baseUrl);
  }

  void _unsupportedMediaSyntax(String baseUrl) {
    _diagnostics.add(
      NativeDocumentStyleDiagnostic(
        code: 'unsupported-media-syntax',
        message: tr(
          "The media condition uses syntax that the current CSS parser cannot represent completely.",
        ),
        baseUrl: baseUrl,
      ),
    );
  }

  bool? _unsupportedMediaFeature(String feature, String baseUrl) {
    _diagnostics.add(
      NativeDocumentStyleDiagnostic(
        code: 'unsupported-media-feature',
        message: tr("Media feature \"{0}\" is not supported.", [feature]),
        baseUrl: baseUrl,
      ),
    );
    return null;
  }

  double? _mediaLengthPixels(css.Expressions expression) {
    if (expression.expressions.length != 1) return null;
    final value = expression.expressions.single;
    if (value is css.EmTerm && value.value is num) {
      final number = (value.value as num).toDouble();
      return number.isFinite && number >= 0 ? number * 16 : null;
    }
    if (value is css.UnitTerm) {
      final number = value.value;
      if (number is! num) return null;
      final unit = value.unitToString()?.toLowerCase();
      final pixels = switch (unit) {
        'px' => number.toDouble(),
        'rem' => number.toDouble() * 16,
        _ => double.nan,
      };
      return pixels.isFinite && pixels >= 0 ? pixels : null;
    }
    if (value is css.LiteralTerm &&
        value.value is num &&
        (value.value as num) == 0) {
      return 0;
    }
    return null;
  }

  double? _mediaResolutionDppx(css.Expressions expression) {
    if (expression.expressions.length != 1) return null;
    final value = expression.expressions.single;
    if (value is! css.UnitTerm || value.value is! num) return null;
    final unit = value.unitToString()?.toLowerCase();
    final number = (value.value as num).toDouble();
    if (!number.isFinite || number <= 0) return null;
    final dppx = switch (unit) {
      'dppx' => number,
      'dpi' => number / 96,
      'dpcm' => number * 2.54 / 96,
      _ => double.nan,
    };
    return dppx.isFinite && dppx > 0 ? dppx : null;
  }

  double? _mediaAspectRatio(css.Expressions expression) {
    final terms = expression.expressions;
    if (terms.length != 1 && terms.length != 3) return null;
    if (terms.first is! css.NumberTerm ||
        (terms.length == 3 &&
            (terms[1] is! css.OperatorSlash || terms[2] is! css.NumberTerm))) {
      return null;
    }
    final first = (terms.first as css.NumberTerm).value;
    final last = terms.length == 3 ? (terms[2] as css.NumberTerm).value : 1;
    if (first is! num || last is! num) return null;
    final numerator = first.toDouble();
    final denominator = last.toDouble();
    if (!numerator.isFinite ||
        !denominator.isFinite ||
        numerator < 0 ||
        denominator <= 0) {
      return null;
    }
    final ratio = numerator / denominator;
    return ratio.isFinite ? ratio : null;
  }

  bool _mediaNumbersEqual(double left, double right) {
    if (!left.isFinite || !right.isFinite) return left == right;
    final scale = left.abs() > right.abs() ? left.abs() : right.abs();
    final tolerance = (scale > 1 ? scale : 1) * 1e-9;
    return (left - right).abs() <= tolerance;
  }

  String? _resolveCustomProperty(
    _VariableScope scope,
    String name,
    Set<_VariableKey> active,
  ) {
    final key = _VariableKey(scope, name);
    if (active.any((entry) => entry == key)) {
      final cycle = {...active, key};
      _cyclicVariables.addAll(cycle);
      for (final entry in cycle) {
        entry.scope.cache.remove(entry.name);
      }
      final signature = cycle.map((entry) => entry.name).toList()..sort();
      final diagnosticKey = '${identityHashCode(scope)}:${signature.join(',')}';
      if (_reportedCycles.add(diagnosticKey)) {
        _diagnostics.add(
          NativeDocumentStyleDiagnostic(
            code: 'cyclic-custom-property',
            message: tr("Custom property cycle: {0}.", [signature.join(' → ')]),
            baseUrl: scope.local[name]?.baseUrl ?? '',
            property: name,
          ),
        );
      }
      return null;
    }
    if (_cyclicVariables.contains(key)) return null;
    if (scope.cache.containsKey(name)) return scope.cache[name];

    final candidate = scope.local[name];
    if (candidate == null) {
      final inherited = scope.parent == null
          ? null
          : _resolveCustomProperty(scope.parent!, name, active);
      scope.cache[name] = inherited;
      return inherited;
    }

    final raw = candidate.value.trim();
    final keyword = raw.toLowerCase();
    if (keyword == 'initial' ||
        keyword == 'revert' ||
        keyword == 'revert-layer') {
      if (keyword != 'initial') {
        _diagnostics.add(
          NativeDocumentStyleDiagnostic(
            code: 'unsupported-css-wide-keyword',
            message: tr("Custom property value \"{0}\" is not computed.", [
              raw,
            ]),
            baseUrl: candidate.baseUrl,
            property: name,
          ),
        );
      }
      scope.cache[name] = null;
      return null;
    }
    if (keyword == 'inherit' || keyword == 'unset') {
      final inherited = scope.parent == null
          ? null
          : _resolveCustomProperty(scope.parent!, name, active);
      scope.cache[name] = inherited;
      return inherited;
    }

    final resolved = candidate.valueExpression == null
        ? candidate.value
        : _resolveExpression(
            candidate.valueExpression!,
            scope,
            {...active, key},
            candidate.baseUrl,
            name,
          );
    final computed = _cyclicVariables.contains(key) ? null : resolved?.trim();
    scope.cache[name] = computed;
    if (computed == null) {
      _diagnostics.add(
        NativeDocumentStyleDiagnostic(
          code: 'invalid-custom-property',
          message: tr("Custom property \"{0}\" has no usable computed value.", [
            name,
          ]),
          baseUrl: candidate.baseUrl,
          property: name,
        ),
      );
    }
    return computed;
  }

  String? _normalizeBackgroundValue(
    String value, {
    required String baseUrl,
    required String property,
  }) {
    final keyword = value.trim().toLowerCase();
    if (_cssWideKeywords.contains(keyword)) return keyword;
    final parsed = _parseCss('* { $property: $value; }', baseUrl);
    _addParseMessages(parsed.messages, baseUrl);
    final declarations = parsed.stylesheet?.topLevels
        .whereType<css.RuleSet>()
        .expand((rule) => rule.declarationGroup.declarations)
        .whereType<css.Declaration>()
        .toList();
    if (declarations == null || declarations.length != 1) {
      _diagnostics.add(
        NativeDocumentStyleDiagnostic(
          code: 'unsupported-background-image',
          message: tr(
            "Could not parse the background value as one CSS declaration.",
          ),
          baseUrl: baseUrl,
          property: property,
        ),
      );
      return null;
    }
    final expression = declarations.single.expression;
    if (expression == null) return null;

    final layers = _splitBackgroundLayers(expression);
    if (layers == null) {
      _diagnostics.add(
        NativeDocumentStyleDiagnostic(
          code: 'unsupported-background-layers',
          message: tr("The background image layer list is malformed."),
          baseUrl: baseUrl,
          property: property,
        ),
      );
      return null;
    }
    final normalizedLayers = <String>[];
    for (final layer in layers) {
      final normalized = _normalizeBackgroundImageLayer(
        layer,
        baseUrl: baseUrl,
        property: property,
      );
      if (normalized == null) return null;
      normalizedLayers.add(normalized);
    }
    return normalizedLayers.join(', ');
  }

  String? _normalizeBackgroundImageLayer(
    css.Expression expression, {
    required String baseUrl,
    required String property,
  }) {
    final collector = _BackgroundImageCollector();
    expression.visit(collector);
    const imageFunctions = <String>{
      'cross-fade',
      'element',
      'image',
      'image-set',
    };
    String? unsupportedFunction;
    for (final function in collector.functions) {
      final normalized = function.toLowerCase();
      if (imageFunctions.contains(normalized)) {
        unsupportedFunction = normalized;
        break;
      }
    }
    if (unsupportedFunction != null) {
      _diagnostics.add(
        NativeDocumentStyleDiagnostic(
          code: 'unsupported-background-image',
          message: tr("The {0} image function is unsupported.", [
            unsupportedFunction,
          ]),
          baseUrl: baseUrl,
          property: property,
        ),
      );
      return null;
    }

    if (collector.gradients.isNotEmpty) {
      if (collector.gradients.length != 1 || collector.urls.isNotEmpty) {
        _diagnostics.add(
          NativeDocumentStyleDiagnostic(
            code: 'unsupported-background-layers',
            message: tr(
              "Only one background image or gradient layer is supported.",
            ),
            baseUrl: baseUrl,
            property: property,
          ),
        );
        return null;
      }
      final gradient = _expressionText(collector.gradients.single).trim();
      if (!_validateBackgroundGradient(gradient, baseUrl, property)) {
        return null;
      }
      return _expressionText(expression).trim();
    }

    if (collector.urls.isEmpty) {
      final text = _expressionText(expression).trim();
      if (property == 'background' || text.toLowerCase() == 'none') {
        return text;
      }
      _diagnostics.add(
        NativeDocumentStyleDiagnostic(
          code: 'unsupported-background-image',
          message: tr(
            "Only none or one raster URL is supported for background-image.",
          ),
          baseUrl: baseUrl,
          property: property,
        ),
      );
      return null;
    }
    if (collector.urls.length != 1) {
      _diagnostics.add(
        NativeDocumentStyleDiagnostic(
          code: 'unsupported-background-layers',
          message: tr("Only one background URL layer is supported."),
          baseUrl: baseUrl,
          property: property,
        ),
      );
      return null;
    }

    final printer = _BackgroundUrlPrinter(
      (raw) => _resolveBackgroundUrl(raw, baseUrl),
    );
    expression.visit(printer);
    if (printer.failure != null) {
      _diagnostics.add(
        NativeDocumentStyleDiagnostic(
          code: 'unsupported-background-url',
          message: printer.failure!,
          baseUrl: baseUrl,
          property: property,
        ),
      );
      return null;
    }
    return printer.toString().trim();
  }

  _BackgroundAnalysis? _analyzeBackgroundShorthand(
    String value,
    String baseUrl,
  ) {
    final keyword = value.trim().toLowerCase();
    if (_cssWideKeywords.contains(keyword)) {
      return _BackgroundAnalysis(keyword, {
        'image': keyword,
        'color': keyword,
        'position': keyword,
        'size': keyword,
        'repeat': keyword,
        'attachment': keyword,
        'origin': keyword,
        'clip': keyword,
      });
    }
    final parsed = _parseCss('* { background: $value; }', baseUrl);
    _addParseMessages(parsed.messages, baseUrl);
    final declarations = parsed.stylesheet?.topLevels
        .whereType<css.RuleSet>()
        .expand((rule) => rule.declarationGroup.declarations)
        .whereType<css.Declaration>()
        .toList();
    if (declarations == null || declarations.length != 1) {
      _diagnostics.add(
        NativeDocumentStyleDiagnostic(
          code: 'unsupported-background-shorthand',
          message: tr("Could not parse this background shorthand."),
          baseUrl: baseUrl,
          property: 'background',
        ),
      );
      return null;
    }
    final expression = declarations.single.expression;
    if (expression == null) return null;

    final layers = _splitBackgroundLayers(expression);
    if (layers == null) {
      _diagnostics.add(
        NativeDocumentStyleDiagnostic(
          code: 'unsupported-background-layers',
          message: tr("The background shorthand layer list is malformed."),
          baseUrl: baseUrl,
          property: 'background',
        ),
      );
      return null;
    }
    if (layers.length == 1) {
      return _analyzeBackgroundShorthandLayer(layers.single, baseUrl);
    }

    final analyses = <_BackgroundAnalysis>[];
    for (final layer in layers) {
      final analysis = _analyzeBackgroundShorthandLayer(layer, baseUrl);
      if (analysis == null) return null;
      analyses.add(analysis);
    }
    if (analyses
        .take(analyses.length - 1)
        .any((analysis) => analysis.hasColor)) {
      _diagnostics.add(
        NativeDocumentStyleDiagnostic(
          code: 'unsupported-background-shorthand',
          message: tr("Only the final background layer may specify a color."),
          baseUrl: baseUrl,
          property: 'background',
        ),
      );
      return null;
    }

    String componentList(String name) =>
        analyses.map((analysis) => analysis.components[name]!).join(', ');

    return _BackgroundAnalysis(
      analyses.map((analysis) => analysis.backgroundValue).join(', '),
      {
        'image': componentList('image'),
        'color': analyses.last.components['color']!,
        'position': componentList('position'),
        'size': componentList('size'),
        'repeat': componentList('repeat'),
        'attachment': componentList('attachment'),
        'origin': componentList('origin'),
        'clip': componentList('clip'),
      },
      hasColor: analyses.last.hasColor,
    );
  }

  _BackgroundAnalysis? _analyzeBackgroundShorthandLayer(
    css.Expression expression,
    String baseUrl,
  ) {
    final terms = expression is css.Expressions
        ? expression.expressions
        : <css.Expression>[expression];

    final collector = _BackgroundImageCollector();
    expression.visit(collector);
    const imageFunctions = <String>{
      'cross-fade',
      'element',
      'image',
      'image-set',
      'paint',
      '-webkit-image-set',
    };
    final unsupportedFunctions = collector.functions
        .map((name) => name.toLowerCase())
        .where(imageFunctions.contains)
        .toList();
    final unsupportedFunction = unsupportedFunctions.isEmpty
        ? null
        : unsupportedFunctions.first;
    if (unsupportedFunction != null) {
      _diagnostics.add(
        NativeDocumentStyleDiagnostic(
          code: 'unsupported-background-image',
          message: tr("The {0} image function is unsupported.", [
            unsupportedFunction,
          ]),
          baseUrl: baseUrl,
          property: 'background',
        ),
      );
      return null;
    }
    if (collector.urls.length + collector.gradients.length > 1) {
      _diagnostics.add(
        NativeDocumentStyleDiagnostic(
          code: 'unsupported-background-layers',
          message: tr("Only one background URL layer is supported."),
          baseUrl: baseUrl,
          property: 'background',
        ),
      );
      return null;
    }

    if (collector.gradients.isNotEmpty &&
        !_validateBackgroundGradient(
          _expressionText(collector.gradients.single).trim(),
          baseUrl,
          'background',
        )) {
      return null;
    }

    final beforeSlash = <css.Expression>[];
    final afterSlash = <css.Expression>[];
    var foundSlash = false;
    for (final term in terms) {
      if (term is css.OperatorSlash) {
        if (foundSlash) {
          _diagnostics.add(
            NativeDocumentStyleDiagnostic(
              code: 'unsupported-background-shorthand',
              message: tr("Only one background size slash is supported."),
              baseUrl: baseUrl,
              property: 'background',
            ),
          );
          return null;
        }
        foundSlash = true;
      } else if (foundSlash) {
        afterSlash.add(term);
      } else {
        beforeSlash.add(term);
      }
    }
    if (foundSlash && afterSlash.isEmpty) {
      _diagnostics.add(
        NativeDocumentStyleDiagnostic(
          code: 'unsupported-background-shorthand',
          message: tr("A background size must follow the slash."),
          baseUrl: baseUrl,
          property: 'background',
        ),
      );
      return null;
    }

    final position = <String>[];
    final size = <String>[];
    final repeats = <String>[];
    final boxes = <String>[];
    final colors = <String>[];
    var attachment = 'scroll';
    var hasAttachment = false;
    var explicitNone = false;
    const repeatValues = {
      'repeat',
      'repeat-x',
      'repeat-y',
      'no-repeat',
      'space',
      'round',
    };
    const attachmentValues = {'fixed', 'local', 'scroll'};
    const boxValues = {'border-box', 'padding-box', 'content-box'};
    const positionValues = {'left', 'right', 'top', 'bottom', 'center'};
    const sizeValues = {'auto', 'cover', 'contain'};

    bool consumeCommon(css.Expression term) {
      final text = _expressionText(term).trim();
      final keyword = text.toLowerCase();
      if (term is css.UriTerm || collector.gradients.contains(term)) {
        return true;
      }
      if (keyword == 'none') {
        explicitNone = true;
        return true;
      }
      if (_isBackgroundColorTerm(term)) {
        colors.add(text);
        return true;
      }
      if (repeatValues.contains(keyword)) {
        repeats.add(keyword);
        return true;
      }
      if (attachmentValues.contains(keyword)) {
        if (hasAttachment) return false;
        attachment = keyword;
        hasAttachment = true;
        return true;
      }
      if (boxValues.contains(keyword)) {
        boxes.add(keyword);
        return true;
      }
      return false;
    }

    for (final term in beforeSlash) {
      if (consumeCommon(term)) continue;
      final text = _expressionText(term).trim();
      if (term is css.UnitTerm ||
          text == '0' ||
          positionValues.contains(text.toLowerCase()) ||
          _isCalcFunction(term)) {
        position.add(text);
        continue;
      }
      _diagnostics.add(
        NativeDocumentStyleDiagnostic(
          code: 'unsupported-background-shorthand',
          message: tr("Unsupported background component \"{0}\".", [text]),
          baseUrl: baseUrl,
          property: 'background',
        ),
      );
      return null;
    }

    for (final term in afterSlash) {
      if (consumeCommon(term)) continue;
      final text = _expressionText(term).trim();
      if (term is css.UnitTerm ||
          text == '0' ||
          sizeValues.contains(text.toLowerCase()) ||
          _isCalcFunction(term)) {
        size.add(text);
        continue;
      }
      _diagnostics.add(
        NativeDocumentStyleDiagnostic(
          code: 'unsupported-background-shorthand',
          message: tr("Unsupported background size component \"{0}\".", [text]),
          baseUrl: baseUrl,
          property: 'background',
        ),
      );
      return null;
    }
    if (repeats.length > 2 ||
        boxes.length > 2 ||
        colors.length > 1 ||
        position.length > 4 ||
        size.length > 2 ||
        (explicitNone &&
            (collector.urls.isNotEmpty || collector.gradients.isNotEmpty))) {
      _diagnostics.add(
        NativeDocumentStyleDiagnostic(
          code: 'unsupported-background-shorthand',
          message: tr(
            "This background shorthand has conflicting or excess components.",
          ),
          baseUrl: baseUrl,
          property: 'background',
        ),
      );
      return null;
    }

    var image = 'none';
    String backgroundValue;
    if (collector.urls.isNotEmpty) {
      final printer = _BackgroundUrlPrinter(
        (raw) => _resolveBackgroundUrl(raw, baseUrl),
      );
      expression.visit(printer);
      if (printer.failure != null) {
        _diagnostics.add(
          NativeDocumentStyleDiagnostic(
            code: 'unsupported-background-url',
            message: printer.failure!,
            baseUrl: baseUrl,
            property: 'background',
          ),
        );
        return null;
      }
      backgroundValue = printer.toString().trim();
      final imagePrinter = _BackgroundUrlPrinter(
        (raw) => _resolveBackgroundUrl(raw, baseUrl),
      );
      collector.urls.single.visit(imagePrinter);
      if (imagePrinter.failure != null) return null;
      image = imagePrinter.toString().trim();
    } else {
      backgroundValue = _expressionText(expression).trim();
      if (collector.gradients.isNotEmpty) {
        image = _expressionText(collector.gradients.single).trim();
      }
    }

    final origin = boxes.isEmpty ? 'padding-box' : boxes.first;
    final clip = boxes.length < 2
        ? (boxes.isEmpty ? 'border-box' : boxes.first)
        : boxes[1];
    return _BackgroundAnalysis(backgroundValue, {
      'image': image,
      'color': colors.isEmpty ? 'transparent' : colors.first,
      'position': position.isEmpty ? '0% 0%' : position.join(' '),
      'size': size.isEmpty ? 'auto' : size.join(' '),
      'repeat': repeats.isEmpty ? 'repeat' : repeats.join(' '),
      'attachment': attachment,
      'origin': origin,
      'clip': clip,
    }, hasColor: colors.isNotEmpty);
  }

  List<css.Expression>? _splitBackgroundLayers(css.Expression expression) {
    final terms = expression is css.Expressions
        ? expression.expressions
        : <css.Expression>[expression];
    final layers = <css.Expression>[];
    var layerTerms = <css.Expression>[];

    void finishLayer() {
      if (layerTerms.length == 1) {
        layers.add(layerTerms.single);
      } else {
        final layer = css.Expressions(expression.span);
        for (final term in layerTerms) {
          layer.add(term.clone());
        }
        layers.add(layer);
      }
      layerTerms = <css.Expression>[];
    }

    for (final term in terms) {
      if (term is css.OperatorComma) {
        if (layerTerms.isEmpty) return null;
        finishLayer();
      } else {
        layerTerms.add(term);
      }
    }
    if (layerTerms.isEmpty) return null;
    finishLayer();
    return layers;
  }

  bool _validateBackgroundGradient(
    String value,
    String baseUrl,
    String property,
  ) {
    try {
      if (parseNativeHtmlBackgroundGradient(value) != null) return true;
    } on FormatException catch (error) {
      _diagnostics.add(
        NativeDocumentStyleDiagnostic(
          code: 'unsupported-background-image',
          message: error.message,
          baseUrl: baseUrl,
          property: property,
        ),
      );
      return false;
    }
    _diagnostics.add(
      NativeDocumentStyleDiagnostic(
        code: 'unsupported-background-image',
        message: tr("Unable to parse background gradient."),
        baseUrl: baseUrl,
        property: property,
      ),
    );
    return false;
  }

  bool _isBackgroundColorTerm(css.Expression term) {
    if (term is css.FunctionTerm) {
      const colorFunctions = {
        'color',
        'color-mix',
        'hsl',
        'hsla',
        'hwb',
        'lab',
        'lch',
        'light-dark',
        'oklab',
        'oklch',
        'rgb',
        'rgba',
      };
      return colorFunctions.contains(term.value.toString().toLowerCase());
    }
    return _colorValueStatus(term) == _ColorValueStatus.valid;
  }

  bool _isCalcFunction(css.Expression term) =>
      term is css.FunctionTerm && term.value.toString().toLowerCase() == 'calc';

  ({String? url, String? error}) _resolveBackgroundUrl(
    String raw,
    String baseUrl,
  ) {
    final value = _decodeCssEscapes(raw)?.trim();
    if (value == null) {
      return (
        url: null,
        error: tr("The background URL contains an invalid CSS escape."),
      );
    }
    final scheme = RegExp(
      r'^([A-Za-z][A-Za-z0-9+.-]*):',
    ).firstMatch(value)?.group(1)?.toLowerCase();
    if (scheme == 'data') {
      if (!RegExp(r'^data:image/', caseSensitive: false).hasMatch(value)) {
        return (
          url: null,
          error: tr("Only data:image/* background URLs are supported."),
        );
      }
      return (url: value, error: null);
    }
    if (scheme == 'blob') return (url: value, error: null);
    if (scheme != null && scheme != 'http' && scheme != 'https') {
      return (
        url: null,
        error: tr("The {0}: background image URL scheme is unsupported.", [
          scheme,
        ]),
      );
    }
    if (value.startsWith('#')) {
      return (
        url: null,
        error: tr("SVG fragment background images are unsupported."),
      );
    }
    try {
      final resolved = resolveNativeDocumentUrl(value, baseUrl);
      return (url: resolved, error: null);
    } on Object catch (error) {
      return (
        url: null,
        error: tr(
          "Could not resolve the background URL against its source base: {0}",
          [error],
        ),
      );
    }
  }

  String? _resolveExpression(
    css.Expression expression,
    _VariableScope scope,
    Set<_VariableKey> active,
    String baseUrl,
    String property,
  ) {
    final printer = _VariableResolvingPrinter(
      (usage) => _resolveVarUsage(usage, scope, active, baseUrl, property),
    );
    try {
      expression.visit(printer);
    } on Object catch (error) {
      _diagnostics.add(
        NativeDocumentStyleDiagnostic(
          code: 'unsupported-css-expression',
          message: tr("Could not serialize this CSS expression: {0}", [error]),
          baseUrl: baseUrl,
          property: property,
        ),
      );
      return null;
    }
    final unresolved = printer.unresolvedUsage;
    if (unresolved != null) {
      _diagnostics.add(
        NativeDocumentStyleDiagnostic(
          code: 'unresolved-variable',
          message: tr(
            "Ignored declaration because {0} has no value or fallback.",
            [unresolved.name],
          ),
          baseUrl: baseUrl,
          property: property,
        ),
      );
      return null;
    }
    return printer.toString().trim();
  }

  String? _resolveVarUsage(
    css.VarUsage usage,
    _VariableScope scope,
    Set<_VariableKey> active,
    String baseUrl,
    String property,
  ) {
    final resolved = _resolveCustomProperty(scope, usage.name, active);
    if (resolved != null) return resolved;
    if (usage.defaultValues.isEmpty) return null;
    final css.Expression fallbackExpression;
    if (usage.defaultValues.length == 1) {
      fallbackExpression = usage.defaultValues.single;
    } else {
      fallbackExpression = css.Expressions(null)
        ..expressions.addAll(usage.defaultValues);
    }
    return _resolveExpression(
      fallbackExpression,
      scope,
      active,
      baseUrl,
      property,
    );
  }

  _ColorValueStatus _colorValueStatus(css.Expression expression) {
    if (_containsVarUsage(expression)) return _ColorValueStatus.unvalidated;
    final terms = expression is css.Expressions
        ? expression.expressions
        : <css.Expression>[expression];
    if (terms.length != 1) return _ColorValueStatus.invalid;
    final term = terms.single;
    final text = _expressionText(expression).trim();
    final keyword = text.toLowerCase();
    if (_cssWideKeywords.contains(keyword) ||
        keyword == 'currentcolor' ||
        keyword == 'transparent' ||
        _cssSystemColors.contains(keyword)) {
      return _ColorValueStatus.valid;
    }
    if (term is css.HexColorTerm) {
      return term.value is css.BAD_HEX_VALUE
          ? _ColorValueStatus.invalid
          : _ColorValueStatus.valid;
    }
    if (term is css.FunctionTerm) {
      final function = term.value.toString().toLowerCase();
      if (_modernCssColorFunctions.contains(function)) {
        return _ColorValueStatus.unvalidated;
      }
      try {
        css_parser.Color.css(text);
        return _ColorValueStatus.valid;
      } on Object {
        // Keep new color-function syntax visible to the renderer, while
        // refusing known invalid color identifiers below.
        return _ColorValueStatus.unvalidated;
      }
    }
    try {
      css_parser.Color.css(text);
      return _ColorValueStatus.valid;
    } on Object {
      return _ColorValueStatus.invalid;
    }
  }

  bool _containsVarUsage(css.Expression expression) {
    final collector = _VarUsageCollector();
    expression.visit(collector);
    return collector.usages.isNotEmpty;
  }

  void _addParseMessages(List<css_parser.Message> messages, String baseUrl) {
    for (final message in messages) {
      _diagnostics.add(
        NativeDocumentStyleDiagnostic(
          code: 'css-parse-error',
          message: message.describe,
          baseUrl: baseUrl,
        ),
      );
    }
  }
}

class _VarUsageCollector extends css.Visitor {
  final usages = <css.VarUsage>[];

  @override
  dynamic visitVarUsage(css.VarUsage node) {
    usages.add(node);
    return super.visitVarUsage(node);
  }
}

class _BackgroundImageCollector extends css.Visitor {
  final urls = <css.UriTerm>[];
  final functions = <String>[];
  final gradients = <css.FunctionTerm>[];

  @override
  dynamic visitUriTerm(css.UriTerm node) {
    urls.add(node);
    return super.visitUriTerm(node);
  }

  @override
  dynamic visitFunctionTerm(css.FunctionTerm node) {
    functions.add(node.value.toString());
    if (_backgroundGradientFunctions.contains(
      node.value.toString().toLowerCase(),
    )) {
      gradients.add(node);
    }
    return super.visitFunctionTerm(node);
  }
}

class _BackgroundAnalysis {
  const _BackgroundAnalysis(
    this.backgroundValue,
    this.components, {
    this.hasColor = false,
  });

  final String backgroundValue;
  final Map<String, String> components;
  final bool hasColor;
}

class _VariableResolvingPrinter extends css.CssPrinter {
  _VariableResolvingPrinter(this.resolve);

  final String? Function(css.VarUsage usage) resolve;
  css.VarUsage? unresolvedUsage;

  @override
  dynamic visitVarUsage(css.VarUsage node) {
    final replacement = resolve(node);
    if (replacement == null) {
      unresolvedUsage ??= node;
      return null;
    }
    emit(replacement);
    return null;
  }

  @override
  dynamic visitUriTerm(css.UriTerm node) {
    final decoded = _decodeCssEscapes(node.text) ?? node.text;
    emit('url("${_escapeCssString(decoded)}")');
    return null;
  }
}

class _BackgroundUrlPrinter extends css.CssPrinter {
  _BackgroundUrlPrinter(this.resolve);

  final ({String? url, String? error}) Function(String raw) resolve;
  String? failure;

  @override
  dynamic visitUriTerm(css.UriTerm node) {
    final raw = _decodeCssEscapes(node.text);
    if (raw == null) {
      failure ??= tr("The background URL contains an invalid CSS escape.");
      return null;
    }
    final result = resolve(raw);
    final url = result.url;
    if (url == null) {
      failure ??= result.error ?? tr("The background URL is unsupported.");
      return null;
    }
    emit('url("${_escapeCssString(url)}")');
    return null;
  }
}

String _escapeCssString(String value) {
  final escaped = StringBuffer();
  for (final rune in value.runes) {
    if (rune == 0x22 || rune == 0x5c) {
      escaped
        ..write(r'\')
        ..writeCharCode(rune);
    } else if (rune < 0x20 || rune == 0x7f) {
      escaped
        ..write(r'\')
        ..write(rune.toRadixString(16))
        ..write(' ');
    } else {
      escaped.write(String.fromCharCode(rune));
    }
  }
  return escaped.toString();
}

String? _decodeCssEscapes(String value) {
  final decoded = StringBuffer();
  var index = 0;
  while (index < value.length) {
    final current = value.codeUnitAt(index);
    if (current != 0x5c) {
      if (current >= 0xd800 && current <= 0xdbff && index + 1 < value.length) {
        decoded.write(value.substring(index, index + 2));
        index += 2;
      } else {
        decoded.writeCharCode(current);
        index++;
      }
      continue;
    }

    index++;
    if (index == value.length) return null;
    final escaped = value.codeUnitAt(index);
    if (escaped == 0x0a || escaped == 0x0c || escaped == 0x0d) {
      index++;
      if (escaped == 0x0d &&
          index < value.length &&
          value.codeUnitAt(index) == 0x0a) {
        index++;
      }
      continue;
    }

    if (_isCssHexDigit(escaped)) {
      final start = index;
      var digits = 0;
      while (index < value.length &&
          digits < 6 &&
          _isCssHexDigit(value.codeUnitAt(index))) {
        index++;
        digits++;
      }
      final codePoint = int.parse(value.substring(start, index), radix: 16);
      if (index < value.length &&
          _isCssUrlWhitespace(value.codeUnitAt(index))) {
        final whitespace = value.codeUnitAt(index++);
        if (whitespace == 0x0d &&
            index < value.length &&
            value.codeUnitAt(index) == 0x0a) {
          index++;
        }
      }
      if (codePoint == 0 ||
          codePoint > 0x10ffff ||
          (codePoint >= 0xd800 && codePoint <= 0xdfff)) {
        decoded.write('\u{fffd}');
      } else {
        decoded.write(String.fromCharCodes([codePoint]));
      }
      continue;
    }

    decoded.writeCharCode(escaped == 0 ? 0xfffd : escaped);
    index++;
  }
  return decoded.toString();
}

bool _isCssHexDigit(int value) =>
    (value >= 0x30 && value <= 0x39) ||
    (value >= 0x41 && value <= 0x46) ||
    (value >= 0x61 && value <= 0x66);

bool _isCssUrlWhitespace(int value) =>
    value == 0x20 ||
    value == 0x09 ||
    value == 0x0a ||
    value == 0x0c ||
    value == 0x0d;

class _ParsedCss {
  const _ParsedCss(this.stylesheet, this.messages);

  final css.StyleSheet? stylesheet;
  final List<css_parser.Message> messages;
}

class _PreparedMediaStylesheet {
  const _PreparedMediaStylesheet(this.cssText, this.quarantinedCount);

  final String cssText;
  final int quarantinedCount;
}

class _MediaHeader {
  const _MediaHeader({
    required this.start,
    required this.end,
    required this.condition,
  });

  final int start;
  final int end;
  final String condition;
}

_PreparedMediaStylesheet _prepareUnsupportedMediaHeaders(
  String source,
  String baseUrl,
) {
  final headers = _findMediaHeaders(source);
  if (headers.isEmpty) return _PreparedMediaStylesheet(source, 0);

  final output = StringBuffer();
  var lastCopied = 0;
  var quarantinedCount = 0;
  for (final header in headers) {
    if (_isMediaConditionRepresentable(header.condition, baseUrl)) continue;
    output
      ..write(source.substring(lastCopied, header.start))
      ..write('@media not all');
    lastCopied = header.end;
    quarantinedCount++;
  }
  if (quarantinedCount == 0) return _PreparedMediaStylesheet(source, 0);
  output.write(source.substring(lastCopied));
  return _PreparedMediaStylesheet(output.toString(), quarantinedCount);
}

bool _isMediaConditionRepresentable(String condition, String baseUrl) {
  if (_hasUnsupportedMediaBooleanSyntax(condition)) return false;
  final parsed = _parseCss('@media $condition {}', baseUrl);
  if (parsed.messages.isNotEmpty || parsed.stylesheet == null) return false;
  final topLevels = parsed.stylesheet!.topLevels;
  if (topLevels.length != 1 || topLevels.single is! css.MediaDirective) {
    return false;
  }
  final directive = topLevels.single as css.MediaDirective;
  // Parsing without diagnostics plus the MQ4 syntax check above is the
  // representability test. Do not compare reconstructed query spans with the
  // original condition: csslib spans omit tokens for otherwise valid MQ3.
  return directive.mediaQueries.isNotEmpty;
}

List<_MediaHeader> _findMediaHeaders(String source) {
  final headers = <_MediaHeader>[];
  var quote = '';
  var inComment = false;
  var parenthesisDepth = 0;
  var bracketDepth = 0;
  for (var index = 0; index < source.length; index++) {
    final character = source[index];
    final next = index + 1 < source.length ? source[index + 1] : '';
    if (inComment) {
      if (character == '*' && next == '/') {
        inComment = false;
        index++;
      }
      continue;
    }
    if (quote.isNotEmpty) {
      if (character == r'\') {
        index++;
      } else if (character == quote) {
        quote = '';
      }
      continue;
    }
    if (character == '/' && next == '*') {
      inComment = true;
      index++;
    } else if (character == '"' || character == "'") {
      quote = character;
    } else if (character == r'\') {
      index++;
    } else if (character == '(') {
      parenthesisDepth++;
    } else if (character == ')' && parenthesisDepth > 0) {
      parenthesisDepth--;
    } else if (character == '[') {
      bracketDepth++;
    } else if (character == ']' && bracketDepth > 0) {
      bracketDepth--;
    } else if (character == '@' &&
        parenthesisDepth == 0 &&
        bracketDepth == 0 &&
        _isMediaAtKeywordAt(source, index) &&
        _isAtRulePosition(source, index)) {
      final header = _readMediaHeader(source, index);
      if (header != null) {
        headers.add(header);
        parenthesisDepth = 0;
        bracketDepth = 0;
        index = header.end - 1;
      }
    }
  }
  return headers;
}

bool _isMediaAtKeywordAt(String source, int index) {
  if (index + 6 > source.length ||
      source.substring(index, index + 6).toLowerCase() != '@media') {
    return false;
  }
  final afterKeyword = index + 6;
  return afterKeyword == source.length ||
      !RegExp(
        r'[a-z0-9_-]',
        caseSensitive: false,
      ).hasMatch(source[afterKeyword]);
}

bool _isAtRulePosition(String source, int atKeywordStart) {
  var cursor = atKeywordStart - 1;
  while (true) {
    while (cursor >= 0 && (' \t\n\r\f\uFEFF'.contains(source[cursor]))) {
      cursor--;
    }
    if (cursor >= 1 && source[cursor - 1] == '*' && source[cursor] == '/') {
      final commentStart = source.lastIndexOf('/*', cursor - 1);
      if (commentStart < 0) return false;
      cursor = commentStart - 1;
      continue;
    }
    break;
  }
  return cursor < 0 || ';{}'.contains(source[cursor]);
}

_MediaHeader? _readMediaHeader(String source, int atKeywordStart) {
  if (!_isMediaAtKeywordAt(source, atKeywordStart)) return null;
  final conditionStart = atKeywordStart + 6;
  var parenthesisDepth = 0;
  var bracketDepth = 0;
  var quote = '';
  var inComment = false;
  for (var index = conditionStart; index < source.length; index++) {
    final character = source[index];
    final next = index + 1 < source.length ? source[index + 1] : '';
    if (inComment) {
      if (character == '*' && next == '/') {
        inComment = false;
        index++;
      }
      continue;
    }
    if (quote.isNotEmpty) {
      if (character == r'\') {
        index++;
      } else if (character == quote) {
        quote = '';
      }
      continue;
    }
    if (character == '/' && next == '*') {
      inComment = true;
      index++;
    } else if (character == '"' || character == "'") {
      quote = character;
    } else if (character == '(') {
      parenthesisDepth++;
    } else if (character == ')' && parenthesisDepth > 0) {
      parenthesisDepth--;
    } else if (character == '[') {
      bracketDepth++;
    } else if (character == ']' && bracketDepth > 0) {
      bracketDepth--;
    } else if (character == '{') {
      return _MediaHeader(
        start: atKeywordStart,
        end: index,
        condition: source.substring(conditionStart, index).trim(),
      );
    }
  }
  return null;
}

_ParsedCss _parseCss(String text, String baseUrl) {
  final messages = <css_parser.Message>[];
  try {
    final stylesheet = css_parser.parse(
      text,
      errors: messages,
      options: css_parser.PreprocessorOptions(
        useColors: false,
        inputFile: baseUrl,
      ),
    );
    return _ParsedCss(stylesheet, messages);
  } catch (error) {
    return _ParsedCss(null, [
      css_parser.Message(css_parser.MessageLevel.severe, '$error'),
    ]);
  }
}

List<NativeDocumentStyleImport> _importsFromAst(
  css.StyleSheet stylesheet,
  NativeDocumentStylesheet source,
  int sourceIndex,
) {
  var seenNonImport = false;
  final imports = <NativeDocumentStyleImport>[];
  for (var index = 0; index < stylesheet.topLevels.length; index++) {
    final node = stylesheet.topLevels[index];
    if (node is css.ImportDirective) {
      final href = _decodeCssImportHref(node.import);
      final ownMedia = _mediaQueriesText(node.mediaQueries);
      final combined = _combineImportMedia(source.media, ownMedia);
      var resolvedUrl = _resolveImportUrl(href, source.baseUrl);
      String? reason;
      if (seenNonImport) {
        reason = '@import must appear before style rules and other directives.';
      } else if (!combined.supported) {
        reason = combined.reason;
      }
      imports.add(
        NativeDocumentStyleImport(
          href: href,
          url: resolvedUrl,
          baseUrl: source.baseUrl,
          media: combined.media,
          supported: reason == null,
          sourceOrder: index,
          sourceIndex: sourceIndex,
          reason: reason,
        ),
      );
    } else if (node is css.CharsetDirective ||
        node is css.CssComment ||
        node is css.NoOp) {
      continue;
    } else {
      seenNonImport = true;
    }
  }
  return imports;
}

String _decodeCssImportHref(String token) {
  var value = token.trim();
  if (value.length >= 2 &&
      (value.startsWith('"') || value.startsWith("'")) &&
      value[0] == value[value.length - 1]) {
    value = value.substring(1, value.length - 1);
  }

  final codePoints = value.runes.toList();
  final output = StringBuffer();
  for (var index = 0; index < codePoints.length;) {
    final current = codePoints[index];
    if (current != 0x5c) {
      output.writeCharCode(current);
      index++;
      continue;
    }
    if (index + 1 >= codePoints.length) {
      output.writeCharCode(0xfffd);
      index++;
      continue;
    }

    final next = codePoints[index + 1];
    if (next == 0x0a || next == 0x0c || next == 0x0d) {
      index +=
          next == 0x0d &&
              index + 2 < codePoints.length &&
              codePoints[index + 2] == 0x0a
          ? 3
          : 2;
      continue;
    }

    var hexEnd = index + 1;
    while (hexEnd < codePoints.length &&
        hexEnd <= index + 6 &&
        _hexDigitValue(codePoints[hexEnd]) != null) {
      hexEnd++;
    }
    if (hexEnd > index + 1) {
      final digits = String.fromCharCodes(
        codePoints.sublist(index + 1, hexEnd),
      );
      var decoded = int.parse(digits, radix: 16);
      if (decoded == 0 ||
          decoded > 0x10ffff ||
          (decoded >= 0xd800 && decoded <= 0xdfff)) {
        decoded = 0xfffd;
      }
      output.writeCharCode(decoded);
      index = hexEnd;
      if (index < codePoints.length && _isCssWhitespace(codePoints[index])) {
        final isCrLf =
            codePoints[index] == 0x0d &&
            index + 1 < codePoints.length &&
            codePoints[index + 1] == 0x0a;
        index += isCrLf ? 2 : 1;
      }
      continue;
    }

    output.writeCharCode(next);
    index += 2;
  }
  return output.toString();
}

int? _hexDigitValue(int codePoint) {
  if (codePoint >= 0x30 && codePoint <= 0x39) return codePoint - 0x30;
  if (codePoint >= 0x41 && codePoint <= 0x46) return codePoint - 0x41 + 10;
  if (codePoint >= 0x61 && codePoint <= 0x66) return codePoint - 0x61 + 10;
  return null;
}

bool _isCssWhitespace(int codePoint) =>
    codePoint == 0x20 ||
    codePoint == 0x09 ||
    codePoint == 0x0a ||
    codePoint == 0x0c ||
    codePoint == 0x0d;

String? _resolveImportUrl(String href, String baseUrl) {
  try {
    return resolveNativeDocumentUrl(href, baseUrl);
  } catch (_) {
    return null;
  }
}

class _CombinedMedia {
  const _CombinedMedia(this.media, this.supported, [this.reason]);

  final String? media;
  final bool supported;
  final String? reason;
}

_CombinedMedia _combineImportMedia(String? outer, String? imported) {
  final parent = outer?.trim();
  final child = imported?.trim();
  if (parent == null || parent.isEmpty) {
    return _CombinedMedia(child == null || child.isEmpty ? null : child, true);
  }
  if (child == null || child.isEmpty) return _CombinedMedia(parent, true);

  final outerQueries = _parseMediaQueries(parent);
  final importQueries = _parseMediaQueries(child);
  if (outerQueries == null || importQueries == null) {
    return _CombinedMedia(
      tr("{0} and {1}", [parent, child]),
      false,
      tr("The outer and imported media conditions could not be combined."),
    );
  }
  final combinations = <String>[
    for (final outerQuery in outerQueries)
      for (final importQuery in importQueries)
        tr("{0} and {1}", [
          _mediaQuerySourceText(outerQuery),
          _mediaQuerySourceText(importQuery),
        ]),
  ];
  return _CombinedMedia(combinations.join(', '), true);
}

List<css.MediaQuery>? _parseMediaQueries(String media) {
  final parsed = _parseCss('@media $media {}', tr("media condition"));
  if (parsed.messages.isNotEmpty || parsed.stylesheet == null) return null;
  for (final node in parsed.stylesheet!.topLevels) {
    if (node is css.MediaDirective) return node.mediaQueries;
  }
  return null;
}

String? _mediaQueriesText(List<css.MediaQuery> queries) {
  if (queries.isEmpty) return null;
  return queries.map(_mediaQuerySourceText).join(', ');
}

class _ParsedMedia {
  const _ParsedMedia(this.queries, this.messages);

  final List<css.MediaQuery>? queries;
  final List<css_parser.Message> messages;
}

_ParsedMedia _parseMediaText(String media, String baseUrl) {
  final parsed = _parseCss('@media $media {}', baseUrl);
  for (final node in parsed.stylesheet?.topLevels ?? const <css.TreeNode>[]) {
    if (node is css.MediaDirective) {
      return _ParsedMedia(node.mediaQueries, parsed.messages);
    }
  }
  return _ParsedMedia(null, parsed.messages);
}

String _mediaQuerySourceText(css.MediaQuery query) {
  final source = query.span.text.trim();
  if (!query.hasUnary) return source;
  return '${query.unary.toLowerCase()} $source';
}

bool _hasUnsupportedMediaBooleanSyntax(String source) {
  var quote = '';
  var inComment = false;
  var parenthesisDepth = 0;
  for (var index = 0; index < source.length; index++) {
    final character = source[index];
    final next = index + 1 < source.length ? source[index + 1] : '';
    if (inComment) {
      if (character == '*' && next == '/') {
        inComment = false;
        index++;
      }
      continue;
    }
    if (quote.isNotEmpty) {
      if (character == r'\') {
        index++;
      } else if (character == quote) {
        quote = '';
      }
      continue;
    }
    if (character == '/' && next == '*') {
      inComment = true;
      index++;
    } else if (character == '"' || character == "'") {
      quote = character;
    } else if (character == r'\') {
      index++;
    } else if (character == '(') {
      parenthesisDepth++;
      if (parenthesisDepth > 1) return true;
    } else if (character == ')') {
      if (parenthesisDepth == 0) return true;
      parenthesisDepth--;
    } else if (character == '<' || character == '>' || character == '=') {
      return true;
    } else if (character.toLowerCase() == 'o' && next.toLowerCase() == 'r') {
      final before = index == 0 ? '' : source[index - 1];
      final after = index + 2 < source.length ? source[index + 2] : '';
      if (!_isMediaIdentifierCharacter(before) &&
          !_isMediaIdentifierCharacter(after)) {
        return true;
      }
    }
  }
  return parenthesisDepth != 0 || quote.isNotEmpty || inComment;
}

bool _isMediaIdentifierCharacter(String value) {
  if (value.isEmpty) return false;
  final code = value.codeUnitAt(0);
  return (code >= 0x30 && code <= 0x39) ||
      (code >= 0x41 && code <= 0x5a) ||
      (code >= 0x61 && code <= 0x7a) ||
      code == 0x2d ||
      code == 0x5f;
}

String _expressionText(css.Expression expression) {
  final printer = css.CssPrinter();
  expression.visit(printer);
  return printer.toString().trim();
}

_Specificity _specificity(css.Selector selector) {
  var result = _Specificity.zero;
  for (final sequence in selector.simpleSelectorSequences) {
    result += _simpleSpecificity(sequence.simpleSelector);
  }
  return result;
}

_Specificity _simpleSpecificity(css.SimpleSelector selector) {
  if (selector is css.IdSelector) return const _Specificity(1, 0, 0);
  if (selector is css.ClassSelector || selector is css.AttributeSelector) {
    return const _Specificity(0, 1, 0);
  }
  if (selector is css.NegationSelector) {
    final argument = selector.negationArg;
    return argument == null ? _Specificity.zero : _simpleSpecificity(argument);
  }
  if (selector is css.PseudoClassFunctionSelector ||
      selector is css.PseudoClassSelector) {
    return const _Specificity(0, 1, 0);
  }
  if (selector is css.PseudoElementSelector) {
    return const _Specificity(0, 0, 1);
  }
  if (selector is css.NamespaceSelector) {
    final element = selector.nameAsSimpleSelector;
    return element == null || element.isWildcard
        ? _Specificity.zero
        : const _Specificity(0, 0, 1);
  }
  if (selector is css.ElementSelector && !selector.isWildcard) {
    return const _Specificity(0, 0, 1);
  }
  return _Specificity.zero;
}

String? _selectorUnsupportedReason(css.Selector selector) {
  for (final sequence in selector.simpleSelectorSequences) {
    final reason = _simpleSelectorUnsupportedReason(sequence.simpleSelector);
    if (reason != null) return reason;
  }
  return null;
}

String? _simpleSelectorUnsupportedReason(css.SimpleSelector selector) {
  if (selector is css.PseudoElementSelector) {
    return tr("Pseudo-elements cannot be mapped to HTML elements.");
  }
  if (selector is css.PseudoClassFunctionSelector) {
    if (selector.name == 'lang') return null;
    if (selector.name == 'nth-child') {
      if (_numericNthChildIndex(selector) != null) return null;
      return tr("Only numeric :nth-child(n) selectors are supported.");
    }
    return tr("The :{0}() pseudo-class is not supported.", [selector.name]);
  }
  if (selector is css.PseudoClassSelector) {
    if (selector.name == 'visited') {
      return tr(
        ":visited depends on private browsing state and is not applied.",
      );
    }
    if (const {
      'root',
      'target',
      'empty',
      'blank',
      'first-child',
      'last-child',
      'only-child',
      'link',
    }.contains(selector.name)) {
      return null;
    }
    return tr("The :{0} pseudo-class is not supported.", [selector.name]);
  }
  if (selector is css.NegationSelector) {
    final argument = selector.negationArg;
    return argument == null
        ? tr("An empty :not() selector is unsupported.")
        : _simpleSelectorUnsupportedReason(argument);
  }
  if (selector is css.NamespaceSelector) {
    if (selector.namespace.isNotEmpty && selector.namespace != '*') {
      return tr("Named CSS namespaces are unsupported.");
    }
    final name = selector.nameAsSimpleSelector;
    if (name != null) return _simpleSelectorUnsupportedReason(name);
  }
  if (selector is css.ElementSelector ||
      selector is css.IdSelector ||
      selector is css.ClassSelector ||
      selector is css.AttributeSelector) {
    return null;
  }
  return tr("Selector component {0} is unsupported.", [selector.runtimeType]);
}

int? _numericNthChildIndex(css.PseudoClassFunctionSelector selector) {
  if (selector.name != 'nth-child') return null;
  final expressions = selector.expression.expressions;
  if (expressions.length != 1 || expressions.single is! css.LiteralTerm) {
    return null;
  }
  final value = (expressions.single as css.LiteralTerm).value;
  if (value is! num || !value.isFinite || value <= 0 || value % 1 != 0) {
    return null;
  }
  return value.toInt();
}

class _RootSelectorCollector extends css.Visitor {
  _RootSelectorCollector([this.name = 'root']);
  final String name;
  final selectors = <css.PseudoClassSelector>[];
  @override
  dynamic visitPseudoClassSelector(css.PseudoClassSelector node) {
    if (node.name.toLowerCase() == name) selectors.add(node);
    return super.visitPseudoClassSelector(node);
  }

  @override
  dynamic visitNegationSelector(css.NegationSelector node) {
    node.negationArg?.visit(this);
  }
}

/// Records CSS constructs that can make a canvas backing-size attribute affect
/// native layout through style matching or computed declaration values.
///
/// `css.Visitor` does not descend into `:not()` or functional pseudo-class
/// arguments by default, so those edges are followed explicitly. Unsupported
/// selector forms and imports fail closed because their complete dependency
/// surface cannot be proven here.
class _CanvasBitmapDependencyCollector extends css.Visitor {
  bool hasAttributeSelector = false;
  bool hasTextDependentSelector = false;
  bool hasImportantBoxDeclaration = false;
  bool hasAttrFunction = false;
  bool hasUnsupportedSelector = false;
  bool hasUnsupportedRule = false;

  @override
  dynamic visitPseudoClassSelector(css.PseudoClassSelector node) {
    if (const {'empty', 'blank'}.contains(node.name.toLowerCase())) {
      hasTextDependentSelector = true;
    }
    return super.visitPseudoClassSelector(node);
  }

  @override
  dynamic visitAttributeSelector(css.AttributeSelector node) {
    hasAttributeSelector = true;
    return super.visitAttributeSelector(node);
  }

  @override
  dynamic visitFunctionTerm(css.FunctionTerm node) {
    if (node.value.toString().toLowerCase() == 'attr') {
      hasAttrFunction = true;
    }
    return super.visitFunctionTerm(node);
  }

  @override
  dynamic visitSelector(css.Selector node) {
    if (_selectorUnsupportedReason(node) != null) {
      hasUnsupportedSelector = true;
    }
    return super.visitSelector(node);
  }

  @override
  dynamic visitNegationSelector(css.NegationSelector node) {
    node.negationArg?.visit(this);
  }

  @override
  dynamic visitPseudoClassFunctionSelector(
    css.PseudoClassFunctionSelector node,
  ) {
    node.argument.visit(this);
    return super.visitPseudoClassFunctionSelector(node);
  }

  @override
  dynamic visitPseudoElementFunctionSelector(
    css.PseudoElementFunctionSelector node,
  ) {
    hasUnsupportedSelector = true;
    node.expression.visit(this);
  }

  @override
  dynamic visitDeclarationGroup(css.DeclarationGroup node) {
    if (node.declarations.whereType<css.Declaration>().any(
      (declaration) =>
          declaration.important &&
          const {
            'display',
            'box-sizing',
            'width',
            'height',
          }.contains(declaration.property.toLowerCase()),
    )) {
      hasImportantBoxDeclaration = true;
    }
    if (node.declarations.any(
      (declaration) => declaration is! css.Declaration,
    )) {
      hasUnsupportedRule = true;
    }
    return super.visitDeclarationGroup(node);
  }

  @override
  dynamic visitImportDirective(css.ImportDirective node) {
    // A source-level result cannot assert that a fetched import is represented
    // by this cascade. Navigation currently flattens imports into sources, but
    // keeping the parent import in the proof input must remain conservative.
    hasUnsupportedRule = true;
    return super.visitImportDirective(node);
  }
}

class _NthChildSelectorCollector extends css.Visitor {
  final selectors = <css.PseudoClassFunctionSelector>[];

  @override
  dynamic visitPseudoClassFunctionSelector(
    css.PseudoClassFunctionSelector node,
  ) {
    if (node.name == 'nth-child') selectors.add(node);
    return super.visitPseudoClassFunctionSelector(node);
  }

  @override
  dynamic visitNegationSelector(css.NegationSelector node) {
    node.negationArg?.visit(this);
  }
}

class _SelectorRangeReplacement {
  const _SelectorRangeReplacement({
    required this.start,
    required this.end,
    required this.text,
  });

  final int start;
  final int end;
  final String text;
}
