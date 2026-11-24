part of 'native_tex_adapter.dart';

/// Makes the actual painted text glyphs selectable, preserving Math layout,
/// font metrics, italic corrections and the original expression tree.
SyntaxTree nativeSelectableMathTree(SyntaxTree ast) {
  GreenNode visit(GreenNode node) {
    if (node is SymbolNode) {
      return _SelectableMathSymbol(
        symbol: node.symbol,
        mode: node.mode,
        variantForm: node.variantForm,
        overrideAtomType: node.overrideAtomType,
        overrideFont: node.overrideFont,
      );
    }
    if (node is MultiscriptsNode) {
      EquationRowNode? row(EquationRowNode? child) =>
          child == null ? null : visit(child) as EquationRowNode;

      return _SelectableMathMultiscriptsNode(
        alignPostscripts: node.alignPostscripts,
        base: visit(node.base) as EquationRowNode,
        sub: row(node.sub),
        sup: row(node.sup),
        presub: row(node.presub),
        presup: row(node.presup),
      );
    }
    if (node.children.isEmpty) return node;
    return _updateMathChildren(node, [
      for (final child in node.children) child == null ? null : visit(child),
    ]);
  }

  return SyntaxTree(greenRoot: visit(ast.greenRoot) as EquationRowNode);
}

/// Gives script branches a single selectable boundary. The inner children
/// remain the actual RichText glyphs; only their copied fragment order follows
/// MathML's fixed base/sub/sup structure.
class _SelectableMathMultiscriptsNode extends MultiscriptsNode {
  _SelectableMathMultiscriptsNode({
    super.alignPostscripts,
    required super.base,
    super.sub,
    super.sup,
    super.presub,
    super.presup,
  });

  @override
  MultiscriptsNode updateChildren(List<EquationRowNode?> children) =>
      _SelectableMathMultiscriptsNode(
        alignPostscripts: alignPostscripts,
        base: children[0]!,
        sub: children[1],
        sup: children[2],
        presub: children[3],
        presup: children[4],
      );

  @override
  BuildResult buildWidget(
    MathOptions options,
    List<BuildResult?> childBuildResults,
  ) {
    final base = childBuildResults[0]!;
    return BuildResult(
      options: options,
      widget: _NativeMathScriptSelection(
        alignPostscripts: alignPostscripts,
        isBaseCharacterBox:
            this.base.flattenedChildList.length == 1 &&
            this.base.flattenedChildList[0] is SymbolNode,
        baseResult: base,
        subResult: childBuildResults[1],
        supResult: childBuildResults[2],
        presubResult: childBuildResults[3],
        presupResult: childBuildResults[4],
      ),
    );
  }
}

class _NativeMathScriptSelection extends StatefulWidget {
  const _NativeMathScriptSelection({
    required this.alignPostscripts,
    required this.isBaseCharacterBox,
    required this.baseResult,
    required this.subResult,
    required this.supResult,
    required this.presubResult,
    required this.presupResult,
  });

  final bool alignPostscripts;
  final bool isBaseCharacterBox;
  final BuildResult baseResult;
  final BuildResult? subResult;
  final BuildResult? supResult;
  final BuildResult? presubResult;
  final BuildResult? presupResult;

  @override
  State<_NativeMathScriptSelection> createState() =>
      _NativeMathScriptSelectionState();
}

