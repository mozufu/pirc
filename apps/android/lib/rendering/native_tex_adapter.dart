import 'render_l10n.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart'
    show
        ClearSelectionEvent,
        SelectAllSelectionEvent,
        Selectable,
        SelectedContent,
        SelectedContentRange,
        SelectionGeometry,
        SelectionStatus,
        SelectionPoint,
        SelectionEdgeUpdateEvent,
        SelectionEvent,
        SelectionEventType,
        SelectionResult,
        TextGranularity;
import 'package:flutter_math_fork/flutter_math.dart'
    show
        FontOptions,
        Math,
        MathOptions,
        MathStyle,
        OnErrorFallback,
        TexParserSettings;
import 'package:flutter_math_fork/src/ast/options.dart' show OptionsDiff;
import 'package:flutter_math_fork/src/ast/size.dart'
    show Measurement, MeasurementExtOnNum;
import 'package:flutter_math_fork/src/ast/nodes/equation_array.dart';
import 'package:flutter_math_fork/src/ast/nodes/frac.dart';
import 'package:flutter_math_fork/src/ast/nodes/sqrt.dart';
import 'package:flutter_math_fork/src/ast/nodes/space.dart';
import 'package:flutter_math_fork/src/ast/nodes/style.dart';
import 'package:flutter_math_fork/src/ast/nodes/symbol.dart';
import 'package:flutter_math_fork/src/ast/style.dart' show MathStyleExt;
import 'package:flutter_math_fork/src/ast/syntax_tree.dart';
import 'package:flutter_math_fork/src/ast/types.dart' show Mode;
import 'package:flutter_math_fork/src/parser/tex/define_environment.dart';
import 'package:flutter_math_fork/src/parser/tex/environments/array.dart'
    show getHLines;
import 'package:flutter_math_fork/src/ast/nodes/matrix.dart'
    show MatrixNode, MatrixSeparatorStyle;
import 'package:flutter_math_fork/src/ast/nodes/multiscripts.dart'
    show MultiscriptsNode;
import 'package:flutter_math_fork/src/render/layout/multiscripts.dart'
    show Multiscripts;
import 'package:flutter_math_fork/src/parser/tex/functions/katex_base.dart'
    show CrNode;
import 'native_equation_numbers.dart';
import 'package:flutter_math_fork/src/parser/tex/macros.dart'
    show MacroDefinition;
import 'package:flutter_math_fork/src/parser/tex/token.dart' show Token;
import 'native_tex_macros.dart';
import 'native_math_tags.dart';

import 'package:flutter_math_fork/src/parser/tex/environments/eqn_array.dart';
import 'package:flutter_math_fork/src/parser/tex/functions.dart';
import 'package:flutter_math_fork/src/parser/tex/macro_expander.dart'
    show implicitCommands;
import 'package:flutter_math_fork/src/parser/tex/parse_error.dart';
import 'package:flutter_math_fork/src/parser/tex/parser.dart';
import 'package:flutter_math_fork/src/parser/tex/symbols.dart'
    show texSymbolCommandConfigs;
import 'package:flutter_math_fork/src/render/layout/reset_dimension.dart';

part 'native_tex_equations.dart';
part 'native_math_selection.dart';

// The pinned package has no public parser extension registry or AST API.
// ignore_for_file: implementation_imports

/// Registers parser and AST implementations for commands supported by KaTeX
/// but missing from the pinned flutter_math_fork parser.
///
/// Call once before constructing Math.tex widgets. The package currently has
/// no public extension registry on TexParserSettings, so this adapter extends
/// the package's pinned parser registries without changing its cached source.
void registerNativeTexExtensions() {
  registerNativeTexMacros();
  functions.putIfAbsent(
    r'\mathchoice',
    () => FunctionSpec(numArgs: 4, handler: _mathChoiceHandler),
  );
  functions.putIfAbsent(
    r'\smash',
    () => FunctionSpec(
      numArgs: 1,
      numOptionalArgs: 1,
      allowedInText: true,
      handler: _smashHandler,
    ),
  );

  final gathered = EnvSpec(numArgs: 0, handler: _gatherEnvironmentHandler);
  environments.putIfAbsent('gathered', () => gathered);
  for (final name in [
    'gather',
    'gather*',
    'align',
    'align*',
    'equation',
    'equation*',
  ]) {
    environments.putIfAbsent(
      name,
      () => EnvSpec(numArgs: 0, handler: _numberedEquationEnvironment),
    );
  }
  for (final name in [r'\notag', r'\nonumber']) {
    functions.putIfAbsent(
      name,
      () => FunctionSpec(
        numArgs: 0,
        allowedInText: true,
        handler: _suppressEquationNumber,
      ),
    );
  }
}

