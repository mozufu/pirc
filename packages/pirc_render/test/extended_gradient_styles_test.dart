import 'package:flutter_test/flutter_test.dart';
import 'package:html/parser.dart' as html;
import 'package:pirc_render/src/html_document_styles.dart';

void main() {
  test(
    'accepts conic and repeating gradients in image, shorthand, and layers',
    () {
      final document = html.parse('''
        <div id="owner">
          <div id="conic-image"></div>
          <div id="repeating-image"></div>
          <div id="repeating-shorthand"></div>
          <div id="fallback"></div>
          <div id="layers"></div>
          <div id="shorthand-layers"></div>
        </div>
      ''');
      final result = NativeDocumentStyleEngine(
        stylesheets: [
          NativeDocumentStylesheet('''
            #owner {
              --conic: conic-gradient(from 90deg at 25% 75%, red 0%, blue 100%);
              --repeating-linear: repeating-linear-gradient(
                90deg, red 0px 10px, blue 20px 30px);
              --repeating-radial: repeating-radial-gradient(
                circle, red 0px, blue 10px);
            }
            #conic-image { background-image: var(--conic); }
            #repeating-image { background-image: var(--repeating-linear); }
            #repeating-shorthand {
              background: var(--repeating-radial) center / cover no-repeat;
            }
            #fallback {
              background-image: var(--missing, repeating-conic-gradient(
                from 45deg at center, red 0deg, blue 90deg));
            }
            #layers {
              background-image:
                repeating-conic-gradient(
                  from 45deg at center, red 0deg, blue 90deg),
                linear-gradient(to right, white, black);
            }
            #shorthand-layers {
              background: var(--conic),
                repeating-linear-gradient(90deg, red 0px, blue 10px) white;
            }
          ''', baseUrl: 'https://example.test/style.css'),
        ],
        viewportWidth: 390,
        dark: false,
      ).apply(document);

      final conic =
          result.stylesByElement[document.querySelector('#conic-image')]!;
      expect(conic['background-image'], contains('conic-gradient'));

      final repeatingLinear =
          result.stylesByElement[document.querySelector('#repeating-image')]!;
      expect(
        repeatingLinear['background-image'],
        contains('repeating-linear-gradient'),
      );

      final repeatingRadial = result
          .stylesByElement[document.querySelector('#repeating-shorthand')]!;
      expect(
        repeatingRadial['background-image'],
        contains('repeating-radial-gradient'),
      );
      expect(repeatingRadial['background-position'], 'center');
      expect(repeatingRadial['background-size'], 'cover');
      expect(repeatingRadial['background-repeat'], 'no-repeat');

      final fallback =
          result.stylesByElement[document.querySelector('#fallback')]!;
      expect(
        fallback['background-image'],
        contains('repeating-conic-gradient'),
      );

      final layers = result.stylesByElement[document.querySelector('#layers')]!;
      expect(layers['background-image'], contains('repeating-conic-gradient'));
      expect(layers['background-image'], contains('linear-gradient'));

      final shorthandLayers =
          result.stylesByElement[document.querySelector('#shorthand-layers')]!;
      expect(shorthandLayers['background-image'], contains('conic-gradient'));
      expect(
        shorthandLayers['background-image'],
        contains('repeating-linear-gradient'),
      );
      expect(shorthandLayers['background-color'], '#fff');
      expect(result.diagnostics, isEmpty);
    },
  );

  test(
    'diagnoses unsupported interpolation spaces and invalid gradient grammar',
    () {
      final document = html.parse('''
        <div id="bad-interpolation"></div>
        <div id="bad-shorthand"></div>
      ''');
      final result = NativeDocumentStyleEngine(
        stylesheets: [
          NativeDocumentStylesheet('''
            #bad-interpolation {
              background-image: conic-gradient(in unknown-space, red, blue);
            }
            #bad-shorthand {
              background: repeating-conic-gradient(from banana, red, blue);
            }
          ''', baseUrl: 'https://example.test/style.css'),
        ],
        viewportWidth: 390,
        dark: false,
      ).apply(document);

      expect(
        result.stylesByElement[document.querySelector('#bad-interpolation')],
        isNull,
      );
      expect(
        result.stylesByElement[document.querySelector('#bad-shorthand')],
        isNull,
      );
      final unsupportedImages = result.diagnostics
          .where(
            (diagnostic) => diagnostic.code == 'unsupported-background-image',
          )
          .toList();
      expect(unsupportedImages, hasLength(2));
      expect(
        unsupportedImages.map((diagnostic) => diagnostic.property),
        containsAll(['background-image', 'background']),
      );
    },
  );
}
