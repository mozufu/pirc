import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart' as fm;
import 'package:flutter_test/flutter_test.dart';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html;
import 'package:pirc_render_document/src/document_computed_styles.dart';
import 'package:pirc_render/src/document_element_scroll.dart';
import 'package:pirc_render/src/document_layout.dart';
import 'package:pirc_render/src/document_layout_visibility.dart';
import 'package:pirc_render/src/document_margin_collapse.dart';
import 'package:pirc_render/src/document_offsets.dart';
import 'package:pirc_render/src/html_document_styles.dart';
import 'package:pirc_render/src/html_syntax.dart';
import 'package:pirc_render/src/native_html.dart';

import 'live_test.dart' show theme;

const _fixturePath =
    'tool/parity/fixtures/document-computed-styles-chromium153.json';
const _revision = 1;

final Map<String, dynamic> _fixture =
    jsonDecode(File(_fixturePath).readAsStringSync()) as Map<String, dynamic>;

// These are the properties whose browser values have a direct native
// representation in the current computed-style packet. Any remaining fixture
// property is either asserted as a specifically named native difference or
// listed below as unrepresented; it never becomes a broad case exemption.
const _assertedProperties = <String, Map<String, Set<String>>>{
  'flex_and_grid_inline_items_are_blockified': <String, Set<String>>{
    '*': <String>{'display', 'width', 'height', 'position', 'box-sizing'},
  },
  'ua_defaults_and_block_inline_elements': <String, Set<String>>{
    '*': <String>{
      'display',
      'position',
      'box-sizing',
      'color',
      'background-color',
      'font-size',
      'font-weight',
      'font-style',
      'line-height',
      'margin-top',
      'margin-right',
      'margin-bottom',
      'margin-left',
      'padding-top',
      'padding-left',
      'width',
      'height',
      'list-style-type',
      'white-space',
      'visibility',
    },
  },
  'font_shorthand_inheritance_em_rem_and_line_height': <String, Set<String>>{
    '*': <String>{
      'font-family',
      'font-size',
      'font-weight',
      'font-style',
      'font-variant',
      'font-stretch',
      'line-height',
      'letter-spacing',
      'word-spacing',
      'text-transform',
    },
  },
  'color_current_color_and_rgba_serialization': <String, Set<String>>{
    '*': <String>{
      'color',
      'background-color',
      'border-top-color',
      'border-right-color',
      'border-bottom-color',
      'border-left-color',
      'opacity',
    },
  },
  'content_box_and_border_box_dimensions': <String, Set<String>>{
    '*': <String>{
      'display',
      'box-sizing',
      'width',
      'height',
      'min-width',
      'max-width',
      'min-height',
      'max-height',
      'padding-top',
      'padding-right',
      'padding-bottom',
      'padding-left',
      'border-top-width',
      'border-right-width',
      'margin-top',
      'margin-left',
    },
  },
  'percentage_margin_padding_use_containing_block_width': <String, Set<String>>{
    '*': <String>{
      'box-sizing',
      'width',
      'height',
      'margin-top',
      'margin-right',
      'margin-bottom',
      'margin-left',
      'padding-top',
      'padding-right',
      'padding-bottom',
      'padding-left',
      'border-left-width',
    },
  },
  'relative_insets_and_directional_overconstraint': <String, Set<String>>{
    '*': <String>{
      'display',
      'position',
      'direction',
      'top',
      'right',
      'bottom',
      'left',
      'width',
      'height',
      'margin-top',
      'margin-left',
    },
  },
  'relative_insets_with_auto_height_containing_block': <String, Set<String>>{
    '*': <String>{
      'position',
      'top',
      'right',
      'bottom',
      'left',
      'width',
      'height',
      'margin-top',
      'margin-left',
    },
  },
  'display_none_and_disconnected_elements': <String, Set<String>>{
    '*': <String>{
      'display',
      'position',
      'width',
      'height',
      'color',
      'font-size',
      'visibility',
    },
    'hiddenChild': <String>{'--token'},
  },
  'custom_properties_inheritance_and_var_fallback': <String, Set<String>>{
    '*': <String>{
      '--theme',
      '--surface',
      'color',
      'background-color',
      'border-top-color',
    },
    'parent': <String>{'--local'},
    'child': <String>{'--local'},
    'fallback': <String>{'--local'},
  },
  'cssom_readonly_declaration_and_property_iteration': <String, Set<String>>{
    '*': <String>{
      'color',
      'background-color',
      'font-size',
      'font-family',
      'line-height',
      'margin-top',
      'padding-left',
      'width',
      'height',
      'box-sizing',
    },
  },
  'class_and_inline_style_mutation_update_retained_declaration':
      <String, Set<String>>{
        '*': <String>{
          'color',
          'background-color',
          'width',
          'height',
          'display',
          'font-size',
        },
      },
};

