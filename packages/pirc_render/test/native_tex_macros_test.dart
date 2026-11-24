import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_math_fork/flutter_math.dart'
    show Math, MathStyle, Strict, TexParserSettings;
import 'package:flutter_math_fork/src/ast/syntax_tree.dart'
    show GreenNode, SyntaxTree;
import 'package:flutter_math_fork/src/ast/types.dart' show Mode;
import 'package:flutter_math_fork/src/parser/tex/macro_expander.dart'
    show MacroExpander;
import 'package:flutter_math_fork/src/parser/tex/parse_error.dart'
    show ParseException;
import 'package:flutter_math_fork/src/parser/tex/parser.dart' show TexParser;
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_render/src/native_tex_macros.dart';

void main() {
  setUpAll(registerNativeTexMacros);

  group('native TeX definition primitives', () {
    test('substitutes ordered parameters into the canonical AST', () {
      expect(_canonical(r'\def\double#1{#1+#1}\double{x}'), _canonical('x+x'));
    });

    test(
      'matches a literal prefix, delimited arguments, and nested groups',
      () {
        expect(
          _canonical(r'\def\take pre#1;{#1}\take pre{x};'),
          _canonical('x'),
        );
        expect(
          _canonical(r'\def\swap#1,#2;{#2+#1}\swap{a,b},{c};'),
          _canonical('c+a,b'),
        );
        expect(
          _canonical(r'\def\swap#1,#2;{#2+#1}\swap a,{b,c};'),
          _canonical('b,c+a'),
        );
        expect(_canonical(r'\def\take#1,{#1}\take {a,b},'), _canonical('a,b'));
        expect(_canonical(r'\def\take#1aba{x}\take ababa'), _canonical('xba'));
        expect(
          () => _parse(r'\def\take#1ab{#1}\take xac'),
          throwsA(isA<ParseException>()),
        );
      },
    );

    test('def expands at use time while edef snapshots its replacement', () {
      const source =
          r'\def\alias{x}\def\lazy{\alias}\edef\eager{\alias}'
          r'\def\alias{y}\lazy+\eager';
      expect(_canonical(source), _canonical('y+x'));
    });

    test('gdef, xdef, and global prefixes survive enclosing groups', () {
      expect(
        _canonical(r'{\gdef\shared{a}\shared}+\shared'),
        _canonical('a+a'),
      );
      expect(
        _canonical(r'{\xdef\shared{a}\shared}+\shared'),
        _canonical('a+a'),
      );
      expect(
        _canonical(r'{\global\def\shared{a}\shared}+\shared'),
        _canonical('a+a'),
      );
      expect(
        _canonical(r'{\global\long\def\shared{a}\shared}+\shared'),
        _canonical('a+a'),
      );
      expect(_canonical(r'{\long\def\local{a}\local}+b'), _canonical('a+b'));
    });

    test('edef and xdef expand macros before storing their replacement', () {
      expect(
        _canonical(r'\def\old{x}{\xdef\saved{\old}}\def\old{y}\saved'),
        _canonical('x'),
      );
      expect(
        _canonical(
          r'\def\old{x}{\global\edef\saved{\old}}'
          r'\def\old{y}\saved',
        ),
        _canonical('x'),
      );
    });

    test('escaped parameter marker becomes one literal token', () {
      final definitionParser = TexParser(r'\gdef\suffix#1{#1##}', _settings);
      definitionParser.parse();
      final expander = MacroExpander('{x}', _settings, Mode.math)
        ..macros = definitionParser.macroExpander.macros;
      final definition = expander.macros.get(r'\suffix');
      expect(definition, isNotNull);
      final result = definition!.expand(expander);
      expect(result.tokens.reversed.map((token) => token.text), ['x', '#']);

      // flutter_math_fork's parser cannot render a literal # symbol, though
      // the definition expansion itself correctly produces that one token.
      expect(
        () => _parse(r'\def\suffix#1{#1##}\text{\suffix{x}}'),
        throwsA(
          isA<ParseException>().having(
            (error) => error.token?.text,
            'offending token',
            '#',
          ),
        ),
      );
    });

    test('local definition is scoped to its group', () {
      expect(
        () => _parse(r'{\def\local{a}\local}+\local'),
        throwsA(isA<ParseException>()),
      );
    });

    test('repeated local definitions restore the group-entry binding', () {
      expect(
        _canonical(r'\def\value{x}{\def\value{y}\def\value{z}\value}+\value'),
        _canonical('z+x'),
      );
      expect(
        () => _parse(r'{\def\local{x}\def\local{y}\local}+\local'),
        throwsA(isA<ParseException>()),
      );
      expect(
        _canonical(
          r'\def\value{x}{\def\value{y}\gdef\value{z}'
          r'\def\value{q}\value}+\value',
        ),
        _canonical('q+z'),
      );
    });

    test('rejects malformed names, parameter templates, and prefixes', () {
      for (final source in [
        r'\def{f}{x}',
        r'\def\f#2{x}',
        r'\def\f#0{x}',
        r'\def\f#1#3{x}',
        r'\def\f#1',
        r'\global a',
      ]) {
        expect(
          () => _parse(source),
          throwsA(isA<ParseException>()),
          reason: source,
        );
      }
    });

    test(
      'edef rejects unknown controls and recursive macros hit maxExpand',
      () {
        expect(
          () => _parse(r'\edef\saved{\unknownCommand}'),
          throwsA(isA<ParseException>()),
        );
        const limited = TexParserSettings(maxExpand: 12);
        expect(
          () => _parse(r'\def\loop{\loop}\loop', settings: limited),
          throwsA(
            isA<ParseException>().having(
              (error) => error.message,
              'message',
              contains('Too many expansions'),
            ),
          ),
        );
        expect(
          () =>
              _parse(r'\def\loop{\loop}\edef\saved{\loop}', settings: limited),
          throwsA(
            isA<ParseException>().having(
              (error) => error.message,
              'message',
              contains('Too many expansions'),
            ),
          ),
        );
      },
    );

    testWidgets('assignment marker preserves adjacent binary spacing', (
      tester,
    ) async {
      final settings = _settings;
      final expected = TexParser('a+b', settings).parse();
      final actual = TexParser(
        r'\def\rightAtom{b}a+\rightAtom',
        settings,
      ).parse();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Math(
                  key: const ValueKey('canonical'),
                  ast: SyntaxTree(greenRoot: expected),
                  mathStyle: MathStyle.text,
                ),
                Math(
                  key: const ValueKey('with-assignment'),
                  ast: SyntaxTree(greenRoot: actual),
                  mathStyle: MathStyle.text,
                ),
              ],
            ),
          ),
        ),
      );
      expect(
        tester.getSize(find.byKey(const ValueKey('with-assignment'))).width,
        closeTo(
          tester.getSize(find.byKey(const ValueKey('canonical'))).width,
          0.01,
        ),
      );
    });
  });
}

