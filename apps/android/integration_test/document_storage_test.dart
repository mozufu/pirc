import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:html/parser.dart' as html;
import 'package:integration_test/integration_test.dart';
import 'package:pirc_mobile/live/document_navigation_state.dart';
import 'package:pirc_mobile/live/document_scripts.dart';
import 'package:pirc_mobile/live/gateway.dart';
import 'package:pirc_render/src/html_form_submission.dart';

const page = r'''<p id="state"></p><p id="events">[]</p>
<button id="first">First</button><button id="second">Second</button><button id="read">Read</button>
<script>
window.received=[];
function report() { document.querySelector('#state').textContent=JSON.stringify({local:localStorage.getItem('shared'),session:sessionStorage.getItem('draft')}); }
onstorage=e=>{received.push({key:e.key,old:e.oldValue,value:e.newValue,local:e.storageArea===localStorage,url:e.url,trusted:e.isTrusted});document.querySelector('#events').textContent=JSON.stringify(received);report()};
document.querySelector('#first').onclick=()=>{localStorage.shared='one';sessionStorage.draft='draft-a';report()};
document.querySelector('#second').onclick=()=>{history.pushState({},'', '/pushed');localStorage.shared='two';sessionStorage.draft='draft-b';report()};
document.querySelector('#read').onclick=report;
report();
</script>''';

String text(NativeDocumentScripts scripts, String selector) =>
    html.parse(scripts.content?.text ?? '').querySelector(selector)?.text ?? '';
Json state(NativeDocumentScripts scripts) =>
    obj(jsonDecode(text(scripts, '#state')));
Future<void> click(NativeDocumentScripts scripts, String id) async {
  final element = html.parse(scripts.content!.text).querySelector('#$id')!;
  await scripts.click(element.attributes['data-pirc-script-id']!, const []);
}

