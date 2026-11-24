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
import 'package:pirc_render/src/html_document_content.dart';
import 'package:pirc_render/src/html_file.dart';
import 'package:pirc_mobile/theme.dart';
import 'document_file_reader_fixture.dart';

class _PickedGateway extends Gateway {
  int picks = 0;
  @override
  Future<dynamic> call(String method, [Json args = const {}]) async {
    if (method == 'pickAttachments') {
      picks++;
      return [
        {
          'name': 'selected.bin',
          'mimeType': 'application/octet-stream',
          'bytes': Uint8List.fromList([0, 127, 128, 255, 13, 10]),
        },
      ];
    }
    return super.call(method, args);
  }
}

const _largeRead = r'''
<button id="large-read" type="button">Read 2 MiB</button><pre id="large-result">WAITING</pre>
<script>
document.querySelector('#large-read').onclick=async()=>{
 try {
  const bytes=new Uint8Array(2*1024*1024);for(let i=0;i<bytes.length;i++)bytes[i]=i%256;
  const file=new File([bytes],'large.bin',{type:'application/octet-stream'});
  const reader=new FileReader();
  const read=method=>new Promise((resolve,reject)=>{reader.onload=()=>resolve(reader.result);reader.onerror=()=>reject(reader.error);reader[method](file);});
  const buffer=await read('readAsArrayBuffer');const values=new Uint8Array(buffer);
  for(let i=0;i<values.length;i++)if(values[i]!==i%256)throw new Error('byte '+i);
  const url=await read('readAsDataURL');
  const base64=url.slice(url.indexOf(',')+1);
  document.querySelector('#large-result').textContent=JSON.stringify({bytes:values.length,exact:true,urlLength:url.length,prefix:base64.slice(0,16),tail:base64.slice(-8),readyState:reader.readyState,error:reader.error});
 }catch(error){document.querySelector('#large-result').textContent=JSON.stringify({error:String(error)});}
};
</script>
''';
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'native FileReader matches Chrome and reads selected files',
    (tester) async {
      final expected = jsonDecode(fileReaderExpectedJson) as Map;
      final theme = await PircTheme.load();
      final gateway = _PickedGateway();
      final windows = NativeDocumentWindows(gateway);
      final source = windows.target(
        '',
        null,
        sourceUrl: 'https://example.test/file-reader',
      );
      NativeFetchedDocument? document;
      Object? result(String selector) {
        final raw = document?.scripts?.content?.text;
        if (raw == null) return null;
        final text = html.parse(raw).querySelector(selector)?.text;
        if (text == null || text.isEmpty || text == 'WAITING') return null;
        try {
          return jsonDecode(text);
        } catch (_) {
          return null;
        }
      }

      Future<void> until(bool Function() condition, String label) async {
        for (var i = 0; i < 400 && !condition(); i++) {
          await tester.pump(const Duration(milliseconds: 50));
        }
        expect(
          condition(),
          isTrue,
          reason: '$label: ${document?.scripts?.diagnostics}',
        );
        expect(tester.takeException(), isNull);
      }

      Finder button(String label) => find.byWidgetPredicate(
        (w) => w is NativeHtmlButtonWidget && w.button.label == label,
      );
      Future<void> tap(Finder f) async {
        await tester.ensureVisible(f);
        await tester.pumpAndSettle();
        expect(f.hitTestable(), findsOneWidget);
        await tester.tap(f);
      }

      var serial = 0;
      try {
        for (final width in [390.0, 860.0]) {
          for (final brightness in Brightness.values) {
            for (final scale in [1.0, 2.0]) {
              if (document != null) {
                final old = document;
                await tester.pumpWidget(const SizedBox());
                source.history.clear();
                old.dispose();
                await old.scripts?.closed;
              }
              final bytes = Uint8List.fromList(
                utf8.encode(
                  fileReaderHtml.replaceFirst('</body>', '$_largeRead</body>'),
                ),
              );
              document = NativeFetchedDocument(
                id: ++serial,
                url: 'https://example.test/file-reader',
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
              source.history.add(
                NativeDocumentHistoryItem(document.url, document),
              );
              source.index = 0;
              windows.select(source);
              tester.view.devicePixelRatio = 1;
              tester.view.physicalSize = Size(width, 844);
              await tester.pumpWidget(
                MaterialApp(
                  theme: theme.build(brightness),
                  home: Builder(
                    builder: (context) => MediaQuery(
                      data: MediaQuery.of(
                        context,
                      ).copyWith(textScaler: TextScaler.linear(scale)),
                      child: Scaffold(
                        body: NativeDocumentScope(
                          windows: windows,
                          window: source,
                          documentUrl: document!.url,
                          child: NativeFetchedDocumentView(
                            key: ValueKey(serial),
                            document: document,
                            gateway: gateway,
                            onLink: (_) {},
                            onSubmit: (_) {},
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              );
              await until(
                () => document!.scripts?.ready == true,
                'Reader isolate ready',
              );
              await tap(button('Read programmatic files'));
              await until(
                () => result('#file-reader-result') != null,
                'Programmatic reader results',
              );
              expect(result('#file-reader-result'), expected['programmatic']);
              final picks = gateway.picks;
              await tap(find.byType(NativeHtmlFileInputWidget));
              await until(() => gateway.picks == picks + 1, 'Picker fixture');
              await tester.pumpAndSettle();
              final previousResult = jsonEncode(result('#file-reader-result'));
              await tap(button('Read selected file'));
              await until(
                () =>
                    jsonEncode(result('#file-reader-result')) !=
                        previousResult &&
                    result('#file-reader-result') != null,
                'Selected reader result',
              );
              expect(result('#file-reader-result'), expected['selected']);
              if (serial == 1) {
                await tap(button('Read 2 MiB'));
                await until(
                  () => result('#large-result') != null,
                  '2 MiB arrayBuffer and Data URL',
                );
                expect(result('#large-result'), {
                  'bytes': 2097152,
                  'exact': true,
                  'urlLength':
                      'data:application/octet-stream;base64,'.length +
                      ((2097152 + 2) ~/ 3) * 4,
                  'prefix': 'AAECAwQFBgcICQoL',
                  'tail': '+/z9/v8=',
                  'readyState': 2,
                  'error': null,
                });
                debugPrint('FILE_READER:2MiB-exact-bytes-and-dataURL');
              }
              debugPrint(
                'FILE_READER:chrome-match:$width:${brightness.name}:$scale',
              );
            }
          }
        }
      } finally {
        await tester.pumpWidget(const SizedBox());
        final closed = document?.scripts?.closed;
        windows.dispose();
        await closed;
        tester.view.reset();
      }
    },
    timeout: const Timeout(Duration(minutes: 6)),
  );
}
