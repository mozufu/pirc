import 'html_form_submission.dart';
import 'html_media_box.dart';
import 'native_html.dart' show NativeHtmlLink, NativeHtmlMediaBuilder;
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart' show CharacterBoundary;
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_math_fork/flutter_math.dart';
import 'native_tex_adapter.dart';
import 'native_math_block.dart';
import 'native_math_error.dart';
import 'native_inline_math.dart';
import 'native_math_paragraph.dart';
import 'native_equation_numbers.dart';
import 'package:markdown/markdown.dart' as md;
import '../theme.dart';
import 'code_block.dart';
import 'mermaid/native_mermaid.dart';
import 'markdown_syntax.dart';
import 'markdown_file_links.dart';
import 'markdown_stream.dart';
import 'markdown_spacing.dart';
import 'markdown_cursor.dart';
import 'markdown_selection.dart';
import 'html_syntax.dart';
import '../live/remote_content_gate.dart' show nativeHeldMarkdownImage;

/// Flutter widgets only; no web view and no HTML/JS execution. All unsupported
/// rich-content cases remain visible and tracked in PARITY.md.
class NativeMarkdown extends StatefulWidget {
  const NativeMarkdown({
    super.key,
    required this.source,
    this.onLink,
    this.onHtmlNavigate,
    this.onFormSubmit,
    this.imageBuilder,
    this.mediaBuilder,
    this.fontSize,
    this.lineHeight,
    this.textColor,
    this.compact = false,
    this.streaming = false,
    this.fontWeight = FontWeight.w400,
    this.alignment = WrapAlignment.start,
    this.inlineOnly = false,
    this.linkReferences = const {},
  });
  final String source;
  final void Function(String)? onLink;
  final ValueChanged<NativeHtmlLink>? onHtmlNavigate;
  final ValueChanged<NativeHtmlFormSubmission>? onFormSubmit;
  final MarkdownImageBuilder? imageBuilder;
  final NativeHtmlMediaBuilder? mediaBuilder;
  final double? fontSize, lineHeight;
  final Color? textColor;
  final bool compact, streaming;
  final bool inlineOnly;
  final Map<String, md.LinkReference> linkReferences;
  final FontWeight fontWeight;
  final WrapAlignment alignment;
  @override
  State<NativeMarkdown> createState() => _NativeMarkdownState();
}

class _NativeMarkdownState extends State<NativeMarkdown> {
  String get source => widget.source;
  double? get fontSize => widget.fontSize;
  double? get lineHeight => widget.lineHeight;
  Color? get textColor => widget.textColor;
  bool get streaming => widget.streaming;
  bool get compact => widget.compact;
  bool get inlineOnly => widget.inlineOnly;
  Map<String, md.LinkReference> get linkReferences => widget.linkReferences;
  FontWeight get fontWeight => widget.fontWeight;
  WrapAlignment get alignment => widget.alignment;
  void onLink(String href) => widget.onLink?.call(href);
  @override
  Widget build(BuildContext context) => NativeEquationNumberDocument.ensure(
    context,
    NativeSelection(
      child: NativeSelectionGroup(
        blockSeparation: true,
        child: MarkdownStream(
          source: source,
          streaming: streaming,
          configuration: (
            fontSize,
            lineHeight,
            textColor,
            compact,
            inlineOnly,
            linkReferences,
            fontWeight,
            alignment,
            widget.imageBuilder != null,
          ),
          spacing: (fontSize ?? 15) * (compact ? .55 : .85),
          boundarySpacing: (previous, next) =>
              _boundarySpacing(context, previous, next),
          builder: (part, cursor, first, last) =>
              _body(context, part, cursor, first, last),
        ),
      ),
    ),
  );
  double _boundarySpacing(BuildContext context, String previous, String next) {
    List<md.Element> blocks(String value) => md.Document(
      extensionSet: md.ExtensionSet.gitHubFlavored,
      blockSyntaxes: const [
        NativeHtmlBlockSyntax(),
        NativeHeadingSyntax(),
        NativeMathBlockSyntax(),
        NativeFenceSyntax(),
        NativeTableSyntax(),
      ],
      encodeHtml: false,
    ).parseLines(value.split('\n')).whereType<md.Element>().toList();
    final before = blocks(previous), after = blocks(next);
    final size = fontSize ?? 15.0;
    return NativeMarkdownMargins(
      fontSize: size,
      paragraphSpacing: size * (compact ? .55 : .85),
      textScaler: MediaQuery.textScalerOf(context),
    ).gap(
      before.isEmpty ? md.Element.empty('p') : before.last,
      after.isEmpty ? md.Element.empty('p') : after.first,
    );
  }

