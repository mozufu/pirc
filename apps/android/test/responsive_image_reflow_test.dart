import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_mobile/live/document_navigation.dart';
import 'package:pirc_mobile/live/document_navigation_state.dart';
import 'package:pirc_mobile/live/gateway.dart';
import 'package:pirc_render/src/html_document_content.dart';

import 'live_test.dart' show FakeGateway, theme;

final Map<String, dynamic> _responsiveFixture =
    jsonDecode(
          File(
            '../../fixtures/mobile-parity/html-responsive-images.json',
          ).readAsStringSync(),
        )
        as Map<String, dynamic>;

final Map<String, Map<String, dynamic>> _assetsByPath = {
  for (final raw in (_responsiveFixture['assetManifest'] as List))
    (raw as Map<String, dynamic>)['path'] as String: raw,
};

Uint8List _assetBytes(String path) {
  final dataUri = Uri.parse(_assetsByPath[path]!['dataUri'] as String);
  return dataUri.data!.contentAsBytes();
}

Json _imageResponse(String path) => {
  'bytes': _assetBytes(path),
  'mimeType': _assetsByPath[path]!['mimeType'],
};

NativeFetchedDocument _document(String markup) {
  final bytes = Uint8List.fromList(utf8.encode(markup));
  return NativeFetchedDocument(
    id: 1,
    url: 'https://images.example/document',
    status: 200,
    bytes: bytes,
    mimeType: 'text/html',
    headers: const {},
    content: NativeHtmlDocumentContent.fromBytes(
      bytes,
      mimeType: 'text/html',
      charset: 'utf-8',
    ),
  );
}

Widget _page(NativeFetchedDocument document, FakeGateway gateway) =>
    MaterialApp(
      theme: theme.build(Brightness.light),
      home: Scaffold(
        body: NativeFetchedDocumentView(
          document: document,
          gateway: gateway,
          onLink: (_) {},
          onSubmit: (_) {},
        ),
      ),
    );

Future<void> _render(
  WidgetTester tester,
  NativeFetchedDocument document,
  FakeGateway gateway, {
  required double width,
  required double devicePixelRatio,
}) async {
  tester.view.devicePixelRatio = devicePixelRatio;
  tester.view.physicalSize = Size(
    width * devicePixelRatio,
    900 * devicePixelRatio,
  );
  await tester.pumpWidget(_page(document, gateway));
  await tester.pumpAndSettle();
}

Future<void> _waitForAsset(WidgetTester tester, String path) async {
  final expectedBytes = _assetBytes(path);
  final imageFinder = find.byType(Image);
  for (var attempt = 0; attempt < 80; attempt += 1) {
    if (imageFinder.evaluate().length == 1) {
      final image = tester.widget<Image>(imageFinder);
      final provider = image.image;
      if (provider is MemoryImage &&
          listEquals(provider.bytes, expectedBytes)) {
        return;
      }
    }
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump();
  }
  expect(imageFinder, findsOneWidget);
  final provider = tester.widget<Image>(imageFinder).image;
  expect(provider, isA<MemoryImage>());
  expect((provider as MemoryImage).bytes, orderedEquals(expectedBytes));
}

String _lastImageRequest(FakeGateway gateway) => gateway.calls
    .where((call) => call.$1 == 'image')
    .map((call) => call.$2['source'] as String)
    .last;

bool _historyHasText(NativeFetchedDocument document, String value) =>
    document.historyControls.capture()?.controls.values.any(
      (entry) => entry.text == value,
    ) ??
    false;

String _pictureMarkup() => '''
<!doctype html><html><body style="margin:0">
  <form><label>Note <input name="note" value="Initial"></label></form>
  <picture>
    <source media="(max-width: 600px)" srcset="/picture-mobile.png">
    <source media="(min-width: 700px)" srcset="/picture-desktop.png">
    <img src="/fallback.png" alt="Responsive picture">
  </picture>
</body></html>
''';

