import 'html_form_submission.dart';
import 'dart:convert';
import 'dart:math' as math;
import 'html_syntax.dart';
import 'markdown_spacing.dart';
import 'native_html.dart';
import 'native_math_paragraph.dart';
import 'package:flutter/gestures.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';

/// One selection gesture can cross native text, code and table cells. Reuse an
/// existing region (for example a file preview) instead of nesting gesture roots.
class NativeSelection extends StatelessWidget {
  const NativeSelection({super.key, required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) =>
      SelectionContainer.maybeOf(context) == null
      ? SelectionArea(child: child)
      : child;
}

/// Flutter normally concatenates selected RenderParagraphs without separators.
/// Groups preserve logical boundaries without inserting invisible glyphs into
/// the rendered text or changing the layout/selection offsets.
class NativeSelectionGroup extends StatefulWidget {
  const NativeSelectionGroup({
    super.key,
    required this.child,
    this.separator = '',
    this.table = false,
    this.blockSeparation = false,
    this.breakAfter,
    this.tableCell,
  });
  final Widget child;
  final String separator;
  final bool table, blockSeparation;
  final int? breakAfter;
  final ({int row, int column})? tableCell;
  @override
  State<NativeSelectionGroup> createState() => _NativeSelectionGroupState();
}

class _NativeSelectionGroupState extends State<NativeSelectionGroup> {
  late final _JoinedSelection delegate = _JoinedSelection();
  @override
  void dispose() {
    delegate.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    delegate.separator = widget.separator;
    delegate.table = widget.table;
    delegate.blockSeparation = widget.blockSeparation;
    delegate.breakAfter = widget.breakAfter;
    delegate.tableCell = widget.tableCell;
    return SelectionContainer(delegate: delegate, child: widget.child);
  }
}

enum _SelectionEndpointEdge { logicalStart, logicalEnd }

class _JoinedSelection extends StaticSelectionContainerDelegate {
  String separator = '';
  bool table = false, blockSeparation = false;
  int? breakAfter;
  ({int row, int column})? tableCell;
  bool _emptySelected = false;
  Offset? _emptyStart, _emptyEnd;
  Offset? _dragAnchor, _dragFocus;
  TextGranularity? _dragAnchorGranularity, _dragFocusGranularity;
  Selectable? _dragAnchorSelectable, _dragFocusSelectable;
  bool _recordingPointerEdge = false;
  bool _layoutOrderPending = false;
  bool _orderRepairScheduled = false;
  bool _disposed = false;
  int _orderRepairAttempts = 0;
  bool get _emptyCell => tableCell != null && selectables.isEmpty;

  static const _maxOrderRepairAttempts = 8;

  bool _isParagraphAwaitingLayout(AssertionError error) {
    final message = error.toString();
    return message.contains('rendering/paragraph.dart') &&
        message.contains("'!debugNeedsLayout': is not true.");
  }

  int _compareByTransformOrigin(Selectable a, Selectable b) {
    final pointA = MatrixUtils.transformPoint(
      a.getTransformTo(null),
      Offset.zero,
    );
    final pointB = MatrixUtils.transformPoint(
      b.getTransformTo(null),
      Offset.zero,
    );
    if ((pointA.dy - pointB.dy).abs() > 0.5) {
      return pointA.dy.compareTo(pointB.dy);
    }
    return pointA.dx.compareTo(pointB.dx);
  }

  int _compareByPaintedBoxes(
    Selectable a,
    Selectable b,
    Comparator<Selectable> fallback,
  ) {
    final transformA = a.getTransformTo(null);
    final transformB = b.getTransformTo(null);
    // Use the first painted boxes instead of multi-line unions. A text
    // fragment wrapping after a placeholder can otherwise sort before the
    // glyphs inside that placeholder. Overlapping boxes share a visual row.
    final boxesA = a.boundingBoxes;
    final boxesB = b.boundingBoxes;
    if (boxesA.isNotEmpty && boxesB.isNotEmpty) {
      final firstA = MatrixUtils.transformRect(transformA, boxesA.first);
      final firstB = MatrixUtils.transformRect(transformB, boxesB.first);
      if (firstA.bottom <= firstB.top + 0.5) return -1;
      if (firstB.bottom <= firstA.top + 0.5) return 1;
      if ((firstA.left - firstB.left).abs() > 0.5) {
        return firstA.left.compareTo(firstB.left);
      }
    }
    return fallback(a, b);
  }