  Widget _body(
    BuildContext context,
    String part,
    bool cursor,
    bool first,
    bool last,
  ) {
    final colors = Theme.of(context).extension<PircColors>()!;
    final phone = MediaQuery.sizeOf(context).width <= 650;
    final size = fontSize ?? 15.0;
    final em = MediaQuery.textScalerOf(context).scale(size);
    final height = lineHeight ?? (compact ? 1.6 : (phone ? 1.65 : 1.75));
    // Without a caller-supplied builder, images still go through the hold-back
    // for remote sources; the package default would fetch them on display.
    final imageUris = _MarkdownImageUris();
    Widget markdownImageBuilder(Uri uri, String? title, String? alt) =>
        (widget.imageBuilder ?? nativeHeldMarkdownImage)(
          imageUris.restore(uri),
          title,
          alt,
        );
    TextStyle heading(double scale) => TextStyle(
      fontSize: size * scale,
      height: 1.35,
      fontWeight: FontWeight.w700,
      color: colors['text.primary'],
    );
    return SelectionMarkdownBody(
      data: part,
      onFormSubmit: widget.onFormSubmit,
      onHtmlNavigate: widget.onHtmlNavigate,
      mediaBuilder: widget.mediaBuilder,
      documentStart: first,
      documentEnd: last,
      extensionSet: md.ExtensionSet.gitHubFlavored,
      blockSyntaxes: inlineOnly
          ? [NativeInlineBlockSyntax(linkReferences)]
          : const [
              NativeHtmlBlockSyntax(),
              NativeHeadingSyntax(),
              NativeMathBlockSyntax(),
              NativeFenceSyntax(),
              NativeTableSyntax(),
            ],
      inlineSyntaxes: [
        NativeHtmlInlineSyntax(),
        NativeMathInlineSyntax(),
        ...nativeFileLinkSyntaxes(),
      ],
      paddingBuilders: cursor ? cursorPlacement(part) : const {},
      builders: {
        'pirc-stream-cursor': NativeCursorBuilder(),
        'pirc-math': _MathBuilder(block: false, size: size, lineHeight: height),
        'pirc-math-block': _MathBuilder(
          block: true,
          size: size,
          lineHeight: height,
        ),
        'pirc-code': _CodeBuilder(
          ready: !streaming,
          fontSize: size,
          lineHeight: height,
        ),
        'code': _InlineCodeBuilder(size: size, onLink: onLink),
        'pirc-table': _TableBuilder(
          size: size,
          onLink: onLink,
          onHtmlNavigate: widget.onHtmlNavigate,
          onFormSubmit: widget.onFormSubmit,
          imageBuilder: markdownImageBuilder,
          mediaBuilder: widget.mediaBuilder,
        ),
      },
      checkboxBuilder: (checked) => NativeTaskCheckbox(checked: checked),
      imageBuilder: markdownImageBuilder,
      imageSourceTransform: imageUris.preserve,
      onTapLink: (_, href, _) {
        if (href != null) onLink(href);
      },
      styleSheet: MarkdownStyleSheet.fromTheme(Theme.of(context)).copyWith(
        textAlign: alignment,
        p: TextStyle(
          letterSpacing: 0,
          fontWeight: fontWeight,
          fontSize: size,
          height: height,
          color: textColor ?? colors['text.primary'],
        ),
        a: TextStyle(
          color: colors['accent.default'],
          decoration: TextDecoration.underline,
          decorationColor: colors['accent.default'].withValues(alpha: .35),
        ),
        strong: TextStyle(
          fontWeight: FontWeight.w700,
          color: colors['text.primary'],
        ),
        h1: heading(1.35),
        h2: heading(1.2),
        h3: heading(1.08),
        h4: heading(1),
        h5: heading(1),
        h6: heading(1),
        blockSpacing: size * (compact ? .55 : .85),
        listIndent: em * 1.5,
        listBulletPadding: EdgeInsets.zero,
        code: TextStyle(
          fontFamily: 'monospace',
          fontSize: size * .87,
          color: colors['text.primary'],
          backgroundColor: colors['surface.subtle'],
        ),
        codeblockDecoration: BoxDecoration(
          color: colors['code.bg'],
          borderRadius: BorderRadius.circular(12),
        ),
        blockquote: TextStyle(
          color: colors['text.muted'],
          fontSize: size,
          height: height,
        ),
        blockquotePadding: EdgeInsets.fromLTRB(
          3 + em * .95,
          em * .1,
          0,
          em * .1,
        ),
        blockquoteDecoration: BoxDecoration(
          border: Border(
            left: BorderSide(color: colors['line.strong'], width: 3),
          ),
        ),
        tableHead: TextStyle(
          fontSize: size * .92,
          height: 1.5,
          fontWeight: FontWeight.w600,
        ),
        tableBody: TextStyle(fontSize: size * .92, height: 1.5),
        tableColumnWidth: const IntrinsicColumnWidth(),
        tableHeadAlign: TextAlign.left,
        tableCellsPadding: const EdgeInsets.symmetric(
          horizontal: 10,
          vertical: 6,
        ),
        tableHeadCellsDecoration: BoxDecoration(
          color: colors['surface.subtle'],
        ),
        tableBorder: TableBorder(
          horizontalInside: BorderSide(color: colors['line.default']),
          top: BorderSide(color: colors['line.default']),
          bottom: BorderSide(color: colors['line.default']),
          left: BorderSide(color: colors['line.default']),
          right: BorderSide(color: colors['line.default']),
          borderRadius: BorderRadius.circular(12),
        ),
        horizontalRuleDecoration: BoxDecoration(
          border: Border(top: BorderSide(color: colors['line.default'])),
        ),
      ),
    );
  }
}

