import 'package:flutter_test/flutter_test.dart';
import 'package:html/parser.dart' as html;
import 'package:pirc_render/src/html_document_styles.dart';

void main() {
  test('resolves stylesheet background-image against its source URL', () {
    final document = html.parse('<div id="target"></div>');
    final result = NativeDocumentStyleEngine(
      stylesheets: [
        NativeDocumentStylesheet(
          '#target { background-image: url(../images/card.png); }',
          baseUrl: 'https://example.test/css/cards.css',
        ),
      ],
      viewportWidth: 390,
      dark: false,
    ).apply(document);

    final target = document.querySelector('#target')!;
    expect(
      result.stylesByElement[target]!['background-image'],
      'url("https://example.test/images/card.png")',
    );
    expect(
      result.styleAttributesByElement[target],
      contains('background-image: url("https://example.test/images/card.png")'),
    );
    expect(result.diagnostics, isEmpty);
  });

  test('resolves inline style URL against the effective document base', () {
    final document = html.parse(
      '<div id="target" style="background-image: url(hero.png)"></div>',
    );
    final result = NativeDocumentStyleEngine(
      stylesheets: const [],
      viewportWidth: 390,
      dark: false,
      documentBaseUrl: 'https://example.test/root/base/',
    ).apply(document);

    expect(
      result.stylesByElement[document.querySelector(
        '#target',
      )]!['background-image'],
      'url("https://example.test/root/base/hero.png")',
    );
    expect(result.diagnostics, isEmpty);
  });

  test(
    'resolves one-layer background shorthand and retains its layout terms',
    () {
      final document = html.parse('<div id="target"></div>');
      final result = NativeDocumentStyleEngine(
        stylesheets: [
          NativeDocumentStylesheet(
            '#target { background: url(hero.png) center / cover no-repeat; }',
            baseUrl: 'https://example.test/css/cards.css',
          ),
        ],
        viewportWidth: 390,
        dark: false,
      ).apply(document);

      final background = result
          .stylesByElement[document.querySelector('#target')]!['background']!;
      expect(background, contains('url("https://example.test/css/hero.png")'));
      expect(background, contains('center'));
      expect(background, contains('cover'));
      expect(background, contains('no-repeat'));
      final style = result.stylesByElement[document.querySelector('#target')]!;
      expect(
        style['background-image'],
        'url("https://example.test/css/hero.png")',
      );
      expect(style['background-position'], 'center');
      expect(style['background-size'], 'cover');
      expect(style['background-repeat'], 'no-repeat');
      expect(result.diagnostics, isEmpty);
    },
  );

  test(
    'gradient shorthand participates in source order and variable cascade',
    () {
      final document = html.parse(
        '<div id="a"></div><div id="b"></div><div id="c"></div>',
      );
      final result = NativeDocumentStyleEngine(
        stylesheets: [
          NativeDocumentStylesheet('''
        :root { --gradient: linear-gradient(to right, red 0%, blue 100%); }
        #a { background: var(--gradient) white; background-color: black; }
        #b { background-image: radial-gradient(circle, red, blue); background: white; }
        #c { background: white; background-image: var(--gradient); }
      ''', baseUrl: 'https://example.test/style.css'),
        ],
        viewportWidth: 390,
        dark: false,
      ).apply(document);
      final a = result.stylesByElement[document.querySelector('#a')]!;
      final b = result.stylesByElement[document.querySelector('#b')]!;
      final c = result.stylesByElement[document.querySelector('#c')]!;
      expect(a['background-image'], contains('linear-gradient'));
      expect(a['background-color'], '#000');
      expect(a['background-position'], '0% 0%');
      expect(a['background-size'], 'auto');
      expect(b['background-image'], 'none');
      expect(b['background-color'], '#fff');
      expect(c['background-image'], contains('linear-gradient'));
      expect(c['background-color'], '#fff');
      expect(result.diagnostics, isEmpty);
    },
  );

  test(
    'gradient functions do not turn internal commas into background layers',
    () {
      final document = html.parse('<div id="a"></div><div id="b"></div>');
      final result = NativeDocumentStyleEngine(
        stylesheets: [
          NativeDocumentStylesheet('''
        #a { background-image: linear-gradient(90deg, rgba(255,0,0,.5), rgba(0,0,255,.5)); }
        #b { background-image: linear-gradient(red, blue), radial-gradient(white, black); }
      ''', baseUrl: 'https://example.test/style.css'),
        ],
        viewportWidth: 390,
        dark: false,
      ).apply(document);
      expect(
        result.stylesByElement[document.querySelector(
          '#a',
        )]!['background-image'],
        contains('rgba'),
      );
      expect(
        result.stylesByElement[document.querySelector(
          '#b',
        )]!['background-image'],
        contains('radial-gradient'),
      );
      expect(result.diagnostics, isEmpty);
    },
  );

  test(
    'background shorthand resets and competes with longhand declarations',
    () {
      final document = html.parse('''
      <div id="same-rule"></div>
      <div id="specific" class="card"></div>
    ''');
      final result = NativeDocumentStyleEngine(
        stylesheets: [
          NativeDocumentStylesheet('''
          #same-rule {
            background-image: url(before.png);
            background: red;
          }
          .card { background-image: url(before.png); }
          #specific { background: red; }
        ''', baseUrl: 'https://example.test/css/style.css'),
        ],
        viewportWidth: 390,
        dark: false,
      ).apply(document);

      for (final id in ['same-rule', 'specific']) {
        final style = result.stylesByElement[document.querySelector('#$id')]!;
        expect(style['background-image'], 'none', reason: id);
        expect(style['background-color'], '#f00', reason: id);
        expect(
          style.keys.take(2),
          ['background', 'background-image'],
          reason: '$id style-map order must apply shorthand before longhands',
        );
      }
      expect(result.diagnostics, isEmpty);
    },
  );

  test(
    'mixed declarations retain the winning image when a later weaker shorthand resets',
    () {
      final document = html.parse('<div id="target" class="card"></div>');
      final result = NativeDocumentStyleEngine(
        stylesheets: [
          NativeDocumentStylesheet(
            '#target{background-image:url(high.png)}.card{padding:4px}.card{background:red}',
            baseUrl: 'https://example.test/css/a.css',
          ),
        ],
        viewportWidth: 390,
        dark: false,
      ).apply(document);
      final style = result.stylesByElement[document.querySelector('#target')]!;
      expect(
        style['background-image'],
        'url("https://example.test/css/high.png")',
      );
      expect(style['padding-top'], '4px');
      expect(style.keys.first, 'background');
      final serialized =
          result.styleAttributesByElement[document.querySelector('#target')]!;
      expect(
        serialized.indexOf('background:'),
        lessThan(serialized.indexOf('background-image:')),
      );
    },
  );
  test(
    'a custom-property URL uses the consuming declaration stylesheet base',
    () {
      // Pinned Chrome probe: --asset:url(var.png) is defined by /a/vars.css,
      // then consumed by background-image in /b/use.css; its computed URL is
      // https://example.test/b/var.png. Fallback URL tokens use the same base.
      final document = html.parse('''
        <div id="wrapper">
          <div id="from-variable"></div>
          <div id="from-fallback"></div>
        </div>
      ''');
      final result = NativeDocumentStyleEngine(
        stylesheets: [
          NativeDocumentStylesheet(
            '#wrapper { --asset: url(var.png); }',
            baseUrl: 'https://example.test/a/vars.css',
          ),
          NativeDocumentStylesheet('''
            #from-variable { background-image: var(--asset); }
            #from-fallback { background-image: var(--missing, url(fallback.png)); }
          ''', baseUrl: 'https://example.test/b/use.css'),
        ],
        viewportWidth: 390,
        dark: false,
      ).apply(document);

      expect(
        result.stylesByElement[document.querySelector(
          '#from-variable',
        )]!['background-image'],
        'url("https://example.test/b/var.png")',
      );
      expect(
        result.stylesByElement[document.querySelector(
          '#from-fallback',
        )]!['background-image'],
        'url("https://example.test/b/fallback.png")',
      );
      expect(result.diagnostics, isEmpty);
    },
  );

  test('preserves data raster URLs and CSS-escapes rewritten strings', () {
    final document = html.parse('''
      <div id="data" style="background-image: url('data:image/png;base64,AAAA')"></div>
      <div id="escaped"></div>
    ''');
    final result = NativeDocumentStyleEngine(
      stylesheets: [
        NativeDocumentStylesheet(
          r'#escaped { background-image: url(poster\20 one.png); }',
          baseUrl: 'https://example.test/css/style.css',
        ),
      ],
      viewportWidth: 390,
      dark: false,
      documentBaseUrl: 'https://example.test/page/index.html',
    ).apply(document);

    expect(
      result.stylesByElement[document.querySelector(
        '#data',
      )]!['background-image'],
      'url("data:image/png;base64,AAAA")',
    );
    expect(
      result.stylesByElement[document.querySelector('#escaped')],
      isNotNull,
      reason: '${result.diagnostics}',
    );
    expect(
      result.stylesByElement[document.querySelector(
        '#escaped',
      )]!['background-image'],
      'url("https://example.test/css/poster%20one.png")',
    );
    expect(result.diagnostics, isEmpty);
  });

  test('diagnoses unsupported image functions and URLs', () {
    final document = html.parse('''
      <div id="layered"></div>
      <div id="image-set"></div>
      <div id="svg"></div>
      <div id="scheme"></div>
      <div id="data-svg"></div>
    ''');
    final result = NativeDocumentStyleEngine(
      stylesheets: [
        NativeDocumentStylesheet('''
          #layered { background: url(one.png), url(two.png); }
          #image-set { background-image: image-set(
            url(one.png) 1x, url(two.png) 2x); }
          #svg { background-image: url(#card); }
          #scheme { background-image: url(file:///tmp/card.png); }
          #data-svg { background-image: url('data:image/svg+xml,<svg/>'); }
        ''', baseUrl: 'https://example.test/css/style.css'),
      ],
      viewportWidth: 390,
      dark: false,
    ).apply(document);

    for (final id in ['image-set', 'svg', 'scheme']) {
      expect(result.stylesByElement[document.querySelector('#$id')], isNull);
    }
    expect(
      result.stylesByElement[document.querySelector(
        '#layered',
      )]!['background-image'],
      contains('url("https://example.test/css/two.png")'),
    );
    expect(
      result.stylesByElement[document.querySelector(
        '#data-svg',
      )]!['background-image'],
      contains('data:image/svg+xml'),
    );
    expect(
      result.diagnostics.map((diagnostic) => diagnostic.code),
      containsAll([
        'unsupported-background-image',
        'unsupported-background-url',
      ]),
    );
    expect(
      result.diagnostics
          .where(
            (diagnostic) => diagnostic.code == 'unsupported-background-url',
          )
          .map((diagnostic) => diagnostic.message),
      contains('SVG fragment background images are unsupported.'),
    );
  });

  test('reports inline URLs when no effective document base is available', () {
    final document = html.parse(
      '<div id="target" style="background-image: url(hero.png)"></div>',
    );
    final result = NativeDocumentStyleEngine(
      stylesheets: const [],
      viewportWidth: 390,
      dark: false,
    ).apply(document);

    expect(result.stylesByElement[document.querySelector('#target')], isNull);
    expect(
      result.diagnostics.map((diagnostic) => diagnostic.code),
      contains('unsupported-background-url'),
    );
  });
}
