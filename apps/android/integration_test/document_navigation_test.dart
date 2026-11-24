import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:pirc_mobile/live/app_document_route.dart';
import 'package:pirc_mobile/live/common.dart';
import 'package:pirc_mobile/live/document_navigation.dart';
import 'package:pirc_mobile/live/document_navigation_state.dart';
import 'package:pirc_mobile/live/gateway.dart';
import 'package:pirc_render/src/html_buttons.dart';
import 'package:pirc_render/src/html_controls.dart';
import 'package:pirc_render/src/html_form_submission.dart';
import 'package:pirc_render/src/html_text_fields.dart';
import 'package:pirc_mobile/theme.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('real Android document POST, response rendering, history and empty replies', (
    t,
  ) async {
    expect(const bool.fromEnvironment('PIRC_REAL_GATEWAY'), isTrue);
    expect(const bool.fromEnvironment('PIRC_DOCUMENTS'), isTrue);
    final gateway = Gateway();
    await gateway.call('pair', {
      'link': const String.fromEnvironment('PIRC_PAIR_LINK'),
    });
    await gateway.call('completeOnboarding');
    final boot = obj(await gateway.call('boot'));
    final theme = await PircTheme.load();
    final owner = LiveController(gateway);
    owner.origin = boot['origin'] as String?;
    owner.pairingStamp = boot['pairingStamp'] as String?;
    final appRoutes = <NativeAppDocumentRoute>[];
    final windows = NativeDocumentWindows(
      gateway,
      owner: owner,
      onAppRoute: (route) async {
        appRoutes.add(route);
      },
    );
    Future<void> until(bool Function() ready, String label) async {
      for (var i = 0; i < 150 && !ready(); i++) {
        await t.pump(const Duration(milliseconds: 200));
      }
      expect(ready(), isTrue, reason: label);
      await t.pumpAndSettle();
      expect(t.takeException(), isNull, reason: label);
    }

    Future<void> press() async {
      final button = find.byType(NativeHtmlButtonWidget).first;
      await t.ensureVisible(button);
      await t.pumpAndSettle();
      await t.tap(button);
      await t.pump();
    }

    final managedHost = GlobalKey<NativeDocumentHostState>();
    Widget page(String source, {bool managed = false}) {
      final body = Scaffold(
        body: SingleChildScrollView(
          child: RichTextBody(source, gateway: gateway),
        ),
      );
      return MaterialApp(
        theme: theme.build(Brightness.light),
        home: NativeDocumentScope(
          windows: windows,
          documentUrl: '${boot['origin']}/?session=test',
          sourceIdentity: windows.accountIdentity,
          child: managed
              ? NativeDocumentHost(
                  key: managedHost,
                  windows: windows,
                  child: body,
                )
              : body,
        ),
      );
    }

    Future<List<dynamic>> receipts() async {
      final reply = obj(
        await gateway.call('document', {
          'url': '${boot['origin']}/parity-documents/receipt',
          'method': 'GET',
          'pairingStamp': boot['pairingStamp'],
        }),
      );
      expect(reply['status'], 200);
      return obj(
            jsonDecode(utf8.decode(reply['bytes'] as Uint8List)),
          )['requests']
          as List<dynamic>;
    }

    try {
      final initialReceiptCount = (await receipts()).length;
      await t.pumpWidget(
        page(
          '<form action="/parity-documents/echo" method="post"><input name="message" value="Initial"><button>Send</button></form>',
        ),
      );
      await t.pumpAndSettle();
      await t.enterText(find.byType(EditableText), '城市 台北 ~ + &');
      await press();
      await until(
        () => find.text('Echo document').evaluate().isNotEmpty,
        'native response opens',
      );
      expect(find.byType(NativeDocumentWorkspace), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(NativeDocumentWorkspace),
          matching: find.text('城市 台北 ~ + &', findRichText: true),
        ),
        findsOneWidget,
      );
      await t.enterText(find.byType(EditableText), 'response edited');
      await press();
      await until(
        () => find.text('Next document').evaluate().isNotEmpty,
        'relative response form loads',
      );
      await t.tap(find.byTooltip('返回'));
      await t.pumpAndSettle();
      expect(
        t.widget<EditableText>(find.byType(EditableText)).controller.text,
        'response edited',
      );
      await t.tap(find.byTooltip('下一頁'));
      await t.pumpAndSettle();
      final submitted = (await receipts()).skip(initialReceiptCount).toList();
      expect(
        submitted,
        hasLength(2),
        reason: 'Back and forward must not replay either POST',
      );
      expect(submitted.map((r) => obj(r)['method']), ['POST', 'POST']);
      expect(submitted.map((r) => obj(r)['path']), [
        '/parity-documents/echo',
        '/parity-documents/next',
      ]);
      expect(
        obj(submitted[0])['body'],
        'message=%E5%9F%8E%E5%B8%82+%E5%8F%B0%E5%8C%97+%7E+%2B+%26',
      );
      expect(obj(submitted[1])['body'], 'message=response+edited');
      for (final request in submitted) {
        expect(
          obj(request)['contentType'],
          'application/x-www-form-urlencoded',
        );
      }
      await t.tap(find.byTooltip('關閉頁面'));
      await t.pumpAndSettle();
      expect(
        t.widget<EditableText>(find.byType(EditableText)).controller.text,
        '城市 台北 ~ + &',
      );
      for (final status in [204, 205]) {
        await t.pumpWidget(
          page(
            '<form action="/parity-documents/empty$status" method="post"><input name="message" value="Kept $status"><button>Send</button></form>',
          ),
        );
        await t.pumpAndSettle();
        await press();
        await until(
          () => windows.windows.every((w) => !w.loading),
          'empty$status completes',
        );
        expect(find.byType(NativeDocumentWorkspace), findsNothing);
        expect(
          t.widget<EditableText>(find.byType(EditableText)).controller.text,
          'Kept $status',
        );
      }
      await t.pumpWidget(
        page(
          '<form action="/parity-documents/styles"><button>Styled</button></form>',
        ),
      );
      await t.pumpAndSettle();
      await press();
      await until(
        () => find.text('Raw CSS response').evaluate().isNotEmpty,
        'native CSS response opens',
      );
      final styled = windows.active!.current!.document!;
      expect(
        styled.stylesheets,
        hasLength(4),
        reason: 'Two external sheets, head style and a relative imported sheet',
      );
      expect(styled.styleDiagnostics, isEmpty);
      final colorProbe = t
          .widgetList<RichText>(find.byType(RichText))
          .singleWhere(
            (r) => r.text.toPlainText() == 'Source order and import',
          );
      expect(
        colorProbe.text.style!.color,
        const Color.fromRGBO(70, 80, 90, 1),
        reason: 'Last external CSS actually paints in Flutter',
      );
      final styleRequests = (await receipts())
          .where(
            (r) => '${obj(r)['path']}'.startsWith('/parity-documents/css/'),
          )
          .toList();
      expect(styleRequests.map((r) => obj(r)['path']), [
        '/parity-documents/css/base.css',
        '/parity-documents/css/later.css',
        '/parity-documents/css/nested/imported.css',
      ]);
      expect(styleRequests.every((r) => obj(r)['method'] == 'GET'), isTrue);
      expect(
        styleRequests.every((r) => obj(r)['accept'] == 'text/css,*/*;q=0.1'),
        isTrue,
      );
      await t.tap(find.byTooltip('關閉頁面'));
      await t.pumpAndSettle();
      await t.pumpWidget(
        page(
          '<form action="/parity-documents/control-styles"><button>Controls</button></form>',
        ),
      );
      await t.pumpAndSettle();
      await press();
      await until(
        () => find.text('Raw form control styles').evaluate().isNotEmpty,
        'native styled control document opens',
      );
      final controlFields = t
          .widgetList<NativeHtmlTextFieldWidget>(
            find.byType(NativeHtmlTextFieldWidget),
          )
          .toList();
      expect(controlFields, hasLength(12));
      final inherited = controlFields.singleWhere(
        (f) => f.field.name == 'plain',
      );
      expect(inherited.textStyle.fontFamily, 'Arial');
      expect(inherited.textStyle.fontSize, 12);
      expect(inherited.boxStyle, isNotNull);
      final editor = find.descendant(
        of: find.byWidget(inherited),
        matching: find.byType(EditableText),
      );
      await t.ensureVisible(editor);
      await t.pumpAndSettle();
      await t.enterText(editor, 'Native CSS edit');
      expect(inherited.state.valueFor(inherited.field.key), 'Native CSS edit');
      expect(t.takeException(), isNull);
      await t.tap(find.byTooltip('關閉頁面'));
      await t.pumpAndSettle();
      final routeProbeReceiptStart = (await receipts()).length;

      var callbackCount = appRoutes.length;
      await t.pumpWidget(
        page(
          '<form action="/parity-documents/app-shell" method="get"><input type="hidden" name="session" value="real-session"><button>Open Pirc session</button></form>',
        ),
      );
      await t.pumpAndSettle();
      await press();
      await until(
        () => appRoutes.length == callbackCount + 1,
        'GET Pirc shell returns to the App route callback',
      );
      expect(appRoutes.last.target, isA<NativeAppSessionRouteTarget>());
      expect(
        (appRoutes.last.target! as NativeAppSessionRouteTarget).sessionId,
        'real-session',
      );
      expect(find.byType(NativeDocumentWorkspace), findsNothing);

      callbackCount = appRoutes.length;
      await t.pumpWidget(
        page(
          '<form action="/parity-documents/app-shell" method="post"><input name="probe" value="direct post"><button>POST app shell</button></form>',
        ),
      );
      await t.pumpAndSettle();
      await press();
      await until(
        () => find.byType(NativeDocumentWorkspace).evaluate().isNotEmpty,
        'POST app shell remains a native document reload',
      );
      expect(appRoutes.length, callbackCount);
      await t.tap(find.byTooltip('關閉頁面'));
      await t.pumpAndSettle();

      callbackCount = appRoutes.length;
      await t.pumpWidget(
        page(
          '<form action="/parity-documents/app-redirect303" method="post"><input name="probe" value="redirect body"><button>POST redirect to app shell</button></form>',
        ),
      );
      await t.pumpAndSettle();
      await press();
      await until(
        () => appRoutes.length == callbackCount + 1,
        '303 POST redirect to a GET Pirc shell returns to App',
      );
      expect(appRoutes.last.target, isA<NativeAppSchedulesRouteTarget>());
      expect(
        (appRoutes.last.target! as NativeAppSchedulesRouteTarget).scheduleId,
        'real-route',
      );
      expect(
        appRoutes.last.canonicalUrl,
        contains('/parity-documents/app-shell?'),
      );
      expect(find.byType(NativeDocumentWorkspace), findsNothing);

      callbackCount = appRoutes.length;
      await t.pumpWidget(
        page(
          '<form action="/parity-documents/deep/reports" method="get"><input type="hidden" name="session" value="deep-session"><input type="hidden" name="trace" value="kept"><button>Open deep Pirc route</button></form>',
        ),
      );
      await t.pumpAndSettle();
      await press();
      await until(
        () => appRoutes.length == callbackCount + 1,
        'GET deep SPA fallback preserves route query',
      );
      expect(appRoutes.last.isSpaFallbackPath, isTrue);
      expect(
        appRoutes.last.canonicalUrl,
        contains(
          '/parity-documents/deep/reports?session=deep-session&trace=kept',
        ),
      );
      expect(appRoutes.last.target, isA<NativeAppSessionRouteTarget>());
      expect(
        (appRoutes.last.target! as NativeAppSessionRouteTarget).sessionId,
        'deep-session',
      );
      expect(find.byType(NativeDocumentWorkspace), findsNothing);

      final routeRequests = (await receipts())
          .skip(routeProbeReceiptStart)
          .map(obj)
          .toList();
      expect(routeRequests, hasLength(5));
      expect(routeRequests.map((request) => request['method']), [
        'GET',
        'POST',
        'POST',
        'GET',
        'GET',
      ]);
      expect(routeRequests.map((request) => request['path']), [
        '/parity-documents/app-shell?session=real-session',
        '/parity-documents/app-shell',
        '/parity-documents/app-redirect303',
        '/parity-documents/app-shell?open=schedules&schedule=real-route',
        '/parity-documents/deep/reports?session=deep-session&trace=kept',
      ]);
      expect(routeRequests.map((request) => request['body']), [
        '',
        'probe=direct+post',
        'probe=redirect+body',
        '',
        '',
      ]);
      expect(
        routeRequests[1]['contentType'],
        'application/x-www-form-urlencoded',
      );
      expect(
        routeRequests[2]['contentType'],
        'application/x-www-form-urlencoded',
      );

      for (final window in windows.windows.toList()) {
        windows.close(window);
      }
      final cachedReceiptStart = (await receipts()).length;
      await t.pumpWidget(
        page(
          '<form action="/parity-documents/echo" method="post"><input name="message" value="cached source"><button>Cache native response</button></form>',
          managed: true,
        ),
      );
      await t.pumpAndSettle();
      await press();
      await until(
        () => find.byType(NativeFetchedDocumentView).evaluate().isNotEmpty,
        'managed native document opens',
      );
      final cachedWindow = windows.active!;
      final cachedView = t.state(find.byType(NativeFetchedDocumentView));
      final cachedEditor = t
          .widget<EditableText>(find.byType(EditableText))
          .controller;
      await t.enterText(find.byType(EditableText), 'Android cached edit');
      await t.pumpAndSettle();
      await managedHost.currentState!.back();
      await t.pumpAndSettle();
      expect(cachedWindow.index, -1);
      expect(find.byType(NativeDocumentWorkspace), findsNothing);
      await managedHost.currentState!.forward();
      await t.pumpAndSettle();
      expect(cachedWindow.index, 0);
      expect(
        t.state(find.byType(NativeFetchedDocumentView)),
        isNot(same(cachedView)),
      );
      expect(
        t.widget<EditableText>(find.byType(EditableText)).controller,
        isNot(same(cachedEditor)),
      );
      expect(
        t.widget<EditableText>(find.byType(EditableText)).controller.text,
        'Android cached edit',
      );
      expect(
        (await receipts()).length - cachedReceiptStart,
        1,
        reason: 'Back/forward must not replay this POST',
      );
      expect(t.takeException(), isNull);
      await managedHost.currentState!.back();
      await t.pumpAndSettle();

      for (final window in windows.windows.toList()) {
        windows.close(window);
      }
      final validationReceiptStart = (await receipts()).length;
      await t.pumpWidget(
        page(
          '<form action="/parity-documents/cache" method="get"><button>Open cache fixture</button></form>',
          managed: true,
        ),
      );
      await t.pumpAndSettle();
      await press();
      await until(
        () =>
            windows.active?.currentDocument?.url.contains(
              '/parity-documents/cache',
            ) ==
            true,
        'cache fixture document opens',
      );
      final validationWindow = windows.active!;
      final originalDocument = validationWindow.currentDocument!;
      final originalHistoryLength = validationWindow.history.length;
      final cacheInputWidget = t.widget<EditableText>(
        find.byType(EditableText),
      );
      expect(cacheInputWidget.controller.text, 'server default');
      await t.enterText(find.byType(EditableText), 'Native cache edit');
      await t.pumpAndSettle();
      expect(
        t.widget<EditableText>(find.byType(EditableText)).controller.text,
        'Native cache edit',
      );

      await t.tap(find.byTooltip('重新載入'));
      await t.pump();
      await until(
        () =>
            !validationWindow.loading &&
            validationWindow.currentDocument?.id != originalDocument.id,
        'toolbar reload replaces the current document from a 304 cache hit',
      );
      expect(validationWindow.currentDocument, isNot(same(originalDocument)));
      expect(validationWindow.history.length, originalHistoryLength);
      expect(
        t.widget<EditableText>(find.byType(EditableText)).controller.text,
        'server default',
        reason:
            'Reload restores the input value from the cached representation.',
      );

      final validationRequests = (await receipts())
          .skip(validationReceiptStart)
          .map(obj)
          .where(
            (request) =>
                '${request['path']}'.startsWith('/parity-documents/cache'),
          )
          .toList();
      expect(validationRequests, hasLength(2));
      expect(validationRequests.map((request) => request['method']), [
        'GET',
        'GET',
      ]);
      expect(validationRequests.map((request) => request['responseStatus']), [
        200,
        304,
      ]);
      expect(validationRequests[1]['ifNoneMatch'], '"native-cache-v1"');
      expect(
        validationRequests[1]['ifModifiedSince'],
        'Wed, 21 Oct 2015 07:28:00 GMT',
      );
      expect(validationRequests[1]['cacheControl'], 'max-age=0');
      expect(validationRequests[1]['pragma'], '');
      expect(
        validationRequests.every((request) => request['body'] == ''),
        isTrue,
        reason: 'GET revalidation must not replay a form POST.',
      );
      await t.tap(find.byTooltip('關閉頁面'));
      await t.pumpAndSettle();
      for (final window in windows.windows.toList()) {
        windows.close(window);
      }

      // Exercise the actual touch entry, not a direct model selection. Both
      // responses pass through Android transport and the local real Gateway.
      final touchRequestStart = (await receipts()).length;
      await t.pumpWidget(page('<p>Main App touch source</p>', managed: true));
      await t.pumpAndSettle();
      final opener = windows.target('', null, sourceUrl: '${boot['origin']}/');
      await opener.load(
        const NativeHtmlFormRequest(
          url: '/parity-documents/next',
          method: 'GET',
          target: '',
        ),
        baseUrl: '${boot['origin']}/',
      );
      final child = windows.target(
        'touch-child',
        opener,
        sourceUrl: opener.current!.url,
      );
      await child.load(
        const NativeHtmlFormRequest(
          url: '/parity-documents/cache',
          method: 'GET',
          target: 'touch-child',
        ),
        baseUrl: '${boot['origin']}/',
      );
      await managedHost.currentState!.selectWindow(child);
      await t.pumpAndSettle();
      final childDocument = child.currentDocument;
      await t.enterText(
        find.byType(EditableText),
        'Retain through touch switch',
      );
      await t.tap(find.byTooltip('App 視窗'));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('document-window-source-select')));
      await t.pumpAndSettle();
      expect(windows.active, isNull);
      expect(
        find.text('Main App touch source', findRichText: true),
        findsOneWidget,
      );
      expect(child.currentDocument, same(childDocument));
      final sourceContext = t.element(
        find.text('Main App touch source', findRichText: true),
      );
      final manager = showNativeDocumentWindowManager(
        sourceContext,
        windows,
        managedHost.currentState!,
      );
      await t.pumpAndSettle();
      final selectChild = find.byKey(Key('document-window-select-${child.id}'));
      await t.ensureVisible(selectChild);
      await t.tap(selectChild);
      await t.pumpAndSettle();
      await manager;
      expect(windows.active, same(child));
      expect(
        t.widget<EditableText>(find.byType(EditableText)).controller.text,
        'Retain through touch switch',
      );
      await t.tap(find.byTooltip('關閉頁面'));
      await t.pumpAndSettle();
      expect(windows.active, same(opener));
      expect(child.disposed, isTrue);
      final touchRequests = (await receipts())
          .skip(touchRequestStart)
          .map(obj)
          .toList();
      expect(touchRequests, hasLength(2));
      expect(touchRequests.every((r) => r['method'] == 'GET'), isTrue);
      await managedHost.currentState!.selectWindow(null);
      await t.pumpAndSettle();
      for (final window in windows.windows.toList()) {
        windows.close(window);
      }

      final namedReceiptStart = (await receipts()).length;
      final named = windows.target(
        'android-history',
        null,
        sourceUrl: '${boot['origin']}/',
      );
      await named.load(
        const NativeHtmlFormRequest(
          url: '/parity-documents/named-history',
          method: 'GET',
          target: '',
        ),
        baseUrl: '${boot['origin']}/',
      );
      await managedHost.currentState!.selectWindow(named);
      await t.pumpAndSettle();
      final firstNamedDocument = named.currentDocument!;
      NativeHtmlTextFieldWidget field(String name) => t
          .widgetList<NativeHtmlTextFieldWidget>(
            find.byType(NativeHtmlTextFieldWidget),
          )
          .singleWhere((widget) => widget.field.name == name);
      String fieldValue(String name) {
        final widget = field(name);
        return widget.state.controllerFor(widget.field.key).text;
      }

      Future<void> editField(String name, String value) async {
        final widget = field(name);
        final editor = find.descendant(
          of: find.byWidget(widget),
          matching: find.byType(EditableText),
        );
        await t.ensureVisible(editor);
        await t.enterText(editor, value);
        await t.pumpAndSettle();
      }

      await editField('text', 'Android saved edit');
      await editField('controlOff', 'Must reset autocomplete off');
      await editField('password', 'Must reset password');
      await editField('revertedText', 'temporary edit');
      await editField('revertedText', 'revert server-v1');
      FocusManager.instance.primaryFocus?.unfocus();
      await t.pumpAndSettle();
      firstNamedDocument.scroll.jumpTo(620);
      await t.pumpAndSettle();
      final savedOffset = firstNamedDocument.scroll.offset;
      await named.load(
        const NativeHtmlFormRequest(
          url: '/parity-documents/named-history-next',
          method: 'GET',
          target: '',
        ),
        baseUrl: '${boot['origin']}/',
      );
      await t.pumpAndSettle();
      await t.tap(find.byTooltip('返回'));
      await t.pump();
      await until(
        () =>
            !named.loading &&
            named.index == 0 &&
            named.currentDocument != firstNamedDocument,
        'named Back fetches a new server-v2 document',
      );
      expect(named.history, hasLength(2));
      expect(
        named.currentDocument!.content.text,
        contains('Response server-v2'),
      );
      expect(fieldValue('text'), 'Android saved edit');
      expect(fieldValue('controlOff'), 'control off server server-v2');
      expect(fieldValue('password'), 'password server server-v2');
      expect(fieldValue('revertedText'), 'revert server-v2');
      expect(fieldValue('untouchedText'), 'untouched server-v2');
      expect(named.currentDocument!.scroll.offset, closeTo(savedOffset, .5));
      final untouchedCheck = t
          .widgetList<NativeHtmlControlWidget>(
            find.byType(NativeHtmlControlWidget),
          )
          .singleWhere(
            (widget) => widget.control.label == 'Untouched checkbox',
          );
      expect(
        untouchedCheck.state.isChecked(untouchedCheck.control.key),
        isTrue,
      );
      expect(untouchedCheck.control.checked, isFalse);
      await t.tap(find.byTooltip('下一頁'));
      await t.pump();
      await until(
        () => !named.loading && named.index == 1,
        'named Forward fetches the next GET',
      );
      final namedRequests = (await receipts())
          .skip(namedReceiptStart)
          .map(obj)
          .toList();
      expect(namedRequests.map((request) => request['path']), [
        '/parity-documents/named-history',
        '/parity-documents/named-history-next',
        '/parity-documents/named-history',
        '/parity-documents/named-history-next',
      ]);
      expect(
        namedRequests.every((request) => request['method'] == 'GET'),
        isTrue,
      );
      expect(namedRequests[2]['cacheControl'], '');
      expect(namedRequests[2]['pragma'], '');
      await managedHost.currentState!.closeWindow(named);
      await t.pumpAndSettle();

      final postReceiptStart = (await receipts()).length;
      final postWindow = windows.target(
        '_blank',
        null,
        sourceUrl: '${boot['origin']}/',
      );
      await postWindow.load(
        const NativeHtmlFormRequest(
          url: '/parity-documents/post-no-store',
          method: 'POST',
          target: '',
          body: 'once=true',
          contentType: 'application/x-www-form-urlencoded',
        ),
        baseUrl: '${boot['origin']}/',
      );
      await postWindow.load(
        const NativeHtmlFormRequest(
          url: '/parity-documents/named-history-next',
          method: 'GET',
          target: '',
        ),
        baseUrl: '${boot['origin']}/',
      );
      await managedHost.currentState!.selectWindow(postWindow);
      await t.pumpAndSettle();
      await t.tap(find.byTooltip('返回'));
      await t.pumpAndSettle();
      expect(postWindow.historyPostResubmissionRequired, isTrue);
      expect(find.text('確認重新提交表單'), findsOneWidget);
      expect(find.text('ERR_CACHE_MISS'), findsOneWidget);
      expect(find.text('Submitted data', findRichText: true), findsNothing);
      var postRequests = (await receipts())
          .skip(postReceiptStart)
          .map(obj)
          .toList();
      expect(postRequests.map((request) => request['method']), ['POST', 'GET']);
      await t.tap(find.byTooltip('重新載入'));
      await t.pumpAndSettle();
      expect(find.text('重新送出表單？'), findsOneWidget);
      await t.tap(find.text('取消'));
      await t.pumpAndSettle();
      expect(postWindow.historyPostResubmissionRequired, isTrue);
      await t.tap(find.byTooltip('重新載入'));
      await t.pumpAndSettle();
      await t.tap(find.text('重新送出'));
      await t.pump();
      await until(
        () =>
            !postWindow.loading && !postWindow.historyPostResubmissionRequired,
        'explicit confirmation replays the saved POST',
      );
      postRequests = (await receipts())
          .skip(postReceiptStart)
          .map(obj)
          .toList();
      expect(postRequests.map((request) => request['method']), [
        'POST',
        'GET',
        'POST',
      ]);
      expect(postRequests.last['body'], 'once=true');
      expect(postWindow.history, hasLength(2));
      await managedHost.currentState!.closeWindow(postWindow);
      await t.pumpAndSettle();

      for (final endpoint in ['devices', 'providers', 'provider-auth']) {
        final forbidden = obj(
          await gateway.call('document', {
            'url': '${boot['origin']}/api/$endpoint',
            'method': 'GET',
            'pairingStamp': boot['pairingStamp'],
          }),
        );
        expect(
          forbidden['status'],
          403,
          reason: 'Device bearer cannot gain browser $endpoint privileges',
        );
      }
      expect(t.takeException(), isNull);
    } finally {
      await t.pumpWidget(const SizedBox());
      windows.dispose();
      owner.dispose();
      await gateway.call('unpair');
    }
  });
}
