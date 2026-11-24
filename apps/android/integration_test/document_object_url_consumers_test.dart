import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:html/parser.dart' as html;
import 'package:integration_test/integration_test.dart';
import 'package:pirc_mobile/rendering/document_background_image.dart';
import 'package:pirc_mobile/live/document_navigation.dart';
import 'package:pirc_mobile/live/document_navigation_state.dart';
import 'package:pirc_mobile/live/gateway.dart';
import 'package:pirc_mobile/rendering/html_buttons.dart';
import 'package:pirc_mobile/rendering/html_document_content.dart';
import 'package:pirc_mobile/theme.dart';

class _SaveCapturingGateway extends Gateway {
  final saved = Completer<Json>();

  @override
  Future<dynamic> call(String method, [Json args = const {}]) async {
    if (method == 'boot') {
      return {'origin': 'https://example.test', 'pairingStamp': 'blob-fixture'};
    }
    if (method == 'saveDocument') {
      final raw = args['bytes'];
      final bytes = raw is Uint8List
          ? Uint8List.fromList(raw)
          : Uint8List.fromList((raw as List).cast<int>());
      if (!saved.isCompleted) {
        saved.complete({
          'bytes': bytes,
          'name': args['name'],
          'mimeType': args['mimeType'],
          'pairingStamp': args['pairingStamp'],
        });
      }
      return {'saved': true};
    }
    return super.call(method, args);
  }
}

const _redPng = <int>[
  137,
  80,
  78,
  71,
  13,
  10,
  26,
  10,
  0,
  0,
  0,
  13,
  73,
  72,
  68,
  82,
  0,
  0,
  0,
  1,
  0,
  0,
  0,
  1,
  8,
  6,
  0,
  0,
  0,
  31,
  21,
  196,
  137,
  0,
  0,
  0,
  13,
  73,
  68,
  65,
  84,
  120,
  156,
  99,
  248,
  207,
  192,
  240,
  31,
  0,
  5,
  0,
  1,
  255,
  137,
  153,
  61,
  29,
  0,
  0,
  0,
  0,
  73,
  69,
  78,
  68,
  174,
  66,
  96,
  130,
];

