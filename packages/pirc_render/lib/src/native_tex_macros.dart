import 'render_l10n.dart';
// ignore_for_file: implementation_imports

import 'package:flutter_math_fork/src/ast/nodes/space.dart';
import 'package:flutter_math_fork/src/ast/size.dart' show Measurement;
import 'package:flutter_math_fork/src/ast/syntax_tree.dart' show GreenNode;
import 'package:flutter_math_fork/src/ast/types.dart' show Mode;
import 'package:flutter_math_fork/src/parser/tex/functions.dart'
    show FunctionContext, FunctionSpec, functions;
import 'package:flutter_math_fork/src/parser/tex/macro_expander.dart'
    show MacroExpander;
import 'package:flutter_math_fork/src/parser/tex/macros.dart'
    show MacroDefinition, MacroExpansion;
import 'package:flutter_math_fork/src/parser/tex/parse_error.dart'
    show ParseException;
import 'package:flutter_math_fork/src/parser/tex/parser.dart' show TexParser;
import 'package:flutter_math_fork/src/parser/tex/token.dart' show Token;

/// Registers the TeX definition primitives implemented by this adapter.
///
/// flutter_math_fork does not expose a parser extension registry, so this uses
/// its parser's existing function table. Registration is idempotent.
void registerNativeTexMacros() {
  for (final command in _definitionCommands) {
    functions.putIfAbsent(
      command,
      () => FunctionSpec(
        numArgs: 0,
        allowedInText: true,
        handler: _handleDefinition,
      ),
    );
  }
  for (final command in _prefixCommands) {
    functions.putIfAbsent(
      command,
      () =>
          FunctionSpec(numArgs: 0, allowedInText: true, handler: _handlePrefix),
    );
  }
}

/// Zero-size, spacing-category marker emitted for a definition command.
///
/// Keeping an explicit marker lets callers identify parser assignments while
/// ensuring EquationRowNode's spacing pass skips it between math atoms.
class NativeTexAssignmentNode extends SpaceNode {
  NativeTexAssignmentNode(Mode mode)
    : super(
        height: Measurement.zero,
        width: Measurement.zero,
        depth: Measurement.zero,
        mode: mode,
      );
}

const _definitionCommands = <String>{r'\def', r'\gdef', r'\edef', r'\xdef'};

const _globalLongCommand = r'\\globallong';
const _prefixCommands = <String>{r'\global', r'\long', _globalLongCommand};

/// KaTeX's prefix rewriting table for the supported definition primitives.
///
/// KaTeX also maps \let and \futurelet here. Those assignment forms are
/// outside this helper's supported scope and are rejected as invalid prefixes.
const _globalPrefixMap = <String, String>{
  r'\global': r'\global',
  r'\long': _globalLongCommand,
  _globalLongCommand: _globalLongCommand,
  r'\def': r'\gdef',
  r'\gdef': r'\gdef',
  r'\edef': r'\xdef',
  r'\xdef': r'\xdef',
};

const _invalidControlSequenceTokens = <String>{
  r'\',
  '{',
  '}',
  r'$',
  '&',
  '#',
  '^',
  '_',
  'EOF',
};

GreenNode _handleDefinition(TexParser parser, FunctionContext context) {
  final command = context.funcName;
  final isGlobal = command == r'\gdef' || command == r'\xdef';
  final isExpanded = command == r'\edef' || command == r'\xdef';
  final expander = parser.macroExpander;

  final nameToken = expander.popToken();
  if (_invalidControlSequenceTokens.contains(nameToken.text)) {
    throw ParseException(tr("Expected a control sequence"), nameToken);
  }

  var parameterCount = 0;
  final delimiters = <List<String>>[<String>[]];
  Token? insertedOpeningBrace;

  // Read the parameter template as raw lexer tokens. Expanding these tokens
  // would change literal delimiters and parameter markers in the definition.
  while (expander.future().text != '{') {
    final token = expander.popToken();
    if (token.text == '#') {
      // KaTeX's TeX compatibility rule: a final # immediately before the
      // replacement group's opening brace inserts that brace at both ends.
      if (expander.future().text == '{') {
        insertedOpeningBrace = expander.future();
        delimiters[parameterCount].add('{');
        break;
      }

      final numberToken = expander.popToken();
      final number = _singleDigit(numberToken.text);
      if (number == null || number == 0) {
        throw ParseException(
          tr("Invalid argument number \"{0}\"", [numberToken.text]),
          numberToken,
        );
      }
      if (number != parameterCount + 1) {
        throw ParseException(
          tr("Argument number \"{0}\" out of order", [numberToken.text]),
          numberToken,
        );
      }
      parameterCount++;
      delimiters.add(<String>[]);
    } else if (token.text == 'EOF') {
      throw ParseException(tr("Expected a macro definition"), token);
    } else {
      delimiters[parameterCount].add(token.text);
    }
  }

  // consumeArgs reads a balanced raw group and returns stack-order tokens.
  final replacement = expander.consumeArgs(1).single;
  if (insertedOpeningBrace != null) {
    replacement.insert(0, _copyToken(insertedOpeningBrace));
  }

  final storedReplacement = isExpanded
      ? _expandReplacement(parser, replacement)
      : replacement.map(_copyToken).toList(growable: false);
  final storedDelimiters = delimiters
      .map((delimiter) => List<String>.unmodifiable(delimiter))
      .toList(growable: false);
  final definition = MacroDefinition((context) {
    if (context is! MacroExpander) {
      throw StateError(tr("Expected flutter_math_fork MacroExpander context."));
    }

    final args = _consumeDefinitionArguments(
      context,
      parameterCount,
      storedDelimiters,
    );
    final expansionTokens = _substituteParameters(
      storedReplacement,
      args,
      parameterCount,
    );
    // Arguments have already been read and substituted, including delimiters.
    return MacroExpansion(tokens: expansionTokens, numArgs: 0);
  });

  _setDefinition(expander, nameToken.text, definition, global: isGlobal);
  return NativeTexAssignmentNode(parser.mode);
}

