import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show debugPrintSynchronously;
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:pirc_mobile/live/document_navigation.dart';
import 'package:pirc_mobile/live/document_navigation_state.dart';
import 'package:pirc_mobile/live/gateway.dart';
import 'package:pirc_render/src/html_document_content.dart';
import 'package:pirc_mobile/theme.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'document visibility reaches native JS and freezes frames across window and app activity',
    (tester) async {
      final theme = await PircTheme.load(), g = Gateway();
      final accepted = <Json>[];
      for (final width in [390.0, 768.0]) {
        for (final dpr in [1.0, 3.0]) {
          for (final dark in [false, true]) {
            tester.view.devicePixelRatio = dpr;
            tester.view.physicalSize = Size(
              width * dpr,
              (width == 390 ? 844 : 1024) * dpr,
            );
            final bytes = utf8.encode(
              '''<!doctype html><html><body><pre id="probe">WAIT</pre><script>
    var frames=0,edges=[];
    function report(){document.getElementById('probe').textContent=JSON.stringify({hidden:document.hidden,state:document.visibilityState,frames:frames,edges:edges});}
    document.addEventListener('visibilitychange',function(e){edges.push({state:document.visibilityState,hidden:document.hidden,bubbles:e.bubbles,cancelable:e.cancelable,composed:e.composed,trusted:e.isTrusted,target:e.target===document});report();Promise.resolve().then(function(){edges.push({promise:document.visibilityState});report();});});
    function frame(){frames++;report();requestAnimationFrame(frame);}report();requestAnimationFrame(frame);
   </script></body></html>''',
            );
            final document = NativeFetchedDocument(
              id: 1,
              url: 'https://example.test/visibility',
              status: 200,
              bytes: bytes,
              mimeType: 'text/html',
              content: NativeHtmlDocumentContent.fromBytes(
                bytes,
                mimeType: 'text/html',
                charset: 'utf-8',
              ),
              headers: {},
            );
            final visible = ValueNotifier<bool>(true);
            try {
              await tester.pumpWidget(
                MaterialApp(
                  theme: theme.build(dark ? Brightness.dark : Brightness.light),
                  home: Scaffold(
                    body: ValueListenableBuilder<bool>(
                      valueListenable: visible,
                      builder: (_, value, _) => TickerMode(
                        enabled: value,
                        child: NativeFetchedDocumentView(
                          document: document,
                          gateway: g,
                          onLink: (_) {},
                          onSubmit: (_) {},
                        ),
                      ),
                    ),
                  ),
                ),
              );
              Json read() {
                final text = document.scripts?.content?.bodyInnerHtml ?? '';
                final match = RegExp(
                  r'<pre[^>]*>(.*?)</pre>',
                  dotAll: true,
                ).firstMatch(text);
                if (match == null || !match.group(1)!.startsWith('{')) {
                  return {};
                }
                return obj(
                  jsonDecode(
                    match
                        .group(1)!
                        .replaceAll('&quot;', '"')
                        .replaceAll('&amp;', '&'),
                  ),
                );
              }

              Future<Json> until(bool Function(Json) test) async {
                for (var i = 0; i < 100; i++) {
                  await tester.pump(const Duration(milliseconds: 30));
                  final value = read();
                  if (value.isNotEmpty && test(value)) return value;
                }
                fail(
                  'Visibility timeout ${document.scripts?.diagnostics} ${read()}',
                );
              }

              final initial = await until(
                (v) => v['hidden'] == false && (v['frames'] as num) > 1,
              );
              expect(initial['edges'], isEmpty);
              visible.value = false;
              final hidden = await until(
                (v) => v['hidden'] == true && (v['edges'] as List).length == 2,
              );
              await tester.pump(const Duration(milliseconds: 400));
              expect(read()['frames'], hidden['frames']);
              visible.value = true;
              final shown = await until(
                (v) =>
                    v['hidden'] == false &&
                    (v['edges'] as List).length == 4 &&
                    (v['frames'] as num) > (hidden['frames'] as num),
              );
              document.scripts!.didChangeAppLifecycleState(
                AppLifecycleState.paused,
              );
              final paused = await until(
                (v) => v['hidden'] == true && (v['edges'] as List).length == 6,
              );
              await tester.pump(const Duration(milliseconds: 400));
              expect(read()['frames'], paused['frames']);
              document.scripts!.didChangeAppLifecycleState(
                AppLifecycleState.resumed,
              );
              final resumed = await until(
                (v) =>
                    v['hidden'] == false &&
                    (v['edges'] as List).length == 8 &&
                    (v['frames'] as num) > (paused['frames'] as num),
              );
              final edges = resumed['edges'] as List;
              for (var i = 0; i < 4; i++) {
                final hidden = i.isEven, state = hidden ? 'hidden' : 'visible';
                expect(edges[i * 2], {
                  'state': state,
                  'hidden': hidden,
                  'bubbles': true,
                  'cancelable': false,
                  'composed': false,
                  'trusted': true,
                  'target': true,
                });
                expect(edges[i * 2 + 1], {'promise': state});
              }
              expect(document.scripts!.diagnostics, isEmpty);
              expect(tester.takeException(), isNull);
              accepted.add({
                'width': width,
                'dpr': dpr,
                'dark': dark,
                'initial': initial,
                'hidden': hidden,
                'shown': shown,
                'paused': paused,
                'resumed': resumed,
              });
              debugPrintSynchronously(
                'PIRC_VISIBILITY_PROGRESS ${accepted.length}/8',
              );
            } finally {
              await tester.pumpWidget(const SizedBox.shrink());
              document.dispose();
              if (document.scripts != null) await document.scripts!.closed;
              visible.dispose();
              tester.view.reset();
            }
          }
        }
      }
      expect(accepted, hasLength(8));
      debugPrintSynchronously(
        'PIRC_NATIVE_VISIBILITY_ACCEPTANCE ${jsonEncode(accepted)}',
      );
    },
  );
}
