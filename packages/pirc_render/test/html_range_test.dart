import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:html/parser.dart' as html;
import 'package:pirc_render/src/html_range.dart';

NativeHtmlRangeDescriptor rangeById(
  NativeHtmlRangeState state,
  String source,
  String id,
) {
  final fragment = html.parseFragment(state.annotateHtml(source));
  final element = fragment.querySelector('#$id');
  expect(element, isNotNull);
  return state.resolveControl(element!)!;
}

Widget rangeWidget(
  NativeHtmlRangeState state,
  NativeHtmlRangeDescriptor control,
) => NativeHtmlRangeWidget(
  state: state,
  control: control,
  focusAccent: const Color(0xff4176e6),
);

Widget appFor(
  NativeHtmlRangeState state,
  Iterable<NativeHtmlRangeDescriptor> controls,
) => MaterialApp(
  home: Scaffold(
    body: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [for (final control in controls) rangeWidget(state, control)],
    ),
  ),
);

void main() {
  test('sanitizes defaults, malformed attributes, and exact step bases', () {
    const source = '''
      <input id="default" type="range">
      <input id="off-grid" type="range" min="0" max="10" step="3" value="4">
      <input id="tie" type="range" min="0" max="10" step="4" value="2">
      <input id="implicit-base" type="range" max="10" step="2" value="5">
      <input id="decimal-base" type="range" max="1" step="0.3" value="0.2">
      <input id="invalid-min" type="range" min="broken" max="10" step="2" value="5">
      <input id="exponent" type="range" min="1e-3" max="1e-1" step="2e-2" value="5e-2">
      <input id="any" type="range" min="0" max="10" step="any" value="5.25">
      <input id="malformed" type="range" min="bad" max="Infinity" step="0" value="n/a" required>
      <input id="collapsed" type="range" min="10" max="3" value="50">
      <input id="not-range" type="text" value="ignored">
    ''';
    final state = NativeHtmlRangeState.fromHtml(source);
    addTearDown(state.dispose);

    final defaultRange = rangeById(state, source, 'default');
    expect(defaultRange.initialValue, '50');
    expect(defaultRange.effectiveMin, '0');
    expect(defaultRange.effectiveMax, '100');
    expect(defaultRange.stepBase, '0');
    expect(defaultRange.effectiveStep, '1');

    expect(rangeById(state, source, 'off-grid').initialValue, '3');
    expect(rangeById(state, source, 'tie').initialValue, '4');
    final implicitBase = rangeById(state, source, 'implicit-base');
    expect(implicitBase.initialValue, '5');
    expect(implicitBase.stepBase, '5');
    final decimalBase = rangeById(state, source, 'decimal-base');
    expect(decimalBase.initialValue, '0.2');
    expect(decimalBase.stepBase, '0.2');
    final invalidMin = rangeById(state, source, 'invalid-min');
    expect(invalidMin.min, 'broken');
    expect(invalidMin.effectiveMin, '0');
    expect(invalidMin.stepBase, '5');
    expect(invalidMin.initialValue, '5');
    expect(rangeById(state, source, 'exponent').initialValue, '0.041');
    final any = rangeById(state, source, 'any');
    expect(any.stepAny, isTrue);
    expect(any.initialValue, '5.25');
    final malformed = rangeById(state, source, 'malformed');
    expect(malformed.min, 'bad');
    expect(malformed.max, 'Infinity');
    expect(malformed.step, '0');
    expect(malformed.initialValue, '50');
    expect(malformed.required, isTrue);
    expect(malformed.willValidate, isTrue);
    final collapsed = rangeById(state, source, 'collapsed');
    expect(collapsed.effectiveMin, '10');
    expect(collapsed.effectiveMax, '10');
    expect(collapsed.initialValue, '10');
    final fragment = html.parseFragment(state.annotateHtml(source));
    expect(state.resolveControl(fragment.querySelector('#not-range')!), isNull);
  });

  test(
    'preserves source markers, labels, fieldset disablement and visibility',
    () {
      const source = '''
      <fieldset disabled>
        <legend><label for="legend">Legend range</label><input id="legend" type="range"></legend>
        <label for="disabled">Disabled range</label><input id="disabled" type="range">
      </fieldset>
      <label>Implicit range <input id="implicit" type="range"></label>
      <span id="name">Accessible</span><span id="description">Help text</span>
      <label for="aria">Visible label</label>
      <input id="aria" type="range" aria-label="Fallback" aria-labelledby="name" aria-describedby="description" readonly required data-pirc-native-range-id="spoof">
      <input id="title" type="range" title="Title fallback">
      <input id="hidden" type="range" hidden>
      <div style="display:none"><input id="display-none" type="range"></div>
    ''';
      final state = NativeHtmlRangeState.fromHtml(source);
      addTearDown(state.dispose);

      final legend = rangeById(state, source, 'legend');
      final disabled = rangeById(state, source, 'disabled');
      expect(legend.disabled, isFalse);
      expect(disabled.disabled, isTrue);
      expect(rangeById(state, source, 'implicit').label, 'Implicit range');
      final aria = rangeById(state, source, 'aria');
      expect(aria.label, 'Accessible');
      expect(aria.hint, 'Help text');
      expect(aria.readOnly, isTrue);
      expect(aria.willValidate, isFalse);
      expect(aria.required, isTrue);
      expect(rangeById(state, source, 'title').label, 'Title fallback');
      expect(rangeById(state, source, 'hidden').visible, isFalse);
      expect(rangeById(state, source, 'display-none').visible, isFalse);

      final annotated = state.annotateHtml(source);
      expect(annotated, isNot(contains('spoof')));
      expect(annotated, contains('data-pirc-native-range-id='));
      final fragment = html.parseFragment(annotated);
      final label = fragment.querySelector('label[for="aria"]')!;
      expect(state.resolveLabel(label)?.key, aria.key);
      expect(() => state.annotateHtml('$source '), throwsArgumentError);
    },
  );

  testWidgets(
    'keyboard, Home/End, repeat, readonly and form reset match HTML',
    (tester) async {
      const source = '''
      <label for="range">Integer range</label>
      <input id="range" type="range" max="10" step="2" value="5">
      <input id="readonly" type="range" min="0" max="10" step="2" value="4" readonly>
      <input id="disabled" type="range" min="0" max="10" step="2" value="6" disabled>
      <input id="any" type="range" min="0" max="10" step="any" value="5.25">
    ''';
      final state = NativeHtmlRangeState.fromHtml(source);
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        state.dispose();
      });
      final range = rangeById(state, source, 'range');
      final readonly = rangeById(state, source, 'readonly');
      final disabled = rangeById(state, source, 'disabled');
      final any = rangeById(state, source, 'any');
      await tester.pumpWidget(appFor(state, [range, readonly, disabled, any]));

      expect(
        tester.getSize(find.byKey(ValueKey('native-html-range-${range.key}'))),
        const Size(129, 16),
      );
      state.focusControl(range.key);
      await tester.pump();
      expect(state.focusNodeFor(range.key).hasFocus, isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      expect(state.valueFor(range.key), '7');
      await tester.sendKeyRepeatEvent(LogicalKeyboardKey.arrowUp);
      expect(state.valueFor(range.key), '9');
      await tester.sendKeyEvent(LogicalKeyboardKey.home);
      expect(state.valueFor(range.key), '1');
      await tester.sendKeyEvent(LogicalKeyboardKey.end);
      expect(state.valueFor(range.key), '9');

      state.setRangeValue(readonly.key, 8);
      expect(state.valueFor(readonly.key), '8');
      state.resetDefaults([range.key, readonly.key, disabled.key]);
      expect(state.valueFor(range.key), '5');
      expect(state.valueFor(readonly.key), '4');
      expect(state.valueFor(disabled.key), '6');
      state.focusControl(disabled.key);
      await tester.pump();
      expect(state.focusNodeFor(disabled.key).hasFocus, isFalse);
      expect(state.stepRange(disabled.key, direction: 1), isFalse);

      state.focusControl(any.key);
      await tester.pump();
      expect(state.focusNodeFor(any.key).hasFocus, isTrue);
      expect(state.stepRange(any.key, direction: 1), isTrue);
      expect(state.valueFor(any.key), '5.35');
      await tester.pump();
      final anySemantics = tester
          .getSemantics(find.byKey(ValueKey('native-html-range-${any.key}')))
          .getSemanticsData();
      expect(anySemantics.flagsCollection.isSlider, isTrue);
      expect(anySemantics.value, '5.35');
      expect(anySemantics.hasAction(SemanticsAction.increase), isTrue);
      expect(anySemantics.hasAction(SemanticsAction.decrease), isTrue);
    },
  );

  testWidgets('labels focus, pointer changes, and readonly remains operable', (
    tester,
  ) async {
    const source = '''
      <label for="range">Brightness</label>
      <input id="range" type="range" min="0" max="20" value="10" readonly>
    ''';
    final state = NativeHtmlRangeState.fromHtml(source);
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      state.dispose();
    });
    final control = rangeById(state, source, 'range');
    await tester.pumpWidget(appFor(state, [control]));
    final fragment = html.parseFragment(state.annotateHtml(source));
    state.activateLabel(fragment.querySelector('label')!);
    await tester.pump();
    expect(state.focusNodeFor(control.key).hasFocus, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    expect(state.valueFor(control.key), '11');

    final rect = tester.getRect(
      find.byKey(ValueKey('native-html-range-${control.key}')),
    );
    await tester.tapAt(Offset(rect.left + rect.width * .75, rect.center.dy));
    await tester.pump();
    expect(state.focusNodeFor(control.key).hasFocus, isTrue);
    expect(double.parse(state.valueFor(control.key)), greaterThan(14));
  });
}
