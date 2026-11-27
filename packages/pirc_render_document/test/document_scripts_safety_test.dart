// Safety regressions of the document runtime (plans/client.md, Testing):
// the request cap, images behind a tap, requests without credentials,
// Subresource Integrity, and storage and cookies kept per document. They
// stay in the default suite although the runtime is tier 3.
import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_render_document/src/document_integrity.dart';
import 'package:pirc_render_document/src/document_json.dart';
import 'package:pirc_render_document/src/document_resource_limiter.dart';
import 'package:pirc_render_document/src/document_script_resources.dart';
import 'package:pirc_render_document/src/document_scripts.dart';
import 'package:pirc_render_document/src/scripts_platform.dart';

/// The part-1 fake (per-session storage and cookies) with a stand-in for the
/// runtime: each evaluation answers as `__pircDocument` would.
class RuntimeFake extends FakeScriptsPlatform {
  RuntimeFake({this.respond});

  /// The runtime's answer to one evaluation; null for the default.
  final Json? Function(DocumentScriptSession session, String source)? respond;
  final evaluations = <int, List<String>>{};
  final resources = <(int, DocumentResourceRequest)>[];
  final pending = <Completer<DocumentResourceResponse>>[];
  final sessions = <DocumentScriptSession>[];
  var inFlight = 0, peak = 0;

  @override
  Future<DocumentScriptSession> open() async {
    final session = await super.open();
    sessions.add(session);
    return session;
  }

  @override
  Future<String> evaluate(DocumentScriptSession session, String source) async {
    await super.evaluate(session, source);
    (evaluations[session.id] ??= []).add(source);
    final answer = respond?.call(session, source);
    if (answer != null) return jsonEncode(answer);
    if (source.startsWith('__pircDocument.storage') ||
        source.startsWith('__pircDocument.syncCookies')) {
      return '{"ok":true}';
    }
    return jsonEncode({'html': '<body></body>', 'diagnostics': []});
  }

  @override
  Future<DocumentResourceResponse> resource(
    DocumentScriptSession session,
    DocumentResourceRequest request,
  ) async {
    calls.add('resource');
    resources.add((session.id, request));
    // As Kotlin: a request over the cap is refused, not queued.
    if (inFlight >= DocumentResourceLimiter.maxInFlight) {
      throw PlatformException(code: ScriptsError.resource);
    }
    inFlight++;
    if (inFlight > peak) peak = inFlight;
    final answer = Completer<DocumentResourceResponse>();
    pending.add(answer);
    try {
      return await answer.future;
    } finally {
      inFlight--;
    }
  }
}

DocumentResourceResponse ok([
  String text = 'ok',
  String mimeType = 'text/plain',
  String type = 'cors',
]) => DocumentResourceResponse(
  status: 200,
  statusText: 'OK',
  url: 'https://example.test/r',
  headers: const [],
  body: Uint8List.fromList(utf8.encode(text)),
  type: type,
  redirected: false,
  mimeType: mimeType,
  originClean: type == 'cors',
);

String sri(String text) =>
    'sha384-${base64.encode(sha384.convert(utf8.encode(text)).bytes)}';

/// A runtime answer that asks for one linked stylesheet.
Json? linkedStylesheet(String source, Json request) {
  final init = source.startsWith('__pircDocument.init(');
  // Every snapshot names the stylesheet owner, as the runtime's do.
  if (!init && !source.startsWith('__pircDocument.snapshot(')) return null;
  return {
    'html': '<body></body>',
    'diagnostics': [],
    'stylesheets': {
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
          'baseURL': 'https://example.test/',
          'fetchHref': 'https://cdn.example/theme.css',
          'requestable': true,
          'isStylesheet': true,
        },
      ],
    },
    'resourceRequests': [
      if (init)
        {
          'id': 'stylesheet-1',
          'kind': 'stylesheet',
          'ownerType': 'link',
          'url': 'https://cdn.example/theme.css',
          'baseURL': 'https://example.test/',
          ...request,
        },
    ],
  };
}

String completionOf(RuntimeFake platform) => platform.evaluations[1]!
    .firstWhere((s) => s.startsWith('__pircDocument.completeResource('));

