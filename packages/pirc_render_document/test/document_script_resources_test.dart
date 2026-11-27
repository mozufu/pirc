// Resource lifecycle, containment and limits: safety regressions, so the
// default suite runs them (plans/client.md, Testing).
import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_render_document/src/document_scripts.dart';
import 'package:pirc_render_document/src/document_script_resources.dart';
import 'support/legacy_scripts_platform.dart';

class ResourceGateway extends LegacyScriptsPlatform {
  final calls = <(String, Json)>[];
  final pending = <String, Completer<Json>>{};
  final completed = <Json>[];
  List<Json> requests = [];
  List<String> cancellations = [];
  Completer<void>? dispatchGate;
  Completer<void>? dispatchEntered;
  bool failSnapshot = false;
  bool repeatFirstRequest = false;
  Json? styleSnapshot;
  @override
  Future<dynamic> call(String method, [Json args = const {}]) async {
    calls.add((method, args));
    switch (method) {
      case 'resolveDocumentUrl':
        return Uri.parse(
          args['baseUrl'] as String,
        ).resolve(args['reference'] as String).toString();
      case 'documentScriptCapabilities':
        return {'supported': true};
      case 'documentScriptOpen':
        return {'id': 42};
      case 'documentScriptClose':
        return null;
      case 'documentScriptResource':
        final request = obj(args['request']);
        final future = Completer<Json>();
        pending[request['id'] as String] = future;
        return future.future;
      case 'documentScriptResourceCancel':
        final id = args['requestId'] as String;
        final future = pending[id];
        if (future != null && !future.isCompleted) {
          future.completeError(StateError('Canceled'));
        }
        return null;
      case 'documentScriptEvaluate':
        final source = args['source'] as String;
        if (source == 'runtime') return {'value': 'ready'};
        final gate = dispatchGate;
        if (gate != null && source.startsWith('__pircDocument.dispatch(')) {
          dispatchGate = null;
          dispatchEntered?.complete();
          await gate.future;
        }
        if (source.startsWith('__pircDocument.completeResource(')) {
          final payload = source.substring(
            '__pircDocument.completeResource('.length,
            source.length - 1,
          );
          completed.add(obj(jsonDecode(payload)));
        }
        final snapshot = source.startsWith('__pircDocument.snapshot');
        final cancelled = List<String>.of(cancellations);
        cancellations.clear();
        final emitted = List<Json>.of(requests);
        if (!repeatFirstRequest) requests.clear();
        return {
          'value': jsonEncode({
            'html': '<body>${completed.length}</body>',
            if (styleSnapshot != null) 'stylesheets': styleSnapshot,
            'resourceRequests': emitted,
            'resourceCancellations': cancelled,
            'diagnostics': snapshot && failSnapshot
                ? [
                    {'code': 'runtime.output_limit', 'message': 'too large'},
                  ]
                : [],
          }),
        };
    }
    throw StateError(method);
  }
}

