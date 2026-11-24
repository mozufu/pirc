part of 'native_tex_adapter.dart';

/// A tag remains separate from the formula AST, as in the pinned KaTeX tree.
class NativeTexEquationTag {
  NativeTexEquationTag({
    this.content,
    required this.automatic,
    this.anchor,
    this.column,
  });
  final EquationRowNode? content;
  final bool automatic;
  final NativeMathTagAnchor? anchor;
  final Object? column;
}

class NativeTexParseResult {
  NativeTexParseResult({required this.ast, required this.tags});
  final SyntaxTree ast;
  final List<NativeTexEquationTag> tags;
  int get automaticNumberCount => tags.where((tag) => tag.automatic).length;
}

/// Parse body and tags with one macro namespace and expansion budget.
NativeTexParseResult parseNativeTex(
  String expression, {
  TexParserSettings settings = const TexParserSettings(),
}) {
  registerNativeTexExtensions();
  final parser = _NativeTexParser(expression, settings);
  parser.clearGlobalMacro(r'\df@tag');
  final body = parser.parse();
  if (parser.macroExpander.macros.get(r'\df@tag') != null) {
    if (!settings.displayMode) {
      throw ParseException(tr("\\tag works only in display equations"));
    }
    parser.equationTags.add(
      NativeTexEquationTag(content: parser.parseTag(), automatic: false),
    );
  }
  return NativeTexParseResult(
    ast: SyntaxTree(greenRoot: body),
    tags: List.unmodifiable(parser.equationTags),
  );
}

class _NativeEquationInternal extends TransparentNode {
  @override
  final List<GreenNode> children = const [];
  @override
  AtomType get leftType => AtomType.spacing;
  @override
  AtomType get rightType => AtomType.spacing;
  @override
  List<MathOptions> computeChildOptions(MathOptions options) => const [];
  @override
  _NativeEquationInternal updateChildren(List<GreenNode> newChildren) =>
      _NativeEquationInternal();
  @override
  bool shouldRebuildWidget(MathOptions oldOptions, MathOptions newOptions) =>
      false;
}

GreenNode _suppressEquationNumber(TexParser parser, FunctionContext context) {
  parser.macroExpander.macros.set(
    r'\@eqnsw',
    MacroDefinition.fromString('0'),
    global: true,
  );
  return _NativeEquationInternal();
}

/// Preserves the package's direct RenderLine children needed by EqnArray.
class _NativeTaggedEquationRow extends EquationRowNode {
  _NativeTaggedEquationRow({required super.children, required this.anchor});
  final NativeMathTagAnchor anchor;
  @override
  BuildResult buildWidget(MathOptions options, List<BuildResult?> children) {
    final result = super.buildWidget(options, children);
    return BuildResult(
      options: result.options,
      widget: NativeMathTagRow(anchor: anchor, child: result.widget),
    );
  }

  @override
  EquationRowNode updateChildren(List<GreenNode> newChildren) =>
      _NativeTaggedEquationRow(children: newChildren, anchor: anchor);
}

