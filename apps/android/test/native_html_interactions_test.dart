import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_mobile/live/gateway.dart';
import 'package:pirc_render/src/html_controls.dart';
import 'native_html_test.dart' show shell, tapText;

void main() {
  final fixture = obj(
    jsonDecode(
      File(
        '../../fixtures/mobile-parity/html-interactions.json',
      ).readAsStringSync(),
    ),
  );
  String source(String id) =>
      rows(fixture['cases']).singleWhere((c) => c['id'] == id)['source']
          as String;
  bool checked(WidgetTester t, String label) =>
      t
          .getSemantics(find.bySemanticsLabel(label))
          .getSemanticsData()
          .flagsCollection
          .isChecked ==
      ui.CheckedState.isTrue;

  testWidgets(
    'HTML labels toggle enabled controls and preserve disabled state',
    (t) async {
      final semantics = t.ensureSemantics();
      await t.pumpWidget(shell(source('html-checkbox-states')));
      await t.pumpAndSettle();
      expect(checked(t, 'Enabled unchecked checkbox'), isFalse);
      expect(checked(t, 'Keep this option'), isTrue);
      await tapText(t, 'Enable the option');
      expect(checked(t, 'Enabled unchecked checkbox'), isTrue);
      await tapText(t, 'Keep this option');
      expect(checked(t, 'Keep this option'), isFalse);
      await tapText(t, 'Unavailable option');
      expect(checked(t, 'Unavailable option'), isFalse);
      expect(t.takeException(), isNull);
      semantics.dispose();
    },
  );

  testWidgets('radio labels select one value without toggling it off', (
    t,
  ) async {
    final semantics = t.ensureSemantics();
    await t.pumpWidget(shell(source('html-radio-label-group')));
    await t.pumpAndSettle();
    await tapText(t, 'Beta answer');
    expect(checked(t, 'Beta answer'), isTrue);
    expect(checked(t, 'Alpha answer'), isFalse);
    await tapText(t, 'Beta answer');
    expect(checked(t, 'Beta answer'), isTrue);
    await tapText(t, 'Delta answer');
    expect(checked(t, 'Beta answer'), isFalse);
    expect(checked(t, 'Delta answer'), isTrue);
    semantics.dispose();
  });

  testWidgets(
    'same HTML rebuild retains state; replaced content resets defaults',
    (t) async {
      final semantics = t.ensureSemantics();
      const content =
          '<label><input type="checkbox">Remember this choice</label>';
      await t.pumpWidget(shell(content));
      await t.pumpAndSettle();
      await tapText(t, 'Remember this choice');
      expect(checked(t, 'Remember this choice'), isTrue);
      await t.pumpWidget(shell(content));
      await t.pumpAndSettle();
      expect(checked(t, 'Remember this choice'), isTrue);
      await t.pumpWidget(shell('$content<p>New content</p>'));
      await t.pumpAndSettle();
      expect(checked(t, 'Remember this choice'), isFalse);
      semantics.dispose();
    },
  );

  testWidgets(
    'nested links keep their action instead of toggling label control',
    (t) async {
      final semantics = t.ensureSemantics();
      String? link;
      await t.pumpWidget(
        shell(
          '<label><input type="checkbox" aria-label="Accept terms">Read <a href="https://example.com/terms">Terms</a></label>',
          onLink: (value) => link = value,
        ),
      );
      await t.pumpAndSettle();
      await tapText(t, 'Terms');
      expect(link, 'https://example.com/terms');
      expect(checked(t, 'Accept terms'), isFalse);
      final control = find.byType(NativeHtmlControlWidget);
      await t.tap(control);
      await t.pumpAndSettle();
      expect(checked(t, 'Accept terms'), isTrue);
      await t.sendKeyEvent(LogicalKeyboardKey.space);
      await t.pumpAndSettle();
      expect(checked(t, 'Accept terms'), isFalse);
      expect(t.takeException(), isNull);
      semantics.dispose();
    },
  );

  testWidgets(
    'named HTML disclosures enforce exclusivity while nested content remains interactive',
    (t) async {
      await t.pumpWidget(shell(source('html-details-groups')));
      await t.pumpAndSettle();
      Finder visible(String text) =>
          find.text(text, findRichText: true).hitTestable();
      expect(visible('First disclosure content.'), findsOneWidget);
      expect(visible('Second disclosure content.'), findsNothing);
      await tapText(t, 'Second named disclosure');
      expect(visible('First disclosure content.'), findsNothing);
      expect(visible('Second disclosure content.'), findsOneWidget);
      await tapText(t, 'Outer disclosure');
      expect(visible('Nested content.'), findsOneWidget);
      await tapText(t, 'Nested disclosure');
      expect(visible('Nested content.'), findsNothing);
      expect(t.takeException(), isNull);
    },
  );
  testWidgets('closed disclosure does not leak its hidden paragraph margin', (
    t,
  ) async {
    await t.pumpWidget(shell(source('html-details-groups')));
    await t.pumpAndSettle();
    Finder summary(String label) => find.byWidgetPredicate(
      (widget) =>
          widget is RichText && widget.text.toPlainText().contains(label),
    );
    final closed = t.getRect(summary('Closed details'));
    final next = t.getRect(summary('Initially open details'));
    expect(next.top, closeTo(closed.bottom, .01));
    await tapText(t, 'Closed details');
    await tapText(t, 'Closed details');
    expect(
      t.getRect(summary('Initially open details')).top,
      closeTo(closed.bottom, .01),
    );
  });

  testWidgets('radios in closed details become navigable after opening', (
    t,
  ) async {
    final semantics = t.ensureSemantics();
    await t.pumpWidget(
      shell(
        '<p><label><input type="radio" name="choice" checked>Outside</label></p><details><summary>More choices</summary><label><input type="radio" name="choice">Inside</label></details><label><input type="radio" name="choice">Last</label>',
      ),
    );
    await t.pumpAndSettle();
    await tapText(t, 'Outside');
    await t.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await t.pumpAndSettle();
    expect(checked(t, 'Last'), isTrue);
    await tapText(t, 'More choices');
    await tapText(t, 'Outside');
    await t.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await t.pumpAndSettle();
    expect(checked(t, 'Inside'), isTrue);
    expect(t.takeException(), isNull);
    semantics.dispose();
  });
}