Future<void> settle() async {
  for (var i = 0; i < 20; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

Json? emitOnce(String source, List<Json> requests) {
  if (!source.startsWith('__pircDocument.init(')) return null;
  return {
    'html': '<body></body>',
    'diagnostics': [],
    'resourceRequests': requests,
  };
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('the cap of 6 requests in flight', () {
    test('a request over the cap waits for a slot', () async {
      final limiter = DocumentResourceLimiter();
      final gates = [for (var i = 0; i < 9; i++) Completer<int>()];
      final started = <int>[];
      final results = [
        for (final (i, gate) in gates.indexed)
          limiter.run(() {
            started.add(i);
            return gate.future.then((_) => i);
          }),
      ];
      await settle();
      expect(started, [0, 1, 2, 3, 4, 5]);
      expect(limiter.waiting, 3);
      // Waiting requests start in arrival order, one per freed slot.
      gates[3].complete(0);
      await settle();
      expect(started, [0, 1, 2, 3, 4, 5, 6]);
      expect(limiter.active, 6);
      gates[0].complete(0);
      await settle();
      expect(started, [0, 1, 2, 3, 4, 5, 6, 7]);
      for (final gate in gates) {
        if (!gate.isCompleted) gate.complete(0);
      }
      expect(await Future.wait(results), [0, 1, 2, 3, 4, 5, 6, 7, 8]);
      expect(started, [0, 1, 2, 3, 4, 5, 6, 7, 8]);
      expect(limiter.active, 0);
    });

    test(
      'callers that arrive while the slot is busy run one at a time',
      () async {
        final limiter = DocumentResourceLimiter(maximum: 1);
        final first = Completer<void>();
        var running = 0, peak = 0;
        Future<void> job(Future<void> wait) => limiter.run(() async {
          running++;
          if (running > peak) peak = running;
          await wait;
          running--;
        });
        final a = job(first.future);
        final b = job(Future.value());
        await settle();
        first.complete();
        final c = job(Future.value());
        await Future.wait([a, b, c]);
        expect(peak, 1);
      },
    );

    test(
      'a cancelled waiting request leaves the queue and never runs',
      () async {
        final limiter = DocumentResourceLimiter(maximum: 1);
        final gate = Completer<void>();
        final ran = <String>[];
        final running = limiter.run(() async {
          ran.add('a');
          await gate.future;
        }, id: 'a');
        final b = limiter.run(() async => ran.add('b'), id: 'b');
        final c = limiter.run(() async => ran.add('c'), id: 'c');
        await settle();
        expect(limiter.cancel('b'), isTrue);
        // A running request is not affected; Kotlin cancels it.
        expect(limiter.cancel('a'), isFalse);
        expect(limiter.cancel('unknown'), isFalse);
        await expectLater(b, throwsStateError);
        expect(limiter.waiting, 1);
        gate.complete();
        await Future.wait([running, c]);
        expect(ran, ['a', 'c']);
        expect(limiter.active, 0);
      },
    );

    test('closing fails the waiting requests', () async {
      final limiter = DocumentResourceLimiter(maximum: 1);
      final gate = Completer<void>();
      final running = limiter.run(() => gate.future);
      final waiting = limiter.run(() async {});
      limiter.close();
      await expectLater(waiting, throwsStateError);
      gate.complete();
      await running;
      expect(() => limiter.run(() async {}), throwsStateError);
    });

    // The document's own resource queue holds the 7th and 8th request until
    // a slot is free, so the channel never sees more than 6 and none is
    // refused; the limiter above guards every other caller of `resource`.
    test(
      'a document has at most 6 requests out and still finishes all 8',
      () async {
        final platform = RuntimeFake(
          respond: (_, source) => emitOnce(source, [
            for (var i = 1; i <= 8; i++)
              {
                'id': 'fetch-$i',
                'kind': 'fetch',
                'url': 'https://example.test/$i',
              },
          ]),
        );
        final scripts = NativeDocumentScripts(platform);
        addTearDown(scripts.dispose);
        await scripts.start(source: '<p>x</p>', url: 'https://example.test/');
        await settle();
        expect(scripts.ready, isTrue);
        expect(platform.resources, hasLength(6));
        expect(platform.peak, 6);
        platform.pending.first.complete(ok());
        await settle();
        expect(platform.resources, hasLength(7));
        for (final answer in platform.pending.skip(1)) {
          if (!answer.isCompleted) answer.complete(ok());
        }
        await settle();
        for (final answer in platform.pending) {
          if (!answer.isCompleted) answer.complete(ok());
        }
        await settle();
        expect(platform.resources, hasLength(8));
        expect(platform.peak, 6);
        final completions = platform.evaluations[1]!
            .where((s) => s.startsWith('__pircDocument.completeResource('))
            .toList();
        expect(completions, hasLength(8));
        expect(completions.every((s) => s.contains('"ok":true')), isTrue);
      },
    );
  });

  group('requests carry no credentials', () {
    test('credential fields are dropped and credential headers refused', () {
      final wire = documentResourceRequest({
        'id': 'fetch-1',
        'kind': 'fetch',
        'url': 'https://example.test/api',
        'method': 'POST',
        'headers': [
          ['content-type', 'text/plain'],
        ],
        'bodyBase64': base64Encode(utf8.encode('hi')),
        'mode': 'cors',
        'credentials': 'include',
        'referrerPolicy': 'unsafe-url',
        'forcePreflight': true,
      }).toWire();
      expect(wire.keys, isNot(contains('credentials')));
      expect(wire.keys, isNot(contains('referrerPolicy')));
      expect(wire.keys, isNot(contains('forcePreflight')));
      expect(wire['bodyBytes'], utf8.encode('hi'));
      for (final name in ['Authorization', 'Cookie', 'Proxy-Authorization']) {
        expect(
          () => documentResourceRequest({
            'id': 'fetch-2',
            'kind': 'fetch',
            'url': 'https://example.test/',
            'headers': [
              [name, 'x'],
            ],
          }),
          throwsArgumentError,
        );
      }
    });

    test('same-origin requests fail: an opaque origin has none', () {
      expect(
        () => documentResourceRequest({
          'id': 'fetch-1',
          'kind': 'fetch',
          'url': 'https://example.test/',
          'mode': 'same-origin',
        }),
        throwsStateError,
      );
    });

    test('scripts choose their kind and mode as browsers do', () {
      Json wire(Json request) => documentResourceRequest({
        'id': 'script-1',
        'kind': 'script',
        'url': 'https://cdn.example/a.js',
        ...request,
      }).toWire();
      expect(wire({'type': 'module'})['kind'], 'module');
      expect(wire({})['kind'], 'script');
      expect(wire({})['mode'], 'no-cors');
      expect(wire({'crossOrigin': 'anonymous'})['mode'], 'cors');
      expect(
        () => documentResourceRequest({
          'id': 'image-1',
          'kind': 'image',
          'url': 'https://example.test/a.png',
        }),
        throwsFormatException,
      );
    });

    test('a remote image never reaches the channel', () async {
      final platform = RuntimeFake(
        respond: (_, source) => emitOnce(source, [
          {
            'id': 'image-1',
            'kind': 'image',
            'url': 'https://example.test/a.png',
          },
        ]),
      );
      final scripts = NativeDocumentScripts(platform);
      addTearDown(scripts.dispose);
      await scripts.start(source: '<img>', url: 'https://example.test/');
      await settle();
      expect(platform.resources, isEmpty);
      final completion = platform.evaluations[1]!.firstWhere(
        (s) => s.startsWith('__pircDocument.completeResource('),
      );
      expect(completion, contains('"ok":false'));
      expect(completion, contains('only after a tap'));
    });
  });

  group('Subresource Integrity', () {
    final bytes = Uint8List.fromList(utf8.encode('alert(1)'));
    final good = 'sha384-${base64.encode(sha384.convert(bytes).bytes)}';

    test('a matching hash passes and a wrong one fails', () {
      expect(
        documentIntegrityMatches(good, bytes, responseType: 'cors'),
        isTrue,
      );
      expect(
        documentIntegrityMatches(
          'sha384-${base64.encode(sha384.convert([1]).bytes)}',
          bytes,
          responseType: 'cors',
        ),
        isFalse,
      );
      // The strongest algorithm decides.
      expect(
        documentIntegrityMatches(
          'sha256-${base64.encode(sha256.convert(bytes).bytes)} sha512-AAAA',
          bytes,
          responseType: 'cors',
        ),
        isFalse,
      );
      expect(
        documentIntegrityMatches('md5-x', bytes, responseType: 'cors'),
        isTrue,
      );
    });

    test('an opaque response never passes a non-empty check', () {
      expect(
        documentIntegrityMatches(good, bytes, responseType: 'opaque'),
        isFalse,
      );
      expect(
        documentIntegrityMatches(null, bytes, responseType: 'opaque'),
        isTrue,
      );
    });

    test('a no-cors script with integrity fails closed', () async {
      final platform = RuntimeFake(
        respond: (_, source) => emitOnce(source, [
          {
            'id': 'script-1',
            'kind': 'script',
            'url': 'https://cdn.example/a.js',
            // No crossorigin attribute: a no-cors request, opaque response.
            'integrity': sri('alert(1)'),
          },
        ]),
      );
      final scripts = NativeDocumentScripts(platform);
      addTearDown(scripts.dispose);
      await scripts.start(source: '<script>', url: 'https://example.test/');
      await settle();
      expect(platform.resources.single.$2.mode, 'no-cors');
      // The right bytes, but the document may not read them.
      platform.pending.single.complete(
        ok('alert(1)', 'text/javascript', 'opaque'),
      );
      await settle();
      final completion = completionOf(platform);
      expect(completion, contains('"ok":false'));
      expect(completion, isNot(contains('alert(1)')));
      expect(completion, contains('integrity check'));
    });

    for (final (label, integrity, loaded) in [
      ('a matching', sri('p{color:red}'), true),
      ('a wrong', sri('p{color:blue}'), false),
    ]) {
      test(
        'a stylesheet with $label hash ${loaded ? 'applies' : 'is refused'}',
        () async {
          final platform = RuntimeFake(
            respond: (_, source) => linkedStylesheet(source, {
              'crossOrigin': 'anonymous',
              'integrity': integrity,
            }),
          );
          final scripts = NativeDocumentScripts(platform);
          addTearDown(scripts.dispose);
          await scripts.start(source: '<link>', url: 'https://example.test/');
          await settle();
          expect(platform.resources.single.$2.mode, 'cors');
          platform.pending.single.complete(ok('p{color:red}', 'text/css'));
          await settle();
          expect(completionOf(platform), contains('"ok":$loaded'));
          if (!loaded) {
            expect(completionOf(platform), contains('integrity check'));
          }
          expect(
            scripts.stylesheets?.any(
                  (sheet) => sheet.cssText.contains('red'),
                ) ??
                false,
            loaded,
          );
        },
      );
    }

    test('a no-cors stylesheet with integrity is refused', () async {
      final platform = RuntimeFake(
        respond: (_, source) =>
            linkedStylesheet(source, {'integrity': sri('p{color:red}')}),
      );
      final scripts = NativeDocumentScripts(platform);
      addTearDown(scripts.dispose);
      await scripts.start(source: '<link>', url: 'https://example.test/');
      await settle();
      expect(platform.resources.single.$2.mode, 'no-cors');
      platform.pending.single.complete(
        ok('p{color:red}', 'text/css', 'opaque'),
      );
      await settle();
      expect(completionOf(platform), contains('"ok":false'));
      expect(completionOf(platform), contains('integrity check'));
    });

    test('a script that fails its check is not given to the runtime', () async {
      final platform = RuntimeFake(
        respond: (_, source) => emitOnce(source, [
          {
            'id': 'script-1',
            'kind': 'script',
            'url': 'https://cdn.example/a.js',
            'crossOrigin': 'anonymous',
            'integrity': 'sha384-${base64.encode(sha384.convert([1]).bytes)}',
          },
        ]),
      );
      final scripts = NativeDocumentScripts(platform);
      addTearDown(scripts.dispose);
      await scripts.start(source: '<script>', url: 'https://example.test/');
      await settle();
      platform.pending.single.complete(ok('alert(1)'));
      await settle();
      final completion = platform.evaluations[1]!.firstWhere(
        (s) => s.startsWith('__pircDocument.completeResource('),
      );
      expect(completion, contains('"ok":false'));
      expect(completion, isNot(contains('alert(1)')));
    });
  });

  group('storage and cookies are per document', () {
    test(
      'a second document at the same origin sees none of the first',
      () async {
        int? generation;
        var wrote = false;
        final platform = RuntimeFake(
          respond: (session, source) {
            if (session.id != 1) return null;
            if (source.startsWith('__pircDocument.storageSyncBegin(')) {
              generation =
                  obj(
                        jsonDecode(source.substring(32, source.length - 1)),
                      )['generation']
                      as int;
              return {'ok': true};
            }
            if (source.startsWith('__pircDocument.init(') && !wrote) {
              wrote = true;
              return {
                'html': '<body></body>',
                'diagnostics': [],
                'storageWritesPending': true,
              };
            }
            if (source.startsWith('__pircDocument.storageWritesBegin(')) {
              return {'count': 1};
            }
            if (source.startsWith('__pircDocument.storageWriteInfo(')) {
              return {
                'area': 'local',
                'type': 'set',
                'generation': generation,
                'keyLength': 3,
                'valueLength': 6,
              };
            }
            if (source.startsWith('__pircDocument.storageWritePart(')) {
              final part = obj(
                jsonDecode(source.substring(32, source.length - 1)),
              );
              return {'text': part['part'] == 'key' ? 'key' : 'secret'};
            }
            return null;
          },
        );
        final first = NativeDocumentScripts(platform);
        addTearDown(first.dispose);
        await first.start(source: '<p>1</p>', url: 'https://example.test/');
        await settle();
        expect(first.ready, isTrue);
        final firstSession = platform.sessions.single;
        final firstStore = await platform.storage(firstSession);
        expect(firstStore.local, {'key': 'secret'});
        await platform.cookies(firstSession, ['secret=1']);

        final second = NativeDocumentScripts(platform);
        addTearDown(second.dispose);
        await second.start(source: '<p>2</p>', url: 'https://example.test/');
        await settle();
        expect(second.ready, isTrue);
        final seen = platform.evaluations[2]!.join('\n');
        expect(seen, isNot(contains('secret')));
        expect(seen, contains('"cookieState":{'));
      },
    );
  });
}