/// Protect URL fragments from the dependency's legacy size-hint split.
/// The encoded URI exists only in the parsed AST; the Markdown source stays
/// untouched and the custom loader receives the original URI.
class _MarkdownImageUris {
  final String _nonce = _newNonce();
  final Map<String, Uri> _sources = {};
  var _next = 0;

  String preserve(String source) {
    if (!source.contains('#')) return source;
    final original = Uri.tryParse(source);
    if (original == null) return source;
    final marker = Uri(
      scheme: 'pirc-markdown-fragment',
      host: _nonce,
      pathSegments: ['${_next++}'],
    ).toString();
    _sources[marker] = original;
    return marker;
  }

  Uri restore(Uri uri) => _sources[uri.toString()] ?? uri;

  static String _newNonce() {
    final random = math.Random.secure();
    return List.generate(
      16,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
  }
}

class _InlineCodeBuilder extends MarkdownElementBuilder {
  _InlineCodeBuilder({required this.size, required this.onLink});
  final double size;
  final void Function(String) onLink;
  @override
  Widget? visitElementAfterWithContext(
    BuildContext context,
    md.Element element,
    TextStyle? preferredStyle,
    TextStyle? parentStyle,
  ) {
    final colors = Theme.of(context).extension<PircColors>()!;
    final font = (parentStyle?.fontSize ?? size) * .87;
    final href = element.attributes['pirc-href'];
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors['web.bg-subtle'],
        borderRadius: BorderRadius.circular(6),
      ),
      child: Padding(
        padding: EdgeInsets.symmetric(
          horizontal: font * .4,
          vertical: font * .12,
        ),
        child: GestureDetector(
          onTap: href == null ? null : () => onLink(href),
          child: Text(
            element.textContent,
            style: (parentStyle ?? TextStyle(fontSize: size)).copyWith(
              fontFamily: 'monospace',
              fontSize: font,
              height: 1,
              color: colors['text.primary'],
              backgroundColor: Colors.transparent,
              decoration: href != null
                  ? TextDecoration.underline
                  : parentStyle?.decoration,
              decorationColor: href != null
                  ? colors['accent.default'].withValues(alpha: .35)
                  : parentStyle?.decorationColor,
            ),
          ),
        ),
      ),
    );
  }
}

class _MathBuilder extends MarkdownElementBuilder {
  _MathBuilder({
    required this.block,
    required this.size,
    required this.lineHeight,
  });
  final bool block;
  final double size, lineHeight;
  @override
  bool isBlockElement() => block;
  @override
  Widget? visitElementAfterWithContext(
    BuildContext context,
    md.Element element,
    TextStyle? preferredStyle,
    TextStyle? parentStyle,
  ) {
    final display = block || element.attributes['display'] == 'true';
    final fontSize = parentStyle?.fontSize ?? size;
    final height = parentStyle?.height ?? lineHeight;
    registerNativeTexExtensions();
    final colors = Theme.of(context).extension<PircColors>()!;
    return NativeMarkdownMath(
      bodyStyle: parentStyle,
      bodyFontSize: fontSize,
      lineHeight: height,
      display: display,
      math: NativeMathTex(
        element.textContent,
        mathStyle: display ? MathStyle.display : MathStyle.text,
        settings: TexParserSettings(
          displayMode: display,
          throwOnError: false,
          maxExpand: 500,
          strict: Strict.ignore,
        ),
        textStyle: TextStyle(
          fontSize: fontSize * 1.08,
          color: parentStyle?.color ?? colors['text.primary'],
        ),
        onParsed: display
            ? (_, math) => NativeMathDisplayBlock(
                bodyFontSize: fontSize,
                mathFontSize: fontSize * 1.08,
                child: math,
              )
            : (_, math) => NativeInlineMath(
                math: math as Math,
                bodyFontSize: fontSize,
                lineHeight: height,
              ),
        onErrorFallback: (_) => NativeMathErrorText(
          source: element.textContent,
          bodyFontSize: fontSize,
          lineHeight: height,
          block: block,
          fontFamily:
              parentStyle?.fontFamily ??
              Theme.of(context).textTheme.bodyMedium?.fontFamily,
        ),
      ),
    );
  }
}