const _consumerHtml =
    r'''<!doctype html><html><head><meta charset="utf-8"><title>Blob URL consumers</title>
<style>
#blob-background { width: 32px; height: 32px; }
</style></head><body>
<h1>Blob URL consumers</h1>
<button id="create-consumers" type="button">Create Blob URL consumers</button>
<img id="blob-image" width="32" height="32" alt="red PNG">
<div id="blob-background" style="width:32px;height:32px"></div>
<p><a id="blob-download" download="red.png" href="">Download red PNG</a></p>
<pre id="consumer-result">WAITING</pre>
<script>
(() => {
  const resultNode = document.querySelector('#consumer-result');
  const pngBytes = Uint8Array.from([
    137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82,
    0, 0, 0, 1, 0, 0, 0, 1, 8, 6, 0, 0, 0, 31, 21, 196, 137, 0, 0, 0,
    13, 73, 68, 65, 84, 120, 156, 99, 248, 207, 192, 240, 31, 0, 5, 0,
    1, 255, 137, 153, 61, 29, 0, 0, 0, 0, 73, 69, 78, 68, 174, 66, 96, 130
  ]);
  document.querySelector('#create-consumers').addEventListener('click', () => {
    const blob = new Blob([pngBytes], {type: 'image/png'});
    const url = URL.createObjectURL(blob);
    const image = document.querySelector('#blob-image');
    const background = document.querySelector('#blob-background');
    const download = document.querySelector('#blob-download');

    image.src = url;
    background.style.backgroundImage = 'url("' + url + '")';
    download.setAttribute('href', url);

    resultNode.textContent = JSON.stringify({
      originMatches: url.startsWith('blob:' + location.origin + '/'),
      imageSrcHasBlob: image.getAttribute('src').startsWith('blob:'),
      imageAttributeMatches: image.getAttribute('src') === url,
      backgroundStyleContainsUrl: background.getAttribute('style').includes(url),
      downloadHrefMatches: download.getAttribute('href') === url
    });
  });
})();
</script></body></html>''';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'Blob URL renders as a CSS background and saves exact download bytes',
    (tester) async {
      final gateway = _SaveCapturingGateway();
      final boot = obj(await gateway.call('boot'));
      final origin = boot['origin'] as String;
      final theme = await PircTheme.load();
      final windows = NativeDocumentWindows(gateway);
      final window = windows.target('', null, sourceUrl: '$origin/source');
      final bytes = Uint8List.fromList(utf8.encode(_consumerHtml));
      final document = NativeFetchedDocument(
        id: 1,
        url: '$origin/blob-consumers',
        status: 200,
        bytes: bytes,
        mimeType: 'text/html',
        headers: {},
        content: NativeHtmlDocumentContent.fromBytes(
          bytes,
          mimeType: 'text/html',
          charset: 'utf-8',
        ),
      );
      window.history.add(NativeDocumentHistoryItem(document.url, document));
      window.index = 0;
      windows.select(window);
      final boundaryKey = GlobalKey();
      final linkAction = Completer<void>();

      Map<String, dynamic>? result() {
        final raw = document.scripts?.content?.text;
        if (raw == null) return null;
        final text = html.parse(raw).querySelector('#consumer-result')?.text;
        if (text == null || text.isEmpty || text == 'WAITING') return null;
        try {
          final decoded = jsonDecode(text);
          return decoded is Map<String, dynamic> ? decoded : null;
        } catch (_) {
          return null;
        }
      }

      Future<void> until(bool Function() condition, String label) async {
        for (var i = 0; i < 400 && !condition(); i++) {
          await tester.pump(const Duration(milliseconds: 50));
        }
        expect(
          condition(),
          isTrue,
          reason: '$label: ${document.scripts?.diagnostics}',
        );
        expect(tester.takeException(), isNull);
      }

      Finder createButton() => find.byWidgetPredicate(
        (widget) =>
            widget is NativeHtmlButtonWidget &&
            widget.button.label == 'Create Blob URL consumers',
      );

      Finder blobBackground() => find.byWidgetPredicate((widget) {
        if (widget is! DecoratedBox || widget.decoration is! BoxDecoration) {
          return false;
        }
        final provider = (widget.decoration as BoxDecoration).image?.image;
        return provider is NativeDocumentBackgroundImage &&
            provider.source.scheme == 'blob';
      });

      Future<List<int>> sampleBackgroundPixel(Finder backgroundFinder) async {
        final backgroundRect = tester.getRect(backgroundFinder);
        final boundaryRect = tester.getRect(find.byKey(boundaryKey));
        final point = backgroundRect.center - boundaryRect.topLeft;
        final boundary = tester.renderObject<RenderRepaintBoundary>(
          find.byKey(boundaryKey),
        );
        final capture = await boundary.toImage(pixelRatio: 1);
        try {
          final data = (await capture.toByteData(
            format: ui.ImageByteFormat.rawStraightRgba,
          ))!;
          final pixels = data.buffer.asUint8List(
            data.offsetInBytes,
            data.lengthInBytes,
          );
          final x = point.dx.floor();
          final y = point.dy.floor();
          expect(x, inInclusiveRange(0, capture.width - 1));
          expect(y, inInclusiveRange(0, capture.height - 1));
          final offset = (y * capture.width + x) * 4;
          return pixels.sublist(offset, offset + 4);
        } finally {
          capture.dispose();
        }
      }

      try {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(390, 844);
        await tester.pumpWidget(
          MaterialApp(
            theme: theme.build(Brightness.light),
            home: Builder(
              builder: (context) => Scaffold(
                body: RepaintBoundary(
                  key: boundaryKey,
                  child: NativeDocumentScope(
                    windows: windows,
                    window: window,
                    documentUrl: document.url,
                    child: Builder(
                      builder: (documentContext) => NativeFetchedDocumentView(
                        document: document,
                        gateway: gateway,
                        onLink: (link) {
                          final scope = NativeDocumentScope.maybeOf(
                            documentContext,
                          );
                          if (scope == null) {
                            if (!linkAction.isCompleted) {
                              linkAction.completeError(
                                StateError('Document scope is missing.'),
                              );
                            }
                            return;
                          }
                          unawaited(
                            saveNativeDocumentLink(
                              documentContext,
                              gateway,
                              link,
                              scope: scope,
                            ).then<void>(
                              (_) {
                                if (!linkAction.isCompleted) {
                                  linkAction.complete();
                                }
                              },
                              onError: (Object error, StackTrace stackTrace) {
                                if (!linkAction.isCompleted) {
                                  linkAction.completeError(error, stackTrace);
                                }
                              },
                            ),
                          );
                        },
                        onSubmit: (_) {},
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );

        await until(
          () => document.scripts?.ready == true,
          'Object URL isolate ready',
        );
        await tester.ensureVisible(createButton());
        await tester.pumpAndSettle();
        expect(createButton().hitTestable(), findsOneWidget);
        await tester.tap(createButton());
        await until(() => result() != null, 'Blob consumers created');
        expect(result(), {
          'originMatches': true,
          'imageSrcHasBlob': true,
          'imageAttributeMatches': true,
          'backgroundStyleContainsUrl': true,
          'downloadHrefMatches': true,
        });

        final backgroundFinder = blobBackground();
        expect(backgroundFinder, findsOneWidget);
        final decoration =
            tester.widget<DecoratedBox>(backgroundFinder).decoration
                as BoxDecoration;
        final provider =
            decoration.image!.image as NativeDocumentBackgroundImage;
        expect(provider.source.scheme, 'blob');
        expect(tester.getSize(backgroundFinder), const Size(32, 32));
        final decoded = Completer<void>();
        final stream = provider.resolve(ImageConfiguration.empty);
        late ImageStreamListener listener;
        listener = ImageStreamListener(
          (info, sync) {
            debugPrint(
              'BLOB_BACKGROUND:frame=${info.image.width}x${info.image.height}',
            );
            if (!decoded.isCompleted) decoded.complete();
          },
          onError: (Object error, StackTrace? stack) {
            debugPrint('BLOB_BACKGROUND:error=$error');
            if (!decoded.isCompleted) decoded.completeError(error, stack);
          },
        );
        stream.addListener(listener);
        try {
          await until(() => decoded.isCompleted, 'Blob background codec');
          await decoded.future;
        } finally {
          stream.removeListener(listener);
        }

        List<int>? pixel;
        for (var i = 0; i < 40; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 25)),
          );
          await tester.pump();
          final sample = await sampleBackgroundPixel(backgroundFinder);
          pixel = sample;
          if (sample[0] > 240 &&
              sample[1] < 16 &&
              sample[2] < 16 &&
              sample[3] > 240) {
            break;
          }
        }
        expect(pixel, [
          255,
          0,
          0,
          255,
        ], reason: 'The CSS background must paint the real red Blob PNG.');

        final downloadFinder = find.byWidgetPredicate(
          (widget) =>
              widget is RichText &&
              widget.text.toPlainText().contains('Download red PNG'),
        );
        expect(downloadFinder, findsOneWidget);
        final rich = tester.widget<RichText>(downloadFinder);
        final render = tester.renderObject<RenderParagraph>(downloadFinder);
        final start = rich.text.toPlainText().indexOf('Download red PNG');
        final box = render
            .getBoxesForSelection(
              TextSelection(baseOffset: start, extentOffset: start + 1),
            )
            .first
            .toRect();
        await tester.tapAt(render.localToGlobal(box.center));

        await linkAction.future.timeout(const Duration(seconds: 45));
        final saved = await gateway.saved.future.timeout(
          const Duration(seconds: 45),
        );
        final savedBytes = saved['bytes'] as Uint8List;
        expect(saved['name'], 'red.png');
        expect(saved['mimeType'], 'image/png');
        expect(saved['pairingStamp'], 'blob-fixture');
        expect(savedBytes, hasLength(70));
        expect(savedBytes.sublist(0, 8), [137, 80, 78, 71, 13, 10, 26, 10]);
        expect(savedBytes, _redPng);
        expect(tester.takeException(), isNull);
        debugPrint(
          'OBJECT_URL_CONSUMERS:css-red-pixel:download-red.png:70-bytes',
        );
      } finally {
        await tester.pumpWidget(const SizedBox());
        final closed = document.scripts?.closed;
        windows.dispose();
        await closed;
        tester.view.reset();
      }
    },
    timeout: const Timeout(Duration(minutes: 4)),
  );
}
