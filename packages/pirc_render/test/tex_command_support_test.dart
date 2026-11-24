import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_math_fork/flutter_math.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_render/src/native_tex_adapter.dart';

class _TexCase {
  const _TexCase(
    this.id,
    this.source, {
    this.display = true,
    this.browserSupported = true,
    this.malformed = false,
  });
  final String id;
  final String source;
  final bool display;
  final bool browserSupported;
  final bool malformed;
}

// KaTeX reference: apps/web/node_modules/katex 0.16.47, rendered with the
// same options as apps/web/src/lib/markdown.ts (strict: ignore, maxExpand: 500,
// throwOnError: false, trust: false). The cline and multicolumn expressions
// produce KaTeX's red unsupported-command rendering, not a .katex-error span.
const _cases = <_TexCase>[
  _TexCase('mathchoice-inline', r'\mathchoice{D}{T}{S}{SS}', display: false),
  _TexCase(
    'mathchoice-in-script',
    r'x^{\mathchoice{a}{b}{c}{d}}',
    display: false,
  ),
  _TexCase('smash-default', r'\smash{\frac{x}{y}}'),
  _TexCase('smash-top', r'\smash[t]{\frac{x}{y}}'),
  _TexCase('smash-bottom', r'\smash[b]{\frac{x}{y}}'),
  _TexCase('gather', r'\begin{gather}a=b\\c=d\end{gather}'),
  _TexCase('gather-star', r'\begin{gather*}a=b\\c=d\end{gather*}'),
  _TexCase('gathered', r'\left\{\begin{gathered}a=b\\c=d\end{gathered}\right.'),
  _TexCase('Vmatrix', r'\begin{Vmatrix}a&b\\c&d\end{Vmatrix}'),
  _TexCase(
    'array-horizontal-rules',
    r'\begin{array}{|c:c|}\hline a&b\\\hdashline c&d\\\hline\end{array}',
  ),
  _TexCase(
    'array-cline',
    r'\begin{array}{cc}a&b\\\cline{1-1}c&d\end{array}',
    browserSupported: false,
  ),
  _TexCase(
    'array-multicolumn',
    r'\begin{array}{cc}\multicolumn{2}{c}{x}\\a&b\end{array}',
    browserSupported: false,
  ),
  _TexCase(
    'unknown-inline',
    r'x+\mystery+y',
    display: false,
    browserSupported: false,
  ),
  _TexCase(
    'unknown-script',
    r'x+\mystery^2+y',
    display: false,
    browserSupported: false,
  ),
  _TexCase(
    'unknown-before-group',
    r'x+\mystery{z}+y',
    display: false,
    browserSupported: false,
  ),
  _TexCase(
    'unknown-in-text',
    r'\text{before \mystery after}',
    display: false,
    browserSupported: false,
  ),
  _TexCase(
    'unknown-from-macro',
    r'\newcommand{\bad}{\mystery}x+\bad+y',
    display: false,
    browserSupported: false,
  ),
  _TexCase(
    'known-macro-after-unknown',
    r'\newcommand{\known}{\alpha}\mystery+\known',
    display: false,
    browserSupported: false,
  ),
  _TexCase('verb-is-not-unknown', r'\verb|x|+y', display: false),
  _TexCase(
    'unknown-in-frac',
    r'\frac{\mystery}{y}+z',
    display: false,
    browserSupported: false,
  ),
  _TexCase(
    'unknown-in-left-right',
    r'\left(\mystery\right)+x',
    display: false,
    browserSupported: false,
  ),
  _TexCase('unmatched-brace', r'x+{y', malformed: true),
  _TexCase(
    'unknown-environment',
    r'\begin{bogus}x\end{bogus}',
    malformed: true,
  ),
  _TexCase('missing-frac-argument', r'\frac{x}', malformed: true),
  _TexCase('stray-end', r'\end{matrix}', malformed: true),
];

String _textOfSpan(InlineSpan span) {
  if (span is! TextSpan) return '';
  return '${span.text ?? ''}${span.children?.map(_textOfSpan).join() ?? ''}';
}

String _textInColor(InlineSpan span, Color target, {TextStyle? inherited}) {
  if (span is! TextSpan) return '';
  final style = inherited?.merge(span.style) ?? span.style;
  final ownText = style?.color == target ? span.text ?? '' : '';
  return ownText +
      (span.children
              ?.map((child) => _textInColor(child, target, inherited: style))
              .join() ??
          '');
}

