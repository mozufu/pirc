import 'dart:ui' show SemanticsRole;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_render/src/html_select.dart';
import 'package:pirc_render/src/html_controls.dart';
import 'native_html_test.dart' show shell, tapText;

void main() {
  testWidgets(
    'native HTML dropdown opens, selects, retains and resets with document',
    (tester) async {
      final semantics = tester.ensureSemantics();
      try {
        const source =
            '<div><label for="choice">Choose</label> <select id="choice">'
            '<option value="a">Alpha</option><option disabled value="b">Blocked</option>'
            '<option value="c">Charlie</option></select></div>';
        await tester.pumpWidget(shell(source));
        await tester.pumpAndSettle();
        var widget = tester.widget<NativeHtmlSelectWidget>(
          find.byType(NativeHtmlSelectWidget),
        );
        expect(widget.state.valueFor(widget.control.key), 'a');
        final selectSemantics = tester
            .getSemantics(
              find.byKey(ValueKey('native-html-select-${widget.control.key}')),
            )
            .getSemanticsData();
        expect(selectSemantics.role, SemanticsRole.none);
        expect(selectSemantics.flagsCollection.isButton, isTrue);
        expect(selectSemantics.value, 'Alpha');
        await tester.tap(find.byType(NativeHtmlSelectWidget));
        await tester.pumpAndSettle();
        expect(find.text('Charlie'), findsOneWidget);
        await tester.tap(find.text('Charlie'));
        await tester.pumpAndSettle();
        expect(widget.state.valueFor(widget.control.key), 'c');
        await tester.pumpWidget(shell(source));
        await tester.pumpAndSettle();
        widget = tester.widget<NativeHtmlSelectWidget>(
          find.byType(NativeHtmlSelectWidget),
        );
        expect(widget.state.valueFor(widget.control.key), 'c');
        await tester.pumpWidget(
          shell(source.replaceFirst('Alpha', 'New default')),
        );
        await tester.pumpAndSettle();
        widget = tester.widget<NativeHtmlSelectWidget>(
          find.byType(NativeHtmlSelectWidget),
        );
        expect(widget.state.valueFor(widget.control.key), 'a');
        expect(tester.takeException(), isNull);
      } finally {
        semantics.dispose();
      }
    },
  );

  testWidgets('replacement document closes its old open dropdown', (
    tester,
  ) async {
    const source =
        '<select><option>Alpha</option><option>Charlie</option></select>';
    await tester.pumpWidget(shell(source));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(NativeHtmlSelectWidget));
    await tester.pumpAndSettle();
    expect(find.text('Charlie'), findsOneWidget);
    await tester.pumpWidget(
      shell('<select><option>Replacement</option></select>'),
    );
    await tester.pumpAndSettle();
    expect(find.text('Charlie'), findsNothing);
    expect(find.text('Replacement'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('HTML select, checkbox and text labels keep separate targets', (
    tester,
  ) async {
    await tester.pumpWidget(
      shell(
        '<div><label for="choice">Pick one</label>'
        '<select id="choice"><option>One</option><option>Two</option></select>'
        '<label for="edit">Edit text</label><input id="edit">'
        '<label for="agree">Agree</label><input type="checkbox" id="agree"></div>',
      ),
    );
    await tester.pumpAndSettle();
    final select = tester.widget<NativeHtmlSelectWidget>(
      find.byType(NativeHtmlSelectWidget),
    );
    await tapText(tester, 'Pick one');
    expect(select.state.focusNodeFor(select.control.key).hasFocus, isTrue);
    await tapText(tester, 'Edit text');
    expect(
      tester.widget<EditableText>(find.byType(EditableText)).focusNode.hasFocus,
      isTrue,
    );
    await tapText(tester, 'Agree');
    final check = tester.widget<NativeHtmlControlWidget>(
      find.byType(NativeHtmlControlWidget),
    );
    expect(check.state.isChecked(check.control.key), isTrue);
    expect(select.state.valueFor(select.control.key), 'One');
    expect(tester.takeException(), isNull);
  });
  testWidgets('dropdown preserves same-name and empty group headers', (
    tester,
  ) async {
    await tester.pumpWidget(
      shell(
        '<select><optgroup label="Same"><option>First</option></optgroup>'
        '<optgroup label="Empty"></optgroup><optgroup label="Same"><option>Second</option></optgroup>'
        '<optgroup label="Trailing"></optgroup></select>',
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byType(NativeHtmlSelectWidget));
    await tester.pumpAndSettle();
    expect(find.text('Same'), findsNWidgets(2));
    expect(find.text('Empty'), findsOneWidget);
    expect(find.text('Trailing'), findsOneWidget);
    await tester.tap(find.text('Second'));
    await tester.pumpAndSettle();
    final select = tester.widget<NativeHtmlSelectWidget>(
      find.byType(NativeHtmlSelectWidget),
    );
    expect(select.state.selectedIndices(select.control.key), [1]);
    expect(select.state.valueFor(select.control.key), 'Second');
    expect(tester.takeException(), isNull);
  });

  testWidgets('group-only popup closes when its source disappears', (
    tester,
  ) async {
    await tester.pumpWidget(
      shell('<select><optgroup label="Empty group"></optgroup></select>'),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byType(NativeHtmlSelectWidget));
    await tester.pumpAndSettle();
    expect(find.text('Empty group'), findsOneWidget);
    await tester.pumpWidget(shell('Replacement'));
    await tester.pumpAndSettle();
    expect(find.text('Empty group'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
