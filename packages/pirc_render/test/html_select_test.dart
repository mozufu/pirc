import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:html/parser.dart' as html;
import 'package:pirc_render/src/html_select.dart';

NativeHtmlSelectDescriptor selectById(
  NativeHtmlSelectState state,
  String source,
  String id,
) {
  final fragment = html.parseFragment(state.annotateHtml(source));
  final element = fragment.querySelector('#$id');
  expect(element, isNotNull);
  return state.resolveControl(element!)!;
}

void main() {
  test('applies browser initial selectedness and display-size defaults', () {
    const source = '''
      <select id="default"><option disabled value="x">Unavailable</option>
        <option value="a">Alpha</option><option value="b">Beta</option></select>
      <select id="last"><option selected value="a">Alpha</option>
        <option selected disabled value="b">Selected despite disabled</option></select>
      <select id="list" size="3"><option>One</option><option>Two</option></select>
      <select id="multiple" multiple><option>One</option><option>Two</option></select>
      <fieldset disabled><select id="fieldset-disabled"><option>Still selected</option></select></fieldset>
      <select id="all-disabled"><option disabled>One</option>
        <optgroup disabled label="Group"><option>Two</option></optgroup></select>
      <select id="explicit-disabled"><option selected disabled value="x">Retained</option>
        <option value="y">Other</option></select>
      <select id="multi-selected" multiple><option selected value="a">A</option>
        <option value="b">B</option><option selected value="c">C</option></select>
      <select id="empty"></select>
    ''';
    final state = NativeHtmlSelectState.fromHtml(source);
    addTearDown(state.dispose);

    final defaultSelect = selectById(state, source, 'default');
    expect(defaultSelect.size, 0);
    expect(defaultSelect.displaySize, 1);
    expect(state.selectedIndices(defaultSelect.key), [1]);
    expect(state.valueFor(defaultSelect.key), 'a');

    final last = selectById(state, source, 'last');
    expect(state.selectedIndices(last.key), [1]);
    expect(state.valueFor(last.key), 'b');

    final list = selectById(state, source, 'list');
    expect(list.size, 3);
    expect(list.displaySize, 3);
    expect(state.selectedIndices(list.key), isEmpty);

    final multiple = selectById(state, source, 'multiple');
    expect(multiple.size, 0);
    expect(multiple.displaySize, 4);
    expect(multiple.multiple, isTrue);
    expect(state.selectedIndices(multiple.key), isEmpty);

    final fieldsetDisabled = selectById(state, source, 'fieldset-disabled');
    expect(fieldsetDisabled.disabled, isTrue);
    expect(fieldsetDisabled.options.single.disabled, isTrue);
    expect(state.selectedIndices(fieldsetDisabled.key), [0]);

    final allDisabled = selectById(state, source, 'all-disabled');
    expect(state.selectedIndices(allDisabled.key), isEmpty);
    expect(state.valueFor(allDisabled.key), '');

    final explicitDisabled = selectById(state, source, 'explicit-disabled');
    expect(state.selectedIndices(explicitDisabled.key), [0]);
    expect(explicitDisabled.options.first.disabled, isTrue);
    expect(state.valueFor(explicitDisabled.key), 'x');

    final multiSelected = selectById(state, source, 'multi-selected');
    expect(state.selectedIndices(multiSelected.key), [0, 2]);
    expect(state.valueFor(multiSelected.key), 'a');
    expect(selectById(state, source, 'empty').options, isEmpty);
  });

  test(
    'parses option text, value, label, groups, and effective disabledness',
    () {
      const source = '''
      <select id="choice">
        <optgroup label="Unavailable" disabled>
          <option value="x">Hidden by group</option>
        </optgroup>
        <optgroup label="Available">
          <option>  Alpha   label </option>
          <option value="" label="Shown label">Other text</option>
          <option value="z" label="">Third</option>
        </optgroup>
      </select>
    ''';
      final state = NativeHtmlSelectState.fromHtml(source);
      addTearDown(state.dispose);

      final choice = selectById(state, source, 'choice');
      expect(choice.options, hasLength(4));
      expect(choice.options[0].index, 0);
      expect(choice.options[0].group, 'Unavailable');
      expect(choice.options[0].disabled, isTrue);
      expect(choice.options[1].group, 'Available');
      expect(choice.options[1].text, 'Alpha label');
      expect(choice.options[1].value, 'Alpha label');
      expect(choice.options[1].label, 'Alpha label');
      expect(choice.options[2].text, 'Other text');
      expect(choice.options[2].value, '');
      expect(choice.options[2].label, 'Shown label');
      expect(choice.options[3].label, '');
    },
  );

  test('parses size as a non-negative integer and keeps DOM default zero', () {
    const source = '''
      <select id="absent"><option>A</option></select>
      <select id="plus" size="  +3junk"><option>A</option></select>
      <select id="zero" size="0"><option>A</option></select>
      <select id="invalid" size="-2"><option>A</option></select>
      <select id="multiple" multiple size="2"><option>A</option></select>
    ''';
    final state = NativeHtmlSelectState.fromHtml(source);
    addTearDown(state.dispose);

    expect(selectById(state, source, 'absent').size, 0);
    expect(selectById(state, source, 'absent').displaySize, 1);
    expect(selectById(state, source, 'plus').size, 3);
    expect(selectById(state, source, 'plus').displaySize, 3);
    expect(selectById(state, source, 'zero').size, 0);
    expect(selectById(state, source, 'zero').displaySize, 1);
    expect(selectById(state, source, 'invalid').size, 0);
    expect(selectById(state, source, 'invalid').displaySize, 1);
    expect(selectById(state, source, 'multiple').size, 2);
    expect(selectById(state, source, 'multiple').displaySize, 2);
  });

  test(
    'uses nonce markers, duplicate-id first match, labels, and fieldset rules',
    () {
      const source = '''
      <select id="choice" data-pirc-native-select-id="spoof"><option>One</option>
        <option>Two</option></select>
      <label for="choice" data-pirc-native-select-for="spoof">Pick</label>
      <span id="duplicate">First id is text</span><label for="duplicate">No target</label>
      <select id="duplicate"><option>Not associated</option></select>
      <label><span>Wrapped</span><select id="wrapped"><option>Current</option>
        <option>Next</option></select></label>
      <label><button>First labelable</button><select id="later">Later</select></label>
      <fieldset disabled>
        <legend><label for="legend">Legend choice</label>
          <select id="legend"><option>Enabled</option></select></legend>
        <label for="blocked">Blocked choice</label><select id="blocked"><option>Disabled</option></select>
      </fieldset>
      <div hidden><select id="hidden"><option>Hidden</option></select></div>
      <div style="display:none"><select id="none"><option>Hidden</option></select></div>
    ''';
      final state = NativeHtmlSelectState.fromHtml(source);
      addTearDown(state.dispose);

      final annotated = state.annotateHtml(source);
      expect(annotated, isNot(contains('spoof')));
      expect(annotated, contains('data-pirc-native-select-id='));
      expect(() => state.annotateHtml('$source '), throwsArgumentError);
      final fragment = html.parseFragment(annotated);
      expect(
        state
            .resolveLabel(fragment.querySelector('label[for="choice"]')!)
            ?.label,
        'Pick',
      );
      expect(
        state.resolveLabel(fragment.querySelector('label[for="duplicate"]')!),
        isNull,
      );
      expect(
        state.resolveLabel(fragment.querySelector('label:not([for])')!)?.label,
        'Wrapped',
      );
      expect(
        state.resolveLabel(fragment.querySelectorAll('label:not([for])')[1]),
        isNull,
      );
      expect(
        state
            .resolveLabel(fragment.querySelector('label[for="legend"]')!)
            ?.disabled,
        isFalse,
      );
      expect(
        state
            .resolveLabel(fragment.querySelector('label[for="blocked"]')!)
            ?.disabled,
        isTrue,
      );
      expect(selectById(state, source, 'blocked').disabled, isTrue);
      expect(selectById(state, source, 'hidden').visible, isFalse);
      expect(selectById(state, source, 'none').visible, isFalse);
    },
  );

  testWidgets(
    'label activation focuses without changing selectedness; selection does not focus',
    (tester) async {
      const source =
          '<label for="choice">Pick</label><select id="choice">'
          '<option>One</option><option>Two</option></select>';
      final state = NativeHtmlSelectState.fromHtml(source);
      addTearDown(state.dispose);
      final control = selectById(state, source, 'choice');
      final fragment = html.parseFragment(state.annotateHtml(source));
      final label = fragment.querySelector('label')!;
      final focusNode = state.focusNodeFor(control.key);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Focus(focusNode: focusNode, child: const Text('select')),
          ),
        ),
      );
      expect(state.selectedIndices(control.key), [0]);
      state.activateLabel(label);
      await tester.pump();
      expect(focusNode.hasFocus, isTrue);
      expect(state.selectedIndices(control.key), [0]);

      focusNode.unfocus();
      state.select(control.key, 1);
      await tester.pump();
      expect(state.valueFor(control.key), 'Two');
      expect(focusNode.hasFocus, isFalse);
    },
  );

  test(
    'selection supports exclusive, multiple, disabled, and cleared states',
    () {
      const source = '''
      <select id="single"><option value="a">A</option><option value="b">B</option>
        <option disabled value="c">C</option></select>
      <select id="multiple" multiple><option value="a">A</option>
        <option value="b">B</option><option disabled value="c">C</option></select>
      <select id="disabled" disabled><option>A</option><option>B</option></select>
    ''';
      final state = NativeHtmlSelectState.fromHtml(source);
      addTearDown(state.dispose);
      final single = selectById(state, source, 'single');
      final multiple = selectById(state, source, 'multiple');
      final disabled = selectById(state, source, 'disabled');

      expect(state.select(single.key, 1), isTrue);
      expect(state.selectedIndices(single.key), [1]);
      expect(state.valueFor(single.key), 'b');
      // Activating the currently selected dropdown value must not deselect it.
      expect(state.select(single.key, 1), isFalse);
      expect(state.selectedIndices(single.key), [1]);
      expect(state.select(single.key, 1, selected: false), isTrue);
      expect(state.selectedIndices(single.key), isEmpty);
      expect(state.valueFor(single.key), '');
      expect(state.select(single.key, 2), isFalse);
      expect(state.select(disabled.key, 1), isFalse);
      expect(state.select(multiple.key, 0), isTrue);
      expect(state.select(multiple.key, 1), isTrue);
      expect(state.selectedIndices(multiple.key), [0, 1]);
      expect(state.valueFor(multiple.key), 'a');
      expect(state.select(multiple.key, 0, selected: false), isTrue);
      expect(state.selectedIndices(multiple.key), [1]);
    },
  );
}
