import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_mobile/live/app.dart';
import 'package:pirc_mobile/live/document_navigation.dart';
import 'package:pirc_mobile/live/gateway.dart';
import 'package:pirc_mobile/live/panels.dart';
import 'package:pirc_mobile/live/side_panel.dart';
import 'package:pirc_render/src/html_buttons.dart';

import 'app_document_live_routes_test.dart' show scope;
import 'live_test.dart' show theme;
import 'native_document_live_history_test.dart' show LiveHistoryGateway;

final _pircShell = File('../web/index.html').readAsStringSync();

Json _documentResponse(String path, String body) => {
  'status': 200,
  'finalUrl': 'https://gateway.example$path',
  'finalMethod': 'GET',
  'mimeType': 'text/html',
  'charset': 'UTF-8',
  'bytes': Uint8List.fromList(utf8.encode(body)),
  'headersRelevant': <String, String>{
    'Content-Type': 'text/html; charset=utf-8',
  },
};

void _setDesktopViewport(WidgetTester tester) {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(1024, 900);
  addTearDown(tester.view.reset);
}

Future<void> _selectMemoryPanel(WidgetTester tester) async {
  await tester.tap(find.byTooltip('Show side panel'));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const ValueKey('panel-tab-memory')));
  await tester.pumpAndSettle();
}

void _expectPanelKind(WidgetTester tester, String kind) {
  final panel = find.byType(NativeSidePanel);
  expect(panel, findsOneWidget);
  expect(tester.widget<NativeSidePanel>(panel).tab, kind);
  final workPanel = find.byType(WorkPanel);
  expect(workPanel, findsOneWidget);
  expect(tester.widget<WorkPanel>(workPanel).kind, kind);
}

Future<void> _tapHtmlButton(WidgetTester tester) async {
  final button = find.byType(NativeHtmlButtonWidget).first;
  await tester.ensureVisible(button);
  await tester.tap(button);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'history Back restores the selected panel after a shell GET changes sessions',
    (tester) async {
      _setDesktopViewport(tester);
      final gateway = LiveHistoryGateway();
      gateway.snapshot = {
        ...gateway.snapshot,
        'messages': [
          {
            'id': 'open-shell',
            'role': 'assistant',
            'content':
                '<form action="/" method="get">'
                '<input type="hidden" name="session" value="session-second">'
                '<button>Open second session</button></form>',
          },
        ],
      };
      gateway.responses.add(
        _documentResponse('/?session=session-second', _pircShell),
      );
      final controller = LiveController(gateway);
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        await gateway.stream.close();
      });

      await tester.pumpWidget(MobileApp(theme: theme, controller: controller));
      await tester.pumpAndSettle();
      expect(controller.sessionId, 'session-latest');
      await _selectMemoryPanel(tester);
      _expectPanelKind(tester, 'memory');

      await _tapHtmlButton(tester);

      expect(gateway.documentRequests, hasLength(1));
      expect(gateway.documentRequests.single['method'], 'GET');
      expect(
        gateway.documentRequests.single['url'],
        'https://gateway.example/?session=session-second',
      );
      expect(controller.sessionId, 'session-second');
      expect(find.byType(NativeDocumentWorkspace), findsNothing);

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();

      expect(controller.sessionId, 'session-latest');
      expect(
        scope(tester).documentUrl,
        'https://gateway.example/?session=session-latest',
      );
      _expectPanelKind(tester, 'memory');
      expect(gateway.documentRequests, hasLength(1));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'direct session changes keep the selected panel; account changes reset it',
    (tester) async {
      _setDesktopViewport(tester);
      final gateway = LiveHistoryGateway();
      final controller = LiveController(gateway);
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        await gateway.stream.close();
      });

      await tester.pumpWidget(MobileApp(theme: theme, controller: controller));
      await tester.pumpAndSettle();
      expect(controller.sessionId, 'session-latest');
      await _selectMemoryPanel(tester);
      _expectPanelKind(tester, 'memory');

      await controller.open('session-second');
      await tester.pumpAndSettle();
      expect(controller.sessionId, 'session-second');
      _expectPanelKind(tester, 'memory');

      controller
        ..origin = 'https://another-gateway.example'
        ..clientId = 'another-client';
      controller.changed();
      await tester.pumpAndSettle();

      _expectPanelKind(tester, 'files');
      expect(tester.takeException(), isNull);
    },
  );
}
