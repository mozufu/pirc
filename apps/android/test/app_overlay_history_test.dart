import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_mobile/live/app.dart';
import 'package:pirc_mobile/live/document_navigation.dart';
import 'package:pirc_mobile/live/gateway.dart';
import 'package:pirc_mobile/live/settings_dialog.dart';
import 'package:pirc_render/src/html_buttons.dart';

import 'app_document_live_routes_test.dart' show scope;
import 'live_test.dart' show theme;
import 'native_document_live_history_test.dart' show LiveHistoryGateway;

final _pircShell = File('../web/index.html').readAsStringSync();

class _HeldDocumentGateway extends LiveHistoryGateway {
  _HeldDocumentGateway(String sourceHtml) {
    snapshot = {
      ...snapshot,
      'messages': [
        {'id': 'overlay-source', 'role': 'assistant', 'content': sourceHtml},
      ],
    };
  }

  final documentStarted = Completer<void>();
  final documentResponse = Completer<Json>();
  final documentArguments = <Json>[];
  bool changeMemoryOnNextRead = false;

  @override
  dynamic normal(String method, Json args) {
    if (method == 'request' && args['path'] == '/api/memory') {
      return _memoryFixture(changed: changeMemoryOnNextRead);
    }
    return super.normal(method, args);
  }

  @override
  Future<dynamic> call(String method, [Json args = const {}]) async {
    if (method == 'documentPrepareRequest') {
      return {
        'nativeCookieRequestKey':
            'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
      };
    }
    if (method == 'document') {
      documentArguments.add(Map<String, dynamic>.from(args));
      if (!documentStarted.isCompleted) documentStarted.complete();
      return documentResponse.future;
    }
    return super.call(method, args);
  }
}

Json _memoryFixture({bool changed = false}) => {
  'usage': {
    'user': {'used': 0, 'max': 10000},
    'note': {'used': 2800, 'max': 10000},
  },
  'user': <Json>[],
  'notes': [
    for (var i = 0; i < 24; i++)
      {
        'id': 'overlay-memory-$i',
        'content': [
          'Overlay memory entry $i.',
          if (changed && i == 0) 'Updated on the server.',
          List.filled(12, 'A saved note.').join(' '),
        ].join(' '),
        'status': 'active',
        'updatedAt': 1700000000000 - i * 1000,
        'origins': ['assistant'],
        'sources': <String, dynamic>{},
      },
  ],
  'removed': <Json>[],
  'proposals': <Json>[],
  'sessions': {'session-latest': 'Latest session'},
};

Json _htmlResponse(String url, String html) => {
  'status': 200,
  'finalUrl': url,
  'finalMethod': 'GET',
  'mimeType': 'text/html',
  'charset': 'UTF-8',
  'bytes': Uint8List.fromList(utf8.encode(html)),
  'headersRelevant': <String, dynamic>{
    'content-type': 'text/html; charset=utf-8',
  },
};

void _desktopViewport(WidgetTester tester) {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(1024, 840);
  addTearDown(tester.view.reset);
}

Future<void> _submitSourceForm(WidgetTester tester) async {
  final button = find.byType(NativeHtmlButtonWidget).first;
  await tester.ensureVisible(button);
  await tester.tap(button);
  await tester.pump();
}

Future<void> _openMemorySettings(WidgetTester tester) async {
  final settings = find.widgetWithText(TextButton, 'Settings');
  expect(settings, findsOneWidget);
  await tester.ensureVisible(settings);
  await tester.tap(settings);
  await tester.pumpAndSettle();

  final memoryTab = find.byKey(const ValueKey('settings-tab-Memory'));
  expect(memoryTab, findsOneWidget);
  await tester.tap(memoryTab);
  await tester.pumpAndSettle();
  expect(find.text("The assistant's notes · MEMORY"), findsOneWidget);
}

Finder _settingsScroll({bool skipOffstage = true}) => find.descendant(
  of: find.byType(NativeSettingsDialog, skipOffstage: skipOffstage),
  matching: find.byType(Scrollable, skipOffstage: skipOffstage),
);