class _NativeMathScriptSelectionState
    extends State<_NativeMathScriptSelection> {
  final _branchKeys = List<GlobalKey>.generate(
    5,
    (index) => GlobalKey(debugLabel: 'native-math-script-branch-$index'),
  );
  final _branchDelegates = List<StaticSelectionContainerDelegate>.generate(
    5,
    (_) => _MathScriptBranchSelectionDelegate(),
  );
  late final _delegate = _NativeMathScriptSelectionDelegate(_branchKeys);

  BuildResult? _groupBranch(BuildResult? result, int index) {
    if (result == null) return null;
    return BuildResult(
      options: result.options,
      italic: result.italic,
      skew: result.skew,
      results: result.results,
      widget: SelectionContainer(
        key: _branchKeys[index],
        delegate: _branchDelegates[index],
        child: result.widget,
      ),
    );
  }

  @override
  void dispose() {
    _delegate.dispose();
    for (final branch in _branchDelegates) {
      branch.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SelectionContainer(
    delegate: _delegate,
    child: Multiscripts(
      alignPostscripts: widget.alignPostscripts,
      isBaseCharacterBox: widget.isBaseCharacterBox,
      baseResult: _groupBranch(widget.baseResult, 0)!,
      subResult: _groupBranch(widget.subResult, 1),
      supResult: _groupBranch(widget.supResult, 2),
      presubResult: _groupBranch(widget.presubResult, 3),
      presupResult: _groupBranch(widget.presupResult, 4),
    ),
  );
}

class _NativeMathScriptSelectionDelegate
    extends StaticSelectionContainerDelegate {
  _NativeMathScriptSelectionDelegate(this._branchKeys);

  final List<GlobalKey> _branchKeys;

  @override
  SelectedContent? getSelectedContent() {
    final fragments = <String>[];
    // MathML's multiscripts child order is base, subscript, superscript,
    // presubscript, presuperscript. Read each nested container's real selected
    // text; never derive text from the AST or formula source.
    for (final key in _branchKeys) {
      final branch = key.currentState;
      if (branch is! Selectable) continue;
      final content = (branch as Selectable).getSelectedContent();
      if (content != null && content.plainText.isNotEmpty) {
        fragments.add(content.plainText);
      }
    }
    if (fragments.isEmpty) return null;
    return SelectedContent(plainText: fragments.join());
  }
}

/// Keeps the true gesture anchor and focus when a script branch is made of
/// several selectable glyph fragments. Flutter's default multi-selectable
/// delegate can clear an anchor fragment at a boundary before it sees the
/// second edge, so rebuild the covered fragments from real child selections.
class _MathScriptBranchSelectionDelegate
    extends StaticSelectionContainerDelegate {
  Offset? _anchorPosition, _focusPosition;
  TextGranularity? _anchorGranularity, _focusGranularity;
  Selectable? _anchorSelectable, _focusSelectable;
  bool _recordingPointerEdge = false;

  void _clearDragTracking() {
    _anchorPosition = _focusPosition = null;
    _anchorGranularity = _focusGranularity = null;
    _anchorSelectable = _focusSelectable = null;
  }

  @override
  SelectionResult dispatchSelectionEvent(SelectionEvent event) {
    if (event is! SelectionEdgeUpdateEvent) _clearDragTracking();
    return super.dispatchSelectionEvent(event);
  }

  @override
  SelectionResult handleSelectionEdgeUpdate(SelectionEdgeUpdateEvent event) {
    if (event.type == SelectionEventType.startEdgeUpdate) {
      _anchorPosition = event.globalPosition;
      _anchorGranularity = event.granularity;
      _anchorSelectable = null;
    } else {
      _focusPosition = event.globalPosition;
      _focusGranularity = event.granularity;
      _focusSelectable = null;
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
          _anchorSelectable = selectable;
        } else {
          _focusSelectable = selectable;
        }
      }
    }
    return result;
  }

  void _rebuildSelectionAcrossFragments() {
    final anchor = _anchorSelectable;
    final focus = _focusSelectable;
    final anchorPosition = _anchorPosition;
    final focusPosition = _focusPosition;
    if (anchor == null ||
        focus == null ||
        anchorPosition == null ||
        focusPosition == null) {
      return;
    }
    final anchorIndex = selectables.indexOf(anchor);
    final focusIndex = selectables.indexOf(focus);
    if (anchorIndex < 0 || focusIndex < 0) return;
    if (anchorIndex == focusIndex) {
      super.dispatchSelectionEventToChild(
        anchor,
        SelectionEdgeUpdateEvent.forStart(
          globalPosition: anchorPosition,
          granularity: _anchorGranularity ?? TextGranularity.character,
        ),
      );
      super.dispatchSelectionEventToChild(
        focus,
        SelectionEdgeUpdateEvent.forEnd(
          globalPosition: focusPosition,
          granularity: _focusGranularity ?? TextGranularity.character,
        ),
      );
      return;
    }

    // Each branch is a single MathML logical group, so restore the actual
    // selected glyph fragments after a drag crosses branch children. The
    // enclosing paragraph delegate only repairs when its marker edge was
    // routed to a different selectable; it does not redo this inner selection.
    final forward = anchorIndex < focusIndex;
    final lower = forward ? anchorIndex : focusIndex;
    final upper = forward ? focusIndex : anchorIndex;
    for (var index = lower + 1; index < upper; index++) {
      super.dispatchSelectionEventToChild(
        selectables[index],
        const SelectAllSelectionEvent(),
      );
    }
    _selectEndpoint(
      anchor,
      startEdge: anchorPosition,
      endEdgeRole: forward
          ? _MathScriptEndpointEdge.logicalEnd
          : _MathScriptEndpointEdge.logicalStart,
      granularity: _anchorGranularity ?? TextGranularity.character,
    );
    _selectEndpoint(
      focus,
      startEdgeRole: forward
          ? _MathScriptEndpointEdge.logicalStart
          : _MathScriptEndpointEdge.logicalEnd,
      endEdge: focusPosition,
      granularity: _focusGranularity ?? TextGranularity.character,
    );
    currentSelectionStartIndex = anchorIndex;
    currentSelectionEndIndex = focusIndex;
  }

  void _selectEndpoint(
    Selectable selectable, {
    Offset? startEdge,
    Offset? endEdge,
    _MathScriptEndpointEdge? startEdgeRole,
    _MathScriptEndpointEdge? endEdgeRole,
    required TextGranularity granularity,
  }) {
    super.dispatchSelectionEventToChild(
      selectable,
      const SelectAllSelectionEvent(),
    );
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
          _MathScriptEndpointEdge.logicalStart => logicalStart,
          _MathScriptEndpointEdge.logicalEnd => logicalEnd,
          null => null,
        };
    final resolvedEnd =
        endEdge ??
        switch (endEdgeRole) {
          _MathScriptEndpointEdge.logicalStart => logicalStart,
          _MathScriptEndpointEdge.logicalEnd => logicalEnd,
          null => null,
        };
    if (resolvedStart == null || resolvedEnd == null) return;
    super.dispatchSelectionEventToChild(
      selectable,
      SelectionEdgeUpdateEvent.forStart(
        globalPosition: resolvedStart,
        granularity: granularity,
      ),
    );
    super.dispatchSelectionEventToChild(
      selectable,
      SelectionEdgeUpdateEvent.forEnd(
        globalPosition: resolvedEnd,
        granularity: granularity,
      ),
    );
  }

  @override
  SelectionResult handleClearSelection(ClearSelectionEvent event) {
    _clearDragTracking();
    return super.handleClearSelection(event);
  }
}

