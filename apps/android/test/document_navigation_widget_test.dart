import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_mobile/live/common.dart';
import 'package:pirc_mobile/live/document_navigation.dart';
import 'package:pirc_mobile/live/document_navigation_state.dart';
import 'package:pirc_mobile/live/gateway.dart';
import 'package:pirc_render/src/html_buttons.dart';
import 'package:pirc_render/src/html_document_urls.dart';
import 'package:pirc_render/src/html_form_submission.dart';
import 'native_html_test.dart' show tapText;
import 'live_test.dart' show theme;

class DocumentGateway extends Gateway {
  final calls = <Json>[];
  final responses = <Json>[];
  final bootResponse = <String, dynamic>{
    'origin': 'https://gateway.example',
    'pairingStamp': 'stamp',
  };
  @override
  Future<dynamic> call(String method, [Json args = const {}]) async {
    if (method == 'documentPrepareRequest') {
      return {
        'nativeCookieRequestKey':
            'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
      };
    }
    if (method == 'boot') {
      return Map<String, dynamic>.from(bootResponse);
    }
    if (method == 'resolveDocumentUrl') {
      return resolveNativeDocumentUrl(
        args['reference'] as String,
        args['baseUrl'] as String,
      );
    }
    if (method == 'document') {
      calls.add(args);
      return responses.removeAt(0);
    }
    return {};
  }
}

Json response(
  String path,
  String body, {
  int status = 200,
  String mime = 'text/html',
  String finalMethod = 'GET',
}) => {
  'status': status,
  'finalUrl': 'https://gateway.example$path',
  'finalMethod': finalMethod,
  'mimeType': mime,
  'charset': 'UTF-8',
  'bytes': Uint8List.fromList(utf8.encode(body)),
  'headersRelevant': <String, dynamic>{},
};
Widget app(
  DocumentGateway gateway,
  NativeDocumentWindows windows,
  String source,
) => MaterialApp(
  theme: theme.build(Brightness.light),
  home: NativeDocumentScope(
    windows: windows,
    documentUrl: 'https://gateway.example/?session=s',
    sourceIdentity: windows.accountIdentity,
    child: Scaffold(
      body: SingleChildScrollView(
        child: RichTextBody(source, gateway: gateway),
      ),
    ),
  ),
);
Future<void> clickSubmit(WidgetTester t) async {
  final button = find.byType(NativeHtmlButtonWidget).first;
  await t.ensureVisible(button);
  await t.pumpAndSettle();
  await t.tap(button);
  await t.pumpAndSettle();
}