  void _sortCurrentSelectablesByPaintedBoxes(Comparator<Selectable> fallback) {
    final ordered = List<Selectable>.of(selectables);
    final selectedStart =
        currentSelectionStartIndex >= 0 &&
            currentSelectionStartIndex < selectables.length
        ? selectables[currentSelectionStartIndex]
        : null;
    final selectedEnd =
        currentSelectionEndIndex >= 0 &&
            currentSelectionEndIndex < selectables.length
        ? selectables[currentSelectionEndIndex]
        : null;
    ordered.sort((a, b) => _compareByPaintedBoxes(a, b, fallback));
    selectables
      ..clear()
      ..addAll(ordered);
    currentSelectionStartIndex = selectedStart == null
        ? -1
        : selectables.indexOf(selectedStart);
    currentSelectionEndIndex = selectedEnd == null
        ? -1
        : selectables.indexOf(selectedEnd);
    layoutDidChange();
  }

  void _scheduleOrderRepair() {
    if (_disposed ||
        !_layoutOrderPending ||
        _orderRepairScheduled ||
        _orderRepairAttempts >= _maxOrderRepairAttempts) {
      return;
    }
    _orderRepairScheduled = true;
    final fallback = super.compareOrder;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _orderRepairScheduled = false;
      if (_disposed || !_layoutOrderPending) return;

      try {
        _sortCurrentSelectablesByPaintedBoxes(fallback);
      } on AssertionError catch (error) {
        if (!_isParagraphAwaitingLayout(error)) rethrow;
        _orderRepairAttempts++;
        _scheduleOrderRepair();
        WidgetsBinding.instance.ensureVisualUpdate();
        return;
      }
      _layoutOrderPending = false;
      _orderRepairAttempts = 0;
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  void _clearDragTracking() {
    _dragAnchor = _dragFocus = null;
    _dragAnchorGranularity = _dragFocusGranularity = null;
    _dragAnchorSelectable = _dragFocusSelectable = null;
  }

  @override
  SelectionResult dispatchSelectionEvent(SelectionEvent event) {
    if (event is! SelectionEdgeUpdateEvent) _clearDragTracking();
    if (!_emptyCell) return super.dispatchSelectionEvent(event);
    final rect = event is ClearSelectionEvent
        ? Rect.zero
        : Offset.zero & containerSize;
    var result = SelectionResult.none;
    if (event is ClearSelectionEvent) {
      _emptySelected = false;
      _emptyStart = _emptyEnd = null;
    } else if (event is SelectAllSelectionEvent) {
      _emptySelected = true;
      _emptyStart = rect.topLeft;
      _emptyEnd = rect.bottomRight;
    } else if (event is SelectionEdgeUpdateEvent) {
      final local = MatrixUtils.transformPoint(
        getTransformTo(null)..invert(),
        event.globalPosition,
      );
      if (event.type == SelectionEventType.startEdgeUpdate) {
        _emptyStart = local;
      } else {
        _emptyEnd = local;
      }
      int relative(Offset point) {
        if (point.dy < rect.top ||
            (point.dy <= rect.bottom && point.dx < rect.left)) {
          return -1;
        }
        if (point.dy > rect.bottom || point.dx > rect.right) return 1;
        return 0;
      }

      if (_emptyStart != null && _emptyEnd != null) {
        final a = relative(_emptyStart!), b = relative(_emptyEnd!);
        _emptySelected =
            _emptyStart != _emptyEnd && (a <= 0 && b >= 0 || b <= 0 && a >= 0);
      }
      result = SelectionUtils.getResultBasedOnRect(rect, local);
    } else if (event is SelectWordSelectionEvent ||
        event is SelectParagraphSelectionEvent) {
      _emptySelected = false;
      final point = event is SelectWordSelectionEvent
          ? event.globalPosition
          : (event as SelectParagraphSelectionEvent).globalPosition;
      result = SelectionUtils.getResultBasedOnRect(
        rect,
        MatrixUtils.transformPoint(getTransformTo(null)..invert(), point),
      );
    } else if (event is GranularlyExtendSelectionEvent) {
      result = event.forward ? SelectionResult.next : SelectionResult.previous;
    }
    layoutDidChange();
    notifyListeners();
    return result;
  }

  @override
  SelectionResult handleSelectionEdgeUpdate(SelectionEdgeUpdateEvent event) {
    if (event.type == SelectionEventType.startEdgeUpdate) {
      _dragAnchor = event.globalPosition;
      _dragAnchorGranularity = event.granularity;
      _dragAnchorSelectable = null;
    } else {
      _dragFocus = event.globalPosition;
      _dragFocusGranularity = event.granularity;
      _dragFocusSelectable = null;
    }

    _recordingPointerEdge = true;
    final result = super.handleSelectionEdgeUpdate(event);
    _recordingPointerEdge = false;

    if (event.type == SelectionEventType.endEdgeUpdate) {
      _rebuildSelectionAcrossFragments();
    }
    return result;
  }

  @override
  SelectionResult dispatchSelectionEventToChild(
    Selectable selectable,
    SelectionEvent event,
  ) {
    final result = super.dispatchSelectionEventToChild(selectable, event);
    if (_recordingPointerEdge && event is SelectionEdgeUpdateEvent) {
      final containsPointer = selectable.boundingBoxes.any(
        (box) => MatrixUtils.transformRect(
          selectable.getTransformTo(null),
          box,
        ).inflate(0.5).contains(event.globalPosition),
      );
      if (containsPointer) {
        if (event.type == SelectionEventType.startEdgeUpdate) {
          _dragAnchorSelectable = selectable;
        } else {
          _dragFocusSelectable = selectable;
        }
      }
    }
    return result;
  }

  /// The framework's multi-selectable delegate clears the first edge's
  /// selectable when that edge falls exactly at a fragment boundary. Preserve
  /// the pointer's real anchor/focus selectables, then rebuild only the actual
  /// selected RichText fragments after both edge events arrive. This keeps
  /// reversed drags and selection handles attached to the user's original
  /// edges instead of swapping the start and end events.
  void _rebuildSelectionAcrossFragments() {
    final anchor = _dragAnchorSelectable;
    final focus = _dragFocusSelectable;
    final anchorPosition = _dragAnchor;
    final focusPosition = _dragFocus;
    if (anchor == null ||
        focus == null ||
        anchorPosition == null ||
        focusPosition == null) {
      return;
    }

    final anchorIndex = selectables.indexOf(anchor);
    final focusIndex = selectables.indexOf(focus);
    if (anchorIndex < 0 || focusIndex < 0 || anchorIndex == focusIndex) return;

    // Flutter's normal routing already preserves ordinary paragraph drags.
    // Rebuild only when the SDK routed an edge to a different selectable than
    // the one containing the user's original pointer (the inline Math marker
    // boundary case this delegate repairs).
    if (currentSelectionStartIndex == anchorIndex &&
        currentSelectionEndIndex == focusIndex) {
      return;
    }

    final forward = anchorIndex < focusIndex;
    final lower = math.min(anchorIndex, focusIndex);
    final upper = math.max(anchorIndex, focusIndex);
    for (var index = lower + 1; index < upper; index++) {
      _dispatchToChild(selectables[index], const SelectAllSelectionEvent());
    }

    if (forward) {
      _selectEndpoint(
        anchor,
        startEdge: anchorPosition,
        endEdgeRole: _SelectionEndpointEdge.logicalEnd,
        granularity: _dragAnchorGranularity ?? TextGranularity.character,
      );
      _selectEndpoint(
        focus,
        startEdgeRole: _SelectionEndpointEdge.logicalStart,
        endEdge: focusPosition,
        granularity: _dragFocusGranularity ?? TextGranularity.character,
      );
    } else {
      _selectEndpoint(
        anchor,
        startEdge: anchorPosition,
        endEdgeRole: _SelectionEndpointEdge.logicalStart,
        granularity: _dragAnchorGranularity ?? TextGranularity.character,
      );
      _selectEndpoint(
        focus,
        startEdgeRole: _SelectionEndpointEdge.logicalEnd,
        endEdge: focusPosition,
        granularity: _dragFocusGranularity ?? TextGranularity.character,
      );
    }

    // Keep the roles from the original gesture. In particular, a reversed
    // drag retains its right-side anchor as the start handle.
    currentSelectionStartIndex = anchorIndex;
    currentSelectionEndIndex = focusIndex;
  }

  void _selectEndpoint(
    Selectable selectable, {
    Offset? startEdge,
    Offset? endEdge,
    _SelectionEndpointEdge? startEdgeRole,
    _SelectionEndpointEdge? endEdgeRole,
    required TextGranularity granularity,
  }) {
    _dispatchToChild(selectable, const SelectAllSelectionEvent());
    final geometry = selectable.value;
    final transform = selectable.getTransformTo(null);
    final logicalStart = geometry.startSelectionPoint == null
        ? null
        : MatrixUtils.transformPoint(
            transform,
            geometry.startSelectionPoint!.localPosition,
          );
    final logicalEnd = geometry.endSelectionPoint == null
        ? null
        : MatrixUtils.transformPoint(
            transform,
            geometry.endSelectionPoint!.localPosition,
          );
    final resolvedStart =
        startEdge ??
        switch (startEdgeRole) {
          _SelectionEndpointEdge.logicalStart => logicalStart,
          _SelectionEndpointEdge.logicalEnd => logicalEnd,
          null => null,
        };
    final resolvedEnd =
        endEdge ??
        switch (endEdgeRole) {
          _SelectionEndpointEdge.logicalStart => logicalStart,
          _SelectionEndpointEdge.logicalEnd => logicalEnd,
          null => null,
        };
    if (resolvedStart == null || resolvedEnd == null) return;

    _dispatchToChild(
      selectable,
      SelectionEdgeUpdateEvent.forStart(
        globalPosition: resolvedStart,
        granularity: granularity,
      ),
    );
    _dispatchToChild(
      selectable,
      SelectionEdgeUpdateEvent.forEnd(
        globalPosition: resolvedEnd,
        granularity: granularity,
      ),
    );
  }

  SelectionResult _dispatchToChild(
    Selectable selectable,
    SelectionEvent event,
  ) => super.dispatchSelectionEventToChild(selectable, event);

  @override
  SelectionResult handleClearSelection(ClearSelectionEvent event) {
    _clearDragTracking();
    return super.handleClearSelection(event);
  }

  @override
  SelectionGeometry get value =>
      _emptyCell ? getSelectionGeometry() : super.value;

  @override
  SelectionGeometry getSelectionGeometry() {
    if (!_emptyCell) return super.getSelectionGeometry();
    final size = _emptySelected ? containerSize : Size.zero;
    return SelectionGeometry(
      hasContent: true,
      status: _emptySelected
          ? SelectionStatus.uncollapsed
          : SelectionStatus.none,
      startSelectionPoint: !_emptySelected
          ? null
          : SelectionPoint(
              localPosition: Offset(0, size.height),
              lineHeight: size.height,
              handleType: TextSelectionHandleType.left,
            ),
      endSelectionPoint: !_emptySelected
          ? null
          : SelectionPoint(
              localPosition: Offset(size.width, size.height),
              lineHeight: size.height,
              handleType: TextSelectionHandleType.right,
            ),
    );
  }

  @override
  SelectedContentRange? getSelection() => !_emptyCell
      ? super.getSelection()
      : _emptySelected
      ? const SelectedContentRange(startOffset: 0, endOffset: 0)
      : null;

  // Empty cells still have table semantics, but add no hidden text or painted
  // glyphs. Keep their existing padding box in the selection event chain.
  @override
  void didChangeSelectables() {
    super.didChangeSelectables();
    if (_layoutOrderPending) _orderRepairAttempts = 0;
    _scheduleOrderRepair();
    // Registration can propagate through several groups after the frame. The
    // SDK queues another post-frame update without requesting that frame; an
    // idle document would otherwise remain unselectable until another repaint.
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  SelectedContent? _tableContent() {
    final cells =
        [
          for (final selectable in selectables)
            if (selectable.getSelectedContent() case final _BlockContent c)
              if (c.cell != null) c,
        ]..sort((a, b) {
          final row = a.cell!.row.compareTo(b.cell!.row);
          return row == 0 ? a.cell!.column.compareTo(b.cell!.column) : row;
        });
    if (cells.isEmpty) return null;
    final text = StringBuffer();
    int? row, column;
    var rowHasText = false;
    for (final cell in cells) {
      final position = cell.cell!;
      if (row != position.row) {
        if (row != null) text.write('\n');
        row = position.row;
        column = null;
        rowHasText = false;
      }
      if (rowHasText) text.write('\t' * (position.column - column!));
      text.write(cell.plainText);
      rowHasText = rowHasText || cell.plainText.isNotEmpty;
      column = position.column;
    }
    return _BlockContent(text.toString(), breakAfter ?? 1);
  }

  @override
  Comparator<Selectable> get compareOrder {
    final fallback = super.compareOrder;
    if (_layoutOrderPending) {
      final binding = WidgetsBinding.instance;
      if (binding.schedulerPhase == SchedulerPhase.idle &&
          !binding.hasScheduledFrame) {
        // A later idle selection action may retry after the bounded repair
        // window was exhausted while layout kept changing.
        if (_orderRepairAttempts >= _maxOrderRepairAttempts) {
          _orderRepairAttempts = 0;
        }
      }
      _scheduleOrderRepair();
    }
    return (a, b) {
      try {
        return _compareByPaintedBoxes(a, b, fallback);
      } on AssertionError catch (error) {
        if (!_isParagraphAwaitingLayout(error)) rethrow;
        _layoutOrderPending = true;
        _scheduleOrderRepair();
        return _compareByTransformOrigin(a, b);
      }
    };
  }

  @override
  SelectedContent? getSelectedContent() {
    if (_emptyCell) {
      return _emptySelected ? _BlockContent('', 0, cell: tableCell) : null;
    }
    if (table) return _tableContent();
    final buffer = StringBuffer();
    int? previous;
    var lastBreak = 0;
    for (var i = 0; i < selectables.length; i++) {
      final selected = selectables[i].getSelectedContent();
      final content = selected?.plainText;
      if (content == null || content.isEmpty) continue;
      if (previous != null) {
        buffer.write(blockSeparation ? '\n' * lastBreak : separator);
      }
      buffer.write(content);
      previous = i;
      lastBreak = selected is _BlockContent ? selected.breakAfter : 0;
    }
    return previous == null
        ? null
        : _BlockContent(
            buffer.toString(),
            breakAfter ?? lastBreak,
            cell: tableCell,
          );
  }
}

class _BlockContent extends SelectedContent {
  const _BlockContent(String text, this.breakAfter, {this.cell})
    : super(plainText: text);
  final int breakAfter;
  final ({int row, int column})? cell;
}

/// Retain the parsed nodes alongside the package's native widget output. This
/// avoids guessing paragraph/heading semantics from fonts or widget shapes, and
/// parses each chunk once, just as MarkdownBody did before selection support.
class SelectionMarkdownBody extends MarkdownBody {
  const SelectionMarkdownBody({
    super.key,
    required super.data,
    super.extensionSet,
    super.blockSyntaxes,
    super.inlineSyntaxes,
    super.paddingBuilders,
    super.builders,
    super.checkboxBuilder,
    super.bulletBuilder,
    super.imageBuilder,
    this.imageSourceTransform,
    this.onFormSubmit,
    this.onHtmlNavigate,
    this.mediaBuilder,
    super.onTapLink,
    super.styleSheet,
    this.documentStart = true,
    this.documentEnd = true,
  }) : super(selectable: false);

  final bool documentStart, documentEnd;
  final String Function(String source)? imageSourceTransform;
  final ValueChanged<NativeHtmlFormSubmission>? onFormSubmit;
  final ValueChanged<NativeHtmlLink>? onHtmlNavigate;
  final NativeHtmlMediaBuilder? mediaBuilder;

  @override
  State<SelectionMarkdownBody> createState() => _SelectionMarkdownBodyState();

  @override
  Widget build(BuildContext context, List<Widget>? children) =>
      NativeSelectionGroup(
        blockSeparation: true,
        child: super.build(context, children),
      );
}

class _SelectionMarkdownBodyState extends State<SelectionMarkdownBody>
    implements MarkdownBuilderDelegate {
  final _recognizers = <TapGestureRecognizer>[];
  List<Widget> _children = [];
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _parse();
  }

  @override
  void didUpdateWidget(SelectionMarkdownBody oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.data != oldWidget.data ||
        widget.styleSheet != oldWidget.styleSheet ||
        widget.documentStart != oldWidget.documentStart ||
        widget.documentEnd != oldWidget.documentEnd ||
        widget.imageSourceTransform != oldWidget.imageSourceTransform ||
        widget.onFormSubmit != oldWidget.onFormSubmit ||
        widget.onHtmlNavigate != oldWidget.onHtmlNavigate ||
        widget.mediaBuilder != oldWidget.mediaBuilder) {
      _parse();
    }
  }