class _CodeBuilder extends MarkdownElementBuilder {
  _CodeBuilder({
    required this.ready,
    required this.fontSize,
    required this.lineHeight,
  });
  final bool ready;
  final double fontSize, lineHeight;
  @override
  bool isBlockElement() => true;
  @override
  Widget? visitElementAfterWithContext(
    BuildContext context,
    md.Element element,
    TextStyle? preferredStyle,
    TextStyle? parentStyle,
  ) => element.attributes['language'] == 'mermaid'
      ? NativeMermaid(
          source: element.textContent,
          ready: ready,
          fontSize: fontSize,
          lineHeight: lineHeight,
        )
      : NativeCodeBlock(
          source: element.textContent,
          language: element.attributes['language'] ?? '',
          headerLineHeight: lineHeight,
        );
}

class _TableBuilder extends MarkdownElementBuilder {
  _TableBuilder({
    required this.size,
    this.onLink,
    this.onHtmlNavigate,
    this.onFormSubmit,
    this.imageBuilder,
    this.mediaBuilder,
  });
  final double size;
  final void Function(String)? onLink;
  final ValueChanged<NativeHtmlLink>? onHtmlNavigate;
  final ValueChanged<NativeHtmlFormSubmission>? onFormSubmit;
  final MarkdownImageBuilder? imageBuilder;
  final NativeHtmlMediaBuilder? mediaBuilder;

  MarkdownImageBuilder? _cellImageBuilder(BuildContext context, bool isHeader) {
    final imageBuilder = this.imageBuilder;
    if (imageBuilder == null) return null;
    final style = (Theme.of(context).textTheme.bodyMedium ?? const TextStyle())
        .copyWith(
          fontSize: size * .92,
          height: 1.5,
          fontWeight: isHeader ? FontWeight.w600 : FontWeight.w400,
        );
    final textScaler = MediaQuery.textScalerOf(context);
    final textDirection = Directionality.of(context);
    return (uri, title, alt) => _MarkdownTableInlineImage(
      style: style,
      textScaler: textScaler,
      textDirection: textDirection,
      child: imageBuilder(uri, title, alt),
    );
  }

