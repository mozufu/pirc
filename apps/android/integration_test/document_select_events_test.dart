import 'dart:convert';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:html/parser.dart' as html;
import 'package:integration_test/integration_test.dart';
import 'package:pirc_mobile/live/document_navigation.dart';
import 'package:pirc_mobile/live/document_navigation_state.dart';
import 'package:pirc_mobile/live/gateway.dart';
import 'package:pirc_render/src/html_document_content.dart';
import 'package:pirc_render/src/html_select.dart';
import 'package:pirc_mobile/theme.dart';

const _listboxesHtml = '''<!doctype html><html><body>
<label for="listbox">Listbox</label>
<select id="listbox" size="4">
  <option id="alpha-option" value="alpha" selected>Alpha</option>
  <option id="bravo-option" value="bravo">Bravo</option>
  <option id="charlie-option" value="charlie">Charlie</option>
  <option id="delta-option" value="delta">Delta</option>
</select>
<label for="cancel-keys">Canceled keys</label>
<select id="cancel-keys" size="4">
  <option id="cancel-a-option" value="cancel-a" selected>Cancel Alpha</option>
  <option id="cancel-b-option" value="cancel-b">Cancel Beta</option>
  <option id="cancel-c-option" value="cancel-c">Cancel Charlie</option>
  <option id="cancel-d-option" value="cancel-d">Cancel Delta</option>
</select>
<label for="mutating-select">Mutating key</label>
<select id="mutating-select" size="4">
  <option id="start-option" value="start" selected>Mutation Start</option>
  <option id="old-next-option" value="old-next">Old Next</option>
  <option id="last-option" value="last">Last Option</option>
</select>
<pre id="oracle" style="font-size:1px;line-height:1px;max-height:1px;overflow:hidden"></pre>
<script>
const oracle = document.querySelector('#oracle');
const rows = [];
function eventTarget(target) {
  return target && target.getAttribute
    ? target.id || target.tagName.toLowerCase()
    : null;
}
function record(event) {
  const target = event.target;
  const select = target && target.closest ? target.closest('select') : null;
  const options = select ? Array.from(select.options) : [];
  rows.push({
    type: event.type,
    target: eventTarget(target),
    select: select ? eventTarget(select) : null,
    value: select ? select.value : null,
    selectedValues: options.filter(option => option.selected).map(option => option.value),
    selectedIndices: options.flatMap((option, index) => option.selected ? [index] : []),
    optionValues: options.map(option => option.value),
    key: event.key ?? null,
    shiftKey: event.shiftKey ?? false,
    defaultPrevented: event.defaultPrevented
  });
  oracle.textContent = JSON.stringify(rows);
}
for (const type of ['focusin', 'focusout', 'click', 'keydown', 'keyup', 'input', 'change']) {
  document.addEventListener(type, record);
}
for (const select of document.querySelectorAll('select')) {
  select.addEventListener('focus', record);
  select.addEventListener('blur', record);
}
document.querySelector('#charlie-option').addEventListener('click', event => event.preventDefault());
document.querySelector('#cancel-keys').addEventListener('keydown', event => {
  if (event.key === 'ArrowDown' || event.key === 'End') event.preventDefault();
});
document.querySelector('#mutating-select').addEventListener('keydown', event => {
  const select = event.currentTarget;
  if (event.key !== 'ArrowDown' || select.options.length !== 3) return;
  const option = document.createElement('option');
  option.value = 'inserted';
  option.textContent = 'Inserted Option';
  option.id = 'inserted-option';
  select.insertBefore(option, select.options[1]);
});
oracle.textContent = JSON.stringify(rows);
</script></body></html>''';