  void _disposeRecognizers() {
    for (final recognizer in _recognizers) {
      recognizer.dispose();
    }
    _recognizers.clear();
  }

  @override
  void dispose() {
    _disposeRecognizers();
    super.dispose();
  }

  void _parse() {
    _disposeRecognizers();
    final document = md.Document(
      blockSyntaxes: widget.blockSyntaxes,
      inlineSyntaxes: widget.inlineSyntaxes,
      extensionSet: widget.extensionSet ?? md.ExtensionSet.gitHubFlavored,
      encodeHtml: false,
    );
    final nodes = document.parseLines(
      const LineSplitter().convert(widget.data),
    );
    _trimListBlockSeparators(nodes);
    _restoreCheckboxSpaces(nodes);
    if (containsNativeHtml(nodes)) {
      final styles = MarkdownStyleSheet.fromTheme(
        Theme.of(context),
      ).merge(widget.styleSheet);
      _children = [
        NativeHtmlDocument(
          nodes: nodes,
          style: styles.p!,
          styles: styles,
          builders: widget.builders,
          imageBuilder: widget.imageBuilder,
          checkboxBuilder: widget.checkboxBuilder,
          onLink: (href) => widget.onTapLink?.call('', href, ''),
          onFormSubmit: widget.onFormSubmit,
          onNavigate: widget.onHtmlNavigate,
          mediaBuilder: widget.mediaBuilder,
        ),
      ];
      return;
    }
    _transformImageSources(nodes);
    final styles = MarkdownStyleSheet.fromTheme(
      Theme.of(context),
    ).merge(widget.styleSheet);
    _children = _buildScope(
      nodes,
      styles,
      documentStart: widget.documentStart,
      documentEnd: widget.documentEnd,
    );
  }

