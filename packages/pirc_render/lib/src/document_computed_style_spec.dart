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
