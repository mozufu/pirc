import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_math_fork/flutter_math.dart' show Math;

import 'native_inline_math.dart';
import 'native_math_error.dart';
import 'native_math_paragraph_selection.dart';
import 'native_tex_adapter.dart';

/// Inline or display math emitted by the Markdown math builder.
///
/// This marker keeps the source Math widget intact until its paragraph parent
/// can decide whether it is safe to turn an ordinary inline formula into
/// breakable RichText placeholders. Its standalone build preserves the
/// original semantics-to-Math relationship.
class NativeMarkdownMath extends StatelessWidget {
  const NativeMarkdownMath({
    super.key,
    required this.math,
    required this.bodyFontSize,
    required this.lineHeight,
    required this.display,
    this.bodyStyle,
    this.disableTextScaling = false,
  });

  final NativeMathTex math;
  final double bodyFontSize;
  final double lineHeight;
  final bool display;
  final TextStyle? bodyStyle;
  final bool disableTextScaling;

  @override
  Widget build(BuildContext context) {
    final child = Semantics(label: math.expression, child: math);
    return disableTextScaling
        ? MediaQuery.withNoTextScaling(child: child)
        : child;
  }
}

/// Original and rendered pieces for one formula expanded inside a paragraph.
class NativeParagraphMathFormula {
  const NativeParagraphMathFormula({
    required this.index,
    required this.source,
    required this.math,
    required this.parts,
  });

  /// Index within the containing [NativeMathParagraphContent].
  final int index;
  final NativeMathTex source;
  final Math math;
  final List<Math> parts;
}

/// The painted TeX part represented by one RichText placeholder.
class NativeMathPart extends StatelessWidget {
  const NativeMathPart({
    super.key,
    required this.formulaIndex,
    required this.partIndex,
    required this.math,
    this.semanticsLabel,
    this.excludeSemantics = false,
    this.clipboardPrefix,
    this.clipboardFullText,
  });

  final int formulaIndex;
  final int partIndex;
  final Math math;
  final String? semanticsLabel;
  final bool excludeSemantics;
  final String? clipboardPrefix;
  final String? clipboardFullText;

  @override
  Widget build(BuildContext context) {
    final child = NativeMathInlinePart(
      math: math,
      semanticsLabel: semanticsLabel,
      excludeSemantics: excludeSemantics,
    );
    return clipboardPrefix == null && clipboardFullText == null
        ? child
        : NativeMathClipboardPart(
            prefix: clipboardPrefix ?? '',
            fullText: clipboardFullText,
            child: child,
          );
  }
}

/// Diagnostic metadata for a RichText run containing expanded inline math.
///
/// [formulas] retain the original source Math models, while [child] contains
/// only the actual rendered break parts. The original full formula is never
/// mounted as a second painted widget.
class NativeMathParagraphContent extends StatelessWidget {
  NativeMathParagraphContent({
    super.key,
    required List<NativeParagraphMathFormula> formulas,
    required this.child,
  }) : formulas = List<NativeParagraphMathFormula>.unmodifiable(formulas);

  final List<NativeParagraphMathFormula> formulas;
  final Widget child;

  @override
  Widget build(BuildContext context) => child;
}

typedef NativeMathInlineMarkerBuilder =
    NativeMarkdownMath? Function(
      BuildContext context,
      TextStyle effectiveStyle, {
      TextStyle? precedingTextStyle,
      TextStyle? followingTextStyle,
    });

typedef NativeMathInlineWidgetWrapper =
    Widget Function(
      BuildContext context,
      Widget child,
      GestureRecognizer? inheritedRecognizer,
    );

/// One inline widget emitted by an HTML [BuildTree]. Slots are kept in the
/// same order as its inline [WidgetBit]s, including non-math widgets, so the
/// adapter can verify that it is rewriting the exact placeholder it was
/// given.
class NativeMathInlineSlot {
  const NativeMathInlineSlot({
    required this.expectedWidget,
    this.sourceId,
    this.buildMarker,
    this.wrapMathWidget,
  });

  final Widget expectedWidget;
  final String? sourceId;
  final NativeMathInlineMarkerBuilder? buildMarker;
  final NativeMathInlineWidgetWrapper? wrapMathWidget;
}

typedef NativeMathParagraphRichTextBuilder =
    RichText Function(
      RichText source,
      InlineSpan text,
      SelectionRegistrar? selectionRegistrar,
    );

