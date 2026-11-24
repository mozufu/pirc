import 'package:flutter_test/flutter_test.dart';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html;
import 'package:pirc_render/src/document_margin_collapse.dart';

typedef _StylesById = Map<String, Map<String, String>>;

class _PreparedDocument {
  const _PreparedDocument(this.document, this.stylesByElement);

  final dom.Document document;
  final Map<dom.Element, Map<String, String>> stylesByElement;
}

_PreparedDocument _prepare(String source, [_StylesById stylesById = const {}]) {
  final document = html.parse(source);
  var generatedId = 0;
  final stylesByElement = <dom.Element, Map<String, String>>{};
  for (final element in document.querySelectorAll('*')) {
    final id = element.id;
    element.attributes['data-pirc-document-style'] = id.isEmpty
        ? 'generated-${generatedId++}'
        : id;
    stylesByElement[element] = Map<String, String>.of(
      stylesById[id] ?? const {},
    );
  }
  return _PreparedDocument(document, stylesByElement);
}

Map<String, double> _collapse(
  String source, [
  _StylesById stylesById = const {},
]) {
  final prepared = _prepare(source, stylesById);
  return nativeDocumentCollapsedTopMargins(
    document: prepared.document,
    stylesByElement: prepared.stylesByElement,
  );
}