const _multipleAndPopupHtml = '''<!doctype html><html><body>
<label for="multi-select">Multiple select</label>
<select id="multi-select" multiple size="4">
  <option id="multi-alpha-option" value="multi-alpha" selected>Multi Alpha</option>
  <option id="multi-bravo-option" value="multi-bravo">Multi Bravo</option>
  <option id="multi-charlie-option" value="multi-charlie">Multi Charlie</option>
  <option id="multi-delta-option" value="multi-delta">Multi Delta</option>
</select>
<label for="popup-select">Popup select</label>
<select id="popup-select">
  <option id="popup-one-option" value="popup-one" selected>Popup One</option>
  <option id="popup-two-option" value="popup-two">Popup Two</option>
</select>
<pre id="oracle" style="font-size:1px;line-height:1px;max-height:1px;overflow:hidden"></pre>
<script>
const oracle = document.querySelector('#oracle');
const rows = [];
function eventTarget(target) {
  return target && target.getAttribute
    ? target.id || target.tagName.toLowerCase()
    : null;
}
function record(event) {
  const target = event.target;
  const select = target && target.closest ? target.closest('select') : null;
  const options = select ? Array.from(select.options) : [];
  rows.push({
    type: event.type,
    target: eventTarget(target),
    select: select ? eventTarget(select) : null,
    value: select ? select.value : null,
    selectedValues: options.filter(option => option.selected).map(option => option.value),
    selectedIndices: options.flatMap((option, index) => option.selected ? [index] : []),
    optionValues: options.map(option => option.value),
    key: event.key ?? null,
    shiftKey: event.shiftKey ?? false,
    defaultPrevented: event.defaultPrevented
  });
  oracle.textContent = JSON.stringify(rows);
}
for (const type of ['focusin', 'focusout', 'click', 'keydown', 'keyup', 'input', 'change']) {
  document.addEventListener(type, record);
}
for (const select of document.querySelectorAll('select')) {
  select.addEventListener('focus', record);
  select.addEventListener('blur', record);
}
oracle.textContent = JSON.stringify(rows);
</script></body></html>''';

NativeFetchedDocument _document(String url, String source) {
  final bytes = Uint8List.fromList(utf8.encode(source));
  return NativeFetchedDocument(
    id: 1,
    url: url,
    status: 200,
    bytes: bytes,
    mimeType: 'text/html',
    headers: const {},
    content: NativeHtmlDocumentContent.fromBytes(
      bytes,
      mimeType: 'text/html',
      charset: 'utf-8',
    ),
  );
}

List<Map<String, dynamic>> _oracleRows(NativeFetchedDocument document) {
  final source = document.scripts?.content?.text;
  if (source == null) return const [];
  final encoded = html.parse(source).querySelector('#oracle')?.text.trim();
  if (encoded == null || encoded.isEmpty) return const [];
  return (jsonDecode(encoded) as List<dynamic>)
      .map((row) => Map<String, dynamic>.from(row as Map))
      .toList();
}

Future<void> _until(
  WidgetTester tester,
  NativeFetchedDocument document,
  bool Function() predicate,
  String label,
) async {
  for (var i = 0; i < 200 && !predicate(); i++) {
    await tester.pump(const Duration(milliseconds: 25));
  }
  expect(
    predicate(),
    isTrue,
    reason: '$label: ${document.scripts?.diagnostics}',
  );
  expect(tester.takeException(), isNull, reason: label);
}

Finder _selectFinder(String label) => find.byWidgetPredicate(
  (widget) => widget is NativeHtmlSelectWidget && widget.control.label == label,
);

NativeHtmlSelectWidget _select(WidgetTester tester, String label) =>
    tester.widget<NativeHtmlSelectWidget>(_selectFinder(label));