  void _transformImageSources(List<md.Node> nodes) {
    final transform = widget.imageSourceTransform;
    if (transform == null) return;

    void visit(md.Node node) {
      if (node is! md.Element) return;
      if (node.tag == 'img') {
        final source = node.attributes['src'];
        if (source != null) node.attributes['src'] = transform(source);
      }
      for (final child in node.children ?? const <md.Node>[]) {
        visit(child);
      }
    }

    for (final node in nodes) {
      visit(node);
    }
  }

  List<Widget> _buildScope(
    List<md.Node> nodes,
    MarkdownStyleSheet styles, {
    md.Element? parent,
    bool documentStart = false,
    bool documentEnd = false,
  }) {
    final builder = MarkdownBuilder(
      delegate: this,
      selectable: false,
      styleSheet: styles,
      imageDirectory: widget.imageDirectory,
      imageBuilder: widget.imageBuilder,
      checkboxBuilder: widget.checkboxBuilder,
      bulletBuilder:
          widget.bulletBuilder ??
          (parameters) => Text(
            parameters.style == BulletStyle.orderedList
                ? '${parameters.index + 1}.'
                : '•',
            maxLines: 1,
            softWrap: false,
            overflow: TextOverflow.visible,
            textAlign: parameters.style == BulletStyle.orderedList
                ? TextAlign.right
                : TextAlign.center,
            style: styles.p,
          ),
      builders: {
        ...widget.builders,
        'pirc-quote-scope': _QuoteBuilder((quote) {
          final nested = styles.copyWith(p: styles.p?.merge(styles.blockquote));
          return _QuoteScope(
            child: DecoratedBox(
              decoration: styles.blockquoteDecoration!,
              child: Padding(
                padding: styles.blockquotePadding!,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: widget.fitContent
                      ? CrossAxisAlignment.start
                      : CrossAxisAlignment.stretch,
                  children: _buildScope(
                    quote.children ?? [],
                    nested,
                    parent: quote,
                  ),
                ),
              ),
            ),
          );
        }),
      },
      paddingBuilders: widget.paddingBuilders,
      fitContent: widget.fitContent,
      listItemCrossAxisAlignment: widget.listItemCrossAxisAlignment,
      softLineBreak: widget.softLineBreak,
    );
    return _selectionChildren(
      builder.build(nodes.map(_isolateQuotes).toList()),
      nodes,
      parent: parent,
      documentStart: documentStart,
      documentEnd: documentEnd,
      margins: NativeMarkdownMargins(
        fontSize: styles.p?.fontSize ?? 15,
        paragraphSpacing: styles.blockSpacing ?? 12.75,
        textScaler: MediaQuery.textScalerOf(context),
      ),
    );
  }

