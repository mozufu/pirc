import 'package:flutter_test/flutter_test.dart';
import 'package:html/parser.dart' as html;
import 'package:pirc_render/src/html_document_styles.dart';

void main() {
  test(
    'flex expands keyword, numeric, and basis forms and resets longhands',
    () {
      final document = html.parse('''
      <div id="none"></div>
      <div id="auto"></div>
      <div id="initial"></div>
      <div id="single"></div>
      <div id="zero"></div>
      <div id="two-numbers"></div>
      <div id="basis"></div>
      <div id="number-basis"></div>
      <div id="basis-number"></div>
      <div id="three-values"></div>
      <div id="unitless-zero-basis"></div>
      <div id="reordered-three"></div>
      <div id="flow-wrap"></div>
      <div id="flow-direction"></div>
      <div id="flow-both"></div>
      <div id="flow-initial"></div>
    ''');
      final result = NativeDocumentStyleEngine(
        stylesheets: [
          NativeDocumentStylesheet('''
          #none { flex-grow: 9; flex-shrink: 8; flex-basis: 40px; flex: none; }
          #auto { flex: auto; }
          #initial { flex: initial; }
          #single { flex: 2; }
          #zero { flex: 0; }
          #two-numbers { flex: 2 3; }
          #basis { flex: 20px; }
          #number-basis { flex: 2 20px; }
          #basis-number { flex: 20px 2; }
          #three-values { flex: 2 3 20%; }
          #unitless-zero-basis { flex: 1 1 0; }
          #reordered-three { flex: 20px 2 3; }
          #flow-wrap { flex-direction: column; flex-wrap: wrap-reverse; flex-flow: wrap; }
          #flow-direction { flex-flow: column-reverse; }
          #flow-both { flex-flow: wrap-reverse column; }
          #flow-initial { flex-flow: initial; }
        ''', baseUrl: 'https://example.test/flex.css'),
        ],
        viewportWidth: 390,
        dark: false,
      ).apply(document);

      Map<String, String> styleFor(String id) =>
          result.stylesByElement[document.querySelector('#$id')]!;

      expect(styleFor('none')['flex-grow'], '0');
      expect(styleFor('none')['flex-shrink'], '0');
      expect(styleFor('none')['flex-basis'], 'auto');
      expect(styleFor('auto')['flex-grow'], '1');
      expect(styleFor('auto')['flex-shrink'], '1');
      expect(styleFor('auto')['flex-basis'], 'auto');
      expect(styleFor('initial')['flex-grow'], '0');
      expect(styleFor('initial')['flex-shrink'], '1');
      expect(styleFor('initial')['flex-basis'], 'auto');
      expect(styleFor('single')['flex-grow'], '2');
      expect(styleFor('single')['flex-shrink'], '1');
      expect(styleFor('single')['flex-basis'], '0%');
      expect(styleFor('zero')['flex-grow'], '0');
      expect(styleFor('zero')['flex-shrink'], '1');
      expect(styleFor('zero')['flex-basis'], '0%');
      expect(styleFor('two-numbers')['flex-grow'], '2');
      expect(styleFor('two-numbers')['flex-shrink'], '3');
      expect(styleFor('two-numbers')['flex-basis'], '0%');
      expect(styleFor('basis')['flex-grow'], '1');
      expect(styleFor('basis')['flex-shrink'], '1');
      expect(styleFor('basis')['flex-basis'], '20px');
      expect(styleFor('number-basis')['flex-grow'], '2');
      expect(styleFor('number-basis')['flex-shrink'], '1');
      expect(styleFor('number-basis')['flex-basis'], '20px');
      expect(styleFor('basis-number')['flex-grow'], '2');
      expect(styleFor('basis-number')['flex-shrink'], '1');
      expect(styleFor('basis-number')['flex-basis'], '20px');
      expect(styleFor('unitless-zero-basis')['flex-grow'], '1');
      expect(styleFor('unitless-zero-basis')['flex-shrink'], '1');
      expect(styleFor('unitless-zero-basis')['flex-basis'], '0');
      expect(styleFor('three-values')['flex-grow'], '2');
      expect(styleFor('three-values')['flex-shrink'], '3');
      expect(styleFor('three-values')['flex-basis'], '20%');
      expect(styleFor('reordered-three')['flex-grow'], '2');
      expect(styleFor('reordered-three')['flex-shrink'], '3');
      expect(styleFor('reordered-three')['flex-basis'], '20px');
      expect(styleFor('flow-wrap')['flex-direction'], 'row');
      expect(styleFor('flow-wrap')['flex-wrap'], 'wrap');
      expect(styleFor('flow-direction')['flex-direction'], 'column-reverse');
      expect(styleFor('flow-direction')['flex-wrap'], 'nowrap');
      expect(styleFor('flow-both')['flex-direction'], 'column');
      expect(styleFor('flow-both')['flex-wrap'], 'wrap-reverse');
      expect(styleFor('flow-initial')['flex-direction'], 'row');
      expect(styleFor('flow-initial')['flex-wrap'], 'nowrap');
      expect(result.diagnostics, isEmpty);
    },
  );

  test('expanded flex longhands retain cascade order and importance', () {
    final document = html.parse('''
      <div id="order"></div>
      <div id="reverse-order"></div>
      <div id="priority"></div>
      <div id="flow-priority"></div>
      <div id="inline" style="flex-grow: 9"></div>
    ''');
    final result = NativeDocumentStyleEngine(
      stylesheets: [
        NativeDocumentStylesheet('''
          #order { flex: 2; flex-grow: 8; }
          #reverse-order { flex-grow: 8; flex: 3; }
          #priority {
            flex: 2 3 20px !important;
            flex-grow: 8;
            flex-shrink: 7 !important;
            flex-basis: 9px;
          }
          #flow-priority {
            flex-flow: column wrap !important;
            flex-direction: row;
            flex-wrap: nowrap !important;
          }
          #inline { flex: 2 3 20px; }
        ''', baseUrl: 'https://example.test/cascade.css'),
      ],
      viewportWidth: 390,
      dark: false,
    ).apply(document);

    Map<String, String> styleFor(String id) =>
        result.stylesByElement[document.querySelector('#$id')]!;

    expect(styleFor('order')['flex-grow'], '8');
    expect(styleFor('order')['flex-shrink'], '1');
    expect(styleFor('order')['flex-basis'], '0%');
    expect(styleFor('reverse-order')['flex-grow'], '3');
    expect(styleFor('reverse-order')['flex-shrink'], '1');
    expect(styleFor('reverse-order')['flex-basis'], '0%');
    expect(styleFor('priority')['flex-grow'], '2');
    expect(styleFor('priority')['flex-shrink'], '7');
    expect(styleFor('priority')['flex-basis'], '20px');
    expect(styleFor('flow-priority')['flex-direction'], 'column');
    expect(styleFor('flow-priority')['flex-wrap'], 'nowrap');
    expect(styleFor('inline')['flex-grow'], '9');
    expect(styleFor('inline')['flex-shrink'], '3');
    expect(styleFor('inline')['flex-basis'], '20px');
    expect(result.diagnostics, isEmpty);
  });

  test('malformed and negative flex shorthands do not partially apply', () {
    final document = html.parse('''
      <div id="negative-grow"></div>
      <div id="negative-shrink"></div>
      <div id="negative-basis"></div>
      <div id="too-many"></div>
      <div id="bad-basis"></div>
      <div id="duplicate-basis"></div>
      <div id="bad-flow"></div>
      <div id="duplicate-flow"></div>
      <div id="invalid-longhand"></div>
      <div id="unsupported-wide"></div>
    ''');
    final result = NativeDocumentStyleEngine(
      stylesheets: [
        NativeDocumentStylesheet('''
          #negative-grow { flex: 4 5 6px; flex: -1; }
          #negative-shrink { flex: 4 5 6px; flex: 1 -2; }
          #negative-basis { flex: 4 5 6px; flex: 1 2 -3px; }
          #too-many { flex: 4 5 6px; flex: 1 2 3 4; }
          #bad-basis { flex: 4 5 6px; flex: 1 2 10s; }
          #duplicate-basis { flex: 4 5 6px; flex: 1 auto 20px; }
          #bad-flow { flex-flow: column wrap; flex-flow: row column; }
          #duplicate-flow { flex-flow: column wrap; flex-flow: wrap nowrap; }
          #invalid-longhand { flex: 2; flex-grow: -1; }
          #unsupported-wide { flex: 3; flex: inherit; }
        ''', baseUrl: 'https://example.test/invalid.css'),
      ],
      viewportWidth: 390,
      dark: false,
    ).apply(document);

    Map<String, String> styleFor(String id) =>
        result.stylesByElement[document.querySelector('#$id')]!;

    for (final id in [
      'negative-grow',
      'negative-shrink',
      'negative-basis',
      'too-many',
      'bad-basis',
      'duplicate-basis',
    ]) {
      expect(styleFor(id)['flex-grow'], '4', reason: id);
      expect(styleFor(id)['flex-shrink'], '5', reason: id);
      expect(styleFor(id)['flex-basis'], '6px', reason: id);
    }
    for (final id in ['bad-flow', 'duplicate-flow']) {
      expect(styleFor(id)['flex-direction'], 'column', reason: id);
      expect(styleFor(id)['flex-wrap'], 'wrap', reason: id);
    }
    expect(styleFor('invalid-longhand')['flex-grow'], '2');
    expect(styleFor('invalid-longhand')['flex-shrink'], '1');
    expect(styleFor('invalid-longhand')['flex-basis'], '0%');
    expect(styleFor('unsupported-wide')['flex-grow'], '3');
    expect(styleFor('unsupported-wide')['flex-shrink'], '1');
    expect(styleFor('unsupported-wide')['flex-basis'], '0%');
    expect(
      result.diagnostics.where(
        (diagnostic) =>
            diagnostic.property == 'flex' &&
            diagnostic.code == 'unsupported-shorthand',
      ),
      hasLength(7),
    );
    expect(
      result.diagnostics.where(
        (diagnostic) => diagnostic.code == 'invalid-flex-value',
      ),
      hasLength(1),
    );
  });

  test(
    'var values and fallbacks are expanded after custom property cascade',
    () {
      final document = html.parse('''
      <div id="components"></div>
      <div id="whole"></div>
      <div id="fallback"></div>
      <div id="variable-priority"></div>
      <div id="flow"></div>
    ''');
      final result = NativeDocumentStyleEngine(
        stylesheets: [
          NativeDocumentStylesheet('''
          #components {
            --grow: 2;
            --basis: 25%;
            flex: var(--grow) 3 var(--basis);
          }
          #whole { --complete-flex: 4 2 content; flex: var(--complete-flex); }
          #fallback { flex: var(--missing, 1 2 12px); }
          #variable-priority {
            --grow: 5;
            flex: var(--grow) 2 10px !important;
            flex-grow: 1;
          }
          #flow {
            --direction: column-reverse;
            --wrap: wrap-reverse;
            flex-flow: var(--wrap) var(--direction);
          }
        ''', baseUrl: 'https://example.test/variables.css'),
        ],
        viewportWidth: 390,
        dark: false,
      ).apply(document);

      Map<String, String> styleFor(String id) =>
          result.stylesByElement[document.querySelector('#$id')]!;

      expect(styleFor('components')['flex-grow'], '2');
      expect(styleFor('components')['flex-shrink'], '3');
      expect(styleFor('components')['flex-basis'], '25%');
      expect(styleFor('whole')['flex-grow'], '4');
      expect(styleFor('whole')['flex-shrink'], '2');
      expect(styleFor('whole')['flex-basis'], 'content');
      expect(styleFor('fallback')['flex-grow'], '1');
      expect(styleFor('fallback')['flex-shrink'], '2');
      expect(styleFor('fallback')['flex-basis'], '12px');
      expect(styleFor('variable-priority')['flex-grow'], '5');
      expect(styleFor('variable-priority')['flex-shrink'], '2');
      expect(styleFor('variable-priority')['flex-basis'], '10px');
      expect(styleFor('flow')['flex-direction'], 'column-reverse');
      expect(styleFor('flow')['flex-wrap'], 'wrap-reverse');
      expect(result.diagnostics, isEmpty);
    },
  );

  test('gap expands normal, nonnegative lengths, and percentages', () {
    final document = html.parse('''
      <div id="one"></div>
      <div id="two"></div>
      <div id="normal"></div>
      <div id="percentage"></div>
      <div id="zero"></div>
      <div id="negative"></div>
      <div id="too-many"></div>
      <div id="negative-longhand"></div>
      <div id="unsupported-wide"></div>
    ''');
    final result = NativeDocumentStyleEngine(
      stylesheets: [
        NativeDocumentStylesheet('''
          #one { row-gap: 8px; column-gap: 12px; gap: 4px; }
          #two { gap: 4px 9px; }
          #normal { gap: 10px; gap: normal; }
          #percentage { gap: 10% 5%; }
          #zero { gap: 0; }
          #negative { gap: 2px 3px; gap: -1px 4px; }
          #too-many { gap: 2px 3px; gap: 1px 2px 3px; }
          #negative-longhand { gap: 4px; row-gap: -2px; }
          #unsupported-wide { gap: 5px; gap: inherit; }
        ''', baseUrl: 'https://example.test/gap.css'),
      ],
      viewportWidth: 390,
      dark: false,
    ).apply(document);

    Map<String, String> styleFor(String id) =>
        result.stylesByElement[document.querySelector('#$id')]!;

    expect(styleFor('one')['row-gap'], '4px');
    expect(styleFor('one')['column-gap'], '4px');
    expect(styleFor('two')['row-gap'], '4px');
    expect(styleFor('two')['column-gap'], '9px');
    expect(styleFor('normal')['row-gap'], 'normal');
    expect(styleFor('normal')['column-gap'], 'normal');
    expect(styleFor('percentage')['row-gap'], '10%');
    expect(styleFor('percentage')['column-gap'], '5%');
    expect(styleFor('zero')['row-gap'], '0');
    expect(styleFor('zero')['column-gap'], '0');
    expect(styleFor('negative')['row-gap'], '2px');
    expect(styleFor('negative')['column-gap'], '3px');
    expect(styleFor('too-many')['row-gap'], '2px');
    expect(styleFor('too-many')['column-gap'], '3px');
    expect(styleFor('negative-longhand')['row-gap'], '4px');
    expect(styleFor('negative-longhand')['column-gap'], '4px');
    expect(styleFor('unsupported-wide')['row-gap'], '5px');
    expect(styleFor('unsupported-wide')['column-gap'], '5px');
    expect(
      result.diagnostics.where(
        (diagnostic) =>
            diagnostic.property == 'gap' &&
            diagnostic.code == 'unsupported-shorthand',
      ),
      hasLength(3),
    );
    expect(
      result.diagnostics.where(
        (diagnostic) => diagnostic.code == 'invalid-gap-value',
      ),
      hasLength(1),
    );
  });

  test('gap expansion respects cascade importance and variable fallbacks', () {
    final document = html.parse('''
      <div id="order"></div>
      <div id="reverse-order"></div>
      <div id="priority"></div>
      <div id="components"></div>
      <div id="whole"></div>
      <div id="fallback"></div>
      <div id="inline" style="--row: 6px; gap: var(--row) 11px"></div>
    ''');
    final result = NativeDocumentStyleEngine(
      stylesheets: [
        NativeDocumentStylesheet('''
          #order { gap: 4px; row-gap: 6px; }
          #reverse-order { row-gap: 6px; gap: 4px 8px; }
          #priority {
            gap: 4px 8px !important;
            row-gap: 12px;
            column-gap: 9px !important;
          }
          #components {
            --row: 5px;
            --column: 10%;
            gap: var(--row) var(--column);
          }
          #whole { --both-gaps: 7px 9px; gap: var(--both-gaps); }
          #fallback { gap: var(--missing, 3px 6px); }
        ''', baseUrl: 'https://example.test/gap-variables.css'),
      ],
      viewportWidth: 390,
      dark: false,
    ).apply(document);

    Map<String, String> styleFor(String id) =>
        result.stylesByElement[document.querySelector('#$id')]!;

    expect(styleFor('order')['row-gap'], '6px');
    expect(styleFor('order')['column-gap'], '4px');
    expect(styleFor('reverse-order')['row-gap'], '4px');
    expect(styleFor('reverse-order')['column-gap'], '8px');
    expect(styleFor('priority')['row-gap'], '4px');
    expect(styleFor('priority')['column-gap'], '9px');
    expect(styleFor('components')['row-gap'], '5px');
    expect(styleFor('components')['column-gap'], '10%');
    expect(styleFor('whole')['row-gap'], '7px');
    expect(styleFor('whole')['column-gap'], '9px');
    expect(styleFor('fallback')['row-gap'], '3px');
    expect(styleFor('fallback')['column-gap'], '6px');
    expect(styleFor('inline')['row-gap'], '6px');
    expect(styleFor('inline')['column-gap'], '11px');
    expect(result.diagnostics, isEmpty);
  });
}
