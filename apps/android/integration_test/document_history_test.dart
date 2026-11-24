import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:html/parser.dart' as html;
import 'package:integration_test/integration_test.dart';
import 'package:pirc_mobile/live/document_navigation.dart';
import 'package:pirc_mobile/live/document_navigation_state.dart';
import 'package:pirc_mobile/live/gateway.dart';
import 'package:pirc_render/src/html_buttons.dart';
import 'package:pirc_render/src/html_document_urls.dart';
import 'package:pirc_render/src/html_form_submission.dart';
import 'package:pirc_mobile/theme.dart';

const _origin = 'https://example.test';
const _source = '''<!doctype html><html><body>
<input id="draft" value="initial"><p id="report">loading</p>
<button type="button" id="push">Push one</button>
<button type="button" id="replace">Replace two</button>
<button type="button" id="same">Push same URL</button>
<button type="button" id="back">Script back</button>
<button type="button" id="forward">Script forward</button>
<button type="button" id="reload">Script reload</button>
<button type="button" id="leave">Leave document</button>
<a href="#anchor">Go anchor</a><a href="/other">Other document</a>
<p id="anchor">Anchor target</p>
<script>
window.events=[];
function paint(){document.querySelector('#report').textContent=JSON.stringify({url:location.href,state:history.state,length:history.length,events:events,draft:document.querySelector('#draft').value});}
window.onpopstate=e=>{events.push({type:e.type,state:e.state,trusted:e.isTrusted,identity:e.state===history.state});paint();};
window.onhashchange=e=>{events.push({type:e.type,oldURL:e.oldURL,newURL:e.newURL,trusted:e.isTrusted});paint();};
document.querySelector('#push').onclick=()=>{const value={page:1,nested:{value:1}};history.pushState(value,'','?page=1');value.nested.value=99;paint();};
document.querySelector('#replace').onclick=()=>{history.replaceState({page:2},'','?page=2#two');paint();};
document.querySelector('#same').onclick=()=>{history.pushState({page:3},'',location.href);paint();};
document.querySelector('#back').onclick=()=>history.back();
document.querySelector('#forward').onclick=()=>history.forward();
document.querySelector('#reload').onclick=()=>history.go(0);
document.querySelector('#leave').onclick=()=>location.assign('/other');
paint();
</script></body></html>''';

