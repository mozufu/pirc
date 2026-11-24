import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:html/dom.dart' as dom;
import 'package:pirc_mobile/live/document_navigation.dart';
import 'package:pirc_mobile/live/document_navigation_state.dart';
import 'package:pirc_mobile/live/gateway.dart';
import 'package:pirc_render/src/document_layout.dart';
import 'package:pirc_render/src/html_document_box.dart';
import 'package:pirc_render/src/html_document_content.dart';
import 'package:pirc_render/src/html_document_styles.dart';
import 'live_test.dart' show theme;

Finder box(String id) => find.byWidgetPredicate(
  (w) =>
      w is NativeDocumentBox &&
      w.geometryOwner is dom.Element &&
      (w.geometryOwner as dom.Element).id == id,
);
void main() {
  final fixture =
      jsonDecode(
            File(
              'tool/parity/fixtures/document-relative-units-chromium153.json',
            ).readAsStringSync(),
          )
          as Map;
  setUpAll(() {
    expect(fixture['browserVersion'], '153.0.8010.12');
    expect(fixture['cases'], hasLength(64));
  });
  for (final row in fixture['cases'] as List) {
    testWidgets(
      'native relative units ${row['spec']['id']} ${row['viewport']['width']} dpr${row['dpr']} ${row['theme']}',
      (tester) async {
        final bytes = Uint8List.fromList(utf8.encode(row['html'] as String));
        final document = NativeFetchedDocument(
          id: 0,
          url: 'https://relative-units.example/test',
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
        final visited = <String>[], paintKey = GlobalKey();
        final dpr = (row['dpr'] as num).toDouble();
        tester.view.devicePixelRatio = dpr;
        tester.view.padding = const FakeViewPadding();
        tester.view.viewPadding = const FakeViewPadding();
        tester.view.viewInsets = const FakeViewPadding();
        try {
          var generation = 0;
          for (final state in row['states'] as List) {
            final viewport = state['viewport'] as Map,
                result = state['result'] as Map;
            final size = Size(
              (viewport['width'] as num).toDouble(),
              (viewport['height'] as num).toDouble(),
            );
            tester.view.physicalSize = size * dpr;
            document.stylesheets = [
              NativeDocumentStylesheet(
                state['css'] as String,
                baseUrl: document.url,
              ),
            ];
            await tester.pumpWidget(
              MaterialApp(
                theme: theme.build(
                  row['theme'] == 'dark' ? Brightness.dark : Brightness.light,
                ),
                home: RepaintBoundary(
                  key: paintKey,
                  child: Scaffold(
                    body: NativeFetchedDocumentView(
                      document: document,
                      gateway: Gateway(),
                      onLink: (link) => visited.add(link.href),
                      onSubmit: (_) {},
                    ),
                  ),
                ),
              ),
            );
            await tester.pumpAndSettle();
            if (state['phase'] == 0) {
              await tester.enterText(
                find.byType(EditableText),
                'retained draft',
              );
              await tester.pumpAndSettle();
            }
            expect(
              tester
                  .widget<EditableText>(find.byType(EditableText))
                  .controller
                  .text,
              result['draft'],
            );
            final root = tester.widget<NativeDocumentLayoutRoot>(
              find.byType(NativeDocumentLayoutRoot),
            );
            final packet = root.controller.capture(
              revision: root.revision,
              generation: ++generation,
              viewport: size,
            );
            expect(packet, isNotNull);
            final elements = <String, dom.Element>{};
            for (final w in tester.widgetList<NativeDocumentBox>(
              find.byType(NativeDocumentBox),
            )) {
              if (w.geometryOwner case final dom.Element e) {
                final id = e.attributes['data-pirc-script-id'];
                if (id != null) elements[id] = e;
              }
            }
            final packetBoxes = {
              for (final entry in packet!['boxes'] as List)
                entry['id']: entry as Map,
            };
            for (final id in ['parent', 'subject', 'after']) {
              final expected = result['items'][id] as Map;
              final rect = tester.getRect(box(id)),
                  reference = expected['rect'] as List;
              for (var axis = 0; axis < 4; axis++) {
                expect(
                  [rect.left, rect.top, rect.width, rect.height][axis],
                  closeTo((reference[axis] as num).toDouble(), 1 / 32),
                  reason: '$id phase${state['phase']} rect$axis',
                );
              }
              final e =
                      (tester.widget<NativeDocumentBox>(box(id)).geometryOwner
                          as dom.Element),
                  nativeId = e.attributes['data-pirc-script-id'];
              final actual = packetBoxes[nativeId]!;
              final offset = actual['offset'] as Map?;
              expect(offset, isNotNull, reason: '$id measured offset support');
              expect(
                offset!['top'],
                expected['offset']['top'],
                reason: '$id offsetTop',
              );
              expect(
                offset['left'],
                expected['offset']['left'],
                reason: '$id offsetLeft',
              );
              expect(
                offset['parentId'] == null
                    ? null
                    : elements[offset['parentId']]?.id,
                expected['offset']['parent'],
                reason: '$id offsetParent',
              );
              for (final property in [
                'top',
                'right',
                'bottom',
                'left',
                'font-size',
              ]) {
                expect(
                  actual['computedStyle'][property],
                  expected['style'][property],
                  reason: '$id $property phase${state['phase']}',
                );
              }
            }
            final boundary = tester.renderObject<RenderRepaintBoundary>(
              find.byKey(paintKey),
            );
            final image = (await tester.runAsync(
              () => boundary.toImage(pixelRatio: dpr),
            ))!;
            try {
              final data = (await tester.runAsync(
                () => image.toByteData(
                  format: ui.ImageByteFormat.rawStraightRgba,
                ),
              ))!;
              for (var i = 0; i < (result['probes'] as List).length; i++) {
                final p = result['probes'][i] as List;
                final x = ((p[0] as num) * dpr).floor(),
                    y = ((p[1] as num) * dpr).floor(),
                    base = (y * image.width + x) * 4;
                expect(
                  [for (var c = 0; c < 4; c++) data.getUint8(base + c)],
                  result['pixels'][i],
                  reason: 'paint probe$i phase${state['phase']}',
                );
              }
            } finally {
              image.dispose();
            }
            Offset point(String name) {
              final p = result[name] as List;
              return Offset((p[0] as num).toDouble(), (p[1] as num).toDouble());
            }

            final before = visited.length;
            await tester.tapAt(point('original'));
            await tester.pumpAndSettle();
            expect(
              visited,
              hasLength(before),
              reason: 'old flow point cannot activate shifted link',
            );
            await tester.tapAt(point('hit'));
            await tester.pumpAndSettle();
            expect(visited, hasLength(before + 1));
            expect(visited.last, '/next');
            expect(tester.takeException(), isNull);
          }
        } finally {
          await tester.pumpWidget(const SizedBox());
          document.dispose();
          await tester.pumpAndSettle();
          tester.view.reset();
        }
      },
    );
  }
}
