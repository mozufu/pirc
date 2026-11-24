import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_render/src/html_syntax.dart';
import 'package:pirc_render/src/native_html.dart';
import 'live_test.dart' show theme;

void main() {
  testWidgets(
    'script snapshots keep authored defaults for persisted text values',
    (t) async {
      final history = NativeHtmlHistoryController();
      await t.pumpWidget(
        MaterialApp(
          theme: theme.build(Brightness.light),
          home: Scaffold(
            body: NativeHtmlDocument(
              nodes: [
                NativeHtmlRaw(
                  '<input id="draft" name="draft" value="live edit" data-pirc-script-id="pirc-1" data-pirc-history-default-value="initial">',
                ),
              ],
              style: const TextStyle(fontSize: 16),
              styles: MarkdownStyleSheet(),
              builders: const {},
              historyController: history,
              scriptDocument: Object(),
              scriptSnapshot: Object(),
            ),
          ),
        ),
      );
      await t.pumpAndSettle();
      expect(history.capture()!.controls.values.single.text, 'live edit');
      await t.pumpWidget(const SizedBox.shrink());
      history.dispose();
    },
  );
  testWidgets(
    'fresh history values survive first scripted DOM and synchronize without input events',
    (t) async {
      final original = NativeHtmlHistoryController();
      final fresh = NativeHtmlHistoryController();
      final identity = Object();
      final restored = <List<Map<String, dynamic>>>[];
      Future<void> render(
        String source,
        NativeHtmlHistoryController history, {
        Object? snapshot,
      }) async {
        await t.pumpWidget(
          MaterialApp(
            theme: theme.build(Brightness.light),
            home: Scaffold(
              body: NativeHtmlDocument(
                nodes: [NativeHtmlRaw(source)],
                style: const TextStyle(fontSize: 16),
                styles: MarkdownStyleSheet(),
                builders: const {},
                historyController: history,
                scriptDocument: identity,
                scriptSnapshot: snapshot,
                onScriptRestoreControls: (controls) async {
                  restored.add(controls);
                },
              ),
            ),
          ),
        );
        await t.pumpAndSettle();
      }

      await render('<input name="draft" value="initial">', original);
      await t.enterText(find.byType(TextField), 'persisted edit');
      final saved = original.capture()!;
      await t.pumpWidget(const SizedBox.shrink());
      fresh.restore(saved);
      await render('<input name="draft" value="new default">', fresh);
      expect(
        t.widget<TextField>(find.byType(TextField)).controller!.text,
        'persisted edit',
      );
      expect(restored, isEmpty);
      await render(
        '<input name="draft" value="new default" data-pirc-script-id="pirc-1" data-pirc-history-default-value="new default">',
        fresh,
        snapshot: Object(),
      );
      expect(
        t.widget<TextField>(find.byType(TextField)).controller!.text,
        'persisted edit',
      );
      expect(restored, hasLength(1));
      expect(restored.single.single['id'], 'pirc-1');
      expect(restored.single.single['value'], 'persisted edit');
      expect(t.takeException(), isNull);
      await t.pumpWidget(const SizedBox.shrink());
      original.dispose();
      fresh.dispose();
    },
  );
}
