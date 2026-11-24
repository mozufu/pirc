import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_render/src/html_date.dart';
import 'package:pirc_render/src/html_syntax.dart';
import 'package:pirc_render/src/html_text_fields.dart';
import 'package:pirc_render/src/native_html.dart';
import 'live_test.dart' show theme;

void main() {
  testWidgets('eligible dates and partial segments survive fresh HTTP history', (
    tester,
  ) async {
    Future<void> render(
      NativeHtmlHistoryController history,
      String initialDate,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: theme.build(Brightness.light),
          home: Scaffold(
            body: NativeHtmlDocument(
              key: ValueKey(history),
              nodes: [
                NativeHtmlRaw(
                  '<form id="f"><input name="visit" type="date" value="$initialDate"><input name="message" value="server default"></form>',
                ),
              ],
              style: const TextStyle(fontSize: 16),
              styles: MarkdownStyleSheet(),
              builders: const {},
              historyController: history,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    NativeHtmlDateInput date() =>
        tester.widget<NativeHtmlDateInput>(find.byType(NativeHtmlDateInput));
    NativeHtmlTextFieldWidget text() =>
        tester.widget<NativeHtmlTextFieldWidget>(
          find.byType(NativeHtmlTextFieldWidget),
        );
    for (final partial in [false, true]) {
      final original = NativeHtmlHistoryController();
      await render(original, '2024-06-15');
      final control = date();
      if (partial) {
        control.state.updateSegment(
          control.control.key,
          NativeHtmlDateSegment.year,
          '',
        );
      } else {
        control.state.setValue(control.control.key, '2024-06-17');
      }
      text().state.controllerFor(text().field.key).text = 'user edit';
      final snapshot = original.capture()!;
      expect(
        snapshot.controls.values.any(
          (entry) => entry.kind == NativeHtmlHistoryValueKind.date,
        ),
        isTrue,
      );
      final fresh = NativeHtmlHistoryController()
        ..restore(snapshot.forFreshResponse());
      await render(fresh, '2025-01-02');
      expect(
        date().state.valueFor(date().control.key),
        partial ? '' : '2024-06-17',
      );
      expect(date().state.badInputFor(date().control.key), partial);
      expect(text().state.valueFor(text().field.key), 'user edit');
      final held = NativeHtmlHistoryController()..restore(snapshot);
      await render(held, '2024-06-15');
      expect(
        date().state.valueFor(date().control.key),
        partial ? '' : '2024-06-17',
      );
      expect(date().state.badInputFor(date().control.key), partial);
      expect(tester.takeException(), isNull);
    }
  });
}