  @override
  GestureRecognizer createLink(String text, String? href, String title) {
    final recognizer = TapGestureRecognizer()
      ..onTap = () => widget.onTapLink?.call(text, href, title);
    _recognizers.add(recognizer);
    return recognizer;
  }

  @override
  TextSpan formatText(MarkdownStyleSheet style, String code) =>
      TextSpan(style: style.code, text: code.replaceFirst(RegExp(r'\n$'), ''));

  @override
  Widget build(BuildContext context) => widget.build(context, _children);
}

const _blockTags = {
  'p',
  'h1',
  'h2',
  'h3',
  'h4',
  'h5',
  'h6',
  'ul',
  'ol',
  'li',
  'blockquote',
  'pre',
  'hr',
  'pirc-code',
  'pirc-table',
  'pirc-math-block',
};

// The builder places consecutive inline AST nodes in one anonymous Wrap.
List<md.Element> _flowNodes(List<md.Node> nodes) {
  final blocks = <md.Element>[];
  var inline = <md.Node>[];
  void flush() {
    if (inline.isNotEmpty) blocks.add(md.Element('pirc-inline', inline));
    inline = [];
  }

  for (final node in nodes) {
    if (node is md.Element && _blockTags.contains(node.tag)) {
      flush();
      blocks.add(node);
    } else {
      inline.add(node);
    }
  }
  flush();
  return blocks;
}