Json request(String id) => {
  'id': id,
  'kind': id.split('-').first,
  'url': 'https://example.test/$id',
};
Json response([String text = 'loaded']) => {
  'status': 200,
  'statusText': 'OK',
  'url': 'https://example.test/result',
  'headers': [
    ['content-type', 'text/plain'],
  ],
  'bodyBytes': utf8.encode(text),
  'type': 'basic',
  'redirected': false,
};
Future<void> settle() async {
  for (var i = 0; i < 12; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  test(
    'module sources always use UTF-8 even with conflicting charset or UTF-16 BOM',
    () {
      final request = {'id': 'script-1', 'kind': 'script', 'type': 'module'};
      expect(
        completeDocumentScriptResource(request, {
          'status': 200,
          'url': 'https://example.test/final.js',
          'charset': 'windows-1252',
          'bodyBytes': utf8.encode("export const text = '猫';"),
        })['source'],
        "export const text = '猫';",
      );
      expect(
        completeDocumentScriptResource(request, {
          'status': 200,
          'charset': 'utf-16le',
          'bodyBytes': [255, 254, 65, 0],
        })['source'],
        '\uFFFD\uFFFDA\u0000',
      );
      expect(
        completeDocumentScriptResource(request, {
          'status': 200,
          'bodyBytes': [239, 187, 191, ...utf8.encode('export {};')],
        })['source'],
        'export {};',
      );
    },
  );

  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'stylesheet bytes stay in Dart and only status reaches JavaScript',
    () async {
      final g = ResourceGateway()
        ..styleSnapshot = {
          'sheets': [],
          'links': [
            {
              'id': 'owner',
              'ownerId': 'owner',
              'order': 0,
              'revision': 1,
              'requestId': 'owner:1',
              'transportId': 'stylesheet-1',
              'ownerType': 'link',
              'baseURL': 'https://example.test/page',
              'fetchHref': 'https://example.test/theme.css',
              'requestable': true,
              'isStylesheet': true,
            },
          ],
        }
        ..requests = [
          {
            'id': 'stylesheet-1',
            'kind': 'stylesheet',
            'ownerType': 'link',
            'url': 'https://example.test/theme.css',
            'baseURL': 'https://example.test/page',
            'stylesheetReferrerUrl': 'https://spoof.invalid/private',
          },
        ];
      final state = NativeDocumentScripts(g);
      await state.start(source: '', url: 'https://example.test/page');
      await settle();
      expect(g.pending.keys, ['stylesheet-1']);
      final request = g.calls
          .firstWhere((call) => call.$1 == 'documentScriptResource')
          .$2;
      expect(obj(request['request'])['kind'], 'stylesheet');
      // A document with an opaque origin sends no referrer at all, so the
      // authored one never reaches the channel either.
      expect(
        obj(request['request']).keys,
        isNot(contains('stylesheetReferrerUrl')),
      );
      g.pending['stylesheet-1']!.complete({
        ...response('p{color:rgb(1,2,3)}'),
        'mimeType': 'text/css',
        'type': 'stylesheet',
      });
      await settle();
      expect(state.stylesheets!.single.cssText, contains('rgb(1,2,3)'));
      expect(g.completed.single['ok'], true);
      expect(g.completed.single.containsKey('source'), false);
      expect(g.completed.single.containsKey('bodyBytes'), false);
      expect(g.completed.single.containsKey('bodyBase64'), false);
      expect(jsonEncode(g.completed.single), isNot(contains('rgb(1,2,3)')));
      state.dispose();
    },
  );

  test(
    'inline stylesheet completions render without native network I/O',
    () async {
      final g = ResourceGateway()
        ..styleSnapshot = {
          'sheets': [
            {
              'id': 'owner',
              'ownerId': 'owner',
              'order': 0,
              'revision': 1,
              'requestId': 'owner:1',
              'transportId': 'stylesheet-1',
              'ownerType': 'style',
              'baseURL': 'https://example.test/page',
              'cssText': 'p{height:23px}',
            },
          ],
          'links': [],
        }
        ..requests = [
          {
            'id': 'stylesheet-1',
            'kind': 'stylesheet',
            'ownerType': 'style',
            'cssText': 'p{height:23px}',
            'baseURL': 'https://example.test/page',
            'stylesheetReferrerUrl': 'https://example.test/page',
          },
        ];
      final state = NativeDocumentScripts(g);
      await state.start(source: '', url: 'https://example.test/page');
      await settle();
      expect(
        g.calls.where((call) => call.$1 == 'documentScriptResource'),
        isEmpty,
      );
      expect(g.completed.single['ok'], true);
      expect(state.stylesheets!.single.cssText, contains('height:23px'));
      state.dispose();
    },
  );

  test(
    'resource I/O does not block events; completions update DOM and bind principal',
    () async {
      final g = ResourceGateway()..requests = [request('script-1')];
      final state = NativeDocumentScripts(g);
      await state.start(
        source: '<script src="/lib.js"></script>',
        url: 'https://example.test/page',
        referrerPolicy: 'no-referrer',
      );
      await settle();
      // The channel never learns the document URL; only the runtime does.
      expect(g.calls.firstWhere((c) => c.$1 == 'documentScriptOpen').$2.keys, [
        'owner',
      ]);
      expect(
        g.calls
            .firstWhere(
              (c) =>
                  c.$1 == 'documentScriptEvaluate' &&
                  '${c.$2['source']}'.startsWith('__pircDocument.init'),
            )
            .$2['source'],
        contains('"referrerPolicy":"no-referrer"'),
      );
      expect(g.pending.keys, ['script-1']);
      expect(await state.click('button', []), false);
      expect(g.completed, isEmpty);
      g.pending['script-1']!.complete(response('document.title="ready";'));
      await settle();
      expect(g.completed.single['source'], 'document.title="ready";');
      expect(state.content!.bodyInnerHtml, '1');
      state.dispose();
    },
  );
  test('duplicate request IDs are never fetched again', () async {
    final g = ResourceGateway()
      ..requests = [request('fetch-1')]
      ..repeatFirstRequest = true;
    final state = NativeDocumentScripts(g);
    await state.start(source: '', url: 'https://example.test/');
    await settle();
    g.pending['fetch-1']!.complete(response('你好'));
    await settle();
    expect(
      g.calls.where((c) => c.$1 == 'documentScriptResource'),
      hasLength(1),
    );
    expect(
      base64Decode(g.completed.single['bodyBase64'] as String),
      utf8.encode('你好'),
    );
    state.dispose();
  });
  test('failed snapshot cannot start network side effects', () async {
    final g = ResourceGateway()
      ..requests = [request('script-1')]
      ..failSnapshot = true;
    final state = NativeDocumentScripts(g);
    await state.start(source: '', url: 'https://example.test/');
    await settle();
    expect(state.ready, false);
    expect(g.pending, isEmpty);
    state.dispose();
  });
  test(
    'network failure is delivered to JS; disposed completion cannot revive isolate',
    () async {
      final g = ResourceGateway()
        ..requests = [request('fetch-1'), request('fetch-2')];
      final state = NativeDocumentScripts(g);
      await state.start(source: '', url: 'https://example.test/');
      await settle();
      g.pending['fetch-1']!.completeError(StateError('CORS denied'));
      await settle();
      expect(g.completed.single['ok'], false);
      expect(g.completed.single['error'], contains('CORS denied'));
      expect(state.ready, true);
      state.dispose();
      g.pending['fetch-2']!.complete(response());
      await settle();
      expect(g.completed, hasLength(1));
    },
  );
  test(
    'six concurrent resources; retained history defers completion and resumes',
    () async {
      final g = ResourceGateway()
        ..requests = List.generate(8, (i) => request('fetch-${i + 1}'));
      final state = NativeDocumentScripts(g);
      await state.start(source: '', url: 'https://example.test/');
      await settle();
      expect(g.pending, hasLength(6));
      state.setActivity(attached: false, visible: false);
      g.pending['fetch-1']!.complete(response());
      await settle();
      expect(g.completed, isEmpty);
      expect(g.pending, hasLength(6));
      state.setActivity(attached: true, visible: true);
      await settle();
      expect(g.completed, hasLength(1));
      expect(g.pending, hasLength(7));
      state.dispose();
      for (final pending in g.pending.values) {
        if (!pending.isCompleted) pending.complete(response());
      }
      await settle();
    },
  );
  test(
    'cancellation releases six active slots and suppresses old completions',
    () async {
      final g = ResourceGateway()
        ..requests = List.generate(7, (i) => request('fetch-${i + 1}'));
      final state = NativeDocumentScripts(g);
      await state.start(source: '', url: 'https://example.test/');
      await settle();
      expect(g.pending.keys, List.generate(6, (i) => 'fetch-${i + 1}'));
      g.cancellations = List.generate(6, (i) => 'fetch-${i + 1}');
      await state.click('cancel', []);
      await settle();
      final cancels = g.calls
          .where((c) => c.$1 == 'documentScriptResourceCancel')
          .toList();
      expect(cancels, hasLength(6));
      final opening = g.calls
          .firstWhere((c) => c.$1 == 'documentScriptResource')
          .$2;
      for (final cancel in cancels) {
        expect(cancel.$2['id'], opening['id']);
        expect(cancel.$2['owner'], opening['owner']);
      }
      expect(g.pending.containsKey('fetch-7'), true);
      expect(g.completed, isEmpty);
      g.pending['fetch-7']!.complete(response('next ready'));
      await settle();
      expect(g.completed.map((c) => c['id']), ['fetch-7']);
      expect(state.ready, true);
      state.dispose();
    },
  );
  test(
    'queued and same-batch cancellations never dispatch HTTP or cancel another ID',
    () async {
      final g = ResourceGateway()
        ..requests = List.generate(7, (i) => request('fetch-${i + 1}'))
        ..cancellations = ['fetch-7', 'fetch-99'];
      final state = NativeDocumentScripts(g);
      await state.start(source: '', url: 'https://example.test/');
      await settle();
      expect(g.pending, hasLength(6));
      expect(
        g.calls.where((c) => c.$1 == 'documentScriptResourceCancel'),
        isEmpty,
      );
      g.cancellations = ['fetch-6', 'fetch-6'];
      await state.click('cancel', []);
      await settle();
      expect(
        g.calls.where((c) => c.$1 == 'documentScriptResourceCancel'),
        hasLength(1),
      );
      expect(g.pending.containsKey('fetch-7'), false);
      expect(g.pending['fetch-1']!.isCompleted, false);
      expect(g.completed, isEmpty);
      state.dispose();
      for (final future in g.pending.values) {
        if (!future.isCompleted) future.complete(response());
      }
      await settle();
    },
  );
  test('malformed cancellation cannot cancel active network work', () async {
    final g = ResourceGateway()..requests = [request('fetch-1')];
    final state = NativeDocumentScripts(g);
    await state.start(source: '', url: 'https://example.test/');
    await settle();
    g.cancellations = ['fetch-1', 'other-session'];
    await state.click('cancel', []);
    await settle();
    expect(
      g.calls.where((c) => c.$1 == 'documentScriptResourceCancel'),
      isEmpty,
    );
    expect(state.ready, false);
    expect(g.calls.last.$1, 'documentScriptClose');
    g.pending['fetch-1']!.complete(response());
    await settle();
    expect(g.completed, isEmpty);
    state.dispose();
  });
  for (final count in [1, 2]) {
    test(
      'canceling a queued completion preserves the document and $count-result delivery queue',
      () async {
        final g = ResourceGateway()
          ..requests = List.generate(count, (i) => request('fetch-${i + 1}'));
        final state = NativeDocumentScripts(g);
        await state.start(source: '', url: 'https://example.test/');
        await settle();
        final gate = Completer<void>();
        final entered = Completer<void>();
        g.dispatchGate = gate;
        g.dispatchEntered = entered;
        final click = state.click('cancel', []);
        await entered.future;
        // Complete native I/O while the preceding script evaluation is held.
        // Its delivery callback is queued behind that evaluation, which then
        // cancels/removes the response before delivery gets its turn.
        for (var i = 1; i <= count; i++) {
          g.pending['fetch-$i']!.complete(response());
        }
        await settle();
        g.cancellations = ['fetch-1'];
        gate.complete();
        await click;
        await settle();
        expect(state.ready, true, reason: '${state.diagnostics}');
        expect(state.diagnostics, isEmpty);
        expect(
          g.completed.map((c) => c['id']),
          count == 1 ? <String>[] : ['fetch-2'],
        );
        expect(
          g.calls.where((c) => c.$1 == 'documentScriptResourceCancel'),
          isEmpty,
        );
        // A skipped delivery callback must not strand the event/resource queue.
        g.requests = [request('fetch-3')];
        await state.click('load-next', []);
        await settle();
        expect(g.pending.containsKey('fetch-3'), true);
        g.pending['fetch-3']!.complete(response('next'));
        await settle();
        expect(g.completed.last['id'], 'fetch-3');
        expect(state.ready, true);
        state.dispose();
      },
    );
  }
  testWidgets(
    'canceling a decoded image awaiting delivery releases its handle without retiring the document',
    (tester) async {
      await tester.runAsync(() async {
        // Remote images wait for a tap, so the decoded image is a data: URL.
        final g = ResourceGateway()
          ..requests = [
            {
              'id': 'image-1',
              'kind': 'image',
              'url':
                  'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAYAAABytg0kAAAAFElEQVR4nGP4z8DwHwyBNBAw/AcAR8oI+ItOQ4UAAAAASUVORK5CYII=',
            },
          ];
        final state = NativeDocumentScripts(g);
        final gate = Completer<void>();
        try {
          final entered = Completer<void>();
          g.dispatchGate = gate;
          g.dispatchEntered = entered;
          await state.start(source: '', url: 'https://example.test/');
          final click = state.click('replace-image', []);
          await entered.future;
          for (var i = 0; i < 200 && state.canvasImages.isEmpty; i++) {
            await Future<void>.delayed(const Duration(milliseconds: 1));
          }
          expect(state.canvasImages, hasLength(1));
          expect(state.canvasImages.values.single.width, 2);
          g.cancellations = ['image-1'];
          gate.complete();
          await click;
          await settle();
          expect(state.canvasImages, isEmpty);
          expect(state.ready, true, reason: '${state.diagnostics}');
          expect(state.diagnostics, isEmpty);
          expect(g.completed, isEmpty);
          expect(
            g.calls.where((c) => c.$1 == 'documentScriptResourceCancel'),
            isEmpty,
          );
        } finally {
          if (!gate.isCompleted) gate.complete();
          state.dispose();
        }
      });
      // Finish the deferred ui.Image release before the next test.
      await tester.pump();
    },
  );
  test('empty response bytes and absent response bodies stay distinct', () {
    expect(
      completeDocumentScriptResource(request('fetch-1'), {
        ...response(),
        'status': 204,
        'bodyBytes': null,
      })['bodyBase64'],
      isNull,
    );
    expect(
      completeDocumentScriptResource(
        request('fetch-1'),
        response(''),
      )['bodyBase64'],
      '',
    );
    expect(
      completeDocumentScriptResource(request('script-1'), {
        ...response(),
        'status': 204,
        'bodyBytes': null,
      })['source'],
      '',
    );
  });
  test(
    'resource completion decoding respects byte limits, status and charset',
    () {
      expect(
        completeDocumentScriptResource(request('script-1'), {
          ...response(),
          'bodyBytes': [0xe9],
          'charset': 'windows-1252',
        })['source'],
        'é',
      );
      expect(
        () => completeDocumentScriptResource(request('script-1'), {
          ...response(),
          'status': 404,
        }),
        throwsFormatException,
      );
      expect(
        completeDocumentScriptResource(request('fetch-1'), {
          ...response(),
          'status': 404,
        })['status'],
        404,
      );
      expect(
        () => completeDocumentScriptResource(request('fetch-1'), {
          ...response(),
          'bodyBytes': [256],
        }),
        throwsFormatException,
      );
      expect(
        () => completeDocumentScriptResource(request('fetch-1'), {
          ...response(),
          'bodyBytes': List.filled(2 * 1024 * 1024 + 1, 1),
        }),
        throwsFormatException,
      );
    },
  );
}
