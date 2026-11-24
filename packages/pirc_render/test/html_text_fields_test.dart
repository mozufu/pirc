import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:html/parser.dart' as html;
import 'package:pirc_render/src/html_text_fields.dart';

NativeHtmlTextFieldDescriptor fieldById(
  NativeHtmlTextFieldState state,
  String source,
  String id,
) {
  final fragment = html.parseFragment(state.annotateHtml(source));
  final element = fragment.querySelector('#$id');
  expect(element, isNotNull);
  return state.resolveControl(element!)!;
}

Widget fieldWidget(
  NativeHtmlTextFieldState state,
  NativeHtmlTextFieldDescriptor field,
) => NativeHtmlTextFieldWidget(
  state: state,
  field: field,
  textStyle: const TextStyle(fontFamily: 'Arial', fontSize: 16),
);

Widget appFor(
  NativeHtmlTextFieldState state,
  Iterable<NativeHtmlTextFieldDescriptor> fields,
) => MaterialApp(
  home: Scaffold(
    body: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [for (final field in fields) fieldWidget(state, field)],
    ),
  ),
);

void main() {
  test(
    'scans supported types, sanitizes initial values and retains metadata',
    () {
      const source = '''
      <input id="plain" value=" a&#10;b ">
      <input id="bad-type" type="made-up" value="fallback">
      <input id="search" type="search" value="query">
      <input id="email" type="email" value="&#10;  user@example.test  &#10;">
      <input id="url" type="url" value="  https://example.test/path  ">
      <input id="tel" type="tel" value="123">
      <input id="password" type="password" value="secret">
      <input id="not-this-slice" type="number" value="7" min="1" max="10" step="0.25">
      <input id="invalid-number" type="number" value="1.">
      <input id="exponent-number" type="number" value="-1.25e2" step="any">
      <textarea id="notes" rows=" +3" cols=" 24 " maxlength="8"
        minlength="2" required>first&#10;second</textarea>
    ''';
      final state = NativeHtmlTextFieldState.fromHtml(source);
      addTearDown(state.dispose);

      expect(fieldById(state, source, 'plain').initialValue, ' ab ');
      expect(
        fieldById(state, source, 'bad-type').kind,
        NativeHtmlTextFieldKind.text,
      );
      expect(
        fieldById(state, source, 'search').kind,
        NativeHtmlTextFieldKind.search,
      );
      expect(
        fieldById(state, source, 'email').initialValue,
        'user@example.test',
      );
      expect(
        fieldById(state, source, 'url').initialValue,
        'https://example.test/path',
      );
      expect(fieldById(state, source, 'tel').kind, NativeHtmlTextFieldKind.tel);
      expect(
        fieldById(state, source, 'password').kind,
        NativeHtmlTextFieldKind.password,
      );
      final number = html
          .parseFragment(state.annotateHtml(source))
          .querySelector('#not-this-slice')!;
      final amount = state.resolveControl(number)!;
      expect(amount.kind, NativeHtmlTextFieldKind.number);
      expect(amount.initialValue, '7');
      expect(amount.min, '1');
      expect(amount.max, '10');
      expect(amount.step, '0.25');
      expect(fieldById(state, source, 'invalid-number').initialValue, '');
      final exponent = fieldById(state, source, 'exponent-number');
      expect(exponent.initialValue, '-1.25e2');
      expect(exponent.step, 'any');

      final notes = fieldById(state, source, 'notes');
      expect(notes.kind, NativeHtmlTextFieldKind.textarea);
      expect(notes.initialValue, 'first\nsecond');
      expect(notes.rows, 3);
      expect(notes.cols, 24);
      expect(notes.maxLength, 8);
      expect(notes.minLength, 2);
      expect(notes.required, isTrue);
    },
  );

  testWidgets('number input uses numeric edits and HTML step bounds', (
    tester,
  ) async {
    const source = '''
      <input id="amount" type="number" min="0" max="2" step="0.25" value="1.3">
      <input id="empty" type="number">
      <input id="any" type="number" step="any" value="1.5">
    ''';
    final state = NativeHtmlTextFieldState.fromHtml(source);
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      state.dispose();
    });

    final amount = fieldById(state, source, 'amount');
    await tester.pumpWidget(appFor(state, [amount]));
    final textField = tester.widget<TextField>(find.byType(TextField));
    expect(
      textField.keyboardType,
      const TextInputType.numberWithOptions(decimal: true, signed: true),
    );
    final semantics = tester
        .getSemantics(
          find.byKey(ValueKey('native-html-text-field-${amount.key}')),
        )
        .getSemanticsData();
    expect(semantics.hasAction(SemanticsAction.increase), isTrue);
    expect(semantics.hasAction(SemanticsAction.decrease), isTrue);
    state.focusControl(amount.key);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    expect(state.valueFor(amount.key), '1.5');
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    expect(state.valueFor(amount.key), '1.25');
    await tester.enterText(find.byType(TextField), '3');
    expect(state.valueFor(amount.key), '3');
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    expect(state.valueFor(amount.key), '2');
    await tester.enterText(find.byType(TextField), '-0.125');
    expect(state.valueFor(amount.key), '-0.125');
    await tester.enterText(find.byType(TextField), '1.25e2');
    expect(state.valueFor(amount.key), '1.25e2');
    await tester.enterText(find.byType(TextField), 'not a number');
    expect(state.valueFor(amount.key), '1.25e2');

    final empty = fieldById(state, source, 'empty');
    await tester.pumpWidget(appFor(state, [empty]));
    state.focusControl(empty.key);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    expect(state.valueFor(empty.key), '1');
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    expect(state.valueFor(empty.key), '0');

    final any = fieldById(state, source, 'any');
    await tester.pumpWidget(appFor(state, [any]));
    state.focusControl(any.key);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    expect(state.valueFor(any.key), '2.5');
  });

  test(
    'uses nonce markers, rejects spoofed markers and requires exact source',
    () {
      const source = '''
      <input id="one" data-pirc-native-text-field-id="spoof" value="first">
      <label for="one" data-pirc-native-text-field-for="spoof">First field</label>
    ''';
      final state = NativeHtmlTextFieldState.fromHtml(source);
      addTearDown(state.dispose);

      final annotated = state.annotateHtml(source);
      expect(annotated, isNot(contains('spoof')));
      expect(annotated, contains('data-pirc-native-text-field-id='));
      final fragment = html.parseFragment(annotated);
      final input = fragment.querySelector('#one')!;
      final label = fragment.querySelector('label')!;
      expect(state.resolveControl(input)?.initialValue, 'first');
      expect(state.resolveLabel(label)?.label, 'First field');
      expect(() => state.annotateHtml('$source '), throwsArgumentError);
    },
  );

  test('resolves labels with HTML first-target and fieldset rules', () {
    const source = '''
      <fieldset disabled>
        <legend>
          <label for="legend-field">Enabled legend field</label>
          <input id="legend-field" value="ok">
        </legend>
        <label for="outside">Disabled field</label><input id="outside">
        <legend><input id="second-legend"></legend>
      </fieldset>
      <label for="duplicate">Duplicate target</label>
      <span id="duplicate">not a field</span><input id="duplicate">
      <label><input type="checkbox"><input id="later">Nested control</label>
      <label for="readonly">Read only label</label>
      <input id="readonly" readonly value="fixed">
      <input id="hidden" hidden>
      <div style="display: none"><input id="display-none"></div>
    ''';
    final state = NativeHtmlTextFieldState.fromHtml(source);
    addTearDown(state.dispose);

    final annotated = html.parseFragment(state.annotateHtml(source));
    final legendLabel = annotated.querySelector('label[for="legend-field"]')!;
    final outsideLabel = annotated.querySelector('label[for="outside"]')!;
    final duplicateLabel = annotated.querySelector('label[for="duplicate"]')!;
    final wrappingLabel = annotated.querySelector('label:not([for])')!;
    final readOnlyLabel = annotated.querySelector('label[for="readonly"]')!;

    expect(state.resolveLabel(legendLabel)?.disabled, isFalse);
    expect(state.resolveLabel(outsideLabel)?.disabled, isTrue);
    expect(state.resolveLabel(duplicateLabel), isNull);
    expect(state.resolveLabel(wrappingLabel), isNull);
    expect(fieldById(state, source, 'second-legend').disabled, isTrue);
    expect(fieldById(state, source, 'hidden').visible, isFalse);
    expect(fieldById(state, source, 'display-none').visible, isFalse);
    expect(state.resolveLabel(readOnlyLabel)?.readOnly, isTrue);
  });

  testWidgets(
    'typing updates the document controller and maxlength uses UTF-16',
    (tester) async {
      const source =
          '<input id="bounded" maxlength="2" value="">'
          '<input id="composed" maxlength="4" value="">';
      final state = NativeHtmlTextFieldState.fromHtml(source);
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        state.dispose();
      });
      final bounded = fieldById(state, source, 'bounded');
      final composed = fieldById(state, source, 'composed');

      await tester.pumpWidget(appFor(state, [bounded]));
      await tester.enterText(find.byType(TextField), '😀ab');
      await tester.pump();
      expect(state.valueFor(bounded.key), '😀');

      // Active IME composition can temporarily exceed maxlength; the committed
      // update is then restricted using UTF-16 code-unit length.
      await tester.pumpWidget(appFor(state, [composed]));
      final formatters = tester
          .widget<TextField>(find.byType(TextField))
          .inputFormatters!;
      TextEditingValue formatEdit(
        TextEditingValue oldValue,
        TextEditingValue newValue,
      ) => formatters.fold(
        newValue,
        (value, formatter) => formatter.formatEditUpdate(oldValue, value),
      );
      final composing = TextEditingValue(
        text: 'abcdef',
        selection: const TextSelection.collapsed(offset: 6),
        composing: const TextRange(start: 2, end: 5),
      );
      final composingResult = formatEdit(TextEditingValue.empty, composing);
      expect(composingResult.text, 'abcdef');
      expect(composingResult.composing, const TextRange(start: 2, end: 5));
      final committed = formatEdit(
        composingResult,
        composingResult.copyWith(
          selection: const TextSelection.collapsed(offset: 6),
          composing: TextRange.empty,
        ),
      );
      expect(committed.text, 'abcd');
    },
  );

  testWidgets(
    'labels focus fields; disabled fields reject focus; readonly stays focusable',
    (tester) async {
      const source = '''
      <label for="readonly">Read only label</label>
      <input id="readonly" readonly value="fixed">
      <label>Wrapped <span>field</span><input id="wrapped" value="inside"></label>
      <fieldset disabled>
        <legend><label for="legend-field">Legend label</label>
          <input id="legend-field"></legend>
        <label for="disabled">Disabled label</label><input id="disabled">
      </fieldset>
    ''';
      final state = NativeHtmlTextFieldState.fromHtml(source);
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        state.dispose();
      });
      final readOnly = fieldById(state, source, 'readonly');
      final wrapped = fieldById(state, source, 'wrapped');
      final legend = fieldById(state, source, 'legend-field');
      final disabled = fieldById(state, source, 'disabled');

      await tester.pumpWidget(
        appFor(state, [readOnly, wrapped, legend, disabled]),
      );
      expect(
        tester.widget<TextField>(find.byType(TextField).first).readOnly,
        isTrue,
      );
      expect(
        tester.widget<TextField>(find.byType(TextField).last).enabled,
        isFalse,
      );

      final readOnlyLabel = html
          .parseFragment(state.annotateHtml(source))
          .querySelector('label[for="readonly"]')!;
      state.activateLabel(readOnlyLabel);
      await tester.pump();
      expect(state.focusNodeFor(readOnly.key).hasFocus, isTrue);
      expect(state.valueFor(readOnly.key), 'fixed');

      final wrappedLabel = html
          .parseFragment(state.annotateHtml(source))
          .querySelector('label:not([for])')!;
      expect(state.resolveLabel(wrappedLabel)?.key, wrapped.key);
      state.activateLabel(wrappedLabel);
      await tester.pump();
      expect(state.focusNodeFor(wrapped.key).hasFocus, isTrue);
      expect(state.valueFor(wrapped.key), 'inside');

      final disabledLabel = html
          .parseFragment(state.annotateHtml(source))
          .querySelector('label[for="disabled"]')!;
      state.activateLabel(disabledLabel);
      state.focusControl(disabled.key);
      await tester.pump();
      expect(state.focusNodeFor(disabled.key).hasFocus, isFalse);
    },
  );

  testWidgets('same-document rebuild retains edits; replacement state resets', (
    tester,
  ) async {
    const source = '<input id="value" value="before">';
    final state = NativeHtmlTextFieldState.fromHtml(source);
    NativeHtmlTextFieldState? replacementState;
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      replacementState?.dispose();
      state.dispose();
    });
    var field = fieldById(state, source, 'value');

    await tester.pumpWidget(appFor(state, [field]));
    await tester.enterText(find.byType(TextField), 'edited');
    await tester.pump();
    expect(state.valueFor(field.key), 'edited');

    await tester.pumpWidget(appFor(state, [field]));
    expect(state.valueFor(field.key), 'edited');

    const replacementSource = '<input id="value" value="replacement">';
    final newState = NativeHtmlTextFieldState.fromHtml(replacementSource);
    replacementState = newState;
    final replacement = fieldById(newState, replacementSource, 'value');
    await tester.pumpWidget(appFor(newState, [replacement]));
    expect(newState.valueFor(replacement.key), 'replacement');
  });
}