/// Reassembles Markdown's inline Wrap children into prose that can break
/// around ordinary inline TeX formulas.
///
/// Adjacent Text and RichText children are collected into RichText runs. Math
/// source markers are resolved in this build context, after Markdown has
/// established its no-text-scaling subtree. Other inline widgets remain
/// WidgetSpan children in those runs. Display math splits the surrounding
/// inline runs into a Column and stays mounted as its original NativeMathTex
/// widget, preserving equation numbering and display layout.
class NativeMathParagraph extends StatelessWidget {
  const NativeMathParagraph({
    super.key,
    required this.children,
    this.alignment = WrapAlignment.start,
  });

  /// Applies an HTML-resolved text style to a standalone math marker.
  ///
  /// flutter_widget_from_html may unwrap a paragraph containing only one
  /// WidgetSpan before it calls [WidgetFactory.buildText]. In that case the
  /// normal RichText adapter cannot prepare the math marker, so the owning
  /// HTML BuildTree uses this same normalization at its inline placeholder.
  /// Its [bodyStyle] is already text-scaled by the HTML style resolver.
  static NativeMarkdownMath styleStandaloneMarker(
    NativeMarkdownMath marker,
    TextStyle bodyStyle,
  ) {
    final bodyFontSize = bodyStyle.fontSize ?? marker.bodyFontSize;
    final lineHeight = bodyStyle.height ?? marker.lineHeight;
    final original = marker.math;
    final originalTextStyle = original.textStyle ?? const TextStyle();
    final styledMath = NativeMathTex(
      original.expression,
      key: original.key,
      mathStyle: original.mathStyle,
      textStyle: originalTextStyle.copyWith(
        inherit: false,
        fontSize: bodyFontSize * 1.08,
        color: bodyStyle.color ?? originalTextStyle.color,
        fontWeight: FontWeight.normal,
        fontStyle: FontStyle.normal,
      ),
      onErrorFallback: (error) {
        final fallback = original.onErrorFallback(error);
        if (fallback is NativeMathErrorText) {
          return NativeMathErrorText(
            key: fallback.key,
            source: fallback.source,
            bodyFontSize: bodyFontSize,
            lineHeight: lineHeight,
            block: marker.display,
            fontFamily: bodyStyle.fontFamily ?? fallback.fontFamily,
          );
        }
        return fallback;
      },
      onParsed: original.onParsed,
      settings: original.settings,
      // The HTML style resolver has already applied its text scale.
      textScaleFactor: 1,
      logicalPpi: original.logicalPpi,
      options: original.options,
      firstEquationNumber: original.firstEquationNumber,
    );
    return NativeMarkdownMath(
      key: marker.key,
      math: styledMath,
      bodyFontSize: bodyFontSize,
      lineHeight: lineHeight,
      display: marker.display,
      bodyStyle: bodyStyle,
      disableTextScaling: true,
    );
  }

  final List<Widget> children;
  final WrapAlignment alignment;

  /// Rewrites only verified HTML inline-math placeholders in [source].
  /// [slots] must have one entry for each inline WidgetBit, in flattening
  /// order, and each entry must identify the exact WidgetPlaceholder child.
  /// If the source tree and span stream disagree, [source] is returned
  /// unchanged instead of risking a replacement of a control or image.
  static Widget adaptRichText(
    RichText source, {
    required List<NativeMathInlineSlot> slots,
    NativeMathParagraphRichTextBuilder? richTextBuilder,
  }) => _NativeMathRichTextAdapter(
    source: source,
    slots: slots,
    richTextBuilder: richTextBuilder,
  );

