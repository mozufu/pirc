import 'package:flutter_math_fork/flutter_math.dart';
import 'package:flutter_math_fork/src/ast/nodes/symbol.dart';
import 'package:flutter_math_fork/src/ast/syntax_tree.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_render/src/native_tex_adapter.dart';
// ignore_for_file: implementation_imports

String text(GreenNode node) => node is SymbolNode
    ? node.symbol
    : node.children.whereType<GreenNode>().map(text).join();
NativeTexParseResult parse(String source, {bool display = true}) =>
    parseNativeTex(
      source,
      settings: TexParserSettings(
        displayMode: display,
        throwOnError: false,
        maxExpand: 500,
        strict: Strict.ignore,
      ),
    );

void main() {
  test(
    'standalone tags retain parentheses, star, source ordering and macro scope',
    () {
      for (final (source, label) in [
        (r'x+y\tag{A}', '(A)'),
        (r'x+y\tag*{A}', 'A'),
        (r'\tag{T}x+y', '(T)'),
        (r'\newcommand{\pircEqTag}{\tag{M}}\pircEqTag x+y', '(M)'),
        (r'\begin{array}{cc}a&b\\c&d\end{array}\tag{AR}', '(AR)'),
        (r'\begin{gathered}a=b\\c=d\end{gathered}\tag{G}', '(G)'),
      ]) {
        final result = parse(source);
        expect(result.tags, hasLength(1), reason: source);
        expect(text(result.tags.single.content!), label, reason: source);
        expect(result.tags.single.anchor, isNull, reason: source);
        expect(result.automaticNumberCount, 0);
        expect(text(result.ast.greenRoot), isNot(contains(r'\gdef')));
      }
      expect(parse(r'\pircEqTag x+y').tags, isEmpty);
    },
  );

  test('inline, duplicate and nested tags remain structural errors', () {
    expect(
      () => parse(r'x+y\tag{I}', display: false),
      throwsA(isA<ParseException>()),
    );
    for (final source in [r'x+y\tag{A}\tag{B}', r'x+y\tag{\tag{B}}']) {
      expect(
        () => parse(source),
        throwsA(isA<ParseException>()),
        reason: source,
      );
    }
  });

  test(
    'AMS rows distinguish manual, automatic, suppressed and starred tags',
    () {
      final gather = parse(
        r'\begin{gather}a=b\tag{M}\\c=d\nonumber\\e=f\end{gather}',
      );
      expect(gather.tags, hasLength(2));
      expect(gather.tags.map((t) => t.automatic), [false, true]);
      expect(text(gather.tags.first.content!), '(M)');
      expect(gather.tags.every((t) => t.anchor != null), isTrue);
      expect(gather.automaticNumberCount, 1);
      expect(parse(r'\begin{gather*}a=b\\c=d\end{gather*}').tags, isEmpty);
      expect(
        parse(
          r'\begin{align}a&=b\\c&=d\notag\\e&=f\end{align}',
        ).automaticNumberCount,
        2,
      );
      expect(parse(r'\begin{align*}a&=b\\c&=d\end{align*}').tags, isEmpty);
      expect(
        parse(r'\begin{equation}a=b\end{equation}').automaticNumberCount,
        1,
      );
      expect(parse(r'\begin{equation*}a=b\end{equation*}').tags, isEmpty);
      final multiple = parse(
        r'\begin{gather}a=b\tag{A}\\c=d\tag*{B}\end{gather}',
      );
      expect(multiple.tags.map((tag) => text(tag.content!)), ['(A)', 'B']);
      expect(multiple.automaticNumberCount, 0);
      final manual = parse(r'\begin{equation}a=b\tag{E}\notag\end{equation}');
      expect(manual.automaticNumberCount, 0);
      expect(text(manual.tags.single.content!), '(E)');
    },
  );

  test('AMS context and row grammar errors do not create partial tags', () {
    for (final source in [
      r'\begin{gather}a=b\end{gather}',
      r'\begin{equation*}a=b\end{equation*}',
      r'\begin{align}a&=b\end{align}',
    ]) {
      expect(
        () => parse(source, display: false),
        throwsA(isA<ParseException>()),
      );
    }
    expect(
      () => parse(r'\begin{gather}a&b\end{gather}'),
      throwsA(isA<ParseException>()),
    );
    expect(
      () => parse(r'\begin{equation}a&b\end{equation}'),
      throwsA(isA<ParseException>()),
    );
  });
}
