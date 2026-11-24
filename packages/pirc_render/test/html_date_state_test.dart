import 'package:flutter_test/flutter_test.dart';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html;
import 'package:pirc_render/src/html_date.dart';
import 'package:pirc_render/src/html_date_validation.dart';

NativeHtmlDateState stateFor(String source) =>
    NativeHtmlDateState.fromHtml(source);

dom.Element controlById(NativeHtmlDateState state, String source, String id) {
  final fragment = html.parseFragment(state.annotateHtml(source));
  return fragment.querySelector('#$id')!;
}

NativeHtmlDateDescriptor descriptorById(
  NativeHtmlDateState state,
  String source,
  String id,
) => state.resolveControl(controlById(state, source, id))!;

void main() {
  test('annotates date controls and resolves labels and constraints', () {
    const source = '''
<label for="visit">Visit date</label>
<span id="hint">Choose a weekday.</span>
<input id="visit" type="date" name="visit" value="2024-02-29"
 min="2024-02-01" max="2024-03-31" step="2" required
 aria-describedby="hint">
<label><input id="wrapped" type="date" value="2024-03-01"> Wrapped date</label>
''';
    final state = stateFor(source);
    addTearDown(state.dispose);

    final annotated = state.annotateHtml(source);
    expect(annotated, contains('data-pirc-native-date-id='));
    expect(annotated, contains('data-pirc-native-date-for='));
    final visit = descriptorById(state, source, 'visit');
    final wrapped = descriptorById(state, source, 'wrapped');
    final annotatedFragment = html.parseFragment(annotated);
    final dateLabel = annotatedFragment.querySelector('label[for="visit"]')!;

    expect(visit.initialValue, '2024-02-29');
    expect(visit.valueAttribute, '2024-02-29');
    expect(visit.min, '2024-02-01');
    expect(visit.max, '2024-03-31');
    expect(visit.step, '2');
    expect(visit.stepBase.canonical, '2024-02-01');
    expect(visit.required, isTrue);
    expect(visit.name, 'visit');
    expect(visit.label, 'Visit date');
    expect(visit.hint, 'Choose a weekday.');
    expect(wrapped.label, 'Wrapped date');
    expect(state.resolveLabel(dateLabel)?.key, visit.key);
    expect(state.valueFor(visit.key), '2024-02-29');
  });

  test('sanitizes invalid value/min/max attributes to their HTML defaults', () {
    const source =
        '<input id="invalid" type="date" value="2024-2-09" '
        'min="2024-02-30" max="tomorrow" required>';
    final state = stateFor(source);
    addTearDown(state.dispose);
    final field = descriptorById(state, source, 'invalid');

    expect(field.initialValue, isEmpty);
    expect(field.valueAttribute, isNull);
    expect(field.min, isNull);
    expect(field.max, isNull);
    expect(field.stepBase.canonical, '1970-01-01');
    expect(state.validityFor(field.key).valueMissing, isTrue);
    expect(state.badInputFor(field.key), isFalse);
  });

  test('disabled fieldsets honor only the first legend exception', () {
    const source = '''
<fieldset disabled>
 <legend><label><input id="legend" type="date" value="2024-02-29">Legend</label></legend>
 <input id="outside" type="date" value="2024-02-29">
 <legend><input id="second-legend" type="date"></legend>
</fieldset>
<input id="disabled" type="date" disabled>
<input id="readonly" type="date" readonly required>
<input id="hidden" type="date" hidden>
<input id="style-hidden" type="date" style="display:none">
''';
    final state = stateFor(source);
    addTearDown(state.dispose);
    final legend = descriptorById(state, source, 'legend');
    final outside = descriptorById(state, source, 'outside');
    final secondLegend = descriptorById(state, source, 'second-legend');
    final disabled = descriptorById(state, source, 'disabled');
    final readonly = descriptorById(state, source, 'readonly');
    final hidden = descriptorById(state, source, 'hidden');
    final styleHidden = descriptorById(state, source, 'style-hidden');

    expect(legend.disabled, isFalse);
    expect(outside.disabled, isTrue);
    expect(secondLegend.disabled, isTrue);
    expect(disabled.disabled, isTrue);
    expect(readonly.readOnly, isTrue);
    expect(readonly.willValidate, isFalse);
    expect(state.validityFor(readonly.key).valid, isTrue);
    expect(hidden.visible, isFalse);
    expect(styleHidden.visible, isFalse);
  });

  test('ARIA name precedence and marker lookalikes are safe', () {
    const source = '''
<span id="name">Referenced date</span><span id="hint">Date hint</span>
<input id="date" type="date" aria-labelledby="missing name"
 aria-label="Fallback" aria-describedby="hint"
 data-pirc-native-date-id="spoof">
<label for="date" data-pirc-native-date-for="spoof">Associated</label>
''';
    final state = stateFor(source);
    addTearDown(state.dispose);
    final annotated = state.annotateHtml(source);
    expect(annotated, isNot(contains('spoof')));
    final date = descriptorById(state, source, 'date');
    final annotatedFragment = html.parseFragment(annotated);
    final label = annotatedFragment.querySelector('label[for="date"]')!;
    expect(date.label, 'Referenced date');
    expect(date.hint, 'Date hint');
    expect(state.resolveLabel(label)?.key, date.key);
  });

  test('segmented edits expose canonical value and bad-input state', () {
    const source =
        '<input id="date" type="date" name="date" required value="2024-02-29">';
    final state = stateFor(source);
    addTearDown(state.dispose);
    final field = descriptorById(state, source, 'date');

    state.updateSegment(field.key, NativeHtmlDateSegment.month, '3');
    expect(state.valueFor(field.key), '2024-03-29');
    expect(state.badInputFor(field.key), isFalse);
    expect(state.wasUserEdited(field.key), isTrue);

    state.updateSegment(field.key, NativeHtmlDateSegment.month, '2');
    expect(state.valueFor(field.key), '2024-02-29');
    state.updateSegment(field.key, NativeHtmlDateSegment.year, '2023');
    expect(state.valueFor(field.key), isEmpty);
    expect(state.badInputFor(field.key), isTrue);
    expect(state.validityFor(field.key).badInput, isTrue);
    expect(state.validityFor(field.key).valueMissing, isTrue);

    state.setValue(field.key, '2024-2-09');
    expect(state.valueFor(field.key), isEmpty);
    expect(state.badInputFor(field.key), isFalse);
    expect(state.wasUserEdited(field.key), isFalse);
    state.setDate(field.key, NativeHtmlDateValue.parse('2024-02-29'));
    expect(state.valueFor(field.key), '2024-02-29');
    state.clear(field.key);
    expect(state.valueFor(field.key), isEmpty);
    expect(state.validityFor(field.key).valueMissing, isTrue);
  });

  test(
    'reset restores defaults and history restores valid and partial drafts',
    () {
      const source =
          '<input id="date" type="date" name="date" value="2024-02-29">';
      final state = stateFor(source);
      addTearDown(state.dispose);
      final field = descriptorById(state, source, 'date');

      state.setDate(field.key, NativeHtmlDateValue.parse('2024-03-01'));
      final validSnapshot = state.captureHistory();
      state.clear(field.key);
      state.restoreHistory(validSnapshot);
      expect(state.valueFor(field.key), '2024-03-01');

      state.updateSegment(field.key, NativeHtmlDateSegment.month, '2');
      state.updateSegment(field.key, NativeHtmlDateSegment.day, '30');
      state.updateSegment(field.key, NativeHtmlDateSegment.year, '2024');
      expect(state.badInputFor(field.key), isTrue);
      expect(state.valueFor(field.key), isEmpty);
      final partialSnapshot = state.captureHistory();
      state.setDate(field.key, NativeHtmlDateValue.parse('2023-05-06'));
      state.restoreHistory(partialSnapshot);
      expect(state.valueFor(field.key), isEmpty);
      expect(state.badInputFor(field.key), isTrue);
      expect(
        state.segmentControllerFor(field.key, NativeHtmlDateSegment.day).text,
        '30',
      );

      state.resetDefaults();
      expect(state.valueFor(field.key), '2024-02-29');
      expect(state.badInputFor(field.key), isFalse);
      expect(state.wasUserEdited(field.key), isFalse);
    },
  );

  test(
    'successful values include empty and readonly, omit disabled controls',
    () {
      const source = '''
<input id="filled" type="date" name="day" value="2024-02-29">
<input id="empty" type="date" name="empty">
<input id="disabled" type="date" name="disabled" value="2024-02-29" disabled>
<input id="readonly" type="date" name="readonly" value="2024-03-01" readonly>
''';
      final state = stateFor(source);
      addTearDown(state.dispose);
      final fields = [
        for (final id in ['filled', 'empty', 'disabled', 'readonly'])
          descriptorById(state, source, id),
      ];
      expect(
        state.successfulValues().map((entry) => (entry.name, entry.value)),
        [('day', '2024-02-29'), ('empty', ''), ('readonly', '2024-03-01')],
      );
      state.resetDefaults(fields.map((field) => field.key));
      expect(state.valuesFor(fields.map((field) => field.key)).length, 4);
    },
  );
}
