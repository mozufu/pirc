import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
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
import 'package:pirc_render_document/src/document_canvas_pointer.dart';
import 'package:pirc_render/src/html_buttons.dart';
import 'package:pirc_render/src/html_document_content.dart';
import 'package:pirc_mobile/theme.dart';

import 'document_canvas_pointer_fixture.dart';

Map<String, dynamic> _probe(NativeFetchedDocument document) {
  final source = document.scripts?.content?.text ?? '';
  final text = html.parse(source).querySelector('#pointer-result')?.text ?? '';
  return text.isEmpty ? {} : Map<String, dynamic>.from(jsonDecode(text) as Map);
}

List<Map<String, dynamic>> _events(
  NativeFetchedDocument document,
  String type,
) => ((_probe(document)['events'] as List?) ?? [])
    .cast<Map>()
    .map((entry) => Map<String, dynamic>.from(entry))
    .where((entry) => entry['type'] == type)
    .toList();

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'Canvas pointer coordinates, capture, redraw continuity and scroll cancellation',
    (t) async {
      final theme = await PircTheme.load();
      final gateway = Gateway();
      for (final width in [390.0, 860.0]) {
        for (final brightness in [Brightness.light, Brightness.dark]) {
          for (final scale in [1.0, 2.0]) {
            t.view.physicalSize = Size(width, 600);
            t.view.devicePixelRatio = 1;
            final bytes = Uint8List.fromList(
              utf8.encode(documentCanvasPointerHtml),
            );
            final document = NativeFetchedDocument(
              id: 1,
              url: 'https://example.test/canvas-pointer',
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
            final loadedStyles =
                await NativeDocumentStyleLoader(
                  isCurrent: () => true,
                  fetch: (_, _) async => throw StateError(
                    'The shared fixture has no external stylesheets.',
                  ),
                  resolve: (_, _) async => throw StateError(
                    'The shared fixture has no external stylesheet URLs.',
                  ),
                ).load(
                  document.content.text,
                  baseUrl: document.url,
                  documentEncoding: document.content.encoding,
                );
            document.stylesheets = loadedStyles.stylesheets;
            expect(loadedStyles.diagnostics, isEmpty);
            final boundaryKey = GlobalKey();
            Future<void> until(bool Function() predicate, String reason) async {
              for (var i = 0; i < 200 && !predicate(); i++) {
                await t.pump(const Duration(milliseconds: 25));
              }
              expect(
                predicate(),
                true,
                reason:
                    '$reason; ${document.scripts?.diagnostics}; scroll=${document.scroll.offset}/${document.scroll.position.maxScrollExtent}; probe=${jsonEncode(_probe(document))}',
              );
              expect(t.takeException(), isNull);
            }

            final canvasFinder = find.byType(NativeDocumentCanvas);
            Offset point(double x, double y) =>
                t.getTopLeft(canvasFinder) + Offset(x, y);
            Future<void> redPixel(double x, double y) async {
              await t.pump();
              final boundary = t.renderObject<RenderRepaintBoundary>(
                find.byKey(boundaryKey),
              );
              final capture = await boundary.toImage(pixelRatio: 1);
              try {
                final data = (await capture.toByteData(
                  format: ui.ImageByteFormat.rawStraightRgba,
                ))!;
                final offset =
                    point(x, y) - t.getTopLeft(find.byKey(boundaryKey));
                final index =
                    (offset.dy.floor() * capture.width + offset.dx.floor()) * 4;
                expect(
                  data.buffer
                      .asUint8List(data.offsetInBytes, data.lengthInBytes)
                      .sublist(index, index + 4),
                  [225, 29, 72, 255],
                );
              } finally {
                capture.dispose();
              }
            }

            void checkEvent(
              Map<String, dynamic> event,
              String pointerType,
              double x,
              double y,
            ) {
              expect(event['pointerType'], pointerType);
              expect(event['isPrimary'], true);
              expect(event['bubbles'], true);
              expect(event['cancelable'], true);
              expect(event['hasPointerCapture'], true);
              expect(event['offsetX'], closeTo(x, .01));
              expect(event['offsetY'], closeTo(y, .01));
              expect(event['mappedX'], closeTo(x * .8, .01));
              expect(event['mappedY'], closeTo(y * .8, .01));
              final rect = Map<String, dynamic>.from(event['rect'] as Map);
              expect(rect['left'], 24);
              expect(rect['top'], 32);
              expect(rect['width'], 300);
              expect(rect['height'], 150);
              expect(event['clientX'], closeTo((rect['left'] as num) + x, .01));
              expect(event['clientY'], closeTo((rect['top'] as num) + y, .01));
            }

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
                    appBar: AppBar(title: const Text('Pointer acceptance')),
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
              await until(
                () =>
                    document.scripts?.ready == true &&
                    canvasFinder.evaluate().isNotEmpty,
                'native runtime ready',
              );
              await t.pumpAndSettle();
              expect(t.getSize(canvasFinder), const Size(300, 150));
              expect(document.scripts!.diagnostics, isEmpty);
              final state = t.state(find.byType(NativeDocumentCanvasPointer));
              final mouse = await t.createGesture(
                kind: PointerDeviceKind.mouse,
              );
              await mouse.addPointer(location: point(20, 30));
              await t.pump();
              await mouse.down(point(90, 60));
              await until(
                () => _events(document, 'pointerdown').isNotEmpty,
                'mouse down',
              );
              checkEvent(
                _events(document, 'pointerdown').last,
                'mouse',
                90,
                60,
              );
              await mouse.moveTo(point(330, 170));
              await until(
                () => _events(
                  document,
                  'pointermove',
                ).any((e) => e['offsetX'] == 330),
                'capture keeps an outside drag',
              );
              expect(_events(document, 'pointerleave'), isEmpty);
              expect(_events(document, 'pointerout'), isEmpty);
              await mouse.moveTo(point(180, 100));
              await until(
                () => _events(
                  document,
                  'pointermove',
                ).any((e) => e['offsetX'] == 180),
                'mouse drag redraw',
              );
              expect(
                t.state(find.byType(NativeDocumentCanvasPointer)),
                same(state),
              );
              await mouse.up();
              await until(
                () => _events(document, 'click').isNotEmpty,
                'mouse coordinate click',
              );
              checkEvent(
                _events(document, 'pointerup').last,
                'mouse',
                180,
                100,
              );
              expect(_events(document, 'mousedown'), hasLength(1));
              expect(_events(document, 'mouseup'), hasLength(1));
              expect(_events(document, 'mousedown').single['pressure'], isNull);
              expect(_events(document, 'pointerdown').first['pressure'], 0.5);
              expect(_events(document, 'gotpointercapture'), hasLength(1));
              expect(_events(document, 'lostpointercapture'), hasLength(1));
              expect(_events(document, 'pointerup').last['buttons'], 0);
              expect(_events(document, 'pointerup').last['pressure'], 0);
              await redPixel(180, 100);
              await mouse.removePointer();
              final initialDownCount = _events(document, 'pointerdown').length;
              final touch = await t.startGesture(
                point(40, 55),
                kind: PointerDeviceKind.touch,
              );
              await until(
                () =>
                    _events(document, 'pointerdown').length > initialDownCount,
                'touch down',
              );
              checkEvent(
                _events(document, 'pointerdown').last,
                'touch',
                40,
                55,
              );
              await touch.moveTo(point(150, 100));
              await until(
                () => _events(document, 'pointermove').any(
                  (e) => e['pointerType'] == 'touch' && e['offsetX'] == 150,
                ),
                'touch drag updates DOM and canvas',
              );
              expect(
                t.state(find.byType(NativeDocumentCanvasPointer)),
                same(state),
              );
              await touch.up();
              await until(
                () => _events(
                  document,
                  'pointerup',
                ).any((e) => e['pointerType'] == 'touch'),
                'touch up',
              );
              checkEvent(
                _events(document, 'pointerup').last,
                'touch',
                150,
                100,
              );
              expect(_events(document, 'pointercancel'), isEmpty);
              expect(document.scroll.offset, 0);
              expect(document.scroll.position.maxScrollExtent, greaterThan(0));
              expect(
                (_probe(document)['captureCalls'] as List).every(
                  (c) => (c as Map)['ok'] == true,
                ),
                true,
              );
              await redPixel(150, 100);
              final auto = find.byWidgetPredicate(
                (w) =>
                    w is NativeHtmlButtonWidget &&
                    w.button.label == 'Enable page scrolling',
              );
              await t.ensureVisible(auto);
              await t.tap(auto);
              await until(
                () => _probe(document)['touchAction'] == 'auto',
                'script turns page scrolling on',
              );
              document.scroll.jumpTo(0);
              await t.pumpAndSettle();
              expect(
                t
                    .widget<NativeDocumentCanvasPointer>(
                      find.byType(NativeDocumentCanvasPointer),
                    )
                    .touchActionNone,
                false,
              );
              final scrollGesture = await t.startGesture(
                point(150, 120),
                kind: PointerDeviceKind.touch,
              );
              await until(
                () => _events(document, 'pointerdown').isNotEmpty,
                'auto down',
              );
              await scrollGesture.moveBy(const Offset(0, -60));
              await t.pump(const Duration(milliseconds: 50));
              await scrollGesture.moveBy(const Offset(0, -100));
              await until(
                () => _events(document, 'pointercancel').isNotEmpty,
                'scroll takes over and cancels canvas pointer',
              );
              await scrollGesture.up();
              await t.pumpAndSettle();
              expect(document.scroll.offset, greaterThan(0));
              expect(_events(document, 'pointercancel'), hasLength(1));
              expect(_events(document, 'pointerup'), isEmpty);
              expect(_events(document, 'click'), isEmpty);
              expect(document.scripts!.diagnostics, isEmpty);
              debugPrint(
                'CANVAS_POINTER:${width.toInt()}:${brightness.name}:$scale:PASS',
              );
            } finally {
              await t.pumpWidget(const SizedBox());
              final closed = document.scripts?.closed;
              document.dispose();
              if (closed != null) await closed;
              t.view.reset();
            }
          }
        }
      }
    },
  );
}