  @override
  bool isBlockElement() => true;
  @override
  Widget? visitElementAfterWithContext(
    BuildContext context,
    md.Element element,
    TextStyle? preferredStyle,
    TextStyle? parentStyle,
  ) {
    final table = element as NativeTableElement;
    final colors = Theme.of(context).extension<PircColors>()!;
    return LayoutBuilder(
      builder: (context, constraints) => Container(
        key: const ValueKey('native-markdown-table'),
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          border: Border.all(color: colors['line.default']),
          borderRadius: BorderRadius.circular(12),
        ),
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: _WebTableSizing(
            viewportWidth: constraints.maxWidth.isFinite
                ? math.max(0, constraints.maxWidth - 2)
                : 0,
            child: NativeSelectionGroup(
              table: true,
              child: Table(
                defaultColumnWidth: const _WebTableColumnWidth(),
                defaultVerticalAlignment: TableCellVerticalAlignment.top,
                border: TableBorder(
                  horizontalInside: BorderSide(color: colors['line.default']),
                ),
                children: [
                  for (var row = 0; row < table.rows.length; row++)
                    TableRow(
                      decoration: row == 0
                          ? BoxDecoration(color: colors['surface.subtle'])
                          : null,
                      children: [
                        for (final (column, cell) in table.rows[row].indexed)
                          TableCell(
                            verticalAlignment:
                                cell.source.trim().isEmpty &&
                                    (column > 0 ||
                                        table.rows[row].any(
                                          (c) => c.source.trim().isNotEmpty,
                                        ))
                                ? TableCellVerticalAlignment.fill
                                : TableCellVerticalAlignment.top,
                            child: NativeSelectionGroup(
                              tableCell: (row: row, column: column),
                              child: Padding(
                                // The CSS collapsed divider is split between
                                // the two adjacent cells. TableBorder paints
                                // this divider but does not reserve its layout
                                // width, so allocate half on each side here.
                                padding: EdgeInsets.fromLTRB(
                                  10,
                                  row == 0 ? 6 : 6.5,
                                  10,
                                  row == table.rows.length - 1 ? 6 : 6.5,
                                ),
                                child: _AnywhereWrapCell(
                                  enabled: row > 0,
                                  child: NativeMarkdown(
                                    source: cell.source,
                                    inlineOnly: true,
                                    linkReferences: table.references,
                                    fontSize: size * .92,
                                    lineHeight: 1.5,
                                    fontWeight: row == 0
                                        ? FontWeight.w600
                                        : FontWeight.w400,
                                    alignment: switch (cell.alignment) {
                                      'center' => WrapAlignment.center,
                                      'right' => WrapAlignment.end,
                                      _ => WrapAlignment.start,
                                    },
                                    onLink: onLink,
                                    onHtmlNavigate: onHtmlNavigate,
                                    mediaBuilder: mediaBuilder,
                                    onFormSubmit: onFormSubmit,
                                    imageBuilder: _cellImageBuilder(
                                      context,
                                      row == 0,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Gives body cells the min-content behavior of the source's
/// `overflow-wrap:anywhere`, while leaving their actual text and selection
/// offsets intact. The paragraph engine already emergency-wraps a long word
/// when layout gives it a narrower width; only its default word-based
/// min-intrinsic measurement needs adapting here.
class _AnywhereWrapCell extends SingleChildRenderObjectWidget {
  const _AnywhereWrapCell({required this.enabled, required super.child});

  final bool enabled;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderAnywhereWrapCell(enabled);

  @override
  void updateRenderObject(
    BuildContext context,
    covariant _RenderAnywhereWrapCell renderObject,
  ) {
    renderObject.enabled = enabled;
  }
}

class _RenderAnywhereWrapCell extends RenderProxyBox {
  _RenderAnywhereWrapCell(this._enabled);

  bool _enabled;

  set enabled(bool value) {
    if (_enabled == value) return;
    _enabled = value;
    markNeedsLayout();
  }

  @override
  double computeMinIntrinsicWidth(double height) {
    final box = child;
    if (!_enabled || box == null) return box?.getMinIntrinsicWidth(height) ?? 0;
    return _anywhereMinContentWidth(box);
  }

  @override
  double computeMaxIntrinsicWidth(double height) =>
      child?.getMaxIntrinsicWidth(height) ?? 0;

  @override
  double computeMinIntrinsicHeight(double width) =>
      child?.getMinIntrinsicHeight(width) ?? 0;

  @override
  double computeMaxIntrinsicHeight(double width) =>
      child?.getMaxIntrinsicHeight(width) ?? 0;

  @override
  Size computeDryLayout(BoxConstraints constraints) {
    final box = child;
    if (box == null) return constraints.smallest;
    return constraints.constrain(box.getDryLayout(constraints));
  }

  @override
  void performLayout() {
    final box = child;
    if (box == null) {
      size = constraints.smallest;
      return;
    }
    box.layout(constraints, parentUsesSize: true);
    size = constraints.constrain(box.size);
  }
}

double _anywhereMinContentWidth(RenderBox box) {
  if (box is RenderNativeHtmlMediaBox) return _intrinsicMinWidth(box);
  if (box is RenderParagraph) return _paragraphMinContentWidth(box);

  if (box is RenderConstrainedBox) {
    final child = box.child;
    final childWidth = child == null ? 0.0 : _anywhereMinContentWidth(child);
    return box.additionalConstraints.constrainWidth(childWidth);
  }

  if (box is RenderPadding) {
    final child = box.child;
    return child == null
        ? box.padding.horizontal
        : _anywhereMinContentWidth(child) + box.padding.horizontal;
  }

  if (box is RenderFlex) {
    final children = _renderBoxChildren(box);
    if (children.isNotEmpty && box.direction == Axis.horizontal) {
      return children.fold<double>(0, (sum, child) {
            final width = _anywhereMinContentWidth(child);
            return sum + width;
          }) +
          box.spacing * math.max(0, children.length - 1);
    }
    if (children.isNotEmpty) {
      return children.fold<double>(
        0,
        (width, child) => math.max(width, _anywhereMinContentWidth(child)),
      );
    }
  }

  if (box is RenderProxyBox) {
    final child = box.child;
    return child == null
        ? _intrinsicMinWidth(box)
        : _anywhereMinContentWidth(child);
  }

  final children = _renderBoxChildren(box);
  if (children.isNotEmpty) {
    return children.fold<double>(
      0,
      (width, child) => math.max(width, _anywhereMinContentWidth(child)),
    );
  }
  return _intrinsicMinWidth(box);
}

double _paragraphMinContentWidth(RenderParagraph paragraph) {
  final atomicWidths = [
    for (
      RenderBox? child = paragraph.firstChild;
      child != null;
      child = paragraph.childAfter(child)
    )
      _intrinsicMinWidth(child),
  ];
  final cached = _paragraphMinContentWidths[paragraph];
  if (cached != null &&
      identical(cached.text, paragraph.text) &&
      cached.textScaler == paragraph.textScaler &&
      cached.textDirection == paragraph.textDirection &&
      cached.locale == paragraph.locale &&
      _sameWidths(cached.atomicWidths, atomicWidths)) {
    return cached.width;
  }

  var width = 0.0;
  final measurements = <(String, TextStyle), double>{};

  double measure(String text, TextStyle style) => measurements.putIfAbsent((
    text,
    style,
  ), () => _measureParagraphText(paragraph, text, style));

  void measureSpan(InlineSpan span, TextStyle inherited) {
    if (span is! TextSpan) return;
    final style = inherited.merge(span.style);
    final text = span.text;
    if (text != null && text.isNotEmpty) {
      final boundaries = CharacterBoundary(text);
      var offset = 0;
      while (offset < text.length) {
        final end = boundaries.getTrailingTextBoundaryAt(offset) ?? text.length;
        final cluster = text.substring(offset, end);
        width = math.max(width, measure(cluster, style));
        offset = end;
      }
    }
    for (final child in span.children ?? const <InlineSpan>[]) {
      measureSpan(child, style);
    }
  }

  measureSpan(paragraph.text, const TextStyle());
  // WidgetSpan children (images, TeX parts, and other replaced content) stay
  // atomic. Their own intrinsic contract supplies their minimum width.
  for (final childWidth in atomicWidths) {
    width = math.max(width, childWidth);
  }
  _paragraphMinContentWidths[paragraph] = _ParagraphMinContentMeasurement(
    text: paragraph.text,
    textScaler: paragraph.textScaler,
    textDirection: paragraph.textDirection,
    locale: paragraph.locale,
    atomicWidths: atomicWidths,
    width: width,
  );
  return width;
}

bool _sameWidths(List<double> first, List<double> second) {
  if (first.length != second.length) return false;
  for (var index = 0; index < first.length; index++) {
    if (first[index] != second[index]) return false;
  }
  return true;
}

final _paragraphMinContentWidths = Expando<_ParagraphMinContentMeasurement>(
  'paragraph anywhere min-content width',
);

class _ParagraphMinContentMeasurement {
  const _ParagraphMinContentMeasurement({
    required this.text,
    required this.textScaler,
    required this.textDirection,
    required this.locale,
    required this.atomicWidths,
    required this.width,
  });

  final InlineSpan text;
  final TextScaler textScaler;
  final TextDirection textDirection;
  final Locale? locale;
  final List<double> atomicWidths;
  final double width;
}

double _measureParagraphText(
  RenderParagraph paragraph,
  String text,
  TextStyle style,
) {
  final painter = TextPainter(
    text: TextSpan(text: text, style: style),
    textDirection: paragraph.textDirection,
    textScaler: paragraph.textScaler,
    locale: paragraph.locale,
  )..layout();
  final width = painter.width;
  painter.dispose();
  return width;
}

double _intrinsicMinWidth(RenderBox box) {
  final width = box.getMinIntrinsicWidth(double.infinity);
  return width.isFinite ? math.max(0, width) : math.max(0, box.size.width);
}

List<RenderBox> _renderBoxChildren(RenderObject object) {
  final children = <RenderBox>[];
  object.visitChildren((child) {
    if (child is RenderBox) children.add(child);
  });
  return children;
}

/// Give replaced images the baseline and inline strut that CSS assigns in a
/// table cell. Markdown's Flutter builder puts image widgets beside text in a
/// Wrap; a baseline-aligned placeholder restores the cell's line-box descent.
class _MarkdownTableInlineImage extends StatelessWidget {
  const _MarkdownTableInlineImage({
    required this.style,
    required this.textScaler,
    required this.textDirection,
    required this.child,
  });

  final TextStyle style;
  final TextScaler textScaler;
  final TextDirection textDirection;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    // Flutter scales WidgetSpan children along with text. CSS text scaling
    // changes the cell's line metrics but leaves a replaced image at its CSS
    // dimensions, so scale the strut font explicitly and keep the span child
    // at its natural size.
    final scaledFontSize = textScaler.scale(style.fontSize ?? 14);
    final scaledStyle = TextStyle(
      fontFamily: style.fontFamily,
      fontSize: scaledFontSize,
      fontWeight: style.fontWeight,
      fontStyle: style.fontStyle,
    );
    return RichText(
      text: TextSpan(
        style: scaledStyle,
        children: [
          WidgetSpan(
            alignment: PlaceholderAlignment.baseline,
            baseline: TextBaseline.alphabetic,
            child: _MarkdownImageBottomBaseline(child: child),
          ),
        ],
      ),
      textScaler: TextScaler.noScaling,
      textDirection: textDirection,
      textWidthBasis: TextWidthBasis.longestLine,
      strutStyle: StrutStyle(
        fontFamily: style.fontFamily,
        fontFamilyFallback: style.fontFamilyFallback,
        fontSize: scaledFontSize,
        fontWeight: style.fontWeight,
        fontStyle: style.fontStyle,
        height: style.height,
        leading: 0,
        leadingDistribution: TextLeadingDistribution.even,
      ),
    );
  }
}

/// Supplies an inline image's replaced-element baseline without asking
/// builder output (which may include Semantics or Tooltip render objects) to
/// implement dry-baseline queries.
class _MarkdownImageBottomBaseline extends SingleChildRenderObjectWidget {
  const _MarkdownImageBottomBaseline({required super.child});

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderMarkdownImageBottomBaseline();
}

class _RenderMarkdownImageBottomBaseline extends RenderProxyBox {
  @override
  double? computeDryBaseline(
    BoxConstraints constraints,
    TextBaseline baseline,
  ) => child?.getDryLayout(constraints).height;

  @override
  double? computeDistanceToActualBaseline(TextBaseline baseline) => size.height;
}

/// Gives a Markdown table the browser's 100% width while allowing
/// min-content columns to overflow horizontally in the scroll view.
class _WebTableSizing extends SingleChildRenderObjectWidget {
  const _WebTableSizing({required this.viewportWidth, required super.child});

  final double viewportWidth;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderWebTableSizing(viewportWidth);

  @override
  void updateRenderObject(
    BuildContext context,
    covariant _RenderWebTableSizing renderObject,
  ) {
    renderObject.viewportWidth = viewportWidth;
  }
}

class _RenderWebTableSizing extends RenderProxyBox {
  _RenderWebTableSizing(this._viewportWidth);

  double _viewportWidth;

  set viewportWidth(double value) {
    if (_viewportWidth == value) return;
    _viewportWidth = value;
    markNeedsLayout();
  }

  double _minimumContentWidth() {
    final child = this.child;
    if (child == null) return 0;
    final width = child.getMinIntrinsicWidth(double.infinity);
    return width.isFinite ? math.max(0, width) : width;
  }

  double get _tableWidth => math.max(_viewportWidth, _minimumContentWidth());

  @override
  double computeMinIntrinsicWidth(double height) => _tableWidth;

  @override
  double computeMaxIntrinsicWidth(double height) => _tableWidth;

  @override
  double computeMinIntrinsicHeight(double width) =>
      child?.getMinIntrinsicHeight(_tableWidth) ?? 0;

  @override
  double computeMaxIntrinsicHeight(double width) =>
      child?.getMaxIntrinsicHeight(_tableWidth) ?? 0;

  @override
  Size computeDryLayout(BoxConstraints constraints) {
    final child = this.child;
    if (child == null) return constraints.smallest;
    final width = constraints.constrainWidth(_tableWidth);
    final childSize = child.getDryLayout(BoxConstraints.tightFor(width: width));
    return constraints.constrain(childSize);
  }

  @override
  void performLayout() {
    final child = this.child;
    if (child == null) {
      size = constraints.smallest;
      return;
    }
    final width = constraints.constrainWidth(_tableWidth);
    child.layout(BoxConstraints.tightFor(width: width), parentUsesSize: true);
    size = constraints.constrain(child.size);
  }
}

/// Allocates a browser-style auto table width from the columns' min/max-content
/// widths. RenderTable's flex shrink updates its deficit while iterating
/// columns, making a max-content flex factor order-dependent. Instead, derive
/// the final width for each column from all columns together: distribute
/// available width above min-content in proportion to each column's remaining
/// max-content capacity. If all columns reach max-content, share any remaining
/// table width evenly. This preserves natural min/max constraints without
/// biasing earlier columns.
class _WebTableColumnWidth extends TableColumnWidth {
  const _WebTableColumnWidth();

  @override
  double minIntrinsicWidth(Iterable<RenderBox> cells, double containerWidth) {
    final columnCells = cells.toList(growable: false);
    if (columnCells.isEmpty) return 0;
    final parent = columnCells.first.parent;
    return _columnIntrinsicWidths(
      columnCells,
      table: parent is RenderTable ? parent : null,
    ).$1;
  }

  @override
  double maxIntrinsicWidth(Iterable<RenderBox> cells, double containerWidth) {
    final columnCells = cells.toList(growable: false);
    final intrinsicMax = _intrinsicWidth(columnCells, maximum: true);
    if (!containerWidth.isFinite || columnCells.isEmpty) return intrinsicMax;

    final table = columnCells.first.parent;
    if (table is! RenderTable || table.columns < 1) return intrinsicMax;
    final columnIndex = _columnIndex(table, columnCells.first);
    if (columnIndex == null) return intrinsicMax;

    final minimums = <double>[];
    final maximums = <double>[];
    for (var column = 0; column < table.columns; column++) {
      final metrics = _columnIntrinsicWidths(
        table.column(column),
        table: table,
      );
      minimums.add(metrics.$1);
      maximums.add(metrics.$2);
    }
    return _allocatedColumnWidths(
      minimums,
      maximums,
      containerWidth,
    )[columnIndex];
  }

  static double _intrinsicWidth(
    Iterable<RenderBox> cells, {
    required bool maximum,
  }) {
    final widths = _columnIntrinsicWidths(cells);
    return maximum ? widths.$2 : widths.$1;
  }

  static (double, double) _columnIntrinsicWidths(
    Iterable<RenderBox> cells, {
    RenderTable? table,
  }) {
    final headerCells = table == null
        ? const <RenderBox>{}
        : table.row(0).toSet();
    var minimum = 0.0;
    var maximum = 0.0;
    for (final cell in cells) {
      final cellMax = cell.getMaxIntrinsicWidth(double.infinity);
      final cellMin = headerCells.contains(cell)
          ? cellMax
          : cell.getMinIntrinsicWidth(double.infinity);
      minimum = math.max(minimum, cellMin);
      maximum = math.max(maximum, cellMax);
    }
    return (minimum, math.max(minimum, maximum));
  }

  static int? _columnIndex(RenderTable table, RenderBox cell) {
    final parentData = cell.parentData;
    if (parentData is TableCellParentData && parentData.x != null) {
      return parentData.x;
    }
    // Parent data receives its column during layout, after RenderTable first
    // asks for intrinsic widths. Markdown tables have a child for each cell,
    // so the first row is enough to resolve the initial query as well.
    final firstRow = table.row(0).toList(growable: false);
    final index = firstRow.indexWhere((child) => identical(child, cell));
    return index < 0 ? null : index;
  }

  static List<double> _allocatedColumnWidths(
    List<double> minimums,
    List<double> maximums,
    double availableWidth,
  ) {
    final widths = List<double>.of(minimums);
    if (widths.isEmpty) return widths;
    var remaining = availableWidth - widths.fold<double>(0, (a, b) => a + b);
    if (remaining <= 0) return widths;

    final capacities = [
      for (var index = 0; index < widths.length; index++)
        math.max(0, maximums[index] - widths[index]),
    ];
    final totalCapacity = capacities.fold<double>(0, (a, b) => a + b);
    if (totalCapacity > 0 && remaining < totalCapacity) {
      for (var index = 0; index < widths.length; index++) {
        widths[index] += remaining * capacities[index] / totalCapacity;
      }
      return widths;
    }

    for (var index = 0; index < widths.length; index++) {
      widths[index] += capacities[index];
    }
    remaining -= totalCapacity;
    if (remaining > 1e-7) {
      final share = remaining / widths.length;
      for (var index = 0; index < widths.length; index++) {
        widths[index] += share;
      }
    }
    return widths;
  }
}

/// Markdown task lists are disabled HTML inputs in the reference, not app
/// actions. Draw the small checkbox directly, avoiding Material icon fonts.
class NativeTaskCheckbox extends StatelessWidget {
  const NativeTaskCheckbox({super.key, required this.checked});
  final bool checked;
  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Semantics(
      checked: checked,
      enabled: false,
      child: Padding(
        padding: const EdgeInsets.only(right: 6.75),
        child: Align(
          alignment: Alignment.centerLeft,
          widthFactor: 1,
          heightFactor: 1,
          child: CustomPaint(
            size: const Size(13, 13),
            painter: _TaskCheckboxPainter(checked, dark),
          ),
        ),
      ),
    );
  }
}

class _TaskCheckboxPainter extends CustomPainter {
  const _TaskCheckboxPainter(this.checked, this.dark);
  final bool checked, dark;
  @override
  void paint(Canvas canvas, Size size) {
    final shape = RRect.fromRectAndRadius(
      Offset.zero & size,
      const Radius.circular(2),
    );
    final edge = dark
        ? (checked ? const Color(0xff757575) : const Color(0xff626262))
        : const Color(0xffd1d1d1);
    canvas.drawRRect(
      shape,
      Paint()
        ..color = checked
            ? edge
            : (dark ? const Color(0xff3b3b3b) : const Color(0xfff8f8f8)),
    );
    canvas.drawRRect(
      shape.deflate(.5),
      Paint()
        ..color = edge
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1,
    );
    if (checked) {
      canvas.drawPath(
        Path()
          ..moveTo(3, 6.5)
          ..lineTo(5.5, 9)
          ..lineTo(10, 3.5),
        Paint()
          ..color = (dark ? const Color(0xff3b3b3b) : const Color(0xffededed))
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5,
      );
    }
  }

  @override
  bool shouldRepaint(_TaskCheckboxPainter oldDelegate) =>
      checked != oldDelegate.checked || dark != oldDelegate.dark;
}