  @override
  Widget build(BuildContext context) {
    if (!children.any((child) => child is NativeMarkdownMath)) {
      return _wrap(children);
    }

    final blocks = <Widget>[];
    final flowChildren = <Widget>[];
    var spans = <InlineSpan>[];
    var formulas = <NativeParagraphMathFormula>[];
    var syntheticMarkerOffsets = <int>[];
    var runTextLength = 0;
    _ParagraphTextStyle? runStyle;
    double? runBodyFontSize;
    double? runLineHeight;
    var sawDisplayMath = false;

    void appendSpan(InlineSpan span) {
      spans.add(span);
      runTextLength += span.toPlainText(includeSemanticsLabels: false).length;
    }

    void flushRichText() {
      if (spans.isEmpty) return;
      final style = runStyle ?? _ParagraphTextStyle.defaults(context);
      final scaledBaseStyle = _scaleTextStyle(
        style.baseStyle,
        style.textScaler,
      );
      final strut = _effectiveStrut(
        style,
        scaledBaseStyle,
        bodyFontSize: runBodyFontSize,
        lineHeight: runLineHeight,
      );
      final registrar = SelectionContainer.maybeOf(context);
      final selectionRegistrar = nativeMathParagraphSelectionRegistrar(
        registrar,
        syntheticMarkerOffsets,
      );
      final richText = _NativeMathRichText(
        text: TextSpan(style: scaledBaseStyle, children: spans),
        textAlign: style.textAlign,
        textDirection: style.textDirection,
        locale: style.locale,
        softWrap: style.softWrap,
        overflow: style.overflow ?? TextOverflow.visible,
        textScaler: TextScaler.noScaling,
        maxLines: style.maxLines,
        strutStyle: strut,
        textWidthBasis: style.textWidthBasis,
        textHeightBehavior: style.textHeightBehavior,
        selectionRegistrar: selectionRegistrar,
        selectionColor: style.selectionColor,
      );
      Widget content = NativeMathParagraphContent(
        formulas: formulas,
        child: richText,
      );
      if (registrar != null) {
        content = MouseRegion(
          cursor:
              DefaultSelectionStyle.of(context).mouseCursor ??
              SystemMouseCursors.text,
          child: content,
        );
      }
      flowChildren.add(content);
      spans = <InlineSpan>[];
      formulas = <NativeParagraphMathFormula>[];
      syntheticMarkerOffsets = <int>[];
      runTextLength = 0;
      runStyle = null;
      runBodyFontSize = null;
      runLineHeight = null;
    }

    void flushFlow() {
      flushRichText();
      if (flowChildren.isEmpty) return;
      blocks.add(_wrap(List<Widget>.of(flowChildren)));
      flowChildren.clear();
    }

    void startOrUpdateStyle(_ParagraphTextStyle next) {
      final existing = runStyle;
      if (existing != null && !existing.sameLayoutAs(next)) flushRichText();
      runStyle ??= next;
    }

    void addMathMarker(NativeMarkdownMath marker) {
      if (marker.display) {
        flushFlow();
        blocks.add(marker);
        sawDisplayMath = true;
        return;
      }

      final resolved = marker.math.resolve(context);
      final math = resolved.math;
      if (resolved.tags.isNotEmpty) {
        flushRichText();
        flowChildren.add(marker);
        return;
      }

      final style = _ParagraphTextStyle.defaults(
        context,
        bodyStyle: marker.bodyStyle,
        bodyFontSize: marker.bodyFontSize,
        lineHeight: marker.lineHeight,
      );
      // Math is an inline placeholder, not a new paragraph. In particular,
      // don't let the marker's synthesized defaults split a flutter_markdown
      // Text.rich run that carries its own strut/locale settings.
      runStyle ??= style;
      runBodyFontSize ??= marker.bodyFontSize;
      runLineHeight ??= marker.lineHeight;

      final formulaIndex = formulas.length;
      if (math.parseError != null) {
        formulas.add(
          NativeParagraphMathFormula(
            index: formulaIndex,
            source: marker.math,
            math: math,
            parts: const [],
          ),
        );
        final sourceText = _collapseAsciiWhitespace(marker.math.expression);
        if (sourceText.isNotEmpty) {
          final base = runStyle!.baseStyle;
          appendSpan(
            TextSpan(
              text: sourceText,
              semanticsLabel: marker.math.expression,
              style: _scaleTextStyle(
                base.copyWith(
                  fontSize: marker.bodyFontSize,
                  height: marker.lineHeight,
                  color: const Color(0xffcc0000),
                ),
                runStyle!.textScaler,
              ),
            ),
          );
        }
        return;
      }

      final parts = nativeMathParagraphBreakParts(math);
      final clipboardPlan = nativeMathClipboardPlan(math);
      formulas.add(
        NativeParagraphMathFormula(
          index: formulaIndex,
          source: marker.math,
          math: math,
          parts: parts,
        ),
      );
      for (var partIndex = 0; partIndex < parts.length; partIndex++) {
        appendSpan(
          WidgetSpan(
            alignment: PlaceholderAlignment.baseline,
            baseline: TextBaseline.alphabetic,
            style: _scaleTextStyle(runStyle!.baseStyle, runStyle!.textScaler),
            child: NativeMathPart(
              formulaIndex: formulaIndex,
              partIndex: partIndex,
              math: parts[partIndex],
              clipboardPrefix: partIndex == 0 ? clipboardPlan?.prefix : null,
              clipboardFullText: clipboardPlan?.fullVisualText == null
                  ? null
                  : partIndex == 0
                  ? '${clipboardPlan!.prefix}${clipboardPlan.fullVisualText}'
                  : '',
              semanticsLabel: partIndex == 0 ? marker.math.expression : null,
              excludeSemantics: partIndex > 0,
            ),
          ),
        );
        // Paragraph struts don't create a text run on a line containing only
        // WidgetSpan placeholders. This U+200B text span provides the body's
        // actual font/line-height metrics without painting or changing the
        // visible line content. Its source offset is filtered at copy time.
        syntheticMarkerOffsets.add(runTextLength);
        final mergedBodyStyle = runStyle!.baseStyle.merge(marker.bodyStyle);
        final markerBodyStyle = mergedBodyStyle.copyWith(
          fontSize: marker.bodyStyle?.fontSize ?? marker.bodyFontSize,
          height: marker.bodyStyle?.height ?? marker.lineHeight,
        );
        appendSpan(
          TextSpan(
            text: '\u200b',
            semanticsLabel: '',
            style: _scaleTextStyle(markerBodyStyle, runStyle!.textScaler),
          ),
        );
      }
    }

    for (final child in children) {
      if (child case final NativeMarkdownMath marker) {
        addMathMarker(marker);
        continue;
      }
      final fragment = _textFragment(context, child);
      if (fragment == null) {
        // Inline code renderers, images and other Markdown widgets belong in
        // the same paragraph's placeholder stream. Pulling them out into the
        // outer Wrap changes line breaking around neighboring math and prose.
        final style = runStyle ?? _ParagraphTextStyle.defaults(context);
        startOrUpdateStyle(style);
        appendSpan(
          WidgetSpan(
            alignment: PlaceholderAlignment.middle,
            style: _scaleTextStyle(runStyle!.baseStyle, runStyle!.textScaler),
            child: child,
          ),
        );
        continue;
      }
      startOrUpdateStyle(fragment.style);
      appendSpan(fragment.span);
    }
    flushFlow();

    if (!sawDisplayMath) {
      return blocks.isEmpty ? _wrap(const []) : blocks.single;
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: blocks,
    );
  }