int _breakAfter(md.Element? node) {
  if (node?.tag == 'p') return 2;
  if ({'ul', 'ol', 'li', 'blockquote'}.contains(node?.tag)) {
    final children = _flowNodes(node!.children ?? []);
    if (children.isNotEmpty) return _breakAfter(children.last);
  }
  return 1;
}

List<Widget> _selectionChildren(
  List<Widget> widgets,
  List<md.Node> nodes, {
  required NativeMarkdownMargins margins,
  md.Element? parent,
  bool documentStart = false,
  bool documentEnd = false,
}) {
  final blocks = _flowNodes(nodes);
  var index = 0;
  return [
    if (documentStart && blocks.isNotEmpty)
      SizedBox(height: margins.startEdge(blocks.first)),
    if (parent?.tag == 'blockquote' && blocks.isNotEmpty)
      SizedBox(
        height: margins.top(blocks.first, parent: 'blockquote', first: true),
      ),
    for (final child in widgets)
      if (child is SizedBox)
        if (index > 0 && index < blocks.length)
          SizedBox(
            height: margins.gap(
              blocks[index - 1],
              blocks[index],
              parent: parent?.tag,
            ),
          )
        else
          child
      else
        _selectionLayout(
          child,
          node: index < blocks.length ? blocks[index++] : null,
          margins: margins,
        ),
    if (parent?.tag == 'blockquote' && blocks.isNotEmpty)
      SizedBox(height: margins.bottom(blocks.last, parent: 'blockquote')),
    if (documentEnd && blocks.isNotEmpty)
      SizedBox(height: margins.endEdge(blocks.last)),
  ];
}

