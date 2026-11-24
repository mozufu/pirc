import 'dart:ui' show Tristate;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_widget_from_html_core/flutter_widget_from_html_core.dart';
import 'package:pirc_render/src/html_details.dart';

void main() {
  testWidgets('named details default closed and opening one closes its peers', (
    tester,
  ) async {
    final groups = NativeHtmlDetailsGroups();
    addTearDown(groups.dispose);

    await tester.pumpWidget(
      _shell(groups, '''
      <details name="exclusive">
        <summary>First section</summary><p>First body</p>
      </details>
      <details name="exclusive">
        <summary>Second section</summary><p><b>Second body</b></p>
      </details>
    '''),
    );

    expect(_content('First body'), findsNothing);
    expect(_content('Second body'), findsNothing);

    await tester.tap(_summary('First section'));
    await tester.pumpAndSettle();
    expect(_content('First body'), findsOneWidget);

    await tester.tap(_summary('Second section'));
    await tester.pumpAndSettle();
    expect(_content('First body'), findsNothing);
    expect(_content('Second body'), findsOneWidget);

    final body = tester.widget<RichText>(_content('Second body'));
    expect(body.text.style?.fontWeight, FontWeight.bold);
  });

  testWidgets('first authored open member wins in tree order', (tester) async {
    final groups = NativeHtmlDetailsGroups();
    addTearDown(groups.dispose);

    await tester.pumpWidget(
      _shell(groups, '''
      <details name="initially-open" open>
        <summary>First open</summary><p>Visible first</p>
      </details>
      <details name="initially-open" open>
        <summary>Second open</summary><p>Hidden second</p>
      </details>
    '''),
    );

    expect(_content('Visible first'), findsOneWidget);
    expect(_content('Hidden second'), findsNothing);
  });

  testWidgets(
    'nested details state survives closing and reopening its parent',
    (tester) async {
      final groups = NativeHtmlDetailsGroups();
      addTearDown(groups.dispose);

      await tester.pumpWidget(
        _shell(groups, '''
      <details>
        <summary>Outer section</summary>
        <details open>
          <summary>Inner section</summary><p>Inner body</p>
        </details>
      </details>
    '''),
      );

      expect(find.text('Inner section'), findsNothing);
      await tester.tap(_summary('Outer section'));
      await tester.pumpAndSettle();
      expect(_content('Inner body'), findsOneWidget);

      await tester.tap(_summary('Inner section'));
      await tester.pumpAndSettle();
      expect(_content('Inner body'), findsNothing);

      await tester.tap(_summary('Outer section'));
      await tester.pumpAndSettle();
      await tester.tap(_summary('Outer section'));
      await tester.pumpAndSettle();
      expect(_summary('Inner section'), findsOneWidget);
      expect(_content('Inner body'), findsNothing);
    },
  );

  testWidgets('summary exposes a button and toggles with Enter and Space', (
    tester,
  ) async {
    final groups = NativeHtmlDetailsGroups();
    addTearDown(groups.dispose);

    await tester.pumpWidget(
      _shell(groups, '''
      <details name="keyboard">
        <summary>Keyboard section</summary><p>Keyboard body</p>
      </details>
    '''),
    );

    final summary = _summary('Keyboard section');
    final semanticsHandle = tester.ensureSemantics();
    final semantics = tester.getSemantics(summary).getSemanticsData();
    expect(semantics.hasAction(SemanticsAction.tap), isTrue);
    expect(semantics.flagsCollection.isExpanded, Tristate.isFalse);
    expect(semantics.flagsCollection.isButton, isTrue);

    await tester.tap(summary);
    await tester.pumpAndSettle();
    expect(_content('Keyboard body'), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(_content('Keyboard body'), findsNothing);

    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pumpAndSettle();
    expect(_content('Keyboard body'), findsOneWidget);
    semanticsHandle.dispose();
  });

  testWidgets('authored open updates still apply after native interaction', (
    tester,
  ) async {
    final groups = NativeHtmlDetailsGroups();
    addTearDown(groups.dispose);
    String source(bool open) =>
        '<details ${open ? 'open' : ''}><summary>Dynamic section</summary><p>Dynamic body</p></details>';
    await tester.pumpWidget(_shell(groups, source(false)));
    await tester.tap(_summary('Dynamic section'));
    await tester.pumpAndSettle();
    expect(_content('Dynamic body'), findsOneWidget);
    await tester.pumpWidget(_shell(groups, source(true)));
    await tester.pumpAndSettle();
    expect(_content('Dynamic body'), findsOneWidget);
    await tester.pumpWidget(_shell(groups, source(false)));
    await tester.pumpAndSettle();
    expect(_content('Dynamic body'), findsNothing);
  });

  testWidgets('only the first direct summary is an activation surface', (
    tester,
  ) async {
    final groups = NativeHtmlDetailsGroups();
    addTearDown(groups.dispose);
    await tester.pumpWidget(
      _shell(
        groups,
        '<details open><summary>Primary</summary><summary>Ordinary body summary</summary><p>Still open</p></details>',
      ),
    );
    await tester.tap(_summary('Ordinary body summary'));
    await tester.pumpAndSettle();
    expect(_content('Still open'), findsOneWidget);
  });

  testWidgets('a keyed HTML replacement resets the authored open state', (
    tester,
  ) async {
    var source = '''
      <details name="replacement">
        <summary>Replaceable section</summary><p>Replaceable body</p>
      </details>
    ''';
    var groups = NativeHtmlDetailsGroups();
    addTearDown(() => groups.dispose());

    await tester.pumpWidget(_replacementShell(source, groups));
    await tester.tap(_summary('Replaceable section'));
    await tester.pumpAndSettle();
    expect(_content('Replaceable body'), findsOneWidget);

    groups.dispose();
    groups = NativeHtmlDetailsGroups();
    source = '$source ';
    await tester.pumpWidget(_replacementShell(source, groups));
    expect(_content('Replaceable body'), findsNothing);
  });
}

Widget _shell(NativeHtmlDetailsGroups groups, String source) => MaterialApp(
  home: Scaffold(
    body: HtmlWidget(source, factoryBuilder: () => _DetailsFactory(groups)),
  ),
);

Finder _summary(String label) => find.byWidgetPredicate(
  (widget) => widget is RichText && widget.text.toPlainText().contains(label),
);

Finder _content(String label) => find.text(label, findRichText: true);

Widget _replacementShell(String source, NativeHtmlDetailsGroups groups) =>
    MaterialApp(
      home: Scaffold(
        body: HtmlWidget(
          source,
          key: ValueKey(source),
          factoryBuilder: () => _DetailsFactory(groups),
        ),
      ),
    );

class _DetailsFactory extends WidgetFactory {
  _DetailsFactory(this.groups);

  final NativeHtmlDetailsGroups groups;

  @override
  void parse(BuildTree tree) {
    if (registerNativeHtmlDetails(tree, this, groups)) return;
    super.parse(tree);
  }
}
