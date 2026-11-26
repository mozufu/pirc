import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:html/dom.dart' as dom;
import 'package:pirc_mobile/live/document_navigation.dart';
import 'package:pirc_mobile/live/document_navigation_state.dart';
import 'package:pirc_mobile/live/document_scripts.dart';
import 'package:pirc_render/src/html_buttons.dart';
import 'package:pirc_render/src/html_document_box.dart';
import 'package:pirc_render/src/html_form_submission.dart';
import 'document_navigation_widget_test.dart' show response;
import 'live_test.dart' show theme;
import 'support/document_vm_gateway.dart';

class AssetGateway extends DocumentVmGateway {
  AssetGateway._(super.process) : super.forTest();
  static Future<AssetGateway> start() async => AssetGateway._(
    await Process.start(Platform.environment['PIRC_TEST_NODE'] ?? 'node', [
      'tool/parity/document_vm_host.mjs',
    ]),
  );
  Uint8List alternate = Uint8List(0);
  int imageCalls = 0;
  final controlWrites = <String>[];
  bool failDispatch = false;
  @override
  Future<dynamic> call(
    String method, [
    Map<String, dynamic> args = const {},
  ]) async {
    if (method == 'documentScriptEvaluate') {
      final source = args['source'] as String;
      if (failDispatch && source.startsWith('__pircDocument.dispatch')) {
        throw StateError('synthetic stopped image script');
      }
      if (source.startsWith('__pircDocument.restoreControls') ||
          source.startsWith('__pircDocument.dispatch')) {
        controlWrites.add(source);
      }
    }
    if (method == 'image') {
      imageCalls++;
      return {'bytes': alternate, 'mimeType': 'image/png'};
    }
    return super.call(method, args);
  }
}

void main() => runLiveAssetCases(
  '../../packages/pirc_render/test/fixtures/parity/document-live-assets-chromium153.json',
);

