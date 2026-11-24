import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:html/parser.dart' as html;
import 'package:integration_test/integration_test.dart';
import 'package:pirc_mobile/live/document_navigation.dart';
import 'package:pirc_mobile/live/document_navigation_state.dart';
import 'package:pirc_mobile/live/gateway.dart';
import 'package:pirc_mobile/live/document_scripts.dart';
import 'package:pirc_mobile/rendering/document_object_urls.dart';
import 'package:pirc_mobile/live/markdown_image.dart';
import 'package:pirc_mobile/rendering/html_buttons.dart';
import 'package:pirc_mobile/rendering/html_document_content.dart';
import 'package:pirc_mobile/theme.dart';
import 'document_object_url_fixture.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('native object URL bridge preserves an exact 2 MiB Blob', (
    tester,
  ) async {
    final scripts = NativeDocumentScripts(Gateway());
    try {
      await scripts.start(
        url: 'https://example.test/blob-limit',
        source: r'''<p id="large-url"></p><script>
        (()=>{const bytes=new Uint8Array(2*1024*1024);for(let i=0;i<bytes.length;i++)bytes[i]=i%256;
          const url=URL.createObjectURL(new Blob([bytes],{type:'application/octet-stream'}));
          document.querySelector('#large-url').textContent=url;})();
        </script>''',
      );
      expect(scripts.ready, isTrue, reason: '${scripts.diagnostics}');
      final url = html
          .parse(scripts.content!.text)
          .querySelector('#large-url')!
          .text;
      expect(url, startsWith('blob:https://example.test/'));
      final blob = NativeDocumentBlob.fromBridge(
        url,
        await scripts.readObjectURL(url),
      );
      final bytes = blob.bytes;
      expect(bytes.length, 2097152);
      for (var i = 0; i < bytes.length; i++) {
        if (bytes[i] != i % 256) fail('Blob byte mismatch at $i');
      }
      expect(blob.mimeType, 'application/octet-stream');
      debugPrint('OBJECT_URL:2MiB-exact-native-bridge:32MiB-heap');
    } finally {
      scripts.dispose();
      await scripts.closed;
    }
  });

  testWidgets(
    'native Blob URLs match Chrome fetch semantics and paint active PNG images',
    (tester) async {
      final expected = jsonDecode(objectUrlExpectedJson) as Map;
      final theme = await PircTheme.load();
      final gateway = Gateway();
      final windows = NativeDocumentWindows(gateway);
      final source = windows.target(
        '',
        null,
        sourceUrl: 'https://example.test/object-url',
      );
      NativeFetchedDocument? document;
      final boundaryKey = GlobalKey();

      Object? result() {
        final raw = document?.scripts?.content?.text;
        if (raw == null) return null;
        final text = html.parse(raw).querySelector('#object-url-result')?.text;
        if (text == null ||
            text.isEmpty ||
            text == 'WAITING' ||
            text == 'RUNNING') {
          return null;
        }
        try {
          return jsonDecode(text);
        } catch (_) {
          return null;
        }
      }

      String? imageSourceAttribute() {
        final raw = document?.scripts?.content?.text;
        if (raw == null) return null;
        return html.parse(raw).querySelector('#blob-image')?.attributes['src'];
      }

      Future<void> until(bool Function() condition, String label) async {
        for (var i = 0; i < 400 && !condition(); i++) {
          await tester.pump(const Duration(milliseconds: 50));
        }
        expect(
          condition(),
          isTrue,
          reason: '$label: ${document?.scripts?.diagnostics}',
        );
        expect(tester.takeException(), isNull);
      }

      Finder button(String label) => find.byWidgetPredicate(
        (w) => w is NativeHtmlButtonWidget && w.button.label == label,
      );

      Future<void> tap(Finder finder) async {
        await tester.ensureVisible(finder);
        await tester.pumpAndSettle();
        expect(finder.hitTestable(), findsOneWidget);
        await tester.tap(finder);
      }

      Future<void> waitForPaintedImage() async {
        bool paintedImage() => tester
            .widgetList<RawImage>(find.byType(RawImage))
            .any((image) => image.image != null);
        for (var i = 0; i < 200 && !paintedImage(); i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 20)),
          );
          await tester.pump();
        }
        expect(
          paintedImage(),
          isTrue,
          reason: 'Blob PNG did not decode and paint.',
        );
      }

      var serial = 0;
      try {
        for (final width in [390.0, 860.0]) {
          for (final brightness in Brightness.values) {
            for (final scale in [1.0, 2.0]) {
              if (document != null) {
                final old = document;
                await tester.pumpWidget(const SizedBox());
                source.history.clear();
                old.dispose();
                await old.scripts?.closed;
              }

              final bytes = Uint8List.fromList(utf8.encode(objectUrlHtml));
              document = NativeFetchedDocument(
                id: ++serial,
                url: 'https://example.test/object-url',
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
              source.history.add(
                NativeDocumentHistoryItem(document.url, document),
              );
              source.index = 0;
              windows.select(source);
              tester.view.devicePixelRatio = 1;
              tester.view.physicalSize = Size(width, 844);
              await tester.pumpWidget(
                MaterialApp(
                  theme: theme.build(brightness),
                  home: Builder(
                    builder: (context) => MediaQuery(
                      data: MediaQuery.of(
                        context,
                      ).copyWith(textScaler: TextScaler.linear(scale)),
                      child: Scaffold(
                        body: RepaintBoundary(
                          key: boundaryKey,
                          child: NativeDocumentScope(
                            windows: windows,
                            window: source,
                            documentUrl: document!.url,
                            child: NativeFetchedDocumentView(
                              key: ValueKey(serial),
                              document: document,
                              gateway: gateway,
                              onLink: (_) {},
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
                () => document!.scripts?.ready == true,
                'Object URL isolate ready',
              );
              await tap(button('Create blob previews'));
              await until(() => result() != null, 'Blob URL fetch results');
              expect(result(), expected);

              final src = imageSourceAttribute();
              expect(src, isNotNull);
              expect(src, startsWith('blob:https://example.test/'));
              expect((result() as Map)['image'], {
                'srcHasBlob': true,
                'attributeSame': true,
              });

              final imageFinder = find.byWidgetPredicate(
                (widget) =>
                    widget is NativeMarkdownImage &&
                    widget.source.scheme == 'blob',
              );
              expect(imageFinder, findsOneWidget);
              final nativeImage = tester.widget<NativeMarkdownImage>(
                imageFinder,
              );
              expect(nativeImage.source.toString(), src);

              await waitForPaintedImage();
              final imageRect = tester.getRect(imageFinder);
              expect(imageRect.width, 32);
              expect(imageRect.height, 32);
              final boundaryRect = tester.getRect(find.byKey(boundaryKey));
              final point = imageRect.center - boundaryRect.topLeft;
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
                final actual = pixels.sublist(offset, offset + 4);
                expect(
                  actual,
                  [255, 0, 0, 255],
                  reason:
                      'The active Blob URL preview should paint the red PNG.',
                );
              } finally {
                capture.dispose();
              }

              debugPrint(
                'OBJECT_URL:chrome-match:$width:${brightness.name}:$scale:blob-png-red',
              );
            }
          }
        }
      } finally {
        await tester.pumpWidget(const SizedBox());
        final closed = document?.scripts?.closed;
        windows.dispose();
        await closed;
        tester.view.reset();
      }
    },
    timeout: const Timeout(Duration(minutes: 6)),
  );
}
