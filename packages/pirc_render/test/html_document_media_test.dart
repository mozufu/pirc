import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:html/parser.dart' as html;
import 'package:pirc_render/src/html_document_styles.dart';

void main() {
  final oracle =
      jsonDecode(
            File(
              'test/fixtures/parity/document-media-chromium153.json',
            ).readAsStringSync(),
          )
          as Map<String, dynamic>;
  final cases = <dynamic>[
    ...oracle['viewportMatrix']['cases'],
    ...oracle['resolutionContexts'],
    ...oracle['touchContext']['cases'],
  ];
  const deferred = {
    'or-width-height',
    'range-width-chain',
    'range-width-and',
    'or-width-height-range',
    'parenthesized-not-unknown-feature',
    'not-invalid-width-range-value',
    'invalid-comma-valid-width-branch',
    'range-width-ge-600',
  };
  for (final row in cases) {
    test('classic CSS media matches frozen Chromium ${row['id']}', () {
      final config = row['configured'] as Map;
      final observations = (row['queryObservations'] as List)
          .where((dynamic item) => !deferred.contains(item['id']))
          .toList();
      for (final outerMedia in [false, true]) {
        final document = html.parse(
          '<html><head></head><body>${List.generate(observations.length, (index) => '<div id="q$index"></div>').join()}</body></html>',
        );
        final sheets = <NativeDocumentStylesheet>[];
        for (var index = 0; index < observations.length; index++) {
          final query = observations[index]['query'] as String;
          final declaration = '#q$index { width: 123px; }';
          sheets.add(
            NativeDocumentStylesheet(
              outerMedia || query.isEmpty
                  ? declaration
                  : '@media $query { $declaration }',
              baseUrl: 'https://media.test/q$index.css',
              media: outerMedia ? query : null,
            ),
          );
        }
        final result = NativeDocumentStyleEngine(
          stylesheets: sheets,
          viewportWidth: (row['innerWidth'] as num).toDouble(),
          viewportHeight: (row['innerHeight'] as num).toDouble(),
          devicePixelRatio: (row['devicePixelRatio'] as num).toDouble(),
          dark: config['colorScheme'] == 'dark',
          reducedMotion: config['reducedMotion'] == 'reduce',
          pointer: config['hasTouch'] == true ? 'coarse' : 'fine',
          hover: config['hasTouch'] == true ? 'none' : 'hover',
        ).apply(document);
        for (var index = 0; index < observations.length; index++) {
          final observation = observations[index];
          final element = document.querySelector('#q$index')!;
          expect(
            result.stylesByElement[element]?['width'] == '123px',
            observation['cssApplied'],
            reason:
                '${row['id']} outer=$outerMedia ${observation['id']}: ${observation['query']}',
          );
        }
      }
    });
  }

  test('common media types, operators, and environment features match', () {
    final result = _apply(
      '''
      @media screen { #screen { width: 101px; } }
      @media all { #all { width: 102px; } }
      @media print { #print { width: 103px; } }
      @media not print { #not-print { width: 104px; } }
      @media only screen and (min-width: 600px) {
        #only-and { width: 105px; }
      }
      @media (width: 600px), (min-width: 900px) {
        #comma { width: 106px; }
      }
      @media (min-width: 37.5em) and (max-width: 37.5rem) {
        #em-rem { width: 107px; }
      }
      @media (max-width: 599px) { #width-fail { width: 108px; } }
      @media (min-height: 50em) and (height: 800px) {
        #height { width: 109px; }
      }
      @media (max-height: 799px) { #height-fail { width: 110px; } }
      @media (orientation: portrait) { #portrait { width: 111px; } }
      @media (orientation: landscape) { #landscape { width: 112px; } }
      @media (resolution: 2dppx) { #resolution-dppx { width: 113px; } }
      @media (min-resolution: 192dpi) {
        #resolution-dpi { width: 114px; }
      }
      @media (max-resolution: 192dpcm) {
        #resolution-dpcm { width: 115px; }
      }
      @media (aspect-ratio: 3/4) { #aspect { width: 116px; } }
      @media (min-aspect-ratio: 1/2) and (max-aspect-ratio: 3/4) {
        #aspect-range { width: 117px; }
      }
      @media (prefers-reduced-motion: reduce) {
        #motion-reduce { width: 118px; }
      }
      @media (prefers-reduced-motion: no-preference) {
        #motion-none { width: 119px; }
      }
      @media (pointer: coarse) and (any-pointer: coarse) {
        #pointer { width: 120px; }
      }
      @media (pointer: fine) { #pointer-fine { width: 121px; } }
      @media (hover: none) and (any-hover: none) {
        #hover { width: 122px; }
      }
      @media (hover: hover) { #hover-hover { width: 123px; } }
      @media (prefers-color-scheme: dark) {
        #dark { width: 124px; }
      }
      @media (prefers-color-scheme: no-preference) {
        #scheme-no-preference { width: 125px; }
      }
    ''',
      viewportWidth: 600,
      viewportHeight: 800,
      devicePixelRatio: 2,
      reducedMotion: true,
      pointer: 'coarse',
      hover: 'none',
      dark: true,
    );
    final widths = _widths(result);

    for (final id in [
      'screen',
      'all',
      'not-print',
      'only-and',
      'comma',
      'em-rem',
      'height',
      'portrait',
      'resolution-dppx',
      'resolution-dpi',
      'resolution-dpcm',
      'aspect',
      'aspect-range',
      'motion-reduce',
      'pointer',
      'hover',
      'dark',
    ]) {
      expect(widths[id], isNotNull, reason: '$id should match');
    }
    for (final id in [
      'print',
      'width-fail',
      'height-fail',
      'landscape',
      'motion-none',
      'pointer-fine',
      'hover-hover',
      'scheme-no-preference',
    ]) {
      expect(widths[id], isNull, reason: '$id should not match');
    }
  });

  test(
    'default media environment is stable and empty sheet media is active',
    () {
      final document = html.parse('<div id="target"></div>');
      final result = NativeDocumentStyleEngine(
        stylesheets: [
          NativeDocumentStylesheet(
            '@media (min-height: 844px) and (resolution: 1dppx) and '
            '(pointer: coarse) and (hover: none) and '
            '(prefers-reduced-motion: no-preference) { '
            '#target { width: 201px; } }',
            baseUrl: 'https://media.test/default.css',
          ),
          NativeDocumentStylesheet(
            '@media (prefers-color-scheme: no-preference) { '
            '#target { max-width: 203px; } }',
            baseUrl: 'https://media.test/scheme.css',
          ),
          const NativeDocumentStylesheet(
            '#target { height: 202px; }',
            baseUrl: 'https://media.test/empty.css',
            media: '',
          ),
        ],
        viewportWidth: 390,
        dark: false,
      ).apply(document);

      final style = result.stylesByElement[document.querySelector('#target')]!;
      expect(style['width'], '201px');
      expect(style['max-width'], isNull);
      expect(style['height'], '202px');
    },
  );

  test('unknown features stay inactive under not, unknown types invert', () {
    final result = _apply(
      '''
      @media not (unknown-feature) {
        #unknown-feature { width: 301px; }
      }
      @media not all and (unknown-feature) {
        #unknown-after-not { width: 305px; }
      }
      @media not nonsense { #unknown-type { width: 302px; } }
      @media not (width: bogus) { #invalid-value { width: 303px; } }
      @media (width: bogus), screen {
        #valid-comma-branch { width: 304px; }
      }
    ''',
      viewportWidth: 390,
      viewportHeight: 844,
      devicePixelRatio: 1,
      reducedMotion: false,
      pointer: 'coarse',
      hover: 'none',
      dark: false,
    );
    final widths = _widths(result);

    expect(widths['unknown-feature'], isNull);
    expect(widths['unknown-after-not'], isNull);
    expect(widths['unknown-type'], isNotNull);
    expect(widths['invalid-value'], isNull);
    expect(widths['valid-comma-branch'], isNotNull);
    expect(
      result.diagnostics.any(
        (diagnostic) => diagnostic.code == 'unsupported-media-feature',
      ),
      isTrue,
    );
  });

  test('MQ4 range, or, and nested conditions do not partially activate', () {
    final result = _apply(
      '''
      #valid-before { width: 404px; }
      @media (min-width: 500px) {
        #valid-media-sibling { width: 405px; }
      }
      @media (width >= 390px) { #range { width: 401px; } }
      @media (min-width: 500px) or (max-width: 700px) {
        #or { width: 402px; }
      }
      @media (not (max-width: 700px)) {
        #nested { width: 403px; }
      }
      #valid-after { width: 406px; }
    ''',
      viewportWidth: 600,
      viewportHeight: 800,
      devicePixelRatio: 2,
      reducedMotion: true,
      pointer: 'coarse',
      hover: 'none',
      dark: true,
    );

    final widths = _widths(result);
    expect(widths['valid-before'], isNotNull);
    expect(widths['valid-media-sibling'], isNotNull);
    expect(widths['valid-after'], isNotNull);
    expect(widths['range'], isNull);
    expect(widths['or'], isNull);
    expect(widths['nested'], isNull);
    expect(
      result.diagnostics.any(
        (diagnostic) =>
            diagnostic.code == 'unsupported-media-syntax' ||
            diagnostic.code == 'unsupported-media-feature' ||
            diagnostic.code == 'css-parse-error',
      ),
      isTrue,
    );
  });
}