const _knownNativeDifferences = <String, Map<String, Map<String, String>>>{
  'ua_defaults_and_block_inline_elements': <String, Map<String, String>>{
    'html': <String, String>{
      'font-family':
          'Chromium resolves its UA generic family to Times; the '
          'native document baseline retains the generic serif family.',
      'height':
          'The native UA document flow reports this root auto-height; the '
          'difference may include default body-margin and line-box behavior.',
    },
    'body': <String, String>{
      'font-family':
          'Chromium resolves its UA generic family to Times; the '
          'native document baseline retains the generic serif family.',
      'height':
          'The native UA document flow reports this body auto-height; the '
          'difference may include default body-margin and line-box behavior.',
    },
    'block': <String, String>{
      'font-family':
          'Chromium resolves its UA generic family to Times; the '
          'native document baseline retains the generic serif family.',
    },
    'inline': <String, String>{
      'font-family':
          'Chromium resolves its UA generic family to Times; the '
          'native document baseline retains the generic serif family.',
    },
    'paragraph': <String, String>{
      'font-family':
          'Chromium resolves its UA generic family to Times; the '
          'native document baseline retains the generic serif family.',
      'height':
          'The platform serif text line box is 2px shorter than the '
          'Chromium Times line box for this paragraph.',
    },
    'heading': <String, String>{
      'font-family':
          'Chromium resolves its UA generic family to Times; the '
          'native document baseline retains the generic serif family.',
      'height':
          'The platform serif text line box is 5px shorter than the '
          'Chromium Times line box for this heading.',
    },
    'list': <String, String>{
      'font-family':
          'Chromium resolves its UA generic family to Times; the '
          'native document baseline retains the generic serif family.',
      'height':
          'The platform serif text line box makes this list auto-height '
          '2px shorter than Chromium Times.',
    },
    'listItem': <String, String>{
      'font-family':
          'Chromium resolves its UA generic family to Times; the '
          'native document baseline retains the generic serif family.',
    },
  },
  'font_shorthand_inheritance_em_rem_and_line_height':
      <String, Map<String, String>>{
        'html': <String, String>{
          'font-family':
              'The authored root font shorthand computes to Times in '
              'Chromium; the native baseline retains generic serif.',
        },
      },
};

// Record only the exact UA auto-height observations at both captured widths.
// Root/body values may reflect flow and default body-margin behavior; inline
// text targets retain normal exact checks except for their measured text boxes.
const _knownNativeGeometryValues = <String, Map<String, Map<String, String>>>{
  'ua_defaults_and_block_inline_elements': <String, Map<String, String>>{
    'html': <String, String>{'height': '197.88px'},
    'body': <String, String>{'height': '173.88px'},
    'paragraph': <String, String>{'height': '16px'},
    'heading': <String, String>{'height': '32px'},
    'list': <String, String>{'height': '16px'},
  },
};

const _knownChromiumGeometryValues = <String, Map<String, Map<String, String>>>{
  'ua_defaults_and_block_inline_elements': <String, Map<String, String>>{
    'html': <String, String>{'height': '184.875px'},
    'body': <String, String>{'height': '152.875px'},
    'paragraph': <String, String>{'height': '18px'},
    'heading': <String, String>{'height': '37px'},
    'list': <String, String>{'height': '18px'},
  },
};

