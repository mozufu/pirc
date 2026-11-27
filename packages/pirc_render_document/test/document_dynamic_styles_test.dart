@Tags(['tier3'])
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_render_document/src/document_dynamic_styles.dart';
import 'package:pirc_render_document/src/document_style_loading.dart';
import 'package:pirc_render/src/html_document_styles.dart';

const _baseUrl = 'https://example.test/page/';

Map<String, dynamic> _inline({
  required String ownerId,
  required int order,
  required String cssText,
  int revision = 0,
  String? transportId,
  String? media,
  bool disabled = false,
  String baseUrl = _baseUrl,
  String? crossOrigin,
  String? integrity,
  String? referrerPolicy,
  String? referrerUrl = 'https://example.test/page/document',
}) => {
  'ownerId': ownerId,
  'id': '$ownerId-dom',
  'order': order,
  'revision': revision,
  'requestId': '$ownerId:$revision',
  'transportId': transportId ?? 'stylesheet-$order',
  'baseURL': baseUrl,
  'disabled': disabled,
  'media': media,
  'cssText': cssText,
  'isStylesheet': true,
  'crossOrigin': crossOrigin,
  'integrity': integrity,
  'referrerPolicy': referrerPolicy,
  'stylesheetReferrerUrl': referrerUrl,
};

Map<String, dynamic> _link({
  required String ownerId,
  required int order,
  required String fetchHref,
  int revision = 0,
  String? transportId,
  String? media,
  bool disabled = false,
  bool requestable = true,
  bool isStylesheet = true,
  String baseUrl = _baseUrl,
  String? crossOrigin,
  String? integrity,
  String? referrerPolicy,
  String? referrerUrl = 'https://example.test/page/document',
}) => {
  'ownerId': ownerId,
  'id': '$ownerId-dom',
  'order': order,
  'revision': revision,
  'requestId': '$ownerId:$revision',
  'transportId': transportId ?? 'stylesheet-$order',
  'baseURL': baseUrl,
  'disabled': disabled,
  'media': media,
  'href': fetchHref,
  'fetchHref': fetchHref,
  'requestable': requestable,
  'isStylesheet': isStylesheet,
  'crossOrigin': crossOrigin,
  'integrity': integrity,
  'referrerPolicy': referrerPolicy,
  'stylesheetReferrerUrl': referrerUrl,
};

NativeLoadedDocumentStyles _loaded(
  List<NativeDocumentStylesheet> stylesheets, {
  List<String> diagnostics = const [],
  bool loaded = true,
}) => NativeLoadedDocumentStyles(stylesheets, diagnostics, loaded: loaded);

NativeStylesheetRequestOptions _requestOptions({
  String? crossOrigin,
  String? integrity,
  String? referrerPolicy,
  String referrerUrl = 'https://example.test/page/document',
}) => NativeStylesheetRequestOptions(
  crossOrigin: crossOrigin,
  integrity: integrity,
  referrerPolicy: referrerPolicy,
  referrerUrl: referrerUrl,
);