// Adapter for flutter_markdown_plus 1.0.12's public widget output. A paragraph
// is a Column containing a Wrap; a list contains Rows with a bullet and Flexible
// body. Preserve every layout property while adding logical selection groups.
// Math markers are composed into paragraph spans. Other custom builders keep
// their own rendering and selection behavior.
Widget _selectionLayout(
  Widget widget, {
  md.Element? node,
  required NativeMarkdownMargins margins,
}) {
  if (widget is Column) {
    return NativeSelectionGroup(
      blockSeparation: true,
      breakAfter: _breakAfter(node),
      child: Column(
        key: widget.key,
        mainAxisAlignment: widget.mainAxisAlignment,
        mainAxisSize: widget.mainAxisSize,
        crossAxisAlignment: widget.crossAxisAlignment,
        textDirection: widget.textDirection,
        verticalDirection: widget.verticalDirection,
        textBaseline: widget.textBaseline,
        spacing: widget.spacing,
        children: _selectionChildren(
          widget.children,
          node?.children ?? [],
          margins: margins,
          parent: node,
        ),
      ),
    );
  }
  if (widget is Row) {
    return Row(
      key: widget.key,
      mainAxisAlignment: widget.mainAxisAlignment,
      mainAxisSize: widget.mainAxisSize,
      crossAxisAlignment: widget.crossAxisAlignment,
      textDirection: widget.textDirection,
      verticalDirection: widget.verticalDirection,
      textBaseline: widget.textBaseline,
      spacing: widget.spacing,
      children: [
        SelectionContainer.disabled(child: widget.children.first),
        for (final child in widget.children.skip(1))
          if (child is Flexible)
            Flexible(
              key: child.key,
              flex: child.flex,
              fit: child.fit,
              child: _selectionLayout(
                child.child,
                node: node,
                margins: margins,
              ),
            )
          else
            _selectionLayout(child, node: node, margins: margins),
      ],
    );
  }
  if (widget is Padding) {
    return Padding(
      key: widget.key,
      padding: widget.padding,
      child: widget.child == null
          ? null
          : _selectionLayout(widget.child!, node: node, margins: margins),
    );
  }
  if (widget is DecoratedBox) {
    return DecoratedBox(
      key: widget.key,
      decoration: widget.decoration,
      position: widget.position,
      child: widget.child == null
          ? null
          : _selectionLayout(widget.child!, node: node, margins: margins),
    );
  }
  if (widget is SizedBox) return widget;
  if (widget is Wrap &&
      widget.children.any((child) => child is NativeMarkdownMath)) {
    return NativeSelectionGroup(
      breakAfter: _breakAfter(node),
      child: NativeMathParagraph(
        key: widget.key,
        alignment: widget.alignment,
        children: widget.children,
      ),
    );
  }
  return NativeSelectionGroup(breakAfter: _breakAfter(node), child: widget);
}