const _unrepresentedProperties = <String, Map<String, String>>{
  'ua_defaults_and_block_inline_elements': <String, String>{},
  'font_shorthand_inheritance_em_rem_and_line_height': <String, String>{
    'font':
        'The CSS font shorthand serialization is outside the native '
        'computed-style property surface.',
  },
  'color_current_color_and_rgba_serialization': <String, String>{
    'fill': 'SVG paint defaults are not represented for these HTML boxes.',
  },
  'display_none_and_disconnected_elements': <String, String>{
    '--token':
        'An unset custom property is serialized as an empty browser '
        'value and omitted from the native snapshot.',
  },
  'custom_properties_inheritance_and_var_fallback': <String, String>{
    '--missing':
        'An unset custom property is serialized as an empty browser '
        'value and omitted from the native snapshot.',
    '--local':
        'The inherited custom property is unset on the root and body; '
        'their empty browser values are omitted from the native snapshot.',
  },
};

const _unrepresentedTargets = <String, Map<String, String>>{
  'ua_defaults_and_block_inline_elements': <String, String>{
    'button':
        'Chromium form-control UA values are host-platform dependent; '
        'none of this target’s supportedProperties are requested from the '
        'native computed-style surface.',
  },
};

const _unrepresentedPropertiesByTarget =
    <String, Map<String, Map<String, String>>>{
      'ua_defaults_and_block_inline_elements': <String, Map<String, String>>{
        'listItem': <String, String>{
          'width':
              'A list-item is emitted as multiple core fragments rather than '
              'one measured RenderBox; native width is therefore omitted.',
          'height':
              'A list-item is emitted as multiple core fragments rather than '
              'one measured RenderBox; native height is therefore omitted.',
        },
      },
    };

const _unrepresentedTargetProperties = <String, Map<String, Set<String>>>{
  'ua_defaults_and_block_inline_elements': <String, Set<String>>{
    'button': <String>{
      'display',
      'position',
      'box-sizing',
      'color',
      'background-color',
      'font-family',
      'font-size',
      'font-weight',
      'font-style',
      'line-height',
      'margin-top',
      'margin-right',
      'margin-bottom',
      'margin-left',
      'padding-top',
      'padding-left',
      'width',
      'height',
      'list-style-type',
      'white-space',
      'visibility',
    },
  },
};