enum _MathScriptEndpointEdge { logicalStart, logicalEnd }

class _SelectableMathSymbol extends SymbolNode {
  _SelectableMathSymbol({
    required super.symbol,
    required super.mode,
    super.variantForm,
    super.overrideAtomType,
    super.overrideFont,
  });

  @override
  SymbolNode withSymbol(String symbol) => _SelectableMathSymbol(
    symbol: symbol,
    mode: mode,
    variantForm: variantForm,
    overrideAtomType: overrideAtomType,
    overrideFont: overrideFont,
  );

  @override
  BuildResult buildWidget(MathOptions options, List<BuildResult?> children) {
    final original = super.buildWidget(options, children);
    return BuildResult(
      widget: _registerMathText(original.widget),
      options: original.options,
      italic: original.italic,
      skew: original.skew,
      results: original.results,
    );
  }
}

Widget _registerMathText(Widget widget) {
  if (widget is RichText) {
    return Builder(
      builder: (context) => RichText(
        key: widget.key,
        text: widget.text,
        textAlign: widget.textAlign,
        textDirection: widget.textDirection,
        softWrap: widget.softWrap,
        overflow: widget.overflow,
        textScaler: widget.textScaler,
        maxLines: widget.maxLines,
        locale: widget.locale,
        strutStyle: widget.strutStyle,
        textWidthBasis: widget.textWidthBasis,
        textHeightBehavior: widget.textHeightBehavior,
        selectionColor:
            DefaultSelectionStyle.of(context).selectionColor ??
            DefaultSelectionStyle.defaultColor,
        selectionRegistrar: SelectionContainer.maybeOf(context),
      ),
    );
  }
  if (widget is ResetDimension) {
    return ResetDimension(
      key: widget.key,
      height: widget.height,
      depth: widget.depth,
      width: widget.width,
      horizontalAlignment: widget.horizontalAlignment,
      child: _registerMathText(widget.child!),
    );
  }
  if (widget is Padding) {
    return Padding(
      key: widget.key,
      padding: widget.padding,
      child: widget.child == null ? null : _registerMathText(widget.child!),
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
      children: widget.children.map(_registerMathText).toList(),
    );
  }
  // Some composite/stretchy symbols are painted paths. Their selection is a
  // separate capability, not replaced with hidden text here.
  return widget;
}

