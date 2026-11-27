@Tags(['tier3'])
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_render_document/src/document_scripts.dart';
import 'support/legacy_scripts_platform.dart';

import 'document_scripts_test.dart' show ScriptsGateway;

class AnchorActivationGateway extends ScriptsGateway {
  List<Json> initial = [], followup = [], forms = [], pumpActions = [];
  int? nativeLinkOrder;
  int? timerDelayMs;
  Completer<void>? dispatchGate, dispatchStarted;
  List<Json> _snapshotActions = const [];

  void holdNextDispatch() {
    dispatchGate = Completer<void>();
    dispatchStarted = Completer<void>();
  }

  @override
  Future<dynamic> call(String method, [Json args = const {}]) async {
    final response = await super.call(method, args);
    if (method != 'documentScriptEvaluate') return response;

    final decoded = obj(jsonDecode(response['value'] as String));
    final source = '${args['source']}';
    final snapshot = source.startsWith('__pircDocument.snapshot');
    final dispatch = source.startsWith('__pircDocument.dispatch');
    final init = source.startsWith('__pircDocument.init');
    final pump = source.startsWith('__pircDocument.pump');

    if (dispatch && dispatchGate != null) {
      if (!(dispatchStarted?.isCompleted ?? true)) {
        dispatchStarted!.complete();
      }
      await dispatchGate!.future;
      dispatchGate = null;
    }

    if (snapshot) {
      decoded['navigationActions'] = _snapshotActions;
      decoded['formActions'] = const <Json>[];
      _snapshotActions = const [];
      decoded['scheduler'] = {
        'timerDelayMs': timerDelayMs,
        'animationFrame': false,
      };
    } else {
      if (dispatch || init) {
        decoded['navigationActions'] = initial;
        decoded['formActions'] = forms;
        _snapshotActions = followup;
        initial = [];
        forms = [];
        followup = [];
      } else if (pump) {
        decoded['navigationActions'] = pumpActions;
        decoded['formActions'] = const <Json>[];
        pumpActions = [];
        // Let this timer complete once unless the test installs another one.
        timerDelayMs = null;
      } else {
        decoded['navigationActions'] = const <Json>[];
        decoded['formActions'] = const <Json>[];
      }
      decoded['defaultPrevented'] = false;
      if (dispatch && nativeLinkOrder != null) {
        decoded['nativeLinkDefaultOrder'] = nativeLinkOrder;
      }
    }
    return {'value': jsonEncode(decoded)};
  }
}

Json anchorAction(
  String url, {
  String target = '_self',
  String? download,
  String referrerPolicy = 'strict-origin-when-cross-origin',
  bool noreferrer = false,
  bool noopener = false,
  int actionOrder = 1,
  Json? capturedBlob,
}) => {
  'kind': 'anchor',
  'url': url,
  'target': target,
  'download': download,
  'referrerPolicy': referrerPolicy,
  'noreferrer': noreferrer,
  'noopener': noopener,
  'replace': false,
  'actionOrder': actionOrder,
  'capturedBlob': ?capturedBlob,
};

Future<NativeDocumentScripts> startScripts(
  AnchorActivationGateway gateway, {
  String url = 'https://example.test/document',
  double Function()? clockMilliseconds,
}) async {
  final scripts = NativeDocumentScripts(
    gateway,
    clockMilliseconds: clockMilliseconds,
  );
  await scripts.start(source: '<p>fixture</p>', url: url);
  expect(scripts.ready, isTrue);
  return scripts;
}