void main() {
  for (final raw in _fixture['cases'] as List) {
    final capture = raw as Map<String, dynamic>;
    final name = capture['name'] as String;
    if (!_assertedProperties.containsKey(name)) continue;
    final viewport = Size(
      (capture['viewportWidth'] as num).toDouble(),
      (capture['viewportHeight'] as num).toDouble(),
    );

    testWidgets(
      'Native computed styles match Chromium: $name ${viewport.width.toInt()}',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = viewport;
        addTearDown(tester.view.reset);

        final prepared = _prepareDocument(capture, viewport);
        final layout = NativeDocumentLayoutController();
        final elementScroll = NativeDocumentElementScrollController();
        final windowScroll = ScrollController();
        addTearDown(layout.dispose);
        addTearDown(elementScroll.dispose);
        addTearDown(windowScroll.dispose);

        try {
          await tester.pumpWidget(
            MaterialApp(
              theme: theme.build(Brightness.light),
              home: Align(
                alignment: Alignment.topLeft,
                child: SizedBox(
                  width: viewport.width,
                  height: viewport.height,
                  child: SingleChildScrollView(
                    controller: windowScroll,
                    child: NativeHtmlDocument(
                      key: ValueKey('computed-style-$name'),
                      nodes: [NativeHtmlRaw(prepared.markup)],
                      style: const TextStyle(
                        inherit: false,
                        fontFamily: 'serif',
                        fontSize: 16,
                        height: kTextHeightNone,
                        color: Colors.black,
                        letterSpacing: 0,
                      ),
                      styles: fm.MarkdownStyleSheet(),
                      builders: const {},
                      markdownStyles: false,
                      imageViewport: viewport,
                      authorStylesBuilder: (element) =>
                          prepared.stylesByKey[element
                              .attributes['data-pirc-document-style']],
                      layoutController: layout,
                      elementScrollController: elementScroll,
                      layoutRevision: _revision,
                      layoutKnownIds: prepared.ids,
                      layoutNoBoxIds: prepared.noBoxIds,
                      layoutComputedStyles: prepared.computedStyleSpecs,
                      layoutOffsetSpecs: prepared.offsetSpecs,
                      documentTopMargins: prepared.documentTopMargins,
                      documentPercentTopMargins:
                          prepared.documentPercentTopMargins,
                    ),
                  ),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();

          final packet = layout.capture(
            revision: _revision,
            generation: 1,
            viewport: viewport,
            scrollOffset: Offset(
              0,
              windowScroll.hasClients ? windowScroll.offset : 0,
            ),
            elementScrollMetrics: elementScroll.metricsFor,
            scrollEvents: elementScroll.pendingScrollEvents,
          );
          expect(packet, isNotNull, reason: '$name layout is ready');
          _expectStyles(capture: capture, ids: prepared.ids, packet: packet!);
          expect(tester.takeException(), isNull, reason: name);
        } finally {
          await tester.pumpWidget(const SizedBox.shrink());
        }
      },
    );
  }
}

void _expectStyles({
  required Map<String, dynamic> capture,
  required Set<String> ids,
  required Map<String, dynamic> packet,
}) {
  final name = capture['name'] as String;
  final expectedById = capture['expected'] as Map<String, dynamic>;
  final boxes = {
    for (final box in (packet['boxes'] as List).cast<Map<String, dynamic>>())
      box['id'] as String: box,
  };
  expect(boxes.keys.toSet(), ids, reason: '$name target IDs');

  final propertyMap = _assertedProperties[name]!;
  final fixtureProperties = (capture['supportedProperties'] as List)
      .cast<String>()
      .toSet();
  final explicitlyUnrepresented =
      _unrepresentedProperties[name] ?? const <String, String>{};
  final knownDifferences =
      _knownNativeDifferences[name] ?? const <String, Map<String, String>>{};

  for (final id in ids) {
    final browser = expectedById[id] as Map<String, dynamic>;
    final browserValues = browser['values'] as Map<String, dynamic>;
    final nativeBox = boxes[id]!;
    final nativeValues =
        nativeBox['computedStyle'] as Map<String, dynamic>? ??
        const <String, dynamic>{};
    final selected = <String>{...?propertyMap['*'], ...?propertyMap[id]};
    final unrepresentedForTarget =
        _unrepresentedPropertiesByTarget[name]?[id] ?? const <String, String>{};
    final idDifferences = knownDifferences[id] ?? const <String, String>{};
    expect(
      fixtureProperties,
      containsAll(selected),
      reason: '$name selected fixture properties for #$id',
    );

    for (final property in fixtureProperties) {
      if (unrepresentedForTarget.containsKey(property)) {
        expect(
          selected,
          contains(property),
          reason: '$name explicitly selected unsupported target property',
        );
        expect(
          browserValues,
          contains(property),
          reason: 'Chromium expected #$id $property',
        );
        expect(
          nativeValues,
          isNot(contains(property)),
          reason:
              '$name explicitly omits #$id $property: ${unrepresentedForTarget[property]!}',
        );
      } else if (selected.contains(property)) {
        expect(
          browserValues,
          contains(property),
          reason: 'Chromium expected #$id $property',
        );
        expect(
          nativeValues,
          contains(property),
          reason: 'native snapshot omitted #$id $property',
        );
        final nativeValue = nativeValues[property] as String;
        final browserValue = browserValues[property] as String;
        if (idDifferences.containsKey(property)) {
          if (property == 'font-family') {
            expect(
              browserValue,
              'Times',
              reason: '$name captured generic-font difference for #$id',
            );
            expect(
              nativeValue,
              'serif',
              reason: '$name native generic family for #$id',
            );
          } else {
            final knownNativeValue =
                _knownNativeGeometryValues[name]?[id]?[property];
            expect(
              knownNativeValue,
              isNotNull,
              reason: '$name has no concrete recorded value for #$id $property',
            );
            final knownBrowserValue =
                _knownChromiumGeometryValues[name]?[id]?[property];
            expect(
              browserValue,
              knownBrowserValue,
              reason: '$name captured Chromium value for #$id $property',
            );
            expect(
              nativeValue,
              knownNativeValue,
              reason:
                  '$name recorded native value for #$id $property: ${idDifferences[property]!}',
            );
          }
        } else if (property.startsWith('--')) {
          _expectCustomTokenValue(
            nativeValue,
            browserValue,
            reason: '$name #$id $property',
          );
        } else {
          _expectCssValue(
            nativeValue,
            browserValue,
            reason: '$name #$id $property',
          );
        }
      } else if (idDifferences.containsKey(property)) {
        final actual = nativeValues[property];
        expect(
          browserValues[property],
          'Times',
          reason: '$name recorded Chromium family difference for #$id',
        );
        expect(actual, 'serif', reason: '$name native generic family for #$id');
      } else if (explicitlyUnrepresented.containsKey(property)) {
        expect(
          nativeValues,
          isNot(contains(property)),
          reason:
              '$name unrepresented #$id $property: ${explicitlyUnrepresented[property]!}',
        );
      } else {
        fail(
          '$name has no assertion or explicit support boundary for #$id $property',
        );
      }
    }

    if (name == 'display_none_and_disconnected_elements' &&
        id == 'hiddenParent') {
      expect(
        nativeValues,
        isNot(contains('--token')),
        reason: 'an unset custom property is omitted from #hiddenParent',
      );
    }
    if (name == 'custom_properties_inheritance_and_var_fallback' &&
        (id == 'html' || id == 'body')) {
      expect(
        nativeValues,
        isNot(contains('--local')),
        reason: 'unset inherited --local is omitted from #$id',
      );
    }
  }

  // These targets are deliberately detached in the Chromium capture. The
  // native layout surface only reports connected DOM nodes.
  if (name == 'display_none_and_disconnected_elements') {
    expect(ids, isNot(contains('removed')));
    expect(ids, isNot(contains('neverConnected')));
  }
  if (name == 'ua_defaults_and_block_inline_elements') {
    for (final entry in _unrepresentedPropertiesByTarget[name]!.entries) {
      expect(ids, contains(entry.key));
      expect(
        entry.value.keys.toSet(),
        equals(<String>{'width', 'height'}),
        reason: 'only list-item geometry is omitted for #${entry.key}',
      );
    }
    // Chromium's form-control UA styles depend on the host. Keep the button
    // in the document but outside this computed-style snapshot.
    expect(ids, isNot(contains('button')));
    final omittedTargets = (capture['targets'] as List)
        .cast<String>()
        .toSet()
        .difference(ids);
    expect(omittedTargets, equals(_unrepresentedTargets[name]!.keys.toSet()));
    final targetReason = _unrepresentedTargets[name]!['button']!;
    final unsupportedButtonProperties =
        _unrepresentedTargetProperties[name]!['button']!;
    expect(unsupportedButtonProperties, equals(fixtureProperties));
    for (final property in unsupportedButtonProperties) {
      expect(
        targetReason,
        contains('supportedProperties'),
        reason: 'Chromium #button $property exclusion is documented',
      );
    }
  }
}

void _expectCssValue(String actual, String browser, {required String reason}) {
  final actualPx = RegExp(r'^(-?\d+(?:\.\d+)?)px$').firstMatch(actual);
  final browserPx = RegExp(r'^(-?\d+(?:\.\d+)?)px$').firstMatch(browser);
  if (actualPx != null && browserPx != null) {
    final actualNumber = double.parse(actualPx.group(1)!);
    final browserNumber = double.parse(browserPx.group(1)!);
    expect(
      (actualNumber - browserNumber).abs(),
      lessThanOrEqualTo(.02),
      reason: '$reason native=$actual Chromium=$browser',
    );
    return;
  }
  expect(actual, browser, reason: reason);
}

void _expectCustomTokenValue(
  String actual,
  String browser, {
  required String reason,
}) {
  // The native cascade serializer inserts spaces after commas in functional
  // tokens, while Chromium preserves the authored custom-property token
  // spacing. Compare the token values after this narrowly scoped whitespace
  // normalization; ordinary computed colors still require exact serialization.
  String normalizeFunctionalCommas(String value) =>
      value.trim().replaceAll(RegExp(r'\s*,\s*'), ',');

  expect(
    normalizeFunctionalCommas(actual),
    normalizeFunctionalCommas(browser),
    reason: '$reason (custom-token comma whitespace only)',
  );
}

class _PreparedDocument {
  const _PreparedDocument({
    required this.markup,
    required this.ids,
    required this.stylesByKey,
    required this.noBoxIds,
    required this.computedStyleSpecs,
    required this.offsetSpecs,
    required this.documentTopMargins,
    required this.documentPercentTopMargins,
  });

  final String markup;
  final Set<String> ids;
  final Map<String, Map<String, String>> stylesByKey;
  final Set<String> noBoxIds;
  final Map<String, NativeDocumentComputedStyleSpec> computedStyleSpecs;
  final Map<String, NativeDocumentOffsetSpec> offsetSpecs;
  final Map<String, double> documentTopMargins;
  final Map<String, NativeDocumentTopMarginGroup> documentPercentTopMargins;
}

_PreparedDocument _prepareDocument(
  Map<String, dynamic> capture,
  Size viewport,
) {
  final document = html.parse(capture['authoredHTML'] as String);
  final root = document.documentElement!;
  final body = document.body!;
  final expectedById = capture['expected'] as Map<String, dynamic>;

  // Recreate the browser capture's detached fixture nodes before computing the
  // document snapshot. Disconnected styles are outside NativeHtmlDocument's
  // layout-backed computed-style surface.
  for (final entry in expectedById.entries) {
    final expected = entry.value as Map<String, dynamic>;
    if (expected['isConnected'] == false) {
      document.getElementById(entry.key)?.remove();
    }
  }
  final ids = <String>{};
  for (final entry in expectedById.entries) {
    if (entry.value['isConnected'] != true) continue;
    if (capture['name'] == 'ua_defaults_and_block_inline_elements' &&
        entry.key == 'button') {
      continue;
    }
    final element = document.getElementById(entry.key);
    if (element == null) continue;
    element.attributes['data-pirc-script-id'] = entry.key;
    ids.add(entry.key);
  }

  final captureSettings = _fixture['capture'] as Map<String, dynamic>;
  final cascade = NativeDocumentStyleEngine(
    stylesheets: [
      for (final style in document.querySelectorAll('style'))
        NativeDocumentStylesheet(
          style.text,
          baseUrl: 'https://computed-styles.example/',
        ),
    ],
    viewportWidth: viewport.width,
    viewportHeight: viewport.height,
    devicePixelRatio: (captureSettings['deviceScaleFactor'] as num).toDouble(),
    dark: false,
  ).apply(document);
  final stylesByElement = <dom.Element, Map<String, String>>{
    for (final element in document.querySelectorAll('*'))
      element: {
        if (identical(element, body)) 'margin': '8px',
        ...?cascade.stylesByElement[element],
      },
  };
  final computedStyleSpecs = nativeDocumentComputedStyleSpecs(
    document: document,
    stylesByElement: stylesByElement,
    viewportWidth: viewport.width,
    viewportHeight: viewport.height,
    dark: false,
  );
  final noBoxIds = nativeDocumentNoBoxIds(
    document: document,
    knownIds: ids,
    stylesByElement: stylesByElement,
  );
  final offsetSpecs = nativeDocumentOffsetSpecs(
    document: document,
    stylesByElement: stylesByElement,
  );

  final stylesByKey = <String, Map<String, String>>{};
  var nextStyleKey = 0;
  for (final element in document.querySelectorAll('*')) {
    final key = (nextStyleKey++).toString();
    element.attributes['data-pirc-document-style'] = key;
    stylesByKey[key] = Map<String, String>.of(stylesByElement[element]!);
    element.attributes.remove('style');
  }

  String attrs(dom.Element element) => element.attributes.entries
      .map(
        (entry) => ' ${entry.key}="${const HtmlEscape().convert(entry.value)}"',
      )
      .join();

  return _PreparedDocument(
    markup:
        '<div${attrs(root)}><div${attrs(body)}>${body.innerHtml}</div></div>',
    ids: ids,
    stylesByKey: stylesByKey,
    noBoxIds: noBoxIds,
    computedStyleSpecs: computedStyleSpecs,
    offsetSpecs: offsetSpecs,
    documentTopMargins: nativeDocumentCollapsedTopMargins(
      document: document,
      stylesByElement: stylesByElement,
    ),
    documentPercentTopMargins: nativeDocumentPercentTopMarginGroups(
      document: document,
      stylesByElement: stylesByElement,
    ),
  );
}