void _setDefinition(
  MacroExpander expander,
  String name,
  MacroDefinition definition, {
  required bool global,
}) {
  final groups = expander.macros.undefStack;
  if (global || groups.isEmpty) {
    expander.macros.set(name, definition, global: global);
    return;
  }

  // flutter_math_fork.Namespace.set overwrites the group's undo value on every
  // local assignment. Keep the first value so repeated definitions restore the
  // binding that existed when the group began. containsKey matters because a
  // null undo entry represents a name that was undefined at group entry.
  final undo = groups.last;
  final alreadyRecorded = undo.containsKey(name);
  final originalUndoValue = undo[name];
  expander.macros.set(name, definition);
  if (alreadyRecorded) {
    undo[name] = originalUndoValue;
  }
}

GreenNode _handlePrefix(TexParser parser, FunctionContext context) {
  parser.consumeSpaces();
  final token = parser.fetch();
  final rewritten = _globalPrefixMap[token.text];
  if (rewritten == null) {
    throw ParseException(tr("Invalid token after macro prefix"), token);
  }

  if (context.funcName == r'\global' ||
      context.funcName == _globalLongCommand) {
    // Reuse the parser's cached lookahead token so the delegated primitive
    // consumes the rewritten name without re-lexing or expanding it again.
    token.text = rewritten;
  }

  final result = parser.parseFunction(null, null, null);
  if (result == null) {
    throw ParseException(tr("Invalid token after macro prefix"), token);
  }
  return result;
}

int? _singleDigit(String text) {
  if (text.length != 1) return null;
  final unit = text.codeUnitAt(0);
  if (unit < 0x30 || unit > 0x39) return null;
  return unit - 0x30;
}

List<List<Token>> _consumeDefinitionArguments(
  MacroExpander expander,
  int parameterCount,
  List<List<String>> delimiters,
) {
  final prefix = delimiters.first;
  for (final expected in prefix) {
    final actual = expander.popToken();
    if (actual.text != expected) {
      throw ParseException(
        tr("Use of the macro does not match its definition"),
        actual,
      );
    }
  }

  return List<List<Token>>.generate(
    parameterCount,
    (index) => _consumeMacroArgument(expander, delimiters[index + 1]),
    growable: false,
  );
}

List<Token> _consumeMacroArgument(
  MacroExpander expander,
  List<String> delimiter,
) {
  if (delimiter.isEmpty) {
    return expander.consumeArgs(1).single;
  }

  // KaTeX permits a trailing `#` in the parameter template. Its implicit
  // opening-brace delimiter is a special case because that brace is matched
  // before it opens the argument group.
  if (delimiter.contains('{')) {
    return _consumeBraceDelimitedArgument(expander, delimiter);
  }

  final tokens = <Token>[];
  final start = expander.future();
  final pending = <Token>[];
  final prefix = _delimiterPrefixLengths(delimiter);
  var depth = 0;
  var matched = 0;
  while (true) {
    final token = expander.popToken();
    if (token.text == 'EOF') {
      throw ParseException(
        tr("Unexpected end of input in a macro argument, expected '{0}'", [
          delimiter[matched],
        ]),
        token,
      );
    }

    if (token.text == '{') {
      tokens.addAll(pending);
      pending.clear();
      matched = 0;
      tokens.add(token);
      depth++;
    } else if (token.text == '}') {
      if (depth == 0) {
        throw ParseException('Extra }', token);
      }
      tokens.addAll(pending);
      pending.clear();
      matched = 0;
      tokens.add(token);
      depth--;
    } else if (depth > 0) {
      tokens.add(token);
    } else {
      pending.add(token);
      while (matched > 0 && token.text != delimiter[matched]) {
        final fallback = prefix[matched - 1];
        final flushCount = matched - fallback;
        tokens.addAll(pending.take(flushCount));
        pending.removeRange(0, flushCount);
        matched = fallback;
      }
      if (token.text == delimiter[matched]) {
        matched++;
        if (matched == delimiter.length) {
          pending.removeRange(
            pending.length - delimiter.length,
            pending.length,
          );
          break;
        }
      } else {
        tokens.addAll(pending);
        pending.clear();
      }
    }
  }

  // A single outer brace group is syntax for the argument and is removed.
  if (start.text == '{' &&
      tokens.isNotEmpty &&
      tokens.first.text == '{' &&
      tokens.last.text == '}') {
    tokens.removeLast();
    tokens.removeAt(0);
  }
  return tokens.reversed.map(_copyToken).toList(growable: false);
}

