import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_render/src/native_markdown.dart';
import 'package:pirc_render/src/html_controls.dart';
import 'native_html_test.dart' show shell, tapText;

void main() {
  testWidgets(
    'HTML edits survive parent rebuild but new document gets defaults',
    (tester) async {
      const source =
          '<div><label for="editable-name">Name</label><input id="editable-name" value="Initial"></div>';
      await tester.pumpWidget(shell(source));
      await tester.pumpAndSettle();
      final editable = find.byType(EditableText);
      expect(editable, findsOneWidget);
      await tester.enterText(editable, 'User edit');
      await tester.pumpWidget(shell(source));
      await tester.pumpAndSettle();
      expect(
        tester.widget<EditableText>(editable).controller.text,
        'User edit',
      );
      await tester.pumpWidget(
        shell(source.replaceFirst('Initial', 'Replacement')),
      );
      await tester.pumpAndSettle();
      expect(
        tester.widget<EditableText>(editable).controller.text,
        'Replacement',
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('text and checkable label handlers coexist in native Markdown', (
    tester,
  ) async {
    await tester.pumpWidget(
      shell(
        '<div><label for="editable-name">Edit name</label><input id="editable-name">'
        '<label for="agree">Agree</label><input id="agree" type="checkbox"></div>',
      ),
    );
    await tester.pumpAndSettle();
    await tapText(tester, 'Edit name');
    final editable = tester.widget<EditableText>(find.byType(EditableText));
    expect(editable.focusNode.hasFocus, isTrue);
    await tester.enterText(find.byType(EditableText), 'Native');
    await tapText(tester, 'Agree');
    expect(editable.controller.text, 'Native');
    final checkable = tester.widget<NativeHtmlControlWidget>(
      find.byType(NativeHtmlControlWidget),
    );
    expect(checkable.state.isChecked(checkable.control.key), isTrue);
    expect(find.byType(NativeMarkdown), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