GreenNode _numberedEquationEnvironment(TexParser raw, EnvContext context) {
  if (raw is! _NativeTexParser) {
    // Keep the pre-existing registry's body-only gather API usable by raw
    // Math.tex consumers. The App uses NativeMathTex for tag metadata.
    if (context.envName == 'gather' || context.envName == 'gather*') {
      return _gatherEnvironmentHandler(raw, context);
    }
    throw ParseException(tr("Equation tags require the native TeX parser."));
  }
  final parser = raw;
  if (!parser.settings.displayMode) {
    throw ParseException(
      tr("{{0}} can be used only in display mode.", [context.envName]),
    );
  }
  final isAlign = context.envName.startsWith('align');
  final singleRow = context.envName.startsWith('equation');
  final automatic = !context.envName.endsWith('*');
  final expander = parser.macroExpander;
  expander.beginGroup();
  expander.macros.set(r'\\', MacroDefinition.fromString(r'\cr'));
  final stretch = expander.expandMacroAsText(r'\arraystretch');
  final arrayStretch = stretch == null ? 1.0 : double.tryParse(stretch);
  if (arrayStretch == null || arrayStretch < 0) {
    throw ParseException(
      r'Invalid \arraystretch: '
      '$stretch',
    );
  }
  expander.beginGroup();
  final column = Object();
  final body = <EquationRowNode>[];
  final rowSpacings = <Measurement>[];
  final hlines = <MatrixSeparatorStyle>[];
  var cells = <EquationRowNode>[];
  var rowAutomatic = automatic;
  void beginRow() {
    rowAutomatic = automatic;
    if (automatic) {
      expander.macros.set(
        r'\@eqnsw',
        MacroDefinition.fromString('1'),
        global: true,
      );
    }
  }

  void endRow() {
    final manual = expander.macros.get(r'\df@tag') != null;
    final numbered =
        rowAutomatic && expander.expandMacroAsText(r'\@eqnsw') == '1';
    final content = manual ? parser.parseTag() : null;
    final anchor = manual || numbered ? NativeMathTagAnchor() : null;
    final children = <GreenNode>[];
    if (isAlign) {
      // Alternating right/left columns use the fork's alignment markers.
      for (var index = 0; index < cells.length; index++) {
        if (index.isOdd) children.add(EquationRowNode.empty());
        children.addAll(cells[index].children);
        children.add(SpaceNode.alignerOrSpacer());
      }
    } else {
      if (cells.length != 1) {
        throw ParseException(tr("Too many columns in {0}", [context.envName]));
      }
      children.addAll(cells.single.children);
    }
    final styled = <GreenNode>[
      StyleNode(
        optionsDiff: const OptionsDiff(style: MathStyle.display),
        children: children,
      ),
    ];
    body.add(
      anchor == null
          ? EquationRowNode(children: styled)
          : _NativeTaggedEquationRow(children: styled, anchor: anchor),
    );
    if (anchor != null) {
      parser.equationTags.add(
        NativeTexEquationTag(
          content: content,
          automatic: !manual,
          anchor: anchor,
          column: column,
        ),
      );
    }
    if (manual) parser.clearGlobalMacro(r'\df@tag');
  }

  beginRow();
  hlines.add(getHLines(parser).lastOrNull ?? MatrixSeparatorStyle.none);
  while (true) {
    final content = parser.parseExpression(
      breakOnInfix: false,
      breakOnTokenText: singleRow ? r'\end' : r'\cr',
    );
    expander.endGroup();
    expander.beginGroup();
    cells.add(content.wrapWithEquationRow());
    final next = parser.fetch().text;
    if (next == '&') {
      if (!isAlign) {
        throw ParseException(tr("Too many columns in {0}", [context.envName]));
      }
      parser.consume();
    } else if (next == r'\end') {
      // KaTeX keeps one empty AMS row but removes a trailing empty row.
      if (body.isEmpty || cells.length != 1 || content.isNotEmpty) endRow();
      hlines.add(MatrixSeparatorStyle.none);
      break;
    } else if (next == r'\cr' && !singleRow) {
      final cr = parser.parseFunction(null, null, null);
      if (cr is! CrNode) {
        throw ParseException(tr("Expected equation row break"));
      }
      endRow();
      rowSpacings.add(cr.size ?? Measurement.zero);
      hlines.add(getHLines(parser).lastOrNull ?? MatrixSeparatorStyle.none);
      cells = [];
      beginRow();
    } else {
      throw ParseException(r'Expected & or \\ or \end', parser.nextToken);
    }
  }
  expander.endGroup();
  expander.endGroup();
  final array = EquationArrayNode(
    body: body,
    addJot: !singleRow,
    arrayStretch: arrayStretch,
    hlines: hlines,
    rowSpacings: rowSpacings,
  );
  return _removeTrailingJot(array);
}
