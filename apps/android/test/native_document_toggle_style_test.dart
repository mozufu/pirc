import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_mobile/live/document_navigation.dart';
import 'package:pirc_mobile/live/document_navigation_state.dart';
import 'package:pirc_render/src/html_controls.dart';
import 'package:pirc_render/src/html_form_submission.dart';
import 'live_test.dart' show theme;
import 'native_html_test.dart' show tapText;
import 'document_navigation_widget_test.dart' show DocumentGateway, response;

void main() {
  testWidgets(
    'CSS sized toggles preserve single activation, labels and radio keyboard groups',
    (tester) async {
      const source =
          '''<!doctype html><html><head><style>body{margin:0}input{width:70px;height:40px;padding:0;margin:0;border:0}</style></head><body>
    <input id="check" type="checkbox"><label for="check">Check label</label>
    <input type="radio" name="choice" checked aria-label="One"><input type="radio" name="choice" aria-label="Two">
    </body></html>''';
      final gateway = DocumentGateway()
            ..responses.add(response('/toggles', source)),
          windows = NativeDocumentWindows(gateway),
          window = windows.target(
            'toggles',
            null,
            sourceUrl: 'https://gateway.example/',
          );
      addTearDown(windows.dispose);
      await window.load(
        const NativeHtmlFormRequest(url: '/toggles', method: 'GET', target: ''),
        baseUrl: window.sourceUrl,
      );
      windows.select(window);
      await tester.pumpWidget(
        MaterialApp(
          theme: theme.build(Brightness.light),
          home: NativeDocumentWorkspace(windows: windows),
        ),
      );
      await tester.pumpAndSettle();
      final controls = tester
          .widgetList<NativeHtmlControlWidget>(
            find.byType(NativeHtmlControlWidget),
          )
          .toList();
      expect(controls, hasLength(3));
      for (final control in controls) {
        expect(tester.getSize(find.byWidget(control)), const Size(70, 40));
      }
      final check = controls.first, first = controls[1], second = controls[2];
      expect(check.state.isChecked(check.control.key), isFalse);
      await tester.tap(find.byWidget(check));
      await tester.pumpAndSettle();
      expect(
        check.state.isChecked(check.control.key),
        isTrue,
        reason: 'one pointer activation',
      );
      expect(
        check.state.focusNodeFor(check.control.key)!.hasPrimaryFocus,
        isTrue,
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pumpAndSettle();
      expect(
        check.state.isChecked(check.control.key),
        isFalse,
        reason: 'one keyboard activation',
      );
      await tapText(tester, 'Check label');
      await tester.pumpAndSettle();
      expect(
        check.state.isChecked(check.control.key),
        isTrue,
        reason: 'associated label keeps its native target',
      );
      await tester.tap(find.byWidget(first));
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pumpAndSettle();
      expect(first.state.isChecked(first.control.key), isFalse);
      expect(second.state.isChecked(second.control.key), isTrue);
      expect(
        second.state.focusNodeFor(second.control.key)!.hasPrimaryFocus,
        isTrue,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    },
  );
}