  Wrap _wrap(List<Widget> children) => Wrap(
    alignment: alignment,
    crossAxisAlignment: WrapCrossAlignment.center,
    children: children,
  );
}

class _InlineMathTextNeighbors {
  const _InlineMathTextNeighbors({this.preceding, this.following});

  final TextStyle? preceding;
  final TextStyle? following;
}

class _InlineMathSpanEntry {
  const _InlineMathSpanEntry(this.span, this.style, {required this.isText});

  final InlineSpan span;
  final TextStyle style;
  final bool isText;
}

Map<WidgetSpan, _InlineMathTextNeighbors> _neighboringTextStyles(
  InlineSpan root,
  TextStyle rootStyle,
) {
  final entries = <_InlineMathSpanEntry>[];
  void visit(InlineSpan span, TextStyle inherited) {
    if (span is TextSpan) {
      final effective = inherited.merge(span.style);
      if (span.text?.isNotEmpty == true) {
        entries.add(_InlineMathSpanEntry(span, effective, isText: true));
      }
      for (final child in span.children ?? const <InlineSpan>[]) {
        visit(child, effective);
      }
    } else if (span is WidgetSpan) {
      entries.add(
        _InlineMathSpanEntry(span, inherited.merge(span.style), isText: false),
      );
    }
  }

  visit(root, rootStyle);
  final result = <WidgetSpan, _InlineMathTextNeighbors>{};
  for (var index = 0; index < entries.length; index++) {
    final entry = entries[index];
    if (entry.span is! WidgetSpan) continue;
    TextStyle? preceding;
    TextStyle? following;
    for (var before = index - 1; before >= 0; before--) {
      if (entries[before].isText) {
        preceding = entries[before].style;
        break;
      }
    }
    for (var after = index + 1; after < entries.length; after++) {
      if (entries[after].isText) {
        following = entries[after].style;
        break;
      }
    }
    result[entry.span as WidgetSpan] = _InlineMathTextNeighbors(
      preceding: preceding,
      following: following,
    );
  }
  return result;
}

class _NativeMathRichTextAdapter extends StatelessWidget {
  const _NativeMathRichTextAdapter({
    required this.source,
    required this.slots,
    required this.richTextBuilder,
  });

  final RichText source;
  final List<NativeMathInlineSlot> slots;
  final NativeMathParagraphRichTextBuilder? richTextBuilder;

