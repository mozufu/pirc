import 'package:flutter_test/flutter_test.dart';
import 'package:html/parser.dart' as html;
import 'package:pirc_render/src/document_computed_styles.dart';
import 'package:pirc_render/src/html_document_styles.dart';

const _baseUrl = 'https://example.test/computed.css';

Map<String, NativeDocumentComputedStyleSpec> _compute(
  String markup, {
  String css = '',
  bool dark = false,
  double viewportWidth = 390,
  double viewportHeight = 844,
}) {
  final document = html.parse(markup);
  final cascade = NativeDocumentStyleEngine(
    stylesheets: [NativeDocumentStylesheet(css, baseUrl: _baseUrl)],
    viewportWidth: viewportWidth,
    dark: dark,
  ).apply(document);
  return nativeDocumentComputedStyleSpecs(
    document: document,
    stylesByElement: cascade.stylesByElement,
    viewportWidth: viewportWidth,
    viewportHeight: viewportHeight,
    dark: dark,
  );
}

void main() {
  test('resolves inherited typography, colors, and CSS-wide keywords', () {
    final specs = _compute(
      '''
      <div id="parent" data-pirc-script-id="parent">
        <span id="child" data-pirc-script-id="child"></span>
      </div>
    ''',
      css: '''
      #parent {
        color: rgb(25, 50, 75);
        font: 600 20px / 1.5 serif;
      }
      #child {
        font-size: 1.25em;
        background-color: currentColor;
        opacity: 1.2;
        width: 50%;
        height: calc(100% - 2px);
        margin: 1em 2%;
        padding: 3px;
        position: relative;
        inset: 10% auto auto 1vw;
        border: 2px solid currentColor;
      }
    ''',
    );

    final parent = specs['parent']!;
    final child = specs['child']!;
    expect(parent.values['font-size'], '20px');
    expect(parent.values['font-weight'], '600');
    expect(parent.values['line-height'], '30px');
    expect(child.values['font-size'], '25px');
    expect(child.values['font-weight'], '600');
    expect(child.values['font-family'], 'serif');
    expect(child.values['line-height'], '37.5px');
    expect(child.values['color'], 'rgb(25, 50, 75)');
    expect(child.values['background-color'], 'rgb(25, 50, 75)');
    expect(child.values['position'], 'relative');
    expect(child.values['opacity'], '1');
    expect(child.values['border-top-style'], 'solid');
    expect(child.values['border-top-color'], 'rgb(25, 50, 75)');
    expect(child.lengths['width'], '50%');
    expect(child.lengths['height'], 'calc(100% - 2px)');
    expect(child.lengths['margin-top'], '25px');
    expect(child.lengths['margin-left'], '2%');
    expect(child.lengths['padding-top'], '3px');
    expect(child.lengths['padding-right'], '3px');
    expect(child.lengths['top'], '10%');
    expect(child.lengths['right'], 'auto');
    expect(child.lengths['left'], '3.9px');
    expect(child.lengths['border-top-width'], '2px');
  });

  test(
    'provides trusted basic HTML defaults and complete geometry longhands',
    () {
      final specs = _compute('''
      <html data-pirc-script-id="root"><body data-pirc-script-id="body">
        <div data-pirc-script-id="block"></div>
        <span data-pirc-script-id="inline"></span>
        <p data-pirc-script-id="paragraph"></p>
        <h1 data-pirc-script-id="heading"></h1>
        <ul data-pirc-script-id="list"><li data-pirc-script-id="item"></li></ul>
        <code data-pirc-script-id="code"></code>
        <ol data-pirc-script-id="ordered"><li data-pirc-script-id="ordered-item"></li></ol>
      </body></html>
    ''');

      expect(specs['root']!.values['display'], 'block');
      expect(specs['root']!.values['font-family'], 'serif');
      expect(specs['root']!.values['font-size'], '16px');
      expect(specs['root']!.lengths['width'], 'auto');
      expect(specs['root']!.lengths['height'], 'auto');
      expect(specs['body']!.lengths['margin-top'], '8px');
      expect(specs['block']!.values['display'], 'block');
      expect(specs['inline']!.values['display'], 'inline');
      expect(specs['paragraph']!.lengths['margin-top'], '16px');
      expect(specs['heading']!.values['font-size'], '32px');
      expect(specs['heading']!.values['font-weight'], '700');
      expect(specs['heading']!.lengths['margin-top'], '21.44px');
      expect(specs['list']!.lengths['padding-left'], '40px');
      expect(specs['item']!.values['display'], 'list-item');
      expect(specs['code']!.values['font-family'], 'monospace');
      expect(specs['ordered']!.values['list-style-type'], 'decimal');
      expect(specs['ordered-item']!.values['list-style-type'], 'decimal');

      final geometryProperties = <String>{
        'width',
        'height',
        'min-width',
        'max-width',
        'min-height',
        'max-height',
        'top',
        'right',
        'bottom',
        'left',
        for (final side in ['top', 'right', 'bottom', 'left']) 'margin-$side',
        for (final side in ['top', 'right', 'bottom', 'left']) 'padding-$side',
        for (final side in ['top', 'right', 'bottom', 'left'])
          'border-$side-width',
      };
      expect(specs['block']!.lengths.keys, containsAll(geometryProperties));
    },
  );

  test('inherits default text color using the requested theme', () {
    final light = _compute('''
      <div id="parent" data-pirc-script-id="parent">
        <span data-pirc-script-id="child"></span>
      </div>
    ''');
    final dark = _compute('''
      <div data-pirc-script-id="parent">
        <span data-pirc-script-id="child"></span>
      </div>
    ''', dark: true);

    expect(light['parent']!.values['color'], 'rgb(0, 0, 0)');
    expect(light['child']!.values['color'], 'rgb(0, 0, 0)');
    expect(dark['parent']!.values['color'], 'rgb(255, 255, 255)');
    expect(dark['child']!.values['color'], 'rgb(255, 255, 255)');
  });

  test('retains logical system font families and inherits them', () {
    final specs = _compute('''
      <div id="parent" data-pirc-script-id="parent">
        <span id="child" data-pirc-script-id="child"></span>
      </div>
    ''', css: '#parent { font-family: system-ui, sans-serif; }');

    expect(specs['parent']!.values['font-family'], 'system-ui, sans-serif');
    expect(specs['child']!.values['font-family'], 'system-ui, sans-serif');
  });

  test('explicit font-weight inherit bypasses user-agent bold defaults', () {
    final specs = _compute('''
      <div data-pirc-script-id="parent">
        <strong id="inherited" data-pirc-script-id="inherited"></strong>
        <strong data-pirc-script-id="ua-bold"></strong>
      </div>
    ''', css: '#inherited { font-weight: inherit; }');

    expect(specs['parent']!.values['font-weight'], '400');
    expect(specs['inherited']!.values['font-weight'], '400');
    expect(specs['ua-bold']!.values['font-weight'], '700');
  });

  test('normalizes font-stretch and word-spacing computed values', () {
    final specs = _compute(
      '''
      <div id="parent" data-pirc-script-id="parent">
        <span id="child" data-pirc-script-id="child"></span>
      </div>
    ''',
      css: '''
      #parent { font-stretch: condensed; word-spacing: normal; }
      #child { font-stretch: normal; }
    ''',
    );

    expect(specs['parent']!.values['font-stretch'], '75%');
    expect(specs['child']!.values['font-stretch'], '100%');
    expect(specs['parent']!.values['word-spacing'], '0px');
    expect(specs['child']!.values['word-spacing'], '0px');
  });

  test('omits font sizes that depend on unsupported ancestor expressions', () {
    final specs = _compute(
      '''
      <div id="parent" data-pirc-script-id="parent">
        <span id="child" data-pirc-script-id="child">
          <i data-pirc-script-id="grandchild"></i>
        </span>
      </div>
    ''',
      css: '''
      #parent { font-size: calc(100% + 2px); }
      #child {
        font-size: 2em;
        margin-top: 1em;
        margin-right: 1rem;
        width: 2rem;
      }
    ''',
    );

    expect(specs['parent']!.values, isNot(contains('font-size')));
    expect(specs['child']!.values, isNot(contains('font-size')));
    expect(specs['grandchild']!.values, isNot(contains('font-size')));
    expect(specs['child']!.lengths, isNot(contains('margin-top')));
    expect(specs['child']!.lengths['margin-right'], '16px');
    expect(specs['child']!.lengths['width'], '32px');
  });

  test('omits rem geometry when the root font size is unsupported', () {
    final specs = _compute(
      '''
      <html><body>
        <div data-pirc-script-id="target"></div>
      </body></html>
    ''',
      css: '''
      html { font-size: calc(100% + 1px); }
      [data-pirc-script-id="target"] { width: 2rem; }
    ''',
    );

    expect(specs['target']!.lengths, isNot(contains('width')));
  });

  test('inherited em geometry keeps the parent computed value', () {
    final specs = _compute(
      '''
      <div id="parent" data-pirc-script-id="parent">
        <span id="child" data-pirc-script-id="child"></span>
      </div>
    ''',
      css: '''
      #parent { font-size: 16px; margin-top: 1em; }
      #child { font-size: 32px; margin-top: inherit; }
    ''',
    );

    expect(specs['parent']!.lengths['margin-top'], '16px');
    expect(specs['child']!.lengths['margin-top'], '16px');
  });

  test('resolves only common CSS length units with the required bases', () {
    double? resolve(String value, {double? percentageBasis}) =>
        nativeComputedCssLength(
          value,
          fontSize: 20,
          rootFontSize: 10,
          viewportWidth: 390,
          viewportHeight: 800,
          percentageBasis: percentageBasis,
        );

    expect(resolve('12.5px'), 12.5);
    expect(resolve('2em'), 40);
    expect(resolve('1.5rem'), 15);
    expect(resolve('50%'), isNull);
    expect(resolve('50%', percentageBasis: 200), 100);
    expect(resolve('10vw'), 39);
    expect(resolve('25vh'), 200);
    expect(resolve('0'), 0);
    expect(resolve('calc(100% - 2px)'), isNull);
    expect(resolve('auto'), isNull);
  });

  test('blockifies direct inline flex and grid children', () {
    final specs = _compute('''
      <div style="display:flex"><span data-pirc-script-id="flex"></span></div>
      <div style="display:grid"><span data-pirc-script-id="grid"></span>
        <span data-pirc-script-id="hidden" style="display:none"></span></div>
      <div><span data-pirc-script-id="inline"></span></div>
    ''');
    expect(specs['flex']!.values['display'], 'block');
    expect(specs['grid']!.values['display'], 'block');
    expect(specs['hidden']!.values['display'], 'none');
    expect(specs['inline']!.values['display'], 'inline');
  });

  test('spec maps are immutable snapshots', () {
    final spec = NativeDocumentComputedStyleSpec(
      values: const {'color': 'rgb(0, 0, 0)'},
      lengths: const {'width': 'auto'},
      fontSize: 16,
      rootFontSize: 16,
    );

    expect(() => spec.values['color'] = 'red', throwsUnsupportedError);
    expect(() => spec.lengths['width'] = '10px', throwsUnsupportedError);
  });

  test(
    'bounds oversized custom-property inheritance and marks it unavailable',
    () {
      final declarations = List.generate(
        300,
        (index) => '--token-$index: value-$index;',
      ).join('\n');
      final specs = _compute('''
      <html data-pirc-script-id="root"><body>
        <div data-pirc-script-id="child"></div>
      </body></html>
    ''', css: ':root { $declarations }');
      final root = specs['root']!;
      final child = specs['child']!;

      expect(root.available, isFalse);
      expect(root.values.length, lessThanOrEqualTo(256));
      expect(root.values.keys.where((key) => key.startsWith('--')), isEmpty);
      expect(child.available, isFalse);
      expect(child.values.keys.where((key) => key.startsWith('--')), isEmpty);
    },
  );
}
