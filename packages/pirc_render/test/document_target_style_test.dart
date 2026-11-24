import 'package:flutter_test/flutter_test.dart';
import 'package:html/parser.dart' as html;
import 'package:pirc_render/src/html_document_styles.dart';
import 'package:pirc_render/src/document_fragment.dart';

void main() {
  test(
    'target selectors keep specificity, negation, combinators, nth-child and root matching',
    () {
      final document = html.parse(
        '<div id="one" class="item"></div><div id="two" class="item"></div>',
      );
      final target = document.getElementById('two')!;
      final before = {
        for (final e in document.querySelectorAll('*')) e: Map.of(e.attributes),
      };
      final result = NativeDocumentStyleEngine(
        stylesheets: const [
          NativeDocumentStylesheet('''
.item{color:red} :root :target:nth-child(2){color:green} #two{color:blue}
.item:not(:target){background-color:#112233} :target{background-color:#123456}
:target + .item{width:22px} :target{height:40px!important} #two{height:80px}
''', baseUrl: 'https://gateway.example/style.css'),
        ],
        viewportWidth: 390,
        dark: false,
        fragmentTarget: target,
      ).apply(document);
      expect(result.diagnostics, isEmpty);
      expect(result.stylesByElement[target]?['color'], '#00f');
      expect(result.stylesByElement[target]?['background-color'], '#123456');
      expect(result.stylesByElement[target]?['height'], '40px');
      expect(
        result.stylesByElement[document.getElementById(
          'one',
        )]?['background-color'],
        '#123',
      );
      for (final e in document.querySelectorAll('*')) {
        expect(
          e.attributes.keys.where(
            (k) => k.toString().startsWith('data-native-css-'),
          ),
          isEmpty,
        );
        expect(e.attributes['id'], before[e]?['id']);
      }
    },
  );
  test('null target matches no positive target and negation still matches', () {
    final document = html.parse('<div class="item"></div>');
    final result = NativeDocumentStyleEngine(
      stylesheets: const [
        NativeDocumentStylesheet(
          ':target{color:red}.item:not(:target){color:blue}',
          baseUrl: 'https://gateway.example/style.css',
        ),
      ],
      viewportWidth: 390,
      dark: false,
    ).apply(document);
    expect(
      result.stylesByElement[document.querySelector('.item')]?['color'],
      '#00f',
    );
    expect(result.diagnostics, isEmpty);
  });
  test(
    'static target identity changes only for navigation, including same-URL activation',
    () {
      final document = html.parse(
        '<div id="one" data-pirc-script-id="a"></div><a name="one" data-pirc-script-id="b"></a><div id="雪" data-pirc-script-id="c"></div>',
      );
      final state = NativeDocumentTargetState('https://gateway.example/#one');
      final first = state.resolve(document)!;
      first.id = 'renamed';
      expect(state.resolve(document), same(first));
      state.navigate('https://gateway.example/#one');
      expect(state.resolve(document)?.localName, 'a');
      state.navigate('https://gateway.example/#%E9%9B%AA');
      expect(state.resolve(document)?.id, '雪');
      state.navigate('https://gateway.example/#absent');
      expect(state.resolve(document), isNull);
    },
  );
  test('authored attributes cannot forge temporary target markers', () {
    final document = html.parse(
      '<div id="one"></div><div id="fake" data-native-css-nth-0-target=""></div>',
    );
    final result = NativeDocumentStyleEngine(
      stylesheets: const [
        NativeDocumentStylesheet(
          ':target{height:60px}',
          baseUrl: 'https://gateway.example/style.css',
        ),
      ],
      viewportWidth: 390,
      dark: false,
      fragmentTarget: document.getElementById('one'),
    ).apply(document);
    expect(
      result.stylesByElement[document.getElementById('one')]?['height'],
      '60px',
    );
    expect(
      result.stylesByElement[document.getElementById('fake')]?['height'],
      isNull,
    );
    expect(
      document
          .getElementById('fake')!
          .attributes['data-native-css-nth-0-target'],
      '',
    );
  });
}
