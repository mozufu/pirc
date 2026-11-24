import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_mobile/live/app_document_route.dart';
import 'package:pirc_mobile/live/common.dart';
import 'package:pirc_mobile/live/document_navigation.dart';
import 'package:pirc_mobile/live/document_navigation_state.dart';
import 'package:pirc_mobile/live/gateway.dart';
import 'package:pirc_render/src/html_buttons.dart';

import 'document_navigation_widget_test.dart'
    show DocumentGateway, clickSubmit, response;
import 'live_test.dart' show theme;
import 'native_html_test.dart' show tapText;

const _pircShell = '''
<!doctype html><html lang="en"><head>
<meta name="description" content="A calm command surface for persistent coding-agent sessions.">
<meta name="apple-mobile-web-app-title" content="pirc">
<title>pirc</title></head><body><div id="app"></div>
<script type="module" src="/src/main.ts"></script></body></html>
''';

Widget _hostedApp({
  required DocumentGateway gateway,
  required NativeDocumentWindows windows,
  required GlobalKey<NativeDocumentHostState> hostKey,
  required String source,
}) => MaterialApp(
  theme: theme.build(Brightness.light),
  home: NativeDocumentScope(
    windows: windows,
    documentUrl: 'https://gateway.example/?session=source',
    sourceIdentity: windows.accountIdentity,
    child: NativeDocumentHost(
      key: hostKey,
      windows: windows,
      child: Scaffold(
        body: SingleChildScrollView(
          child: RichTextBody(source, gateway: gateway),
        ),
      ),
    ),
  ),
);

Finder _documentViewFinder() =>
    find.byType(NativeFetchedDocumentView, skipOffstage: false);

Finder _documentEditorFinder(Finder documentView) => find.descendant(
  of: documentView,
  matching: find.byType(EditableText, skipOffstage: false),
);

Future<void> _clickButtonAt(WidgetTester tester, int index) async {
  final button = find.byType(NativeHtmlButtonWidget).at(index);
  await tester.ensureVisible(button);
  await tester.tap(button);
  await tester.pumpAndSettle();
}

Future<void> _tapTextWithoutScrolling(WidgetTester tester, String label) async {
  final finder = find
      .byWidgetPredicate(
        (widget) =>
            widget is RichText && widget.text.toPlainText().contains(label),
      )
      .first;
  final rich = tester.widget<RichText>(finder);
  final render = tester.renderObject<RenderParagraph>(finder);
  final start = rich.text.toPlainText().indexOf(label);
  final box = render
      .getBoxesForSelection(
        TextSelection(baseOffset: start, extentOffset: start + 1),
      )
      .first
      .toRect();
  await tester.tapAt(render.localToGlobal(box.center));
  await tester.pumpAndSettle();
}