const _settings = TexParserSettings(
  displayMode: true,
  throwOnError: true,
  maxExpand: 500,
  strict: Strict.ignore,
);

GreenNode _parse(String source, {TexParserSettings settings = _settings}) =>
    TexParser(source, settings).parse();

String _canonical(String source) => jsonEncode(
  _withoutAssignmentMarkers(_parse(source).toJson(), isRoot: true),
);

Object? _withoutAssignmentMarkers(Object? value, {bool isRoot = false}) {
  if (value is Map) {
    if (value['type'] == 'NativeTexAssignmentNode') return null;
    final result = value.map<String, Object?>((key, child) {
      final cleaned = _withoutAssignmentMarkers(child);
      if (key == 'children' && cleaned is List) {
        return MapEntry(
          key.toString(),
          cleaned.where((entry) => entry != null).toList(growable: false),
        );
      }
      return MapEntry(key.toString(), cleaned);
    });
    if (value['type'] == 'EquationRowNode') {
      final children = result['children'];
      if (children is List && children.isEmpty && !isRoot) return null;
      if (children is List && children.length == 1) {
        return children.single;
      }
    }
    return result;
  }
  if (value is Iterable) {
    return value
        .map((child) => _withoutAssignmentMarkers(child))
        .where((child) => child != null)
        .toList(growable: false);
  }
  return value;
}
