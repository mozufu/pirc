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

Map<String, List<Map<String, Object>>> _normalize(
  Map<String, NativeDocumentTopMarginGroup> groups,
) => {
  for (final entry in groups.entries)
    entry.key: [
      for (final contribution in entry.value.contributions)
        {
          'originId': contribution.originId,
          'value': contribution.value,
          'percentage': contribution.percentage,
        },
    ],
};

const _borderedBody = <String, String>{
  'margin-top': '0px',
  'border-top-style': 'solid',
  'border-top-width': '1px',
};

void main() {
  test('nested percent groups retain every original margin contribution', () {
    final prepared = _prepare(
      '<html id="html"><body id="body"><div id="outer"><div id="middle"><div id="inner"></div></div></div></body></html>',
      {
        'body': _borderedBody,
        'outer': {'height': '60px', 'margin-top': '4%'},
        'middle': {'height': '40px', 'margin-top': '7px'},
        'inner': {'height': '10px', 'margin-top': '9%'},
      },
    );

    final groups = nativeDocumentPercentTopMarginGroups(
      document: prepared.document,
      stylesByElement: prepared.stylesByElement,
    );

    expect(_normalize(groups), {
      'outer': [
        {'originId': 'outer', 'value': 4.0, 'percentage': true},
        {'originId': 'middle', 'value': 7.0, 'percentage': false},
        {'originId': 'inner', 'value': 9.0, 'percentage': true},
      ],
      'middle': <Map<String, Object>>[],
      'inner': <Map<String, Object>>[],
    });
  });

  test('fixed-only groups remain on the existing collapsed-margin path', () {
    final prepared = _prepare(
      '<html><body id="body"><div id="parent"><div id="child"></div></div></body></html>',
      {
        'body': _borderedBody,
        'parent': {'height': '30px', 'margin-top': '5px'},
        'child': {'height': '10px', 'margin-top': '9px'},
      },
    );

    final percentGroups = nativeDocumentPercentTopMarginGroups(
      document: prepared.document,
      stylesByElement: prepared.stylesByElement,
    );
    final fixedMargins = nativeDocumentCollapsedTopMargins(
      document: prepared.document,
      stylesByElement: prepared.stylesByElement,
    );

    expect(percentGroups, isEmpty);
    expect(fixedMargins, {'parent': 9.0, 'child': 0.0});
  });

  test('body default and percent child keep separate origin IDs', () {
    final prepared = _prepare(
      '<html id="html"><body id="body"><div id="child"></div></body></html>',
      {
        'html': {'margin-top': '500px'},
        'child': {'height': '20px', 'margin-top': '10%'},
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

    final groups = nativeDocumentPercentTopMarginGroups(
      document: prepared.document,
      stylesByElement: prepared.stylesByElement,
    );

    expect(_normalize(groups), {
      'body': [
        {'originId': 'body', 'value': 8.0, 'percentage': false},
        {'originId': 'child', 'value': 10.0, 'percentage': true},
      ],
      'child': <Map<String, Object>>[],
    });
    expect(groups.containsKey('html'), isFalse);
    expect(prepared.stylesByElement, equals(originalStyles));
    for (final element in prepared.document.querySelectorAll('*')) {
      expect(element.attributes, equals(originalAttributes[element]));
    }
  });

  for (final exclusion in <({String name, String child, _StylesById styles})>[
    (
      name: 'a block formatting context',
      child: '<div id="child"></div>',
      styles: {
        'parent': {'height': '30px', 'overflow': 'hidden'},
        'child': {'height': '10px', 'margin-top': '10%'},
      },
    ),
    (
      name: 'clearance',
      child: '<div id="child"></div>',
      styles: {
        'parent': {'height': '30px', 'clear': 'both'},
        'child': {'height': '10px', 'margin-top': '10%'},
      },
    ),
    (
      name: 'a replaced control element',
      child: '<input id="child">',
      styles: {
        'parent': {'height': '30px'},
        'child': {'display': 'block', 'height': '10px', 'margin-top': '10%'},
      },
    ),
  ]) {
    test('does not plan percent collapse across ${exclusion.name}', () {
      final prepared = _prepare(
        '<html><body id="body"><div id="parent">${exclusion.child}</div></body></html>',
        {'body': _borderedBody, ...exclusion.styles},
      );

      final groups = nativeDocumentPercentTopMarginGroups(
        document: prepared.document,
        stylesByElement: prepared.stylesByElement,
      );

      expect(groups, isEmpty);
    });
  }

  test('does not build a group when a member has no current style ID', () {
    final prepared = _prepare(
      '<html><body id="body"><div id="parent"><div id="child"></div></div></body></html>',
      {
        'body': _borderedBody,
        'parent': {'height': '30px', 'margin-top': '5px'},
        'child': {'height': '10px', 'margin-top': '10%'},
      },
    );
    prepared.document
        .getElementById('child')!
        .attributes
        .remove('data-pirc-document-style');

    final groups = nativeDocumentPercentTopMarginGroups(
      document: prepared.document,
      stylesByElement: prepared.stylesByElement,
    );

    expect(groups, isEmpty);
  });
  test(
    'a positive percentage height is nonempty only through a definite height chain',
    () {
      for (final parentHeight in ['200px', 'auto']) {
        final prepared = _prepare(
          '<html><body id="body"><div id="parent"><div id="child"></div></div></body></html>',
          {
            'body': _borderedBody,
            'parent': {'height': parentHeight},
            'child': {'height': '50%', 'margin-top': '5%'},
          },
        );
        final groups = nativeDocumentPercentTopMarginGroups(
          document: prepared.document,
          stylesByElement: prepared.stylesByElement,
        );
        if (parentHeight == 'auto') {
          expect(groups, isEmpty);
        } else {
          expect(groups.keys.toSet(), {'parent', 'child'});
        }
      }
    },
  );
}
