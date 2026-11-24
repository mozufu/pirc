import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_mobile/live/common.dart';
import 'package:pirc_mobile/live/document_navigation.dart';
import 'package:pirc_mobile/live/document_navigation_state.dart';
import 'package:pirc_render/src/html_text_fields.dart';

import 'document_navigation_widget_test.dart'
    show DocumentGateway, clickSubmit, response;
import 'live_test.dart' show theme;
import 'native_html_test.dart' show tapText;

Widget _hostedApp({
  required DocumentGateway gateway,
  required NativeDocumentWindows windows,
  required GlobalKey<NativeDocumentHostState> hostKey,
  required Brightness brightness,
  required double textScale,
}) => MaterialApp(
  theme: theme.build(brightness),
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(
      context,
    ).copyWith(textScaler: TextScaler.linear(textScale)),
    child: child!,
  ),
  home: NativeDocumentScope(
    windows: windows,
    documentUrl: 'https://gateway.example/?session=source',
    sourceIdentity: windows.accountIdentity,
    child: NativeDocumentHost(
      key: hostKey,
      windows: windows,
      child: Scaffold(
        body: SingleChildScrollView(
          child: RichTextBody(
            '<form action="/posted" method="post">'
            '<button>Submit POST</button></form>',
            gateway: gateway,
          ),
        ),
      ),
    ),
  ),
);

void main() {
  testWidgets(
    'ERR_CACHE_MISS POST history stays readable and hides inactive content across layouts',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(390, 844);
      addTearDown(tester.view.reset);

      final post = response(
        '/posted',
        '<title>Uncacheable POST</title>'
            '<form><label>Old field '
            '<input name="secret" value="old-default"></label></form>'
            '<p>POST_ONLY_CONTENT_SENTINEL</p>'
            '<a href="/after">Continue to GET</a>',
        finalMethod: 'POST',
      )..['headersRelevant'] = <String, String>{'Cache-Control': 'no-store'};
      final gateway = DocumentGateway()
        ..responses.addAll([
          post,
          response('/after', '<title>After GET</title><p>GET_ONLY_CONTENT</p>'),
        ]);
      final windows = NativeDocumentWindows(
        gateway,
        appDocumentUrl: () => 'https://gateway.example/?session=source',
      );
      addTearDown(windows.dispose);
      final hostKey = GlobalKey<NativeDocumentHostState>();

      await tester.pumpWidget(
        _hostedApp(
          gateway: gateway,
          windows: windows,
          hostKey: hostKey,
          brightness: Brightness.light,
          textScale: 1,
        ),
      );
      await tester.pumpAndSettle();
      await clickSubmit(tester);

      final window = windows.active!;
      final postDocument = window.currentDocument!;
      final oldField = tester.widget<NativeHtmlTextFieldWidget>(
        find.byType(NativeHtmlTextFieldWidget),
      );
      final oldFocus = oldField.state.focusNodeFor(oldField.field.key);
      await tester.tap(find.byType(EditableText));
      await tester.pumpAndSettle();
      expect(oldFocus.hasFocus, isTrue);
      await tester.enterText(find.byType(EditableText), 'edited POST value');
      await tester.pumpAndSettle();
      expect(gateway.calls.single['method'], 'POST');

      await tapText(tester, 'Continue to GET');
      expect(window.currentDocument!.content.title, 'After GET');
      expect(gateway.calls.map((call) => call['method']), ['POST', 'GET']);

      expect(
        await window.traverseHistory(0),
        NativeDocumentLoadResult.committed,
      );
      await tester.pumpAndSettle();
      expect(window.historyPostResubmissionRequired, isTrue);
      expect(window.currentDocument, same(postDocument));
      expect(gateway.calls.map((call) => call['method']), ['POST', 'GET']);
      expect(find.text('ERR_CACHE_MISS'), findsOneWidget);
      expect(find.text("Confirm form resubmission"), findsOneWidget);
      expect(find.text('POST_ONLY_CONTENT_SENTINEL'), findsNothing);
      expect(find.text('GET_ONLY_CONTENT'), findsNothing);
      expect(find.byType(NativeHtmlTextFieldWidget), findsNothing);
      expect(find.byType(EditableText), findsNothing);
      expect(oldFocus.hasFocus, isFalse);

      const widths = [320.0, 360.0, 390.0, 430.0, 600.0, 768.0, 1024.0];
      for (final width in widths) {
        tester.view.physicalSize = Size(width, 844);
        for (final brightness in [Brightness.light, Brightness.dark]) {
          for (final scale in [1.0, 2.0]) {
            await tester.pumpWidget(
              _hostedApp(
                gateway: gateway,
                windows: windows,
                hostKey: hostKey,
                brightness: brightness,
                textScale: scale,
              ),
            );
            await tester.pumpAndSettle();

            final variant = 'width=$width brightness=$brightness scale=$scale';
            expect(
              find.text('ERR_CACHE_MISS'),
              findsOneWidget,
              reason: variant,
            );
            expect(
              find.text('POST_ONLY_CONTENT_SENTINEL'),
              findsNothing,
              reason: variant,
            );
            expect(
              find.byType(NativeHtmlTextFieldWidget),
              findsNothing,
              reason: variant,
            );
            expect(oldFocus.hasFocus, isFalse, reason: variant);

            final heading = tester.widget<Text>(
              find.text("Confirm form resubmission"),
            );
            expect(
              heading.style?.color,
              brightness == Brightness.dark
                  ? const Color(0xff9aa0a6)
                  : const Color(0xff202124),
              reason: variant,
            );
            final icon = find.byWidgetPredicate(
              (widget) =>
                  widget is CustomPaint &&
                  widget.painter.runtimeType.toString() ==
                      '_NativePostErrorIcon',
            );
            expect(icon, findsOneWidget, reason: variant);
            expect(tester.getSize(icon), const Size(72, 72), reason: variant);
            expect(tester.takeException(), isNull, reason: variant);
          }
        }
      }
    },
  );
}
