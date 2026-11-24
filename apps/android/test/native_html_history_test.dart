import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_render/src/html_buttons.dart';
import 'package:pirc_render/src/html_controls.dart';
import 'package:pirc_render/src/html_range.dart';
import 'package:pirc_render/src/html_select.dart';
import 'package:pirc_render/src/html_syntax.dart';
import 'package:pirc_render/src/native_html.dart';
import 'live_test.dart' show theme;

final Map<String, dynamic> _documentFixture =
    jsonDecode(
          File(
            '../../fixtures/mobile-parity/app-document-target-context.json',
          ).readAsStringSync(),
        )
        as Map<String, dynamic>;

String _fixtureMarkup({
  required String version,
  required int number,
  required bool untouchedCheck,
  required bool selectOne,
  required int rangeDefault,
}) {
  final document =
      _documentFixture['namedHistoryDocument'] as Map<String, dynamic>;
  return (document['responseHtmlTemplate'] as String)
      .replaceAll('{{version}}', version)
      .replaceAll('{{numberDefault}}', '$number')
      .replaceAll('{{rangeDefault}}', '$rangeDefault')
      .replaceAll('{{checkAttribute}}', untouchedCheck ? 'checked' : '')
      .replaceAll('{{selectOneAttribute}}', selectOne ? 'selected' : '')
      .replaceAll('{{selectTwoAttribute}}', selectOne ? '' : 'selected');
}

Widget _page(String source, NativeHtmlHistoryController? history) =>
    MaterialApp(
      theme: theme.build(Brightness.light),
      home: Scaffold(
        body: SingleChildScrollView(
          child: NativeHtmlDocument(
            nodes: [NativeHtmlRaw(source)],
            style: const TextStyle(fontSize: 15),
            styles: MarkdownStyleSheet(),
            builders: const {},
            markdownStyles: false,
            historyController: history,
          ),
        ),
      ),
    );

Finder _editableWithValue(String value) => find.byWidgetPredicate(
  (widget) => widget is EditableText && widget.controller.text == value,
);

Finder _controlWithLabel(String label) => find.byWidgetPredicate(
  (widget) =>
      widget is NativeHtmlControlWidget && widget.control.label == label,
);

NativeHtmlSelectWidget _selectNamed(WidgetTester tester, String? name) =>
    tester.widget<NativeHtmlSelectWidget>(
      find.byWidgetPredicate(
        (widget) =>
            widget is NativeHtmlSelectWidget && widget.control.name == name,
      ),
    );

