import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html;
import 'package:pirc_render/src/html_controls.dart';

NativeHtmlControlDescriptor controlById(
  NativeHtmlControlState state,
  String source,
  String id,
) {
  final fragment = html.parseFragment(state.annotateHtml(source));
  final input = fragment.querySelector('input#$id');
  expect(input, isNotNull);
  return state.resolveControl(input!)!;
}

NativeHtmlControlState controls(String source) =>
    NativeHtmlControlState.fromHtml(source);

dom.Element elementById(
  NativeHtmlControlState state,
  String source,
  String id,
) {
  final fragment = html.parseFragment(state.annotateHtml(source));
  return fragment.querySelector('#$id')!;
}

ValueKey<String> semanticsKey(NativeHtmlControlDescriptor control) =>
    ValueKey('native-html-control-${control.key}');

void main() {
  test('marks controls and resolves labels across HtmlWidget reparsing', () {
    const source = '''
<label for="mail">Send updates</label>
<input id="mail" type="checkbox" aria-describedby="help">
<span id="help">Description</span>
<label><input id="choice" type="radio" name="group" checked>First answer</label>
''';
    final state = controls(source);
    addTearDown(state.dispose);

    final annotated = state.annotateHtml(source);
    expect(annotated, contains('data-pirc-native-control-id='));
    expect(annotated, contains('data-pirc-native-control-for='));
    final reparsed = html.parseFragment(annotated);
    final mail = state.resolveControl(reparsed.querySelector('#mail')!)!;
    final choice = state.resolveControl(reparsed.querySelector('#choice')!)!;
    final explicitLabel = state.resolveLabel(
      reparsed.querySelector('label[for="mail"]')!,
    );
    final wrappingLabel = reparsed.querySelectorAll('label').last;

    expect(mail.type, NativeHtmlControlType.checkbox);
    expect(mail.label, 'Send updates');
    expect(mail.hint, 'Description');
    expect(mail.disabled, isFalse);
    expect(mail.checked, isFalse);
    expect(choice.type, NativeHtmlControlType.radio);
    expect(choice.label, 'First answer');
    expect(choice.checked, isTrue);
    expect(explicitLabel?.key, mail.key);
    expect(state.resolveLabel(wrappingLabel)?.key, choice.key);

    final spoofed = NativeHtmlControlState.fromHtml(
      '<input id="mail" type="checkbox" data-pirc-native-control-id="attacker">'
      '<label for="mail" data-pirc-native-control-for="attacker">Safe</label>',
    );
    addTearDown(spoofed.dispose);
    final safeMarkup = spoofed.annotateHtml(
      '<input id="mail" type="checkbox" data-pirc-native-control-id="attacker">'
      '<label for="mail" data-pirc-native-control-for="attacker">Safe</label>',
    );
    expect(safeMarkup, isNot(contains('attacker')));
    expect(
      spoofed
          .resolveLabel(html.parseFragment(safeMarkup).querySelector('label')!)
          ?.label,
      'Safe',
    );
  });

  test('referenced accessible name takes precedence over aria-label', () {
    const source =
        '<span id="name">Referenced name</span>'
        '<input id="choice" type="checkbox" aria-label="Fallback name" '
        'aria-labelledby="missing name">';
    final state = controls(source);
    addTearDown(state.dispose);
    expect(controlById(state, source, 'choice').label, 'Referenced name');
  });

  testWidgets('Space activates on release and cancels after losing focus', (
    tester,
  ) async {
    for (final type in ['checkbox', 'radio']) {
      final source = '<input id="choice" type="$type">';
      final state = controls(source);
      final choice = controlById(state, source, 'choice');
      final other = FocusNode();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                NativeHtmlControlWidget(
                  state: state,
                  control: choice,
                  accent: Colors.blue,
                ),
                Focus(focusNode: other, child: const Text('Other focus')),
              ],
            ),
          ),
        ),
      );
      state.focusControl(choice.key);
      await tester.pump();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.space);
      expect(state.isChecked(choice.key), isFalse);
      await tester.sendKeyRepeatEvent(LogicalKeyboardKey.space);
      expect(state.isChecked(choice.key), isFalse);
      other.requestFocus();
      await tester.pump();
      await tester.sendKeyUpEvent(LogicalKeyboardKey.space);
      expect(state.isChecked(choice.key), isFalse);
      state.focusControl(choice.key);
      await tester.pump();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.space);
      expect(state.isChecked(choice.key), isFalse);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.space);
      expect(state.isChecked(choice.key), isTrue);
      await tester.pumpWidget(const SizedBox.shrink());
      other.dispose();
      state.dispose();
    }
  });

  test('same-name radios are exclusive and isolated by form owner', () {
    const source = '''
<form id="one">
 <input id="alpha" type="radio" name="answer" checked>
 <input id="beta" type="radio" name="answer">
</form>
<form id="two"><input id="other" type="radio" name="answer" checked></form>
''';
    final state = controls(source);
    addTearDown(state.dispose);
    final alpha = controlById(state, source, 'alpha');
    final beta = controlById(state, source, 'beta');
    final other = controlById(state, source, 'other');

    expect(state.isChecked(alpha.key), isTrue);
    expect(state.isChecked(other.key), isTrue);
    state.activateControl(beta.key);
    expect(state.isChecked(alpha.key), isFalse);
    expect(state.isChecked(beta.key), isTrue);
    expect(state.isChecked(other.key), isTrue);
    state.activateControl(beta.key);
    expect(state.isChecked(beta.key), isTrue);
  });

  test('disabled fieldset honors the first legend exception', () {
    const source = '''
<fieldset disabled>
 <legend><label><input id="legend" type="checkbox">Enabled in legend</label></legend>
 <label><input id="outside" type="checkbox">Disabled in fieldset</label>
 <legend><input id="second-legend" type="checkbox"></legend>
</fieldset>
''';
    final state = controls(source);
    addTearDown(state.dispose);
    final legend = controlById(state, source, 'legend');
    final outside = controlById(state, source, 'outside');
    final second = controlById(state, source, 'second-legend');

    expect(legend.disabled, isFalse);
    expect(outside.disabled, isTrue);
    expect(second.disabled, isTrue);
    state.activateLabel(
      elementById(state, source, 'outside').parent as dom.Element,
    );
    expect(state.isChecked(outside.key), isFalse);
    state.activateLabel(
      elementById(state, source, 'legend').parent as dom.Element,
    );
    expect(state.isChecked(legend.key), isTrue);
  });

  testWidgets('checkbox uses a small native-style control and Space toggles', (
    tester,
  ) async {
    final model = controls(
      '<input id="enabled" type="checkbox" aria-label="Enabled">'
      '<input id="disabled" type="checkbox" checked disabled aria-label="Disabled">',
    );
    addTearDown(model.dispose);
    const source =
        '<input id="enabled" type="checkbox" aria-label="Enabled">'
        '<input id="disabled" type="checkbox" checked disabled aria-label="Disabled">';
    final enabled = controlById(model, source, 'enabled');
    final disabled = controlById(model, source, 'disabled');
    final semantics = tester.ensureSemantics();

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Row(
            children: [
              NativeHtmlControlWidget(
                state: model,
                control: enabled,
                accent: const Color(0xff4176e6),
              ),
              NativeHtmlControlWidget(
                state: model,
                control: disabled,
                accent: const Color(0xff4176e6),
              ),
            ],
          ),
        ),
      ),
    );

    final enabledFinder = find.byKey(semanticsKey(enabled));
    final disabledFinder = find.byKey(semanticsKey(disabled));
    expect(
      tester.getSize(
        find.descendant(of: enabledFinder, matching: find.byType(CustomPaint)),
      ),
      const Size(13, 13),
    );
    final unfocusedPainter = tester
        .widget<CustomPaint>(
          find.descendant(
            of: enabledFinder,
            matching: find.byType(CustomPaint),
          ),
        )
        .painter!;
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    expect(model.isChecked(enabled.key), isFalse);
    expect(
      tester
          .getSemantics(enabledFinder)
          .getSemanticsData()
          .flagsCollection
          .isFocused,
      ui.Tristate.isTrue,
    );
    final focusedPainter = tester
        .widget<CustomPaint>(
          find.descendant(
            of: enabledFinder,
            matching: find.byType(CustomPaint),
          ),
        )
        .painter!;
    expect(unfocusedPainter.shouldRepaint(focusedPainter), isTrue);
    expect(
      tester
          .getSemantics(enabledFinder)
          .getSemanticsData()
          .flagsCollection
          .isChecked,
      ui.CheckedState.isFalse,
    );
    await tester.tap(enabledFinder);
    await tester.pump();
    expect(model.isChecked(enabled.key), isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump();
    expect(model.isChecked(enabled.key), isFalse);
    await tester.tap(disabledFinder);
    await tester.pump();
    expect(model.isChecked(disabled.key), isTrue);
    expect(tester.takeException(), isNull);
    semantics.dispose();
  });

  testWidgets(
    'radio arrow keys skip disabled items and Enter does not toggle',
    (tester) async {
      const source = '''
<input id="alpha" type="radio" name="g" checked aria-label="Alpha">
<input id="beta" type="radio" name="g" disabled aria-label="Beta">
<span style="display:none"><input id="gamma" type="radio" name="g" aria-label="Hidden gamma"></span>
<input id="delta" type="radio" name="g" aria-label="Delta">
''';
      final model = controls(source);
      addTearDown(model.dispose);
      final alpha = controlById(model, source, 'alpha');
      final beta = controlById(model, source, 'beta');
      final gamma = controlById(model, source, 'gamma');
      final delta = controlById(model, source, 'delta');
      final semantics = tester.ensureSemantics();

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Row(
              children: [
                for (final control in [alpha, beta, delta])
                  NativeHtmlControlWidget(
                    state: model,
                    control: control,
                    accent: const Color(0xff4176e6),
                  ),
              ],
            ),
          ),
        ),
      );

      final alphaFinder = find.byKey(semanticsKey(alpha));
      await tester.tap(alphaFinder);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      expect(model.isChecked(alpha.key), isFalse);
      expect(model.isChecked(beta.key), isFalse);
      expect(model.isChecked(gamma.key), isFalse);
      expect(gamma.visible, isFalse);
      expect(model.isChecked(delta.key), isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(model.isChecked(delta.key), isTrue);
      expect(
        tester
            .getSemantics(find.byKey(semanticsKey(delta)))
            .getSemanticsData()
            .flagsCollection
            .isFocused,
        ui.Tristate.isTrue,
      );
      expect(model.isTabStop(delta.key), isTrue);
      expect(model.isTabStop(alpha.key), isFalse);
      expect(model.isTabStop(beta.key), isFalse);
      expect(model.isTabStop(gamma.key), isFalse);
      expect(tester.takeException(), isNull);
      semantics.dispose();
    },
  );
}