void main() {
  test(
    'collapses a positive first-child margin onto a relative fixed-height parent',
    () {
      final collapsed = _collapse(
        '<html><body id="body"><div id="parent"><div id="child"></div></div></body></html>',
        {
          'body': {
            'margin-top': '0px',
            'border-top-style': 'solid',
            'border-top-width': '1px',
          },
          'parent': {
            'position': 'relative',
            'height': '120px',
            'margin-top': '5px',
          },
          'child': {'height': '20px', 'margin-top': '7px'},
        },
      );

      expect(collapsed, {'parent': 7, 'child': 0});
    },
  );

  test('uses postorder effective margins for nested first-child chains', () {
    final collapsed = _collapse(
      '<html><body id="body"><div id="outer"><div id="middle"><div id="inner"></div></div></div></body></html>',
      {
        'body': {
          'border-top-style': 'solid',
          'border-top-width': '1px',
          'margin-top': '0px',
        },
        'outer': {'height': '60px', 'margin-top': '1px'},
        'middle': {'height': '40px', 'margin-top': '9px'},
        'inner': {'height': '10px', 'margin-top': '13px'},
      },
    );

    expect(collapsed, {'outer': 13, 'middle': 0, 'inner': 0});
  });

  test(
    'uses the body default margin, excludes html, and leaves the cascade unchanged',
    () {
      final prepared = _prepare(
        '<html id="html"><body id="body"><div id="target"></div></body></html>',
        {
          'html': {'margin-top': '500px'},
          'target': {'height': '12px', 'margin-top': '3.5px'},
        },
      );
      final originalStyles = {
        for (final entry in prepared.stylesByElement.entries)
          entry.key: Map<String, String>.of(entry.value),
      };
      final originalAttributes = {
        for (final element in prepared.document.querySelectorAll('*'))
          element: Map<Object, String>.of(element.attributes),
      };

      final collapsed = nativeDocumentCollapsedTopMargins(
        document: prepared.document,
        stylesByElement: prepared.stylesByElement,
      );

      expect(collapsed, {'body': 8, 'target': 0});
      expect(collapsed.containsKey('html'), isFalse);
      expect(prepared.stylesByElement, equals(originalStyles));
      for (final element in prepared.document.querySelectorAll('*')) {
        expect(element.attributes, equals(originalAttributes[element]));
      }
    },
  );

  test(
    'comments and normal whitespace do not interrupt collapse; hidden boxes participate',
    () {
      final collapsed = _collapse(
        '<html><body id="body"> \n<!-- comment -->\n<div id="hidden"></div></body></html>',
        {
          'body': {'margin-top': '0px'},
          'hidden': {
            'visibility': 'hidden',
            'height': '5px',
            'margin-top': '3.5px',
          },
        },
      );

      expect(collapsed, {'body': 3.5, 'hidden': 0});
    },
  );

  test('skips display-none children when finding the first in-flow block', () {
    final collapsed = _collapse(
      '<html><body id="body"><div id="parent"><span id="gone"></span><div id="target"></div></div></body></html>',
      {
        'body': {
          'border-top-style': 'solid',
          'border-top-width': '1px',
          'margin-top': '0px',
        },
        'gone': {'display': 'none'},
        'target': {'height': '10px', 'margin-top': '12px'},
      },
    );

    expect(collapsed, {'parent': 12, 'target': 0});
  });

  test('does not collapse through a nonzero top border or padding', () {
    for (final edge in [
      {'border-top-style': 'solid', 'border-top-width': '1px'},
      {'padding-top': '2px'},
    ]) {
      final collapsed = _collapse(
        '<html><body id="body"><div id="child"></div></body></html>',
        {
          'body': {'margin-top': '0px', ...edge},
          'child': {'height': '10px', 'margin-top': '9px'},
        },
      );
      expect(collapsed, isEmpty, reason: '$edge');
    }
  });

  test(
    'a width alone does not create a border edge when border style is none',
    () {
      final collapsed = _collapse(
        '<html><body id="body"><div id="child"></div></body></html>',
        {
          'body': {
            'margin-top': '0px',
            'border-top-style': 'none',
            'border-top-width': '1px',
          },
          'child': {'height': '10px', 'margin-top': '9px'},
        },
      );

      expect(collapsed, {'body': 9, 'child': 0});
    },
  );

  for (final parentStyle in [
    {'display': 'flow-root'},
    {'display': 'flex'},
    {'display': 'grid'},
    {'overflow': 'hidden'},
    {'overflow-y': 'auto'},
    {'overflow': 'scroll'},
    {'contain': 'layout'},
    {'column-count': '1'},
    {'column-count': '2'},
    {'float': 'left'},
    {'position': 'absolute'},
    {'clear': 'both'},
    {'writing-mode': 'vertical-rl'},
  ]) {
    test(
      'does not collapse through a formatting-context or out-of-flow parent: $parentStyle',
      () {
        final collapsed = _collapse(
          '<html><body id="body"><div id="parent"><div id="child"></div></div></body></html>',
          {
            'body': {
              'margin-top': '0px',
              'border-top-style': 'solid',
              'border-top-width': '1px',
            },
            'parent': {'height': '30px', ...parentStyle},
            'child': {'height': '10px', 'margin-top': '9px'},
          },
        );
        expect(collapsed, isEmpty, reason: '$parentStyle');
      },
    );
  }

  for (final childStyle in [
    {'display': 'inline'},
    {'display': 'flex'},
    {'display': 'grid'},
    {'float': 'left'},
    {'position': 'absolute'},
    {'position': 'fixed'},
    {'clear': 'both'},
  ]) {
    test(
      'does not collapse an inline or out-of-flow first child: $childStyle',
      () {
        final collapsed = _collapse(
          '<html><body id="body"><div id="parent"><div id="child"></div></div></body></html>',
          {
            'body': {
              'margin-top': '0px',
              'border-top-style': 'solid',
              'border-top-width': '1px',
            },
            'parent': {'height': '30px'},
            'child': {'height': '10px', 'margin-top': '9px', ...childStyle},
          },
        );
        expect(collapsed, isEmpty, reason: '$childStyle');
      },
    );
  }

  for (final owner in ['parent', 'child']) {
    for (final margin in ['-1px', '10%', '1em', 'auto', 'calc(2px)']) {
      test('leaves unsupported $owner top margin $margin untouched', () {
        final collapsed = _collapse(
          '<html><body id="body"><div id="parent"><div id="child"></div></div></body></html>',
          {
            'body': {
              'margin-top': '0px',
              'border-top-style': 'solid',
              'border-top-width': '1px',
            },
            'parent': {
              'height': '30px',
              if (owner == 'parent') 'margin-top': margin,
            },
            'child': {
              'height': '10px',
              'margin-top': owner == 'child' ? margin : '9px',
            },
          },
        );
        expect(collapsed, isEmpty, reason: '$owner: $margin');
      });
    }
  }

  test(
    'does not collapse across preceding inline content or preformatted whitespace',
    () {
      final inlineContent = _collapse(
        '<html><body id="body"><div id="parent">text<div id="child"></div></div></body></html>',
        {
          'body': {
            'margin-top': '0px',
            'border-top-style': 'solid',
            'border-top-width': '1px',
          },
          'parent': {'height': '30px'},
          'child': {'height': '10px', 'margin-top': '9px'},
        },
      );
      final preformattedWhitespace = _collapse(
        '<html><body id="body"><div id="parent"> \n<div id="child"></div></div></body></html>',
        {
          'body': {
            'margin-top': '0px',
            'border-top-style': 'solid',
            'border-top-width': '1px',
          },
          'parent': {'height': '30px', 'white-space': 'pre'},
          'child': {'height': '10px', 'margin-top': '9px'},
        },
      );

      expect(inlineContent, isEmpty);
      expect(preformattedWhitespace, isEmpty);
    },
  );

  test('does not collapse through an empty child block', () {
    final collapsed = _collapse(
      '<html><body id="body"><div id="parent"><div id="empty"></div></div></body></html>',
      {
        'body': {
          'margin-top': '0px',
          'border-top-style': 'solid',
          'border-top-width': '1px',
        },
        'parent': {'margin-top': '0px'},
        'empty': {'margin-top': '9px'},
      },
    );

    expect(collapsed, isEmpty);
  });
}