/// A resolved expression retained as data when its inline fragments are
/// rendered directly inside a paragraph rather than as an atomic widget.
class NativeResolvedMath {
  const NativeResolvedMath({required this.math, required this.tags});
  final Math math;
  final List<NativeTexEquationTag> tags;
}

/// Parses TeX and resolves mathchoice branches using the options from this
/// widget's final build context. Keeping this as a widget is important for
/// Markdown inline math, where a parent builder may insert a no-scaling
/// MediaQuery after the Markdown element has already been visited.
class NativeMathTex extends StatelessWidget {
  const NativeMathTex(
    this.expression, {
    super.key,
    this.mathStyle = MathStyle.display,
    this.textStyle,
    this.onErrorFallback = Math.defaultOnErrorFallback,
    this.onParsed,
    this.settings = const TexParserSettings(),
    this.textScaleFactor,
    this.logicalPpi,
    this.options,
    this.firstEquationNumber,
  });

  final String expression;
  final MathStyle mathStyle;
  final TextStyle? textStyle;
  final OnErrorFallback onErrorFallback;

  /// Wraps successfully parsed math; parse errors keep the fallback widget path.
  final Widget Function(BuildContext context, Widget math)? onParsed;
  final TexParserSettings settings;
  final double? textScaleFactor;
  final double? logicalPpi;
  final MathOptions? options;
  final int? firstEquationNumber;

  NativeResolvedMath resolve(BuildContext context) {
    registerNativeTexExtensions();
    final resolvedOptions =
        options ??
        _mathOptionsFromContext(
          context,
          mathStyle: mathStyle,
          textStyle: textStyle,
          textScaleFactor: textScaleFactor,
          logicalPpi: logicalPpi,
        );

    SyntaxTree? ast;
    ParseException? parseError;
    var tags = <NativeTexEquationTag>[];
    try {
      final result = parseNativeTex(expression, settings: settings);
      ast = result.ast;
      tags = result.tags;
      ast = nativeSelectableMathTree(
        resolveNativeMathChoices(ast, resolvedOptions),
      );
    } on ParseException catch (error) {
      parseError = error;
    } on Object catch (error) {
      parseError = ParseException(
        tr(
          "Unsanitized parse exception detected: {0}. Please report this error with corresponding input.",
          [error],
        ),
      );
    }

    final math = Math(
      key: key,
      ast: ast,
      parseError: parseError,
      mathStyle: mathStyle,
      textStyle: textStyle,
      logicalPpi: logicalPpi,
      options: resolvedOptions,
      onErrorFallback: onErrorFallback,
    );
    return NativeResolvedMath(math: math, tags: tags);
  }

  @override
  Widget build(BuildContext context) {
    RenderL10n.watch(context);
    final resolved = resolve(context);
    final math = resolved.math;
    final tags = resolved.tags;
    final parseError = math.parseError;
    final resolvedOptions = math.options!;
    Widget finish(int firstNumber) {
      Widget rendered = math;
      if (parseError == null && tags.isNotEmpty) {
        var nextNumber = firstNumber;
        rendered = NativeTaggedMath(
          math: math,
          tags: [
            for (final tag in tags)
              NativeMathTag(
                anchor: tag.anchor,
                column: tag.column,
                math: Math(
                  ast: nativeSelectableMathTree(
                    resolveNativeMathChoices(
                      SyntaxTree(
                        greenRoot:
                            tag.content ??
                            EquationRowNode(
                              children: '(${nextNumber++})'.runes
                                  .map(
                                    (rune) => SymbolNode(
                                      symbol: String.fromCharCode(rune),
                                      mode: Mode.text,
                                    ),
                                  )
                                  .toList(),
                            ),
                      ),
                      resolvedOptions,
                    ),
                  ),
                  options: resolvedOptions,
                  mathStyle: mathStyle,
                  onErrorFallback: onErrorFallback,
                ),
              ),
          ],
        );
      }
      return parseError == null && onParsed != null
          ? onParsed!(context, rendered)
          : rendered;
    }

    final numberCount = tags.where((tag) => tag.automatic).length;
    return firstEquationNumber == null && numberCount > 0
        ? NativeEquationNumberSlot(count: numberCount, builder: finish)
        : finish(firstEquationNumber ?? 1);
  }
}