  @override
  Widget build(BuildContext context) {
    Widget unchanged() =>
        richTextBuilder?.call(source, source.text, source.selectionRegistrar) ??
        source;

    final widgetSpans = _collectWidgetSpans(source.text);
    if (widgetSpans.length != slots.length ||
        List<bool>.generate(
          slots.length,
          (index) =>
              identical(widgetSpans[index].child, slots[index].expectedWidget),
        ).any((matches) => !matches)) {
      return unchanged();
    }
    if (!slots.any((slot) => slot.buildMarker != null)) return unchanged();

    final formulas = <NativeParagraphMathFormula>[];
    final syntheticMarkerOffsets = <int>[];
    var slotIndex = 0;
    var textOffset = 0;
    var changed = false;
    final textScaler = source.textScaler;
    final rootStyle = source.text.style ?? DefaultTextStyle.of(context).style;
    final neighboringStyles = _neighboringTextStyles(source.text, rootStyle);

    InlineSpan transform(
      InlineSpan span,
      TextStyle inheritedStyle,
      GestureRecognizer? inheritedRecognizer,
    ) {
      if (span is TextSpan) {
        final effectiveStyle = inheritedStyle.merge(span.style);
        final effectiveRecognizer = span.recognizer ?? inheritedRecognizer;
        if (span.text != null) textOffset += span.text!.length;
        final children = span.children
            ?.map(
              (child) => transform(child, effectiveStyle, effectiveRecognizer),
            )
            .toList(growable: false);
        return TextSpan(
          text: span.text,
          children: children,
          style: span.style,
          recognizer: span.recognizer,
          mouseCursor: span.mouseCursor,
          onEnter: span.onEnter,
          onExit: span.onExit,
          semanticsLabel: span.semanticsLabel,
          semanticsIdentifier: span.semanticsIdentifier,
          locale: span.locale,
          spellOut: span.spellOut,
        );
      }

      if (span is! WidgetSpan) {
        textOffset += span.toPlainText(includeSemanticsLabels: false).length;
        return span;
      }

      final slot = slots[slotIndex++];
      final effectiveStyle = inheritedStyle.merge(span.style);
      final buildMarker = slot.buildMarker;
      if (buildMarker == null) {
        textOffset += span.toPlainText(includeSemanticsLabels: false).length;
        return span;
      }

      final neighbors = neighboringStyles[span];
      final marker = buildMarker(
        context,
        effectiveStyle,
        precedingTextStyle: neighbors?.preceding,
        followingTextStyle: neighbors?.following,
      );
      if (marker == null) {
        textOffset += span.toPlainText(includeSemanticsLabels: false).length;
        return span;
      }

      final markerStyle = marker.bodyStyle ?? effectiveStyle;
      final styledMarker = NativeMathParagraph.styleStandaloneMarker(
        marker,
        markerStyle,
      );
      if (styledMarker.display) {
        changed = true;
        textOffset += span.toPlainText(includeSemanticsLabels: false).length;
        return WidgetSpan(
          child:
              slot.wrapMathWidget?.call(
                context,
                styledMarker,
                inheritedRecognizer,
              ) ??
              styledMarker,
          alignment: span.alignment,
          baseline: span.baseline,
          style: span.style,
        );
      }

      final resolved = styledMarker.math.resolve(context);
      final math = resolved.math;
      if (math.parseError != null) {
        changed = true;
        final formulaIndex = formulas.length;
        formulas.add(
          NativeParagraphMathFormula(
            index: formulaIndex,
            source: styledMarker.math,
            math: math,
            parts: const [],
          ),
        );
        final sourceText = _collapseAsciiWhitespace(
          styledMarker.math.expression,
        );
        textOffset += sourceText.length;
        if (sourceText.isEmpty) return const TextSpan(text: '');
        return TextSpan(
          style: span.style,
          // Keep the error visible as ordinary prose while honoring its
          // inherited HTML font metrics and link recognizer.
          children: [
            TextSpan(
              text: sourceText,
              semanticsLabel: styledMarker.math.expression,
              style: _scaleTextStyle(
                markerStyle.copyWith(
                  fontSize: styledMarker.bodyFontSize,
                  height: styledMarker.lineHeight,
                  color: const Color(0xffcc0000),
                ),
                textScaler,
              ),
              recognizer: inheritedRecognizer,
            ),
          ],
        );
      }

      if (resolved.tags.isNotEmpty) {
        changed = true;
        textOffset += span.toPlainText(includeSemanticsLabels: false).length;
        return WidgetSpan(
          child:
              slot.wrapMathWidget?.call(
                context,
                styledMarker,
                inheritedRecognizer,
              ) ??
              styledMarker,
          alignment: span.alignment,
          baseline: span.baseline,
          style: span.style,
        );
      }

      changed = true;
      final parts = nativeMathParagraphBreakParts(math);
      final clipboardPlan = nativeMathClipboardPlan(math);
      final formulaIndex = formulas.length;
      formulas.add(
        NativeParagraphMathFormula(
          index: formulaIndex,
          source: styledMarker.math,
          math: math,
          parts: parts,
        ),
      );
      final replacementChildren = <InlineSpan>[];
      for (var partIndex = 0; partIndex < parts.length; partIndex++) {
        final part = NativeMathPart(
          formulaIndex: formulaIndex,
          partIndex: partIndex,
          math: parts[partIndex],
          clipboardPrefix: partIndex == 0 ? clipboardPlan?.prefix : null,
          clipboardFullText: clipboardPlan?.fullVisualText == null
              ? null
              : partIndex == 0
              ? '${clipboardPlan!.prefix}${clipboardPlan.fullVisualText}'
              : '',
          semanticsLabel: partIndex == 0 ? styledMarker.math.expression : null,
          excludeSemantics: partIndex > 0,
        );
        replacementChildren.add(
          WidgetSpan(
            alignment: PlaceholderAlignment.baseline,
            baseline: TextBaseline.alphabetic,
            style: _scaleTextStyle(effectiveStyle, textScaler),
            child:
                slot.wrapMathWidget?.call(context, part, inheritedRecognizer) ??
                part,
          ),
        );
        textOffset++;
        syntheticMarkerOffsets.add(textOffset);
        replacementChildren.add(
          TextSpan(
            text: '\u200b',
            semanticsLabel: '',
            style: _scaleTextStyle(effectiveStyle, textScaler),
          ),
        );
        textOffset++;
      }
      return TextSpan(style: span.style, children: replacementChildren);
    }

    final transformed = transform(source.text, rootStyle, null);
    if (!changed) return unchanged();

    final selectionRegistrar = nativeMathParagraphSelectionRegistrar(
      source.selectionRegistrar,
      syntheticMarkerOffsets,
    );
    final richText =
        richTextBuilder?.call(source, transformed, selectionRegistrar) ??
        _NativeMathRichText(
          key: source.key,
          text: transformed,
          textAlign: source.textAlign,
          textDirection: source.textDirection,
          locale: source.locale,
          softWrap: source.softWrap,
          overflow: source.overflow,
          textScaler: source.textScaler,
          maxLines: source.maxLines,
          strutStyle: source.strutStyle,
          textWidthBasis: source.textWidthBasis,
          textHeightBehavior: source.textHeightBehavior,
          selectionRegistrar: selectionRegistrar,
          selectionColor: source.selectionColor,
        );
    return NativeMathParagraphContent(formulas: formulas, child: richText);
  }
}

