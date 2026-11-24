import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:html/parser.dart' as html;
import 'package:pirc_render/src/html_text_fields.dart';

class _FieldBinding {
  const _FieldBinding({
    required this.state,
    required this.field,
    required this.domId,
  });

  final NativeHtmlTextFieldState state;
  final NativeHtmlTextFieldDescriptor field;
  final String domId;
}

List<_FieldBinding> _bindings(String source) {
  final state = NativeHtmlTextFieldState.fromHtml(source);
  final fragment = html.parseFragment(state.annotateHtml(source));
  return fragment
      .querySelectorAll('input,textarea')
      .map((element) {
        final field = state.resolveControl(element)!;
        return _FieldBinding(
          state: state,
          field: field,
          domId: element.attributes['id'] ?? '',
        );
      })
      .toList(growable: false);
}

_FieldBinding _binding(String source, String id) =>
    _bindings(source).firstWhere((binding) => binding.domId == id);

Widget _page(Iterable<_FieldBinding> fields) => MaterialApp(
  home: Scaffold(
    body: SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final binding in fields)
            NativeHtmlTextFieldWidget(
              state: binding.state,
              field: binding.field,
              textStyle: const TextStyle(fontSize: 16),
            ),
        ],
      ),
    ),
  ),
);

void main() {
  testWidgets('user text edit emits input then one change on blur', (
    tester,
  ) async {
    const source =
        '<input id="entry" value="Initial" data-pirc-script-id="entry">';
    final binding = _binding(source, 'entry');
    final events = <String>[];
    binding.state.onUserEvent = (key, type) => events.add('$key:$type');

    await tester.pumpWidget(_page([binding]));
    await tester.pumpAndSettle();

    binding.state.focusNodeFor(binding.field.key).requestFocus();
    await tester.pump();
    expect(events, isEmpty);

    await tester.enterText(find.byType(EditableText), 'Edited');
    expect(events, ['${binding.field.key}:input']);
    binding.state.focusNodeFor(binding.field.key).unfocus();
    await tester.pump();
    expect(events, [
      '${binding.field.key}:input',
      '${binding.field.key}:change',
    ]);

    binding.state.focusNodeFor(binding.field.key).unfocus();
    await tester.pump();
    expect(events, [
      '${binding.field.key}:input',
      '${binding.field.key}:change',
    ]);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox());
    binding.state.dispose();
  });

  testWidgets('focus, history, programmatic edits, and reset emit no events', (
    tester,
  ) async {
    const source =
        '<input id="entry" value="Initial" data-pirc-script-id="entry">';
    final binding = _binding(source, 'entry');
    final events = <String>[];
    final detailedValueEvents = <String>[];
    final state = binding.state;
    final key = binding.field.key;
    state.onUserEvent = (_, type) => events.add(type);
    state.onDetailedUserEvent = (_, type, _) {
      if (type == 'input' || type == 'change') {
        detailedValueEvents.add(type);
      }
    };

    await tester.pumpWidget(_page([binding]));
    await tester.pumpAndSettle();

    final focus = state.focusNodeFor(key);
    focus.requestFocus();
    await tester.pump();
    state.controllerFor(key).text = 'Programmatic history value';
    state.recordUserEdit(key);
    await tester.pump();
    focus.unfocus();
    await tester.pump();
    expect(events, isEmpty);
    expect(detailedValueEvents, isEmpty);

    focus.requestFocus();
    await tester.pump();
    await tester.enterText(find.byType(EditableText), 'User edit');
    expect(events, ['input']);
    expect(detailedValueEvents, ['input']);
    state.resetDefaults([key]);
    await tester.pump();
    focus.unfocus();
    await tester.pump();
    expect(state.valueFor(key), 'Initial');
    expect(events, ['input']);
    expect(detailedValueEvents, ['input']);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox());
    state.dispose();
  });

  testWidgets('IME composition events follow composing ranges', (tester) async {
    const source = '<input id="entry" data-pirc-script-id="entry">';
    final binding = _binding(source, 'entry');
    final events = <String>[];
    final inputData = <Map<String, dynamic>>[];
    final compositionData = <String, List<String>>{};
    binding.state.onDetailedUserEvent = (_, type, eventData) {
      events.add(type);
      if (type == 'input') inputData.add(Map.of(eventData));
      if (type.startsWith('composition')) {
        compositionData
            .putIfAbsent(type, () => <String>[])
            .add(eventData['data'] as String? ?? '');
      }
    };

    await tester.pumpWidget(_page([binding]));
    await tester.pumpAndSettle();
    binding.state.focusNodeFor(binding.field.key).requestFocus();
    await tester.pump();

    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: '漢',
        selection: TextSelection.collapsed(offset: 1),
        composing: TextRange(start: 0, end: 1),
      ),
    );
    await tester.pump();
    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: '日',
        selection: TextSelection.collapsed(offset: 1),
        composing: TextRange(start: 0, end: 1),
      ),
    );
    await tester.pump();
    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: '日',
        selection: TextSelection.collapsed(offset: 1),
        composing: TextRange.empty,
      ),
    );
    await tester.pump();

    expect(events, [
      'focus',
      'focusin',
      'compositionstart',
      'compositionupdate',
      'input',
      'compositionupdate',
      'input',
      'compositionend',
    ]);
    expect(compositionData['compositionstart'], ['']);
    expect(compositionData['compositionupdate'], ['漢', '日']);
    expect(compositionData['compositionend'], ['日']);
    expect(inputData, [
      {'data': '漢', 'inputType': 'insertCompositionText', 'isComposing': true},
      {'data': '日', 'inputType': 'insertCompositionText', 'isComposing': true},
    ]);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox());
    binding.state.dispose();
  });

  testWidgets('replacement input metadata preserves emoji code points', (
    tester,
  ) async {
    final binding = _binding(
      '<input id="entry" value="😀" data-pirc-script-id="entry">',
      'entry',
    );
    final values = <Object?>[];
    binding.state.onDetailedUserEvent = (_, type, data) {
      if (type == 'input') values.add(data['data']);
    };
    await tester.pumpWidget(_page([binding]));
    await tester.enterText(find.byType(EditableText), '😁');
    expect(values, ['😁']);
    await tester.pumpWidget(const SizedBox());
    binding.state.dispose();
  });

  testWidgets('hardware Enter awaits cancellation and follows adopted editor', (
    tester,
  ) async {
    const initialSource =
        '<input id="entry" value="Draft" data-pirc-script-id="entry">';
    const nextSource =
        '<input id="entry" value="Draft" data-pirc-script-id="entry">';
    final initial = _binding(initialSource, 'entry');
    final keyEvents = <Map<String, Object?>>[];
    final submitted = <String>[];
    Completer<bool>? nextEnterResult;

    Future<bool> keyEvent(String key, String type, Map<String, dynamic> data) {
      keyEvents.add({'key': key, 'type': type, ...data});
      if (type == 'keydown' && data['key'] == 'Enter') {
        final result = nextEnterResult!;
        nextEnterResult = null;
        return result.future;
      }
      return Future<bool>.value(false);
    }

    initial.state
      ..onUserKeyEvent = keyEvent
      ..onSubmit = submitted.add;
    await tester.pumpWidget(_page([initial]));
    await tester.pumpAndSettle();
    initial.state.focusNodeFor(initial.field.key).requestFocus();
    await tester.pump();

    final cancelled = Completer<bool>();
    nextEnterResult = cancelled;
    await tester.sendKeyDownEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(keyEvents.single['key'], 'Enter');
    expect(keyEvents.single['code'], 'Enter');
    cancelled.complete(true);
    await tester.pump();
    expect(submitted, isEmpty);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(keyEvents.last['type'], 'keyup');

    final allowed = Completer<bool>();
    nextEnterResult = allowed;
    await tester.sendKeyDownEvent(LogicalKeyboardKey.enter);
    await tester.pump();

    final next = _binding(nextSource, 'entry');
    next.state
      ..onUserKeyEvent = keyEvent
      ..onSubmit = submitted.add;
    next.state.adoptEditingState(initial.state);
    initial.state.dispose();
    await tester.pumpWidget(_page([next]));
    await tester.pump();
    allowed.complete(false);
    await tester.pump();
    expect(submitted, [next.field.key]);

    await tester.sendKeyUpEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    final stale = Completer<bool>();
    nextEnterResult = stale;
    await tester.sendKeyDownEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    next.state.focusNodeFor(next.field.key).unfocus();
    await tester.pump();
    stale.complete(false);
    await tester.pump();
    expect(submitted, [next.field.key]);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.enter);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox());
    next.state.dispose();
  });

  test('number stepping emits input and change for each committed step', () {
    const source =
        '<input id="amount" type="number" value="1" min="0" max="3" data-pirc-script-id="amount">';
    final binding = _binding(source, 'amount');
    final events = <String>[];
    binding.state.onUserEvent = (key, type) => events.add('$key:$type');

    expect(binding.state.stepNumber(binding.field.key, direction: 1), isTrue);
    expect(binding.state.valueFor(binding.field.key), '2');
    expect(events, [
      '${binding.field.key}:input',
      '${binding.field.key}:change',
    ]);
    expect(binding.state.stepNumber(binding.field.key, direction: 1), isTrue);
    expect(binding.state.valueFor(binding.field.key), '3');
    expect(events, [
      '${binding.field.key}:input',
      '${binding.field.key}:change',
      '${binding.field.key}:input',
      '${binding.field.key}:change',
    ]);
    expect(binding.state.stepNumber(binding.field.key, direction: 1), isFalse);
    expect(events, [
      '${binding.field.key}:input',
      '${binding.field.key}:change',
      '${binding.field.key}:input',
      '${binding.field.key}:change',
    ]);

    binding.state.dispose();
  });

  testWidgets(
    'adoption keeps editor identity and composition, then applies script value silently',
    (tester) async {
      const initialSource =
          '<input id="entry" value="Initial" data-pirc-script-id="entry">';
      const sameValueSource =
          '<input id="entry" value="draft" data-pirc-script-id="entry">';
      const changedValueSource =
          '<input id="entry" value="Script reset" data-pirc-script-id="entry">';
      final oldBinding = _binding(initialSource, 'entry');
      final events = <String>[];
      oldBinding.state.onUserEvent = (_, type) => events.add(type);

      await tester.pumpWidget(_page([oldBinding]));
      await tester.pumpAndSettle();

      final oldController = oldBinding.state.controllerFor(
        oldBinding.field.key,
      );
      final oldFocus = oldBinding.state.focusNodeFor(oldBinding.field.key);
      oldFocus.requestFocus();
      await tester.pump();
      oldController.value = const TextEditingValue(
        text: 'draft',
        selection: TextSelection.collapsed(offset: 2),
        composing: TextRange(start: 1, end: 4),
      );
      final oldEditorKey = tester.widget<TextField>(find.byType(TextField)).key;

      final sameValueBinding = _binding(sameValueSource, 'entry');
      sameValueBinding.state.onUserEvent = (_, type) => events.add(type);
      sameValueBinding.state.adoptEditingState(oldBinding.state);
      oldBinding.state.dispose();
      await tester.pumpWidget(_page([sameValueBinding]));
      await tester.pump();

      final adoptedController = sameValueBinding.state.controllerFor(
        sameValueBinding.field.key,
      );
      expect(identical(adoptedController, oldController), isTrue);
      expect(
        identical(
          sameValueBinding.state.focusNodeFor(sameValueBinding.field.key),
          oldFocus,
        ),
        isTrue,
      );
      expect(
        identical(
          tester.widget<TextField>(find.byType(TextField)).key,
          oldEditorKey,
        ),
        isTrue,
      );
      expect(adoptedController.value.text, 'draft');
      expect(
        adoptedController.selection,
        const TextSelection.collapsed(offset: 2),
      );
      expect(
        adoptedController.value.composing,
        const TextRange(start: 1, end: 4),
      );
      expect(oldFocus.hasFocus, isTrue);
      expect(events, isEmpty);

      final changedBinding = _binding(changedValueSource, 'entry');
      changedBinding.state.onUserEvent = (_, type) => events.add(type);
      changedBinding.state.adoptEditingState(sameValueBinding.state);
      sameValueBinding.state.dispose();
      await tester.pumpWidget(_page([changedBinding]));
      await tester.pump();

      final changedController = changedBinding.state.controllerFor(
        changedBinding.field.key,
      );
      expect(identical(changedController, oldController), isTrue);
      expect(changedController.text, 'Script reset');
      expect(
        changedController.selection,
        TextSelection.collapsed(offset: 'Script reset'.length),
      );
      expect(changedController.value.composing, TextRange.empty);
      expect(
        identical(
          tester.widget<TextField>(find.byType(TextField)).key,
          oldEditorKey,
        ),
        isTrue,
      );
      expect(oldFocus.hasFocus, isTrue);
      expect(events, isEmpty);
      expect(tester.takeException(), isNull);

      await tester.pumpWidget(const SizedBox());
      changedBinding.state.dispose();
    },
  );

  testWidgets(
    'pending change follows its editor across a same-value snapshot',
    (tester) async {
      const oldSource =
          '<input id="entry" value="Initial" data-pirc-script-id="entry">';
      const nextSource =
          '<input id="entry" value="Edited" data-pirc-script-id="entry">';
      final oldBinding = _binding(oldSource, 'entry');
      final events = <String>[];
      oldBinding.state.onUserEvent = (key, type) => events.add('$key:$type');

      await tester.pumpWidget(_page([oldBinding]));
      await tester.pumpAndSettle();
      oldBinding.state.focusNodeFor(oldBinding.field.key).requestFocus();
      await tester.pump();
      await tester.enterText(find.byType(EditableText), 'Edited');
      expect(events, ['${oldBinding.field.key}:input']);

      final nextBinding = _binding(nextSource, 'entry');
      nextBinding.state.onUserEvent = (key, type) => events.add('$key:$type');
      nextBinding.state.adoptEditingState(oldBinding.state);
      oldBinding.state.dispose();
      await tester.pumpWidget(_page([nextBinding]));
      await tester.pump();
      nextBinding.state.focusNodeFor(nextBinding.field.key).unfocus();
      await tester.pump();

      expect(events, [
        '${oldBinding.field.key}:input',
        '${nextBinding.field.key}:change',
      ]);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      nextBinding.state.dispose();
    },
  );

  test('duplicate, removed, and incompatible fields are not adopted', () {
    const previousSource = '''
<input id="duplicate-a" value="old a" data-pirc-script-id="duplicate">
<input id="duplicate-b" value="old b" data-pirc-script-id="duplicate">
<input id="kind" value="old kind" data-pirc-script-id="kind">
<input id="removed" value="old removed" data-pirc-script-id="removed">
''';
    const nextSource = '''
<input id="duplicate-a" value="new a" data-pirc-script-id="duplicate">
<input id="duplicate-b" value="new b" data-pirc-script-id="duplicate">
<input id="kind" type="number" value="7" data-pirc-script-id="kind">
<input id="fresh" value="fresh" data-pirc-script-id="fresh">
''';
    final previous = _bindings(previousSource);
    final next = _bindings(nextSource);
    final previousState = previous.first.state;
    final nextState = next.first.state;
    final oldById = {for (final field in previous) field.domId: field};
    final nextById = {for (final field in next) field.domId: field};
    oldById['duplicate-a']!.state
            .controllerFor(oldById['duplicate-a']!.field.key)
            .text =
        'user duplicate';
    oldById['kind']!.state.controllerFor(oldById['kind']!.field.key).text =
        'user kind';

    nextState.adoptEditingState(previousState);

    expect(
      nextById['duplicate-a']!.state.valueFor(
        nextById['duplicate-a']!.field.key,
      ),
      'new a',
    );
    expect(
      nextById['duplicate-b']!.state.valueFor(
        nextById['duplicate-b']!.field.key,
      ),
      'new b',
    );
    expect(nextById['kind']!.state.valueFor(nextById['kind']!.field.key), '7');
    expect(
      nextById['fresh']!.state.valueFor(nextById['fresh']!.field.key),
      'fresh',
    );
    expect(
      identical(
        nextState.controllerFor(nextById['duplicate-a']!.field.key),
        oldById['duplicate-a']!.state.controllerFor(
          oldById['duplicate-a']!.field.key,
        ),
      ),
      isFalse,
    );
    expect(
      identical(
        nextState.controllerFor(nextById['kind']!.field.key),
        oldById['kind']!.state.controllerFor(oldById['kind']!.field.key),
      ),
      isFalse,
    );

    previousState.dispose();
    nextState.dispose();
  });
}