/// Matches KaTeX's `throwOnError: false` behavior for unknown control words.
///
/// The pinned fork's own unsupported-command formatter is unimplemented. This
/// subclass handles only the leaf command at the parser's group boundary, so
/// enclosing functions and the rest of the expression still use the original
/// parser and malformed syntax continues to raise its normal parse error.
class _NativeTexParser extends TexParser {
  _NativeTexParser(super.content, super.settings);

  final equationTags = <NativeTexEquationTag>[];

  void clearGlobalMacro(String name) {
    macroExpander.macros.current.remove(name);
    for (final group in macroExpander.macros.undefStack) {
      group.remove(name);
    }
  }

  EquationRowNode parseTag() {
    final savedToken = nextToken;
    final savedMode = mode;
    final stackLength = macroExpander.stack.length;
    consume();
    switchMode(Mode.math);
    macroExpander.pushToken(Token('}'));
    macroExpander.pushToken(Token(r'\df@tag'));
    try {
      final content = parseExpression(breakOnInfix: false);
      expect('}');
      return content.wrapWithEquationRow();
    } finally {
      if (macroExpander.stack.length > stackLength) {
        macroExpander.stack.removeRange(
          stackLength,
          macroExpander.stack.length,
        );
      }
      nextToken = savedToken;
      switchMode(savedMode);
    }
  }

  @override
  List<GreenNode> parseExpression({
    bool breakOnInfix = false,
    String? breakOnTokenText,
    bool infixArgumentMode = false,
  }) => super
      .parseExpression(
        breakOnInfix: breakOnInfix,
        breakOnTokenText: breakOnTokenText,
        infixArgumentMode: infixArgumentMode,
      )
      .where(
        (node) =>
            node is! _NativeEquationInternal &&
            node is! NativeTexAssignmentNode,
      )
      .toList();

  static final RegExp _verbToken = RegExp(r'^\\verb[^a-zA-Z]');

  @override
  GreenNode? parseGroup(
    String name, {
    required bool optional,
    int? greediness,
    String? breakOnTokenText,
    Mode? mode,
    bool consumeSpaces = false,
  }) {
    if (settings.throwOnError || optional) {
      return super.parseGroup(
        name,
        optional: optional,
        greediness: greediness,
        breakOnTokenText: breakOnTokenText,
        mode: mode,
        consumeSpaces: consumeSpaces,
      );
    }

    final outerMode = this.mode;
    if (mode != null) switchMode(mode);
    if (consumeSpaces) this.consumeSpaces();

    final token = fetch();
    final command = token.text;
    final isUnknownControl =
        command.startsWith('\\') &&
        !implicitCommands.contains(command) &&
        !functions.containsKey(command) &&
        !texSymbolCommandConfigs[this.mode]!.containsKey(command) &&
        !_verbToken.hasMatch(command);

    if (isUnknownControl) {
      final node = _unsupportedCommandNode(command);
      consume();
      if (mode != null) switchMode(outerMode);
      return node;
    }

    if (mode != null) switchMode(outerMode);
    return super.parseGroup(
      name,
      optional: optional,
      greediness: greediness,
      breakOnTokenText: breakOnTokenText,
      mode: mode,
      consumeSpaces: consumeSpaces,
    );
  }
}

GreenNode _unsupportedCommandNode(String command) => StyleNode(
  optionsDiff: const OptionsDiff(color: Color(0xffcc0000)),
  children: [
    EquationRowNode(
      children: command.runes
          .map(
            (rune) =>
                SymbolNode(symbol: String.fromCharCode(rune), mode: Mode.text),
          )
          .toList(growable: false),
    ),
  ],
);