void main() {
  test(
    'inline CSS is immediate; links join by document order on completion',
    () {
      final controller = NativeDynamicDocumentStyles();
      final link = _link(
        ownerId: 'owner-link',
        order: 1,
        fetchHref: 'https://example.test/page/a.css',
        media: 'screen',
      );
      final inline = _inline(
        ownerId: 'owner-inline',
        order: 2,
        cssText: 'p { color: red; }',
        media: 'print',
      );
      final disabled = _inline(
        ownerId: 'owner-disabled',
        order: 3,
        cssText: 'p { color: blue; }',
        disabled: true,
      );

      controller.update({
        'sheets': [inline, disabled],
        'links': [link],
      });

      expect(controller.stylesheets, hasLength(1));
      expect(controller.stylesheets.single.cssText, inline['cssText']);
      expect(controller.stylesheets.single.media, 'print');
      expect(controller.diagnostics, isEmpty);

      expect(
        controller.complete(
          'stylesheet-1',
          _loaded([
            NativeDocumentStylesheet(
              'p { color: green; }',
              baseUrl: 'https://cdn.example.test/a.css',
            ),
          ]),
        ),
        isTrue,
      );
      expect(controller.stylesheets.map((sheet) => sheet.cssText).toList(), [
        'p { color: green; }',
        'p { color: red; }',
      ]);
      expect(controller.stylesheets.map((sheet) => sheet.media).toList(), [
        'screen',
        'print',
      ]);
    },
  );

  test(
    'inline CSS switches from raw text to expanded imports on completion',
    () {
      final controller = NativeDynamicDocumentStyles();
      const rawCss = '@import "theme.css"; p { color: red; }';
      controller.update({
        'sheets': [
          _inline(
            ownerId: 'owner-inline',
            order: 0,
            cssText: rawCss,
            transportId: 'stylesheet-inline',
          ),
        ],
        'links': <Map<String, dynamic>>[],
      });

      expect(controller.stylesheets.single.cssText, rawCss);
      expect(
        controller.complete(
          'stylesheet-inline',
          _loaded(
            [
              NativeDocumentStylesheet(
                'a { color: blue; }',
                baseUrl: 'https://example.test/page/theme.css',
              ),
              NativeDocumentStylesheet('p { color: red; }', baseUrl: _baseUrl),
            ],
            diagnostics: const ['An imported stylesheet failed.'],
            loaded: false,
          ),
        ),
        isTrue,
      );
      expect(controller.stylesheets.map((sheet) => sheet.cssText).toList(), [
        'a { color: blue; }',
        'p { color: red; }',
      ]);
      expect(controller.stylesheets.map((sheet) => sheet.baseUrl).toList(), [
        'https://example.test/page/theme.css',
        _baseUrl,
      ]);
      expect(
        controller.diagnostics,
        contains('An imported stylesheet failed.'),
      );
    },
  );

  test(
    'link href revisions clear old CSS and stale completions are rejected',
    () {
      final controller = NativeDynamicDocumentStyles();
      controller.update({
        'sheets': <Map<String, dynamic>>[],
        'links': [
          _link(
            ownerId: 'owner-link',
            order: 0,
            fetchHref: 'https://example.test/old.css',
            revision: 1,
            transportId: 'stylesheet-old',
          ),
        ],
      });
      expect(controller.stylesheets, isEmpty);
      expect(
        controller.complete(
          'stylesheet-old',
          _loaded([
            NativeDocumentStylesheet('p { color: red; }', baseUrl: _baseUrl),
          ]),
        ),
        isTrue,
      );
      expect(controller.stylesheets.single.cssText, 'p { color: red; }');

      controller.update({
        'sheets': <Map<String, dynamic>>[],
        'links': [
          _link(
            ownerId: 'owner-link',
            order: 0,
            fetchHref: 'https://example.test/new.css',
            revision: 2,
            transportId: 'stylesheet-new',
          ),
        ],
      });
      expect(controller.stylesheets, isEmpty);
      expect(
        controller.complete(
          'stylesheet-old',
          _loaded([
            NativeDocumentStylesheet('p { color: black; }', baseUrl: _baseUrl),
          ]),
        ),
        isFalse,
      );
      expect(
        controller.complete(
          'stylesheet-new',
          _loaded(
            [
              NativeDocumentStylesheet(
                'p { color: purple; }',
                baseUrl: 'https://cdn.example.test/new.css',
              ),
            ],
            diagnostics: const ['An imported stylesheet failed.'],
            loaded: false,
          ),
        ),
        isTrue,
      );
      expect(controller.stylesheets.single.cssText, 'p { color: purple; }');
      expect(
        controller.stylesheets.single.baseUrl,
        'https://cdn.example.test/new.css',
      );
      expect(
        controller.diagnostics,
        contains('An imported stylesheet failed.'),
      );

      controller.update({
        'sheets': <Map<String, dynamic>>[],
        'links': <Map<String, dynamic>>[],
      });
      expect(controller.stylesheets, isEmpty);
      expect(
        controller.complete(
          'stylesheet-new',
          _loaded([
            NativeDocumentStylesheet('p { color: orange; }', baseUrl: _baseUrl),
          ]),
        ),
        isFalse,
      );
    },
  );

  test(
    'media changes rewrap cached sources without requiring completion again',
    () {
      final controller = NativeDynamicDocumentStyles();
      final descriptor = _link(
        ownerId: 'owner-link',
        order: 0,
        fetchHref: 'https://example.test/page/a.css',
        revision: 4,
        transportId: 'stylesheet-4',
        media: 'screen',
      );
      controller.update({
        'sheets': <Map<String, dynamic>>[],
        'links': [descriptor],
      });
      expect(
        controller.complete(
          'stylesheet-4',
          _loaded([
            NativeDocumentStylesheet('p { color: red; }', baseUrl: _baseUrl),
          ]),
        ),
        isTrue,
      );
      expect(controller.stylesheets.single.media, 'screen');

      final changedMedia = Map<String, dynamic>.of(descriptor)
        ..['media'] = 'print'
        ..['baseURL'] = 'https://example.test/changed/'
        ..['href'] = 'relative.css';
      controller.update({
        'sheets': <Map<String, dynamic>>[],
        'links': [changedMedia],
      });
      expect(controller.stylesheets, hasLength(1));
      expect(controller.stylesheets.single.cssText, 'p { color: red; }');
      expect(controller.stylesheets.single.media, 'print');
    },
  );

  test(
    'first-snapshot seeds match order, source, options and base only once',
    () {
      const base = 'https://example.test/page/';
      const referrer = 'https://example.test/page/document';
      final options = _requestOptions(
        crossOrigin: 'anonymous',
        integrity: 'sha256-example',
        referrerPolicy: 'no-referrer',
        referrerUrl: referrer,
      );
      final linkSeed = NativePreparedDocumentStyle(
        order: 0,
        href: 'https://example.test/page/seed.css',
        cssText: null,
        baseUrl: base,
        options: options,
        stylesheets: [
          NativeDocumentStylesheet(
            '@media screen {p { color: red; }}',
            baseUrl: 'https://cdn.example.test/seed.css',
          ),
        ],
        diagnostics: const ['Seed import failed, retaining partial CSS.'],
        loaded: false,
        media: 'screen',
      );
      final inlineOptions = _requestOptions(
        referrerPolicy: 'no-referrer',
        referrerUrl: referrer,
      );
      final inlineSeed = NativePreparedDocumentStyle(
        order: 1,
        href: null,
        cssText: 'p { color: blue; }',
        baseUrl: base,
        options: inlineOptions,
        stylesheets: [
          NativeDocumentStylesheet(
            '@media screen {p { color: blue; }}',
            baseUrl: base,
          ),
        ],
        diagnostics: const [],
        loaded: true,
        media: 'screen',
      );
      final controller = NativeDynamicDocumentStyles(
        seeds: [linkSeed, inlineSeed],
      );
      final link = _link(
        ownerId: 'owner-link',
        order: 0,
        fetchHref: linkSeed.href!,
        revision: 1,
        transportId: 'stylesheet-seed-link',
        media: 'print',
        baseUrl: base,
        crossOrigin: 'anonymous',
        integrity: 'sha256-example',
        referrerPolicy: 'no-referrer',
        referrerUrl: referrer,
      );
      final inline = _inline(
        ownerId: 'owner-inline',
        order: 1,
        cssText: inlineSeed.cssText!,
        revision: 1,
        transportId: 'stylesheet-seed-inline',
        media: 'print',
        baseUrl: base,
        referrerPolicy: 'no-referrer',
        referrerUrl: referrer,
      );
      controller.update({
        'sheets': [inline],
        'links': [link],
      });

      expect(controller.stylesheets.map((sheet) => sheet.cssText).toList(), [
        'p { color: red; }',
        'p { color: blue; }',
      ]);
      expect(controller.stylesheets.map((sheet) => sheet.media).toList(), [
        'print',
        'print',
      ]);
      final takenLinkSeed = controller.takeSeed('stylesheet-seed-link');
      expect(takenLinkSeed, isNotNull);
      expect(takenLinkSeed!.loaded, isFalse);
      expect(takenLinkSeed.stylesheets.single.cssText, 'p { color: red; }');
      expect(
        takenLinkSeed.diagnostics,
        contains('Seed import failed, retaining partial CSS.'),
      );
      expect(controller.takeSeed('stylesheet-seed-link'), isNull);
      expect(controller.takeSeed('stylesheet-seed-inline'), isNotNull);

      final changedLink = _link(
        ownerId: 'owner-link',
        order: 0,
        fetchHref: 'https://example.test/page/next.css',
        revision: 2,
        transportId: 'stylesheet-next',
        baseUrl: base,
        crossOrigin: 'anonymous',
        integrity: 'sha256-example',
        referrerPolicy: 'no-referrer',
        referrerUrl: referrer,
      );
      final changedInline = _inline(
        ownerId: 'owner-inline',
        order: 1,
        cssText: 'p { color: black; }',
        revision: 2,
        transportId: 'stylesheet-inline-next',
        baseUrl: base,
      );
      controller.update({
        'sheets': [changedInline],
        'links': [changedLink],
      });
      expect(controller.stylesheets.map((sheet) => sheet.cssText).toList(), [
        'p { color: black; }',
      ]);
      expect(controller.takeSeed('stylesheet-next'), isNull);
    },
  );

  test('initial base mutations keep a frozen absolute link seed', () {
    final seed = NativePreparedDocumentStyle(
      order: 0,
      href: 'https://example.test/one/theme.css',
      cssText: null,
      baseUrl: 'https://example.test/one/',
      options: _requestOptions(),
      stylesheets: [
        const NativeDocumentStylesheet(
          'p{color:red}',
          baseUrl: 'https://example.test/one/theme.css',
        ),
      ],
      diagnostics: const [],
      loaded: true,
    );
    final controller = NativeDynamicDocumentStyles(seeds: [seed]);
    controller.update({
      'sheets': [],
      'links': [
        _link(
          ownerId: 'link',
          order: 0,
          fetchHref: seed.href!,
          baseUrl: 'https://example.test/two/',
          transportId: 'stylesheet-1',
        ),
      ],
    });
    expect(controller.takeSeed('stylesheet-1'), isNotNull);
    expect(
      controller.stylesheets.single.baseUrl,
      'https://example.test/one/theme.css',
    );
  });

  test(
    'a seed mismatch on the first snapshot is not used by later snapshots',
    () {
      const base = 'https://example.test/page/';
      final seed = NativePreparedDocumentStyle(
        order: 0,
        href: 'https://example.test/page/a.css',
        cssText: null,
        baseUrl: base,
        options: _requestOptions(),
        stylesheets: [
          NativeDocumentStylesheet('p { color: red; }', baseUrl: base),
        ],
        diagnostics: const [],
        loaded: true,
      );
      final controller = NativeDynamicDocumentStyles(seeds: [seed]);
      controller.update({
        'sheets': <Map<String, dynamic>>[],
        'links': [
          _link(
            ownerId: 'owner-link',
            order: 0,
            fetchHref: seed.href!,
            transportId: 'stylesheet-a',
            crossOrigin: 'anonymous',
          ),
        ],
      });
      expect(controller.takeSeed('stylesheet-a'), isNull);
      controller.update({
        'sheets': <Map<String, dynamic>>[],
        'links': [
          _link(
            ownerId: 'owner-link',
            order: 0,
            fetchHref: seed.href!,
            transportId: 'stylesheet-a',
          ),
        ],
      });
      expect(controller.stylesheets, isEmpty);
      expect(controller.takeSeed('stylesheet-a'), isNull);
    },
  );

  test('disabled and non-stylesheet owners do not render', () {
    final controller = NativeDynamicDocumentStyles();
    controller.update({
      'sheets': [
        _inline(
          ownerId: 'disabled-inline',
          order: 0,
          cssText: 'p { color: red; }',
          disabled: true,
        ),
      ],
      'links': [
        _link(
          ownerId: 'not-a-stylesheet',
          order: 1,
          fetchHref: 'https://example.test/alternate.css',
          transportId: 'stylesheet-alternate',
          isStylesheet: false,
        ),
      ],
    });
    expect(controller.stylesheets, isEmpty);
    expect(
      controller.complete(
        'stylesheet-alternate',
        _loaded([
          NativeDocumentStylesheet('p { color: blue; }', baseUrl: _baseUrl),
        ]),
      ),
      isFalse,
    );
  });

  test(
    'completed partial styles are compacted to the document source prefix',
    () {
      final controller = NativeDynamicDocumentStyles(
        maximumSources: 2,
        maximumBytes: 100,
      );
      final first = _link(
        ownerId: 'first-link',
        order: 0,
        fetchHref: 'https://example.test/first.css',
        transportId: 'stylesheet-first',
      );
      final second = _link(
        ownerId: 'second-link',
        order: 1,
        fetchHref: 'https://example.test/second.css',
        transportId: 'stylesheet-second',
      );
      controller.update({
        'sheets': <Map<String, dynamic>>[],
        'links': [first, second],
      });

      expect(
        controller.complete(
          'stylesheet-first',
          _loaded(
            [
              NativeDocumentStylesheet('a{}', baseUrl: _baseUrl),
              NativeDocumentStylesheet('b{}', baseUrl: _baseUrl),
            ],
            diagnostics: const ['Imported CSS is partial.'],
            loaded: false,
          ),
        ),
        isTrue,
      );
      expect(
        controller.complete(
          'stylesheet-second',
          _loaded([NativeDocumentStylesheet('c{}', baseUrl: _baseUrl)]),
        ),
        isTrue,
      );
      expect(controller.stylesheets.map((sheet) => sheet.cssText).toList(), [
        'a{}',
        'b{}',
      ]);
      expect(controller.diagnostics, contains('Imported CSS is partial.'));
      expect(
        controller.diagnostics,
        contains(startsWith('Document stylesheet source limit exceeded')),
      );

      // Removing the first owner must not reveal its over-budget successor: the
      // discarded response was removed from persistent owner state as well.
      controller.update({
        'sheets': <Map<String, dynamic>>[],
        'links': [second],
      });
      expect(controller.stylesheets, isEmpty);
      expect(
        controller.diagnostics,
        contains(startsWith('Document stylesheet source limit exceeded')),
      );
    },
  );

  test('disabled completed styles still consume the document byte budget', () {
    final controller = NativeDynamicDocumentStyles(
      maximumSources: 64,
      maximumBytes: 8,
    );
    final disabled = _link(
      ownerId: 'disabled-link',
      order: 0,
      fetchHref: 'https://example.test/disabled.css',
      transportId: 'stylesheet-disabled',
      disabled: true,
    );
    final visible = _link(
      ownerId: 'visible-link',
      order: 1,
      fetchHref: 'https://example.test/visible.css',
      transportId: 'stylesheet-visible',
    );
    controller.update({
      'sheets': <Map<String, dynamic>>[],
      'links': [disabled, visible],
    });
    expect(
      controller.complete(
        'stylesheet-disabled',
        _loaded([NativeDocumentStylesheet('a{}', baseUrl: _baseUrl)]),
      ),
      isTrue,
    );
    expect(
      controller.complete(
        'stylesheet-visible',
        _loaded([NativeDocumentStylesheet('b{}', baseUrl: _baseUrl)]),
      ),
      isTrue,
    );
    expect(controller.stylesheets, isEmpty);
    expect(
      controller.diagnostics,
      contains(startsWith('Document stylesheet decoded-text limit exceeded')),
    );

    controller.update({
      'sheets': <Map<String, dynamic>>[],
      'links': [visible],
    });
    expect(controller.stylesheets, isEmpty);
  });

  test('UTF-16 decoded byte and source-count budgets cover all owners', () {
    final byteLimited = NativeDynamicDocumentStyles(
      maximumSources: 64,
      maximumBytes: 5,
    );
    byteLimited.update({
      'sheets': [
        _inline(ownerId: 'unicode', order: 0, cssText: '😀'),
        _inline(ownerId: 'one-unit', order: 1, cssText: 'x'),
      ],
      'links': <Map<String, dynamic>>[],
    });
    // Dart String.length counts UTF-16 code units: 😀 consumes four bytes.
    expect(byteLimited.stylesheets.map((sheet) => sheet.cssText).toList(), [
      '😀',
    ]);
    expect(
      byteLimited.diagnostics,
      contains(startsWith('Document stylesheet decoded-text limit exceeded')),
    );

    final sourceLimited = NativeDynamicDocumentStyles(maximumSources: 1);
    sourceLimited.update({
      'sheets': [
        _inline(ownerId: 'first', order: 0, cssText: 'a{}'),
        _inline(ownerId: 'second', order: 1, cssText: 'b{}'),
      ],
      'links': <Map<String, dynamic>>[],
    });
    expect(sourceLimited.stylesheets, hasLength(1));
    expect(
      sourceLimited.diagnostics,
      contains(startsWith('Document stylesheet source limit exceeded')),
    );
    expect(NativeDynamicDocumentStyles.defaultMaximumSources, 64);
    expect(NativeDynamicDocumentStyles.defaultMaximumBytes, 8 * 1024 * 1024);
  });
}
