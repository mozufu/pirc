import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:html/parser.dart' as html;
import 'package:pirc_render/src/html_controls.dart';
import 'package:pirc_render/src/html_date.dart';
import 'package:pirc_render/src/html_date_validation.dart';
import 'package:pirc_render/src/html_range.dart';
import 'package:pirc_render/src/html_select.dart';

NativeHtmlControlDescriptor _control(
  NativeHtmlControlState state,
  String source,
  String id,
) => state.resolveControl(
  html.parseFragment(state.annotateHtml(source)).querySelector('#$id')!,
)!;

NativeHtmlSelectDescriptor _select(
  NativeHtmlSelectState state,
  String source,
  String id,
) => state.resolveControl(
  html.parseFragment(state.annotateHtml(source)).querySelector('#$id')!,
)!;

NativeHtmlRangeDescriptor _range(
  NativeHtmlRangeState state,
  String source,
  String id,
) => state.resolveControl(
  html.parseFragment(state.annotateHtml(source)).querySelector('#$id')!,
)!;

NativeHtmlDateDescriptor _date(
  NativeHtmlDateState state,
  String source,
  String id,
) => state.resolveControl(
  html.parseFragment(state.annotateHtml(source)).querySelector('#$id')!,
)!;

Widget _rangePage(
  NativeHtmlRangeState state,
  NativeHtmlRangeDescriptor range,
) => MaterialApp(
  home: Scaffold(
    body: Align(
      alignment: Alignment.topLeft,
      child: NativeHtmlRangeWidget(
        state: state,
        control: range,
        focusAccent: const Color(0xff4176e6),
      ),
    ),
  ),
);