void main() {
  testWidgets('picture source reflows while form edits and history survive', (
    tester,
  ) async {
    tester.view.reset();
    addTearDown(tester.view.reset);
    final gateway = FakeGateway();
    gateway.handler = (method, args) async {
      if (method != 'image') return gateway.normal(method, args);
      return _imageResponse(Uri.parse(args['source'] as String).path);
    };
    final document = _document(_pictureMarkup());

    try {
      await _render(tester, document, gateway, width: 390, devicePixelRatio: 1);
      await _waitForAsset(tester, '/picture-mobile.png');
      expect(_lastImageRequest(gateway), '/picture-mobile.png');

      final editorFinder = find.byType(EditableText).first;
      await tester.enterText(editorFinder, 'Edited before reflow');
      await tester.pumpAndSettle();
      final editorController = tester
          .widget<EditableText>(editorFinder)
          .controller;
      expect(_historyHasText(document, 'Edited before reflow'), isTrue);

      await _render(tester, document, gateway, width: 768, devicePixelRatio: 1);
      await _waitForAsset(tester, '/picture-desktop.png');
      expect(_lastImageRequest(gateway), '/picture-desktop.png');
      expect(
        tester.widget<EditableText>(find.byType(EditableText).first).controller,
        same(editorController),
      );
      expect(editorController.text, 'Edited before reflow');
      expect(_historyHasText(document, 'Edited before reflow'), isTrue);
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      document.dispose();
      await gateway.stream.close();
    }
  });

  testWidgets(
    'DPR source changes keep the same logical PNG size and edited history',
    (tester) async {
      tester.view.reset();
      addTearDown(tester.view.reset);
      final gateway = FakeGateway();
      gateway.handler = (method, args) async {
        if (method != 'image') return gateway.normal(method, args);
        return _imageResponse(Uri.parse(args['source'] as String).path);
      };
      final document = _document('''
<!doctype html><html><body style="margin:0">
  <form><label>Note <input name="note" value="Initial"></label></form>
  <img src="/density-1x.png"
       srcset="/density-1x.png 1x, /density-2x.png 2x"
       alt="Density image">
</body></html>
''');

      try {
        await _render(
          tester,
          document,
          gateway,
          width: 390,
          devicePixelRatio: 1,
        );
        await _waitForAsset(tester, '/density-1x.png');
        expect(_lastImageRequest(gateway), '/density-1x.png');
        final oneXImage = tester.widget<Image>(find.byType(Image));
        final oneXSize = tester.getSize(find.byType(Image));
        expect(oneXImage.image, isA<MemoryImage>());
        expect((oneXImage.image as MemoryImage).scale, 1);
        expect(oneXSize, const Size(100, 50));

        final editorFinder = find.byType(EditableText).first;
        await tester.enterText(editorFinder, 'Keep this edit');
        await tester.pumpAndSettle();
        final editorController = tester
            .widget<EditableText>(editorFinder)
            .controller;
        expect(_historyHasText(document, 'Keep this edit'), isTrue);

        await _render(
          tester,
          document,
          gateway,
          width: 390,
          devicePixelRatio: 2,
        );
        await _waitForAsset(tester, '/density-2x.png');
        expect(_lastImageRequest(gateway), '/density-2x.png');
        final twoXImage = tester.widget<Image>(find.byType(Image));
        expect((twoXImage.image as MemoryImage).scale, 2);
        expect(tester.getSize(find.byType(Image)), oneXSize);
        expect(
          tester
              .widget<EditableText>(find.byType(EditableText).first)
              .controller,
          same(editorController),
        );
        expect(editorController.text, 'Keep this edit');
        expect(_historyHasText(document, 'Keep this edit'), isTrue);
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        document.dispose();
        await gateway.stream.close();
      }
    },
  );

  testWidgets(
    'late bytes from an old picture candidate cannot replace the new image',
    (tester) async {
      tester.view.reset();
      addTearDown(tester.view.reset);
      final gateway = FakeGateway();
      final oldRequestStarted = Completer<void>();
      final oldResponse = Completer<Json>();
      gateway.handler = (method, args) async {
        if (method != 'image') return gateway.normal(method, args);
        final path = Uri.parse(args['source'] as String).path;
        if (path == '/picture-mobile.png') {
          if (!oldRequestStarted.isCompleted) oldRequestStarted.complete();
          return oldResponse.future;
        }
        return _imageResponse(path);
      };
      final document = _document(_pictureMarkup());

      try {
        await _render(
          tester,
          document,
          gateway,
          width: 390,
          devicePixelRatio: 1,
        );
        expect(oldRequestStarted.isCompleted, isTrue);
        expect(_lastImageRequest(gateway), '/picture-mobile.png');

        await _render(
          tester,
          document,
          gateway,
          width: 768,
          devicePixelRatio: 1,
        );
        await _waitForAsset(tester, '/picture-desktop.png');
        expect(_lastImageRequest(gateway), '/picture-desktop.png');
        final desktopImageSize = tester.getSize(find.byType(Image));

        oldResponse.complete(_imageResponse('/picture-mobile.png'));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)),
        );
        await tester.pumpAndSettle();

        final displayed = tester.widget<Image>(find.byType(Image)).image;
        expect(displayed, isA<MemoryImage>());
        expect(
          (displayed as MemoryImage).bytes,
          orderedEquals(_assetBytes('/picture-desktop.png')),
        );
        expect(tester.getSize(find.byType(Image)), desktopImageSize);
        expect(_lastImageRequest(gateway), '/picture-desktop.png');
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        document.dispose();
        await gateway.stream.close();
      }
    },
  );
}
