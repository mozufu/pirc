import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart' show debugPrintSynchronously;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:pirc_mobile/live/gateway.dart';
import 'package:pirc_mobile/live/document_navigation.dart';
import 'package:pirc_mobile/live/document_navigation_state.dart';
import 'package:pirc_render/src/html_form_submission.dart';
import 'package:pirc_mobile/theme.dart';

final classicOracle = obj(
  jsonDecode(
    "{\"browserVersion\":\"153.0.8010.12\",\"browserExecutable\":\"<repository>/.pirc/test-browsers/chromium_headless_shell-1243/chrome-headless-shell-mac-arm64/chrome-headless-shell\",\"cases\":[{\"name\":\"async-inline-module-does-not-interrupt-parser-classics\",\"html\":\"<script >window.trace=[];document.addEventListener('DOMContentLoaded',()=>trace.push('dcl'));window.addEventListener('load',()=>{window.result=trace})</script><script type=\\\"module\\\" async>trace.push('module',typeof parserValue,document.currentScript===null)</script><script >let parserValue=2;trace.push('classic')</script>\",\"resources\":{},\"expected\":[\"classic\",\"dcl\",\"module\",\"number\",true],\"requests\":[\"/page\"],\"errors\":[]},{\"name\":\"lexical-class-mutation-and-window-properties\",\"html\":\"<script >let sharedCount=9;const sharedObject={n:4};class SharedThing{value(){return sharedCount}};var globalNumber=6;function globalReader(){return sharedObject.n}</script><script >sharedCount++;sharedObject.n=5;window.result=[sharedCount,sharedObject.n,new SharedThing().value(),SharedThing.name,window.globalNumber,window.globalReader(),typeof window.sharedCount,typeof window.sharedObject,typeof window.SharedThing]</script>\",\"resources\":{},\"expected\":[10,5,10,\"SharedThing\",6,5,\"undefined\",\"undefined\",\"undefined\"],\"requests\":[\"/page\"],\"errors\":[]},{\"name\":\"strict-var-and-function-retain-global-scope\",\"html\":\"<script >\\\"use strict\\\";var strictNumber=17;function strictReader(){return strictNumber};</script><script >window.result=[strictNumber,strictReader(),window.strictNumber,window.strictReader()]</script>\",\"resources\":{},\"expected\":[17,17,17,17],\"requests\":[\"/page\"],\"errors\":[]},{\"name\":\"redeclaration-error-does-not-stop-later-scripts\",\"html\":\"<script >let stableValue=11;window.trace=['first']</script><script >let stableValue=12;trace.push('unreachable')</script><script >trace.push(stableValue);window.result=trace</script>\",\"resources\":{},\"expected\":[\"first\",11],\"requests\":[\"/page\"],\"errors\":[\"Identifier 'stableValue' has already been declared\"]},{\"name\":\"partial-runtime-failure-retains-initialized-and-tdz-bindings\",\"html\":\"<script >window.trace=[];let beforeFailure=3;let uninitialized=uninitialized;trace.push('unreachable')</script><script >trace.push(beforeFailure);try{trace.push(uninitialized)}catch(e){trace.push(e.name)};window.result=trace</script>\",\"resources\":{},\"expected\":[3,\"ReferenceError\"],\"requests\":[\"/page\"],\"errors\":[\"Cannot access 'uninitialized' before initialization\"]},{\"name\":\"syntax-failure-has-no-partial-execution\",\"html\":\"<script >window.trace=[]</script><script >trace.push('unreachable');let duplicate;let duplicate;</script><script >trace.push(typeof duplicate);window.result=trace</script>\",\"resources\":{},\"expected\":[\"undefined\"],\"requests\":[\"/page\"],\"errors\":[\"Identifier 'duplicate' has already been declared\"]},{\"name\":\"external-and-deferred-shared-bindings-and-events\",\"html\":\"<script >window.trace=[];document.addEventListener('DOMContentLoaded',()=>{trace.push('dcl');window.result=trace})</script><script id=\\\"external\\\" src=\\\"/classic.js\\\" onload=\\\"trace.push('external-load')\\\"></script><script >trace.push(externalValue);externalValue++</script><script defer src=\\\"/deferred.js\\\" onload=\\\"trace.push('defer-load')\\\"></script>\",\"resources\":{\"/classic.js\":\"let externalValue=20;trace.push(document.currentScript.id)\",\"/deferred.js\":\"trace.push(externalValue);externalValue++\"},\"expected\":[\"external\",\"external-load\",20,21,\"defer-load\",\"dcl\"],\"requests\":[\"/page\",\"/classic.js\",\"/deferred.js\"],\"errors\":[]},{\"name\":\"classic-globals-visible-in-module-and-handler\",\"html\":\"<button id=\\\"run\\\" onclick=\\\"sharedValue++;window.handlerValue=sharedValue\\\">Run</button><script >let sharedValue=30;const fixedValue=2;class SharedClass{};</script><script >document.querySelector('#run').click()</script><script type=\\\"module\\\">window.result=[sharedValue,fixedValue,SharedClass.name,window.handlerValue,document.currentScript===null]</script>\",\"resources\":{},\"expected\":[31,2,\"SharedClass\",31,true],\"requests\":[\"/page\"],\"errors\":[]},{\"name\":\"successful-script-microtasks-run-before-next-script\",\"html\":\"<script id=\\\"first\\\">let microtaskValue=1;window.trace=[document.currentScript.id];Promise.resolve().then(()=>{microtaskValue=2;trace.push(document.currentScript===null)})</script><script >trace.push(microtaskValue);window.result=trace</script>\",\"resources\":{},\"expected\":[\"first\",false,2],\"requests\":[\"/page\"],\"errors\":[]},{\"name\":\"error-script-microtask-current-script\",\"html\":\"<script >window.trace=[];Promise.resolve().then(()=>trace.push(document.currentScript===null));throw new Error('ordinary synthetic failure')</script><script >trace.push('continued');window.result=trace</script>\",\"resources\":{},\"expected\":[false,\"continued\"],\"requests\":[\"/page\"],\"errors\":[\"ordinary synthetic failure\"]},{\"name\":\"nested-inline-synchronous-effects-and-current-script\",\"html\":\"<script id=\\\"outer\\\">window.trace=[document.currentScript.id];var nested=document.createElement('script');nested.id='nested';nested.textContent=\\\"var nestedNumber=4;trace.push(document.currentScript.id)\\\";document.head.appendChild(nested);trace.push(nestedNumber,document.currentScript.id)</script><script >window.result=trace</script>\",\"resources\":{},\"expected\":[\"outer\",\"nested\",4,\"outer\"],\"requests\":[\"/page\"],\"errors\":[]},{\"name\":\"nested-inline-global-lexical-scope\",\"knownDifference\":\"Synchronous DOM-inserted inline scripts use eval because AndroidX has no reentrant native Script evaluation callback.\",\"html\":\"<script >var nested=document.createElement('script');nested.textContent='let nestedLexical=5';document.head.appendChild(nested)</script><script >window.result=[typeof nestedLexical]</script>\",\"resources\":{},\"expected\":[\"number\"],\"requests\":[\"/page\"],\"errors\":[]},{\"name\":\"promise-valued-script-completion-does-not-block-parser\",\"html\":\"<script >window.trace=['first'];new Promise(()=>{})</script><script >trace.push('second');window.result=trace</script>\",\"resources\":{},\"expected\":[\"first\",\"second\"],\"requests\":[\"/page\"],\"errors\":[]}]}",
  ),
);
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'persistent native classic Script globals over paired HTTP in Flutter',
    (tester) async {
      final gateway = Gateway();
      final theme = await PircTheme.load();
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final origin = 'http://127.0.0.1:${server.port}';
      final token = 'pirc_dev_${List.filled(43, 'A').join()}';
      Json current = {};
      final failures = <String>[], receipts = <Json>[], accepted = <Json>[];
      final listener = server.listen((request) async {
        try {
          await request.drain<void>();
          if (request.headers.value('authorization') != 'Bearer $token') {
            failures.add('Missing synthetic bearer: ${request.uri}');
          }
          if (request.uri.path == '/api/sessions') {
            request.response.headers.contentType = ContentType.json;
            request.response.write('{"sessions":[]}');
          } else {
            receipts.add({'case': current['name'], 'path': request.uri.path});
            request.response.headers.set('cache-control', 'no-store');
            if (request.uri.path == '/page') {
              request.response.headers.contentType = ContentType(
                'text',
                'html',
                charset: 'utf-8',
              );
              request.response.write(
                '''<!doctype html><html><body><pre id="probe">WAIT</pre>${current['html']}
       <script>var probeTimer=setInterval(function(){if(Array.isArray(window.result)){document.querySelector('#probe').textContent=JSON.stringify(window.result);clearInterval(probeTimer);}},1)</script>
       </body></html>''',
              );
            } else {
              final source = obj(current['resources'])[request.uri.path];
              if (source is! String) {
                failures.add('Unexpected path ${request.uri}');
                request.response.statusCode = 404;
              }
              request.response.headers.contentType = ContentType(
                'text',
                'javascript',
                charset: 'utf-8',
              );
              request.response.write(source ?? '');
            }
          }
          await request.response.close();
        } catch (error) {
          failures.add('$error');
          try {
            await request.response.close();
          } catch (_) {}
        }
      });
      try {
        await gateway.call('pair', {
          'link': Uri(
            scheme: 'pirc',
            host: 'pair',
            queryParameters: {'url': origin, 'token': token},
          ).toString(),
        });
        tester.view.devicePixelRatio = 1;
        for (final width in [390.0, 768.0]) {
          for (final brightness in Brightness.values) {
            tester.view.physicalSize = Size(width, 1000);
            for (final raw in classicOracle['cases'] as List) {
              current = obj(raw);
              final start = receipts.length;
              final windows = NativeDocumentWindows(gateway);
              final window = windows.target(
                '',
                null,
                sourceUrl: '$origin/page',
              );
              NativeFetchedDocument? document;
              try {
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
                document = window.currentDocument;
                final hidden =
                    width == 390.0 &&
                    brightness == Brightness.dark &&
                    current['name'] ==
                        'lexical-class-mutation-and-window-properties';
                await tester.pumpWidget(
                  TickerMode(
                    enabled: !hidden,
                    child: MaterialApp(
                      theme: theme.build(brightness),
                      home: NativeDocumentWorkspace(windows: windows),
                    ),
                  ),
                );
                if (hidden) {
                  expect(
                    TickerMode.valuesOf(
                      tester.element(find.byType(NativeFetchedDocumentView)),
                    ).enabled,
                    isFalse,
                  );
                }
                final knownDifference = current['knownDifference'] is String;
                final expected = knownDifference
                    ? ['undefined']
                    : current['expected'];
                var ready = false;
                for (var turn = 0; turn < 400; turn++) {
                  await tester.pump(const Duration(milliseconds: 20));
                  if (find
                      .text(jsonEncode(expected), findRichText: true)
                      .evaluate()
                      .isNotEmpty) {
                    ready = true;
                    break;
                  }
                }
                expect(
                  ready,
                  isTrue,
                  reason:
                      '${current['name']} $width $brightness: ${document?.scripts?.diagnostics}',
                );
                expect(tester.takeException(), isNull);
                expect(failures, isEmpty);
                final diagnostics = document?.scripts?.diagnostics ?? [];
                if (knownDifference) {
                  expect(
                    diagnostics.any(
                      (d) => d.contains('Synchronous DOM-inserted'),
                    ),
                    isTrue,
                  );
                }
                accepted.add({
                  'name': current['name'],
                  'width': width,
                  'brightness': brightness.name,
                  'visible': !hidden,
                  'browserExpected': current['expected'],
                  'nativeExpected': expected,
                  'knownDifference': current['knownDifference'],
                  'requests': receipts.skip(start).toList(),
                  'diagnostics': diagnostics,
                });
              } finally {
                await tester.pumpWidget(const SizedBox());
                windows.dispose();
                await document?.scripts?.closed;
              }
            }
          }
        }
        expect(accepted.length, 52);
        debugPrintSynchronously(
          'CLASSIC_HTTP_ACCEPTANCE:${jsonEncode({'matrix': accepted, 'failures': failures})}',
        );
      } finally {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
        await gateway.call('unpair');
        await listener.cancel();
        await server.close(force: true);
      }
    },
  );
}
