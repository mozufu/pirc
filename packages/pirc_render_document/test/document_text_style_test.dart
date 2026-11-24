import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:html/parser.dart' as html;
import 'package:pirc_render_document/src/document_computed_styles.dart';
import 'package:pirc_render/src/document_layout.dart';
import 'package:pirc_render/src/html_document_styles.dart';
import 'package:pirc_render/src/html_document_box.dart';
import 'package:pirc_render/src/html_document_flex.dart';

NativeDocumentStylesResult cascade(String css, {String inline = ''}) {
  final document = html.parse(
    '<div id="target" data-color="red" style="$inline">text</div>',
  );
  return NativeDocumentStyleEngine(
    stylesheets: [
      NativeDocumentStylesheet(css, baseUrl: 'https://example.test/style.css'),
    ],
    viewportWidth: 390,
    dark: false,
  ).apply(document);
}

void main() {
  for (final selector in [
    '#target',
    '.item',
    '[data-color]',
    '[data-color=":empty"]',
    ':nth-child(1)',
    ':not(.item)',
    'div /* :empty */',
  ]) {
    test('text-independent selector proof accepts $selector', () {
      expect(
        cascade('$selector { color: red }').textContentSelectorsIndependent,
        isTrue,
      );
    });
  }
  for (final selector in [
    ':empty',
    ':not(:empty)',
    ':blank',
    ':not(:blank)',
    ':EMPTY',
    'div:empty + div',
    ':has(:empty)',
    ':hover',
    '::before',
  ]) {
    test('text-dependent or unsupported selector fences $selector', () {
      expect(
        cascade('$selector { color: red }').textContentSelectorsIndependent,
        isFalse,
      );
    });
  }
  test(
    'inactive rules, unresolved imports and bad inline values cannot hide dependencies',
    () {
      expect(
        cascade(
          '@media (min-width: 9999px) { :empty { color: red } }',
        ).textContentSelectorsIndependent,
        isFalse,
      );
      expect(
        cascade(
          '@import "next.css"; #target { color: red }',
        ).textContentSelectorsIndependent,
        isFalse,
      );
      expect(
        cascade(
          '#target { color: red }',
          inline: 'color:var(--missing)',
        ).textContentSelectorsIndependent,
        isFalse,
      );
    },
  );
  testWidgets(
    'native packet certifies cascade values and excludes used lengths',
    (tester) async {
      final document = html.parse(
        '<div id="target" data-pirc-script-id="target" style="width:90px;color:red;pointer-events:none;--Theme:night">text</div>',
      );
      final result = NativeDocumentStyleEngine(
        stylesheets: const [],
        viewportWidth: 390,
        dark: false,
      ).apply(document);
      final specs = nativeDocumentComputedStyleSpecs(
        document: document,
        stylesByElement: result.stylesByElement,
        viewportWidth: 390,
        viewportHeight: 844,
        textContentSelectorsIndependent: result.textContentSelectorsIndependent,
      );
      expect(specs['target']!.textContentSelectorsIndependent, isTrue);
      final controller = NativeDocumentLayoutController();
      addTearDown(controller.dispose);
      final owner = Object();
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: Align(
            alignment: Alignment.topLeft,
            child: NativeDocumentLayoutRoot(
              controller: controller,
              revision: 1,
              knownIds: const {'target'},
              computedStyles: specs,
              child: NativeDocumentLayoutElement(
                controller: controller,
                revision: 1,
                id: 'target',
                boxSurface: (box) =>
                    nativeDocumentBoxSurface(box, owner: owner),
                child: NativeDocumentBox(
                  geometryOwner: owner,
                  width: const NativeFlexLength.pixels(90),
                  height: const NativeFlexLength.pixels(40),
                  child: const SizedBox(),
                ),
              ),
            ),
          ),
        ),
      );
      final packet = controller.capture(
        revision: 1,
        generation: 1,
        viewport: const Size(390, 844),
      )!;
      final box = (packet['boxes'] as List).single as Map;
      final properties = box['textIndependentStyleProperties'] as List;
      expect(
        properties,
        containsAll(['color', 'pointer-events', 'font-family', '--Theme']),
      );
      expect(properties, isNot(contains('width')));
      expect(properties, isNot(contains('height')));
      expect(box['computedStyle'], contains('width'));
    },
  );
}