List<WidgetSpan> _collectWidgetSpans(InlineSpan span) => switch (span) {
  TextSpan() => [
    for (final child in span.children ?? const <InlineSpan>[])
      ..._collectWidgetSpans(child),
  ],
  WidgetSpan() => [span],
  _ => const [],
};

class _TextFragment {
  const _TextFragment({required this.style, required this.span});
  final _ParagraphTextStyle style;
  final InlineSpan span;
}

/// RichText whose dry-baseline path avoids the unsupported RenderSemantics
/// wrapper installed by WidgetSpan for our Math placeholder subtrees.
class _NativeMathRichText extends RichText {
  _NativeMathRichText({
    super.key,
    required super.text,
    required super.textAlign,
    required super.textDirection,
    required super.softWrap,
    required super.overflow,
    required super.textScaler,
    required super.maxLines,
    required super.locale,
    required super.strutStyle,
    required super.textWidthBasis,
    required super.textHeightBehavior,
    required super.selectionRegistrar,
    required super.selectionColor,
  });

  @override
  RenderNativeMathParagraph createRenderObject(BuildContext context) {
    return RenderNativeMathParagraph(
      text,
      textAlign: textAlign,
      textDirection: textDirection ?? Directionality.of(context),
      softWrap: softWrap,
      overflow: overflow,
      textScaler: textScaler,
      maxLines: maxLines,
      locale: locale ?? Localizations.maybeLocaleOf(context),
      strutStyle: strutStyle,
      textWidthBasis: textWidthBasis,
      textHeightBehavior: textHeightBehavior,
      registrar: selectionRegistrar,
      selectionColor: selectionColor,
    );
  }
}

class RenderNativeMathParagraph extends RenderParagraph {
  RenderNativeMathParagraph(
    super.text, {
    super.textAlign,
    required super.textDirection,
    super.softWrap,
    super.overflow,
    super.textScaler,
    super.maxLines,
    super.locale,
    super.strutStyle,
    super.textWidthBasis,
    super.textHeightBehavior,
    super.children,
    super.selectionColor,
    super.registrar,
  });

