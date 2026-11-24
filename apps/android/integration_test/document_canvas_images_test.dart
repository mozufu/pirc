import 'dart:async';
import 'dart:convert';
import 'dart:io';
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
import 'package:pirc_mobile/live/document_style_loading.dart';
import 'package:pirc_render_document/src/document_canvas.dart';
import 'package:pirc_render/src/html_document_content.dart';
import 'package:pirc_mobile/theme.dart';
import 'document_canvas_images_fixture.dart';

Map<String, dynamic>? probe(NativeFetchedDocument document) {
  final text =
      html
          .parse(document.scripts?.content?.text ?? '')
          .querySelector('#canvas-images-result')
          ?.text ??
      '';
  if (!text.startsWith('{')) return null;
  return Map<String, dynamic>.from(jsonDecode(text) as Map);
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'native Image lifecycle and Canvas decoded bitmap pixels match Chrome fixture',
    (t) async {
      final png = base64Decode(
        RegExp(
          r"const pngBase64 = '([^']+)'",
        ).firstMatch(documentCanvasImagesHtml)!.group(1)!,
      );
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final origin = 'http://127.0.0.1:${server.port}';
      final requests = <String>[];
      final serving = server.listen((request) {
        unawaited(() async {
          requests.add(request.uri.path);
          if (request.uri.path.startsWith('/slow')) {
            await Future<void>.delayed(const Duration(milliseconds: 300));
          }
          if (request.uri.path.contains('broken')) {
            request.response.headers.contentType = ContentType('image', 'png');
            request.response.write('not a PNG');
          } else if (request.uri.path == '/quadrants.png' ||
              request.uri.path == '/slow.png') {
            request.response.headers.contentType = ContentType('image', 'png');
            request.response.add(png);
          } else {
            request.response.statusCode = 404;
          }
          await request.response.close();
        }());
      });
      final theme = await PircTheme.load();
      final gateway = Gateway();
      try {
        for (final width in [390.0, 860.0]) {
          for (final brightness in [Brightness.light, Brightness.dark]) {
            for (final scale in [1.0, 2.0]) {
              t.view.physicalSize = Size(width, 600);
              t.view.devicePixelRatio = 1;
              final bytes = Uint8List.fromList(
                utf8.encode(documentCanvasImagesHtml),
              );
              final document = NativeFetchedDocument(
                id: 1,
                url: '$origin/fixture',
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
              final styles =
                  await NativeDocumentStyleLoader(
                    isCurrent: () => true,
                    fetch: (_, _) async => throw StateError('no external CSS'),
                    resolve: (_, _) async =>
                        throw StateError('no external CSS'),
                  ).load(
                    document.content.text,
                    baseUrl: document.url,
                    documentEncoding: document.content.encoding,
                  );
              document.stylesheets = styles.stylesheets;
              expect(styles.diagnostics, isEmpty);
              final boundaryKey = GlobalKey();
              try {
                await t.pumpWidget(
                  MaterialApp(
                    theme: theme.build(brightness),
                    builder: (context, child) => MediaQuery(
                      data: MediaQuery.of(
                        context,
                      ).copyWith(textScaler: TextScaler.linear(scale)),
                      child: child!,
                    ),
                    home: Scaffold(
                      body: RepaintBoundary(
                        key: boundaryKey,
                        child: NativeFetchedDocumentView(
                          document: document,
                          gateway: gateway,
                          onLink: (_) {},
                          onSubmit: (_) {},
                        ),
                      ),
                    ),
                  ),
                );
                for (var i = 0; i < 500 && probe(document) == null; i++) {
                  await t.pump(const Duration(milliseconds: 25));
                }
                final result = probe(document);
                expect(
                  result,
                  isNotNull,
                  reason:
                      '$width/$brightness/$scale: ${document.scripts?.diagnostics}',
                );
                expect(result!['fixtureError'], isNull);
                expect(document.scripts!.ready, true);
                expect(document.scripts!.diagnostics, isEmpty);
                expect(
                  result['sources']['dataPng']['terminal']['type'],
                  'load',
                );
                for (final name in [
                  'dataPng',
                  'blobPng',
                  'httpPng',
                  'dataJpeg',
                  'dataSvg',
                ]) {
                  expect(
                    result['sources'][name]['terminal']['state']['naturalWidth'],
                    4,
                    reason: name,
                  );
                  expect(
                    result['sources'][name]['decode']['status'],
                    'resolved',
                    reason: name,
                  );
                }
                expect(
                  result['draws']['brokenImage']['errorName'],
                  'InvalidStateError',
                );
                expect(
                  result['invalidDrawImage']['wrongType']['errorName'],
                  'TypeError',
                );
                expect(
                  result['blobRevocation']['immediatelyAfterAssignment']['terminal']['type'],
                  'error',
                );
                expect(
                  result['blobRevocation']['inLoadThenLaterDraw']['terminal']['type'],
                  'load',
                );
                expect(
                  result['sourceReplacement']['loadedThenPendingError']['pendingDraw']['status'],
                  'ok',
                );
                expect(
                  result['sourceReplacement']['loadedThenPendingError']['drawAfterError']['errorName'],
                  'InvalidStateError',
                );
                final canvas = find.byType(NativeDocumentCanvas);
                expect(canvas, findsOneWidget);
                expect(t.getSize(canvas), const Size(100, 48));
                await t.pump();
                final boundary = t.renderObject<RenderRepaintBoundary>(
                  find.byKey(boundaryKey),
                );
                final image = await boundary.toImage(pixelRatio: 1);
                try {
                  final pixels = (await image.toByteData(
                    format: ui.ImageByteFormat.rawStraightRgba,
                  ))!;
                  final rgba = pixels.buffer.asUint8List(
                    pixels.offsetInBytes,
                    pixels.lengthInBytes,
                  );
                  final offset =
                      t.getTopLeft(canvas) -
                      t.getTopLeft(find.byKey(boundaryKey));
                  final samples = <String, List<int>>{};
                  void pixel(
                    int x,
                    int y,
                    List<int> expected, {
                    int tolerance = 0,
                  }) {
                    final i =
                        ((offset.dy.floor() + y) * image.width +
                            offset.dx.floor() +
                            x) *
                        4;
                    final actual = rgba.sublist(i, i + 4);
                    samples['$x,$y'] = actual;
                    for (var c = 0; c < 4; c++) {
                      expect(
                        actual[c],
                        closeTo(expected[c], tolerance),
                        reason: '$width/$brightness/$scale pixel$x,$y=$actual',
                      );
                    }
                  }

                  pixel(0, 0, [240, 24, 36, 255]);
                  pixel(2, 0, [22, 205, 74, 255]);
                  pixel(0, 2, [34, 92, 248, 255]);
                  pixel(2, 2, [250, 206, 18, 255]);
                  pixel(9, 1, [240, 24, 36, 255]);
                  pixel(14, 6, [250, 206, 18, 255]);
                  pixel(21, 1, [240, 24, 36, 255]);
                  pixel(33, 1, [240, 24, 36, 255]);
                  pixel(33, 6, [34, 92, 248, 255]);
                  pixel(41, 9, [240, 24, 36, 255]);
                  pixel(1, 21, [255, 255, 255, 255]);
                  pixel(5, 21, [240, 24, 36, 255]);
                  pixel(17, 21, [240, 24, 36, 255]);
                  pixel(25, 21, [240, 24, 36, 255]);
                  pixel(1, 37, [240, 24, 36, 255]);
                  pixel(9, 37, [20, 210, 225, 255]);
                  pixel(17, 37, [240, 24, 36, 255]);
                  pixel(25, 37, [255, 255, 255, 255]);
                  pixel(33, 37, [20, 210, 225, 255]);
                  pixel(41, 37, [240, 24, 36, 255]);
                  pixel(56, 36, [240, 24, 36, 255]);
                  pixel(56, 42, [255, 255, 255, 255]);
                  pixel(64, 36, [255, 255, 255, 255]);
                  pixel(85, 21, [247, 139, 145, 255], tolerance: 1);
                  pixel(89, 25, [252, 230, 136, 255], tolerance: 1);
                  debugPrint(
                    'NATIVE_CANVAS_IMAGES ${jsonEncode({
                      'width': width,
                      'theme': brightness.name,
                      'scale': scale,
                      'pixels': samples,
                      'decodedVersions': document.scripts!.canvasImages.length,
                      'sources': {
                        for (final name in ['dataPng', 'blobPng', 'httpPng', 'dataJpeg', 'dataSvg']) name: result['sources'][name]['terminal']['type'],
                      },
                      'brokenImage': result['draws']['brokenImage'],
                      'pendingDraw': result['sourceReplacement']['loadedThenPendingError']['pendingDraw'],
                      'replacedError': result['sourceReplacement']['loadedThenPendingError']['drawAfterError'],
                    })}',
                  );
                } finally {
                  image.dispose();
                }
                expect(document.scripts!.canvasImages.length, greaterThan(2));
                expect(t.takeException(), isNull);
              } finally {
                await t.pumpWidget(const SizedBox());
                document.dispose();
                await t.pump();
              }
            }
          }
        }
        expect(requests, contains('/quadrants.png'));
        expect(requests, contains('/broken.png'));
        expect(requests, contains('/slow-broken.png'));
      } finally {
        await serving.cancel();
        await server.close(force: true);
        t.view.resetPhysicalSize();
        t.view.resetDevicePixelRatio();
      }
    },
  );
}