void main() {
  testWidgets('pinned KaTeX command support versus native parser', (
    tester,
  ) async {
    final parserErrors = <String, String>{};
    final parsedByAdapter = <String>{};
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(760, 1200);
    addTearDown(tester.view.reset);

    Widget buildCases(
      Map<String, String> errors, {
      bool nativeAdapter = false,
    }) => MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final item in _cases)
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: KeyedSubtree(
                    key: ValueKey('tex-${item.id}'),
                    child: nativeAdapter
                        ? NativeMathTex(
                            item.source,
                            mathStyle: item.display
                                ? MathStyle.display
                                : MathStyle.text,
                            textStyle: const TextStyle(
                              fontSize: 18,
                              color: Colors.black,
                            ),
                            settings: TexParserSettings(
                              displayMode: item.display,
                              throwOnError: false,
                              maxExpand: 500,
                              strict: Strict.ignore,
                            ),
                            onErrorFallback: (error) {
                              errors[item.id] = error.message;
                              return Text('NATIVE_TEX_ERROR_${item.id}');
                            },
                            onParsed: (context, math) {
                              parsedByAdapter.add(item.id);
                              return math;
                            },
                          )
                        : Math.tex(
                            item.source,
                            mathStyle: item.display
                                ? MathStyle.display
                                : MathStyle.text,
                            textStyle: const TextStyle(
                              fontSize: 18,
                              color: Colors.black,
                            ),
                            settings: TexParserSettings(
                              displayMode: item.display,
                              maxExpand: 500,
                              strict: Strict.ignore,
                            ),
                            onErrorFallback: (error) {
                              errors[item.id] = error.message;
                              return Text('NATIVE_TEX_ERROR_${item.id}');
                            },
                          ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );

    await tester.pumpWidget(buildCases(parserErrors));
    await tester.pumpAndSettle();
    final parserResults = <String, Map<String, dynamic>>{};
    for (final item in _cases) {
      final box = tester.getSize(find.byKey(ValueKey('tex-${item.id}')));
      parserResults[item.id] = {
        'accepted': parserErrors[item.id] == null,
        'error': parserErrors[item.id],
        'box': {'width': box.width, 'height': box.height},
      };
    }
    expect(tester.takeException(), isNull);

    // Exercise the candidate extension registry independently of the raw
    // flutter_math_fork parser result above.
    registerNativeTexExtensions();
    final adapterErrors = <String, String>{};
    await tester.pumpWidget(buildCases(adapterErrors, nativeAdapter: true));
    await tester.pumpAndSettle();

    final results = <Map<String, dynamic>>[];
    for (final item in _cases) {
      final box = tester.getSize(find.byKey(ValueKey('tex-${item.id}')));
      final parser = parserResults[item.id]!;
      results.add({
        'id': item.id,
        'source': item.source,
        'browserSupported': item.browserSupported,
        'browserPresentation': item.malformed
            ? 'KaTeX reports a whole-expression syntax error.'
            : item.browserSupported
            ? 'KaTeX renders the expression.'
            : 'KaTeX keeps the surrounding equation and renders the unsupported command in red.',
        'nativePresentation': adapterErrors[item.id] == null
            ? 'Native Math widget renders the parsed expression.'
            : 'NativeMathTex onErrorFallback replaces the entire formula with the test sentinel.',
        'presentationDifference':
            !item.malformed &&
                !item.browserSupported &&
                adapterErrors[item.id] != null
            ? 'The unsupported-command presentations differ; this is not parity.'
            : null,
        'nativeParserAccepted': parser['accepted'],
        'nativeParserError': parser['error'],
        'nativeParserBox': parser['box'],
        'nativeWithExtensionsAccepted': adapterErrors[item.id] == null,
        'nativeWithExtensionsError': adapterErrors[item.id],
        'nativeWithExtensionsBox': {'width': box.width, 'height': box.height},
        'nativeOnParsedCalled': parsedByAdapter.contains(item.id),
      });
    }

    final output = File('build/parity/tex-command-support-native.json')
      ..parent.createSync(recursive: true);
    output.writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert({
        'webRenderer': 'KaTeX 0.16.47, markdown.ts renderMath options',
        'nativeRenderer':
            'flutter_math_fork 0.7.4, NativeMarkdown parser settings',
        'extensions': 'registerNativeTexExtensions()',
        'cases': results,
      }),
    );

    for (final item in _cases) {
      expect(tester.takeException(), isNull, reason: item.id);
    }
    for (final id in [
      'mathchoice-inline',
      'mathchoice-in-script',
      'smash-default',
      'smash-top',
      'smash-bottom',
      'gather',
      'gather-star',
      'gathered',
      'Vmatrix',
      'array-horizontal-rules',
      'unknown-inline',
      'unknown-script',
      'unknown-before-group',
      'unknown-in-text',
      'unknown-from-macro',
      'known-macro-after-unknown',
      'verb-is-not-unknown',
      'unknown-in-frac',
      'unknown-in-left-right',
      'array-cline',
      'array-multicolumn',
    ]) {
      expect(
        adapterErrors[id],
        isNull,
        reason: '$id is supported by the adapter or existing parser',
      );
    }
    for (final item in _cases.where((item) => item.malformed)) {
      expect(
        adapterErrors[item.id],
        isNotNull,
        reason: '${item.id} is structural syntax and must still fail',
      );
      expect(
        parsedByAdapter,
        isNot(contains(item.id)),
        reason: 'onParsed must not wrap failed parses',
      );
    }
    for (final item in _cases.where((item) => !item.malformed)) {
      expect(
        parsedByAdapter,
        contains(item.id),
        reason: 'onParsed wraps successful parse ${item.id}',
      );
    }

    final rendered = tester
        .widgetList<RichText>(find.byType(RichText))
        .map((widget) => _textOfSpan(widget.text))
        .join();
    expect(rendered, contains(r'\mystery'));
    expect(rendered, contains('x'));
    expect(rendered, contains('y'));

    final inlineMathSpans = tester.widgetList<RichText>(
      find.descendant(
        of: find.byKey(const ValueKey('tex-unknown-inline')),
        matching: find.byType(RichText),
      ),
    );
    final inlineMathText = inlineMathSpans
        .map((widget) => _textOfSpan(widget.text))
        .join();
    final redUnsupportedText = inlineMathSpans
        .map((widget) => _textInColor(widget.text, const Color(0xffcc0000)))
        .join();
    expect(inlineMathText, contains(r'\mystery'));
    expect(inlineMathText, contains('x'));
    expect(inlineMathText, contains('y'));
    expect(redUnsupportedText, contains(r'\mystery'));
    expect(redUnsupportedText, isNot(contains('x')));
    expect(
      parserErrors['unknown-inline'],
      contains('Undefined control sequence'),
      reason: 'The unmodified parser remains strict when throwOnError is true.',
    );
  });
}
