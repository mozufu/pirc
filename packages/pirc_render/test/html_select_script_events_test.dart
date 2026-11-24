import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:html/parser.dart' as html;
import 'package:pirc_render/src/html_select.dart';

NativeHtmlSelectDescriptor field(NativeHtmlSelectState state, String source) =>
    state.resolveControl(
      html.parseFragment(state.annotateHtml(source)).querySelector('select')!,
    )!;
Widget page(NativeHtmlSelectState state, NativeHtmlSelectDescriptor control) =>
    MaterialApp(
      home: Scaffold(
        body: NativeHtmlSelectWidget(
          key: state.widgetKeyFor(control.key),
          state: state,
          control: control,
          textStyle: const TextStyle(fontSize: 16),
        ),
      ),
    );
const source =
    '<select size="4" data-pirc-script-id="choice"><option selected>A</option><option>B</option><option>C</option></select>';

void main() {
  testWidgets(
    'script-canceled selection keys keep value; allowed keys emit once',
    (t) async {
      final state = NativeHtmlSelectState.fromHtml(source);
      final control = field(state, source);
      final events = <String>[];
      var cancel = true;
      state.onUserKeyEvent = (_, type, data) async {
        events.add('$type:${data['key']}');
        return cancel;
      };
      state.onUserEvent = (_, type) =>
          events.add('$type:${state.valueFor(control.key)}');
      await t.pumpWidget(page(state, control));
      state.focusControl(control.key);
      await t.pump();
      await t.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await t.pumpAndSettle();
      expect(state.valueFor(control.key), 'A');
      expect(events, ['keydown:ArrowDown', 'keyup:ArrowDown']);
      cancel = false;
      events.clear();
      await t.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await t.pumpAndSettle();
      expect(state.valueFor(control.key), 'B');
      expect(events, [
        'keydown:ArrowDown',
        'input:B',
        'change:B',
        'keyup:ArrowDown',
      ]);
      await t.pumpWidget(const SizedBox());
      state.dispose();
    },
  );

  testWidgets('pending key default follows adopted select and new options', (
    t,
  ) async {
    final previous = NativeHtmlSelectState.fromHtml(source);
    final old = field(previous, source);
    final result = Completer<bool>();
    previous.onUserKeyEvent = (_, type, _) =>
        type == 'keydown' ? result.future : Future.value(false);
    await t.pumpWidget(page(previous, old));
    previous.focusControl(old.key);
    await t.pump();
    final focus = previous.focusNodeFor(old.key);
    await t.sendKeyDownEvent(LogicalKeyboardKey.arrowDown);
    await t.pump();
    const changed =
        '<select size="4" data-pirc-script-id="choice"><option>New A</option><option selected>New B</option><option>New C</option></select>';
    final next = NativeHtmlSelectState.fromHtml(changed);
    final current = field(next, changed);
    next.onUserKeyEvent = (_, _, _) async => false;
    next.adoptInteractionState(previous);
    previous.dispose();
    await t.pumpWidget(page(next, current));
    result.complete(false);
    await t.pumpAndSettle();
    expect(next.focusNodeFor(current.key), same(focus));
    expect(focus.hasFocus, true);
    expect(next.valueFor(current.key), 'New C');
    await t.sendKeyUpEvent(LogicalKeyboardKey.arrowDown);
    await t.pumpAndSettle();
    await t.pumpWidget(const SizedBox());
    next.dispose();
  });

  testWidgets('replacement document cannot receive a pending select default', (
    t,
  ) async {
    final previous = NativeHtmlSelectState.fromHtml(source);
    final old = field(previous, source);
    final result = Completer<bool>();
    previous.onUserKeyEvent = (_, _, _) => result.future;
    await t.pumpWidget(page(previous, old));
    previous.focusControl(old.key);
    await t.pump();
    await t.sendKeyDownEvent(LogicalKeyboardKey.arrowDown);
    await t.pump();
    final next = NativeHtmlSelectState.fromHtml(source);
    final current = field(next, source);
    await t.pumpWidget(page(next, current));
    previous.dispose();
    result.complete(false);
    await t.pumpAndSettle();
    expect(next.valueFor(current.key), 'A');
    await t.sendKeyUpEvent(LogicalKeyboardKey.arrowDown);
    await t.pumpAndSettle();
    await t.pumpWidget(const SizedBox());
    next.dispose();
  });

  testWidgets('multiple range selection emits one committed pair per key', (
    t,
  ) async {
    const multiple =
        '<select multiple size="4"><option selected>A</option><option>B</option><option>C</option></select>';
    final state = NativeHtmlSelectState.fromHtml(multiple);
    final control = field(state, multiple);
    final events = <String>[];
    state.onUserEvent = (_, type) => events.add(type);
    await t.pumpWidget(page(state, control));
    state.focusControl(control.key);
    await t.pump();
    await t.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await t.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await t.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await t.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await t.pumpAndSettle();
    expect(state.selectedIndices(control.key), [0, 1, 2]);
    expect(events, ['input', 'change', 'input', 'change']);
    await t.pumpWidget(const SizedBox());
    state.dispose();
  });
}