/// Replaces each registered mathchoice node with the branch selected by the
/// options at that exact point in the tree. Parent nodes are rebuilt through
/// GreenNode.updateChildren, refreshing derived edge atom types.
SyntaxTree resolveNativeMathChoices(SyntaxTree ast, MathOptions rootOptions) {
  GreenNode resolve(GreenNode node, MathOptions options) {
    if (node is _NativeMathChoiceNode) {
      final index = options.style.size.clamp(0, 3).toInt();
      final branchOptions = node.computeChildOptions(options)[index];
      return resolve(node.branches[index], branchOptions);
    }

    final oldChildren = node.children;
    if (oldChildren.isEmpty) return node;
    final childOptions = node.computeChildOptions(options);
    if (childOptions.length != oldChildren.length) {
      throw StateError(
        tr("{0} returned {1} child options for {2} AST children.", [
          node.runtimeType,
          childOptions.length,
          oldChildren.length,
        ]),
      );
    }

    var changed = false;
    final newChildren = <GreenNode?>[];
    for (var index = 0; index < oldChildren.length; index++) {
      final oldChild = oldChildren[index];
      if (oldChild == null) {
        newChildren.add(null);
        continue;
      }
      final newChild = resolve(oldChild, childOptions[index]);
      if ((node is EquationRowNode || node is TransparentNode) &&
          oldChild is _NativeMathChoiceNode &&
          newChild is EquationRowNode) {
        newChildren.addAll(newChild.children);
      } else {
        newChildren.add(newChild);
      }
      changed = changed || !identical(newChild, oldChild);
    }
    return changed ? _updateMathChildren(node, newChildren) : node;
  }

  final root = resolve(ast.greenRoot, rootOptions);
  return SyntaxTree(
    greenRoot: root is EquationRowNode ? root : root.wrapWithEquationRow(),
  );
}

GreenNode _updateMathChildren(GreenNode node, List<GreenNode?> children) {
  // The package's MatrixNode.updateChildren slices rows from incorrect
  // indices and rejects absent cells. Rebuild the original rectangular body
  // explicitly, retaining null slots and every matrix layout option.
  if (node is MatrixNode) {
    final rows = children.cast<EquationRowNode?>();
    return node.copyWith(
      body: [
        for (var row = 0; row < node.rows; row++)
          List<EquationRowNode?>.of(
            rows.sublist(row * node.cols, (row + 1) * node.cols),
          ),
      ],
    );
  }
  // EquationArrayNode declares nullable generic children but its concrete
  // updateChildren override requires a non-null list.
  if (node is EquationArrayNode) {
    return node.copyWith(
      body: List<EquationRowNode>.of(children.cast<EquationRowNode>()),
    );
  }
  // The package's FracNode.updateChildren drops continued-fraction metadata.
  if (node is FracNode) {
    return FracNode(
      numerator: children[0]! as EquationRowNode,
      denominator: children[1]! as EquationRowNode,
      barSize: node.barSize,
      continued: node.continued,
    );
  }
  // Generic types are covariant: ParentableNode<EquationRowNode> also matches
  // ParentableNode<EquationRowNode?>. Try the non-null child contract first,
  // or FracNode/EquationArrayNode receive a nullable List and fail at runtime.
  if (node is ParentableNode<EquationRowNode>) {
    if (children.any((child) => child == null)) {
      return node.updateChildren(children.cast<EquationRowNode?>());
    }
    return node.updateChildren(
      List<EquationRowNode>.of(children.cast<EquationRowNode>()),
    );
  }
  if (node is ParentableNode<EquationRowNode?>) {
    // Some nullable-generic package nodes (such as MatrixNode) narrow their
    // concrete method parameter to non-null rows. A non-null list satisfies
    // both contracts whenever no optional slot is absent.
    if (children.every((child) => child != null)) {
      return node.updateChildren(
        List<EquationRowNode>.of(children.cast<EquationRowNode>()),
      );
    }
    return node.updateChildren(
      List<EquationRowNode?>.of(children.cast<EquationRowNode?>()),
    );
  }
  if (node is ParentableNode<GreenNode>) {
    return node.updateChildren(children.cast<GreenNode>());
  }
  return node.updateChildren(children);
}