  @override
  List<PlaceholderDimensions> layoutInlineChildren(
    double maxWidth,
    ChildLayouter layoutChild,
    ChildBaselineGetter getChildBaseline,
  ) {
    final dryBaseline = getChildBaseline == ChildLayoutHelper.getDryBaseline;
    return super.layoutInlineChildren(maxWidth, layoutChild, (
      child,
      constraints,
      baseline,
    ) {
      if (dryBaseline && _containsNativeInlineMath(child)) return null;
      return getChildBaseline(child, constraints, baseline);
    });
  }
}

bool _containsNativeInlineMath(RenderObject root) {
  if (root is RenderNativeInlineMath) return true;
  var contains = false;
  root.visitChildren((child) {
    if (!contains) contains = _containsNativeInlineMath(child);
  });
  return contains;
}

class _ParagraphTextStyle {
  const _ParagraphTextStyle({
    required this.baseStyle,
    required this.textScaler,
    required this.textAlign,
    required this.textDirection,
    required this.locale,
    required this.softWrap,
    required this.overflow,
    required this.maxLines,
    required this.strutStyle,
    required this.textWidthBasis,
    required this.textHeightBehavior,
    required this.selectionColor,
  });

  factory _ParagraphTextStyle.defaults(
    BuildContext context, {
    TextStyle? bodyStyle,
    double? bodyFontSize,
    double? lineHeight,
  }) {
    final defaults = DefaultTextStyle.of(context);
    final base = defaults.style.merge(bodyStyle);
    return _ParagraphTextStyle(
      baseStyle: base.copyWith(
        fontSize: base.fontSize ?? bodyFontSize ?? 14,
        height: base.height ?? lineHeight,
      ),
      textScaler: MediaQuery.textScalerOf(context),
      textAlign: defaults.textAlign ?? TextAlign.start,
      textDirection: Directionality.of(context),
      locale: Localizations.maybeLocaleOf(context),
      softWrap: defaults.softWrap,
      overflow: base.overflow ?? _nonDefaultOverflow(defaults.overflow),
      maxLines: defaults.maxLines,
      strutStyle: null,
      textWidthBasis: defaults.textWidthBasis,
      textHeightBehavior:
          defaults.textHeightBehavior ??
          DefaultTextHeightBehavior.maybeOf(context),
      selectionColor: _selectionColor(context),
    );
  }

  final TextStyle baseStyle;
  final TextScaler textScaler;
  final TextAlign textAlign;
  final TextDirection textDirection;
  final Locale? locale;
  final bool softWrap;
  final TextOverflow? overflow;
  final int? maxLines;
  final StrutStyle? strutStyle;
  final TextWidthBasis textWidthBasis;
  final TextHeightBehavior? textHeightBehavior;
  final Color selectionColor;

  bool sameLayoutAs(_ParagraphTextStyle other) =>
      textScaler == other.textScaler &&
      textAlign == other.textAlign &&
      textDirection == other.textDirection &&
      locale == other.locale &&
      softWrap == other.softWrap &&
      overflow == other.overflow &&
      maxLines == other.maxLines &&
      strutStyle == other.strutStyle &&
      textWidthBasis == other.textWidthBasis &&
      textHeightBehavior == other.textHeightBehavior &&
      selectionColor == other.selectionColor;
}

_TextFragment? _textFragment(BuildContext context, Widget widget) {
  final defaults = DefaultTextStyle.of(context);
  if (widget is Text) {
    final scaler = _textScalerForText(context, widget);
    final effectiveStyle = defaults.style.merge(widget.style);
    final sourceSpan = widget.textSpan;
    final span = sourceSpan == null
        ? TextSpan(
            text: widget.data,
            style: effectiveStyle,
            semanticsLabel: widget.semanticsLabel,
            semanticsIdentifier: widget.semanticsIdentifier,
            locale: widget.locale,
          )
        : TextSpan(
            style: effectiveStyle,
            locale: widget.locale,
            semanticsLabel: widget.semanticsLabel,
            semanticsIdentifier: widget.semanticsIdentifier,
            children: [sourceSpan],
          );
    return _TextFragment(
      style: _ParagraphTextStyle(
        baseStyle: effectiveStyle,
        textScaler: scaler,
        textAlign: widget.textAlign ?? defaults.textAlign ?? TextAlign.start,
        textDirection: widget.textDirection ?? Directionality.of(context),
        locale: widget.locale ?? Localizations.maybeLocaleOf(context),
        softWrap: widget.softWrap ?? defaults.softWrap,
        overflow:
            widget.overflow ??
            effectiveStyle.overflow ??
            _nonDefaultOverflow(defaults.overflow),
        maxLines: widget.maxLines ?? defaults.maxLines,
        strutStyle: widget.strutStyle,
        textWidthBasis: widget.textWidthBasis ?? defaults.textWidthBasis,
        textHeightBehavior:
            widget.textHeightBehavior ??
            defaults.textHeightBehavior ??
            DefaultTextHeightBehavior.maybeOf(context),
        selectionColor: widget.selectionColor ?? _selectionColor(context),
      ),
      span: _scaleInlineSpan(span, scaler),
    );
  }

  if (widget is RichText) {
    final span = widget.text;
    final baseStyle = span.style ?? defaults.style;
    return _TextFragment(
      style: _ParagraphTextStyle(
        baseStyle: baseStyle,
        textScaler: widget.textScaler,
        textAlign: widget.textAlign,
        textDirection: widget.textDirection ?? Directionality.of(context),
        locale: widget.locale ?? Localizations.maybeLocaleOf(context),
        softWrap: widget.softWrap,
        overflow: _nonDefaultOverflow(widget.overflow),
        maxLines: widget.maxLines,
        strutStyle: widget.strutStyle,
        textWidthBasis: widget.textWidthBasis,
        textHeightBehavior: widget.textHeightBehavior,
        selectionColor: widget.selectionColor ?? _selectionColor(context),
      ),
      span: _scaleInlineSpan(
        span.style == null
            ? TextSpan(style: baseStyle, children: [span])
            : span,
        widget.textScaler,
      ),
    );
  }
  return null;
}