Future<void> _pressAltArrow(
  WidgetTester tester,
  LogicalKeyboardKey arrow,
) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
  await tester.sendKeyDownEvent(arrow);
  await tester.sendKeyUpEvent(arrow);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'App back and forward retain the same mounted document view and controls',
    (tester) async {
      final gateway = DocumentGateway()
        ..responses.add(
          response(
            '/page',
            '<title>Form document</title><form action="/submit">'
                '<input name="value" value="initial"><button>Send</button>'
                '</form>${List.generate(30, (i) => '<p>row $i</p>').join()}',
          ),
        );
      Object appState = 'source-app-state';
      String? appUrl = 'https://gateway.example/?session=source';
      final restored = <Object>[];
      final windows = NativeDocumentWindows(
        gateway,
        captureAppState: () => appState,
        restoreAppState: (state) async {
          restored.add(state);
          appState = state;
        },
        appDocumentUrl: () => appUrl,
      );
      addTearDown(windows.dispose);
      final hostKey = GlobalKey<NativeDocumentHostState>();
      await tester.pumpWidget(
        _hostedApp(
          gateway: gateway,
          windows: windows,
          hostKey: hostKey,
          source: '<form action="/page"><button>Open document</button></form>',
        ),
      );
      await tester.pumpAndSettle();
      await clickSubmit(tester);

      final window = windows.active!;
      final document = window.currentDocument!;
      final initialCalls = gateway.calls.length;
      final viewFinder = _documentViewFinder();
      final viewState = tester.state<State>(viewFinder);
      final editor = _documentEditorFinder(viewFinder).first;
      final controller = tester.widget<EditableText>(editor).controller;
      await tester.enterText(editor, 'edited while in document');
      await tester.pumpAndSettle();
      expect(document.scroll.hasClients, isTrue);
      expect(document.scroll.position.maxScrollExtent, greaterThan(0));
      document.scroll.jumpTo(document.scroll.position.maxScrollExtent);
      await tester.pumpAndSettle();
      final scrollOffset = document.scroll.offset;
      expect(controller.text, 'edited while in document');

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(window.index, -1);
      expect(find.byType(NativeHtmlButtonWidget), findsOneWidget);
      expect(_documentViewFinder(), findsOneWidget);
      expect(tester.state<State>(_documentViewFinder()), same(viewState));
      expect(
        tester
            .widget<EditableText>(
              _documentEditorFinder(_documentViewFinder()).first,
            )
            .controller,
        same(controller),
      );
      expect(controller.text, 'edited while in document');
      expect(document.scroll.offset, scrollOffset);

      appState = 'source-app-updated';
      appUrl = 'https://gateway.example/?workspace=project%3Aone';
      window.captureCurrentAppState();
      await tester.pump();
      await _pressAltArrow(tester, LogicalKeyboardKey.arrowRight);
      expect(window.index, 0);
      expect(window.currentDocument, same(document));
      expect(_documentViewFinder(), findsOneWidget);
      expect(tester.state<State>(_documentViewFinder()), same(viewState));
      expect(controller.text, 'edited while in document');
      expect(document.scroll.offset, scrollOffset);
      expect(gateway.calls, hasLength(initialCalls));

      await _pressAltArrow(tester, LogicalKeyboardKey.arrowLeft);
      expect(window.index, -1);
      expect(restored, contains('source-app-updated'));
      expect(appState, 'source-app-updated');
      expect(gateway.calls, hasLength(initialCalls));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Android back closes a blank document and keeps the source root route',
    (tester) async {
      final gateway = DocumentGateway()
        ..responses.add(
          response('/blank', '<title>Blank document</title><p>Blank body</p>'),
        );
      final windows = NativeDocumentWindows(gateway);
      addTearDown(windows.dispose);
      final hostKey = GlobalKey<NativeDocumentHostState>();
      await tester.pumpWidget(
        _hostedApp(
          gateway: gateway,
          windows: windows,
          hostKey: hostKey,
          source:
              '<form action="/blank" target="_blank">'
              '<button>Open blank</button></form>',
        ),
      );
      await tester.pumpAndSettle();
      await clickSubmit(tester);

      final blankWindow = windows.active!;
      expect(blankWindow.canReturnToSource, isFalse);
      expect(blankWindow.currentDocument?.url, 'https://gateway.example/blank');
      expect(_documentViewFinder(), findsOneWidget);
      final calls = gateway.calls.length;

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();

      expect(blankWindow.disposed, isTrue);
      expect(windows.windows, isEmpty);
      expect(windows.active, isNull);
      expect(_documentViewFinder(), findsNothing);
      expect(find.byType(NativeDocumentWorkspace), findsNothing);
      expect(find.byType(NativeHtmlButtonWidget), findsOneWidget);
      expect(find.text('Open blank', findRichText: true), findsOneWidget);
      expect(hostKey.currentState, isNotNull);
      expect(
        Navigator.of(tester.element(find.byKey(hostKey))).canPop(),
        isFalse,
      );
      expect(gateway.calls, hasLength(calls));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Android back clears a failed primary request and preserves forward documents',
    (tester) async {
      final gateway = DocumentGateway()
        ..responses.add(
          response(
            '/cached',
            '<title>Cached document</title><p>Cached body</p>',
          ),
        );
      final windows = NativeDocumentWindows(gateway);
      addTearDown(windows.dispose);
      final hostKey = GlobalKey<NativeDocumentHostState>();
      await tester.pumpWidget(
        _hostedApp(
          gateway: gateway,
          windows: windows,
          hostKey: hostKey,
          source:
              '<form action="/cached"><button>Open cached</button></form>'
              '<form action="/failed"><button>Fail primary GET</button></form>',
        ),
      );
      await tester.pumpAndSettle();
      await clickSubmit(tester);

      final window = windows.active!;
      final cachedDocument = window.currentDocument!;
      final cachedEntry = window.history.single;
      final viewFinder = _documentViewFinder();
      final cachedViewState = tester.state<State>(viewFinder);
      expect(gateway.calls, hasLength(1));

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(window.index, -1);
      expect(window.canForward, isTrue);
      expect(find.text('Fail primary GET', findRichText: true), findsOneWidget);

      await _clickButtonAt(tester, 1);
      expect(gateway.calls, hasLength(2));
      expect(gateway.calls.last['url'], 'https://gateway.example/failed?');
      expect(window.index, -1);
      expect(window.error, isNotNull);
      expect(window.failedRequest?.method, 'GET');
      expect(window.canForward, isTrue);
      expect(tester.state<State>(viewFinder), same(cachedViewState));

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();

      expect(window.index, -1);
      expect(window.error, isNull);
      expect(window.failedRequest, isNull);
      expect(window.loading, isFalse);
      expect(window.history, hasLength(1));
      expect(window.history.single, same(cachedEntry));
      expect(window.currentDocument, isNull);
      expect(window.canForward, isTrue);
      expect(window.history.single.document, same(cachedDocument));
      expect(tester.state<State>(viewFinder), same(cachedViewState));
      expect(find.byType(NativeDocumentWorkspace), findsNothing);
      expect(find.byType(NativeHtmlButtonWidget), findsNWidgets(2));
      expect(gateway.calls, hasLength(2));
      expect(
        Navigator.of(tester.element(find.byKey(hostKey))).canPop(),
        isFalse,
      );

      await _pressAltArrow(tester, LogicalKeyboardKey.arrowRight);
      expect(window.index, 0);
      expect(window.currentDocument, same(cachedDocument));
      expect(tester.state<State>(viewFinder), same(cachedViewState));
      expect(gateway.calls, hasLength(2));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'fragment history restores each saved scroll offset without another request',
    (tester) async {
      final gateway = DocumentGateway()
        ..responses.add(
          response(
            '/page',
            '<title>Fragment page</title>'
                '<a href="#a">Go to A</a>'
                '${List.generate(2, (i) => '<p>before $i</p>').join()}'
                '<a href="#b">Go to B</a>'
                '${List.generate(60, (i) => '<p>row $i</p>').join()}'
                '<div id="a">Anchor A</div><div id="b">Anchor B</div>',
          ),
        );
      final windows = NativeDocumentWindows(gateway);
      addTearDown(windows.dispose);
      final hostKey = GlobalKey<NativeDocumentHostState>();
      await tester.pumpWidget(
        _hostedApp(
          gateway: gateway,
          windows: windows,
          hostKey: hostKey,
          source: '<form action="/page"><button>Open page</button></form>',
        ),
      );
      await tester.pumpAndSettle();
      await clickSubmit(tester);
      final window = windows.active!;
      final document = window.currentDocument!;

      await _tapTextWithoutScrolling(tester, 'Go to A');
      await tester.pumpAndSettle();
      final entryA = window.current!;
      expect(entryA.url, 'https://gateway.example/page#a');
      document.scroll.jumpTo(40);
      await tester.pumpAndSettle();
      final offsetA = document.scroll.offset;

      await _tapTextWithoutScrolling(tester, 'Go to B');
      await tester.pumpAndSettle();
      final entryB = window.current!;
      expect(entryB.url, 'https://gateway.example/page#b');
      expect(entryA.scrollOffset, closeTo(offsetA, 0.5));
      expect(document.scroll.position.maxScrollExtent, greaterThan(500));
      document.scroll.jumpTo(500);
      await tester.pumpAndSettle();
      final offsetB = document.scroll.offset;
      expect(offsetB, greaterThan(offsetA));
      expect(window.history, hasLength(3));
      expect(
        window.history.every((entry) => entry.document == document),
        isTrue,
      );
      final calls = gateway.calls.length;

      await hostKey.currentState!.back();
      final backFrames = await tester.pumpAndSettle();
      expect(
        backFrames,
        lessThan(20),
        reason: 'Ready layout must not wait for the bounded fallback.',
      );
      expect(
        document.viewport.lastFragmentDifference,
        isNot('history_layout_not_ready'),
      );
      expect(window.current, same(entryA));
      expect(document.scroll.offset, closeTo(offsetA, 0.5));
      expect(gateway.calls, hasLength(calls));

      await hostKey.currentState!.forward();
      final forwardFrames = await tester.pumpAndSettle();
      expect(
        forwardFrames,
        lessThan(20),
        reason: 'Ready layout must not wait for the bounded fallback.',
      );
      expect(
        document.viewport.lastFragmentDifference,
        isNot('history_layout_not_ready'),
      );
      expect(window.current, same(entryB));
      expect(document.scroll.offset, closeTo(offsetB, 0.5));
      expect(gateway.calls, hasLength(calls));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'document to Pirc route and back/forward restores App selection without HTTP',
    (tester) async {
      final gateway = DocumentGateway()
        ..responses.addAll([
          response(
            '/page',
            '<title>Native source</title><a href="/?open=memory">'
                'Open Pirc memory</a>',
          ),
          response('/?open=memory', _pircShell),
        ]);
      Object appState = 'source-app-state';
      String? appUrl = 'https://gateway.example/?session=source';
      final appliedRoutes = <NativeAppDocumentRoute>[];
      final restored = <Object>[];
      final windows = NativeDocumentWindows(
        gateway,
        onAppRoute: (route) async {
          appliedRoutes.add(route);
          appState = 'app-route:${route.canonicalUrl}';
          appUrl = route.canonicalUrl;
        },
        captureAppState: () => appState,
        restoreAppState: (state) async {
          restored.add(state);
          appState = state;
        },
        appDocumentUrl: () => appUrl,
      );
      addTearDown(windows.dispose);
      final hostKey = GlobalKey<NativeDocumentHostState>();
      await tester.pumpWidget(
        _hostedApp(
          gateway: gateway,
          windows: windows,
          hostKey: hostKey,
          source: '<form action="/page"><button>Open page</button></form>',
        ),
      );
      await tester.pumpAndSettle();
      await clickSubmit(tester);
      final window = windows.active!;
      final document = window.currentDocument!;
      final pageViewState = tester.state<State>(_documentViewFinder());
      final callsBeforeRoute = gateway.calls.length;

      await tapText(tester, 'Open Pirc memory');
      await tester.pumpAndSettle();
      expect(gateway.calls, hasLength(callsBeforeRoute + 1));
      expect(gateway.calls.last['url'], 'https://gateway.example/?open=memory');
      expect(window.history, hasLength(2));
      expect(window.currentDocument, isNull);
      expect(window.currentAppRoute, isNotNull);
      expect(
        window.history.last.appState,
        'app-route:https://gateway.example/?open=memory',
      );
      expect(appliedRoutes, hasLength(1));
      expect(appState, 'app-route:https://gateway.example/?open=memory');
      final routeEntry = window.current!;

      await hostKey.currentState!.back();
      await tester.pumpAndSettle();
      expect(window.currentDocument, same(document));
      expect(tester.state<State>(_documentViewFinder()), same(pageViewState));
      expect(gateway.calls, hasLength(callsBeforeRoute + 1));

      await hostKey.currentState!.forward();
      await tester.pumpAndSettle();
      expect(window.current, same(routeEntry));
      expect(window.currentAppRoute, same(routeEntry.appRoute));
      expect(window.currentDocument, isNull);
      expect(appState, 'app-route:https://gateway.example/?open=memory');
      expect(restored, ['app-route:https://gateway.example/?open=memory']);
      expect(appliedRoutes, hasLength(1));
      expect(gateway.calls, hasLength(callsBeforeRoute + 1));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('account invalidation removes the offstage document subtree', (
    tester,
  ) async {
    final gateway = DocumentGateway()
      ..responses.add(
        response('/page', '<title>Account document</title><p>Body</p>'),
      );
    final owner = LiveController(gateway)
      ..origin = 'https://gateway.example'
      ..clientId = 'client-one'
      ..pairingStamp = 'stamp';
    final windows = NativeDocumentWindows(gateway, owner: owner);
    addTearDown(() {
      windows.dispose();
      owner.dispose();
    });
    final hostKey = GlobalKey<NativeDocumentHostState>();
    await tester.pumpWidget(
      _hostedApp(
        gateway: gateway,
        windows: windows,
        hostKey: hostKey,
        source: '<form action="/page"><button>Open document</button></form>',
      ),
    );
    await tester.pumpAndSettle();
    await clickSubmit(tester);
    final window = windows.active!;
    final viewState = tester.state<State>(_documentViewFinder());

    await hostKey.currentState!.back();
    await tester.pumpAndSettle();
    expect(window.index, -1);
    expect(_documentViewFinder(), findsOneWidget);
    expect(viewState.mounted, isTrue);

    owner.origin = 'https://replacement.example';
    owner.changed();
    await tester.pumpAndSettle();

    expect(windows.windows, isEmpty);
    expect(window.disposed, isTrue);
    expect(viewState.mounted, isFalse);
    expect(_documentViewFinder(), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'new source document navigation truncates and disposes forward documents',
    (tester) async {
      final gateway = DocumentGateway()
        ..responses.addAll([
          response(
            '/one',
            '<title>Document one</title><a href="/two">Open two</a>',
          ),
          response('/two', '<title>Document two</title><p>Second</p>'),
          response('/three', '<title>Document three</title><p>Third</p>'),
        ]);
      final windows = NativeDocumentWindows(gateway);
      addTearDown(windows.dispose);
      final hostKey = GlobalKey<NativeDocumentHostState>();
      await tester.pumpWidget(
        _hostedApp(
          gateway: gateway,
          windows: windows,
          hostKey: hostKey,
          source:
              '<form action="/one"><button>Open one</button></form>'
              '<form action="/three"><button>Open three</button></form>',
        ),
      );
      await tester.pumpAndSettle();
      await clickSubmit(tester);
      final window = windows.active!;
      final firstDocument = window.history[0].document!;
      await tapText(tester, 'Open two');
      final removedForwardDocument = window.history[1].document!;
      expect(window.history, hasLength(2));

      await hostKey.currentState!.back();
      await tester.pumpAndSettle();
      await hostKey.currentState!.back();
      await tester.pumpAndSettle();
      expect(window.index, -1);
      expect(find.byType(NativeHtmlButtonWidget), findsNWidgets(2));

      await _clickButtonAt(tester, 1);

      expect(gateway.calls, hasLength(3));
      expect(gateway.calls.last['url'], 'https://gateway.example/three?');
      expect(window.history, hasLength(1));
      expect(window.currentDocument!.url, 'https://gateway.example/three');
      expect(window.canForward, isFalse);
      expect(() => firstDocument.scroll.addListener(() {}), throwsFlutterError);
      expect(
        () => removedForwardDocument.scroll.addListener(() {}),
        throwsFlutterError,
      );
      expect(tester.takeException(), isNull);
    },
  );
}
