import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_app/l10n/app_localizations.dart';
import 'package:pirc_app/src/document_host.dart' as web;
import 'package:pirc_app/src/document_host_io.dart';
import 'package:pirc_app/src/connection/storage.dart';
import 'package:pirc_app/src/document_media.dart';
import 'package:pirc_app/src/platform/files.dart';
import 'package:pirc_app/src/platform/media.dart';
import 'package:pirc_app/src/render_bridge.dart';
import 'package:pirc_render/pirc_render.dart';
import 'package:pirc_render_document/pirc_render_document.dart';

import 'support/harness.dart';
import 'support/session_fixture.dart';
import 'package:html/parser.dart' as html;
// ignore: implementation_imports
import 'package:pirc_render/src/html_media_spec.dart';

/// Safety regressions of M8 step 6 (default suite, never tagged): documents
/// from a message or a tool result run with an opaque origin. They never
/// receive the device token or a Gateway cookie, their storage is their
/// own, and their remote media load only after a tap.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('org.mozufu.pirc/scripts');
  final calls = <MethodCall>[];

  setUp(() {
    calls.clear();
    var next = 1;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return switch (call.method) {
            'open' => {'id': next++, 'origin': 'null'},
            'storage' => {
              'local': <String, String>{},
              'session': <String, String>{},
            },
            'cookies' => {'cookie': ''},
            'evaluate' => {'value': ''},
            'resource' => {'status': 200, 'type': 'cors', 'headers': []},
            'media' => {'bytes': Uint8List(1), 'mimeType': 'audio/mpeg'},
            _ => null,
          };
        });
  });

  tearDown(
    () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null),
  );

  group('install', () {
    test('the app-wide host never carries the document runtime', () {
      final android = documentRenderHost(platform: TargetPlatform.android);
      expect(android.documentRuntime, isNull);
      expect(android.mediaBuilder, isNotNull);
      for (final platform in [TargetPlatform.macOS, TargetPlatform.iOS]) {
        final host = documentRenderHost(platform: platform);
        expect(host.documentRuntime, isNull);
        expect(host.mediaBuilder, isNull);
      }
      // The Web build compiles the stub, which has no runtime anywhere.
      expect(web.documentRenderHost().documentRuntime, isNull);
      expect(
        web.documentRenderHost(platform: TargetPlatform.android).mediaBuilder,
        isNull,
      );
      // Only a fetched-document view gets the runtime, with its scope.
      expect(
        fetchedDocumentHost(documentScopeOf: (_) => null).documentRuntime,
        isA<NativeDocumentRuntime>(),
      );
    });
  });

  group('a message document through the Android host', () {
    const token = 'pirc_dev_seeded_device_token_7f3a';
    const media = MethodChannel('org.mozufu.pirc/media');
    const html =
        '<p>Report</p>'
        '<video controls src="https://media.example/clip.mp4"></video>'
        '<dialog open data-pirc-dialog-modal="1">Covering dialog</dialog>'
        '<canvas width="40" height="20"></canvas>'
        '<script>fetch("/api/devices", {credentials: "include"}); '
        'localStorage.setItem("k", document.cookie)</script>';

    appTest('gets no token, no Gateway address and no runtime', (tester) async {
      final previous = RenderHost.fallback;
      RenderHost.fallback = documentRenderHost(
        platform: TargetPlatform.android,
      );
      addTearDown(() => RenderHost.fallback = previous);
      final mediaCalls = <MethodCall>[];
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(media, (call) async {
        mediaCalls.add(call);
        return {'id': 1, 'width': 16, 'height': 9, 'playing': true};
      });
      addTearDown(() => messenger.setMockMethodCallHandler(media, null));

      final session = FixtureSession('joined-mid-stream.json');
      (session.snapshot['history']! as List).add({
        'role': 'assistant',
        'content': [
          {'type': 'text', 'text': html},
        ],
        'stopReason': 'stop',
        'timestamp': 5000,
      });
      final gateway = session.install();
      await pumpApp(
        tester,
        gateway: gateway,
        width: 1300,
        height: 2400,
        location: '/work?open=s2',
        saved: Saved(secrets: {deviceTokenKey: token}),
      );
      // The app itself holds the token: the Gateway transport reads it.
      expect(await gateway.tokens.last!.read(), token);

      // Nothing loads, and no script or runtime runs, before a tap.
      final load = find.byKey(const Key('message-media-load'));
      expect(load, findsOneWidget);
      expect(calls, isEmpty);
      expect(mediaCalls, isEmpty);
      expect(find.text('Covering dialog', findRichText: true), findsOneWidget);
      final article = tester.element(load);
      expect(RenderHost.of(article).documentRuntime, isNull);

      await tester.ensureVisible(load);
      await tester.pumpAndSettle();
      await tester.tap(load);
      await tester.pumpAndSettle();
      expect(calls.map((call) => call.method), ['media']);
      expect(calls.single.arguments['url'], 'https://media.example/clip.mp4');
      expect(mediaCalls.map((call) => call.method), contains('open'));

      // No channel call carries the token, a Bearer header, a cookie or the
      // Gateway's address; the Gateway never saw a request for the media.
      for (final call in [...calls, ...mediaCalls]) {
        final wire = jsonEncode(
          call.arguments,
          toEncodable: (value) => value is Uint8List ? '<bytes>' : '$value',
        );
        expect(wire, isNot(contains(token)), reason: call.method);
        expect(wire.toLowerCase(), isNot(contains('bearer')));
        expect(wire.toLowerCase(), isNot(contains('cookie')));
        expect(wire, isNot(contains('gateway.test')));
      }
      expect(
        gateway.requests.where((r) => r.path.contains('clip.mp4')),
        isEmpty,
      );
    });
  });

  group('scripts channel', () {
    test('no call carries a token, a Gateway cookie or credentials', () async {
      const scripts = ChannelScriptsPlatform();
      final a = await scripts.open();
      final b = await scripts.open();
      await scripts.loadRuntime(a);
      await scripts.evaluate(a, 'document.cookie');
      await scripts.storage(a, [
        const DocumentStorageOperation.set('local', 'k', 'v'),
      ]);
      await scripts.cookies(b, ['theme=dark']);
      await scripts.resource(
        a,
        DocumentResourceRequest(
          id: 'fetch-1',
          url: Uri.parse('https://api.example/data'),
          headers: const [('Accept', 'application/json')],
        ),
      );
      await scripts.media(
        Uri.parse('https://media.example/a.mp3'),
        requestId: 'm1',
      );
      await scripts.closeAll();
      const forbiddenKeys = {
        'token',
        'authorization',
        'cookie',
        'gateway',
        'gatewayUrl',
        'pairing',
        'partition',
        'documentUrl',
      };
      for (final call in calls) {
        final wire = jsonEncode(
          call.arguments,
          toEncodable: (value) => '$value',
        );
        expect(wire, isNot(contains('pirc_dev_')), reason: call.method);
        expect(
          wire.toLowerCase(),
          isNot(contains('bearer')),
          reason: call.method,
        );
        void keys(Object? value) {
          if (value is Map) {
            for (final MapEntry(:key, value: inner) in value.entries) {
              expect(forbiddenKeys, isNot(contains(key)), reason: call.method);
              keys(inner);
            }
          } else if (value is List) {
            value.forEach(keys);
          }
        }

        keys(call.arguments);
      }
      // Each call names only its own session, by the owner only this app
      // knows; there is no storage key to ask for another message's data.
      final storage = calls.singleWhere((call) => call.method == 'storage');
      expect(storage.arguments['id'], a.id);
      expect(storage.arguments['owner'], a.owner);
      final cookies = calls.singleWhere((call) => call.method == 'cookies');
      expect(cookies.arguments['id'], b.id);
      expect(cookies.arguments['owner'], b.owner);
      expect(a.owner, isNot(b.owner));
      expect(a.origin, 'null');
    });

    test('credential headers and non-http URLs are refused before Kotlin', () {
      for (final header in ['Authorization', 'cookie', 'Proxy-Authorization']) {
        expect(
          () => DocumentResourceRequest(
            id: 'x',
            url: Uri.parse('https://api.example/'),
            headers: [(header, 'Bearer pirc_dev_secret')],
          ),
          throwsArgumentError,
        );
      }
      for (final url in ['/relative', 'blob:null/1', 'file:///etc/hosts']) {
        expect(
          () => DocumentResourceRequest(id: 'x', url: Uri.parse(url)),
          throwsArgumentError,
        );
      }
      expect(
        () => DocumentResourceRequest(
          id: 'x',
          url: Uri.parse('https://img.example/a.png'),
          kind: 'image',
        ),
        throwsArgumentError,
      );
      expect(
        () => const ChannelScriptsPlatform().media(
          Uri.parse('content://media/1'),
          requestId: 'm',
        ),
        throwsArgumentError,
      );
      expect(calls, isEmpty);
    });

    // The real isolation of storage and cookies is in Kotlin
    // (ScriptsChannelTest: eachMessageDocumentHasItsOwnStorage and
    // eachMessageDocumentHasItsOwnCookies). The fake enforces the same rules.
    test('the fake keeps each message document\'s storage apart', () async {
      final scripts = FakeScriptsPlatform();
      final a = await scripts.open(), b = await scripts.open();
      await scripts.storage(a, [
        const DocumentStorageOperation.set('local', 'k', 'a'),
      ]);
      expect((await scripts.storage(b)).local, isEmpty);
      expect((await scripts.storage(a)).local, {'k': 'a'});
      // Another document's ID with this owner, or the reverse, is refused.
      expect(
        () => scripts.storage(DocumentScriptSession(a.id, b.owner)),
        throwsA(isA<PlatformException>()),
      );
      await scripts.close(a);
      expect(() => scripts.storage(a), throwsA(isA<PlatformException>()));
    });
  });

  group('message media', () {
    Future<void> pump(
      WidgetTester tester,
      String html,
      RenderMediaBuilder builder,
    ) => tester.pumpWidget(
      MaterialApp(
        theme: appTheme(Brightness.light),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: RenderHostScope(
          host: RenderHost(mediaBuilder: builder),
          child: Scaffold(
            body: SingleChildScrollView(child: NativeMarkdown(source: html)),
          ),
        ),
      ),
    );

    testWidgets('remote media load only after a tap', (tester) async {
      final players = FakeMediaPlayers();
      final fetched = <Uri>[];
      await pump(
        tester,
        '<video controls src="https://media.example/clip.mp4"></video>',
        messageMediaBuilder(
          players: players,
          fetch: (url, request) async {
            fetched.add(url);
            return (Uint8List(4), 'video/mp4');
          },
          cancel: (_) async {},
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('message-media-load')), findsOneWidget);
      expect(find.text('From media.example'), findsOneWidget);
      expect(fetched, isEmpty);
      expect(players.opened, isEmpty);

      await tester.tap(find.byKey(const Key('message-media-load')));
      await tester.pumpAndSettle();
      expect(fetched, [Uri.parse('https://media.example/clip.mp4')]);
      expect(players.opened, hasLength(1));
      expect(find.byType(Texture), findsOneWidget);

      // Leaving the message closes its player.
      expect(players.players, hasLength(1));
      await tester.pumpWidget(const SizedBox());
      expect(players.players, isEmpty);
    });

    testWidgets('media of a fetched document is left to its document', (
      tester,
    ) async {
      final builder = messageMediaBuilder(
        players: FakeMediaPlayers(),
        fetch: (_, _) => throw StateError('no fetch'),
        cancel: (_) async {},
      );
      final spec = NativeHtmlMediaSpec.fromElement(
        html
            .parseFragment('<audio src="https://a.example/a.mp3"></audio>')
            .children
            .single,
      );
      expect(builder(_Scope(), spec, const {}), isNull);
      expect(builder(null, spec, const {}), isA<MessageMedia>());
    });
  });

  group('downloads', () {
    test('a data: link is saved through the save picker', () async {
      final files = FakeFilesPlatform();
      files.saves.add('notes.txt');
      final saved = await saveDocumentLink(
        files,
        'data:text/plain;base64,${base64Encode(utf8.encode('hi'))}',
        download: '../../notes.txt',
      );
      expect(saved, 'notes.txt');
      final (name, mimeType, bytes) = files.saved.single;
      expect(name, 'notes.txt');
      expect(mimeType, 'text/plain');
      expect(utf8.decode(bytes), 'hi');
    });

    test('remote and blob downloads are refused', () {
      final files = FakeFilesPlatform();
      for (final href in [
        'https://files.example/a.zip',
        'blob:null/4f1c',
        '/api/files/a',
      ]) {
        expect(
          () => saveDocumentLink(files, href, download: 'a.zip'),
          throwsA(isA<DocumentDownloadRefused>()),
        );
      }
      expect(files.saved, isEmpty);
    });
  });
}

class _Scope implements RenderDocumentScope {
  @override
  Object get accountIdentity => 'account';
  @override
  String? get documentUrl => 'https://doc.example/';
  @override
  RenderDocumentWindow? get window => null;
  @override
  RenderDocumentWindows get windows => throw UnimplementedError();
}
