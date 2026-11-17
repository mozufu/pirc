import 'package:pirc_mobile/live/remote_content_gate.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_mobile/live/document_background_image.dart';
import 'package:pirc_mobile/live/document_navigation_state.dart';
import 'package:pirc_mobile/live/gateway.dart';
import 'package:pirc_mobile/live/common.dart';
import 'live_test.dart' show FakeGateway, theme;

final cases =
    (jsonDecode(
              File(
                '../../fixtures/mobile-parity/animated-images.json',
              ).readAsStringSync(),
            )['cases']
            as List)
        .cast<Map>();
final jpeg = base64Decode(
  jsonDecode(
    File(
      '../../fixtures/mobile-parity/markdown-images.json',
    ).readAsStringSync(),
  )['jpeg'],
);
Future<void> tick(WidgetTester t) async {
  await t.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 10)),
  );
  await t.pump();
}

Future<List<int>> capturePixel(WidgetTester t, Finder boundary) async {
  final r = t.renderObject<RenderRepaintBoundary>(boundary);
  final image = await r.toImage(pixelRatio: 1);
  try {
    final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    final offset = ((image.height - 2) * image.width + image.width - 2) * 4;
    return data!.buffer.asUint8List().sublist(offset, offset + 4);
  } finally {
    image.dispose();
  }
}

Future<ui.Image> firstImage(ImageProvider provider) {
  final ready = Completer<ui.Image>();
  final stream = provider.resolve(ImageConfiguration.empty);
  late ImageStreamListener listener;
  listener = ImageStreamListener(
    (info, sync) {
      stream.removeListener(listener);
      ready.complete(info.image.clone());
    },
    onError: (Object error, StackTrace? stack) {
      stream.removeListener(listener);
      ready.completeError(error, stack);
    },
  );
  stream.addListener(listener);
  return ready.future;
}