class _Gateway extends Gateway {
  _Gateway(this.cache);
  final String cache;
  final requests = <Json>[];
  @override
  Future<dynamic> call(String method, [Json args = const {}]) async {
    switch (method) {
      case 'boot':
        return {'origin': _origin, 'pairingStamp': 'history-fixture'};
      case 'resolveDocumentUrl':
        return resolveNativeDocumentUrl(
          '${args['reference']}',
          '${args['baseUrl']}',
        );
      case 'document':
        requests.add(Map.of(args));
        return {
          'status': 200,
          'bytes': Uint8List.fromList(utf8.encode(_source)),
          'mimeType': 'text/html',
          'charset': 'utf-8',
          'finalUrl': args['url'],
          'finalMethod': 'GET',
          'headersRelevant': {
            'cache-control': cache,
            'content-type': 'text/html; charset=utf-8',
          },
        };
      default:
        return super.call(method, args);
    }
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  for (final cache in ['max-age=600', 'no-store']) {
    testWidgets(
      'native History API preserves controls and state across traversal ($cache)',
      (t) async {
        final gateway = _Gateway(cache);
        final windows = NativeDocumentWindows(gateway);
        final window = windows.target('', null, sourceUrl: '$_origin/start');
        final theme = await PircTheme.load();
        Future<void> until(bool Function() condition, String label) async {
          for (var i = 0; i < 400 && !condition(); i++) {
            await t.pump(const Duration(milliseconds: 25));
          }
          expect(
            condition(),
            isTrue,
            reason: '$label ${window.currentDocument?.scripts?.diagnostics}',
          );
          await t.pump();
          expect(t.takeException(), isNull, reason: label);
        }

        Json? report() {
          final source = window.currentDocument?.scripts?.content?.text;
          if (source == null) return null;
          final text = html.parse(source).querySelector('#report')?.text;
          try {
            return obj(jsonDecode(text ?? ''));
          } catch (_) {
            return null;
          }
        }

        Future<void> tap(String label) async {
          await until(
            () => window.currentDocument?.scripts?.ready == true,
            'ready for $label',
          );
          final finder = find.byWidgetPredicate(
            (w) => w is NativeHtmlButtonWidget && w.button.label == label,
          );
          await t.ensureVisible(finder);
          await t.tap(finder);
          await t.pump();
        }

        try {
          await window.load(
            const NativeHtmlFormRequest(
              url: '$_origin/start',
              method: 'GET',
              target: '',
            ),
            baseUrl: '$_origin/start',
          );
          windows.select(window);
          await t.pumpWidget(
            MaterialApp(
              theme: theme.build(Brightness.light),
              home: NativeDocumentWorkspace(windows: windows),
            ),
          );
          await until(() => report() != null, 'initial report');
          expect(report()!['length'], 2);
          expect(report()!['state'], isNull);
          final document = window.currentDocument;
          await t.enterText(find.byType(TextField), 'retained native draft');
          await tap('Push one');
          await until(
            () => window.current?.url == '$_origin/start?page=1',
            'push committed',
          );
          expect(window.currentDocument, same(document));
          expect(gateway.requests, hasLength(1));
          expect(obj(report()!['state'])['nested'], {'value': 1});
          expect(report()!['events'], isEmpty);
          expect(report()!['draft'], 'retained native draft');
          await tap('Replace two');
          await until(
            () => window.current?.url == '$_origin/start?page=2#two',
            'replace committed',
          );
          expect(window.history, hasLength(2));
          expect(report()!['events'], isEmpty);
          await tap('Push same URL');
          await until(
            () => window.history.length == 3,
            'same URL push committed',
          );
          await tap('Script back');
          await until(
            () => obj(report()?['state'])['page'] == 2,
            'same URL back',
          );
          expect(window.currentDocument, same(document));
          expect(report()!['length'], 4);
          final backEvents = report()!['events'] as List;
          expect(backEvents, hasLength(1));
          expect(obj(backEvents.single), {
            'type': 'popstate',
            'state': {'page': 2},
            'trusted': true,
            'identity': true,
          });
          await tap('Script forward');
          await until(
            () => obj(report()?['state'])['page'] == 3,
            'same URL forward',
          );
          expect(gateway.requests, hasLength(1));
          await t.tap(find.byTooltip('返回'));
          await t.pump();
          await until(
            () => obj(report()?['state'])['page'] == 2,
            'native UI back',
          );
          expect(report()!['draft'], 'retained native draft');
          await tap('Script back');
          await until(
            () => report()?['url'] == '$_origin/start',
            'back to initial entry',
          );
          expect(report()!['state'], isNull);
          final events = report()!['events'] as List;
          expect(obj(events[events.length - 2])['type'], 'popstate');
          expect(obj(events.last)['type'], 'hashchange');
          await tap('Script forward');
          await until(
            () => obj(report()?['state'])['page'] == 2,
            'forward to stored state',
          );
          // Reload must initialize state/length before page scripts and preserve the entry.
          final key = window.current!.entryKey;
          await tap('Script reload');
          await until(
            () => window.currentDocument != document && report() != null,
            'go(0) reload',
          );
          expect(window.current!.entryKey, key);
          expect(report()!['state'], {'page': 2});
          expect(report()!['length'], 4);
          expect(gateway.requests, hasLength(2));
          expect(report()!['events'], isEmpty);
          final beforeLeaving = window.currentDocument;
          await t.enterText(find.byType(TextField), 'cross-document draft');
          await tap('Leave document');
          await until(
            () => window.current?.url == '$_origin/other' && report() != null,
            'other document',
          );
          expect(report()!['state'], isNull);
          await t.tap(find.byTooltip('返回'));
          await t.pump();
          await until(
            () =>
                report()?['url'] == '$_origin/start?page=2#two' &&
                obj(report()?['state'])['page'] == 2,
            'cross document state restore',
          );
          expect(window.current!.entryKey, key);
          expect(
            t.widget<TextField>(find.byType(TextField)).controller!.text,
            'cross-document draft',
          );
          expect(
            identical(window.currentDocument, beforeLeaving),
            cache == 'max-age=600',
          );
          expect(gateway.requests, hasLength(cache == 'max-age=600' ? 3 : 4));
          debugPrint(
            'HISTORY_ACCEPTANCE:${jsonEncode({'cache': cache, 'requests': gateway.requests.length, 'entryKey': key, 'report': report()})}',
          );
        } finally {
          await t.pumpWidget(const SizedBox.shrink());
          windows.dispose();
          await t.pump(const Duration(milliseconds: 100));
        }
      },
    );
  }
}