NativeDocumentStylesResult _apply(
  String cssText, {
  required double viewportWidth,
  required double viewportHeight,
  required double devicePixelRatio,
  required bool reducedMotion,
  required String pointer,
  required String hover,
  required bool dark,
}) {
  final document = html.parse(
    '<div id="screen"></div>'
    '<div id="all"></div>'
    '<div id="print"></div>'
    '<div id="not-print"></div>'
    '<div id="only-and"></div>'
    '<div id="comma"></div>'
    '<div id="em-rem"></div>'
    '<div id="width-fail"></div>'
    '<div id="height"></div>'
    '<div id="height-fail"></div>'
    '<div id="portrait"></div>'
    '<div id="landscape"></div>'
    '<div id="resolution-dppx"></div>'
    '<div id="resolution-dpi"></div>'
    '<div id="resolution-dpcm"></div>'
    '<div id="aspect"></div>'
    '<div id="aspect-range"></div>'
    '<div id="motion-reduce"></div>'
    '<div id="motion-none"></div>'
    '<div id="pointer"></div>'
    '<div id="pointer-fine"></div>'
    '<div id="hover"></div>'
    '<div id="hover-hover"></div>'
    '<div id="dark"></div>'
    '<div id="scheme-no-preference"></div>'
    '<div id="unknown-feature"></div>'
    '<div id="unknown-after-not"></div>'
    '<div id="unknown-type"></div>'
    '<div id="invalid-value"></div>'
    '<div id="valid-comma-branch"></div>'
    '<div id="range"></div>'
    '<div id="or"></div>'
    '<div id="nested"></div>'
    '<div id="valid-before"></div>'
    '<div id="valid-media-sibling"></div>'
    '<div id="valid-after"></div>',
  );
  return NativeDocumentStyleEngine(
    stylesheets: [
      NativeDocumentStylesheet(
        cssText,
        baseUrl: 'https://media.test/style.css',
      ),
    ],
    viewportWidth: viewportWidth,
    viewportHeight: viewportHeight,
    devicePixelRatio: devicePixelRatio,
    reducedMotion: reducedMotion,
    pointer: pointer,
    hover: hover,
    dark: dark,
  ).apply(document);
}

Map<String, String?> _widths(NativeDocumentStylesResult result) => {
  for (final entry in result.stylesByElement.entries)
    if (entry.key.attributes.containsKey('id'))
      entry.key.attributes['id']!: entry.value['width'],
};