void main() {
  setUpAll(() => NativeRemoteContentPolicy.debugOpenForTests = true);
  tearDownAll(() => NativeRemoteContentPolicy.debugOpenForTests = false);
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final item in cases) {
    testWidgets(
      'HTML authenticated ${item['id']} background actually paints and animates',
      (t) async {
        final g = FakeGateway();
        g.handler = (method, args) async => method == 'image'
            ? {
                'bytes': base64Decode(item['base64']),
                'mimeType': item['mimeType'],
              }
            : g.normal(method, args);
        final windows = NativeDocumentWindows(g);
        const key = ValueKey('background-paint');
        await t.pumpWidget(
          MaterialApp(
            theme: theme.build(Brightness.light),
            home: Scaffold(
              body: NativeDocumentScope(
                windows: windows,
                documentUrl: 'https://gateway.example/folder/page',
                child: RepaintBoundary(
                  key: key,
                  child: SizedBox(
                    width: 100,
                    height: 100,
                    child: RichTextBody(
                      '<div style="width:100px;height:100px;background-image:url(back.${item['id']});background-size:cover;background-repeat:no-repeat;background-position:center">Kept text</div>',
                      gateway: g,
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        List<int> p = [];
        for (var i = 0; i < 60; i++) {
          await tick(t);
          p = (await t.runAsync(() => capturePixel(t, find.byKey(key))))!;
          if (p[0] > 200 && p[1] < 20 && p[2] < 20) break;
        }
        expect(p[0], greaterThan(200));
        expect(p[1], lessThan(20));
        expect(p[2], lessThan(20));
        final calls = g.calls.where((c) => c.$1 == 'image').toList();
        expect(calls, hasLength(1));
        expect(calls.single.$2['source'], 'back.${item['id']}');
        expect(
          calls.single.$2['baseUrl'],
          'https://gateway.example/folder/page',
        );
        final decorated = t
            .widgetList<DecoratedBox>(find.byType(DecoratedBox))
            .map((w) => w.decoration)
            .whereType<BoxDecoration>()
            .where((d) => d.image?.image is NativeDocumentBackgroundImage)
            .single;
        expect(decorated.image!.fit, BoxFit.cover);
        expect(decorated.image!.repeat, ImageRepeat.noRepeat);
        expect(decorated.image!.alignment, Alignment.center);
        await t.pump(
          Duration(milliseconds: (item['frameDurationMs'] as num).toInt() + 20),
        );
        p = (await t.runAsync(() => capturePixel(t, find.byKey(key))))!;
        expect(p[2], greaterThan(200));
        expect(p[0], lessThan(20));
        expect(
          find.textContaining('Kept text', findRichText: true),
          findsOneWidget,
        );
        expect(t.takeException(), isNull);
        await t.pumpWidget(const SizedBox());
        windows.dispose();
        await g.stream.close();
      },
    );
  }
  testWidgets('CSS background defaults repeat the image across the element', (
    t,
  ) async {
    final item = cases.first;
    final g = FakeGateway();
    g.handler = (method, args) async => method == 'image'
        ? {'bytes': base64Decode(item['base64']), 'mimeType': item['mimeType']}
        : g.normal(method, args);
    final windows = NativeDocumentWindows(g);
    const key = ValueKey('default-background-paint');
    await t.pumpWidget(
      MaterialApp(
        theme: theme.build(Brightness.light),
        home: Scaffold(
          body: NativeDocumentScope(
            windows: windows,
            documentUrl: 'https://gateway.example/',
            child: RepaintBoundary(
              key: key,
              child: SizedBox(
                width: 100,
                height: 100,
                child: RichTextBody(
                  '<div style="width:100px;height:100px;background-image:url(tile.gif)">Text</div>',
                  gateway: g,
                ),
              ),
            ),
          ),
        ),
      ),
    );
    List<int> pixel = [];
    for (var i = 0; i < 60; i++) {
      await tick(t);
      pixel = (await t.runAsync(() => capturePixel(t, find.byKey(key))))!;
      if (pixel[1] < 20 && (pixel[0] > 200 || pixel[2] > 200)) break;
    }
    expect(pixel[1], lessThan(20));
    expect(pixel[0] > 200 || pixel[2] > 200, isTrue);
    expect(t.takeException(), isNull);
    await t.pumpWidget(const SizedBox());
    windows.dispose();
    await g.stream.close();
  });
  testWidgets('new none or pure-color background does not fetch the previous image', (
    t,
  ) async {
    final g = FakeGateway();
    // Use a single transport so unexpected requests cannot escape the assertion.
    final scopes = NativeDocumentWindows(g);
    await t.pumpWidget(
      MaterialApp(
        theme: theme.build(Brightness.light),
        home: Scaffold(
          body: NativeDocumentScope(
            windows: scopes,
            documentUrl: 'https://gateway.example/',
            child: RichTextBody(
              '<div style="background-image:url(old.png);background-image:none">No image</div>'
              '<div style="background-image:url(old.png);background:red">Red</div>',
              gateway: g,
            ),
          ),
        ),
      ),
    );
    await tick(t);
    expect(g.calls.where((c) => c.$1 == 'image'), isEmpty);
    expect(t.takeException(), isNull);
    await t.pumpWidget(const SizedBox());
    scopes.dispose();
    await g.stream.close();
  });
  test('background image cache keys separate accounts and document owners', () {
    final g = FakeGateway(), owner = Object();
    NativeDocumentBackgroundImage key(Object account, Object owner) =>
        NativeDocumentBackgroundImage(
          source: Uri.parse('/a.jpg'),
          gateway: g,
          accountIdentity: account,
          owner: owner,
          isCurrent: () => true,
        );
    expect(key('one', owner), key('one', owner));
    expect(key('one', owner), isNot(key('two', owner)));
    expect(key('one', owner), isNot(key('one', Object())));
  });
  testWidgets(
    'late authenticated background cannot decode after account invalidation',
    (t) async {
      final g = FakeGateway(), pending = Completer<Json>();
      var valid = true;
      g.handler = (_, _) => pending.future;
      final provider = NativeDocumentBackgroundImage(
        source: Uri.parse('/a.jpg'),
        gateway: g,
        accountIdentity: 'one',
        owner: g,
        isCurrent: () => valid,
      );
      final future = firstImage(provider);
      final error = expectLater(future, throwsStateError);
      await t.pump();
      valid = false;
      pending.complete({'bytes': jpeg, 'mimeType': 'image/jpeg'});
      await error;
      await g.stream.close();
    },
  );
  testWidgets(
    'broken background keeps foreground and unsafe schemes never fetch',
    (t) async {
      final g = FakeGateway();
      g.handler = (_, _) async => throw StateError('network down');
      final windows = NativeDocumentWindows(g);
      await t.pumpWidget(
        MaterialApp(
          theme: theme.build(Brightness.light),
          home: Scaffold(
            body: NativeDocumentScope(
              windows: windows,
              documentUrl: 'https://gateway.example/',
              child: RichTextBody(
                '<div style="background-image:url(/broken.png)">Foreground</div><div style="background-image:url(file:///private.txt)">File denied</div>',
                gateway: g,
              ),
            ),
          ),
        ),
      );
      for (var i = 0; i < 10; i++) {
        await tick(t);
      }
      expect(g.calls.where((c) => c.$1 == 'image').map((c) => c.$2['source']), [
        '/broken.png',
      ]);
      expect(
        find.textContaining('Foreground', findRichText: true),
        findsOneWidget,
      );
      expect(t.takeException(), isNull);
      await t.pumpWidget(const SizedBox());
      windows.dispose();
      await g.stream.close();
    },
  );
  testWidgets(
    'data background JPEG decodes through Flutter without transport',
    (t) async {
      final provider = NativeDocumentBackgroundImage(
        source: Uri.dataFromBytes(jpeg, mimeType: 'image/jpeg'),
        accountIdentity: 'local',
        owner: Object(),
        isCurrent: () => true,
      );
      final image = await t.runAsync(() => firstImage(provider));
      expect(image!.width, greaterThan(0));
      expect(image.height, greaterThan(0));
      image.dispose();
    },
  );
}