/// Clipboard prefix observed from pinned Chrome's selected MathML branch.
/// Accepts plain symbol rows. Recognized fractions/postscript structures use
/// the separately verified full two-branch model below.
String? nativeLinearMathClipboardPrefix(Math math) {
  final root = math.ast?.greenRoot;
  if (root == null || root.children.isEmpty) return null;
  final tokens = <String>[];
  for (final node in root.children) {
    if (node is! SymbolNode ||
        !RegExp(r'^[A-Za-z0-9α-ωΑ-Ω+\-=−()]$').hasMatch(node.symbol)) {
      return null;
    }
    final symbol = node.symbol == '-' ? '−' : node.symbol;
    // KaTeX's MathML builder combines adjacent number atoms into one mn.
    // Letters stay individual mi atoms; do not merge an authored word.
    if (RegExp(r'^[0-9]$').hasMatch(symbol) &&
        tokens.isNotEmpty &&
        RegExp(r'^[0-9]+$').hasMatch(tokens.last)) {
      tokens[tokens.length - 1] += symbol;
    } else {
      tokens.add(symbol);
    }
  }
  return '\n${tokens.join('\n')}\n';
}

class NativeMathClipboardPlan {
  const NativeMathClipboardPlan(this.prefix, {this.fullVisualText});
  final String prefix;
  // Only recognized structural ASTs have a complete verified HTML-branch model.
  final String? fullVisualText;
}

NativeMathClipboardPlan? nativeMathClipboardPlan(Math math) {
  final linear = nativeLinearMathClipboardPrefix(math);
  if (linear != null) return NativeMathClipboardPlan(linear);
  final root = math.ast?.greenRoot;
  if (root == null) return null;
  final branch = _structuralMathClipboardNode(root, 0);
  if (branch == null || !branch.structural) return null;
  return NativeMathClipboardPlan(
    branch.semantic.isEmpty ? '' : '\n${branch.semantic.join('\n')}\n',
    fullVisualText: branch.visual,
  );
}

class _MathClipboardBranch {
  const _MathClipboardBranch(
    this.semantic,
    this.visual, {
    this.startsTable = false,
    this.structural = false,
  });
  final List<String> semantic;
  final String visual;
  final bool startsTable, structural;
}

_MathClipboardBranch? _structuralMathClipboardNode(GreenNode node, int depth) {
  if (depth > 64) return null;
  if (node is SymbolNode) {
    if (node.variantForm ||
        node.overrideFont != null ||
        !RegExp(r'^[A-Za-z0-9α-ωΑ-Ω+\-=−()]$').hasMatch(node.symbol)) {
      return null;
    }
    final symbol = node.symbol == '-' ? '−' : node.symbol;
    return _MathClipboardBranch([symbol], symbol);
  }
  if (node is EquationRowNode) {
    if (node.children.isEmpty) return null;
    final semantic = <String>[];
    final visual = StringBuffer();
    var precedingDigit = false, structural = false, startsTable = false;
    for (final child in node.children) {
      final branch = _structuralMathClipboardNode(child, depth + 1);
      if (branch == null) return null;
      final digit =
          child is SymbolNode && RegExp(r'^[0-9]$').hasMatch(child.symbol);
      if (digit && precedingDigit) {
        semantic[semantic.length - 1] += branch.semantic.single;
      } else {
        semantic.addAll(branch.semantic);
      }
      precedingDigit = digit;
      if (visual.isEmpty) startsTable = branch.startsTable;
      // Chrome inserts a space/newline before an inline vlist table following
      // sibling content. Existing trailing vlist whitespace remains significant.
      if (branch.startsTable && visual.isNotEmpty) visual.write(' \n');
      visual.write(branch.visual);
      structural = structural || branch.structural;
    }
    return _MathClipboardBranch(
      semantic,
      visual.toString(),
      startsTable: startsTable,
      structural: structural,
    );
  }
  if (node is FracNode) {
    if (node.barSize != null || node.continued) return null;
    final numerator = _structuralMathClipboardNode(node.numerator, depth + 1);
    final denominator = _structuralMathClipboardNode(
      node.denominator,
      depth + 1,
    );
    if (numerator == null || denominator == null) return null;
    // KaTeX mfrac is numerator/denominator, but its HTML vlist builds the
    // denominator first, then the rule (no text), numerator and U+200B strut.
    return _MathClipboardBranch(
      [...numerator.semantic, ...denominator.semantic],
      '${denominator.visual}\n${numerator.visual}\n\u200b\n ',
      startsTable: true,
      structural: true,
    );
  }
  if (node is SqrtNode) {
    final body = node.base.children.isEmpty
        ? const _MathClipboardBranch([], '')
        : _structuralMathClipboardNode(node.base, depth + 1);
    final index = node.index == null
        ? null
        : _structuralMathClipboardNode(node.index!, depth + 1);
    if (body == null || (node.index != null && index == null)) return null;
    // KaTeX's surd is an SVG path. MathML copies body/index, while the HTML
    // branch places its index vlist first and retains the body's U+200B strut.
    return _MathClipboardBranch(
      [...body.semantic, if (index != null) ...index.semantic],
      '${index == null ? '' : '${index.visual}\n  \n'}${body.visual}\n\u200b\n ',
      startsTable: true,
      structural: true,
    );
  }
  if (node is MultiscriptsNode) {
    if (node.presub != null ||
        node.presup != null ||
        node.alignPostscripts ||
        node.base.children.length != 1 ||
        (node.base.children.single is! SymbolNode &&
            node.base.children.single is! SqrtNode) ||
        (node.sub == null && node.sup == null)) {
      return null;
    }
    final base = _structuralMathClipboardNode(node.base, depth + 1);
    final sub = node.sub == null
        ? null
        : _structuralMathClipboardNode(node.sub!, depth + 1);
    final sup = node.sup == null
        ? null
        : _structuralMathClipboardNode(node.sup!, depth + 1);
    if (base == null ||
        (node.sub != null && sub == null) ||
        (node.sup != null && sup == null)) {
      return null;
    }
    final scripts = <_MathClipboardBranch>[?sub, ?sup];
    return _MathClipboardBranch(
      [...base.semantic, for (final script in scripts) ...script.semantic],
      '${base.visual} \n${scripts.map((s) => s.visual).join('\n')}\n${sub == null ? ' ' : '\u200b\n '}',
      structural: true,
    );
  }
  return null;
}

