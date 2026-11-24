import 'package:flutter_test/flutter_test.dart';
import 'package:html/parser.dart' as html;
import 'package:pirc_render/src/html_responsive_image.dart';

NativeResponsiveImageSelection selectImage(
  String source, {
  double viewportWidth = 800,
  double viewportHeight = 800,
  double devicePixelRatio = 1,
  bool dark = false,
}) {
  final document = html.parse(source);
  final img = document.querySelector('img');
  if (img == null) throw StateError('No image element in test source.');
  return selectNativeResponsiveImage(
    img,
    viewportWidth: viewportWidth,
    viewportHeight: viewportHeight,
    devicePixelRatio: devicePixelRatio,
    dark: dark,
  );
}

void main() {
  test('AVIF picture selection follows verified native capabilities', () {
    final img = html
        .parseFragment(
          '<picture><source type="image/avif" srcset="preferred.avif"><img src="fallback.png"></picture>',
        )
        .querySelector('img')!;
    expect(
      selectNativeResponsiveImage(
        img,
        viewportWidth: 390,
        devicePixelRatio: 1,
        avifSupported: true,
      ).url,
      'preferred.avif',
    );
    expect(
      selectNativeResponsiveImage(
        img,
        viewportWidth: 390,
        devicePixelRatio: 1,
        avifSupported: false,
      ).url,
      'fallback.png',
    );
  });

  test('a plain src is the density-one fallback', () {
    final selection = selectImage('<img src="photo.png">');

    expect(selection.url, 'photo.png');
    expect(selection.density, 1);
    expect(selection.diagnostics, isEmpty);
  });

  test('density srcset candidates work without src', () {
    final selection = selectImage(
      '<img srcset="small.png 1x, large.png 2x">',
      devicePixelRatio: 2,
    );

    expect(selection.url, 'large.png');
    expect(selection.density, 2);
  });

  test('density selection uses the largest candidate below a higher DPR', () {
    final selection = selectImage(
      '<img srcset="one.png 1x, two.png 2x">',
      devicePixelRatio: 3,
    );

    expect(selection.url, 'two.png');
    expect(selection.density, 2);
  });

  test(
    'src is added as the one-density fallback when x candidates omit it',
    () {
      final fallback = selectImage(
        '<img src="fallback.png" srcset="large.png 2x">',
      );
      final larger = selectImage(
        '<img src="fallback.png" srcset="large.png 2x">',
        devicePixelRatio: 2,
      );

      expect(fallback.url, 'fallback.png');
      expect(fallback.density, 1);
      expect(larger.url, 'large.png');
      expect(larger.density, 2);
    },
  );

  test('srcset tokenization keeps the comma inside a data URL', () {
    final oneX = selectImage(
      '<img srcset="data:image/png;base64,AAAA 1x, two.png 2x">',
    );
    final twoX = selectImage(
      '<img srcset="data:image/png;base64,AAAA 1x, two.png 2x">',
      devicePixelRatio: 2,
    );

    expect(oneX.url, 'data:image/png;base64,AAAA');
    expect(twoX.url, 'two.png');
  });

  test('width candidates use the first matching sizes media rule', () {
    final selection = selectImage(
      '<img srcset="400.png 400w, 800.png 800w" '
      'sizes="(max-width: 600px) 100vw, (min-width: 300px) 50vw">',
      viewportWidth: 400,
      devicePixelRatio: 1,
    );

    expect(selection.url, '400.png');
    expect(selection.density, 1);
  });

  test('width candidates default sizes to 100vw and return pixel density', () {
    final selection = selectImage(
      '<img srcset="200.png 200w, 800.png 800w">',
      viewportWidth: 400,
      devicePixelRatio: 2,
    );

    expect(selection.url, '800.png');
    expect(selection.density, 2);
  });

  test('malformed sizes use 100vw and add a named diagnostic', () {
    final selection = selectImage(
      '<img srcset="200.png 200w, 800.png 800w" '
      'sizes="calc(100vw - 20px)">',
      viewportWidth: 400,
      devicePixelRatio: 2,
    );

    expect(selection.url, '800.png');
    expect(selection.density, 2);
    expect(
      selection.diagnostics,
      contains('sizes.unsupported-length: calc(100vw - 20px)'),
    );
  });

  test('sizes min() resolves mixed vw and px bounds', () {
    final selection = selectImage(
      '<img srcset="400.png 400w, 800.png 800w, 1200.png 1200w" '
      'sizes="(min-width: 700px) min(50vw, 360px), 100vw">',
      viewportWidth: 1024,
      devicePixelRatio: 2,
    );

    expect(selection.url, '800.png');
    expect(selection.density, closeTo(800 / 360, 0.0001));
    expect(selection.diagnostics, isEmpty);
  });

  test('a picture source can provide srcset without src', () {
    final selection = selectImage(
      '<picture><source type="image/webp" srcset="hero.webp 2x">'
      '<img src="fallback.png"></picture>',
      devicePixelRatio: 2,
    );

    expect(selection.url, 'hero.webp');
    expect(selection.density, 2);
  });

  test(
    'picture sources are checked in order and unsupported MIME is diagnosed',
    () {
      final selection = selectImage(
        '<picture>'
        '<source type="image/avif" srcset="modern.avif 2x">'
        '<source type="image/webp" srcset="supported.webp 2x">'
        '<img src="fallback.png">'
        '</picture>',
        devicePixelRatio: 2,
      );

      expect(selection.url, 'supported.webp');
      expect(
        selection.diagnostics,
        contains('picture.unsupported-type: image/avif'),
      );
    },
  );

  test('picture media supports ordered width and dark-scheme conditions', () {
    final darkSelection = selectImage(
      '<picture>'
      '<source media="(prefers-color-scheme: dark) and (min-width: 600px)" '
      'srcset="dark.png 1x">'
      '<img src="light.png">'
      '</picture>',
      viewportWidth: 700,
      dark: true,
    );
    final lightSelection = selectImage(
      '<picture>'
      '<source media="(prefers-color-scheme: dark) and (min-width: 600px)" '
      'srcset="dark.png 1x">'
      '<img src="light.png">'
      '</picture>',
      viewportWidth: 700,
      dark: false,
    );

    expect(darkSelection.url, 'dark.png');
    expect(lightSelection.url, 'light.png');
  });

  test('mixed density and width descriptors invalidate the whole srcset', () {
    final selection = selectImage(
      '<img src="fallback.png" srcset="density.png 2x, width.png 800w">',
      devicePixelRatio: 2,
    );

    expect(selection.url, 'fallback.png');
    expect(selection.diagnostics, contains('srcset.mixed-descriptors'));
  });

  test(
    'a malformed mixed candidate does not discard valid width candidates',
    () {
      final selection = selectImage(
        '<img src="fallback.png" sizes="200px" '
        'srcset="400.png 400w 2x, 800.png 800w">',
        viewportWidth: 390,
        devicePixelRatio: 1,
      );

      expect(selection.url, '800.png');
      expect(selection.density, 4);
      expect(
        selection.diagnostics,
        contains('srcset.invalid-descriptor-count: 400.png'),
      );
    },
  );

  test(
    'invalid and duplicate descriptors are rejected candidate by candidate',
    () {
      final selection = selectImage(
        '<img src="fallback.png" '
        'srcset="zero.png 0x, duplicate.png 2x 2x, one.png 1x">',
      );

      expect(selection.url, 'one.png');
      expect(
        selection.diagnostics,
        contains('srcset.invalid-descriptor: zero.png'),
      );
      expect(
        selection.diagnostics,
        contains('srcset.duplicate-descriptor: duplicate.png'),
      );
    },
  );

  test('unsafe schemes and unsupported data MIME are skipped', () {
    final selection = selectImage(
      '<img src="safe.png" srcset="javascript:alert(1) 2x, '
      'data:image/avif;base64,AAAA 3x">',
      devicePixelRatio: 2,
    );

    expect(selection.url, 'safe.png');
    expect(
      selection.diagnostics,
      contains('url.unsafe-scheme: javascript (srcset)'),
    );
    expect(selection.diagnostics, contains('url.unsafe-data-mime: srcset'));
  });

  test('unsupported media syntax is diagnosed and falls back to img src', () {
    final selection = selectImage(
      '<picture><source media="(width > 500px)" srcset="wide.png 1x">'
      '<img src="fallback.png"></picture>',
      viewportWidth: 800,
    );

    expect(selection.url, 'fallback.png');
    expect(
      selection.diagnostics,
      contains('media.unsupported-query: (width > 500px)'),
    );
  });

  test('selection does not mutate its input DOM', () {
    final document = html.parse(
      '<picture><source srcset="wide.png 2x"><img src="base.png"></picture>',
    );
    final img = document.querySelector('img')!;
    final before = document.body!.innerHtml;

    selectNativeResponsiveImage(img, viewportWidth: 800, devicePixelRatio: 2);

    expect(document.body!.innerHtml, before);
  });
}
