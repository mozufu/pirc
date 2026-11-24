import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show debugPrintSynchronously;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:html/parser.dart' as html;
import 'package:integration_test/integration_test.dart';
import 'package:pirc_mobile/live/document_navigation.dart';
import 'package:pirc_mobile/live/document_navigation_state.dart';
import 'package:pirc_mobile/live/gateway.dart';
import 'package:pirc_render_document/src/document_canvas.dart';
import 'package:pirc_render/src/html_background_gradient.dart'
    show parseNativeCssColor;
import 'package:pirc_render/src/html_form_submission.dart';
import 'package:pirc_mobile/theme.dart';

const _fixtureOrigin = String.fromEnvironment('PIRC_CHART_FIXTURE_ORIGIN');

class _ChartGateway extends Gateway {
  @override
  Future<dynamic> call(String method, [Json args = const {}]) async {
    try {
      return await super.call(method, args);
    } catch (error) {
      if (method.startsWith('documentScript')) {
        final source = args['source'] as String? ?? '';
        final operation =
            RegExp(
              r'^(__pircDocument\.\w+|__pircInitializeCanvasText)',
            ).firstMatch(source)?.group(1) ??
            'runtime/source';
        debugPrintSynchronously(
          'PIRC_CHART_BRIDGE_ERROR ${jsonEncode({'method': method, 'operation': operation, 'error': '$error'})}',
        );
      }
      rethrow;
    }
  }
}

Future<String> _fixture(String path) async {
  final origin = Uri.parse(_fixtureOrigin);
  if (origin.scheme != 'http' || origin.host != '127.0.0.1') {
    throw ArgumentError(
      'Chart acceptance requires the loopback fixture server.',
    );
  }
  final client = HttpClient();
  try {
    final request = await client.getUrl(origin.resolve(path));
    final response = await request.close();
    if (response.statusCode != 200) {
      throw HttpException('Missing fixture: $path');
    }
    return await utf8.decoder.bind(response).join();
  } finally {
    client.close(force: true);
  }
}

