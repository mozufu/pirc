import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_mobile/live/document_navigation.dart';
import 'package:pirc_mobile/live/document_navigation_state.dart';
import 'package:pirc_mobile/live/document_scripts.dart';
import 'package:pirc_mobile/live/gateway.dart';
import 'package:pirc_render/src/html_file.dart';
import 'package:pirc_render/src/html_form_submission.dart';
import 'document_navigation_widget_test.dart' show DocumentGateway, response;
import 'live_test.dart' show theme;

// Controlled bridge responses test the real Dart host, native chooser adapter,
// renderer ownership and script leases. The independent Node gate exercises the
// production JS runtime and browser-derived event/file/FormData outcomes.
class PickerLifecycleGateway extends DocumentGateway {
  final pending = Completer<dynamic>();
  final completions = <Json>[];
  int picks = 0, opens = 0, nextAction = 0;
  String version = '0';
  @override
  Future<dynamic> call(String method, [Json args = const {}]) async {
    if (method == 'pickAttachments') {
      picks++;
      return pending.future;
    }
    if (method == 'documentScriptCapabilities') return {'supported': true};
    if (method == 'documentScriptOpen') {
      opens++;
      return {'id': opens};
    }
    if (method == 'documentScriptClose') return null;
    if (method != 'documentScriptEvaluate') return super.call(method, args);
    final source = args['source'] as String;
    if (source == 'runtime') return {'value': ''};
    final actions = <Json>[];
    if (source.startsWith('__pircDocument.dispatch(') &&
        source.contains('"type":"click"')) {
      actions.add({
        'id': ++nextAction,
        'kind': 'file',
        'controlId': 'pirc-1',
        'accept': '',
        'multiple': true,
        'resetVersion': version,
        'actionOrder': nextAction,
      });
    }
    if (source.startsWith('__pircDocument.filePickerResult(')) {
      completions.add(
        Map<String, dynamic>.from(
          jsonDecode(
                source.substring(
                  source.indexOf('(') + 1,
                  source.lastIndexOf(')'),
                ),
              )
              as Map,
        ),
      );
    }
    return {
      'value': jsonEncode({
        'html':
            '<html><body><input type="file" name="upload" multiple data-pirc-script-id="pirc-1" data-pirc-file-reset-version="$version"></body></html>',
        'layout': {'revision': 1, 'ids': [], 'required': false},
        'diagnostics': [],
        'resourceRequests': [],
        'resourceCancellations': [],
        'imageReferences': [],
        'canvases': [],
        'scheduler': {'timerDelayMs': null, 'animationFrame': false},
        'formActions': [],
        'navigationActions': [],
        'filePickerActions': actions,
        'defaultPrevented': false,
        'defaultHandled': true,
      }),
    };
  }
}

