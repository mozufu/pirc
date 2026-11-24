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

final oracle = obj(
  jsonDecode(
    "{\"browserVersion\":\"153.0.8010.12\",\"browserExecutable\":\"<repository>/.pirc/test-browsers/chromium_headless_shell-1243/chrome-headless-shell-mac-arm64/chrome-headless-shell\",\"cases\":[{\"name\":\"scope-prefix-and-global-fallback\",\"html\":\"<script type=\\\"importmap\\\">{\\\"imports\\\":{\\\"pkg/\\\":\\\"/pkg/\\\",\\\"shared\\\":\\\"/global.js\\\"},\\\"scopes\\\":{\\\"/scoped/\\\":{\\\"shared\\\":\\\"/scoped/shared.js\\\"}}}</script><script type=\\\"module\\\">import {value} from '/scoped/main.js';window.result=value;</script>\",\"resources\":{\"/scoped/main.js\":\"import {x} from 'pkg/item.js';import {v} from 'shared';export const value=[x,v];\",\"/pkg/item.js\":\"export const x=3;\",\"/scoped/shared.js\":\"export const v='scoped';\",\"/global.js\":\"export const v='global';\"},\"expected\":[3,\"scoped\"],\"requests\":[\"/page\",\"/scoped/main.js\",\"/pkg/item.js\",\"/scoped/shared.js\"],\"errors\":[]},{\"name\":\"resolve-exact-prefix-blocking-and-normalized-key\",\"html\":\"<script type=\\\"importmap\\\">{\\\"imports\\\":{\\\"x\\\":\\\"/x.js\\\",\\\"pkg/\\\":\\\"/v1/\\\",\\\"pkg/sub/\\\":\\\"/v2/\\\",\\\"blocked\\\":null,\\\"/foo/.\\\":\\\"/bad-address\\\"}}</script><script type=\\\"module\\\">window.result=[];for(const name of ['x','pkg/a.js','pkg/sub/a.js','blocked','pkg/../escape.js','/foo/file.js']){try{result.push(import.meta.resolve(name))}catch(e){result.push(e.name)}}</script>\",\"resources\":{},\"expected\":[\"\$ORIGIN/x.js\",\"\$ORIGIN/v1/a.js\",\"\$ORIGIN/v2/a.js\",\"TypeError\",\"TypeError\",\"TypeError\"],\"requests\":[\"/page\"],\"errors\":[]},{\"name\":\"later-map-keeps-resolved-prefix\",\"html\":\"<script type=\\\"importmap\\\">{\\\"imports\\\":{\\\"pkg/\\\":\\\"/v1/\\\"}}</script><script>var first=import('pkg/a.js');var map=document.createElement('script');map.type='importmap';map.textContent=\\\"{\\\\\\\"imports\\\\\\\":{\\\\\\\"pkg/a.js\\\\\\\":\\\\\\\"/v2/a.js\\\\\\\",\\\\\\\"new\\\\\\\":\\\\\\\"/new.js\\\\\\\"}}\\\";document.head.appendChild(map);;window.done=Promise.all([first,import('pkg/a.js'),import('new')]).then(values=>{window.result=values.map(value=>value.v)});</script>\",\"resources\":{\"/v1/a.js\":\"export const v='v1';\",\"/v2/a.js\":\"export const v='v2';\",\"/new.js\":\"export const v='new';\"},\"expected\":[\"v1\",\"v1\",\"new\"],\"requests\":[\"/page\",\"/v1/a.js\",\"/new.js\"],\"errors\":[]},{\"name\":\"failed-bare-import-can-be-mapped-later\",\"html\":\"<script>var first=import('missing').catch(e=>e.name);var map=document.createElement('script');map.type='importmap';map.textContent=\\\"{\\\\\\\"imports\\\\\\\":{\\\\\\\"missing\\\\\\\":\\\\\\\"/dep.js\\\\\\\"}}\\\";document.head.appendChild(map);;window.done=Promise.all([first,import('missing')]).then(([a,b])=>{window.result=[a,b.value]});</script>\",\"resources\":{\"/dep.js\":\"export const value=7;\"},\"expected\":[\"TypeError\",7],\"requests\":[\"/page\",\"/dep.js\"],\"errors\":[]},{\"name\":\"classic-inline-captures-base\",\"html\":\"<base href=\\\"/before/\\\"><script>function later(){return import('./dep.js')}document.querySelector('base').href='/after/';window.done=later().then(m=>{window.result=[m.value]});</script>\",\"resources\":{\"/before/dep.js\":\"export const value='before';\",\"/after/dep.js\":\"export const value='after';\"},\"expected\":[\"before\"],\"requests\":[\"/page\",\"/before/dep.js\"],\"errors\":[]},{\"name\":\"classic-external-redirect-base\",\"html\":\"<base href=\\\"/other/\\\"><script src=\\\"/redirect-classic.js\\\"></script>\",\"resources\":{\"/redirect-classic.js\":{\"redirect\":\"/real/classic.js\"},\"/real/classic.js\":\"function later(){return import('./dep.js')}window.done=Promise.resolve().then(later).then(m=>{window.result=[m.value]});\",\"/real/dep.js\":\"export const value='real';\",\"/other/dep.js\":\"export const value='other';\"},\"expected\":[\"real\"],\"requests\":[\"/page\",\"/redirect-classic.js\",\"/real/classic.js\",\"/real/dep.js\"],\"errors\":[]},{\"name\":\"classic-import-conversion-order\",\"html\":\"<script>window.trace=[];function options(){trace.push('options expression');return {get with(){trace.push('with getter');return {}}}};var imported=import({toString(){trace.push('specifier ToString');return '/dep.js'}},options());trace.push('after import');var errors=[];try{var p=import(missingSpecifier.value);errors.push('returned')}catch(e){errors.push('sync:'+e.name)};var symbols=[];var symbolPromise=import(Symbol('x'));symbols.push('returned');window.done=Promise.all([imported,symbolPromise.catch(e=>symbols.push(e.name))]).then(()=>{window.result=[trace,errors,symbols]});</script>\",\"resources\":{\"/dep.js\":\"export const value=7;\"},\"expected\":[[\"options expression\",\"specifier ToString\",\"with getter\",\"after import\"],[\"sync:ReferenceError\"],[\"returned\",\"TypeError\"]],\"requests\":[\"/page\",\"/dep.js\"],\"errors\":[]},{\"name\":\"module-import-conversion-order\",\"html\":\"<script type=\\\"module\\\">window.trace=[];function options(){trace.push('options expression');return {get with(){trace.push('with getter');return {}}}};var imported=import({toString(){trace.push('specifier ToString');return '/dep.js'}},options());trace.push('after import');var errors=[];try{var p=import(missingSpecifier.value);errors.push('returned')}catch(e){errors.push('sync:'+e.name)};var symbols=[];var symbolPromise=import(Symbol('x'));symbols.push('returned');window.done=Promise.all([imported,symbolPromise.catch(e=>symbols.push(e.name))]).then(()=>{window.result=[trace,errors,symbols]});</script>\",\"resources\":{\"/dep.js\":\"export const value=7;\"},\"expected\":[[\"options expression\",\"specifier ToString\",\"with getter\",\"after import\"],[\"sync:ReferenceError\"],[\"returned\",\"TypeError\"]],\"requests\":[\"/page\",\"/dep.js\"],\"errors\":[]},{\"name\":\"inline-handler-document-url-base\",\"html\":\"<base href=\\\"/before/\\\"><button id=\\\"run\\\" onclick=\\\"window.done=import('./dep.js').then(m=>{window.result=[m.value]})\\\">Run</button><script>document.querySelector('base').href='/after/';document.querySelector('#run').click();</script>\",\"resources\":{\"/dep.js\":\"export const value='document';\",\"/before/dep.js\":\"export const value='before';\",\"/after/dep.js\":\"export const value='after';\"},\"expected\":[\"document\"],\"requests\":[\"/page\",\"/dep.js\"],\"errors\":[]},{\"name\":\"inline-module-before-late-map\",\"html\":\"<script>window.initialError=false</script><script type=\\\"module\\\" onerror=\\\"window.initialError=true\\\">import value from 'late';window.first=value;</script><script type=\\\"importmap\\\">{\\\"imports\\\":{\\\"late\\\":\\\"/late.js\\\"}}</script><script type=\\\"module\\\">import value from 'late';window.result=[window.first??null,value];</script>\",\"resources\":{\"/late.js\":\"export default 9;\"},\"expected\":[null,9],\"requests\":[\"/page\",\"/late.js\"],\"errors\":[\"Failed to resolve module specifier \\\"late\\\". Relative references must start with either \\\"/\\\", \\\"./\\\", or \\\"../\\\".\"]},{\"name\":\"import-map-integrity-dynamic\",\"html\":\"<script type=\\\"importmap\\\">{\\\"imports\\\":{\\\"valid\\\":\\\"/valid.js\\\",\\\"bad\\\":\\\"/bad.js\\\"},\\\"integrity\\\":{\\\"/valid.js\\\":\\\"sha256-8WcPUuq8y7HxwcBHzO6IllqJSFS5cX1HCDVHW395ILE=\\\",\\\"/bad.js\\\":\\\"sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=\\\"}}</script><script>window.done=Promise.all([import('valid').then(m=>m.value),import('bad').catch(e=>e.name)]).then(values=>{window.result=values});</script>\",\"resources\":{\"/valid.js\":\"export const value=7;\",\"/bad.js\":\"export const value=7;\"},\"expected\":[7,\"TypeError\"],\"requests\":[\"/page\",\"/valid.js\",\"/bad.js\"],\"errors\":[]},{\"name\":\"import-map-integrity-module-src\",\"html\":\"<script type=\\\"importmap\\\">{\\\"integrity\\\":{\\\"/entry.js\\\":\\\"sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=\\\"}}</script><script type=\\\"module\\\" src=\\\"/entry.js\\\" onerror=\\\"window.result=['error']\\\"></script>\",\"resources\":{\"/entry.js\":\"window.result=['executed'];\"},\"expected\":[\"error\"],\"requests\":[\"/page\",\"/entry.js\",\"/entry.js\"],\"errors\":[]}]}",
  ),
);
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('real paired HTTP import maps and classic dynamic modules in Flutter', (
    tester,
  ) async {
    final gateway = Gateway();
    final theme = await PircTheme.load();
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final cross = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final origin = 'http://127.0.0.1:${server.port}',
        crossOrigin = 'http://127.0.0.1:${cross.port}';
    final token = 'pirc_dev_${List.filled(43, 'A').join()}';
    final failures = <String>[],
        receipts = <Json>[],
        crossReceipts = <Json>[],
        accepted = <Json>[];
    Json current = {};
    final crossListener = cross.listen((request) async {
      try {
        await request.drain<void>();
        crossReceipts.add({
          'path': request.uri.path,
          'origin': request.headers.value('origin'),
          'authorization': request.headers.value('authorization'),
          'referer': request.headers.value('referer'),
        });
        request.response.headers.contentType = ContentType(
          'text',
          'javascript',
          charset: 'utf-8',
        );
        if (request.uri.path != '/blocked.js') {
          request.response.headers.set('access-control-allow-origin', origin);
        }
        if (request.uri.path == '/entry.js') {
          request.response.headers.set('referrer-policy', 'no-referrer');
          request.response.write(
            "import {value} from './child.js';window.result=[value];",
          );
        } else if (request.uri.path == '/child.js') {
          request.response.write("export const value='cross';");
        } else {
          request.response.write("window.untrustedExecuted=true;");
        }
        await request.response.close();
      } catch (error) {
        failures.add('$error');
        try {
          await request.response.close();
        } catch (_) {}
      }
    });
    final listener = server.listen((request) async {
      try {
        await request.drain<void>();
        if (request.headers.value('authorization') != 'Bearer $token') {
          failures.add('Missing synthetic device bearer for ${request.uri}');
        }
        if (request.uri.path == '/api/sessions') {
          request.response.headers.contentType = ContentType.json;
          request.response.write('{"sessions":[]}');
        } else {
          receipts.add({
            'case': current['name'],
            'path': request.uri.path,
            'referer': request.headers.value('referer'),
          });
          request.response.headers.set('cache-control', 'no-store');
          if (request.uri.path == '/page') {
            request.response.headers.contentType = ContentType(
              'text',
              'html',
              charset: 'utf-8',
            );
            final html = (current['html'] as String).replaceAll(
              r'$CROSS',
              crossOrigin,
            );
            request.response.write(
              '''<!doctype html><html><body><pre id="probe">WAIT</pre>$html
        <script>var probeTimer=setInterval(function(){if(Array.isArray(window.result)){document.querySelector('#probe').textContent=JSON.stringify(window.result);clearInterval(probeTimer);}},1);</script>
        </body></html>''',
            );
          } else {
            final entry = obj(current['resources'])[request.uri.path];
            if (entry is Map) {
              request.response.statusCode = 302;
              request.response.headers.set(
                'location',
                obj(entry)['redirect'] as String,
              );
            } else if (entry is String) {
              request.response.headers.contentType = ContentType(
                'text',
                'javascript',
                charset: 'utf-8',
              );
              request.response.write(entry);
            } else {
              failures.add('Unexpected fixture path ${request.uri.path}');
              request.response.statusCode = 404;
            }
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
      final cases = [
        ...oracle['cases'] as List,
        {
          'name': 'native-cross-origin-graph',
          'html': '<script type="module" src="\$CROSS/entry.js"></script>',
          'resources': {},
          'expected': ['cross'],
        },
        {
          'name': 'native-cross-origin-rejected',
          'html':
              '<script type="module" src="\$CROSS/blocked.js" onerror="window.result=[\'blocked\']"></script>',
          'resources': {},
          'expected': ['blocked'],
        },
      ];
      for (final width in [390.0, 768.0]) {
        for (final brightness in Brightness.values) {
          tester.view.physicalSize = Size(width, 1000);
          for (final raw in cases) {
            current = obj(raw);
            final name = current['name'];
            final start = receipts.length, crossStart = crossReceipts.length;
            final windows = NativeDocumentWindows(gateway);
            final window = windows.target('', null, sourceUrl: '$origin/page');
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
              await tester.pumpWidget(
                MaterialApp(
                  theme: theme.build(brightness),
                  home: NativeDocumentWorkspace(windows: windows),
                ),
              );
              final expected = jsonEncode(
                current['expected'],
              ).replaceAll(r'$ORIGIN', origin);
              var ready = false;
              for (var turn = 0; turn < 400; turn++) {
                await tester.pump(const Duration(milliseconds: 20));
                if (find
                    .text(expected, findRichText: true)
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
                    '$name $width $brightness: ${document?.scripts?.diagnostics}; receipts=${receipts.skip(start).toList()}; cross=${crossReceipts.skip(crossStart).toList()}',
              );
              expect(tester.takeException(), isNull);
              expect(failures, isEmpty);
              if (name == 'classic-external-redirect-base') {
                expect(
                  receipts
                      .skip(start)
                      .firstWhere(
                        (r) => r['path'] == '/real/dep.js',
                      )['referer'],
                  '$origin/real/classic.js',
                );
              }
              if (name == 'native-cross-origin-graph') {
                final rows = crossReceipts.skip(crossStart).toList();
                expect(rows.length, 2);
                expect(rows.every((r) => r['authorization'] == null), isTrue);
                expect(rows.every((r) => r['origin'] == origin), isTrue);
                expect(
                  rows.firstWhere((r) => r['path'] == '/child.js')['referer'],
                  isNull,
                );
              }
              if (name == 'native-cross-origin-rejected') {
                expect(
                  crossReceipts.skip(crossStart).single['authorization'],
                  isNull,
                );
              }
              accepted.add({
                'name': name,
                'width': width,
                'brightness': brightness.name,
                'expected': current['expected'],
                'requests': receipts.skip(start).toList(),
                'crossRequests': crossReceipts.skip(crossStart).toList(),
              });
            } finally {
              await tester.pumpWidget(const SizedBox());
              windows.dispose();
              await document?.scripts?.closed;
            }
          }
        }
      }
      expect(accepted.length, 56);
      debugPrintSynchronously(
        'MODULE_HTTP_ACCEPTANCE:${jsonEncode({'matrix': accepted, 'failures': failures})}',
      );
    } finally {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
      await gateway.call('unpair');
      await listener.cancel();
      await crossListener.cancel();
      await server.close(force: true);
      await cross.close(force: true);
    }
  });
}
