import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_mobile/live/app.dart';
import 'package:pirc_mobile/live/app_document_route.dart';
import 'package:pirc_mobile/live/document_navigation.dart';
import 'package:pirc_mobile/live/gateway.dart';
import 'package:pirc_render/src/html_buttons.dart';
import 'package:pirc_render/src/html_document_urls.dart';
import 'app_document_live_routes_test.dart' show RouteGateway, scope;
import 'live_test.dart' show theme;

final _pircShell = File('../web/index.html').readAsStringSync();

class LiveHistoryGateway extends RouteGateway {
  LiveHistoryGateway() {
    snapshot = {
      ...snapshot,
      'messages': [
        {
          'id': 'source-form',
          'role': 'assistant',
          'content':
              '<form action="/parity-documents/raw" method="post">'
              '<input type="hidden" name="source" value="source form">'
              '<button>Open native response</button></form>',
        },
      ],
    };
    drafts['session-second'] = 'Second session saved draft';
  }

  final documentRequests = <Json>[];
  final responses = <Json>[];

  @override
  Future<dynamic> call(String method, [Json args = const {}]) async {
    if (method == 'documentPrepareRequest') {
      return {
        'nativeCookieRequestKey':
            'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
      };
    }
    if (method == 'resolveDocumentUrl') {
      return resolveNativeDocumentUrl(
        args['reference'] as String,
        args['baseUrl'] as String,
      );
    }
    if (method == 'document') {
      documentRequests.add(Map<String, dynamic>.from(args));
      if (responses.isEmpty) {
        throw StateError('No queued document response for ${args['url']}.');
      }
      return responses.removeAt(0);
    }
    return super.call(method, args);
  }
}

Json _documentResponse(
  String path,
  String html, {
  String finalMethod = 'GET',
}) => {
  'status': 200,
  'finalUrl': 'https://gateway.example$path',
  'finalMethod': finalMethod,
  'mimeType': 'text/html',
  'charset': 'UTF-8',
  'bytes': Uint8List.fromList(utf8.encode(html)),
  'headersRelevant': <String, dynamic>{
    'content-type': 'text/html; charset=utf-8',
  },
};

Future<void> _tapHtmlButton(WidgetTester tester) async {
  final button = find.byType(NativeHtmlButtonWidget).first;
  await tester.ensureVisible(button);
  await tester.tap(button);
  await tester.pumpAndSettle();
}

