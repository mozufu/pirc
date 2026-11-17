import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_mobile/live/common.dart';
import 'package:pirc_mobile/live/document_navigation.dart';
import 'package:pirc_mobile/live/document_navigation_state.dart';
import 'package:pirc_mobile/live/gateway.dart';

import 'document_navigation_widget_test.dart'
    show DocumentGateway, clickSubmit, response;
import 'live_test.dart' show theme;

/// Records every bridge call so a test can see which native engine methods a
/// document caused.
class _RecordingGateway extends DocumentGateway {
  final methods = <String>[];
  @override
  Future<dynamic> call(String method, [Json args = const {}]) {
    methods.add(method);
    return super.call(method, args);
  }
}

const _page =
    '<title>Landed</title><link rel="stylesheet" href="/site.css">'
    '<p id="shown">Visible body</p>'
    '<form action="/next"><input name="q" value="1"><button>Send</button></form>'
    '<script>fetch("/api/leak"); document.title = "ran";</script>';

Json _landed({required bool paired}) => {
  ...response('/landed', _page),
  // Computed by the native transport from the final response URL; the value
  // a Dart caller or the page supplies is never consulted.
  'pairedOrigin': ?(paired ? true : null),
};

Widget _host(_RecordingGateway gateway, NativeDocumentWindows windows) =>
    MaterialApp(
      theme: theme.build(Brightness.light),
      home: NativeDocumentScope(
        windows: windows,
        documentUrl: 'https://gateway.example/?session=s',
        sourceIdentity: windows.accountIdentity,
        child: NativeDocumentHost(
          windows: windows,
          child: Scaffold(
            body: SingleChildScrollView(
              child: RichTextBody(
                '<form action="/landed"><button>Open</button></form>',
                gateway: gateway,
              ),
            ),
          ),
        ),
      ),
    );

Future<(_RecordingGateway, NativeDocumentWindows)> _land(
  WidgetTester t, {
  required bool paired,
}) async {
  final gateway = _RecordingGateway()..responses.add(_landed(paired: paired));
  final windows = NativeDocumentWindows(
    gateway,
    appDocumentUrl: () => 'https://gateway.example/?session=s',
  );
  addTearDown(windows.dispose);
  await t.pumpWidget(_host(gateway, windows));
  await t.pumpAndSettle();
  await clickSubmit(t);
  await t.pumpAndSettle();
  return (gateway, windows);
}

const _engineMethods = {
  'documentScriptCapabilities',
  'documentScriptOpen',
  'documentScriptEvaluate',
  'documentScriptResource',
  'documentStylesheet',
  'documentScriptCookies',
  'documentScriptStorage',
};

void main() {
  testWidgets(
    'a document the paired origin served is shown inert: no script engine call, no stylesheet fetch, forms still work',
    (t) async {
      final (gateway, windows) = await _land(t, paired: true);
      final document = windows.active!.currentDocument!;
      expect(document.pairedOrigin, isTrue);
      await t.pumpAndSettle();

      expect(gateway.methods.toSet().intersection(_engineMethods), isEmpty);
      expect(document.scripts, isNull);
      expect(document.stylesheets, isEmpty);
      expect(find.textContaining('Visible body', findRichText: true), findsOneWidget);
      // Form interaction in the inert document is unchanged.
      expect(find.textContaining('Send', findRichText: true), findsOneWidget);
      expect(t.takeException(), isNull);
    },
  );

  testWidgets(
    'the same page from another origin still gets its script environment',
    (t) async {
      final (gateway, windows) = await _land(t, paired: false);
      final document = windows.active!.currentDocument!;
      expect(document.pairedOrigin, isFalse);
      await t.pumpAndSettle();

      // The fake bridge reports no engine, so the start fails; what matters
      // is that the document was handed to the engine at all.
      expect(gateway.methods, contains('documentScriptCapabilities'));
      expect(find.textContaining('Visible body', findRichText: true), findsWidgets);
    },
  );
}
