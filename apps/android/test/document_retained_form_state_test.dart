import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_mobile/live/document_navigation_state.dart';
import 'package:pirc_mobile/live/gateway.dart';
import 'package:pirc_render/src/html_date.dart';
import 'package:pirc_render/src/html_controls.dart';
import 'package:pirc_render/src/html_range.dart';
import 'package:pirc_render/src/html_select_widget.dart';
import 'package:pirc_render/src/html_buttons.dart';
import 'package:pirc_render/src/html_file.dart';
import 'package:pirc_render/src/html_text_fields.dart';
import 'document_navigation_widget_test.dart'
    show DocumentGateway, response, app, clickSubmit;

class _FileGateway extends DocumentGateway {
  @override
  Future<dynamic> call(String method, [Json args = const {}]) {
    if (method == 'pickAttachments') {
      return Future.value([
        {
          'name': 'fixture.bin',
          'mimeType': 'application/octet-stream',
          'bytes': base64Encode([0, 127, 128, 255]),
        },
      ]);
    }
    return super.call(method, args);
  }
}

void main() {
  testWidgets(
    'retained history keeps live files, off dates, password and details',
    (tester) async {
      final gateway = _FileGateway()
        ..responses.addAll([
          response(
            '/retained',
            '<title>Retained source</title><form action="/next"><input name="date" type="date" autocomplete="off" value="2024-06-15"><input name="password" type="password" autocomplete="off" value="server"><input name="upload" type="file" required><input type="checkbox" name="check" autocomplete="off"><input type="radio" name="choice" value="a" checked autocomplete="off"><input type="radio" name="choice" value="b" autocomplete="off"><input type="range" name="range" value="10" autocomplete="off"><select name="select" autocomplete="off"><option value="a">A</option><option value="b">B</option></select><button>Next</button><button type="reset">Reset</button></form><details><summary>More</summary><p>Retained disclosure</p></details>',
          ),
          response('/next', '<title>Next page</title><p>Next page body</p>'),
        ]);
      final windows = NativeDocumentWindows(gateway);
      addTearDown(windows.dispose);
      await tester.pumpWidget(
        app(
          gateway,
          windows,
          '<form action="/retained"><button>Open</button></form>',
        ),
      );
      await tester.pumpAndSettle();
      await clickSubmit(tester);
      final date = tester.widget<NativeHtmlDateInput>(
        find.byType(NativeHtmlDateInput),
      );
      date.state.setValue(date.control.key, '2025-10-30');
      final checks = tester
          .widgetList<NativeHtmlControlWidget>(
            find.byType(NativeHtmlControlWidget),
          )
          .toList();
      checks.first.state.activateControl(checks.first.control.key);
      checks.last.state.activateControl(checks.last.control.key);
      final range = tester.widget<NativeHtmlRangeWidget>(
        find.byType(NativeHtmlRangeWidget),
      );
      range.state.setRangeValue(range.control.key, 73);
      final select = tester.widget<NativeHtmlSelectWidget>(
        find.byType(NativeHtmlSelectWidget),
      );
      select.state.select(select.control.key, 1);
      final password = find.byWidgetPredicate(
        (widget) =>
            widget is NativeHtmlTextFieldWidget &&
            widget.field.name == 'password',
      );
      await tester.enterText(
        find.descendant(of: password, matching: find.byType(EditableText)),
        'typed fixture password',
      );
      final fileFinder = find.byType(NativeHtmlFileInputWidget);
      await tester.ensureVisible(fileFinder);
      await tester.tap(fileFinder);
      await tester.pumpAndSettle();
      final file = tester.widget<NativeHtmlFileInputWidget>(fileFinder);
      final fileIdentity = file.state.widgetKeyFor(file.control.key);
      final fileFocus = file.state.focusNodeFor(file.control.key);
      final selectedFile = file.state.filesFor(file.control.key).single;
      expect(file.state.pickerErrorFor(file.control.key), isNull);
      expect(file.state.filesFor(file.control.key).single.bytes, [
        0,
        127,
        128,
        255,
      ]);
      await tester.ensureVisible(
        find.byWidgetPredicate(
          (widget) =>
              widget is RichText && widget.text.toPlainText().contains('More'),
        ),
      );
      await tester.tap(
        find.byWidgetPredicate(
          (widget) =>
              widget is RichText && widget.text.toPlainText().contains('More'),
        ),
      );
      await tester.pumpAndSettle();
      final retained = windows.active!.currentDocument;
      await clickSubmit(tester);
      expect(windows.active!.currentDocument, isNot(same(retained)));
      expect(gateway.calls, hasLength(2));
      await tester.tap(find.byTooltip("Back"));
      await tester.pumpAndSettle();
      expect(windows.active!.currentDocument, same(retained));
      expect(
        gateway.calls,
        hasLength(2),
        reason: 'A retained GET Document does not fetch again',
      );
      final restoredFile = tester.widget<NativeHtmlFileInputWidget>(fileFinder);
      // Updating live disclosure attributes reparses markup. The per-source
      // registry may change; the actual control, selection and focus survive.
      expect(
        restoredFile.state.widgetKeyFor(restoredFile.control.key),
        same(fileIdentity),
      );
      expect(
        restoredFile.state.focusNodeFor(restoredFile.control.key),
        same(fileFocus),
      );
      expect(
        restoredFile.state.filesFor(restoredFile.control.key).single,
        same(selectedFile),
      );
      expect(
        restoredFile.state.filesFor(restoredFile.control.key).single.bytes,
        [0, 127, 128, 255],
      );
      final restoredDate = tester.widget<NativeHtmlDateInput>(
        find.byType(NativeHtmlDateInput),
      );
      expect(
        restoredDate.state.valueFor(restoredDate.control.key),
        '2025-10-30',
      );
      final restoredPassword = tester.widget<NativeHtmlTextFieldWidget>(
        password,
      );
      expect(
        restoredPassword.state.valueFor(restoredPassword.field.key),
        'typed fixture password',
      );
      expect(
        find.text('Retained disclosure', findRichText: true),
        findsOneWidget,
      );
      final restoredChecks = tester
          .widgetList<NativeHtmlControlWidget>(
            find.byType(NativeHtmlControlWidget),
          )
          .toList();
      expect(
        restoredChecks.first.state.isChecked(restoredChecks.first.control.key),
        isTrue,
      );
      expect(
        restoredChecks.last.state.isChecked(restoredChecks.last.control.key),
        isTrue,
      );
      final restoredRange = tester.widget<NativeHtmlRangeWidget>(
        find.byType(NativeHtmlRangeWidget),
      );
      expect(restoredRange.state.valueFor(restoredRange.control.key), '73');
      final restoredSelect = tester.widget<NativeHtmlSelectWidget>(
        find.byType(NativeHtmlSelectWidget),
      );
      expect(restoredSelect.state.valueFor(restoredSelect.control.key), 'b');
      final reset = find.byType(NativeHtmlButtonWidget).last;
      await tester.ensureVisible(reset);
      await tester.tap(reset);
      await tester.pumpAndSettle();
      expect(
        restoredDate.state.valueFor(restoredDate.control.key),
        '2024-06-15',
      );
      expect(
        restoredPassword.state.valueFor(restoredPassword.field.key),
        'server',
      );
      expect(restoredFile.state.filesFor(restoredFile.control.key), isEmpty);
      expect(
        restoredChecks.first.state.isChecked(restoredChecks.first.control.key),
        isFalse,
      );
      expect(
        restoredChecks[1].state.isChecked(restoredChecks[1].control.key),
        isTrue,
      );
      expect(
        restoredChecks.last.state.isChecked(restoredChecks.last.control.key),
        isFalse,
      );
      expect(restoredRange.state.valueFor(restoredRange.control.key), '10');
      expect(restoredSelect.state.valueFor(restoredSelect.control.key), 'a');
      expect(tester.takeException(), isNull);
    },
  );
}
