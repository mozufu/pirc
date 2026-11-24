import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show PlatformException;
import 'package:flutter_test/flutter_test.dart';
import 'package:html/parser.dart' as html;
import 'package:integration_test/integration_test.dart';
import 'package:pirc_mobile/live/document_navigation.dart';
import 'package:pirc_mobile/live/document_navigation_state.dart';
import 'package:pirc_mobile/live/document_scripts.dart';
import 'package:pirc_mobile/live/gateway.dart';
import 'package:pirc_render/src/html_document_content.dart';
import 'package:pirc_render/src/html_buttons.dart';
import 'package:pirc_mobile/theme.dart';

// Holds real TCP connections before response headers. Client-side HTTP cancel
// must produce EOF; a successful JS abort alone cannot satisfy these assertions.
class HeldHttpServer {
  HeldHttpServer._(this.server) {
    subscription = server.listen((socket) {
      sockets.add(socket);
      final bytes = <int>[];
      String? path;
      socket.listen(
        (data) {
          if (path != null) return;
          bytes.addAll(data);
          final header = latin1.decode(bytes);
          if (!header.contains('\r\n\r\n')) return;
          path = Uri.parse(header.split(' ')[1]).path;
          requests.add(path!);
          if (path!.startsWith('/fast')) {
            socket.write(
              'HTTP/1.1 200 OK\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: 5\r\nConnection: close\r\n\r\nready',
            );
            unawaited(socket.flush().then((_) => socket.close()));
          }
        },
        onDone: () {
          if (path?.startsWith('/slow') ?? false) closed.add(path!);
          sockets.remove(socket);
          socket.destroy();
        },
        onError: (Object error) {
          errors.add('$error');
          sockets.remove(socket);
          socket.destroy();
        },
      );
    });
  }
  static Future<HeldHttpServer> start() async => HeldHttpServer._(
    await ServerSocket.bind(InternetAddress.loopbackIPv4, 0),
  );
  final ServerSocket server;
  late final StreamSubscription<Socket> subscription;
  final sockets = <Socket>{};
  final requests = <String>[];
  final closed = <String>[];
  final errors = <String>[];
  String get origin => 'http://127.0.0.1:${server.port}';
  Future<void> dispose() async {
    for (final socket in sockets.toList()) {
      socket.destroy();
    }
    await subscription.cancel();
    await server.close();
  }
}

class RecordingGateway extends Gateway {
  final opened = <Json>[];
  @override
  Future<dynamic> call(String method, [Json args = const {}]) async {
    final result = await super.call(method, args);
    if (method == 'documentScriptOpen') {
      opened.add({...args, 'id': obj(result)['id']});
    }
    return result;
  }
}

Future<void> until(
  WidgetTester t,
  bool Function() condition,
  String reason,
) async {
  for (var i = 0; i < 300 && !condition(); i++) {
    await t.pump(const Duration(milliseconds: 10));
  }
  expect(condition(), true, reason: reason);
}