void runLiveAssetCases(String fixturePath) {
  final runtime = File('assets/document-script-runtime.js').readAsStringSync();
  final fixture = jsonDecode(File(fixturePath).readAsStringSync()) as Map;
  final imagePath = fixture['imagePath'] as String? ?? '/photo.png';
  final imageMime = fixture['imageMime'] as String? ?? 'image/png';
  final imageBytes = base64Decode(
    (fixture['imageBase64'] ?? fixture['png']) as String,
  );
  for (final row in fixture['cases'] as List) {
    for (final scenario in [
      'remount',
      'same-frame',
      'startup',
      if (identical(row, (fixture['cases'] as List).first)) 'stopped',
    ]) {
      testWidgets(
        'live assets ${row['viewport']['width']} ${row['theme']} dpr${row['dpr']} scenario=$scenario',
        (t) async {
          final sameFrame = scenario == 'same-frame';
          final startup = scenario == 'startup';
          final g = (await t.runAsync(AssetGateway.start))!
            ..alternate = base64Decode(fixture['secondFetchPng'] as String)
            ..responses.add({
              ...response(
                '/test',
                fixture[startup ? 'startupHtml' : 'html'] as String,
              ),
              'finalUrl': 'https://assets.example/test',
            });
          final windows = NativeDocumentWindows(g),
              window = windows.target(
                'assets',
                null,
                sourceUrl: 'https://assets.example/',
              );
          await window.load(
            const NativeHtmlFormRequest(
              url: '/test',
              method: 'GET',
              target: '',
            ),
            baseUrl: window.sourceUrl,
          );
          windows.select(window);
          final doc = window.currentDocument!;
          doc.scripts = NativeDocumentScripts(
            g,
            loadRuntime: () async => runtime,
          );
          final paintKey = GlobalKey();
          Widget page(int epoch) => RepaintBoundary(
            key: paintKey,
            child: MaterialApp(
              theme: theme.build(
                row['theme'] == 'dark' ? Brightness.dark : Brightness.light,
              ),
              home: NativeDocumentWorkspace(
                key: ValueKey(epoch),
                windows: windows,
              ),
            ),
          );
          Finder button(String text) => find.byWidgetPredicate(
            (w) => w is NativeHtmlButtonWidget && w.button.label == text,
          );
          Finder box(String id) => find.byWidgetPredicate(
            (w) =>
                w is NativeDocumentBox &&
                w.geometryOwner is dom.Element &&
                (w.geometryOwner as dom.Element).id == id,
          );
          String request(String path) => g.requests.entries
              .singleWhere(
                (e) => Uri.parse(e.value['url'] as String).path == path,
              )
              .key;
          Future<void> awaitRequest(String path) async => driveDocumentVm(
            t,
            () => g.requests.values.any(
              (r) => Uri.parse(r['url'] as String).path == path,
            ),
            reason: 'request $path',
            diagnostic: () => '${doc.scripts?.diagnostics}',
          );
          void reply(
            String path,
            List<int> bytes,
            String mime, {
            String? type,
          }) {
            final id = request(path);
            g.resources[id]!.complete({
              'url': g.requests[id]!['url'],
              'status': 200,
              'statusText': 'OK',
              'headers': {'content-type': mime},
              'type': type ?? 'basic',
              'mimeType': mime,
              'originClean': true,
              'bodyBytes': bytes,
            });
          }

          Future<void> replace(int epoch) async {
            if (!sameFrame) {
              await t.pumpWidget(const SizedBox.shrink());
              await t.pump();
            }
            await t.pumpWidget(page(epoch));
          }

          Future<void> compare(String phase) async {
            final expected = phase == 'startup'
                ? row['startup'] as Map
                : (row['states'] as List).singleWhere(
                        (s) => s['phase'] == phase,
                      )
                      as Map;
            var stable = 0;
            await driveDocumentVm(
              t,
              () {
                final ready =
                    box('panel').evaluate().length == 1 &&
                    (t.getSize(box('panel')).height -
                                (expected['panel'][3] as num))
                            .abs() <
                        1 / 32 &&
                    doc.scripts?.hasPendingPublication == false;
                stable = ready ? stable + 1 : 0;
                return stable >= 3;
              },
              reason: '$phase publication',
              diagnostic: () => '${doc.scripts?.diagnostics}',
            );
            final actual = await t.runAsync(
              () => g.inspect(
                '({probe:window.probe,value:document.getElementById("draft").value,background:getComputedStyle(document.getElementById("panel")).backgroundColor,natural:[document.getElementById("photo").naturalWidth,document.getElementById("photo").naturalHeight]})',
              ),
            );
            expect(actual, {
              for (final k in ['probe', 'value', 'background', 'natural'])
                k: expected[k],
            }, reason: '$phase JS controls=${g.controlWrites}');
            expect(
              t.widget<EditableText>(find.byType(EditableText)).controller.text,
              expected['value'],
            );
            final rect = t.getRect(box('panel'));
            for (var i = 0; i < 4; i++) {
              expect(
                [rect.left, rect.top - 48, rect.width, rect.height][i],
                closeTo((expected['panel'][i] as num).toDouble(), 1 / 32),
              );
            }
            if (expected['pixels'] != null) {
              final boundary = t.renderObject<RenderRepaintBoundary>(
                find.byKey(paintKey),
              );
              final image = (await t.runAsync(
                () => boundary.toImage(pixelRatio: t.view.devicePixelRatio),
              ))!;
              try {
                final bytes = (await t.runAsync(
                  () => image.toByteData(
                    format: ui.ImageByteFormat.rawStraightRgba,
                  ),
                ))!;
                final points = expected['points'] as List;
                for (var i = 0; i < points.length; i++) {
                  final p = points[i] as List;
                  final x = ((p[0] as num) * t.view.devicePixelRatio).floor(),
                      y = (((p[1] as num) + 48) * t.view.devicePixelRatio)
                          .floor(),
                      start = (y * image.width + x) * 4;
                  expect(
                    [for (var c = 0; c < 4; c++) bytes.getUint8(start + c)],
                    expected['pixels'][i],
                    reason: '$phase actual image/canvas pixel$i',
                  );
                }
              } finally {
                image.dispose();
              }
            }
          }

          try {
            t.view.devicePixelRatio = (row['dpr'] as num).toDouble();
            t.view.physicalSize =
                Size(
                  (row['viewport']['width'] as num).toDouble(),
                  (row['viewport']['height'] as num).toDouble() + 48,
                ) *
                t.view.devicePixelRatio;
            addTearDown(t.view.reset);
            await t.pumpWidget(page(0));
            await driveDocumentVm(
              t,
              () => doc.scripts?.ready == true,
              reason: 'startup',
              diagnostic: () => '${doc.scripts?.diagnostics}',
            );
            if (startup) {
              await awaitRequest(imagePath);
              await replace(1);
              reply(imagePath, imageBytes, imageMime, type: 'image');
              await driveDocumentVm(
                t,
                () => find
                    .text('Image loaded', findRichText: true)
                    .evaluate()
                    .isNotEmpty,
                reason: 'startup image',
              );
              await compare('startup');
              expect(
                g.imageCalls,
                0,
                reason: 'startup image shares decoded resource',
              );
              expect(g.requests, hasLength(1));
              expect(g.opens, 1);
              expect(t.takeException(), isNull);
              return;
            }
            await compare('initial');
            await t.enterText(find.byType(EditableText), '草稿🙂');
            await t.tap(button('Load style'));
            await awaitRequest('/theme.css');
            await replace(1);
            reply(
              '/theme.css',
              utf8.encode(fixture['css'] as String),
              'text/css',
              type: 'stylesheet',
            );
            await driveDocumentVm(
              t,
              () => find
                  .text('Style loaded', findRichText: true)
                  .evaluate()
                  .isNotEmpty,
              reason: 'stylesheet load',
              diagnostic: () => '${doc.scripts?.diagnostics}',
            );
            await compare('style');
            await t.tap(button('Load image'));
            await awaitRequest(imagePath);
            await replace(2);
            reply(imagePath, imageBytes, imageMime, type: 'image');
            await driveDocumentVm(
              t,
              () => find
                  .text('Image loaded', findRichText: true)
                  .evaluate()
                  .isNotEmpty,
              reason: 'image load',
              diagnostic: () => '${doc.scripts?.diagnostics}',
            );
            await compare('image');
            if (scenario == 'stopped') {
              g.failDispatch = true;
              final stopping = doc.scripts!.dispatch('pirc-1', 'click', []);
              await driveDocumentVm(
                t,
                () => !doc.scripts!.ready && g.closes == g.opens,
                reason: 'stopped VM',
              );
              await stopping;
              await t.pump();
              expect(
                doc.scripts!.htmlImages.values.every(
                  (image) => image.status == 'loaded',
                ),
                isTrue,
              );
              expect(doc.scripts!.htmlImages, isNotEmpty);
              expect(
                find.byType(
                  imageMime == 'image/svg+xml' ? SvgPicture : RawImage,
                ),
                findsOneWidget,
              );
              expect(
                g.imageCalls,
                0,
                reason: 'valid cached image must not refetch after VM failure',
              );
              expect(t.takeException(), isNull);
              return;
            }
            await t.tap(button('Load module'));
            await awaitRequest('/entry.js');
            await replace(3);
            reply(
              '/entry.js',
              utf8.encode(fixture['entry'] as String),
              'application/javascript',
            );
            await awaitRequest('/dep.js');
            await replace(4);
            reply(
              '/dep.js',
              utf8.encode(fixture['dep'] as String),
              'application/javascript',
            );
            await driveDocumentVm(
              t,
              () => find
                  .text('Module loaded', findRichText: true)
                  .evaluate()
                  .isNotEmpty,
              reason: 'module load',
              diagnostic: () => '${doc.scripts?.diagnostics}',
            );
            await compare('module');
            await t.tap(button('Load module'));
            await compare('cached');
            expect(g.requests, hasLength(4));
            expect(
              g.imageCalls,
              0,
              reason:
                  'managed image must share the decoded native image with JS/Canvas',
            );
            expect(g.opens, 1);
            expect(
              g.controlWrites.where(
                (source) => source.startsWith('__pircDocument.restoreControls'),
              ),
              isEmpty,
              reason:
                  'presentation updates must not replay stale form values into the VM',
            );
            expect(t.takeException(), isNull);
          } finally {
            await t.pumpWidget(const SizedBox.shrink());
            final scripts = doc.scripts;
            windows.dispose();
            var closed = false;
            (scripts?.closed ?? Future<void>.value()).then(
              (_) => closed = true,
            );
            await driveDocumentVm(
              t,
              () => closed && g.closes == g.opens,
              reason: 'retirement',
            );
            await t.runAsync(g.close);
            await t.pump();
          }
        },
      );
    }
  }
}