void main() {
  testWidgets(
    'restores corpus edits and checkedness while keeping v2 reset defaults',
    (tester) async {
      final before = _fixtureMarkup(
        version: 'server-v1',
        number: 11,
        untouchedCheck: true,
        selectOne: true,
        rangeDefault: 10,
      );
      final after = _fixtureMarkup(
        version: 'server-v2',
        number: 22,
        untouchedCheck: false,
        selectOne: false,
        rangeDefault: 20,
      );
      final firstHistory = NativeHtmlHistoryController();
      await tester.pumpWidget(_page(before, firstHistory));
      await tester.pumpAndSettle();

      await tester.enterText(
        _editableWithValue('text server server-v1'),
        'typed text before App navigation',
      );
      await tester.enterText(_editableWithValue('11'), '42');
      await tester.enterText(
        _editableWithValue('textarea server server-v1'),
        'typed textarea first line\ntyped textarea second line',
      );
      await tester.enterText(
        _editableWithValue('duplicate first server-v1'),
        'duplicate first edited',
      );
      await tester.enterText(
        _editableWithValue('duplicate second server-v1'),
        'duplicate second edited',
      );
      await tester.enterText(
        _editableWithValue('unnamed server server-v1'),
        'unnamed user value',
      );
      await tester.enterText(
        _editableWithValue('revert server-v1'),
        'temporary value',
      );
      await tester.enterText(
        _editableWithValue('temporary value'),
        'revert server-v1',
      );

      final textEditor = tester.widget<EditableText>(
        _editableWithValue('typed text before App navigation'),
      );
      textEditor.controller.selection = const TextSelection(
        baseOffset: 6,
        extentOffset: 10,
      );
      await tester.tap(_controlWithLabel('Checked'));
      await tester.tap(_controlWithLabel('Blue'));
      await tester.tap(find.text('One').last);
      await tester.tap(find.text('Two').last);
      await tester.tap(find.text('Three').last);
      await tester.pumpAndSettle();

      final oldMultiple = _selectNamed(tester, 'multiple');
      expect(oldMultiple.state.selectedIndices(oldMultiple.control.key), [
        1,
        2,
      ]);
      final snapshot = firstHistory.capture();
      expect(snapshot, isNotNull);
      expect(snapshot!.length, greaterThan(8));
      expect(
        snapshot.controls.values.map((value) => value.text).whereType<String>(),
        isNot(contains('password server server-v1')),
      );
      expect(
        snapshot.controls.values.map((value) => value.text).whereType<String>(),
        isNot(contains('control off server server-v1')),
      );
      expect(
        snapshot.controls.values.map((value) => value.text).whereType<String>(),
        isNot(contains('revert server-v1')),
        reason: 'a text value returned to its old default is not restored',
      );
      firstHistory.dispose();

      final nextHistory = NativeHtmlHistoryController();
      nextHistory.restore(snapshot);
      await tester.pumpWidget(_page(after, nextHistory));
      await tester.pumpAndSettle();

      expect(
        tester
            .widget<EditableText>(
              _editableWithValue('typed text before App navigation'),
            )
            .controller
            .selection,
        const TextSelection(baseOffset: 6, extentOffset: 10),
      );
      expect(_editableWithValue('42'), findsOneWidget);
      expect(
        _editableWithValue(
          'typed textarea first line\ntyped textarea second line',
        ),
        findsOneWidget,
      );
      expect(_editableWithValue('duplicate first edited'), findsOneWidget);
      expect(_editableWithValue('duplicate second edited'), findsOneWidget);
      expect(_editableWithValue('unnamed user value'), findsOneWidget);
      expect(_editableWithValue('revert server-v2'), findsOneWidget);
      expect(
        _editableWithValue('untouched server-v2'),
        findsOneWidget,
        reason: 'untouched text follows the new response default',
      );
      expect(
        _editableWithValue('control off server server-v2'),
        findsOneWidget,
        reason: 'autocomplete=off values are not restored',
      );
      expect(_editableWithValue('disabled server server-v2'), findsOneWidget);
      expect(_editableWithValue('readonly server server-v2'), findsOneWidget);
      expect(_editableWithValue('password server server-v2'), findsOneWidget);
      expect(
        _editableWithValue('form off text server server-v2'),
        findsOneWidget,
      );
      expect(
        _editableWithValue('form off password server server-v2'),
        findsOneWidget,
      );
      expect(
        tester
            .widget<NativeHtmlControlWidget>(_controlWithLabel('Checked'))
            .state
            .isChecked(
              tester
                  .widget<NativeHtmlControlWidget>(_controlWithLabel('Checked'))
                  .control
                  .key,
            ),
        isFalse,
      );
      expect(
        tester
            .widget<NativeHtmlControlWidget>(_controlWithLabel('Blue'))
            .state
            .isChecked(
              tester
                  .widget<NativeHtmlControlWidget>(_controlWithLabel('Blue'))
                  .control
                  .key,
            ),
        isTrue,
      );
      expect(
        tester
            .widget<NativeHtmlControlWidget>(
              find.byWidgetPredicate(
                (widget) =>
                    widget is NativeHtmlControlWidget &&
                    widget.control.label == 'Untouched checkbox',
              ),
            )
            .state
            .isChecked(
              tester
                  .widget<NativeHtmlControlWidget>(
                    find.byWidgetPredicate(
                      (widget) =>
                          widget is NativeHtmlControlWidget &&
                          widget.control.label == 'Untouched checkbox',
                    ),
                  )
                  .control
                  .key,
            ),
        isTrue,
        reason: 'Chrome restores untouched checkbox checkedness too',
      );
      final restoredMultiple = _selectNamed(tester, 'multiple');
      expect(
        restoredMultiple.state.selectedIndices(restoredMultiple.control.key),
        [1, 2],
      );
      final untouchedSelect = _selectNamed(tester, null);
      expect(
        untouchedSelect.state.valueFor(untouchedSelect.control.key),
        'one',
        reason: 'Chrome restores prior select state across changed defaults',
      );
      final untouchedRange = tester.widget<NativeHtmlRangeWidget>(
        find.byWidgetPredicate(
          (widget) =>
              widget is NativeHtmlRangeWidget && widget.control.name == 'range',
        ),
      );
      expect(
        untouchedRange.state.valueFor(untouchedRange.control.key),
        '20',
        reason: 'an unchanged range follows the new response default',
      );

      final reset = find.byWidgetPredicate(
        (widget) =>
            widget is NativeHtmlButtonWidget &&
            widget.button.type == NativeHtmlButtonType.reset,
      );
      await tester.ensureVisible(reset);
      await tester.tap(reset);
      await tester.pumpAndSettle();
      expect(_editableWithValue('text server server-v2'), findsOneWidget);
      expect(_editableWithValue('22'), findsOneWidget);
      expect(_editableWithValue('textarea server server-v2'), findsOneWidget);
      expect(_editableWithValue('duplicate first server-v2'), findsOneWidget);
      expect(_editableWithValue('duplicate second server-v2'), findsOneWidget);
      expect(_editableWithValue('unnamed server server-v2'), findsOneWidget);
      expect(_editableWithValue('revert server-v2'), findsOneWidget);
      final resetCheckbox = tester.widget<NativeHtmlControlWidget>(
        _controlWithLabel('Checked'),
      );
      expect(resetCheckbox.state.isChecked(resetCheckbox.control.key), isTrue);
      final resetRadio = tester.widget<NativeHtmlControlWidget>(
        _controlWithLabel('Red'),
      );
      expect(resetRadio.state.isChecked(resetRadio.control.key), isTrue);
      expect(
        tester
            .widget<NativeHtmlControlWidget>(
              find.byWidgetPredicate(
                (widget) =>
                    widget is NativeHtmlControlWidget &&
                    widget.control.label == 'Untouched checkbox',
              ),
            )
            .state
            .isChecked(
              tester
                  .widget<NativeHtmlControlWidget>(
                    find.byWidgetPredicate(
                      (widget) =>
                          widget is NativeHtmlControlWidget &&
                          widget.control.label == 'Untouched checkbox',
                    ),
                  )
                  .control
                  .key,
            ),
        isFalse,
      );
      final resetSelect = _selectNamed(tester, null);
      expect(resetSelect.state.valueFor(resetSelect.control.key), 'two');
      final resetMultiple = _selectNamed(tester, 'multiple');
      expect(resetMultiple.state.selectedIndices(resetMultiple.control.key), [
        0,
      ]);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'changed structure ignores unmatched snapshot and detach queues restore',
    (tester) async {
      final controller = NativeHtmlHistoryController();
      const source =
          '<form id="before"><input name="text" value="old default"></form>';
      await tester.pumpWidget(_page(source, controller));
      await tester.pumpAndSettle();
      await tester.enterText(_editableWithValue('old default'), 'history edit');
      final snapshot = controller.capture()!;
      await tester.pumpWidget(const SizedBox());
      expect(controller.capture()!.controls.values.single.text, 'history edit');

      controller.restore(snapshot);
      await tester.pumpWidget(
        _page(
          '<form id="after"><input name="text" value="new default"></form>',
          controller,
        ),
      );
      await tester.pumpAndSettle();
      expect(_editableWithValue('new default'), findsOneWidget);
      expect(tester.takeException(), isNull);
      controller.dispose();
      expect(controller.capture(), isNull);
      controller.restore(snapshot);
    },
  );

  testWidgets('same-controller rebuild retains only matching edited values', (
    tester,
  ) async {
    final controller = NativeHtmlHistoryController();
    const first =
        '<form id="same"><input name="changed" value="old"><input name="untouched" value="old untouched"></form>';
    await tester.pumpWidget(_page(first, controller));
    await tester.pumpAndSettle();
    expect(controller.capture()!.isEmpty, isTrue);
    await tester.enterText(_editableWithValue('old'), 'user value');
    expect(controller.capture()!.isEmpty, isFalse);
    await tester.enterText(_editableWithValue('user value'), 'old');
    expect(
      controller.capture()!.isEmpty,
      isTrue,
      reason: 'reverting to the source default clears the old text snapshot',
    );
    await tester.enterText(_editableWithValue('old'), 'user value');

    await tester.pumpWidget(
      _page(
        '<form id="same"><input name="changed" value="new"><input name="untouched" value="new untouched"></form>',
        controller,
      ),
    );
    await tester.pumpAndSettle();
    expect(_editableWithValue('user value'), findsOneWidget);
    expect(_editableWithValue('new untouched'), findsOneWidget);
    controller.dispose();
  });

  testWidgets(
    'restores unchecked radios and disabled selected options directly',
    (tester) async {
      const v1 = '''
      <form id="radio-select">
        <label for="first-radio">First</label>
        <input id="first-radio" type="radio" name="choice" value="first">
        <label for="second-radio">Second</label>
        <input id="second-radio" type="radio" name="choice" value="second">
        <select name="items" multiple>
          <option value="blocked" selected disabled>Blocked</option>
          <option value="available">Available</option>
        </select>
        <button type="reset">Reset</button>
      </form>
    ''';
      const v2 = '''
      <form id="radio-select">
        <label for="first-radio">First</label>
        <input id="first-radio" type="radio" name="choice" value="first" checked>
        <label for="second-radio">Second</label>
        <input id="second-radio" type="radio" name="choice" value="second">
        <select name="items" multiple>
          <option value="blocked" disabled>Blocked</option>
          <option value="available" selected>Available</option>
        </select>
        <button type="reset">Reset</button>
      </form>
    ''';
      final oldController = NativeHtmlHistoryController();
      await tester.pumpWidget(_page(v1, oldController));
      await tester.pumpAndSettle();
      final snapshot = oldController.capture()!;
      oldController.dispose();

      final newController = NativeHtmlHistoryController()..restore(snapshot);
      await tester.pumpWidget(_page(v2, newController));
      await tester.pumpAndSettle();
      final radios = tester
          .widgetList<NativeHtmlControlWidget>(
            find.byType(NativeHtmlControlWidget),
          )
          .toList();
      expect(
        radios.map((widget) => widget.state.isChecked(widget.control.key)),
        [false, false],
      );
      final select = _selectNamed(tester, 'items');
      expect(select.state.selectedIndices(select.control.key), [0]);

      final reset = find.byWidgetPredicate(
        (widget) =>
            widget is NativeHtmlButtonWidget &&
            widget.button.type == NativeHtmlButtonType.reset,
      );
      await tester.tap(reset);
      await tester.pumpAndSettle();
      final resetRadios = tester
          .widgetList<NativeHtmlControlWidget>(
            find.byType(NativeHtmlControlWidget),
          )
          .toList();
      expect(
        resetRadios.map((widget) => widget.state.isChecked(widget.control.key)),
        [true, false],
      );
      expect(select.state.selectedIndices(select.control.key), [1]);
      newController.dispose();
    },
  );

  testWidgets('duplicate identity counts include untouched preceding controls', (
    tester,
  ) async {
    final oldController = NativeHtmlHistoryController();
    await tester.pumpWidget(
      _page(
        '<form id="duplicates"><input name="same" value="first old"><input name="same" value="second old"></form>',
        oldController,
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(_editableWithValue('second old'), 'second edited');
    final snapshot = oldController.capture()!;
    oldController.dispose();

    final newController = NativeHtmlHistoryController()..restore(snapshot);
    await tester.pumpWidget(
      _page(
        '<form id="duplicates"><input name="same" value="first new"><input name="same" value="second new"></form>',
        newController,
      ),
    );
    await tester.pumpAndSettle();
    expect(_editableWithValue('first new'), findsOneWidget);
    expect(_editableWithValue('second edited'), findsOneWidget);
    newController.dispose();
  });
}