MathOptions _mathOptionsFromContext(
  BuildContext context, {
  required MathStyle mathStyle,
  required TextStyle? textStyle,
  required double? textScaleFactor,
  required double? logicalPpi,
}) {
  var effectiveTextStyle = textStyle;
  if (effectiveTextStyle == null || effectiveTextStyle.inherit) {
    effectiveTextStyle = DefaultTextStyle.of(context).style.merge(textStyle);
  }
  if (MediaQuery.boldTextOf(context)) {
    effectiveTextStyle = effectiveTextStyle.merge(
      const TextStyle(fontWeight: FontWeight.bold),
    );
  }
  final fontSize = effectiveTextStyle.fontSize!;
  final scaledFontSize = textScaleFactor == null
      ? MediaQuery.textScalerOf(context).scale(fontSize)
      : fontSize * textScaleFactor;
  return MathOptions(
    style: mathStyle,
    fontSize: scaledFontSize,
    mathFontOptions:
        effectiveTextStyle.fontWeight != FontWeight.normal &&
            effectiveTextStyle.fontWeight != null
        ? FontOptions(fontWeight: effectiveTextStyle.fontWeight!)
        : null,
    logicalPpi: logicalPpi,
    color: effectiveTextStyle.color!,
  );
}

GreenNode _mathChoiceHandler(TexParser parser, FunctionContext context) {
  final branches = List<EquationRowNode>.generate(
    4,
    (_) =>
        parser.parseArgNode(mode: null, optional: false)!.wrapWithEquationRow(),
    growable: false,
  );
  return _NativeMathChoiceNode(branches);
}

GreenNode _smashHandler(TexParser parser, FunctionContext context) {
  final optional = parser.parseArgNode(mode: null, optional: true);
  var smashHeight = optional == null;
  var smashDepth = optional == null;

  if (optional != null) {
    smashHeight = false;
    smashDepth = false;
    final body = optional is EquationRowNode
        ? optional.children
        : <GreenNode>[optional];
    for (final node in body) {
      if (node is! SymbolNode) {
        smashHeight = false;
        smashDepth = false;
        break;
      }
      if (node.symbol == 't') {
        smashHeight = true;
      } else if (node.symbol == 'b') {
        smashDepth = true;
      } else {
        smashHeight = false;
        smashDepth = false;
        break;
      }
    }
  }

  final argument = parser.parseArgNode(mode: null, optional: false)!;
  return _NativeSmashNode(
    argument.wrapWithEquationRow(),
    smashHeight: smashHeight,
    smashDepth: smashDepth,
  );
}

GreenNode _gatherEnvironmentHandler(TexParser parser, EnvContext context) {
  final displayOnly =
      context.envName == 'gather' || context.envName == 'gather*';
  if (displayOnly && !parser.settings.displayMode) {
    throw ParseException(
      tr("{{0}} can be used only in display mode.", [context.envName]),
    );
  }

  final parsed = parseEqnArray(
    parser,
    addJot: true,
    concatRow: (cells) {
      if (cells.length != 1) {
        throw ParseException(
          tr("Too many columns in {0}: expected 1, got {1}", [
            context.envName,
            cells.length,
          ]),
        );
      }
      return EquationRowNode(
        children: [
          StyleNode(
            optionsDiff: const OptionsDiff(style: MathStyle.display),
            children: cells.single.children,
          ),
        ],
      );
    },
  );
  return _removeTrailingJot(parsed);
}

/// flutter_math_fork adds `jotSize` after every equation-array row, including
/// the final row. KaTeX applies `\jot` only between rows. Subtract the final
/// 3pt at measurement conversion time so any explicit trailing row gap remains
/// intact and the adjustment tracks the active math options.
EquationArrayNode _removeTrailingJot(EquationArrayNode node) {
  if (!node.addJot || node.body.isEmpty) return node;
  final spacings = List<Measurement>.of(node.rowSpacings);
  final lastRow = node.body.length - 1;
  spacings[lastRow] = _TrailingJotAdjustment(spacings[lastRow]);
  return node.copyWith(rowSpacings: spacings);
}

class _TrailingJotAdjustment extends Measurement {
  _TrailingJotAdjustment(this.base) : super(value: base.value, unit: base.unit);

  final Measurement base;

  @override
  double toLpUnder(MathOptions options) =>
      base.toLpUnder(options) - 3.0.pt.toLpUnder(options);
}