Future<void> until(
  WidgetTester t,
  bool Function() ready,
  String description,
) async {
  for (var n = 0; n < 300 && !ready(); n++) {
    await t.pump(const Duration(milliseconds: 50));
  }
  expect(ready(), true, reason: description);
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'native Storage shares origins, isolates windows, survives reload and transfers full UTF16 areas',
    (t) async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final origin = 'http://127.0.0.1:${server.port}';
      final token = 'pirc_dev_${'S' * 43}';
      final listener = server.listen((request) async {
        if (request.uri.path == '/api/sessions') {
          expect(request.headers.value('authorization'), 'Bearer $token');
          request.response.headers.contentType = ContentType.json;
          request.response.write('{"sessions":[]}');
        } else {
          request.response.headers.contentType = ContentType.html;
          request.response.write(page);
        }
        await request.response.close();
      });
      final gateway = Gateway();
      final windows = NativeDocumentWindows(gateway);
      final detached = <NativeDocumentScripts>[];
      Future<NativeDocumentScripts> load(
        NativeDocumentWindow window,
        String path,
      ) async {
        final result = await window.load(
          NativeHtmlFormRequest(
            url: '$origin/$path',
            method: 'GET',
            target: '',
          ),
          baseUrl: origin,
        );
        expect(
          result,
          NativeDocumentLoadResult.committed,
          reason: window.error,
        );
        final doc = window.currentDocument!;
        final scripts = NativeDocumentScripts(gateway);
        doc.scripts = scripts;
        await windows.startDocumentScripts(doc, scripts);
        expect(scripts.ready, true, reason: scripts.diagnostics.join(';'));
        return scripts;
      }

      Future<NativeDocumentScripts> standalone(
        String source,
        String url, {
        String? key,
        String? creator,
      }) async {
        final scripts = NativeDocumentScripts(gateway);
        detached.add(scripts);
        await scripts.start(
          source: source,
          url: url,
          storageSessionKey: key,
          blobCreatorUrl: creator,
        );
        expect(scripts.ready, true, reason: scripts.diagnostics.join(';'));
        return scripts;
      }

      try {
        await t.pumpWidget(const SizedBox());
        await gateway.call('pair', {
          'link': Uri(
            scheme: 'pirc',
            host: 'pair',
            queryParameters: {'url': origin, 'token': token},
          ).toString(),
        });
        final boot = obj(await gateway.call('boot'));
        final stamp = boot['pairingStamp'];
        expect(boot['documentStorage'], true);
        final root = windows.target('', null, sourceUrl: '$origin/source');
        final first = await load(root, 'first');
        await click(first, 'first');
        expect(state(first), {'local': 'one', 'session': 'draft-a'});
        expect(jsonDecode(text(first, '#events')), isEmpty);
        final child = windows.target(
          'child',
          root,
          sourceUrl: root.current!.url,
        );
        final second = await load(child, 'child');
        expect(state(second), {'local': 'one', 'session': 'draft-a'});
        // A paused document keeps its native events, and reconciles on reattachment.
        second.setActivity(attached: false, visible: false);
        await click(first, 'second');
        second.setActivity(attached: true, visible: true);
        await until(
          t,
          () => state(second)['local'] == 'two',
          'cross-window storage event after resume',
        );
        expect(state(second), {'local': 'two', 'session': 'draft-a'});
        final events = jsonDecode(text(second, '#events')) as List;
        expect(events.length, 1);
        expect(events.single, {
          'key': 'shared',
          'old': 'one',
          'value': 'two',
          'local': true,
          'url': '$origin/pushed',
          'trusted': true,
        });
        expect(jsonDecode(text(first, '#events')), isEmpty);
        final blank = windows.target(
          '_blank',
          root,
          sourceUrl: root.current!.url,
        );
        final isolated = await load(blank, 'blank');
        expect(state(isolated), {'local': 'two', 'session': null});
        windows.close(blank);
        await isolated.closed;
        first.setActivity(attached: false, visible: false);
        final reloaded = await load(root, 'reload');
        expect(state(reloaded), {'local': 'two', 'session': 'draft-b'});
        // A blob URL inherits its creator's HTTP origin and the supplied window namespace.
        final blob = await standalone(
          page,
          'blob:$origin/storage-fixture',
          key: child.storageSessionKey,
          creator: '$origin/child',
        );
        expect(state(blob), {'local': 'two', 'session': 'draft-a'});
        blob.dispose();
        await blob.closed;
        windows.close(child);
        windows.close(root);
        await Future.wait([first.closed, second.closed, reloaded.closed]);
        // Native document transport still rejects data:/opaque top-level documents.
        // The runtime getters are tested separately; do not claim device coverage.
        const largeSource =
            r'''<p id="state"></p><p id="events">WAIT</p><button id="large">Large</button><script>
      function report(){const a=localStorage.getItem('large'),b=sessionStorage.getItem('copy');document.querySelector('#state').textContent=JSON.stringify({local:a&&a.length,session:b&&b.length,tail:a&&a.slice(-3),boundary:a&&[a.charCodeAt(131070),a.charCodeAt(131071),a.charCodeAt(131072)]})}
      onstorage=e=>{document.querySelector('#events').textContent=JSON.stringify({length:e.newValue&&e.newValue.length,tail:e.newValue&&e.newValue.slice(-3),local:e.storageArea===localStorage});report()};
      document.querySelector('#large').onclick=()=>{const value='漢😀'.repeat(1700000);localStorage.large=value;sessionStorage.copy=value;report()};report();
      </script>''';
        await gateway.call('documentStorageWindowOpen', {
          'sessionKey': 'large-window',
          'pairingStamp': stamp,
        });
        final observer = await standalone(
          largeSource,
          '$origin/observer',
          key: 'observer-window',
        );
        final writer = await standalone(
          largeSource,
          '$origin/large',
          key: 'large-window',
        );
        await click(writer, 'large');
        expect(writer.ready, true, reason: writer.diagnostics.join(';'));
        expect(state(writer), {
          'local': 5100000,
          'session': 5100000,
          'tail': '漢😀',
          'boundary': [0x6f22, 0xd83d, 0xde00],
        });
        await until(
          t,
          () => text(observer, '#events').startsWith('{'),
          'full-sized native storage event',
        );
        expect(jsonDecode(text(observer, '#events')), {
          'length': 5100000,
          'tail': '漢😀',
          'local': true,
        });
        observer.dispose();
        writer.dispose();
        await Future.wait([observer.closed, writer.closed]);
        final largeReload = await standalone(
          largeSource,
          '$origin/large-reload',
          key: 'large-window',
        );
        expect(state(largeReload)['session'], 5100000);
        expect(state(largeReload)['tail'], '漢😀');
        largeReload.dispose();
        await largeReload.closed;
        await gateway.call('documentStorageWindowClose', {
          'sessionKey': 'large-window',
          'pairingStamp': stamp,
        });
        final fresh = await standalone(
          largeSource,
          '$origin/fresh',
          key: 'fresh-window',
        );
        expect(state(fresh)['local'], 5100000);
        expect(state(fresh)['session'], isNull);
        fresh.dispose();
        await fresh.closed;
      } finally {
        windows.dispose();
        for (final scripts in detached) {
          scripts.dispose();
        }
        await Future.wait(detached.map((s) => s.closed));
        await gateway.call('unpair');
        await listener.cancel();
        await server.close(force: true);
      }
    },
    timeout: const Timeout(Duration(minutes: 8)),
  );
}
