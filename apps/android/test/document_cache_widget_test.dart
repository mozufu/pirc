import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_mobile/live/document_navigation_state.dart';
import 'package:pirc_mobile/live/gateway.dart';
import 'package:pirc_render/src/html_controls.dart';
import 'package:pirc_render/src/html_select_widget.dart';
import 'document_navigation_widget_test.dart'
    show DocumentGateway, response, app, clickSubmit;

void main() {
  testWidgets(
    'toolbar conditional reload resets controls and replaces history like Chrome',
    (t) async {
      final reference = obj(
        jsonDecode(
          File(
            '../../fixtures/mobile-parity/document-cache-expected.json',
          ).readAsStringSync(),
        ),
      );
      final browser = rows(
        reference['cases'],
      ).firstWhere((c) => c['caseId'] == 'no-cache-etag-304');
      final defaults = obj(
        obj(obj(browser['reload'])['document'])['formState'],
      );
      final source = File(
        '../web/tool/parity/capture_document_cache_web.mjs',
      ).readAsStringSync();
      final form = RegExp(
        '<form id="state-probe">.*?</form>',
      ).firstMatch(source)!.group(0)!;
      final html = '<title>Cached form</title>$form';
      final gateway = DocumentGateway()
        ..responses.addAll([
          response('/cached', html)
            ..['headersRelevant'] = {
              'Cache-Control': 'no-cache',
              'ETag': '"v1"',
              'Vary': 'Origin',
            },
          response('/cached', '', status: 304, mime: 'application/octet-stream')
            ..['headersRelevant'] = {
              'Cache-Control': 'no-cache',
              'ETag': '"v1"',
              'Vary': 'Origin',
            },
          response('/cached', html.replaceAll('Cached form', 'Updated form'))
            ..['headersRelevant'] = {
              'Cache-Control': 'no-cache',
              'ETag': '"v2"',
              'Vary': 'Origin',
            },
        ]);
      final windows = NativeDocumentWindows(gateway);
      addTearDown(windows.dispose);
      await t.pumpWidget(
        app(
          gateway,
          windows,
          '<form action="/cached"><button>Open</button></form>',
        ),
      );
      await t.pumpAndSettle();
      await clickSubmit(t);
      final first = windows.active!.currentDocument!;
      final editors = find.byType(EditableText);
      await t.enterText(editors.at(0), 'edited text value');
      await t.enterText(editors.at(1), 'edited autocomplete off');
      await t.tap(find.byType(NativeHtmlControlWidget));
      await t.tap(find.byType(NativeHtmlSelectWidget));
      await t.pumpAndSettle();
      await t.tap(find.text('Two').last);
      await t.pumpAndSettle();
      final check = t.widget<NativeHtmlControlWidget>(
        find.byType(NativeHtmlControlWidget),
      );
      expect(check.state.isChecked(check.control.key), isTrue);
      final select = t.widget<NativeHtmlSelectWidget>(
        find.byType(NativeHtmlSelectWidget),
      );
      expect(select.state.selectedIndices(select.control.key), [1]);
      await t.tap(find.byTooltip("Reload"));
      await t.pumpAndSettle();
      expect(gateway.calls, hasLength(2));
      expect(gateway.calls.last['cacheMode'], 'revalidate');
      expect(gateway.calls.last['ifNoneMatch'], '"v1"');
      expect(windows.active!.history, hasLength(1));
      expect(windows.active!.currentDocument, isNot(same(first)));
      expect(windows.active!.currentDocument!.status, 200);
      expect(
        t.widget<EditableText>(editors.at(0)).controller.text,
        defaults['textValue'],
      );
      expect(
        t.widget<EditableText>(editors.at(1)).controller.text,
        defaults['autocompleteOffValue'],
      );
      final resetCheck = t.widget<NativeHtmlControlWidget>(
        find.byType(NativeHtmlControlWidget),
      );
      expect(
        resetCheck.state.isChecked(resetCheck.control.key),
        defaults['checkboxChecked'],
      );
      final resetSelect = t.widget<NativeHtmlSelectWidget>(
        find.byType(NativeHtmlSelectWidget),
      );
      expect(
        resetSelect
            .control
            .options[resetSelect.state
                .selectedIndices(resetSelect.control.key)
                .single]
            .value,
        defaults['selectValue'],
      );
      await t.tap(find.byTooltip("Reload"));
      await t.pumpAndSettle();
      expect(gateway.calls, hasLength(3));
      expect(windows.active!.history, hasLength(1));
      expect(windows.active!.currentDocument!.content.title, 'Updated form');
      expect(t.takeException(), isNull);
    },
  );
}