Future<NativeFetchedDocument> _mount(
  WidgetTester tester, {
  required String url,
  required String source,
}) async {
  final theme = await PircTheme.load();
  final document = _document(url, source);
  await tester.pumpWidget(
    MaterialApp(
      theme: theme.build(Brightness.light),
      home: Scaffold(
        body: NativeFetchedDocumentView(
          document: document,
          gateway: Gateway(),
          onLink: (_) {},
          onSubmit: (_) {},
        ),
      ),
    ),
  );
  await _until(
    tester,
    document,
    () => document.scripts?.ready == true,
    'document script ready',
  );
  expect(document.scripts!.diagnostics, isEmpty);
  return document;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('listbox taps and keys preserve native event ordering', (
    t,
  ) async {
    final document = await _mount(
      t,
      url: 'https://example.test/document-select-listbox-events',
      source: _listboxesHtml,
    );
    try {
      final listbox = _select(t, 'Listbox');
      final focus = listbox.state.focusNodeFor(listbox.control.key);
      expect(listbox.control.size, 4);
      expect(listbox.state.selectedIndices(listbox.control.key), [0]);

      var start = _oracleRows(document).length;
      await t.ensureVisible(find.text('Bravo'));
      await t.tap(find.text('Bravo'), kind: PointerDeviceKind.touch);
      await _until(
        t,
        document,
        () => _oracleRows(document)
            .skip(start)
            .any(
              (row) =>
                  row['type'] == 'click' && row['target'] == 'bravo-option',
            ),
        'Bravo receives a real option tap',
      );
      final bravoRows = _oracleRows(document).skip(start).toList();
      final bravoTypes = bravoRows
          .where(
            (row) =>
                row['select'] == 'listbox' &&
                const {
                  'focus',
                  'focusin',
                  'input',
                  'change',
                  'click',
                }.contains(row['type']),
          )
          .map((row) => row['type'])
          .toList();
      expect(bravoTypes, ['focus', 'focusin', 'input', 'change', 'click']);
      final bravoClick = bravoRows.singleWhere(
        (row) => row['type'] == 'click' && row['target'] == 'bravo-option',
      );
      expect(bravoClick['value'], 'bravo');
      expect(bravoClick['selectedValues'], ['bravo']);
      expect(
        bravoRows.singleWhere((row) => row['type'] == 'input')['value'],
        'bravo',
      );
      expect(
        bravoRows.singleWhere((row) => row['type'] == 'change')['value'],
        'bravo',
      );
      final selectedListbox = _select(t, 'Listbox');
      expect(
        selectedListbox.state.selectedIndices(selectedListbox.control.key),
        [1],
      );
      expect(focus.hasFocus, isTrue);

      start = _oracleRows(document).length;
      await t.ensureVisible(find.text('Charlie'));
      await t.tap(find.text('Charlie'), kind: PointerDeviceKind.touch);
      await _until(
        t,
        document,
        () => _oracleRows(document)
            .skip(start)
            .any(
              (row) =>
                  row['type'] == 'click' && row['target'] == 'charlie-option',
            ),
        'Charlie click handler cancels its click default',
      );
      final charlieRows = _oracleRows(document).skip(start).toList();
      final charlieClick = charlieRows.singleWhere(
        (row) => row['type'] == 'click' && row['target'] == 'charlie-option',
      );
      expect(charlieClick['defaultPrevented'], isTrue);
      expect(charlieClick['value'], 'charlie');
      expect(charlieRows.where((row) => row['type'] == 'input'), hasLength(1));
      expect(charlieRows.where((row) => row['type'] == 'change'), hasLength(1));
      final charlieListbox = _select(t, 'Listbox');
      expect(charlieListbox.state.selectedIndices(charlieListbox.control.key), [
        2,
      ]);
      expect(focus.hasFocus, isTrue);

      final canceled = _select(t, 'Canceled keys');
      final canceledFocus = canceled.state.focusNodeFor(canceled.control.key);
      await t.ensureVisible(find.text('Cancel Alpha'));
      await t.tap(find.text('Cancel Alpha'), kind: PointerDeviceKind.touch);
      await _until(
        t,
        document,
        () => canceledFocus.hasFocus,
        'canceled-key listbox receives focus',
      );
      for (final key in [
        LogicalKeyboardKey.arrowDown,
        LogicalKeyboardKey.end,
      ]) {
        start = _oracleRows(document).length;
        final name = key == LogicalKeyboardKey.end ? 'End' : 'ArrowDown';
        await t.sendKeyEvent(key);
        await _until(
          t,
          document,
          () => _oracleRows(document)
              .skip(start)
              .any((row) => row['type'] == 'keyup' && row['key'] == name),
          '$name keyup is observed after cancellation',
        );
        final keyRows = _oracleRows(
          document,
        ).skip(start).where((row) => row['select'] == 'cancel-keys').toList();
        final keydown = keyRows.singleWhere(
          (row) => row['type'] == 'keydown' && row['key'] == name,
        );
        expect(keydown['defaultPrevented'], isTrue);
        expect(
          keyRows.where(
            (row) => row['type'] == 'input' || row['type'] == 'change',
          ),
          isEmpty,
        );
        final currentCanceled = _select(t, 'Canceled keys');
        expect(
          currentCanceled.state.selectedIndices(currentCanceled.control.key),
          [0],
        );
        expect(
          currentCanceled.state.focusNodeFor(currentCanceled.control.key),
          same(canceledFocus),
        );
        expect(canceledFocus.hasFocus, isTrue);
      }

      final mutating = _select(t, 'Mutating key');
      final mutatingKey = mutating.key;
      final mutatingFocus = mutating.state.focusNodeFor(mutating.control.key);
      await t.ensureVisible(find.text('Mutation Start'));
      await t.tap(find.text('Mutation Start'), kind: PointerDeviceKind.touch);
      await _until(
        t,
        document,
        () => mutatingFocus.hasFocus,
        'mutation listbox receives focus',
      );
      start = _oracleRows(document).length;
      await t.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await _until(t, document, () {
        final nextRows = _oracleRows(document).skip(start);
        return nextRows.any(
              (row) => row['type'] == 'input' && row['value'] == 'inserted',
            ) &&
            nextRows.any(
              (row) => row['type'] == 'keyup' && row['key'] == 'ArrowDown',
            );
      }, 'ArrowDown applies against the inserted option');
      final mutationRows = _oracleRows(document).skip(start).toList();
      final mutationKeydown = mutationRows.singleWhere(
        (row) => row['type'] == 'keydown' && row['key'] == 'ArrowDown',
      );
      expect(mutationKeydown['defaultPrevented'], isFalse);
      expect(mutationKeydown['optionValues'], [
        'start',
        'inserted',
        'old-next',
        'last',
      ]);
      expect(mutationRows.where((row) => row['type'] == 'input'), hasLength(1));
      expect(
        mutationRows.where((row) => row['type'] == 'change'),
        hasLength(1),
      );
      final updatedMutating = _select(t, 'Mutating key');
      expect(updatedMutating.control.options.map((option) => option.value), [
        'start',
        'inserted',
        'old-next',
        'last',
      ]);
      expect(
        updatedMutating.state.selectedIndices(updatedMutating.control.key),
        [1],
      );
      expect(
        updatedMutating.state.focusNodeFor(updatedMutating.control.key),
        same(mutatingFocus),
      );
      expect(updatedMutating.key, same(mutatingKey));
      expect(mutatingFocus.hasFocus, isTrue);
      expect(
        mutationRows.where(
          (row) =>
              row['select'] == 'mutating-select' &&
              (row['type'] == 'blur' || row['type'] == 'focusout'),
        ),
        isEmpty,
      );
      expect(document.scripts!.diagnostics, isEmpty);
    } finally {
      await t.pumpWidget(const SizedBox());
      document.dispose();
    }
  });

  testWidgets('multiple selection is atomic and popup keeps logical focus', (
    t,
  ) async {
    final document = await _mount(
      t,
      url: 'https://example.test/document-select-multiple-events',
      source: _multipleAndPopupHtml,
    );
    try {
      final multiple = _select(t, 'Multiple select');
      final multipleFocus = multiple.state.focusNodeFor(multiple.control.key);
      var start = _oracleRows(document).length;
      await t.ensureVisible(find.text('Multi Charlie'));
      await t.tap(find.text('Multi Charlie'), kind: PointerDeviceKind.touch);
      await _until(
        t,
        document,
        () => _oracleRows(document)
            .skip(start)
            .any(
              (row) =>
                  row['type'] == 'click' &&
                  row['target'] == 'multi-charlie-option',
            ),
        'touch tap toggles one multiple option',
      );
      var multiRows = _oracleRows(document).skip(start).toList();
      expect(multiRows.where((row) => row['type'] == 'input'), hasLength(1));
      expect(multiRows.where((row) => row['type'] == 'change'), hasLength(1));
      var currentMultiple = _select(t, 'Multiple select');
      expect(
        currentMultiple.state.selectedIndices(currentMultiple.control.key),
        [0, 2],
      );
      expect(
        currentMultiple.state.focusNodeFor(currentMultiple.control.key),
        same(multipleFocus),
      );
      expect(
        multiRows.singleWhere(
          (row) => row['type'] == 'input',
        )['selectedIndices'],
        [0, 2],
      );
      expect(multipleFocus.hasFocus, isTrue);

      start = _oracleRows(document).length;
      await t.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await t.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await t.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await _until(
        t,
        document,
        () => _oracleRows(document)
            .skip(start)
            .any((row) => row['type'] == 'keyup' && row['key'] == 'ArrowDown'),
        'Shift+ArrowDown completes the range selection',
      );
      multiRows = _oracleRows(document).skip(start).toList();
      expect(multiRows.where((row) => row['type'] == 'input'), hasLength(1));
      expect(multiRows.where((row) => row['type'] == 'change'), hasLength(1));
      final rangeKeydown = multiRows.singleWhere(
        (row) => row['type'] == 'keydown' && row['key'] == 'ArrowDown',
      );
      expect(rangeKeydown['shiftKey'], isTrue);
      currentMultiple = _select(t, 'Multiple select');
      expect(
        currentMultiple.state.selectedIndices(currentMultiple.control.key),
        [2, 3],
      );
      expect(
        currentMultiple.state.focusNodeFor(currentMultiple.control.key),
        same(multipleFocus),
      );
      expect(multipleFocus.hasFocus, isTrue);

      final popup = _select(t, 'Popup select');
      final popupFocus = popup.state.focusNodeFor(popup.control.key);
      final popupFinder = _selectFinder('Popup select');
      start = _oracleRows(document).length;
      await t.ensureVisible(popupFinder);
      await t.tap(popupFinder);
      await _until(
        t,
        document,
        () =>
            find.text('Popup Two').evaluate().isNotEmpty &&
            _oracleRows(document)
                .skip(start)
                .any(
                  (row) =>
                      row['type'] == 'click' && row['target'] == 'popup-select',
                ),
        'dropdown opens and reports its activation',
      );
      await t.sendKeyEvent(LogicalKeyboardKey.escape);
      await _until(
        t,
        document,
        () => find.text('Popup Two').evaluate().isEmpty && popupFocus.hasFocus,
        'Escape cancels the logical popup',
      );
      var currentPopup = _select(t, 'Popup select');
      expect(currentPopup.state.selectedIndices(currentPopup.control.key), [0]);
      expect(
        currentPopup.state.focusNodeFor(currentPopup.control.key),
        same(popupFocus),
      );
      expect(popupFocus.hasFocus, isTrue);
      var popupRows = _oracleRows(
        document,
      ).skip(start).where((row) => row['select'] == 'popup-select').toList();
      expect(popupRows.where((row) => row['type'] == 'input'), isEmpty);
      expect(popupRows.where((row) => row['type'] == 'change'), isEmpty);
      expect(
        popupRows.where(
          (row) => row['type'] == 'blur' || row['type'] == 'focusout',
        ),
        isEmpty,
      );
      expect(popupRows.where((row) => row['type'] == 'focus'), hasLength(1));
      expect(popupRows.where((row) => row['type'] == 'focusin'), hasLength(1));

      start = _oracleRows(document).length;
      await t.tap(popupFinder);
      await _until(
        t,
        document,
        () => find.text('Popup Two').evaluate().isNotEmpty,
        'dropdown reopens for a selection',
      );
      await t.pumpAndSettle();
      await t.ensureVisible(find.text('Popup Two'));
      await t.pumpAndSettle();
      await t.tap(find.text('Popup Two'));
      await _until(
        t,
        document,
        () =>
            _oracleRows(document)
                .skip(start)
                .any(
                  (row) =>
                      row['type'] == 'change' && row['value'] == 'popup-two',
                ) &&
            popupFocus.hasFocus &&
            find.text('Popup Two').evaluate().length == 1,
        'choosing Popup Two commits the selection',
      );
      currentPopup = _select(t, 'Popup select');
      expect(currentPopup.state.selectedIndices(currentPopup.control.key), [1]);
      expect(
        currentPopup.state.focusNodeFor(currentPopup.control.key),
        same(popupFocus),
      );
      expect(popupFocus.hasFocus, isTrue);
      popupRows = _oracleRows(
        document,
      ).skip(start).where((row) => row['select'] == 'popup-select').toList();
      expect(popupRows.where((row) => row['type'] == 'input'), hasLength(1));
      expect(popupRows.where((row) => row['type'] == 'change'), hasLength(1));
      expect(
        popupRows.where(
          (row) => row['type'] == 'blur' || row['type'] == 'focusout',
        ),
        isEmpty,
      );
      expect(
        _oracleRows(document).where(
          (row) => row['select'] == 'popup-select' && row['type'] == 'focus',
        ),
        hasLength(1),
      );
      expect(
        _oracleRows(document).where(
          (row) => row['select'] == 'popup-select' && row['type'] == 'focusin',
        ),
        hasLength(1),
      );
      expect(document.scripts!.diagnostics, isEmpty);
    } finally {
      await t.pumpWidget(const SizedBox());
      document.dispose();
    }
  });
}