/// Complements selected painted glyphs with the selected MathML branch for
/// Select All. Pointer/word/handle selection continues to return real glyphs.
class NativeMathClipboardPart extends StatefulWidget {
  const NativeMathClipboardPart({
    super.key,
    required this.prefix,
    required this.child,
    this.fullText,
  });
  final String prefix;
  final String? fullText;
  final Widget child;
  @override
  State<NativeMathClipboardPart> createState() =>
      _NativeMathClipboardPartState();
}

class _NativeMathClipboardPartState extends State<NativeMathClipboardPart> {
  late final delegate = _MathClipboardDelegate(
    () => widget.prefix,
    () => widget.fullText,
  );
  @override
  void didUpdateWidget(covariant NativeMathClipboardPart oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.prefix != widget.prefix ||
        oldWidget.fullText != widget.fullText) {
      delegate.clearClipboardSelection();
    }
  }

  @override
  void dispose() {
    delegate.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      SelectionContainer(delegate: delegate, child: widget.child);
}

class _MathClipboardDelegate extends StaticSelectionContainerDelegate {
  _MathClipboardDelegate(this.prefix, this.fullText);
  final String Function() prefix;
  final String? Function() fullText;
  bool selectedAll = false;
  void clearClipboardSelection() {
    selectedAll = false;
    notifyListeners();
  }

  bool get _vectorOnly => selectables.isEmpty && fullText() != null;
  @override
  int get contentLength =>
      _vectorOnly ? fullText()!.length : super.contentLength;
  @override
  SelectedContentRange? getSelection() => _vectorOnly
      ? selectedAll
            ? SelectedContentRange(startOffset: 0, endOffset: contentLength)
            : null
      : super.getSelection();
  @override
  SelectionGeometry get value =>
      _vectorOnly ? getSelectionGeometry() : super.value;
  @override
  SelectionGeometry getSelectionGeometry() {
    if (!_vectorOnly) return super.getSelectionGeometry();
    // Empty radicals still paint a real SVG surd. Register that container's
    // actual bounds for Select All without inserting hidden selectable text.
    if (!selectedAll) {
      return const SelectionGeometry(
        status: SelectionStatus.none,
        hasContent: true,
      );
    }
    final box = containerSize;
    return SelectionGeometry(
      status: SelectionStatus.uncollapsed,
      hasContent: true,
      startSelectionPoint: SelectionPoint(
        localPosition: Offset(0, box.height),
        lineHeight: box.height,
        handleType: TextSelectionHandleType.left,
      ),
      endSelectionPoint: SelectionPoint(
        localPosition: Offset(box.width, box.height),
        lineHeight: box.height,
        handleType: TextSelectionHandleType.right,
      ),
      selectionRects: [Offset.zero & box],
    );
  }

  @override
  SelectionResult dispatchSelectionEvent(SelectionEvent event) {
    selectedAll = event.type == SelectionEventType.selectAll;
    return super.dispatchSelectionEvent(event);
  }

  @override
  SelectedContent? getSelectedContent() {
    final selected = super.getSelectedContent();
    if (!selectedAll) return selected;
    if (fullText() != null) return SelectedContent(plainText: fullText()!);
    if (selected == null || selected.plainText.isEmpty) return selected;
    return SelectedContent(
      plainText: fullText() ?? '${prefix()}${selected.plainText}',
    );
  }
}