// Text.textScaleFactor remains supported for source widgets that have not
// migrated to a TextScaler. The paragraph output itself always uses noScaling.
TextScaler _textScalerForText(BuildContext context, Text text) {
  final textScaler = text.textScaler;
  if (textScaler != null) return textScaler;
  // ignore: deprecated_member_use
  final textScaleFactor = text.textScaleFactor;
  return textScaleFactor == null
      ? MediaQuery.textScalerOf(context)
      : TextScaler.linear(textScaleFactor);
}

Color _selectionColor(BuildContext context) =>
    DefaultSelectionStyle.of(context).selectionColor ??
    DefaultSelectionStyle.defaultColor;

TextOverflow? _nonDefaultOverflow(TextOverflow? overflow) =>
    overflow == TextOverflow.clip ? null : overflow;

TextStyle _scaleTextStyle(TextStyle style, TextScaler scaler) =>
    style.fontSize == null
    ? style
    : style.copyWith(fontSize: scaler.scale(style.fontSize!));

InlineSpan _scaleInlineSpan(InlineSpan span, TextScaler scaler) =>
    switch (span) {
      TextSpan() => TextSpan(
        text: span.text,
        children: span.children
            ?.map((child) => _scaleInlineSpan(child, scaler))
            .toList(),
        style: span.style == null ? null : _scaleTextStyle(span.style!, scaler),
        recognizer: span.recognizer,
        mouseCursor: span.mouseCursor,
        onEnter: span.onEnter,
        onExit: span.onExit,
        semanticsLabel: span.semanticsLabel,
        semanticsIdentifier: span.semanticsIdentifier,
        locale: span.locale,
        spellOut: span.spellOut,
      ),
      WidgetSpan() => WidgetSpan(
        child: span.child,
        alignment: span.alignment,
        baseline: span.baseline,
        style: span.style == null ? null : _scaleTextStyle(span.style!, scaler),
      ),
      _ => span,
    };

StrutStyle? _effectiveStrut(
  _ParagraphTextStyle style,
  TextStyle scaledBaseStyle, {
  double? bodyFontSize,
  double? lineHeight,
}) {
  final source = style.strutStyle;
  if (source != null) {
    return StrutStyle(
      fontFamily: source.fontFamily,
      fontFamilyFallback: source.fontFamilyFallback,
      fontSize: source.fontSize == null
          ? null
          : style.textScaler.scale(source.fontSize!),
      height: source.height,
      leading: source.leading,
      leadingDistribution: source.leadingDistribution,
      fontWeight: source.fontWeight,
      fontStyle: source.fontStyle,
      // The source strut is a minimum line height. A tall Math placeholder
      // must still be allowed to increase the line box.
      forceStrutHeight: false,
      debugLabel: source.debugLabel,
    );
  }
  if (bodyFontSize == null && lineHeight == null) return null;
  final fontSize = style.baseStyle.fontSize ?? bodyFontSize ?? 14;
  return StrutStyle.fromTextStyle(
    scaledBaseStyle,
    fontSize: style.textScaler.scale(fontSize),
    height: style.baseStyle.height ?? lineHeight,
    leading: 0,
    leadingDistribution: TextLeadingDistribution.even,
    forceStrutHeight: false,
  );
}

String _collapseAsciiWhitespace(String source) =>
    source.replaceAll(RegExp(r'[\t\n\f\r ]+'), ' ').trim();
