import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:html/parser.dart' as html;
import 'package:integration_test/integration_test.dart';
import 'package:pirc_mobile/live/document_navigation.dart';
import 'package:pirc_mobile/live/document_navigation_state.dart';
import 'package:pirc_mobile/live/gateway.dart';
import 'package:pirc_render/src/html_document_content.dart';
import 'package:pirc_mobile/theme.dart';

const source =
    r'''<!doctype html><html><body><p id="status">Working</p><pre id="limits">WAITING</pre><script>
(async()=>{
 const size=2*1024*1024;
 function request(method,path,type,body){return new Promise((resolve,reject)=>{
  const x=new XMLHttpRequest();x.open(method,path);x.responseType=type;x.timeout=15000;
  x.onload=()=>resolve(x.response);x.onerror=()=>reject(new Error('network '+path));x.ontimeout=()=>reject(new Error('timeout '+path));x.send(body);body=null;
 });}
 let data=new Uint8Array(size);for(let i=0;i<size;i++)data[i]=(i*17+13)&255;
 const sent=request('POST','/max-upload','json',data);data=null;
 const upload=await sent;
 const buffer=await request('GET','/max-download','arraybuffer',null);
 const bytes=new Uint8Array(buffer);let sum=0,valid=bytes.length===size;
 for(let i=0;i<bytes.length;i++){sum+=bytes[i];if(bytes[i]!==((i*17+13)&255))valid=false;}
 document.querySelector('#limits').textContent=JSON.stringify({upload,download:{length:bytes.length,checksum:sum,valid}});
 document.querySelector('#status').textContent='XHR 2 MiB passed';
})().catch(e=>document.querySelector('#limits').textContent=JSON.stringify({error:String(e)}));
</script></body></html>''';
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'native XHR transfers exact 2 MiB each direction within unchanged isolate limits',
    (t) async {
      const size = 2 * 1024 * 1024;
      const checksum = 267386880;
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final paths = <String>[];
      final serving = server.listen((req) {
        unawaited(() async {
          paths.add(req.uri.path);
          if (req.uri.path == '/max-upload') {
            int length = 0, sum = 0;
            await for (final chunk in req) {
              length += chunk.length;
              for (final b in chunk) {
                sum += b;
              }
            }
            req.response.headers.contentType = ContentType.json;
            req.response.write(jsonEncode({'length': length, 'checksum': sum}));
          } else if (req.uri.path == '/max-download') {
            final data = Uint8List(size);
            for (var i = 0; i < size; i++) {
              data[i] = (i * 17 + 13) & 255;
            }
            req.response.headers.contentType = ContentType.binary;
            req.response.contentLength = size;
            req.response.add(data);
          } else {
            req.response.statusCode = 404;
          }
          await req.response.close();
        }());
      });
      final bytes = Uint8List.fromList(utf8.encode(source));
      final doc = NativeFetchedDocument(
        id: 1,
        url: 'http://127.0.0.1:${server.port}/fixture',
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
        final theme = await PircTheme.load();
        await t.pumpWidget(
          MaterialApp(
            theme: theme.build(Brightness.light),
            home: Scaffold(
              body: NativeFetchedDocumentView(
                document: doc,
                gateway: Gateway(),
                onLink: (_) {},
                onSubmit: (_) {},
              ),
            ),
          ),
        );
        Map<String, dynamic>? result;
        for (var i = 0; i < 1200; i++) {
          await t.pump(const Duration(milliseconds: 25));
          final text =
              html
                  .parse(doc.scripts?.content?.text ?? '')
                  .querySelector('#limits')
                  ?.text ??
              '';
          if (text.startsWith('{')) {
            result = Map<String, dynamic>.from(jsonDecode(text) as Map);
            break;
          }
        }
        expect(result, isNotNull, reason: '${doc.scripts?.diagnostics}');
        expect(result!['error'], isNull);
        expect(result['upload'], {'length': size, 'checksum': checksum});
        expect(result['download'], {
          'length': size,
          'checksum': checksum,
          'valid': true,
        });
        expect(doc.scripts!.diagnostics, isEmpty);
        expect(paths, ['/max-upload', '/max-download']);
        expect(t.takeException(), isNull);
        debugPrint('NATIVE_XHR_LIMITS ${jsonEncode(result)}');
      } finally {
        await t.pumpWidget(const SizedBox());
        doc.dispose();
        await t.pump();
        await serving.cancel();
        await server.close(force: true);
      }
    },
  );
}
