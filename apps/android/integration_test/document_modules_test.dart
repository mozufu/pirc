import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:pirc_mobile/live/gateway.dart';
import 'package:pirc_mobile/live/document_navigation.dart';
import 'package:pirc_mobile/live/document_navigation_state.dart';
import 'package:pirc_render/src/html_document_content.dart';
import 'package:pirc_render/src/html_buttons.dart';
import 'package:pirc_mobile/theme.dart';

// Exact synthetic module sources and observations from the dedicated browser oracle.
final oracle = obj(
  jsonDecode(
    "{\"browserVersion\":\"153.0.8010.12\",\"browserExecutable\":\"<repository>/.pirc/test-browsers/chromium_headless_shell-1243/chrome-headless-shell-mac-arm64/chrome-headless-shell\",\"cases\":[{\"name\":\"scope-and-shadowing\",\"source\":\"import {value} from './dep.js';window.result=[];try{for(let value of [value]){}}catch(e){result.push(e.name)};try{const C=class value extends value{}}catch(e){result.push(e.name)};try{const obj={arguments};result.push(obj.arguments)}catch(e){result.push(e.name)};try{this.missing}catch(e){result.push(e.name)};result.push(this?.missing,typeof arguments);\",\"modules\":{\"dep.js\":\"export const value=3;\"},\"url\":\"\$ORIGIN/0/page\",\"expected\":[\"ReferenceError\",\"ReferenceError\",\"ReferenceError\",\"TypeError\",null,\"undefined\"]},{\"name\":\"default-class-initialization\",\"source\":\"import D from './class.js';window.result=[D.name,D.observed];\",\"modules\":{\"class.js\":\"export default class {static observed=this.name;}\"},\"url\":\"\$ORIGIN/1/page\",\"expected\":[\"default\",\"default\"]},{\"name\":\"default-expression-tdz\",\"source\":\"import value from './a.js';window.result=[value];\",\"modules\":{\"a.js\":\"import {read} from './b.js';export default read();\",\"b.js\":\"import value from './a.js';export function read(){try{return typeof value}catch(e){return e.name}}\"},\"url\":\"\$ORIGIN/2/page\",\"expected\":[\"ReferenceError\"]},{\"name\":\"live-bindings-and-functions\",\"source\":\"import {count,inc} from './state.js';import * as ns from './state.js';window.result=[count];inc();result.push(count,ns.count,ns.inc===inc,Object.isExtensible(ns),Object.getPrototypeOf(ns));\",\"modules\":{\"state.js\":\"export let count=1;export function inc(){count++}\"},\"url\":\"\$ORIGIN/3/page\",\"expected\":[1,2,2,true,false,null]},{\"name\":\"function-cycle\",\"source\":\"import {a} from './a.js';window.result=[a()];\",\"modules\":{\"a.js\":\"import {b} from './b.js';export function a(){return 'a'+b()};\",\"b.js\":\"import {a} from './a.js';export function b(){return typeof a};\"},\"url\":\"\$ORIGIN/4/page\",\"expected\":[\"afunction\"]},{\"name\":\"dynamic-import-cache\",\"source\":\"const [a,b]=await Promise.all([import('./dep.js'),import('./dep.js')]);window.result=[a.value,a===b,window.depRuns];\",\"modules\":{\"dep.js\":\"window.depRuns=(window.depRuns||0)+1;export const value=7;\"},\"url\":\"\$ORIGIN/5/page\",\"expected\":[7,true,1]},{\"name\":\"inline-base-meta\",\"source\":\"window.result=[this,typeof arguments,document.currentScript,import.meta.url,import.meta.resolve('./asset.svg')];\",\"base\":\"/folder/\",\"modules\":{},\"url\":\"\$ORIGIN/6/page\",\"expected\":[null,\"undefined\",null,\"\$ORIGIN/folder/\",\"\$ORIGIN/folder/asset.svg\"]}]}",
  ),
);
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final gateway = Gateway();
  for (final raw in oracle['cases'] as List) {
    final item = obj(raw);
    testWidgets('Android module oracle: ${item['name']}', (tester) async {
      const origin = 'https://document.example';
      final url = (item['url'] as String).replaceAll(r'$ORIGIN', origin);
      final owner = 'module-oracle-${item['name']}';
      final id = obj(
        await gateway.call('documentScriptOpen', {
          'owner': owner,
          'documentUrl': url,
        }),
      )['id'];
      Future<String> evaluate(String source) async =>
          obj(
                await gateway.call('documentScriptEvaluate', {
                  'id': id,
                  'owner': owner,
                  'source': source,
                }),
              )['value']
              as String;
      Json decode(String value) => obj(jsonDecode(value));
      try {
        await evaluate(
          await rootBundle.loadString('assets/document-script-runtime.js'),
        );
        final html =
            '${item['base'] == null ? '' : '<base href="${item['base']}">'}<script type="module">${item['source']}</script>';
        var snapshot = decode(
          await evaluate(
            '__pircDocument.init(${jsonEncode({'url': url, 'html': html})})',
          ),
        );
        final requests = <dynamic>[...snapshot['resourceRequests'] as List];
        Json? observed;
        for (var turn = 0; turn < 80; turn++) {
          while (requests.isNotEmpty) {
            final request = obj(requests.removeAt(0));
            final name = Uri.parse(request['url'] as String).pathSegments.last;
            final source = obj(item['modules'])[name];
            expect(source, isA<String>(), reason: '$request');
            snapshot = decode(
              await evaluate(
                '__pircDocument.completeResource(${jsonEncode({'id': request['id'], 'ok': true, 'source': source, 'url': request['url']})})',
              ),
            );
            requests.addAll(snapshot['resourceRequests'] as List);
          }
          snapshot = decode(await evaluate('__pircDocument.snapshot()'));
          requests.addAll(snapshot['resourceRequests'] as List);
          final result = decode(
            await evaluate(
              'JSON.stringify({ready:Array.isArray(window.result),value:window.result})',
            ),
          );
          if (result['ready'] == true) {
            observed = result;
            break;
          }
          await tester.pump(const Duration(milliseconds: 16));
        }
        expect(observed, isNotNull, reason: '$snapshot');
        final normalized = jsonDecode(
          jsonEncode(observed!['value']).replaceAll(origin, r'$ORIGIN'),
        );
        expect(normalized, item['expected']);
        expect(
          (snapshot['diagnostics'] as List).where(
            (entry) => obj(entry)['severity'] == 'error',
          ),
          isEmpty,
        );
      } finally {
        await gateway.call('documentScriptClose', {'id': id, 'owner': owner});
      }
    });
  }
  testWidgets('module DOM updates and handlers paint and interact in Flutter', (
    tester,
  ) async {
    final theme = await PircTheme.load();
    final bytes = Uint8List.fromList(
      utf8.encode('''<div id="result">Waiting</div>
      <button type="button" id="add">Module add</button>
      <script type="module">let value=1;const result=document.querySelector('#result');
      result.textContent='Module count '+value;
      document.querySelector('#add').addEventListener('click',()=>{result.textContent='Module count '+(++value)});
      </script>'''),
    );
    final document = NativeFetchedDocument(
      id: 42,
      url: 'https://document.example/page',
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
    try {
      await tester.pumpWidget(
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
        ),
      );
      for (
        var turn = 0;
        turn < 100 &&
            document.scripts?.content?.text.contains('Module count 1') != true;
        turn++
      ) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      await tester.pumpAndSettle();
      expect(find.text('Module count 1', findRichText: true), findsOneWidget);
      await tester.tap(
        find.byWidgetPredicate(
          (widget) =>
              widget is NativeHtmlButtonWidget &&
              widget.button.label == 'Module add',
        ),
      );
      for (
        var turn = 0;
        turn < 100 &&
            !document.scripts!.content!.text.contains('Module count 2');
        turn++
      ) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      await tester.pumpAndSettle();
      expect(find.text('Module count 2', findRichText: true), findsOneWidget);
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox());
      document.dispose();
    }
  });
}
