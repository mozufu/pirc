import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_mobile/l10n/app_i18n.dart';
import 'package:pirc_mobile/live/common.dart';
import 'package:pirc_mobile/live/document_navigation.dart';
import 'package:pirc_mobile/live/document_navigation_state.dart';
import 'package:pirc_render/src/html_document_content.dart';
import 'package:pirc_mobile/live/gateway.dart';
import 'package:pirc_render/src/remote_content_gate.dart';
import 'package:pirc_mobile/live/timeline_tools.dart';
import 'package:pirc_render/src/native_markdown.dart';

import 'live_test.dart' show theme;

final _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
);

/// The bridge methods that put a request on the network on behalf of content.
const _fetching = {
  'image',
  'htmlMediaOpen',
  'document',
  'documentStylesheet',
  'documentScriptResource',
};

/// Counts every request content could cause: bridge fetches at the fake
/// gateway and anything the standalone renderer would send itself.
class _CountingGateway extends Gateway {
  final fetches = <String>[];
  final others = <String>[];
  @override
  Future<dynamic> call(String method, [Json args = const {}]) async {
    if (_fetching.contains(method)) {
      fetches.add('$method ${args['source'] ?? args['url'] ?? ''}');
    } else {
      others.add(method);
    }
    switch (method) {
      case 'image':
        return {'bytes': Uint8List.fromList(_png), 'mimeType': 'image/png'};
      case 'boot':
        return {'origin': 'https://gateway.example', 'pairingStamp': 'stamp'};
      case 'htmlMediaOpen':
        throw StateError('no media in tests');
    }
    return {};
  }
}

/// Flutter keeps one shared HTTP client for network images, so every test
/// reads the same list, cleared before each test.
final _networkUrls = <String>[];

class _CountingHttp implements HttpClient {
  _CountingHttp();
  final urls = _networkUrls;
  @override
  dynamic noSuchMethod(Invocation invocation) {
    final name = invocation.memberName.toString();
    if (name.contains('getUrl') ||
        name.contains('openUrl') ||
        name.contains('postUrl')) {
      urls.add('${invocation.positionalArguments.last}');
      throw const SocketException('blocked by test');
    }
    // Property setters (autoUncompress and the like) are harmless.
    return null;
  }
}

class _HttpCounter {
  List<String> get urls => _networkUrls;
}

const _remoteMessage = '''
Before ![md alt](https://img.example.test/md.png "md title") after

<img src="https://img.example.test/html.png" alt="html alt" loading="eager" decoding="sync" fetchpriority="high">

<img src="https://img.example.test/base.png" srcset="https://img.example.test/s1.png 1x, https://img.example.test/s2.png 2x" alt="srcset alt">

<picture><source srcset="https://img.example.test/pic.webp" type="image/webp"><img src="https://img.example.test/pic.png" alt="picture alt"></picture>

<img src="/api/relative.png" alt="relative alt">

<video src="https://media.example.test/v.mp4" poster="https://img.example.test/poster.png" controls></video>

<audio src="https://media.example.test/a.mp3" controls></audio>

<video controls><source src="https://media.example.test/s.mp4" type="video/mp4"><track src="https://media.example.test/t.vtt"></video>

<div style="background:url(https://img.example.test/bg.png);height:20px">bg</div>

<div style="background-image:url('https://img.example.test/bg2.png');height:20px">bg2</div>

<ul style="list-style-image:url(https://img.example.test/li.png)"><li>item</li></ul>

<div style="border:10px solid red;border-image:url(https://img.example.test/bi.png) 30 round">bi</div>

<div style="mask-image:url(https://img.example.test/mask.png);cursor:url(https://img.example.test/cur.png),auto">mask</div>

<p style="content:url(https://img.example.test/content.png)">content</p>

<svg width="40" height="40" xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink"><image href="https://img.example.test/svgimg.png" xlink:href="https://img.example.test/svgimg2.png" width="40" height="40"/><use href="https://img.example.test/sym.svg#a"/><use xlink:href="https://img.example.test/sym2.svg#b"/></svg>

<form action="https://recv.example.test/post"><input type="image" src="https://img.example.test/submit.png" alt="go"><input name="q" value="1"></form>

<a href="https://x.example.test/y" ping="https://img.example.test/ping">link</a>

<table background="https://img.example.test/tbl.png"><tr><td background="https://img.example.test/td.png">c</td></tr></table>

<img lowsrc="https://img.example.test/low.png" dynsrc="https://img.example.test/dyn.png" alt="legacy">

<link rel="preload" as="image" href="https://img.example.test/preload.png">
<link rel="icon" href="https://img.example.test/icon.png">
<meta http-equiv="refresh" content="0;url=https://img.example.test/refresh">
<style>@import url(https://img.example.test/import.css); body{background:url(https://img.example.test/style.png)}</style>
''';