void main() {
  testWidgets('POST reload asks first and resends the final URL and exact body', (
    t,
  ) async {
    final gateway = DocumentGateway()
      ..responses.addAll([
        response('/landed', '<title>Submitted</title>', finalMethod: 'POST'),
        response('/landed', '<title>Resubmitted</title>', finalMethod: 'POST'),
      ]);
    final windows = NativeDocumentWindows(gateway);
    addTearDown(windows.dispose);
    await t.pumpWidget(
      app(
        gateway,
        windows,
        '<form action="/submit" method="post"><input name="value" value="raw + body"><button>Send</button></form>',
      ),
    );
    await t.pumpAndSettle();
    await clickSubmit(t);

    final saved = windows.active!.current!.document!.reloadRequest!;
    expect(saved.url, 'https://gateway.example/landed');
    expect(saved.method, 'POST');
    expect(saved.body, 'value=raw+%2B+body');
    expect(saved.contentType, 'application/x-www-form-urlencoded');

    await t.tap(find.byTooltip("Reload"));
    await t.pumpAndSettle();
    expect(find.text("Resubmit form?"), findsOneWidget);
    await t.tap(find.text("Cancel"));
    await t.pumpAndSettle();
    expect(gateway.calls, hasLength(1));
    await windows.active!.load(
      const NativeHtmlFormRequest(url: '#section', method: 'GET', target: ''),
      baseUrl: windows.active!.current!.url,
      fragmentAllowed: true,
    );
    await t.pumpAndSettle();
    expect(gateway.calls, hasLength(1));

    await t.tap(find.byTooltip("Reload"));
    await t.pumpAndSettle();
    await t.tap(find.text("Resubmit"));
    await t.pumpAndSettle();
    expect(gateway.calls, hasLength(2));
    expect(gateway.calls.last['url'], 'https://gateway.example/landed#section');
    expect(gateway.calls.last['method'], 'POST');
    expect(gateway.calls.last['body'], 'value=raw+%2B+body');
    expect(
      gateway.calls.last['contentType'],
      'application/x-www-form-urlencoded',
    );
    expect(find.text('Resubmitted'), findsOneWidget);
    expect(t.takeException(), isNull);
  });

  testWidgets('POST redirected to GET reloads as GET without confirmation', (
    t,
  ) async {
    final gateway = DocumentGateway()
      ..responses.addAll([
        response('/landed?done=1', '<title>Redirect result</title>'),
        response('/landed?done=1', '<title>Reloaded result</title>'),
      ]);
    final windows = NativeDocumentWindows(gateway);
    addTearDown(windows.dispose);
    await t.pumpWidget(
      app(
        gateway,
        windows,
        '<form action="/submit" method="post"><input name="x" value="one"><button>Send</button></form>',
      ),
    );
    await t.pumpAndSettle();
    await clickSubmit(t);
    expect(windows.active!.current!.document!.reloadRequest!.method, 'GET');

    await t.tap(find.byTooltip("Reload"));
    await t.pumpAndSettle();
    expect(find.text("Resubmit form?"), findsNothing);
    expect(gateway.calls, hasLength(2));
    expect(gateway.calls.last['url'], 'https://gateway.example/landed?done=1');
    expect(gateway.calls.last['method'], 'GET');
    expect(gateway.calls.last['body'], isNull);
    expect(gateway.calls.last['contentType'], isNull);
    expect(find.text('Reloaded result'), findsOneWidget);
  });

  testWidgets(
    'POST reload confirmation is ignored after the current page changes',
    (t) async {
      final gateway = DocumentGateway()
        ..responses.addAll([
          response(
            '/prior',
            '<title>Prior</title><form action="/landed" method="post"><input name="x" value="one"><button>Submit</button></form>',
          ),
          response('/landed', '<title>Posted</title>', finalMethod: 'POST'),
        ]);
      final windows = NativeDocumentWindows(gateway);
      addTearDown(windows.dispose);
      await t.pumpWidget(
        app(
          gateway,
          windows,
          '<form action="/prior"><button>Open</button></form>',
        ),
      );
      await t.pumpAndSettle();
      await clickSubmit(t);
      await clickSubmit(t);

      await t.tap(find.byTooltip("Reload"));
      await t.pumpAndSettle();
      windows.active!.back();
      await t.pump();
      await t.tap(find.text("Resubmit"));
      await t.pumpAndSettle();

      expect(gateway.calls, hasLength(2));
      expect(windows.active!.current!.url, 'https://gateway.example/prior');
      expect(find.text('Prior'), findsOneWidget);
      expect(t.takeException(), isNull);
    },
  );

  testWidgets('POST reload confirmation is ignored after switching windows', (
    t,
  ) async {
    final gateway = DocumentGateway()
      ..responses.add(
        response('/landed', '<title>Posted</title>', finalMethod: 'POST'),
      );
    final windows = NativeDocumentWindows(gateway);
    addTearDown(windows.dispose);
    await t.pumpWidget(
      app(
        gateway,
        windows,
        '<form action="/submit" method="post"><input name="x" value="one"><button>Send</button></form>',
      ),
    );
    await t.pumpAndSettle();
    await clickSubmit(t);

    final original = windows.active!;
    await t.tap(find.byTooltip("Reload"));
    await t.pumpAndSettle();
    final other = windows.target(
      '_blank',
      original,
      sourceUrl: 'https://gateway.example/other',
    );
    windows.select(other);
    await t.pump();
    await t.tap(find.text("Resubmit"));
    await t.pumpAndSettle();

    expect(gateway.calls, hasLength(1));
    expect(windows.active, same(other));
    expect(t.takeException(), isNull);
  });

  testWidgets('POST reload confirmation is ignored after account changes', (
    t,
  ) async {
    final gateway = DocumentGateway()
      ..responses.add(
        response('/landed', '<title>Posted</title>', finalMethod: 'POST'),
      );
    final windows = NativeDocumentWindows(gateway);
    addTearDown(windows.dispose);
    await t.pumpWidget(
      app(
        gateway,
        windows,
        '<form action="/submit" method="post"><input name="x" value="one"><button>Send</button></form>',
      ),
    );
    await t.pumpAndSettle();
    await clickSubmit(t);

    await t.tap(find.byTooltip("Reload"));
    await t.pumpAndSettle();
    gateway.bootResponse['pairingStamp'] = 'new-account';
    await windows.connection().catchError((_) => <String, dynamic>{});
    await t.pump();
    await t.tap(find.text("Resubmit"));
    await t.pumpAndSettle();

    expect(gateway.calls, hasLength(1));
    expect(windows.windows, isEmpty);
    expect(t.takeException(), isNull);
  });

  testWidgets(
    'App submits real typed request and renders response in Flutter; back preserves source edit',
    (t) async {
      final gateway = DocumentGateway()
        ..responses.add(
          response(
            '/next',
            '<html><head><title>Next document</title></head><body><h1>Returned result</h1></body></html>',
          ),
        );
      final windows = NativeDocumentWindows(gateway);
      addTearDown(windows.dispose);
      await t.pumpWidget(
        app(
          gateway,
          windows,
          '<form action="/next" method="post"><input name="message" value="Initial"><button>Send</button></form>',
        ),
      );
      await t.pumpAndSettle();
      await t.enterText(find.byType(EditableText), 'Edited');
      await clickSubmit(t);
      expect(find.byType(NativeDocumentWorkspace), findsOneWidget);
      expect(find.text('Next document'), findsOneWidget);
      expect(find.text('Returned result', findRichText: true), findsOneWidget);
      expect(gateway.calls.single['body'], 'message=Edited');
      expect(gateway.calls.single['method'], 'POST');
      expect(gateway.calls.single['pairingStamp'], 'stamp');
      await t.tap(find.byTooltip("Back"));
      await t.pumpAndSettle();
      expect(find.byType(NativeDocumentWorkspace), findsNothing);
      expect(
        t.widget<EditableText>(find.byType(EditableText)).controller.text,
        'Edited',
      );
      expect(t.takeException(), isNull);
    },
  );

  testWidgets('204 and 205 never replace source or clear edit', (t) async {
    final gateway = DocumentGateway();
    final windows = NativeDocumentWindows(gateway);
    addTearDown(windows.dispose);
    await t.pumpWidget(
      app(
        gateway,
        windows,
        '<form action="/empty"><input name="x" value="Initial"><button>Send</button></form>',
      ),
    );
    await t.pumpAndSettle();
    await t.enterText(find.byType(EditableText), 'Kept');
    for (final status in [204, 205]) {
      gateway.responses.add(response('/empty', '', status: status));
      await clickSubmit(t);
      expect(find.byType(NativeDocumentWorkspace), findsNothing);
      expect(
        t.widget<EditableText>(find.byType(EditableText)).controller.text,
        'Kept',
      );
      expect(windows.windows, isEmpty);
    }
  });

  testWidgets(
    'fetched HTML forms preserve edited fields through back/forward without replaying POST',
    (t) async {
      final gateway = DocumentGateway()
        ..responses.addAll([
          response(
            '/dir/one',
            '<head><title>One</title></head><body><label for="name">Name</label><form action="two" method="post"><input id="name" name="x" value="Initial"><button>Next</button></form></body>',
          ),
          response('/dir/two', '<title>Two</title><p>Second document</p>'),
        ]);
      final windows = NativeDocumentWindows(gateway);
      addTearDown(windows.dispose);
      await t.pumpWidget(
        app(
          gateway,
          windows,
          '<form action="/dir/one"><button>Open</button></form>',
        ),
      );
      await t.pumpAndSettle();
      await clickSubmit(t);
      await t.enterText(find.byType(EditableText), 'Edited response');
      await clickSubmit(t);
      expect(find.text('Two'), findsOneWidget);
      expect(gateway.calls, hasLength(2));
      await t.tap(find.byTooltip("Back"));
      await t.pumpAndSettle();
      expect(find.text('One'), findsOneWidget);
      expect(
        t.widget<EditableText>(find.byType(EditableText)).controller.text,
        'Edited response',
      );
      await t.tap(find.byTooltip("Next page"));
      await t.pumpAndSettle();
      expect(find.text('Two'), findsOneWidget);
      expect(gateway.calls, hasLength(2));
      expect(gateway.calls.last['url'], 'https://gateway.example/dir/two');
      expect(t.takeException(), isNull);
    },
  );

  testWidgets(
    'response fragment actually reveals target without another HTTP request',
    (t) async {
      final gateway = DocumentGateway()
        ..responses.add(
          response(
            '/fragment',
            '<title>Fragment</title><a href="#destination">Jump</a><div style="height:1200px"></div><div id="destination">Destination</div>',
          ),
        );
      final windows = NativeDocumentWindows(gateway);
      addTearDown(windows.dispose);
      await t.pumpWidget(
        app(
          gateway,
          windows,
          '<form action="/fragment"><button>Open</button></form>',
        ),
      );
      await t.pumpAndSettle();
      await clickSubmit(t);
      expect(
        windows.active!.current!.document!.scroll.position.maxScrollExtent,
        greaterThan(500),
        reason: 'styled empty block creates scroll extent',
      );
      await tapText(t, 'Jump');
      await t.pumpAndSettle();
      expect(gateway.calls, hasLength(1));
      expect(
        windows.active!.current!.url,
        'https://gateway.example/fragment#destination',
      );
      expect(windows.active!.current!.document!.scroll.offset, greaterThan(0));
      expect(t.takeException(), isNull);
    },
  );

  testWidgets('blank target creates one context; named target is reused', (
    t,
  ) async {
    final gateway = DocumentGateway()
      ..responses.add(
        response(
          '/blank',
          '<title>Blank</title><form action="/named" target="report"><button>Named</button></form>',
        ),
      );
    gateway.responses.add(
      response(
        '/named',
        '<title>Named</title><form action="/named-again" target="report"><button>Reuse</button></form>',
      ),
    );
    gateway.responses.add(
      response('/named-again', '<title>Named again</title>'),
    );
    final windows = NativeDocumentWindows(gateway);
    addTearDown(windows.dispose);
    await t.pumpWidget(
      app(
        gateway,
        windows,
        '<form action="/blank" target="_blank"><button>Open</button></form>',
      ),
    );
    await t.pumpAndSettle();
    await clickSubmit(t);
    expect(windows.windows, hasLength(1));
    await clickSubmit(t);
    expect(windows.windows, hasLength(2));
    final named = windows.active;
    await clickSubmit(t);
    expect(windows.windows, hasLength(2));
    expect(windows.active, same(named));
    expect(find.text('Named again'), findsOneWidget);
    await t.tap(find.byTooltip("Close page"));
    await t.pumpAndSettle();
    expect(named!.disposed, isTrue);
    expect(windows.windows, hasLength(1));
    expect(find.byType(NativeDocumentWorkspace), findsOneWidget);
    expect(find.text('Blank'), findsOneWidget);
    expect(gateway.calls, hasLength(3));
    await t.tap(find.byTooltip("Close page"));
    await t.pumpAndSettle();
    expect(windows.windows, isEmpty);
    expect(find.byType(NativeDocumentWorkspace), findsNothing);
    expect(find.text('Open', findRichText: true), findsOneWidget);
    expect(t.takeException(), isNull);
  });
}