class _NativeMathChoiceNode extends ParentableNode<EquationRowNode> {
  _NativeMathChoiceNode(this.branches) : assert(branches.length == 4);

  final List<EquationRowNode> branches;

  @override
  List<EquationRowNode> get children => branches;

  @override
  int computeWidth() =>
      branches.fold<int>(1, (width, branch) => width + branch.capturedCursor);

  @override
  List<int> computeChildPositions() {
    var position = 0;
    return List<int>.generate(branches.length + 1, (index) {
      if (index == 0) return position;
      position += branches[index - 1].capturedCursor;
      return position;
    }, growable: false);
  }

  @override
  List<MathOptions> computeChildOptions(MathOptions options) =>
      List<MathOptions>.filled(branches.length, options, growable: false);

  @override
  BuildResult buildWidget(
    MathOptions options,
    List<BuildResult?> childBuildResults,
  ) {
    final branchIndex = options.style.size.clamp(0, 3);
    final selected = childBuildResults[branchIndex]!;
    return BuildResult(
      options: options,
      widget: selected.widget,
      italic: selected.italic,
      skew: selected.skew,
    );
  }

  @override
  bool shouldRebuildWidget(MathOptions oldOptions, MathOptions newOptions) =>
      oldOptions.style != newOptions.style;

  @override
  AtomType get leftType => _sharedBoundaryType(left: true) ?? AtomType.ord;

  @override
  AtomType get rightType => _sharedBoundaryType(left: false) ?? AtomType.ord;

  AtomType? _sharedBoundaryType({required bool left}) {
    final types = branches.map((branch) {
      final nodes = branch.flattenedChildList;
      final nonSpaces = nodes.where((node) => node is! SpaceNode).toList();
      if (nonSpaces.isEmpty) return AtomType.spacing;
      return left ? nonSpaces.first.leftType : nonSpaces.last.rightType;
    }).toSet();
    return types.length == 1 ? types.single : null;
  }

  @override
  _NativeMathChoiceNode updateChildren(List<EquationRowNode?> newChildren) {
    if (newChildren.length != 4 || newChildren.any((child) => child == null)) {
      throw ArgumentError(tr("mathchoice requires exactly four branches."));
    }
    return _NativeMathChoiceNode(newChildren.cast<EquationRowNode>());
  }

  @override
  Map<String, Object?> toJson() => super.toJson()
    ..addAll({'branches': branches.map((branch) => branch.toJson()).toList()});
}

class _NativeSmashNode extends ParentableNode<EquationRowNode> {
  _NativeSmashNode(
    this.body, {
    required this.smashHeight,
    required this.smashDepth,
  });

  final EquationRowNode body;
  final bool smashHeight;
  final bool smashDepth;

  @override
  List<EquationRowNode> get children => [body];

  @override
  int computeWidth() => body.editingWidth;

  @override
  List<int> computeChildPositions() => [0, body.capturedCursor];

  @override
  List<MathOptions> computeChildOptions(MathOptions options) => [options];

  @override
  BuildResult buildWidget(
    MathOptions options,
    List<BuildResult?> childBuildResults,
  ) {
    final child = childBuildResults.single!;
    return BuildResult(
      options: options,
      italic: child.italic,
      skew: child.skew,
      widget: ResetDimension(
        height: smashHeight ? 0 : null,
        depth: smashDepth ? 0 : null,
        child: child.widget,
      ),
    );
  }

  @override
  bool shouldRebuildWidget(MathOptions oldOptions, MathOptions newOptions) =>
      false;

  @override
  AtomType get leftType => AtomType.ord;

  @override
  AtomType get rightType => AtomType.ord;

  @override
  _NativeSmashNode updateChildren(List<EquationRowNode?> newChildren) {
    if (newChildren.length != 1 || newChildren.single == null) {
      throw ArgumentError(tr("smash requires exactly one body."));
    }
    return _NativeSmashNode(
      newChildren.single!,
      smashHeight: smashHeight,
      smashDepth: smashDepth,
    );
  }

  @override
  Map<String, Object?> toJson() => super.toJson()
    ..addAll({
      'body': body.toJson(),
      'smashHeight': smashHeight,
      'smashDepth': smashDepth,
    });
}