List<Token> _consumeBraceDelimitedArgument(
  MacroExpander expander,
  List<String> delimiter,
) {
  final tokens = <Token>[];
  final start = expander.future();
  var depth = 0;
  var matched = 0;
  while (true) {
    final token = expander.popToken();
    tokens.add(token);

    if (token.text == '{') {
      depth++;
    } else if (token.text == '}') {
      depth--;
      if (depth < 0) {
        throw ParseException('Extra }', token);
      }
    } else if (token.text == 'EOF') {
      throw ParseException(
        tr("Unexpected end of input in a macro argument, expected '{0}'", [
          delimiter[matched],
        ]),
        token,
      );
    }

    if ((depth == 0 || (depth == 1 && delimiter[matched] == '{')) &&
        token.text == delimiter[matched]) {
      matched++;
      if (matched == delimiter.length) {
        tokens.removeRange(tokens.length - matched, tokens.length);
        break;
      }
    } else {
      matched = 0;
    }
  }

  if (start.text == '{' &&
      tokens.length >= 2 &&
      tokens.first.text == '{' &&
      tokens.last.text == '}') {
    tokens.removeLast();
    tokens.removeAt(0);
  }
  return tokens.reversed.map(_copyToken).toList(growable: false);
}

List<int> _delimiterPrefixLengths(List<String> delimiter) {
  final prefix = List<int>.filled(delimiter.length, 0);
  var matched = 0;
  for (var index = 1; index < delimiter.length; index++) {
    while (matched > 0 && delimiter[index] != delimiter[matched]) {
      matched = prefix[matched - 1];
    }
    if (delimiter[index] == delimiter[matched]) matched++;
    prefix[index] = matched;
  }
  return prefix;
}

List<Token> _substituteParameters(
  List<Token> replacement,
  List<List<Token>> args,
  int parameterCount,
) {
  final tokens = replacement.map(_copyToken).toList();
  if (parameterCount == 0) return tokens;

  var index = tokens.length - 1;
  while (index >= 0) {
    if (tokens[index].text != '#') {
      index--;
      continue;
    }
    if (index == 0) {
      throw ParseException(
        tr("Incomplete placeholder at end of macro body"),
        tokens[index],
      );
    }

    final placeholderIndex = index - 1;
    final placeholder = tokens[placeholderIndex];
    if (placeholder.text == '#') {
      // ## is one literal parameter marker.
      tokens.removeAt(index);
      index = placeholderIndex - 1;
      continue;
    }

    final argumentNumber = _singleDigit(placeholder.text);
    if (argumentNumber == null ||
        argumentNumber < 1 ||
        argumentNumber > args.length) {
      throw ParseException(tr("Not a valid argument number"), placeholder);
    }
    tokens.replaceRange(
      placeholderIndex,
      index + 1,
      args[argumentNumber - 1].map(_copyToken),
    );
    index = placeholderIndex - 1;
  }
  return tokens;
}

List<Token> _expandReplacement(TexParser parser, List<Token> replacement) {
  final source = parser.macroExpander;
  final expander = MacroExpander('', parser.settings, parser.mode);
  expander.macros.current
    ..clear()
    ..addAll(source.macros.current);
  expander.expansionCount = source.expansionCount;

  final stop = Token('EOF')..noexpand = true;
  expander.pushToken(stop);
  expander.pushTokens(replacement.map(_copyToken).toList());
  final output = <Token>[];

  try {
    while (true) {
      final unexpanded = expander.expandOnce();
      if (unexpanded == null) continue;
      if (identical(unexpanded, stop)) {
        expander.stack.removeLast();
        break;
      }

      final token = expander.stack.removeLast();
      final wasNoexpanded = token.noexpand || token.treatAsRelax;
      if (token.treatAsRelax) {
        // TeX's \noexpand protects a token during definition-time expansion;
        // it is allowed to expand normally when the resulting macro is used.
        token.noexpand = false;
        token.treatAsRelax = false;
      }
      if (!wasNoexpanded &&
          token.text.startsWith('\\') &&
          !expander.isDefined(token.text)) {
        throw ParseException(
          tr("Undefined control sequence: {0}", [token.text]),
          token,
        );
      }
      output.add(token);
    }
  } finally {
    // Eager expansion is part of the containing expression's expansion budget.
    source.expansionCount = expander.expansionCount;
  }

  return output.reversed.map(_copyToken).toList(growable: false);
}

Token _copyToken(Token token) => Token(token.text, token.loc)
  ..noexpand = token.noexpand
  ..treatAsRelax = token.treatAsRelax;