NativeFetchedDocument document(HeldHttpServer server, String source) {
  final bytes = Uint8List.fromList(utf8.encode(source));
  return NativeFetchedDocument(
    id: 1,
    url: '${server.origin}/fixture',
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
}

String resultOf(NativeFetchedDocument doc) =>
    html
        .parse(doc.scripts?.content?.text ?? '')
        .querySelector('#result')
        ?.text ??
    '';
Future<void> mount(
  WidgetTester t,
  NativeFetchedDocument doc,
  Gateway gateway,
) async {
  final theme = await PircTheme.load();
  await t.pumpWidget(
    MaterialApp(
      theme: theme.build(Brightness.light),
      home: Scaffold(
        body: NativeFetchedDocumentView(
          document: doc,
          gateway: gateway,
          onLink: (_) {},
          onSubmit: (_) {},
        ),
      ),
    ),
  );
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'fetch abort closes six native sockets and immediately frees the seventh slot',
    (t) async {
      final server = await HeldHttpServer.start();
      final gateway = RecordingGateway();
      final doc = document(server, '''<!doctype html><body>
<button id="cancel">取消全部</button><pre id="result">pending</pre><script>
const controllers = Array.from({length:6},()=>new AbortController());
let aborts=0, wrong=0;
for (let i=0;i<6;i++) fetch('/slow-fetch-'+i,{signal:controllers[i].signal})
 .then(()=>wrong++,e=>{if(e.name==='AbortError')aborts++;else wrong++;});
document.querySelector('#cancel').onclick=()=>{
 for(const controller of controllers)controller.abort();
 fetch('/fast-fetch').then(r=>r.text()).then(value=>{
  document.querySelector('#result').textContent=JSON.stringify({value,aborts,wrong});
 });
};
</script></body>''');
      try {
        await mount(t, doc, gateway);
        await until(
          t,
          () => server.requests.where((p) => p.startsWith('/slow')).length == 6,
          'six real HTTP requests must reach the server before cancel',
        );
        final button = find.byWidgetPredicate(
          (widget) =>
              widget is NativeHtmlButtonWidget && widget.button.label == '取消全部',
        );
        await until(
          t,
          () => button.evaluate().isNotEmpty,
          'native button must finish rendering',
        );
        await t.tap(button);
        await until(
          t,
          () => resultOf(doc).contains('ready') && server.closed.length == 6,
          'native cancel must close all sockets and let request seven finish without a 30s wait',
        );
        expect(jsonDecode(resultOf(doc)), {
          'value': 'ready',
          'aborts': 6,
          'wrong': 0,
        });
        expect(server.requests.where((p) => p == '/fast-fetch'), hasLength(1));
        expect(doc.scripts!.diagnostics, isEmpty);
        expect(t.takeException(), isNull);
        debugPrint(
          'NATIVE_HTTP_CANCEL fetch PASS requests=${server.requests} closed=${server.closed}',
        );
      } finally {
        await t.pumpWidget(const SizedBox());
        doc.dispose();
        await doc.scripts?.closed;
        await server.dispose();
      }
    },
  );

  testWidgets(
    'XHR abort timeout and reopen cancel native work before new requests',
    (t) async {
      final server = await HeldHttpServer.start();
      final doc = document(server, '''<!doctype html><body>
<button id="cancel">更新資料</button><pre id="result">pending</pre><script>
const requests=[];let aborted=0,timedout=0,reopened='',fast='';
function render(){if(reopened==='ready'&&fast==='ready')document.querySelector('#result').textContent=JSON.stringify({aborted,timedout,reopened,fast});}
for(let i=0;i<6;i++){
 const xhr=new XMLHttpRequest();xhr.open('GET','/slow-xhr-'+i);
 xhr.onabort=()=>aborted++;
 xhr.ontimeout=()=>{timedout++;fetch('/fast-timeout').then(r=>r.text()).then(v=>{fast=v;render();});};
 xhr.send();requests.push(xhr);
}
document.querySelector('#cancel').onclick=()=>{
 requests[0].open('GET','/fast-reopen');requests[0].onload=()=>{reopened=requests[0].responseText;render();};requests[0].send();
 requests[1].timeout=250;
 for(let i=2;i<6;i++)requests[i].abort();
};
</script></body>''');
      try {
        await mount(t, doc, RecordingGateway());
        await until(
          t,
          () => server.requests.where((p) => p.startsWith('/slow')).length == 6,
          'six XHR sockets must be active before abort/reopen/timeout',
        );
        final button = find.byWidgetPredicate(
          (widget) =>
              widget is NativeHtmlButtonWidget && widget.button.label == '更新資料',
        );
        await until(
          t,
          () => button.evaluate().isNotEmpty,
          'native button must finish rendering',
        );
        await t.tap(button);
        await until(
          t,
          () => resultOf(doc).contains('ready') && server.closed.length == 6,
          'XHR abort, reopen and timeout must each release its native connection',
        );
        expect(jsonDecode(resultOf(doc)), {
          'aborted': 4,
          'timedout': 1,
          'reopened': 'ready',
          'fast': 'ready',
        });
        expect(doc.scripts!.diagnostics, isEmpty);
        expect(t.takeException(), isNull);
        debugPrint(
          'NATIVE_HTTP_CANCEL xhr PASS requests=${server.requests} closed=${server.closed}',
        );
      } finally {
        await t.pumpWidget(const SizedBox());
        doc.dispose();
        await doc.scripts?.closed;
        await server.dispose();
      }
    },
  );

  testWidgets(
    'owner and context checks isolate cancellation; close and unpair terminate owned sockets',
    (t) async {
      final server = await HeldHttpServer.start();
      final gateway = RecordingGateway();
      final first = NativeDocumentScripts(gateway),
          second = NativeDocumentScripts(gateway);
      const sourceA =
          '<body><script>fetch("/slow-owner-a").catch(()=>{});</script></body>';
      const sourceB =
          '<body><script>fetch("/slow-owner-b").catch(()=>{});</script></body>';
      try {
        await first.start(source: sourceA, url: '${server.origin}/a');
        await second.start(source: sourceB, url: '${server.origin}/b');
        await until(
          t,
          () => server.requests.length == 2,
          'both document requests must be active',
        );
        final a = gateway.opened[0], b = gateway.opened[1];
        await expectLater(
          gateway.call('documentScriptResourceCancel', {
            'id': a['id'],
            'owner': b['owner'],
            'requestId': 'fetch-1',
          }),
          throwsA(isA<PlatformException>()),
        );
        await expectLater(
          gateway.call('documentScriptResourceCancel', {
            'id': a['id'],
            'owner': a['owner'],
            'contextId': 'wrong-context',
            'requestId': 'fetch-1',
          }),
          throwsA(isA<PlatformException>()),
        );
        expect(server.closed, isEmpty);
        first.dispose();
        await first.closed;
        await until(
          t,
          () => server.closed.contains('/slow-owner-a'),
          'document close must terminate its HTTP',
        );
        expect(server.closed, ['/slow-owner-a']);
        expect(second.ready, true);
        // A late cleanup call is idempotent, and cannot touch the other document.
        await gateway.call('documentScriptResourceCancel', {
          'id': a['id'],
          'owner': a['owner'],
          'requestId': 'fetch-1',
        });
        expect(server.closed, ['/slow-owner-a']);
        await gateway.call('unpair');
        await until(
          t,
          () => server.closed.contains('/slow-owner-b'),
          'account teardown must terminate all remaining HTTP',
        );
        expect(t.takeException(), isNull);
        debugPrint(
          'NATIVE_HTTP_CANCEL ownership-close-unpair PASS closed=${server.closed}',
        );
      } finally {
        first.dispose();
        second.dispose();
        await Future.wait([first.closed, second.closed]);
        await server.dispose();
      }
    },
  );
}
