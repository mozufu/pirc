import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:html/parser.dart' as html;
import 'package:pirc_render/src/html_controls.dart';

NativeHtmlControlDescriptor _control(
  NativeHtmlControlState state,
  String source,
  String id,
) => state.resolveControl(
  html.parseFragment(state.annotateHtml(source)).querySelector('#$id')!,
)!;

void main() {
  test('activation hook handles checkbox and already-selected radio', () {
    const source = '''
<input id="check" type="checkbox">
<input id="selected" type="radio" name="group" checked>
<input id="next" type="radio" name="group">
''';
    final state = NativeHtmlControlState.fromHtml(source);
    addTearDown(state.dispose);
    final check = _control(state, source, 'check');
    final selected = _control(state, source, 'selected');
    final activations = <String>[];
    final events = <String>[];
    state.onActivateControl = activations.add;
    state.onUserEvent = (key, type) => events.add('$key:$type');

    state.activateControl(check.key);
    state.activateControl(selected.key);

    expect(activations, [check.key, selected.key]);
    expect(state.isChecked(check.key), isFalse);
    expect(state.isChecked(selected.key), isTrue);
    expect(events, isEmpty);
  });

  test('disabled controls do not call the activation hook', () {
    const source = '<input id="check" type="checkbox" disabled checked>';
    final state = NativeHtmlControlState.fromHtml(source);
    addTearDown(state.dispose);
    final check = _control(state, source, 'check');
    final activations = <String>[];
    state.onActivateControl = activations.add;

    state.activateControl(check.key);

    expect(activations, isEmpty);
    expect(state.isChecked(check.key), isTrue);
  });

  test('label activation routes to the associated control hook', () {
    const source =
        '<label for="check">Updates</label>'
        '<input id="check" type="checkbox">';
    final state = NativeHtmlControlState.fromHtml(source);
    addTearDown(state.dispose);
    final fragment = html.parseFragment(state.annotateHtml(source));
    final label = fragment.querySelector('label')!;
    final check = _control(state, source, 'check');
    final activations = <String>[];
    state.onActivateControl = activations.add;

    state.activateLabel(label);

    expect(activations, [check.key]);
    expect(state.isChecked(check.key), isFalse);
  });

  testWidgets('Space release routes activation to the hook', (tester) async {
    const source = '<input id="check" type="checkbox">';
    final state = NativeHtmlControlState.fromHtml(source);
    addTearDown(state.dispose);
    final check = _control(state, source, 'check');
    final activations = <String>[];
    final events = <String>[];
    state.onActivateControl = activations.add;
    state.onUserEvent = (key, type) => events.add('$key:$type');

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: NativeHtmlControlWidget(
            state: state,
            control: check,
            accent: Colors.blue,
          ),
        ),
      ),
    );
    state.focusControl(check.key);
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.space);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.space);

    expect(activations, [check.key]);
    expect(state.isChecked(check.key), isFalse);
    expect(events, isEmpty);
  });

  testWidgets('radio arrow movement routes the next choice to the hook', (
    tester,
  ) async {
    const source = '''
<input id="first" type="radio" name="group" checked>
<input id="second" type="radio" name="group">
''';
    final state = NativeHtmlControlState.fromHtml(source);
    addTearDown(state.dispose);
    final first = _control(state, source, 'first');
    final second = _control(state, source, 'second');
    final activations = <String>[];
    state.onActivateControl = activations.add;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              NativeHtmlControlWidget(
                state: state,
                control: first,
                accent: Colors.blue,
              ),
              NativeHtmlControlWidget(
                state: state,
                control: second,
                accent: Colors.blue,
              ),
            ],
          ),
        ),
      ),
    );
    state.focusControl(first.key);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);

    expect(activations, [second.key]);
    expect(state.isChecked(first.key), isTrue);
    expect(state.isChecked(second.key), isFalse);
  });

  test('without a hook activation keeps local checkedness and events', () {
    const source = '''
<input id="check" type="checkbox">
<input id="first" type="radio" name="group" checked>
<input id="second" type="radio" name="group">
''';
    final state = NativeHtmlControlState.fromHtml(source);
    addTearDown(state.dispose);
    final check = _control(state, source, 'check');
    final first = _control(state, source, 'first');
    final second = _control(state, source, 'second');
    final events = <String>[];
    state.onUserEvent = (key, type) => events.add('$key:$type');

    state.activateControl(check.key);
    state.activateControl(first.key);
    state.activateControl(second.key);
    state.activateControl(second.key);

    expect(state.isChecked(check.key), isTrue);
    expect(state.isChecked(first.key), isFalse);
    expect(state.isChecked(second.key), isTrue);
    expect(events, [
      '${check.key}:input',
      '${check.key}:change',
      '${second.key}:input',
      '${second.key}:change',
    ]);
  });
}