void main() {
  test('checkbox and radio events fire only after changed user activation', () {
    const source = '''
<input id="check" type="checkbox" data-pirc-script-id="check">
<input id="radio" type="radio" name="group" checked data-pirc-script-id="radio">
''';
    final state = NativeHtmlControlState.fromHtml(source);
    addTearDown(state.dispose);
    final check = _control(state, source, 'check');
    final radio = _control(state, source, 'radio');
    final events = <String>[];
    state.onUserEvent = (key, type) =>
        events.add('$key:$type:${state.isChecked(key)}');

    state.activateControl(check.key);
    state.activateControl(radio.key); // Already selected.
    expect(events, ['${check.key}:input:true', '${check.key}:change:true']);

    state.restoreHistoryCheckedness({check.key: false});
    state.resetDefaults([check.key]);
    expect(events, hasLength(2));

    final next = NativeHtmlControlState.fromHtml(source);
    addTearDown(next.dispose);
    final nextRadio = _control(next, source, 'radio');
    final oldNode = FocusNode(canRequestFocus: false);
    state.attachFocusNode(radio.key, oldNode);
    final oldWidgetKey = state.widgetKeyFor(radio.key);
    next.widgetKeyFor(nextRadio.key);
    next.adoptInteractionState(state);
    expect(next.widgetKeyFor(nextRadio.key), same(oldWidgetKey));
    expect(next.isTabStop(nextRadio.key), isFalse);
  });

  test('select change events follow effective user selection only', () {
    const source = '''
<select id="choice" data-pirc-script-id="choice">
  <option value="first" selected>First</option>
  <option value="second">Second</option>
</select>
''';
    final state = NativeHtmlSelectState.fromHtml(source);
    addTearDown(state.dispose);
    final choice = _select(state, source, 'choice');
    final events = <String>[];
    state.onUserEvent = (key, type) =>
        events.add('$type:${state.valueFor(key)}');

    expect(state.select(choice.key, 0), isFalse);
    expect(state.select(choice.key, 1), isTrue);
    expect(events, ['input:second', 'change:second']);

    state.restoreHistorySelectedness(choice.key, {0: true, 1: false});
    state.resetDefaults([choice.key]);
    expect(events, ['input:second', 'change:second']);

    final next = NativeHtmlSelectState.fromHtml(source);
    addTearDown(next.dispose);
    final nextChoice = _select(next, source, 'choice');
    final oldNode = state.focusNodeFor(choice.key);
    final oldWidgetKey = state.widgetKeyFor(choice.key);
    next.adoptInteractionState(state);
    expect(next.focusNodeFor(nextChoice.key), same(oldNode));
    expect(next.widgetKeyFor(nextChoice.key), same(oldWidgetKey));
  });

  test(
    'date input and picker changes emit paired events; restores stay silent',
    () {
      const source =
          '<input id="date" type="date" value="2024-01-02" '
          'data-pirc-script-id="date">';
      final state = NativeHtmlDateState.fromHtml(source);
      addTearDown(state.dispose);
      final date = _date(state, source, 'date');
      final events = <String>[];
      state.onUserEvent = (key, type) =>
          events.add('$type:${state.valueFor(key)}');

      state.updateSegment(date.key, NativeHtmlDateSegment.month, '2');
      state.updateSegment(date.key, NativeHtmlDateSegment.month, '2');
      expect(events, ['input:2024-02-02', 'change:2024-02-02']);

      state.setDate(date.key, NativeHtmlDateValue.parse('2024-03-04'));
      state.setDate(date.key, NativeHtmlDateValue.parse('2024-03-04'));
      state.clear(date.key);
      expect(events, [
        'input:2024-02-02',
        'change:2024-02-02',
        'input:2024-03-04',
        'change:2024-03-04',
        'input:',
        'change:',
      ]);

      final snapshot = state.captureHistory();
      state.setValue(date.key, '2024-05-06');
      state.restoreHistory(snapshot);
      state.resetDefaults([date.key]);
      expect(events, hasLength(6));

      final next = NativeHtmlDateState.fromHtml(source);
      addTearDown(next.dispose);
      final nextDate = _date(next, source, 'date');
      final oldController = state.segmentControllerFor(
        date.key,
        NativeHtmlDateSegment.month,
      );
      final oldFocus = state.segmentFocusNodeFor(
        date.key,
        NativeHtmlDateSegment.month,
      );
      final oldWidgetKey = state.widgetKeyFor(date.key);
      next.adoptInteractionState(state);
      expect(
        next.segmentControllerFor(nextDate.key, NativeHtmlDateSegment.month),
        same(oldController),
      );
      expect(
        next.segmentFocusNodeFor(nextDate.key, NativeHtmlDateSegment.month),
        same(oldFocus),
      );
      expect(next.widgetKeyFor(nextDate.key), same(oldWidgetKey));
      expect(oldController.text, '01');
    },
  );

  test('date snapshots preserve partial entry and apply script replacement', () {
    const source = '<input id="date" type="date" data-pirc-script-id="date">';
    final old = NativeHtmlDateState.fromHtml(source);
    final field = _date(old, source, 'date');
    old.updateSegment(field.key, NativeHtmlDateSegment.month, '2');
    expect(old.valueFor(field.key), '');
    expect(old.badInputFor(field.key), true);
    final revision = old.revisionFor(field.key);
    final next = NativeHtmlDateState.fromHtml(source);
    final nextField = _date(next, source, 'date');
    next.adoptInteractionState(old);
    old.dispose();
    expect(
      next
          .segmentControllerFor(nextField.key, NativeHtmlDateSegment.month)
          .text,
      '2',
    );
    expect(next.badInputFor(nextField.key), true);
    expect(next.wasUserEdited(nextField.key), true);
    expect(next.revisionFor(nextField.key), revision);
    const changedSource =
        '<input id="date" type="date" value="2025-03-04" data-pirc-script-id="date">';
    final changed = NativeHtmlDateState.fromHtml(changedSource);
    final changedField = _date(changed, changedSource, 'date');
    changed.adoptInteractionState(next);
    next.dispose();
    expect(changed.valueFor(changedField.key), '2025-03-04');
    expect(
      changed
          .segmentControllerFor(changedField.key, NativeHtmlDateSegment.month)
          .text,
      '03',
    );
    expect(changed.badInputFor(changedField.key), false);
    expect(changed.revisionFor(changedField.key), isNot(revision));
    changed.dispose();
  });

  test('range drag emits input while moving and change once at commit', () {
    const source =
        '<input id="volume" type="range" min="0" max="10" value="2" '
        'data-pirc-script-id="volume">';
    final state = NativeHtmlRangeState.fromHtml(source);
    addTearDown(state.dispose);
    final range = _range(state, source, 'volume');
    final events = <String>[];
    state.onUserEvent = (key, type) =>
        events.add('$type:${state.valueFor(key)}');

    state.beginUserRangeChange(range.key);
    expect(state.setRangeFraction(range.key, 0.5), isTrue);
    expect(state.setRangeFraction(range.key, 0.5), isFalse);
    expect(events, ['input:5']);
    expect(state.commitUserRangeChange(range.key), isTrue);
    expect(state.commitUserRangeChange(range.key), isFalse);
    expect(events, ['input:5', 'change:5']);

    state.stepRange(range.key, direction: 1);
    expect(events, ['input:5', 'change:5', 'input:6', 'change:6']);
    state.setRangeValue(range.key, 8);
    state.resetDefaults([range.key]);
    expect(events, ['input:5', 'change:5', 'input:6', 'change:6']);
  });

  testWidgets('active range drag survives same-script-id state replacement', (
    tester,
  ) async {
    const source =
        '<input id="volume" type="range" min="0" max="10" value="2" '
        'data-pirc-script-id="volume">';
    final previous = NativeHtmlRangeState.fromHtml(source);
    var previousDisposed = false;
    addTearDown(() {
      if (!previousDisposed) previous.dispose();
    });
    final previousRange = _range(previous, source, 'volume');
    final previousEvents = <String>[];
    previous.onUserEvent = (key, type) => previousEvents.add(type);
    await tester.pumpWidget(_rangePage(previous, previousRange));

    final previousFinder = find.byKey(
      ValueKey('native-html-range-${previousRange.key}'),
    );
    final previousRect = tester.getRect(previousFinder);
    final gesture = await tester.startGesture(
      Offset(
        previousRect.left + previousRect.width * 0.25,
        previousRect.center.dy,
      ),
    );
    await gesture.moveTo(
      Offset(
        previousRect.left + previousRect.width * 0.45,
        previousRect.center.dy,
      ),
    );
    await tester.pump();
    expect(previousEvents, contains('input'));

    final currentValue = previous.valueFor(previousRange.key);
    final nextSource =
        '<input id="volume" type="range" min="0" max="10" value="$currentValue" '
        'data-pirc-script-id="volume">';
    final next = NativeHtmlRangeState.fromHtml(nextSource);
    addTearDown(next.dispose);
    final nextRange = _range(next, nextSource, 'volume');
    final nextEvents = <String>[];
    next.onUserEvent = (key, type) =>
        nextEvents.add('$type:${next.valueFor(key)}');
    final oldFocus = previous.focusNodeFor(previousRange.key);
    final oldGestureKey = previous.gestureKeyFor(previousRange.key);
    next.adoptInteractionState(previous);
    expect(next.focusNodeFor(nextRange.key), same(oldFocus));
    expect(next.gestureKeyFor(nextRange.key), same(oldGestureKey));
    expect(next.valueFor(nextRange.key), currentValue);

    await tester.pumpWidget(_rangePage(next, nextRange));
    previous.dispose();
    previousDisposed = true;
    final nextRect = tester.getRect(
      find.byKey(ValueKey('native-html-range-${nextRange.key}')),
    );
    await gesture.moveTo(
      Offset(nextRect.left + nextRect.width * 0.8, nextRect.center.dy),
    );
    await tester.pump();
    expect(nextEvents, hasLength(1));
    expect(nextEvents.single, startsWith('input:'));

    await gesture.up();
    await tester.pump();
    expect(nextEvents, hasLength(2));
    expect(nextEvents.last, startsWith('change:'));
    expect(tester.takeException(), isNull);
  });
}
