import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_widget_from_html_core/flutter_widget_from_html_core.dart';
import 'package:pirc_render/src/html_fieldset.dart';

void main() {
  testWidgets('fieldset without a legend retains block children', (
    tester,
  ) async {
    await tester.pumpWidget(
      _shell('''
        <fieldset>
          <p>First <strong>paragraph</strong></p>
          <p>Second paragraph</p>
        </fieldset>
      '''),
    );

    expect(_richTextContaining(tester, 'First paragraph'), findsOneWidget);
    expect(_richTextContaining(tester, 'Second paragraph'), findsOneWidget);
    expect(
      tester.getTopLeft(_richTextContaining(tester, 'First paragraph')).dy,
      lessThan(
        tester.getTopLeft(_richTextContaining(tester, 'Second paragraph')).dy,
      ),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'first direct legend is preserved and later legends stay in flow',
    (tester) async {
      String? tappedUrl;
      await tester.pumpWidget(
        _shell(
          '''
        <fieldset>
          <legend><a href="https://example.test/legend">legend link</a></legend>
          <p>Field content with <strong>bold text</strong></p>
          <legend>Secondary legend</legend>
          <p>Last content</p>
        </fieldset>
      ''',
          onTapUrl: (url) {
            tappedUrl = url;
            return true;
          },
        ),
      );

      final legend = find.text('legend link', findRichText: true);
      final body = _richTextContaining(tester, 'Field content with bold text');
      final secondLegend = _richTextContaining(tester, 'Secondary legend');
      final tail = _richTextContaining(tester, 'Last content');
      expect(legend, findsOneWidget);
      expect(body, findsOneWidget);
      expect(secondLegend, findsOneWidget);
      expect(tail, findsOneWidget);
      expect(_richTextContaining(tester, 'bold text'), findsOneWidget);
      expect(
        tester.getTopLeft(legend).dy,
        lessThan(tester.getTopLeft(body).dy),
      );
      expect(
        tester.getTopLeft(body).dy,
        lessThan(tester.getTopLeft(secondLegend).dy),
      );
      expect(
        tester.getTopLeft(secondLegend).dy,
        lessThan(tester.getTopLeft(tail).dy),
      );

      await tester.tap(find.text('legend link', findRichText: true));
      expect(tappedUrl, 'https://example.test/legend');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('nested fieldsets and long legend text lay out at narrow width', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(240, 600);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);

    await tester.pumpWidget(
      _shell('''
        <fieldset>
          <legend>A long caption that wraps without dropping its child content</legend>
          <fieldset>
            <legend>Nested caption</legend>
            <p>Nested content</p>
          </fieldset>
          <p>Outer content</p>
        </fieldset>
      '''),
    );

    expect(_richTextContaining(tester, 'Nested caption'), findsOneWidget);
    expect(_richTextContaining(tester, 'Nested content'), findsOneWidget);
    expect(_richTextContaining(tester, 'Outer content'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

Widget _shell(String source, {bool Function(String)? onTapUrl}) => MaterialApp(
  home: Scaffold(
    body: Padding(
      padding: const EdgeInsets.all(16),
      child: HtmlWidget(
        source,
        factoryBuilder: _FieldsetFactory.new,
        onTapUrl: onTapUrl,
        textStyle: const TextStyle(fontFamily: 'Arial', fontSize: 15),
      ),
    ),
  ),
);

Finder _richTextContaining(WidgetTester tester, String substring) =>
    find.byWidgetPredicate(
      (widget) =>
          widget is RichText && widget.text.toPlainText().contains(substring),
      description: 'RichText containing "$substring"',
    );

class _FieldsetFactory extends WidgetFactory {
  @override
  void parse(BuildTree tree) {
    if (registerNativeHtmlFieldset(tree, this)) return;
    super.parse(tree);
  }
}