String _page(int width, int dpr) {
  final chartWidth = width - 40;
  return '''<!doctype html><html><head><meta charset="utf-8"><style>
html,body{margin:0;padding:0}
#chart-container{position:relative;margin-left:20px;width:${chartWidth}px;height:240px}
#chart{display:block;box-sizing:border-box;width:${chartWidth}px;height:240px}
</style></head><body>
<div id="chart-container"><canvas id="chart" width="${chartWidth * dpr}" height="${240 * dpr}" style="display:block;box-sizing:border-box;width:${chartWidth}px;height:240px"></canvas></div>
<button type="button" id="update">Update data</button><button type="button" id="resize">Resize container</button><pre id="probe">WAIT</pre>
<script src="/chart.js"></script><script>
var canvas=document.getElementById('chart'),chart,chartClicks=[],clickSerial=0,interactionSerial=0,interactionReportPending=false;
function interactionState(){var t=chart.tooltip,r=canvas.getBoundingClientRect();return {
 chartActive:chart.getActiveElements().map(function(e){return {datasetIndex:e.datasetIndex,index:e.index}}),
 tooltip:{opacity:t.opacity,title:t.title||[],body:(t.body||[]).map(function(b){return {before:b.before,lines:b.lines,after:b.after}}),active:t.getActiveElements().map(function(e){return {datasetIndex:e.datasetIndex,index:e.index}}),bounds:{x:t.x,y:t.y,width:t.width,height:t.height}},
 legend:{hitBoxes:chart.legend.legendHitBoxes.map(function(b,i){var item=chart.legend.legendItems[i];return {text:item.text,hidden:item.hidden,datasetIndex:item.datasetIndex,left:b.left,top:b.top,width:b.width,height:b.height,centerPageX:r.x+b.left+b.width/2,centerPageY:r.y+b.top+b.height/2}})},datasetVisible:chart.isDatasetVisible(0),chartClicks:chartClicks,clickSerial:clickSerial,interactionSerial:interactionSerial,chartArea:chart.chartArea};}
function chartState(){var s=getComputedStyle(canvas),r=canvas.getBoundingClientRect();return {
 chart:{width:chart.width,height:chart.height,currentDevicePixelRatio:chart.currentDevicePixelRatio},
 windowDevicePixelRatio:window.devicePixelRatio,
 canvas:{widthAttribute:canvas.width,heightAttribute:canvas.height,css:{display:s.display,boxSizing:s.boxSizing,width:s.width,height:s.height},rect:{x:r.x,y:r.y,width:r.width,height:r.height}},
 bars:chart.getDatasetMeta(0).data.map(function(e,i){var g=e.getProps(['x','y','base','width','height'],true);return {index:i,label:chart.data.labels[i],value:chart.data.datasets[0].data[i],color:e.options.backgroundColor,x:g.x,y:g.y,base:g.base,width:g.width,height:g.height}}),
 labels:chart.data.labels,mutationObserver:typeof MutationObserver,interaction:interactionState()
}}
try{
 var ctx=canvas.getContext('2d');ctx.fillStyle='#ff00ff';ctx.fillRect(0,0,2,2);
 canvas.width=canvas.width;canvas.height=canvas.height;
 chart=new Chart(canvas,{type:'bar',data:{labels:['A','B'],datasets:[{label:'Data',data:[3,7],backgroundColor:'#3b82f6'}]},options:{responsive:true,animation:false,maintainAspectRatio:false,devicePixelRatio:$dpr,onClick:function(e,active){chartClicks.push({kind:e.type,nativeType:e.native.type,x:e.x,y:e.y,inChartArea:e.inChartArea,active:active.map(function(a){return {datasetIndex:a.datasetIndex,index:a.index}})})}}});
 function reportInteraction(){interactionSerial++;if(interactionReportPending)return;interactionReportPending=true;requestAnimationFrame(function(){requestAnimationFrame(function(){interactionReportPending=false;try{document.getElementById('probe').textContent=JSON.stringify(chartState())}catch(e){document.getElementById('probe').textContent=JSON.stringify({error:e.name+': '+e.message})}})})}
 canvas.addEventListener('click',function(){clickSerial++;reportInteraction()});
 canvas.addEventListener('mouseout',reportInteraction);
 document.getElementById('probe').textContent=JSON.stringify(chartState());
 document.getElementById('update').onclick=function(){try{chart.data.datasets[0].data=[6,2];chart.update('none');document.getElementById('probe').textContent=JSON.stringify(chartState())}catch(e){document.getElementById('probe').textContent=JSON.stringify({error:e.name+': '+e.message})}};
 document.getElementById('resize').onclick=function(){
   document.getElementById('chart-container').style.width='${chartWidth + 20}px';canvas.style.width='${chartWidth + 20}px';
   var turns=0;
   function reportResize(){try{if(chart.width!==${chartWidth + 20}&&++turns<30){requestAnimationFrame(reportResize);return}var state=chartState();state.resized=true;document.getElementById('probe').textContent=JSON.stringify(state)}catch(e){document.getElementById('probe').textContent=JSON.stringify({error:e.name+': '+e.message})}}
   requestAnimationFrame(function(){requestAnimationFrame(reportResize)});
 };
}catch(e){document.getElementById('probe').textContent=JSON.stringify({error:e.name+': '+e.message})}
</script></body></html>''';
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  // Match the app: both tests share one EventChannel listener/owner.
  final gateway = _ChartGateway();
  testWidgets(
    'native Chart.js touch tooltips, legend toggles, rapid outside taps, updates and resizing',
    (tester) async {
      final chartSource = await _fixture('/chart.js');
      final reference = obj(jsonDecode(await _fixture('/reference.json')));
      final interactionReference = obj(
        jsonDecode(await _fixture('/interactions.json')),
      );
      final theme = await PircTheme.load();
      final acceptance = <Json>[];
      for (final expectedCase in rows(reference['cases'])) {
        final viewport = obj(expectedCase['viewport']);
        final width = (viewport['width'] as num).toInt();
        final height = (viewport['height'] as num).toInt();
        final dpr = (expectedCase['dpr'] as num).toInt();
        final failures = <String>[];
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        final origin = 'http://127.0.0.1:${server.port}';
        final token = 'pirc_dev_${List.filled(43, 'C').join()}';
        final listener = server.listen((request) async {
          try {
            await request.drain<void>();
            if (request.headers.value('authorization') != 'Bearer $token') {
              failures.add('Missing synthetic bearer');
            }
            if (request.uri.path == '/api/sessions') {
              request.response.headers.contentType = ContentType.json;
              request.response.write('{"sessions":[]}');
            } else if (request.uri.path == '/page') {
              request.response.headers.contentType = ContentType(
                'text',
                'html',
                charset: 'utf-8',
              );
              request.response.write(_page(width, dpr));
            } else if (request.uri.path == '/chart.js') {
              request.response.headers.contentType = ContentType(
                'text',
                'javascript',
                charset: 'utf-8',
              );
              request.response.write(chartSource);
            } else {
              request.response.statusCode = 404;
              failures.add('Unexpected path ${request.uri.path}');
            }
            await request.response.close();
          } catch (error) {
            failures.add('$error');
          }
        });
        NativeDocumentWindows? windows;
        NativeFetchedDocument? document;
        try {
          await gateway.call('pair', {
            'link': Uri(
              scheme: 'pirc',
              host: 'pair',
              queryParameters: {'url': origin, 'token': token},
            ).toString(),
          });
          windows = NativeDocumentWindows(gateway);
          final window = windows.target('', null, sourceUrl: '$origin/page');
          expect(
            await window.load(
              NativeHtmlFormRequest(
                url: '$origin/page',
                method: 'GET',
                target: '',
              ),
              baseUrl: origin,
            ),
            NativeDocumentLoadResult.committed,
          );
          windows.select(window);
          document = window.currentDocument!;
          tester.view.devicePixelRatio = dpr.toDouble();
          tester.view.physicalSize = Size(
            width * dpr.toDouble(),
            height * dpr.toDouble(),
          );
          await tester.pumpWidget(
            MaterialApp(
              theme: theme.build(Brightness.light),
              home: Scaffold(
                body: NativeDocumentScope(
                  documentUrl: '$origin/page',
                  windows: windows,
                  window: window,
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
          Json observation() {
            final text = html
                .parse(document!.scripts?.content?.text ?? '')
                .getElementById('probe')
                ?.text;
            if (text == null || !text.startsWith('{')) return {};
            return obj(jsonDecode(text));
          }

          Future<void> ready({
            bool updated = false,
            bool resized = false,
          }) async {
            for (var turn = 0; turn < 300; turn++) {
              await tester.pump(const Duration(milliseconds: 50));
              final current = observation();
              if (current.containsKey('error')) {
                fail(
                  '${expectedCase['caseId']} ${current['error']}; ${document!.scripts?.diagnostics}',
                );
              }
              if (document!.scripts?.ready == true &&
                  current['bars'] is List &&
                  (!updated || rows(current['bars']).first['value'] == 6) &&
                  (!resized || current['resized'] == true)) {
                return;
              }
            }
            fail('Chart not ready: ${document!.scripts?.diagnostics}');
          }

          final deltas = <Json>[];
          void compare(Json actual, Json expected, String stage) {
            expect(actual['chart'], expected['chart']);
            expect(
              actual['windowDevicePixelRatio'],
              expected['windowDevicePixelRatio'],
            );
            expect(actual['canvas'], expected['canvas']);
            expect(actual['labels'], expected['labels']);
            expect(actual['mutationObserver'], 'function');
            final bars = rows(actual['bars']),
                referenceBars = rows(expected['bars']);
            expect(bars, hasLength(referenceBars.length));
            for (var i = 0; i < bars.length; i++) {
              expect(bars[i]['value'], referenceBars[i]['value']);
              for (final key in ['x', 'y', 'base', 'width', 'height']) {
                final delta =
                    (bars[i][key] as num).toDouble() -
                    (referenceBars[i][key] as num).toDouble();
                deltas.add({
                  'stage': stage,
                  'bar': i,
                  'property': key,
                  'delta': delta,
                });
                expect(
                  delta.abs(),
                  lessThanOrEqualTo(2),
                  reason:
                      'Known platform-font geometry delta ${expectedCase['caseId']} $stage/$i/$key',
                );
              }
            }
          }

          Future<List<Json>> verifyPaint(
            Json current, {
            Json? interactionExpected,
            List<Json>? initialBarSamples,
          }) async {
            final barPixelChecks = <Json>[];
            final finder = find.byType(NativeDocumentCanvas);
            expect(finder, findsOneWidget);
            final widget = tester.widget<NativeDocumentCanvas>(finder);
            final snapshot = widget.snapshot;
            expect(snapshot.width, obj(current['canvas'])['widthAttribute']);
            expect(snapshot.height, 240 * dpr);
            expect(
              snapshot.commands.any((command) => command.op == 'fillText'),
              true,
            );
            final recorder = ui.PictureRecorder();
            final canvas = Canvas(recorder);
            NativeDocumentCanvasPainter(
              snapshot,
            ).paint(canvas, Size(snapshot.width, snapshot.height));
            final picture = recorder.endRecording();
            final image = await tester.runAsync(
              () => picture.toImage(
                snapshot.width.toInt(),
                snapshot.height.toInt(),
              ),
            );
            try {
              final data = (await tester.runAsync(
                () => image!.toByteData(format: ui.ImageByteFormat.rawRgba),
              ))!;
              final bytes = data.buffer.asUint8List();
              for (final bar
                  in (obj(current['interaction'])['datasetVisible'] == false
                      ? <Json>[]
                      : rows(current['bars']))) {
                final x = ((bar['x'] as num) * dpr).floor();
                final y = (((bar['y'] as num) + (bar['base'] as num)) / 2 * dpr)
                    .floor();
                final offset = (y * snapshot.width.toInt() + x) * 4;
                final colorText = interactionExpected == null
                    ? '#3b82f6'
                    : rows(interactionExpected['bars'])[(bar['index'] as num)
                              .toInt()]['color']
                          as String;
                final color = parseNativeCssColor(colorText)!.toARGB32();
                expect(bytes.sublist(offset, offset + 4), [
                  (color >> 16) & 255,
                  (color >> 8) & 255,
                  color & 255,
                  (color >> 24) & 255,
                ]);
              }
              if (initialBarSamples != null) {
                final expected = interactionExpected!;
                final expectedVisible = expected['datasetVisible'] == true;
                final actualInitialBars = initialBarSamples;
                final referenceInitialBars = rows(expected['bars']);
                expect(
                  actualInitialBars,
                  hasLength(referenceInitialBars.length),
                );
                for (var index = 0; index < actualInitialBars.length; index++) {
                  final bar = actualInitialBars[index];
                  final x = ((bar['x'] as num) * dpr).floor();
                  final y =
                      (((bar['y'] as num) + (bar['base'] as num)) / 2 * dpr)
                          .floor();
                  final offset = (y * snapshot.width.toInt() + x) * 4;
                  final pixel = bytes.sublist(offset, offset + 4).toList();
                  final colorText =
                      referenceInitialBars[index]['color'] as String;
                  final argb = parseNativeCssColor(colorText)!.toARGB32();
                  final visibleColor = [
                    (argb >> 16) & 255,
                    (argb >> 8) & 255,
                    argb & 255,
                    (argb >> 24) & 255,
                  ];
                  if (expectedVisible) {
                    expect(
                      pixel,
                      visibleColor,
                      reason:
                          'Legend show must restore bar $index at its original Canvas sample point.',
                    );
                  } else {
                    expect(
                      pixel,
                      isNot(equals(visibleColor)),
                      reason:
                          'Legend hide must remove bar $index fill from its original Canvas sample point.',
                    );
                  }
                  barPixelChecks.add({
                    'barIndex': index,
                    'canvasCssPoint': {
                      'x': bar['x'],
                      'y': ((bar['y'] as num) + (bar['base'] as num)) / 2,
                    },
                    'pixelRgba': pixel,
                    'datasetColorRgba': visibleColor,
                    'datasetVisible': expectedVisible,
                  });
                }
              }
              if (interactionExpected != null &&
                  obj(interactionExpected['tooltip'])['opacity'] == 1) {
                final tooltip = obj(obj(current['interaction'])['tooltip']);
                final bounds = obj(tooltip['bounds']);
                final x = (((bounds['x'] as num) + 8) * dpr).floor();
                final y = (((bounds['y'] as num) + 3) * dpr).floor();
                final offset = (y * snapshot.width.toInt() + x) * 4;
                expect(
                  bytes.sublist(offset, offset + 4),
                  obj(
                    obj(interactionExpected['tooltip'])['backgroundSample'],
                  )['rgba'],
                );
                for (final row in rows(tooltip['body'])) {
                  for (final line in row['lines'] as List) {
                    expect(
                      snapshot.commands.any(
                        (command) =>
                            command.op == 'fillText' &&
                            command.args.first == line,
                      ),
                      true,
                      reason:
                          'Actual tooltip text must reach the native painter.',
                    );
                  }
                }
              }
            } finally {
              image?.dispose();
              picture.dispose();
            }
            return barPixelChecks;
          }

          await ready();
          final initial = observation();
          compare(initial, obj(expectedCase['initial']), 'initial');
          await verifyPaint(initial);
          final interactionCase = rows(
            interactionReference['cases'],
          ).singleWhere((value) => value['caseId'] == expectedCase['caseId']);
          final interactionSteps = obj(interactionCase['steps']);
          final interactionAcceptance = <Json>[];
          for (final name in [
            'touchFirstBar',
            'touchSecondBar',
            'touchOutsideCanvas',
            'touchBlankChart',
            'legendHide',
            'legendShow',
          ]) {
            final before = observation();
            final beforeState = obj(before['interaction']);
            final callCount = rows(beforeState['chartClicks']).length;
            final serial = beforeState['interactionSerial'] as int;
            final expectedStep = obj(interactionSteps[name]);
            final expectedState = obj(expectedStep['state']);
            final origin = tester.getTopLeft(find.byType(NativeDocumentCanvas));
            Offset point;
            if (name == 'touchFirstBar' || name == 'touchSecondBar') {
              final index = name == 'touchFirstBar' ? 0 : 1;
              final bar = rows(before['bars'])[index];
              point =
                  origin +
                  Offset(
                    (bar['x'] as num).toDouble(),
                    ((bar['y'] as num) + (bar['base'] as num)) / 2,
                  );
            } else if (name == 'legendHide' || name == 'legendShow') {
              final box = rows(obj(beforeState['legend'])['hitBoxes']).first;
              point =
                  origin +
                  Offset(
                    (box['left'] as num) + (box['width'] as num) / 2,
                    (box['top'] as num) + (box['height'] as num) / 2,
                  );
            } else if (name == 'touchOutsideCanvas') {
              point = Offset(width - 5, origin.dy + 120);
            } else {
              final area = obj(beforeState['chartArea']);
              point =
                  origin +
                  Offset((area['right'] as num) - 3, (area['top'] as num) + 3);
            }
            await tester.tapAt(point);
            for (var frame = 0; frame < 120; frame++) {
              await tester.pump(const Duration(milliseconds: 50));
              final state = obj(observation()['interaction']);
              if ((state['interactionSerial'] as int? ?? 0) > serial) break;
            }
            final actual = observation();
            final state = obj(actual['interaction']);
            debugPrintSynchronously(
              'PIRC_CHART_INTERACTION_STEP ${jsonEncode({'name': name, 'state': state, 'diagnostics': document.scripts?.diagnostics})}',
            );
            expect(
              state['chartActive'],
              expectedState['chartActive'],
              reason: name,
            );
            expect(
              state['datasetVisible'],
              expectedState['datasetVisible'],
              reason: name,
            );
            final actualHitBoxes = rows(obj(state['legend'])['hitBoxes']);
            final expectedHitBoxes = rows(
              obj(expectedState['legend'])['hitBoxes'],
            );
            expect(actualHitBoxes, hasLength(expectedHitBoxes.length));
            for (var index = 0; index < actualHitBoxes.length; index++) {
              expect(
                actualHitBoxes[index]['text'],
                expectedHitBoxes[index]['text'],
                reason: name,
              );
              expect(
                actualHitBoxes[index]['datasetIndex'],
                expectedHitBoxes[index]['datasetIndex'],
                reason: name,
              );
              expect(
                actualHitBoxes[index]['hidden'],
                expectedHitBoxes[index]['hidden'],
                reason: name,
              );
            }
            final tooltip = obj(state['tooltip']),
                expectedTooltip = obj(expectedState['tooltip']);
            expect(
              tooltip['opacity'],
              expectedTooltip['opacity'],
              reason: name,
            );
            expect(tooltip['active'], expectedTooltip['active'], reason: name);
            if (expectedTooltip['opacity'] == 1) {
              expect(tooltip['title'], expectedTooltip['title'], reason: name);
              expect(tooltip['body'], expectedTooltip['body'], reason: name);
              for (final key in ['x', 'y', 'width', 'height']) {
                expect(
                  obj(tooltip['bounds'])[key],
                  closeTo(
                    (obj(expectedTooltip['bounds'])[key] as num).toDouble(),
                    2,
                  ),
                  reason:
                      '$name tooltip geometry with known native font difference',
                );
              }
            }
            final calls = rows(state['chartClicks']).skip(callCount).toList(),
                expectedCalls = rows(expectedState['chartClicks']);
            expect(calls.length, expectedCalls.length, reason: name);
            for (var index = 0; index < calls.length; index++) {
              for (final key in ['kind', 'nativeType', 'active']) {
                expect(
                  calls[index][key],
                  expectedCalls[index][key],
                  reason: name,
                );
              }
            }
            expect(document.scripts?.diagnostics, isEmpty, reason: name);
            final checkLegendBarVisibility =
                name == 'legendHide' || name == 'legendShow';
            final barPixelChecks = await verifyPaint(
              actual,
              interactionExpected: expectedState,
              initialBarSamples: checkLegendBarVisibility
                  ? rows(initial['bars'])
                  : null,
            );
            interactionAcceptance.add({
              'name': name,
              'state': state,
              if (checkLegendBarVisibility) 'canvasBarPixels': barPixelChecks,
            });
          }
          // No pump between taps: the per-Canvas click queue may complete after
          // the document has already received the outside gesture.
          final beforeRapid = obj(observation()['interaction']);
          final rapidBar = rows(observation()['bars']).first;
          final canvasOrigin = tester.getTopLeft(
            find.byType(NativeDocumentCanvas),
          );
          await tester.tapAt(
            canvasOrigin +
                Offset(
                  (rapidBar['x'] as num).toDouble(),
                  ((rapidBar['y'] as num) + (rapidBar['base'] as num)) / 2,
                ),
          );
          await tester.tapAt(Offset(width - 5, canvasOrigin.dy + 120));
          final priorClicks = rows(beforeRapid['chartClicks']).length;
          for (var frame = 0; frame < 120; frame++) {
            await tester.pump(const Duration(milliseconds: 50));
            final current = observation();
            if (current.containsKey('error')) {
              fail(
                'Rapid observer: ${current['error']}; ${document.scripts?.diagnostics}',
              );
            }
            final state = obj(current['interaction']);
            if (rows(state['chartClicks']).length == priorClicks + 1 &&
                (state['interactionSerial'] as int? ?? 0) >=
                    (beforeRapid['interactionSerial'] as int) + 2 &&
                obj(state['tooltip'])['opacity'] == 0) {
              break;
            }
          }
          final rapid = observation(), rapidState = obj(rapid['interaction']);
          debugPrintSynchronously(
            'PIRC_CHART_RAPID ${jsonEncode({'state': rapidState, 'diagnostics': document.scripts?.diagnostics})}',
          );
          expect(rapidState['chartActive'], isEmpty);
          expect(obj(rapidState['tooltip'])['opacity'], 0);
          expect(rows(rapidState['chartClicks']).length, priorClicks + 1);
          expect(document.scripts?.diagnostics, isEmpty);
          await verifyPaint(
            rapid,
            interactionExpected: obj(
              obj(interactionSteps['touchOutsideCanvas'])['state'],
            ),
          );
          interactionAcceptance.add({
            'name': 'rapidTouchOutsideCanvas',
            'state': rapidState,
          });

          await tester.tap(find.text('Update data', findRichText: true));
          await ready(updated: true);
          final updated = observation();
          compare(updated, obj(expectedCase['updated']), 'updated');
          await verifyPaint(updated);
          await tester.tap(find.text('Resize container', findRichText: true));
          await ready(updated: true, resized: true);
          final resized = observation();

          compare(
            resized,
            obj(obj(expectedCase['responsiveWidthChange'])['measurement']),
            'resized',
          );
          await verifyPaint(resized);
          expect(document.scripts?.diagnostics, isEmpty);
          expect(failures, isEmpty);
          expect(tester.takeException(), isNull);
          acceptance.add({
            'caseId': expectedCase['caseId'],
            'initial': initial,
            'updated': updated,
            'resized': resized,
            'geometryDeltas': deltas,
            'interactions': interactionAcceptance,
            'diagnostics': document.scripts?.diagnostics,
          });
        } finally {
          await tester.pumpWidget(const SizedBox.shrink());
          windows?.dispose();
          if (document?.scripts case final scripts?) await scripts.closed;
          tester.view.reset();
          await listener.cancel();
          await server.close(force: true);
        }
      }
      debugPrintSynchronously(
        'PIRC_NATIVE_CHART_ACCEPTANCE ${jsonEncode(acceptance)}',
      );
    },
    skip: _fixtureOrigin.isEmpty,
  );
  testWidgets(
    'native responsive chart sizing across all four authored modes',
    (tester) async {
      final fixture = obj(
        jsonDecode(await _fixture('/responsive-layout.json')),
      );
      final chartSource = await _fixture('/chart.js');
      final theme = await PircTheme.load();
      final acceptance = <Json>[];
      for (final expectedCase in rows(fixture['cases'])) {
        final viewport = obj(expectedCase['viewport']);
        final width = (viewport['width'] as num).toDouble(),
            height = (viewport['height'] as num).toDouble();
        final dpr = (expectedCase['dpr'] as num).toDouble();
        final failures = <String>[];
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        final origin = 'http://127.0.0.1:${server.port}';
        final token = 'pirc_dev_${List.filled(43, 'R').join()}';
        final listener = server.listen((request) async {
          try {
            await request.drain<void>();
            if (request.headers.value('authorization') != 'Bearer $token') {
              failures.add('Missing synthetic bearer');
            }
            if (request.uri.path == '/api/sessions') {
              request.response.headers.contentType = ContentType.json;
              request.response.write('{"sessions":[]}');
            } else if (request.uri.path == '/page') {
              request.response.headers.contentType = ContentType(
                'text',
                'html',
                charset: 'utf-8',
              );
              request.response.write(expectedCase['authoredHtml']);
            } else if (request.uri.path == '/chart.js' ||
                request.uri.path == '/chart-responsive-driver.js') {
              request.response.headers.contentType = ContentType(
                'text',
                'javascript',
                charset: 'utf-8',
              );
              request.response.write(
                request.uri.path == '/chart.js'
                    ? chartSource
                    : fixture['driverSource'],
              );
            } else {
              request.response.statusCode = 404;
              failures.add('Unexpected path ${request.uri.path}');
            }
            await request.response.close();
          } catch (error) {
            failures.add('$error');
          }
        });
        NativeDocumentWindows? windows;
        NativeFetchedDocument? document;
        try {
          await gateway.call('pair', {
            'link': Uri(
              scheme: 'pirc',
              host: 'pair',
              queryParameters: {'url': origin, 'token': token},
            ).toString(),
          });
          windows = NativeDocumentWindows(gateway);
          final window = windows.target('', null, sourceUrl: '$origin/page');
          expect(
            await window.load(
              NativeHtmlFormRequest(
                url: '$origin/page',
                method: 'GET',
                target: '',
              ),
              baseUrl: origin,
            ),
            NativeDocumentLoadResult.committed,
          );
          windows.select(window);
          document = window.currentDocument!;
          tester.view.devicePixelRatio = dpr;
          tester.view.physicalSize = Size(width * dpr, height * dpr);
          await tester.pumpWidget(
            MaterialApp(
              theme: theme.build(Brightness.light),
              home: Scaffold(
                body: NativeDocumentScope(
                  documentUrl: '$origin/page',
                  windows: windows,
                  window: window,
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
          Json observation() {
            final text = html
                .parse(document!.scripts?.content?.text ?? '')
                .getElementById('probe')
                ?.text;
            return text != null && text.startsWith('{')
                ? obj(jsonDecode(text))
                : {};
          }

          Future<Json> ready(String phase) async {
            for (var turn = 0; turn < 400; turn++) {
              await tester.pump(const Duration(milliseconds: 50));
              final probe = observation();
              if (probe['phase'] == phase) return probe;
            }
            fail(
              '${expectedCase['caseId']} report missing: ${document!.scripts?.diagnostics}',
            );
          }

          final initial = await ready('initial');
          final mode = expectedCase['mode'] as String;
          expect(
            obj(initial['constructor'])['succeeded'],
            isTrue,
            reason: '${expectedCase['caseId']}: $initial',
          );
          expect(obj(initial['constructor'])['error'], isNull);
          expect(initial['error'], isNull);
          expect(
            document.scripts?.diagnostics,
            isEmpty,
            reason: '${expectedCase['caseId']} initialization',
          );
          void compare(Json actual, Json expected) {
            expect(
              actual['chart'],
              containsPair('width', obj(expected['chart'])['width']),
            );
            for (final key in ['height', 'currentDevicePixelRatio']) {
              expect(obj(actual['chart'])[key], obj(expected['chart'])[key]);
            }
            final canvas = obj(actual['canvas']),
                referenceCanvas = obj(expected['canvas']);
            for (final key in [
              'backing',
              'computedStyle',
              'client',
              'offset',
            ]) {
              expect(
                canvas[key],
                referenceCanvas[key],
                reason: '${expectedCase['caseId']} $key',
              );
            }
            for (final key in ['x', 'y', 'width', 'height']) {
              expect(
                obj(canvas['rect'])[key],
                closeTo(
                  (obj(referenceCanvas['rect'])[key] as num).toDouble(),
                  .1,
                ),
              );
            }
            final bars = rows(actual['bars']),
                referenceBars = rows(expected['bars']);
            expect(bars, hasLength(referenceBars.length));
            for (var i = 0; i < bars.length; i++) {
              for (final key in ['x', 'y', 'base', 'width', 'height']) {
                expect(
                  bars[i][key],
                  closeTo((referenceBars[i][key] as num).toDouble(), .1),
                  reason: '${expectedCase['caseId']} bar $i $key',
                );
              }
            }
          }

          Future<void> paintBars(Json state) async {
            final widget = tester.widget<NativeDocumentCanvas>(
              find.byType(NativeDocumentCanvas),
            );
            final snapshot = widget.snapshot;
            final recorder = ui.PictureRecorder();
            NativeDocumentCanvasPainter(
              snapshot,
            ).paint(Canvas(recorder), Size(snapshot.width, snapshot.height));
            final picture = recorder.endRecording();
            final image = await tester.runAsync(
              () => picture.toImage(
                snapshot.width.toInt(),
                snapshot.height.toInt(),
              ),
            );
            try {
              final data = (await tester.runAsync(
                () => image!.toByteData(format: ui.ImageByteFormat.rawRgba),
              ))!;
              final bytes = data.buffer.asUint8List();
              for (final bar in rows(state['bars'])) {
                final x = ((bar['x'] as num) * dpr).floor(),
                    y = (((bar['y'] as num) + (bar['base'] as num)) / 2 * dpr)
                        .floor();
                final offset = (y * snapshot.width.toInt() + x) * 4;
                expect(bytes.sublist(offset, offset + 4), [59, 130, 246, 255]);
              }
            } finally {
              image?.dispose();
              picture.dispose();
            }
          }

          compare(
            obj(initial['state']),
            obj(obj(expectedCase['initialProbe'])['state']),
          );
          await paintBars(obj(initial['state']));
          debugPrintSynchronously(
            'PIRC_RESPONSIVE_CHART_INITIAL ${jsonEncode({'caseId': expectedCase['caseId'], 'report': initial, 'diagnostics': document.scripts?.diagnostics})}',
          );
          await tester.tap(find.text('Resize +20px', findRichText: true));
          await tester.pump();
          final resized = await ready('resized');
          expect(
            resized['error'],
            isNull,
            reason: '${expectedCase['caseId']}: $resized',
          );
          compare(
            obj(resized['state']),
            obj(obj(expectedCase['resizeProbe'])['state']),
          );
          await paintBars(obj(resized['state']));
          debugPrintSynchronously(
            'PIRC_RESPONSIVE_CHART_RESIZED ${jsonEncode({'caseId': expectedCase['caseId'], 'report': resized, 'diagnostics': document.scripts?.diagnostics})}',
          );
          final resizeDiagnostics = document.scripts?.diagnostics ?? <String>[];
          final earlyResize = obj(
            obj(resized['timing'])['afterTwoAnimationFrames'],
          );
          // These authored block/reset cases now require clean stock resize,
          // including the same-callback parent clientWidth read after writes.
          expect(resizeDiagnostics, isEmpty);
          expect(earlyResize['error'], isNull);
          final referenceEarly = obj(
            obj(
              obj(expectedCase['resizeProbe'])['timing'],
            )['afterTwoAnimationFrames'],
          );
          expect(referenceEarly['error'], isNull);
          compare(obj(earlyResize['state']), obj(referenceEarly['state']));
          acceptance.add({
            'caseId': expectedCase['caseId'],
            'mode': mode,
            'status': 'accepted',
            'initial': initial,
            'resized': resized,
            'diagnostics': document.scripts?.diagnostics,
          });
        } finally {
          await tester.pumpWidget(const SizedBox.shrink());
          windows?.dispose();
          if (document?.scripts != null) await document!.scripts!.closed;
          tester.view.reset();
          await listener.cancel();
          await server.close(force: true);
          expect(failures, isEmpty);
        }
      }
      expect(
        acceptance.where(
          (item) =>
              item['mode'] == 'percent_width_reset_styles' &&
              item['status'] == 'accepted',
        ),
        hasLength(4),
      );
      expect(
        acceptance.where((item) => item['status'] == 'accepted'),
        hasLength(16),
      );
      debugPrintSynchronously(
        'PIRC_RESPONSIVE_CHART_ACCEPTANCE ${jsonEncode(acceptance)}',
      );
    },
    skip: _fixtureOrigin.isEmpty,
  );
}
