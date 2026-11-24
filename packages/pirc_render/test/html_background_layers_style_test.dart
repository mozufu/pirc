import 'package:flutter_test/flutter_test.dart';
import 'package:html/parser.dart' as html;
import 'package:pirc_render/src/html_document_styles.dart';

void main() {
  test('normalizes gradient and URL image layers independently', () {
    final document = html.parse('<div id="target"></div>');
    final result = NativeDocumentStyleEngine(
      stylesheets: [
        NativeDocumentStylesheet(
          '#target { background-image: linear-gradient(90deg, rgba(255,0,0,.5), blue), url(../images/card.png); }',
          baseUrl: 'https://example.test/css/page.css',
        ),
      ],
      viewportWidth: 390,
      dark: false,
    ).apply(document);

    final image =
        result.stylesByElement[document.querySelector(
          '#target',
        )]!['background-image']!;
    expect(image, contains('linear-gradient'));
    expect(image, contains('rgba'));
    expect(image, contains('url("https://example.test/images/card.png")'));
    expect(result.diagnostics, isEmpty);
  });

  test('keeps commas inside data URLs while splitting image layers', () {
    final document = html.parse('''
      <div id="target" style="background-image: url('data:image/png;base64,AAAA,BBBB'), url(tile.png)"></div>
    ''');
    final result = NativeDocumentStyleEngine(
      stylesheets: const [],
      viewportWidth: 390,
      dark: false,
      documentBaseUrl: 'https://example.test/page/index.html',
    ).apply(document);

    expect(
      result.stylesByElement[document.querySelector(
        '#target',
      )]!['background-image'],
      'url("data:image/png;base64,AAAA,BBBB"), '
      'url("https://example.test/page/tile.png")',
    );
    expect(result.diagnostics, isEmpty);
  });

  test(
    'expands shorthand layer lists and preserves reset and important rules',
    () {
      final document = html.parse('''
      <div id="target"></div>
      <div id="reset"></div>
    ''');
      final result = NativeDocumentStyleEngine(
        stylesheets: [
          NativeDocumentStylesheet('''
          #target {
            background: url(first.png) left top / contain no-repeat,
              linear-gradient(red, blue) center / cover repeat-x fixed
              border-box content-box red !important;
            background-image: url(ordinary-override.png);
            background-position: right;
          }
          #reset {
            background-color: black;
            background-size: cover;
            background: url(reset.png), none;
          }
        ''', baseUrl: 'https://example.test/css/style.css'),
        ],
        viewportWidth: 390,
        dark: false,
      ).apply(document);

      final targetElement = document.querySelector('#target')!;
      final target = result.stylesByElement[targetElement]!;
      expect(
        target['background-image'],
        startsWith(
          'url("https://example.test/css/first.png"), linear-gradient',
        ),
      );
      expect(
        target['background-image'],
        isNot(contains('ordinary-override.png')),
      );
      expect(target['background-position'], 'left top, center');
      expect(target['background-size'], 'contain, cover');
      expect(target['background-repeat'], 'no-repeat, repeat-x');
      expect(target['background-attachment'], 'scroll, fixed');
      expect(target['background-origin'], 'padding-box, border-box');
      expect(target['background-clip'], 'border-box, content-box');
      expect(target['background-color'], '#f00');
      expect(
        result.styleAttributesByElement[targetElement],
        contains('!important'),
      );

      final reset = result.stylesByElement[document.querySelector('#reset')]!;
      expect(
        reset['background-image'],
        'url("https://example.test/css/reset.png"), none',
      );
      expect(reset['background-color'], 'transparent');
      expect(reset['background-size'], 'auto, auto');
      expect(reset['background-repeat'], 'repeat, repeat');
      expect(result.diagnostics, isEmpty);
    },
  );

  test('rejects explicit color on any non-final shorthand layer', () {
    final document = html.parse('''
      <div id="named-color"></div>
      <div id="transparent-color"></div>
    ''');
    final result = NativeDocumentStyleEngine(
      stylesheets: [
        NativeDocumentStylesheet('''
          #named-color { background: red, url(card.png); }
          #transparent-color { background: transparent, url(card.png); }
        ''', baseUrl: 'https://example.test/style.css'),
      ],
      viewportWidth: 390,
      dark: false,
    ).apply(document);

    expect(
      result.stylesByElement[document.querySelector('#named-color')],
      isNull,
    );
    expect(
      result.stylesByElement[document.querySelector('#transparent-color')],
      isNull,
    );
    expect(
      result.diagnostics.where(
        (diagnostic) =>
            diagnostic.code == 'unsupported-background-shorthand' &&
            diagnostic.message.contains('final background layer'),
      ),
      hasLength(2),
    );
  });

  test('rejects unsupported image functions in any layer', () {
    final document = html.parse('<div id="target"></div>');
    final result = NativeDocumentStyleEngine(
      stylesheets: [
        NativeDocumentStylesheet(
          '#target { background: url(first.png), image-set(url(second.png) 1x); }',
          baseUrl: 'https://example.test/style.css',
        ),
      ],
      viewportWidth: 390,
      dark: false,
    ).apply(document);

    expect(result.stylesByElement[document.querySelector('#target')], isNull);
    expect(
      result.diagnostics.map((diagnostic) => diagnostic.code),
      contains('unsupported-background-image'),
    );
  });

  test('resolves layered image values after custom property expansion', () {
    final document = html.parse('<div id="target"></div>');
    final result = NativeDocumentStyleEngine(
      stylesheets: [
        NativeDocumentStylesheet(
          ':root { --layers: linear-gradient(red, blue), url(card.png); }',
          baseUrl: 'https://example.test/variables/vars.css',
        ),
        NativeDocumentStylesheet(
          '#target { background-image: var(--layers); }',
          baseUrl: 'https://example.test/css/use.css',
        ),
      ],
      viewportWidth: 390,
      dark: false,
    ).apply(document);

    final image =
        result.stylesByElement[document.querySelector(
          '#target',
        )]!['background-image']!;
    expect(image, contains('linear-gradient'));
    expect(image, contains('url("https://example.test/css/card.png")'));
    expect(result.diagnostics, isEmpty);
  });
}
