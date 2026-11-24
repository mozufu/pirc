import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_mobile/live/document_navigation.dart';
import 'package:pirc_mobile/live/document_navigation_state.dart';
import 'package:pirc_render/src/html_buttons.dart';
import 'package:pirc_render/src/html_controls.dart';
import 'package:pirc_render/src/html_date.dart';
import 'package:pirc_render/src/html_file.dart';
import 'package:pirc_render/src/html_form_submission.dart';
import 'package:pirc_render/src/html_range.dart';
import 'package:pirc_render/src/html_select_widget.dart';
import 'package:pirc_render/src/html_text_fields.dart';
import 'package:pirc_render/src/native_html.dart';
import 'document_navigation_widget_test.dart' show DocumentGateway, response;
import 'live_test.dart' show theme;

class LifetimeGateway extends DocumentGateway {
  Completer<dynamic>? picker;
  int picks = 0;
  @override
  Future<dynamic> call(String method, [Map<String, dynamic> args = const {}]) {
    if (method == 'pickAttachments') {
      picks++;
      return picker?.future ??
          Future.value([
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

NativeHtmlTextFieldWidget field(WidgetTester t, String name) =>
    t.widget<NativeHtmlTextFieldWidget>(
      find.byWidgetPredicate(
        (w) => w is NativeHtmlTextFieldWidget && w.field.name == name,
      ),
    );
Map<String, dynamic> readControls(WidgetTester t) {
  final values = <String, dynamic>{
    for (final n in ['text', 'off', 'password', 'notes'])
      n: field(t, n).state.valueFor(field(t, n).field.key),
  };
  final check = t
      .widgetList<NativeHtmlControlWidget>(find.byType(NativeHtmlControlWidget))
      .toList();
  values['check'] = check.first.state.isChecked(check.first.control.key);
  values['choice'] = check.last.state.isChecked(check.last.control.key)
      ? 'b'
      : check[1].state.isChecked(check[1].control.key)
      ? 'a'
      : '';
  final select = t.widget<NativeHtmlSelectWidget>(
    find.byType(NativeHtmlSelectWidget),
  );
  values['select'] = select.state.valueFor(select.control.key);
  final range = t.widget<NativeHtmlRangeWidget>(
    find.byType(NativeHtmlRangeWidget),
  );
  values['range'] = range.state.valueFor(range.control.key);
  final date = t.widget<NativeHtmlDateInput>(find.byType(NativeHtmlDateInput));
  values['date'] = date.state.valueFor(date.control.key);
  final upload = t.widget<NativeHtmlFileInputWidget>(
    find.byType(NativeHtmlFileInputWidget),
  );
  final text = field(t, 'text'),
      selection = text.state.controllerFor(text.field.key).selection;
  return {
    'values': values,
    'selection': [selection.start, selection.end],
    'files': [
      for (final f in upload.state.filesFor(upload.control.key))
        {'name': f.name, 'type': f.mimeType, 'bytes': f.bytes.toList()},
    ],
  };
}

Future<void> editControls(WidgetTester t, Map edited) async {
  for (final n in ['text', 'off', 'password', 'notes']) {
    final f = find.byWidgetPredicate(
      (w) => w is NativeHtmlTextFieldWidget && w.field.name == n,
    );
    await t.ensureVisible(f);
    await t.enterText(
      find.descendant(of: f, matching: find.byType(EditableText)),
      edited[n] as String,
    );
  }
  final checks = t
      .widgetList<NativeHtmlControlWidget>(find.byType(NativeHtmlControlWidget))
      .toList();
  checks.first.state.activateControl(checks.first.control.key);
  checks.last.state.activateControl(checks.last.control.key);
  final select = t.widget<NativeHtmlSelectWidget>(
    find.byType(NativeHtmlSelectWidget),
  );
  select.state.select(select.control.key, 1);
  final range = t.widget<NativeHtmlRangeWidget>(
    find.byType(NativeHtmlRangeWidget),
  );
  range.state.setRangeValue(range.control.key, 73);
  final date = t.widget<NativeHtmlDateInput>(find.byType(NativeHtmlDateInput));
  date.state.setValue(date.control.key, edited['date'] as String);
  final upload = find.byType(NativeHtmlFileInputWidget);
  await t.ensureVisible(upload);
  await t.tap(upload);
  await t.pumpAndSettle();
  final f = field(t, 'text'), c = f.state.controllerFor(f.field.key);
  c.selection = const TextSelection(baseOffset: 1, extentOffset: 4);
  await t.pumpAndSettle();
}

void main() {
  final fixture =
      jsonDecode(
            File(
              'tool/parity/fixtures/document-control-lifetime-chromium153.json',
            ).readAsStringSync(),
          )
          as Map;
  for (final row in fixture['cases'] as List) {
    for (final sameFrame in [false, true]) {
      testWidgets(
        'control lifetime ${row['viewport']['width']} ${row['theme']} dpr${row['dpr']} sameFrame=$sameFrame',
        (t) async {
          final dpr = (row['dpr'] as num).toDouble();
          t.view.devicePixelRatio = dpr;
          t.view.physicalSize =
              Size(
                (row['viewport']['width'] as num).toDouble(),
                (row['viewport']['height'] as num).toDouble() + 48,
              ) *
              dpr;
          addTearDown(t.view.reset);
          final g = LifetimeGateway()
            ..responses.add(response('/lifetime', fixture['html'] as String));
          final windows = NativeDocumentWindows(g);
          final window = windows.target(
            'controls',
            null,
            sourceUrl: 'https://gateway.example/',
          );
          await window.load(
            const NativeHtmlFormRequest(
              url: '/lifetime',
              method: 'GET',
              target: '',
            ),
            baseUrl: window.sourceUrl,
          );
          windows.select(window);
          final document = window.currentDocument!;
          Widget page(int epoch) => MaterialApp(
            theme: theme.build(
              row['theme'] == 'dark' ? Brightness.dark : Brightness.light,
            ),
            home: NativeDocumentWorkspace(
              key: ValueKey(epoch),
              windows: windows,
            ),
          );
          try {
            await t.pumpWidget(page(0));
            await t.pumpAndSettle();
            await editControls(t, fixture['editedValues'] as Map);
            expect(readControls(t), row['edited']);
            final editable = find.descendant(
              of: find.byWidgetPredicate(
                (w) => w is NativeHtmlTextFieldWidget && w.field.name == 'text',
              ),
              matching: find.byType(EditableText),
            );
            await t.ensureVisible(editable);
            await t.tap(editable);
            await t.pump();
            final previousRenderer = t.state(find.byType(NativeHtmlDocument));
            final textField = field(t, 'text');
            final previousController = textField.state.controllerFor(
              textField.field.key,
            );
            previousController.value = previousController.value.copyWith(
              selection: const TextSelection(baseOffset: 1, extentOffset: 4),
              composing: const TextRange(start: 1, end: 4),
            );
            final size = t.view.physicalSize;
            t.view.physicalSize = Size(
              size.width - 20 * dpr,
              size.height - 40 * dpr,
            );
            await t.pumpAndSettle();
            final resized = field(t, 'text');
            expect(
              resized.state.controllerFor(resized.field.key).value.composing,
              const TextRange(start: 1, end: 4),
            );
            t.view.physicalSize = size;
            await t.pumpAndSettle();
            previousController.value = previousController.value.copyWith(
              composing: TextRange.empty,
            );
            final history = document.historyControls.capture()!;
            expect(
              history.controls.values
                  .map((v) => v.text)
                  .whereType<String>()
                  .toSet(),
              {'草稿🙂還在', '第一行\n第二行'},
            );

            if (!sameFrame) {
              await t.pumpWidget(const SizedBox.shrink());
              await t.pumpAndSettle();
              expect(document.liveControls.hasDetachedControls, isTrue);
              expect(
                document.historyControls.capture()!.length,
                history.length,
              );
            }
            await t.pumpWidget(page(1));
            await t.pumpAndSettle();
            expect(window.currentDocument, same(document));
            expect(
              t.state(find.byType(NativeHtmlDocument)),
              isNot(same(previousRenderer)),
            );
            final currentText = field(t, 'text');
            expect(
              currentText.state.controllerFor(currentText.field.key),
              same(previousController),
            );
            expect(document.liveControls.hasDetachedControls, isFalse);

            expect(readControls(t), row['resumed']);
            expect(g.calls, hasLength(1));
            final reset = find.byType(NativeHtmlButtonWidget);
            await t.ensureVisible(reset);
            await t.tap(reset);
            await t.pumpAndSettle();
            final result = readControls(t);
            expect(result['values'], row['reset']['values']);
            expect(result['files'], row['reset']['files']);
            expect(t.takeException(), isNull);
          } finally {
            await t.pumpWidget(const SizedBox.shrink());
            windows.dispose();
          }
        },
      );
    }
  }
  for (final retire in ['resume', 'close', 'account', 'reset']) {
    testWidgets('parked file picker completion $retire', (t) async {
      final g = LifetimeGateway()
        ..picker = Completer<dynamic>()
        ..responses.add(response('/lifetime', fixture['html'] as String));
      final windows = NativeDocumentWindows(g),
          window = windows.target(
            'pending',
            null,
            sourceUrl: 'https://gateway.example/',
          );
      await window.load(
        const NativeHtmlFormRequest(
          url: '/lifetime',
          method: 'GET',
          target: '',
        ),
        baseUrl: window.sourceUrl,
      );
      windows.select(window);
      final document = window.currentDocument!;
      Widget page(int epoch) => MaterialApp(
        theme: theme.build(Brightness.light),
        home: NativeDocumentWorkspace(key: ValueKey(epoch), windows: windows),
      );
      try {
        await t.pumpWidget(page(0));
        await t.pumpAndSettle();
        final upload = find.byType(NativeHtmlFileInputWidget);
        await t.ensureVisible(upload);
        await t.tap(upload);
        await t.pump();
        expect(g.picks, 1);
        await t.pumpWidget(const SizedBox.shrink());
        await t.pumpAndSettle();
        expect(document.liveControls.hasDetachedControls, isTrue);
        if (retire == 'close') windows.close(window);
        if (retire == 'account') windows.invalidateNativeConnection();
        if (retire == 'reset') {
          await t.pumpWidget(page(1));
          await t.pumpAndSettle();
          final reset = find.byType(NativeHtmlButtonWidget);
          await t.ensureVisible(reset);
          await t.tap(reset);
          await t.pumpAndSettle();
        }
        if (retire == 'account') {
          g.picker!.completeError(StateError('synthetic retired picker'));
        } else {
          g.picker!.complete([
            {
              'name': 'late.bin',
              'mimeType': 'application/octet-stream',
              'bytes': base64Encode([0, 127, 128, 255]),
            },
          ]);
        }
        await t.pumpAndSettle();
        if (retire == 'resume') {
          await t.pumpWidget(page(1));
          await t.pumpAndSettle();
          expect(readControls(t)['files'], [
            {
              'name': 'late.bin',
              'type': 'application/octet-stream',
              'bytes': [0, 127, 128, 255],
            },
          ]);
        } else if (retire == 'reset') {
          expect(readControls(t)['files'], isEmpty);
        } else {
          expect(document.liveControls.isDisposed, isTrue);
          expect(document.liveControls.hasDetachedControls, isFalse);
        }
        expect(t.takeException(), isNull);
      } finally {
        await t.pumpWidget(const SizedBox.shrink());
        windows.dispose();
      }
    });
  }
  testWidgets('fresh response keeps live controls out of history restoration', (
    t,
  ) async {
    final g = LifetimeGateway()
      ..responses.addAll([
        response('/lifetime', fixture['html'] as String),
        response('/lifetime', fixture['html'] as String),
      ]);
    final windows = NativeDocumentWindows(g),
        window = windows.target(
          'reload',
          null,
          sourceUrl: 'https://gateway.example/',
        );
    await window.load(
      const NativeHtmlFormRequest(url: '/lifetime', method: 'GET', target: ''),
      baseUrl: window.sourceUrl,
    );
    windows.select(window);
    final old = window.currentDocument!;
    Widget page() => MaterialApp(
      theme: theme.build(Brightness.light),
      home: NativeDocumentWorkspace(windows: windows),
    );
    try {
      await t.pumpWidget(page());
      await t.pumpAndSettle();
      await editControls(t, fixture['editedValues'] as Map);
      await t.pumpWidget(const SizedBox.shrink());
      await t.pumpAndSettle();
      expect(old.liveControls.hasDetachedControls, isTrue);
      await t.pumpWidget(page());
      await t.pumpAndSettle();
      await t.tap(find.byTooltip("Reload"));
      await t.pumpAndSettle();
      expect(window.currentDocument, isNot(same(old)));
      expect(old.liveControls.isDisposed, isTrue);
      await t.pumpWidget(page());
      await t.pumpAndSettle();
      final actual = readControls(t);
      final defaults = (fixture['cases'] as List).first['fresh'] as Map;
      for (final name in [
        'off',
        'password',
        'check',
        'choice',
        'select',
        'range',
        'date',
      ]) {
        expect(actual['values'][name], defaults['values'][name], reason: name);
      }
      expect(actual['files'], isEmpty);
      expect(g.calls, hasLength(2));
      expect(t.takeException(), isNull);
    } finally {
      await t.pumpWidget(const SizedBox.shrink());
      windows.dispose();
    }
  });
  testWidgets('a reparented workspace resumes its same native document state', (
    t,
  ) async {
    final g = LifetimeGateway()
      ..responses.add(response('/lifetime', fixture['html'] as String));
    final windows = NativeDocumentWindows(g),
        window = windows.target(
          'reparent',
          null,
          sourceUrl: 'https://gateway.example/',
        );
    await window.load(
      const NativeHtmlFormRequest(url: '/lifetime', method: 'GET', target: ''),
      baseUrl: window.sourceUrl,
    );
    windows.select(window);
    final key = GlobalKey();
    Widget page(bool top) => MaterialApp(
      theme: theme.build(Brightness.light),
      home: Column(
        children: [
          Expanded(
            child: top
                ? NativeDocumentWorkspace(key: key, windows: windows)
                : const SizedBox(),
          ),
          Expanded(
            child: top
                ? const SizedBox()
                : NativeDocumentWorkspace(key: key, windows: windows),
          ),
        ],
      ),
    );
    try {
      await t.pumpWidget(page(true));
      await t.pumpAndSettle();
      await editControls(t, fixture['editedValues'] as Map);
      final original = t.state(find.byType(NativeHtmlDocument));
      await t.pumpWidget(page(false));
      await t.pumpAndSettle();
      expect(t.state(find.byType(NativeHtmlDocument)), same(original));
      expect(readControls(t), (fixture['cases'] as List).first['resumed']);
      expect(t.takeException(), isNull);
    } finally {
      await t.pumpWidget(const SizedBox.shrink());
      windows.dispose();
    }
  });
}