// Marked emits a literal space after the disabled task checkbox. Dart Markdown
// consumes it in its block syntax. Restore that visible space before layout so
// both rendered text and partial-selection offsets follow the web document.
void _restoreCheckboxSpaces(List<md.Node> nodes) {
  for (final element in nodes.whereType<md.Element>()) {
    final children = element.children;
    if (children == null) continue;
    for (var i = 0; i < children.length; i++) {
      final child = children[i];
      if (child is md.Element &&
          child.tag == 'input' &&
          child.attributes['type'] == 'checkbox') {
        final next = i + 1 < children.length ? children[i + 1] : null;
        if (next is! md.Text || !next.text.startsWith(RegExp(r'\s'))) {
          children.insert(i + 1, md.Text(' '));
          i++;
        }
      }
    }
    _restoreCheckboxSpaces(children);
  }
}

// Dart inserts a newline text node when unwrapping a tight-list paragraph
// after another block. HTML collapses that leading separator at the start of
// the new anonymous line; the Flutter builder would paint it as a space.
void _trimListBlockSeparators(List<md.Node> nodes) {
  for (final node in nodes.whereType<md.Element>()) {
    final children = node.children;
    if (children == null) continue;
    if (node.tag == 'li') {
      var afterBlock = false;
      for (var i = 0; i < children.length; i++) {
        final child = children[i];
        if (afterBlock && child is md.Text) {
          final text = child.text.replaceFirst(RegExp(r'^[ \t\r\n\f]+'), '');
          if (text.isEmpty) {
            children.removeAt(i--);
            continue;
          }
          children[i] = md.Text(text);
        }
        afterBlock = child is md.Element && _blockTags.contains(child.tag);
      }
    }
    _trimListBlockSeparators(children);
  }
}

// Each quote receives a local paragraph style. Avoid the package's single
// quote boolean, which overrides headings and is cleared by nested quotes.
class _QuoteNode extends md.Element {
  _QuoteNode(this.original) : super('pirc-quote-scope', []);
  final md.Element original;
}

md.Node _isolateQuotes(md.Node node) {
  if (node is! md.Element) return node;
  if (node.tag == 'blockquote') return _QuoteNode(node);
  final original = node.children;
  if (original == null) return node;
  final children = original.map(_isolateQuotes).toList();
  if (List.generate(
    children.length,
    (i) => identical(children[i], original[i]),
  ).every((same) => same)) {
    return node;
  }
  return md.Element(node.tag, children)..attributes.addAll(node.attributes);
}

class _QuoteBuilder extends MarkdownElementBuilder {
  _QuoteBuilder(this.buildQuote);
  final Widget Function(md.Element) buildQuote;
  @override
  bool isBlockElement() => true;
  @override
  Widget visitElementAfterWithContext(
    BuildContext context,
    md.Element element,
    TextStyle? preferredStyle,
    TextStyle? parentStyle,
  ) => buildQuote((element as _QuoteNode).original);
}

class _QuoteScope extends StatelessWidget {
  const _QuoteScope({required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) =>
      NativeSelectionGroup(blockSeparation: true, child: child);
}