void main() {
  for (final scenario in [
    'remount',
    'hidden-completion',
    'same-frame',
    'close',
    'account',
    'replace',
    'reset',
    'error',
    'cancel',
    'switch-return',
  ]) {
    testWidgets('fetched script picker lifecycle $scenario', (t) async {
      final g = PickerLifecycleGateway()
        ..responses.add(
          response('/script', '<input type="file"><script>0</script>'),
        );
      final windows = NativeDocumentWindows(g),
          window = windows.target(
            'picker',
            null,
            sourceUrl: 'https://gateway.example/',
          );
      await window.load(
        const NativeHtmlFormRequest(url: '/script', method: 'GET', target: ''),
        baseUrl: window.sourceUrl,
      );
      windows.select(window);
      final document = window.currentDocument!,
          scripts = NativeDocumentScripts(
            g,
            loadRuntime: () async => 'runtime',
          );
      document.scripts = scripts;
      Widget page(int epoch) => MaterialApp(
        theme: theme.build(Brightness.light),
        home: NativeDocumentWorkspace(key: ValueKey(epoch), windows: windows),
      );
      try {
        await t.pumpWidget(page(0));
        await t.pumpAndSettle();
        for (var i = 0; i < 24 && !scripts.ready; i++) {
          await t.pump(const Duration(milliseconds: 20));
        }
        expect(
          scripts.ready,
          isTrue,
          reason:
              'loading=${scripts.loading} diagnostics=${scripts.diagnostics} opens=${g.opens}',
        );
        final control = find.byType(NativeHtmlFileInputWidget);
        await t.ensureVisible(control);
        await t.tap(control);
        await t.pumpAndSettle();
        expect(g.picks, 1);
        if (scenario == 'same-frame') {
          await t.pumpWidget(page(1));
          await t.pumpAndSettle();
        } else {
          await t.pumpWidget(const SizedBox.shrink());
          await t.pumpAndSettle();
        }
        if (scenario == 'remount' ||
            scenario == 'error' ||
            scenario == 'cancel' ||
            scenario == 'reset') {
          await t.pumpWidget(page(1));
          await t.pumpAndSettle();
        }
        if (scenario == 'close') windows.close(window);
        if (scenario == 'account') windows.invalidateNativeConnection();
        if (scenario == 'replace') {
          g.responses.add(response('/new', '<p>Replacement</p>'));
          await window.load(
            const NativeHtmlFormRequest(url: '/new', method: 'GET', target: ''),
            baseUrl: window.sourceUrl,
            replaceCurrent: true,
          );
        }
        if (scenario == 'switch-return') {
          final other = windows.target(
            'other',
            null,
            sourceUrl: window.sourceUrl,
          );
          windows.select(other);
          windows.select(window);
        }
        if (scenario == 'reset') {
          g.version = '1';
          await scripts.dispatch('pirc-1', 'reset', []);
          await t.pumpAndSettle();
        }
        if (scenario == 'error' || scenario == 'account') {
          g.pending.completeError(StateError('synthetic late picker failure'));
        } else if (scenario == 'cancel') {
          g.pending.complete(null);
        } else {
          g.pending.complete([
            {
              'name': 'picked-雪.txt',
              'mimeType': 'text/plain',
              'bytes': base64Encode([0, 127, 128, 255]),
            },
          ]);
        }
        await t.pumpAndSettle();
        if (['close', 'account', 'replace'].contains(scenario)) {
          expect(g.completions, isEmpty);
        } else if (scenario == 'switch-return') {
          expect(g.completions, hasLength(1));
          expect(g.completions.single['cancelled'], isTrue);
          expect(document.scriptFileSelections.get('pirc-1', '0'), isNull);
          await t.pumpWidget(page(2));
          await t.pumpAndSettle();
          // A discarded result must release its lease, allowing a future chooser.
          await scripts.dispatch('pirc-1', 'click', []);
          expect(
            scripts.takeFilePickerActions([
              scripts.filePickerActions.single['sequence'] as int,
            ]),
            hasLength(1),
          );
        } else {
          expect(g.completions, hasLength(1));
          if (scenario == 'hidden-completion') {
            await t.pumpWidget(page(1));
            await t.pumpAndSettle();
          }
          if (scenario == 'error') {
            expect(
              g.completions.single['error'],
              contains('synthetic late picker failure'),
            );
          } else if (scenario == 'cancel') {
            expect(g.completions.single['cancelled'], isTrue);
          } else {
            expect(
              (g.completions.single['files'] as List).single['name'],
              'picked-雪.txt',
            );
          }
          final upload = t.widget<NativeHtmlFileInputWidget>(
            find.byType(NativeHtmlFileInputWidget),
          );
          final files = upload.state.filesFor(upload.control.key);
          if (['error', 'cancel', 'reset'].contains(scenario)) {
            expect(files, isEmpty);
          } else {
            expect(files.single.name, 'picked-雪.txt');
            expect(files.single.bytes, [0, 127, 128, 255]);
          }
          expect(g.opens, 1);
        }
        expect(g.picks, 1);
        expect(t.takeException(), isNull);
      } finally {
        await t.pumpWidget(const SizedBox.shrink());
        windows.dispose();
        await scripts.closed;
      }
    });
  }
}