class _FakeClock {
  double milliseconds = 0;
  double read() => milliseconds;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'validated anchor metadata reaches the queue and is consumed once',
    () async {
      const url = 'https://example.test/export.csv';
      final gateway = AnchorActivationGateway();
      final scripts = await startScripts(gateway);
      addTearDown(scripts.dispose);
      gateway.initial = [
        anchorAction(
          url,
          target: 'reportWindow',
          download: '',
          referrerPolicy: 'no-referrer',
          noreferrer: true,
          noopener: true,
        ),
      ];

      await scripts.click('export-link', []);

      expect(scripts.navigationActions, hasLength(1));
      final queued = scripts.navigationActions.single;
      expect(queued['kind'], 'anchor');
      expect(queued['url'], url);
      expect(queued['target'], '_self');
      expect(queued['download'], ''); // Empty download attribute is present.
      expect(queued['referrerPolicy'], 'no-referrer');
      expect(queued['noreferrer'], isTrue);
      expect(queued['noopener'], isTrue);
      expect(queued['replace'], isFalse);
      final sequence = queued['sequence'] as int;
      expect(scripts.takeNavigationActions([sequence]), [queued]);
      expect(scripts.takeNavigationActions([sequence]), isEmpty);
    },
  );

  testWidgets('startup and timer self-downloads reach the existing save path', (
    tester,
  ) async {
    final startupGateway = AnchorActivationGateway()
      ..initial = [
        anchorAction(
          'https://example.test/startup.txt',
          download: 'startup.txt',
        ),
      ];
    final startup = await startScripts(startupGateway);
    addTearDown(startup.dispose);
    expect(startup.navigationActions.single['download'], 'startup.txt');

    final clock = _FakeClock();
    final timerGateway = AnchorActivationGateway()
      ..timerDelayMs = 5
      ..pumpActions = [
        anchorAction('https://example.test/timer.txt', download: 'timer.txt'),
      ];
    final timerScripts = await startScripts(
      timerGateway,
      clockMilliseconds: clock.read,
    );
    addTearDown(timerScripts.dispose);
    await tester.pump(Duration.zero);
    expect(timerScripts.navigationActions, isEmpty);

    clock.milliseconds = 5;
    await tester.pump(const Duration(milliseconds: 5));
    await tester.pump(Duration.zero);
    expect(timerScripts.navigationActions.map((action) => action['download']), [
      'timer.txt',
    ]);
  });

  test(
    'startup popups are rejected, including a cross-origin download hint',
    () async {
      final gateway = AnchorActivationGateway()
        ..initial = [
          anchorAction('https://example.test/popup', target: '_blank'),
          anchorAction(
            'https://outside.test/export.csv',
            target: '_blank',
            download: 'export.csv',
            actionOrder: 2,
          ),
          anchorAction(
            'https://example.test/named-popup',
            target: 'reportWindow',
            actionOrder: 3,
          ),
        ];
      final scripts = await startScripts(gateway);
      addTearDown(scripts.dispose);

      expect(scripts.navigationActions, isEmpty);
    },
  );

  test(
    'download actions survive later same-window defaults and coalescing',
    () async {
      final gateway = AnchorActivationGateway();
      final scripts = await startScripts(gateway);
      addTearDown(scripts.dispose);
      gateway
        ..initial = [
          anchorAction(
            'https://example.test/first.csv',
            download: 'first.csv',
            actionOrder: 1,
          ),
        ]
        ..followup = [
          anchorAction(
            'https://example.test/second.csv',
            download: 'second.csv',
            actionOrder: 3,
          ),
          {
            'kind': 'navigate',
            'url': 'https://example.test/final',
            'target': '_self',
            'replace': false,
            'actionOrder': 4,
          },
        ]
        ..forms = [
          {
            'kind': 'submit',
            'formId': 'f',
            'target': '_self',
            'actionOrder': 2,
          },
        ]
        ..nativeLinkOrder = 5;

      await scripts.click('anchor', []);

      expect(
        scripts.navigationActions
            .where((action) => action['kind'] == 'anchor')
            .map((action) => action['download']),
        ['first.csv', 'second.csv'],
      );
      expect(
        scripts.navigationActions.where(
          (action) => action['kind'] == 'navigate',
        ),
        isEmpty,
      );
      expect(scripts.formActions, isEmpty);
    },
  );

  test('cross-origin HTTP download hints become ordinary navigation', () async {
    final gateway = AnchorActivationGateway();
    final scripts = await startScripts(
      gateway,
      url: 'https://example.test/source',
    );
    addTearDown(scripts.dispose);
    gateway.initial = [
      anchorAction('https://outside.test/export.csv', download: 'ignored.csv'),
    ];

    await scripts.click('anchor', []);

    expect(scripts.navigationActions, hasLength(1));
    expect(scripts.navigationActions.single['kind'], 'anchor');
    expect(
      scripts.navigationActions.single['url'],
      'https://outside.test/export.csv',
    );
    expect(scripts.navigationActions.single['download'], isNull);
  });

  test('captured Blob bytes preserve an immediate-revoke download', () async {
    const url = 'blob:https://example.test/activation-id';
    final gateway = AnchorActivationGateway();
    final scripts = await startScripts(gateway);
    addTearDown(scripts.dispose);
    gateway.initial = [
      anchorAction(
        url,
        download: 'report.csv',
        capturedBlob: {
          'ok': true,
          'url': url,
          'type': 'text/csv',
          'size': 3,
          'bytesBase64': 'YSxi', // a,b
        },
      ),
    ];

    await scripts.click('blob-export', []);

    expect(scripts.navigationActions, hasLength(1));
    expect(scripts.navigationActions.single['download'], 'report.csv');
    expect(scripts.navigationActions.single['capturedBlob'], {
      'ok': true,
      'url': url,
      'type': 'text/csv',
      'size': 3,
      'bytesBase64': 'YSxi',
    });
  });

  test('data URLs require a download attribute', () async {
    final invalidGateway = AnchorActivationGateway();
    final invalid = await startScripts(invalidGateway);
    addTearDown(invalid.dispose);
    invalidGateway.initial = [anchorAction('data:text/plain;base64,YQ==')];

    await invalid.click('data-link', []);

    expect(invalid.ready, isFalse);
    expect(invalid.navigationActions, isEmpty);

    final downloadGateway = AnchorActivationGateway();
    final download = await startScripts(downloadGateway);
    addTearDown(download.dispose);
    downloadGateway.initial = [
      anchorAction('data:text/plain;base64,YQ==', download: 'a.txt'),
    ];

    await download.click('data-download', []);

    expect(download.navigationActions.single['download'], 'a.txt');
  });

  for (final invalidBlob in <(String, String, Json)>[
    (
      'size mismatch',
      'blob:https://example.test/id',
      {
        'ok': true,
        'url': 'blob:https://example.test/id',
        'type': 'text/plain',
        'size': 2,
        'bytesBase64': 'YQ==',
      },
    ),
    (
      'oversized payload',
      'blob:https://example.test/id',
      {
        'ok': true,
        'url': 'blob:https://example.test/id',
        'type': 'text/plain',
        'size': 2 * 1024 * 1024 + 1,
        'bytesBase64': '',
      },
    ),
    (
      'foreign Blob origin',
      'blob:https://outside.test/id',
      {
        'ok': true,
        'url': 'blob:https://outside.test/id',
        'type': 'text/plain',
        'size': 1,
        'bytesBase64': 'YQ==',
      },
    ),
  ]) {
    test('rejects captured Blob ${invalidBlob.$1}', () async {
      final gateway = AnchorActivationGateway();
      final scripts = await startScripts(gateway);
      addTearDown(scripts.dispose);
      gateway.initial = [
        anchorAction(
          invalidBlob.$2,
          download: 'blob.txt',
          capturedBlob: invalidBlob.$3,
        ),
      ];

      await scripts.click('blob-download', []);

      expect(scripts.ready, isFalse);
      expect(scripts.navigationActions, isEmpty);
    });
  }

  test('malformed anchor metadata is rejected', () async {
    final gateway = AnchorActivationGateway();
    final scripts = await startScripts(gateway);
    addTearDown(scripts.dispose);
    gateway.initial = [
      {...anchorAction('https://example.test/file.csv'), 'download': 42},
    ];

    await scripts.click('bad-anchor', []);

    expect(scripts.ready, isFalse);
    expect(scripts.navigationActions, isEmpty);
  });

  test(
    'hidden, retired, and stale-generation anchors cannot be consumed',
    () async {
      final gateway = AnchorActivationGateway();
      final scripts = await startScripts(gateway);
      addTearDown(scripts.dispose);
      gateway.initial = [
        anchorAction('https://example.test/file.txt', download: 'file.txt'),
      ];
      int sequence() => scripts.navigationActions.single['sequence'] as int;

      await scripts.click('anchor', []);
      final hidden = sequence();
      scripts.setActivity(attached: true, visible: false);
      expect(scripts.takeNavigationActions([hidden]), isEmpty);
      scripts.setActivity(attached: true, visible: true);
      expect(scripts.navigationActions, isEmpty);

      gateway.holdNextDispatch();
      gateway.initial = [
        anchorAction('https://example.test/stale.txt', download: 'stale.txt'),
      ];
      final pending = scripts.click('anchor', []);
      await gateway.dispatchStarted!.future;
      scripts.setActivity(attached: false, visible: false);
      scripts.setActivity(attached: true, visible: true);
      gateway.dispatchGate!.complete();
      await pending;
      expect(scripts.navigationActions, isEmpty);

      gateway.initial = [
        anchorAction(
          'https://example.test/retired.txt',
          download: 'retired.txt',
        ),
      ];
      await scripts.click('anchor', []);
      expect(scripts.navigationActions, hasLength(1));
      final retired = scripts.navigationActions.single['sequence'] as int;
      scripts.dispose();
      expect(scripts.takeNavigationActions([retired]), isEmpty);
    },
  );
}
