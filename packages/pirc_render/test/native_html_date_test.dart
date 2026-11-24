import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:html/parser.dart' as html;
import 'package:pirc_render/src/html_date.dart';

NativeHtmlDateState dateState(String source) =>
    NativeHtmlDateState.fromHtml(source);

NativeHtmlDateDescriptor dateControl(
  NativeHtmlDateState state,
  String source,
  String id,
) {
  final fragment = html.parseFragment(state.annotateHtml(source));
  return state.resolveControl(fragment.querySelector('#$id')!)!;
}

Widget dateApp(NativeHtmlDateState state, String source, Iterable<String> ids) {
  final controls = [
    for (final id in ids)
      NativeHtmlDateInput(
        state: state,
        control: dateControl(state, source, id),
        textStyle: const TextStyle(fontSize: 16, color: Color(0xff111111)),
      ),
  ];
  return MaterialApp(
    locale: const Locale('en', 'US'),
    theme: ThemeData(useMaterial3: false),
    home: Scaffold(
      body: Center(child: Column(children: controls)),
    ),
  );
}

ValueKey<String> segmentKey(String controlKey, NativeHtmlDateSegment segment) =>
    ValueKey('native-html-date-segment-$controlKey-${segment.name}');

void main() {
  testWidgets('date segments update canonical value and validity', (
    tester,
  ) async {
    const source = '<input id="visit" type="date" required value="2024-02-29">';
    final state = dateState(source);
    final control = dateControl(state, source, 'visit');
    await tester.pumpWidget(dateApp(state, source, const ['visit']));
    await tester.pumpAndSettle();
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      state.dispose();
    });

    final month = find.byKey(
      segmentKey(control.key, NativeHtmlDateSegment.month),
    );
    expect(month, findsOneWidget);
    await tester.enterText(month, '3');
    expect(state.valueFor(control.key), '2024-03-29');
    expect(state.validityFor(control.key).valid, isTrue);

    await tester.enterText(month, '13');
    expect(state.valueFor(control.key), isEmpty);
    expect(state.badInputFor(control.key), isTrue);
    expect(state.validityFor(control.key).valueMissing, isTrue);
    expect(state.validityFor(control.key).badInput, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('calendar respects min, max, and date step', (tester) async {
    const source =
        '<input id="visit" type="date" name="visit" '
        'min="2024-06-01" max="2024-06-30" step="7" value="2024-06-15">';
    final state = dateState(source);
    final control = dateControl(state, source, 'visit');
    await tester.pumpWidget(dateApp(state, source, const ['visit']));
    await tester.pumpAndSettle();
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      state.dispose();
    });

    await tester.tap(
      find.byKey(ValueKey('native-html-date-calendar-${control.key}')),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('native-html-date-calendar-popup')),
      findsOneWidget,
    );
    expect(find.text('22'), findsOneWidget);
    await tester.tap(find.text('22'));
    await tester.pumpAndSettle();
    expect(state.valueFor(control.key), '2024-06-22');
    expect(state.validityFor(control.key).stepMismatch, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('late picker results do not override reset or replaced state', (
    tester,
  ) async {
    const source =
        '<input id="visit" type="date" name="visit" '
        'min="2024-06-01" max="2024-06-30" step="7" value="2024-06-15">';

    final resetState = dateState(source);
    final resetControl = dateControl(resetState, source, 'visit');
    await tester.pumpWidget(dateApp(resetState, source, const ['visit']));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(ValueKey('native-html-date-calendar-${resetControl.key}')),
    );
    await tester.pumpAndSettle();
    final popup = find.byKey(const ValueKey('native-html-date-calendar-popup'));
    expect(popup, findsOneWidget);

    resetState.updateSegment(resetControl.key, NativeHtmlDateSegment.day, '22');
    await tester.pumpAndSettle();
    expect(popup, findsNothing);
    resetState.resetDefaults();
    expect(resetState.valueFor(resetControl.key), '2024-06-15');
    expect(resetState.valueFor(resetControl.key), '2024-06-15');

    await tester.pumpWidget(const SizedBox.shrink());
    resetState.dispose();

    final replacedState = dateState(source);
    final replacedControl = dateControl(replacedState, source, 'visit');
    await tester.pumpWidget(dateApp(replacedState, source, const ['visit']));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(ValueKey('native-html-date-calendar-${replacedControl.key}')),
    );
    await tester.pumpAndSettle();
    expect(popup, findsOneWidget);

    final nextSource =
        '<input id="visit" type="date" name="visit" '
        'min="2024-06-01" max="2024-06-30" step="7" value="2024-06-08">';
    final nextState = dateState(nextSource);
    replacedState.dispose();
    await tester.pumpWidget(dateApp(nextState, nextSource, const ['visit']));
    await tester.pumpAndSettle();
    expect(popup, findsNothing);
    await tester.pumpAndSettle();
    expect(
      nextState.valueFor(dateControl(nextState, nextSource, 'visit').key),
      '2024-06-08',
    );
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
    nextState.dispose();
  });

  testWidgets('disabled and readonly dates cannot be edited or picked', (
    tester,
  ) async {
    const source =
        '<label for="disabled">Disabled date</label>'
        '<input id="disabled" type="date" disabled value="2024-02-29">'
        '<label for="readonly">Readonly date</label>'
        '<input id="readonly" type="date" readonly required '
        'value="2024-03-01">';
    final state = dateState(source);
    final disabled = dateControl(state, source, 'disabled');
    final readonly = dateControl(state, source, 'readonly');
    await tester.pumpWidget(
      dateApp(state, source, const ['disabled', 'readonly']),
    );
    await tester.pumpAndSettle();
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      state.dispose();
    });

    final disabledMonth = tester.widget<TextField>(
      find.byKey(segmentKey(disabled.key, NativeHtmlDateSegment.month)),
    );
    final readonlyMonth = tester.widget<TextField>(
      find.byKey(segmentKey(readonly.key, NativeHtmlDateSegment.month)),
    );
    expect(disabledMonth.enabled, isFalse);
    expect(readonlyMonth.readOnly, isTrue);
    expect(
      tester
          .widget<IconButton>(
            find.byKey(ValueKey('native-html-date-calendar-${disabled.key}')),
          )
          .onPressed,
      isNull,
    );
    expect(
      tester
          .widget<IconButton>(
            find.byKey(ValueKey('native-html-date-calendar-${readonly.key}')),
          )
          .onPressed,
      isNull,
    );
    expect(state.validityFor(readonly.key).willValidate, isFalse);
    expect(state.validityFor(readonly.key).valid, isTrue);
    final labels = html.parseFragment(state.annotateHtml(source));
    state.activateLabel(labels.querySelector('label[for="readonly"]')!);
    await tester.pump();
    expect(
      state
          .segmentFocusNodeFor(readonly.key, NativeHtmlDateSegment.month)
          .hasFocus,
      isTrue,
    );
    state.updateSegment(readonly.key, NativeHtmlDateSegment.month, '4');
    expect(state.valueFor(readonly.key), '2024-03-01');
  });
}