Widget _host(
  _CountingGateway gateway,
  NativeDocumentWindows windows,
  String text, {
  bool? loadOnActivation,
}) {
  Widget body = SingleChildScrollView(
    child: RichTextBody(text, gateway: gateway),
  );
  if (loadOnActivation != null) {
    body = NativeRemoteContentPolicy(
      loadOnActivation: loadOnActivation,
      child: body,
    );
  }
  return MaterialApp(
    theme: theme.build(Brightness.light),
    home: NativeDocumentScope(
      windows: windows,
      documentUrl: 'https://gateway.example/?session=s',
      sourceIdentity: windows.accountIdentity,
      child: Scaffold(body: body),
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(_networkUrls.clear);
  tearDown(() => AppI18n.instance.setLanguage('en'));

  Future<(_CountingGateway, NativeDocumentWindows)> pump(
    WidgetTester t,
    String text, {
    bool? loadOnActivation,
  }) async {
    final gateway = _CountingGateway();
    final windows = NativeDocumentWindows(
      gateway,
      appDocumentUrl: () => 'https://gateway.example/?session=s',
    );
    addTearDown(windows.dispose);
    await t.pumpWidget(
      _host(gateway, windows, text, loadOnActivation: loadOnActivation),
    );
    await t.pumpAndSettle();
    return (gateway, windows);
  }

  testWidgets(
    'sensitivity check: the same message does reach the network when loading is not held',
    (t) async {
      await HttpOverrides.runZoned(() async {
        final (gateway, _) = await pump(
          t,
          _remoteMessage,
          loadOnActivation: false,
        );
        // The inventory of resource paths the engine implements for this
        // message. Anything else in it (CSS list-style/border/mask/cursor/
        // content urls, SVG image/use, input type=image, track, ping, legacy
        // background attributes, link/meta/@import) is never requested, with
        // or without the hold-back. A new path appearing here must be gated.
        expect(gateway.fetches, [
          'image https://img.example.test/md.png',
          'image https://img.example.test/html.png',
          'image https://img.example.test/s2.png',
          'image https://img.example.test/pic.webp',
          'image /api/relative.png',
          'image https://img.example.test/poster.png',
          'image https://img.example.test/bg.png',
          'image https://img.example.test/bg2.png',
          'htmlMediaOpen https://media.example.test/v.mp4',
          'htmlMediaOpen https://media.example.test/a.mp3',
          'htmlMediaOpen https://media.example.test/s.mp4',
        ]);
      }, createHttpClient: (c) => _CountingHttp());
    },
  );

  testWidgets(
    'remote images and media in a chat message cause no request before a tap',
    (t) async {
      final counter = _HttpCounter();
      await HttpOverrides.runZoned(() async {
        final (gateway, _) = await pump(t, _remoteMessage);
        expect(
          gateway.fetches,
          isEmpty,
          reason: 'no bridge fetch before activation',
        );
        expect(counter.urls, isEmpty, reason: 'no dart:io request either');
        expect(gateway.others.where((m) => m.contains('image')), isEmpty);
        final placeholders = find.byKey(
          const ValueKey('remote-content-placeholder'),
        );
        // md, html, srcset, picture, relative, video, audio, video+source.
        expect(placeholders, findsNWidgets(8));
        // Alt text and the source host are what the user sees.
        expect(find.text('md alt'), findsOneWidget);
        expect(find.text('html alt'), findsOneWidget);
        expect(find.text('Remote image from img.example.test'), findsWidgets);
        expect(find.text('Remote media from media.example.test'), findsWidgets);
        expect(find.text('https://img.example.test/md.png'), findsOneWidget);
        expect(find.text('Remote image from this server'), findsOneWidget);
      }, createHttpClient: (c) => _CountingHttp());
    },
  );

  testWidgets('a tap loads exactly the tapped image and nothing else', (
    t,
  ) async {
    final (gateway, _) = await pump(t, _remoteMessage);
    expect(gateway.fetches, isEmpty);
    await t.tap(find.text('md alt'));
    await t.pumpAndSettle();
    expect(gateway.fetches, ['image https://img.example.test/md.png']);
    // Its placeholder is gone; the other seven remain untouched.
    expect(
      find.byKey(const ValueKey('remote-content-placeholder')),
      findsNWidgets(7),
    );
    await t.tap(find.text('html alt'));
    await t.pumpAndSettle();
    expect(gateway.fetches, [
      'image https://img.example.test/md.png',
      'image https://img.example.test/html.png',
    ]);
  });

  testWidgets('a tapped srcset image requests only the candidate it chose', (
    t,
  ) async {
    final (gateway, _) = await pump(t, _remoteMessage);
    await t.tap(find.text('srcset alt'));
    await t.pumpAndSettle();
    expect(gateway.fetches, hasLength(1));
    expect(
      gateway.fetches.single,
      startsWith('image https://img.example.test/'),
    );
    expect(gateway.fetches.single, isNot(contains('/md.png')));
  });

  testWidgets('inline data: images keep displaying without a tap', (t) async {
    final data = 'data:image/png;base64,${base64Encode(_png)}';
    final (gateway, _) = await pump(
      t,
      '![inline]($data)\n\n<img src="$data" alt="inline html">',
    );
    expect(gateway.fetches, isEmpty);
    expect(
      find.byKey(const ValueKey('remote-content-placeholder')),
      findsNothing,
    );
    await t.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 200)),
    );
    await t.pump();
    expect(find.byType(Image), findsWidgets);
  });

  testWidgets('timeline attachments: inline bytes show, a URL waits', (
    t,
  ) async {
    final gateway = _CountingGateway();
    await t.pumpWidget(
      MaterialApp(
        theme: theme.build(Brightness.light),
        home: Scaffold(
          body: SingleChildScrollView(
            child: TimelineImages([
              {'mimeType': 'image/png', 'base64': base64Encode(_png)},
              {'url': 'https://img.example.test/attached.png'},
            ], gateway: gateway),
          ),
        ),
      ),
    );
    await t.pumpAndSettle();
    await t.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 200)),
    );
    await t.pump();
    expect(gateway.fetches, isEmpty);
    expect(
      find.byKey(const ValueKey('remote-content-placeholder')),
      findsOneWidget,
    );
    expect(find.byType(Image), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('remote-content-placeholder')));
    await t.pumpAndSettle();
    expect(gateway.fetches, ['image https://img.example.test/attached.png']);
  });

  testWidgets(
    'markdown rendered without a caller builder is held too (no package-default fetch)',
    (t) async {
      final counter = _HttpCounter();
      await HttpOverrides.runZoned(() async {
        await t.pumpWidget(
          MaterialApp(
            theme: theme.build(Brightness.light),
            home: const Scaffold(
              body: NativeMarkdown(
                source: '![standalone](https://img.example.test/s.png)',
              ),
            ),
          ),
        );
        await t.pumpAndSettle();
        expect(counter.urls, isEmpty);
        expect(
          find.byKey(const ValueKey('remote-content-placeholder')),
          findsOneWidget,
        );
        await t.tap(find.text('standalone'));
        await t.pumpAndSettle();
        expect(counter.urls, ['https://img.example.test/s.png']);
      }, createHttpClient: (c) => _CountingHttp());
    },
  );

  testWidgets('standalone HTML (no caller builder) holds images too', (
    t,
  ) async {
    final counter = _HttpCounter();
    await HttpOverrides.runZoned(() async {
      await t.pumpWidget(
        MaterialApp(
          theme: theme.build(Brightness.light),
          home: const Scaffold(
            body: SingleChildScrollView(
              child: NativeMarkdown(
                source:
                    '<img src="https://img.example.test/h.png" alt="held html">\n\n'
                    '<div style="background:url(https://img.example.test/hb.png);height:10px"></div>',
              ),
            ),
          ),
        ),
      );
      await t.pumpAndSettle();
      expect(counter.urls, isEmpty);
      expect(
        find.byKey(const ValueKey('remote-content-placeholder')),
        findsOneWidget,
      );
      await t.tap(find.text('held html'));
      await t.pumpAndSettle();
      expect(counter.urls, ['https://img.example.test/h.png']);
    }, createHttpClient: (c) => _CountingHttp());
  });

  testWidgets('the placeholder is announced as a button with its source', (
    t,
  ) async {
    final handle = t.ensureSemantics();
    await pump(t, '![diagram](https://img.example.test/d.png)');
    final node = t.getSemantics(
      find.byKey(const ValueKey('remote-content-placeholder')),
    );
    expect(node.label, contains('diagram'));
    expect(node.label, contains('img.example.test'));
    handle.dispose();
  });

  testWidgets('zh-TW placeholder text', (t) async {
    AppI18n.instance.setLanguage('zh-TW');
    await pump(t, '![圖](https://img.example.test/d.png)');
    expect(find.text('來自 img.example.test 的遠端圖片'), findsOneWidget);
    expect(find.text('點一下以載入'), findsOneWidget);
  });

  group('a fetched document', () {
    String page({required bool script}) =>
        '<p>Document</p>'
        '<img src="https://img.example.test/doc.png" alt="doc img"'
        '${script ? ' onclick="this.src=\'https://img.example.test/clicked.png\'"' : ''}>'
        '${script ? '<script>document.images[0].click();'
                  'new Image().src="https://img.example.test/script.png";'
                  'fetch("https://img.example.test/f");</script>' : ''}';

    NativeFetchedDocument document({required bool paired, bool script = true}) {
      final bytes = Uint8List.fromList(utf8.encode(page(script: script)));
      return NativeFetchedDocument(
        id: paired ? 1 : 2,
        url: paired
            ? 'https://gateway.example/doc.html'
            : 'https://elsewhere.example/doc.html',
        status: 200,
        bytes: bytes,
        mimeType: 'text/html',
        content: NativeHtmlDocumentContent.fromBytes(
          bytes,
          mimeType: 'text/html',
          charset: 'utf-8',
        ),
        headers: const {},
        pairedOrigin: paired,
      );
    }

    Future<_CountingGateway> show(
      WidgetTester t,
      NativeFetchedDocument doc,
    ) async {
      final gateway = _CountingGateway();
      final windows = NativeDocumentWindows(
        gateway,
        appDocumentUrl: () => 'https://gateway.example/?session=s',
      );
      addTearDown(windows.dispose);
      addTearDown(doc.dispose);
      await t.pumpWidget(
        MaterialApp(
          theme: theme.build(Brightness.light),
          home: NativeDocumentScope(
            windows: windows,
            documentUrl: doc.url,
            sourceIdentity: windows.accountIdentity,
            child: NativeFetchedDocumentView(
              document: doc,
              gateway: gateway,
              onLink: (_) {},
              onSubmit: (_) {},
            ),
          ),
        ),
      );
      await t.pumpAndSettle();
      return gateway;
    }

    testWidgets(
      'served by the paired Gateway: script cannot cause the gated load, only the tap does',
      (t) async {
        final gateway = await show(t, document(paired: true));
        // Script is not run for it, so neither its own requests nor the click
        // it tries to synthesize on the image can reach the placeholder.
        expect(gateway.fetches, isEmpty);
        expect(
          gateway.others.where((m) => m.startsWith('documentScript')),
          isEmpty,
        );
        expect(
          find.byKey(const ValueKey('remote-content-placeholder')),
          findsOneWidget,
        );
        await t.tap(find.text('doc img'));
        await t.pumpAndSettle();
        expect(gateway.fetches, ['image https://img.example.test/doc.png']);
      },
    );

    testWidgets(
      'on another origin it is the page the user went to and loads its own images',
      (t) async {
        final gateway = await show(t, document(paired: false, script: false));
        expect(
          find.byKey(const ValueKey('remote-content-placeholder')),
          findsNothing,
        );
        expect(
          gateway.fetches,
          contains('image https://img.example.test/doc.png'),
        );
      },
    );
  });
}