Future<void> _pressAltArrow(
  WidgetTester tester,
  LogicalKeyboardKey arrow,
) async {
  final workspace = find.byType(NativeDocumentWorkspace, skipOffstage: false);
  Focus.of(tester.element(workspace)).requestFocus();
  await tester.pump();
  await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
  await tester.sendKeyDownEvent(arrow);
  await tester.sendKeyUpEvent(arrow);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'LiveShell restores POST history edits and source state while GET forward refetches',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(390, 844);
      addTearDown(tester.view.reset);

      final gateway = LiveHistoryGateway()
        ..responses.addAll([
          _documentResponse(
            '/parity-documents/raw',
            '<!doctype html><html><head><title>Raw form document</title>'
                '</head><body><h1>Editable response</h1>'
                '<form action="/parity-documents/app-shell" method="get">'
                '<input type="hidden" name="session" value="session-second">'
                '<label>Notes<textarea>Initial native value</textarea></label>'
                '<button>Open Pirc app</button></form></body></html>',
            finalMethod: 'POST',
          ),
          _documentResponse(
            '/parity-documents/app-shell?session=session-second',
            _pircShell,
          ),
          _documentResponse(
            '/parity-documents/app-shell?session=session-second',
            _pircShell,
          ),
        ]);
      final controller = LiveController(gateway);
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        await gateway.stream.close();
      });

      await tester.pumpWidget(MobileApp(theme: theme, controller: controller));
      await tester.pumpAndSettle();
      final initialRoute = NativeAppDocumentRoute.parse(
        'https://gateway.example/conversations/latest?session=session-latest&trace=source#message',
        appRootUrl: 'https://gateway.example/',
        allowSpaFallback: true,
      )!;
      await scope(tester).windows.onAppRoute!(initialRoute);
      await tester.pumpAndSettle();

      expect(controller.sessionId, 'session-latest');
      final sourceUrl = scope(tester).documentUrl;
      expect(
        sourceUrl,
        'https://gateway.example/conversations/latest?session=session-latest',
      );
      await tester.enterText(
        find.byKey(const Key('live-draft')),
        'App draft to restore',
      );
      await tester.pump();
      expect(controller.draft, 'App draft to restore');

      await _tapHtmlButton(tester);
      expect(find.byType(NativeDocumentWorkspace), findsOneWidget);
      final windows = scope(tester).windows;
      final window = windows.active!;
      final rawDocument = window.currentDocument!;
      expect(window.sourceUrl, sourceUrl);
      expect(controller.active, isFalse);
      expect(gateway.documentRequests.map((request) => request['method']), [
        'POST',
      ]);
      expect(
        gateway.documentRequests.single['url'],
        'https://gateway.example/parity-documents/raw',
      );
      expect(gateway.documentRequests.single['body'], 'source=source+form');

      final editor = find
          .descendant(
            of: find.byType(NativeDocumentWorkspace),
            matching: find.byType(EditableText),
          )
          .first;
      final editorController = tester.widget<EditableText>(editor).controller;
      await tester.enterText(editor, 'Edited native value');
      await tester.pumpAndSettle();
      expect(editorController.text, 'Edited native value');

      await _tapHtmlButton(tester);
      expect(find.byType(NativeDocumentWorkspace), findsNothing);
      expect(controller.sessionId, 'session-second');
      expect(controller.draft, 'Second session saved draft');
      expect(controller.active, isTrue);
      expect(window.history, hasLength(2));
      expect(window.currentAppRoute, isNotNull);
      expect(
        scope(tester).documentUrl,
        'https://gateway.example/parity-documents/app-shell?session=session-second',
      );
      expect(gateway.documentRequests, hasLength(2));
      expect(gateway.documentRequests.last['method'], 'GET');
      expect(
        gateway.documentRequests.last['url'],
        'https://gateway.example/parity-documents/app-shell?session=session-second',
      );
      expect(gateway.documentRequests.last['body'], isNull);
      expect(
        gateway.calls.any(
          (call) =>
              call.$1 == 'watch' && call.$2['sessionId'] == 'session-second',
        ),
        isTrue,
      );

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(window.index, 0);
      final restoredRawDocument = window.currentDocument!;
      expect(restoredRawDocument, isNot(same(rawDocument)));
      expect(restoredRawDocument.content.title, 'Raw form document');
      expect(controller.sessionId, 'session-second');
      expect(controller.active, isFalse);
      expect(find.byType(NativeDocumentWorkspace), findsOneWidget);
      final restoredEditor = find
          .descendant(
            of: find.byType(NativeDocumentWorkspace),
            matching: find.byType(EditableText),
          )
          .first;
      final restoredEditorController = tester
          .widget<EditableText>(restoredEditor)
          .controller;
      expect(restoredEditorController, isNot(same(editorController)));
      expect(restoredEditorController.text, 'Edited native value');
      expect(gateway.documentRequests, hasLength(2));

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(window.index, -1);
      expect(find.byType(NativeDocumentWorkspace), findsNothing);
      expect(controller.sessionId, 'session-latest');
      expect(controller.draft, 'App draft to restore');
      expect(controller.active, isTrue);
      expect(scope(tester).documentUrl, sourceUrl);
      expect(gateway.documentRequests, hasLength(2));

      await _pressAltArrow(tester, LogicalKeyboardKey.arrowRight);
      expect(window.index, 0);
      final forwardRawDocument = window.currentDocument!;
      expect(forwardRawDocument, isNot(same(restoredRawDocument)));
      expect(forwardRawDocument.content.title, 'Raw form document');
      final forwardEditor = find
          .descendant(
            of: find.byType(NativeDocumentWorkspace),
            matching: find.byType(EditableText),
          )
          .first;
      final forwardEditorController = tester
          .widget<EditableText>(forwardEditor)
          .controller;
      expect(forwardEditorController, isNot(same(restoredEditorController)));
      expect(forwardEditorController.text, 'Edited native value');
      expect(controller.active, isFalse);
      expect(gateway.documentRequests, hasLength(2));

      await _pressAltArrow(tester, LogicalKeyboardKey.arrowRight);
      expect(window.index, 1);
      expect(window.currentDocument, isNull);
      expect(window.currentAppRoute, isNotNull);
      expect(find.byType(NativeDocumentWorkspace), findsNothing);
      expect(controller.sessionId, 'session-second');
      expect(controller.draft, 'Second session saved draft');
      expect(controller.active, isTrue);
      expect(
        scope(tester).documentUrl,
        'https://gateway.example/parity-documents/app-shell?session=session-second',
      );
      expect(gateway.documentRequests, hasLength(3));
      expect(gateway.documentRequests.last['method'], 'GET');
      expect(
        gateway.documentRequests.last['url'],
        'https://gateway.example/parity-documents/app-shell?session=session-second',
      );
      expect(tester.takeException(), isNull);
    },
  );
}