Future<ScrollableState> _makeMemoryOverlayState(WidgetTester tester) async {
  final forget = find.text('Forget').first;
  await tester.ensureVisible(forget);
  await tester.tap(forget);
  await tester.pumpAndSettle();
  expect(find.text('Forget for good'), findsOneWidget);

  final scroll = _settingsScroll();
  expect(scroll, findsOneWidget);
  await tester.drag(scroll, const Offset(0, -320));
  await tester.pumpAndSettle();
  final state = tester.state<ScrollableState>(scroll);
  expect(state.position.pixels, greaterThan(0));
  return state;
}

Future<void> _pumpApp(
  WidgetTester tester,
  _HeldDocumentGateway gateway,
  LiveController controller,
) async {
  await tester.pumpWidget(MobileApp(theme: theme, controller: controller));
  await tester.pumpAndSettle();
  expect(controller.sessionId, 'session-latest');
}

void _disposeAfterTest(
  WidgetTester tester,
  _HeldDocumentGateway gateway,
  LiveController controller,
) {
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox());
    await gateway.stream.close();
  });
}

void main() {
  testWidgets(
    'source Settings overlay and Memory state survive a slow document GET and Android back',
    (tester) async {
      _desktopViewport(tester);
      final gateway = _HeldDocumentGateway(
        '<form action="/parity-documents/slow" method="get">'
        '<button>Open slow native document</button></form>',
      );
      final controller = LiveController(gateway);
      _disposeAfterTest(tester, gateway, controller);
      await _pumpApp(tester, gateway, controller);

      await _submitSourceForm(tester);
      await gateway.documentStarted.future;
      expect(gateway.documentArguments.single['method'], 'GET');
      expect(find.byType(NativeDocumentWorkspace), findsNothing);

      await _openMemorySettings(tester);
      final retainedScroll = await _makeMemoryOverlayState(tester);
      final scrollOffset = retainedScroll.position.pixels;

      final requestedUrl = '${gateway.documentArguments.single['url']}';
      gateway.documentResponse.complete(
        _htmlResponse(
          requestedUrl,
          '<!doctype html><html><head><title>Slow document</title></head>'
          '<body><h1>Document B</h1></body></html>',
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byType(NativeDocumentWorkspace), findsOneWidget);
      expect(
        scope(tester).windows.active!.currentDocument!.content.title,
        'Slow document',
      );
      expect(find.byType(NativeSettingsDialog), findsNothing);
      expect(
        find.byType(NativeSettingsDialog, skipOffstage: false),
        findsOneWidget,
      );
      expect(
        tester.state<ScrollableState>(_settingsScroll(skipOffstage: false)),
        same(retainedScroll),
      );

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      final window = scope(tester).windows.active!;
      expect(window.index, -1);
      expect(window.canForward, isTrue);
      expect(find.byType(NativeDocumentWorkspace), findsNothing);
      expect(find.byType(NativeSettingsDialog), findsOneWidget);
      expect(find.text("The assistant's notes · MEMORY"), findsOneWidget);
      final restoredScroll = tester.state<ScrollableState>(_settingsScroll());
      expect(restoredScroll, same(retainedScroll));
      expect(restoredScroll.position.pixels, closeTo(scrollOffset, .01));
      expect(gateway.documentArguments, hasLength(1));
      expect(find.text('Forget for good'), findsOneWidget);

      gateway.changeMemoryOnNextRead = true;
      await controller.attention.memoryChanged();
      await tester.pumpAndSettle();
      expect(find.text('Forget for good'), findsNothing);
    },
  );

  testWidgets(
    'Android back closes a source App overlay before moving document history',
    (tester) async {
      _desktopViewport(tester);
      final gateway = _HeldDocumentGateway(
        '<form action="/parity-documents/back-test" method="get">'
        '<button>Open back-test document</button></form>',
      );
      final controller = LiveController(gateway);
      _disposeAfterTest(tester, gateway, controller);
      await _pumpApp(tester, gateway, controller);

      await _submitSourceForm(tester);
      await gateway.documentStarted.future;
      final url = '${gateway.documentArguments.single['url']}';
      gateway.documentResponse.complete(
        _htmlResponse(
          url,
          '<!doctype html><title>Back test</title><h1>Body</h1>',
        ),
      );
      await tester.pumpAndSettle();
      final window = scope(tester).windows.active!;
      expect(window.index, 0);

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(window.index, -1);
      expect(window.canForward, isTrue);

      await _openMemorySettings(tester);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byType(NativeSettingsDialog), findsNothing);
      expect(window.index, -1);
      expect(window.canForward, isTrue);
      expect(gateway.documentArguments, hasLength(1));
    },
  );

  testWidgets(
    'App shell GET gets a fresh overlay stack while Back restores the source modal stack',
    (tester) async {
      _desktopViewport(tester);
      final gateway = _HeldDocumentGateway(
        '<form action="/parity-documents/app-shell" method="get">'
        '<input type="hidden" name="session" value="session-second">'
        '<button>Open second session</button></form>',
      );
      final controller = LiveController(gateway);
      _disposeAfterTest(tester, gateway, controller);
      await _pumpApp(tester, gateway, controller);

      await _submitSourceForm(tester);
      await gateway.documentStarted.future;
      await _openMemorySettings(tester);
      final retainedScroll = await _makeMemoryOverlayState(tester);

      final requestedUrl = '${gateway.documentArguments.single['url']}';
      expect(requestedUrl, contains('session=session-second'));
      gateway.documentResponse.complete(
        _htmlResponse(requestedUrl, _pircShell),
      );
      await tester.pumpAndSettle();

      final windows = scope(tester).windows;
      expect(
        windows.active,
        isNotNull,
        reason:
            'activeId=${windows.activeId}, count=${windows.windows.length}, '
            'windows=${windows.windows.map((w) => '${w.id}:index=${w.index},url=${w.current?.url},'
                'route=${w.currentAppRoute},pending=${w.pendingAppRoute},error=${w.error}').join('; ')}, '
            'session=${controller.sessionId}',
      );
      final activeWindow = windows.active!;
      expect(activeWindow.currentAppRoute, isNotNull);
      expect(controller.sessionId, 'session-second');
      expect(find.byType(NativeDocumentWorkspace), findsNothing);
      expect(find.byType(NativeSettingsDialog), findsNothing);
      expect(
        find.byType(NativeSettingsDialog, skipOffstage: false),
        findsOneWidget,
      );
      expect(gateway.documentArguments, hasLength(1));

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      final window = scope(tester).windows.active!;
      expect(window.index, -1);
      expect(controller.sessionId, 'session-latest');
      expect(find.byType(NativeDocumentWorkspace), findsNothing);
      expect(find.byType(NativeSettingsDialog), findsOneWidget);
      expect(find.text("The assistant's notes · MEMORY"), findsOneWidget);
      expect(find.text('Forget for good'), findsOneWidget);
      final restoredScroll = tester.state<ScrollableState>(_settingsScroll());
      expect(restoredScroll, same(retainedScroll));
      expect(gateway.documentArguments, hasLength(1));
    },
  );

  testWidgets('pairing account change prunes retained modal surfaces', (
    tester,
  ) async {
    _desktopViewport(tester);
    final gateway = _HeldDocumentGateway('<p>Source without navigation</p>');
    final controller = LiveController(gateway);
    _disposeAfterTest(tester, gateway, controller);
    await _pumpApp(tester, gateway, controller);

    await _openMemorySettings(tester);
    await _makeMemoryOverlayState(tester);
    expect(find.byType(NativeSettingsDialog), findsOneWidget);

    gateway.stream.add({
      'type': 'pairingChanged',
      'data': {
        'origin': 'https://new-gateway.example',
        'clientId': 'new-phone',
        'pairingStamp': 'new-pairing',
      },
    });
    await tester.pumpAndSettle();

    expect(controller.origin, 'https://new-gateway.example');
    expect(scope(tester).windows.windows, isEmpty);
    expect(find.byType(NativeSettingsDialog), findsNothing);
    expect(
      find.byType(NativeSettingsDialog, skipOffstage: false),
      findsNothing,
    );
  });
}
