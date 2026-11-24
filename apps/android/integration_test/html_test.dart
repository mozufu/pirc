import 'package:pirc_mobile/rendering/remote_content_gate.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_widget_from_html_core/flutter_widget_from_html_core.dart';
import 'package:integration_test/integration_test.dart';
import 'package:pirc_mobile/live/app.dart';
import 'package:pirc_mobile/live/files_pane.dart';
import 'package:pirc_mobile/live/gateway.dart';
import 'package:pirc_mobile/live/markdown_image.dart';
import 'package:pirc_mobile/theme.dart';
import 'package:pirc_mobile/rendering/code_block.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  // These suites exercise the image/media loaders themselves, not the hold-back.
  setUpAll(() => NativeRemoteContentPolicy.debugOpenForTests = true);
  tearDownAll(() => NativeRemoteContentPolicy.debugOpenForTests = false);
  testWidgets(
    'real Android HTML disclosure, code clipboard and authenticated image link',
    (t) async {
      expect(const bool.fromEnvironment('PIRC_REAL_GATEWAY'), isTrue);
      const id = String.fromEnvironment('PIRC_FILES_SESSION');
      expect(id, isNotEmpty, reason: 'Start the isolated helper with --files.');
      final g = Gateway();
      await g.call('pair', {
        'link': const String.fromEnvironment('PIRC_PAIR_LINK'),
      });
      await g.call('completeOnboarding');
      final preferences = obj(await g.call('preferences'));
      final c = LiveController(g), theme = await PircTheme.load();
      Future<void> until(bool Function() ready, String label) async {
        for (var i = 0; i < 150 && !ready(); i++) {
          await t.pump(const Duration(milliseconds: 200));
        }
        expect(ready(), isTrue, reason: label);
        expect(t.takeException(), isNull, reason: label);
      }

      Future<void> tap(Finder finder) async {
        await t.ensureVisible(finder);
        await t.pumpAndSettle();
        expect(finder.hitTestable(), findsOneWidget);
        await t.tap(finder);
        await t.pumpAndSettle();
      }

      try {
        await g.call('savePreferences', {
          'detailsOpen': false,
          'sidebarCollapsed': false,
        });
        await t.pumpWidget(MobileApp(theme: theme, controller: c));
        await until(
          () => !c.booting && c.sessions.any((s) => s['id'] == id),
          'boot fixture',
        );
        await tap(find.text('Native files fixture'));
        await until(
          () => c.sessionId == id && c.state.isNotEmpty,
          'open session',
        );
        await tap(find.byTooltip('Show side panel'));
        await until(
          () => find.text('docs').evaluate().isNotEmpty,
          'files root',
        );
        await tap(find.text('docs'));
        await until(
          () => find.text('html.md').evaluate().isNotEmpty,
          'HTML fixture directory',
        );
        await tap(find.text('html.md'));
        await until(
          () => find.byType(HtmlWidget).evaluate().isNotEmpty,
          'native HTML document',
        );
        final summary = find.textContaining(
          'Open native details',
          findRichText: true,
        );
        final nested = find.textContaining(
          'stays inside the disclosure.',
          findRichText: true,
        );
        expect(nested.hitTestable(), findsNothing);
        await tap(summary);
        expect(nested.hitTestable(), findsOneWidget);
        expect(find.text('Native table', findRichText: true), findsOneWidget);
        expect(find.text('Ready', findRichText: true), findsOneWidget);
        await tap(summary);
        expect(nested.hitTestable(), findsNothing);
        final codeBlock = find.byType(NativeCodeBlock);
        final colors = Theme.of(t.element(codeBlock)).extension<PircColors>()!;
        List<String> keywordText(
          InlineSpan span, [
          TextStyle parent = const TextStyle(),
        ]) {
          final style = parent.merge(span.style);
          if (span is! TextSpan) return [];
          return [
            if (style.color == colors['web.hl-keyword'] && span.text != null)
              span.text!,
            for (final child in span.children ?? <InlineSpan>[])
              ...keywordText(child, style),
          ];
        }

        final fenced = t
            .widgetList<RichText>(
              find.descendant(of: codeBlock, matching: find.byType(RichText)),
            )
            .expand((w) => keywordText(w.text))
            .join();
        expect(fenced, contains('const'));
        expect(fenced, contains('true'));
        final authored = t.widget<RichText>(
          find.byWidgetPredicate(
            (w) =>
                w is RichText &&
                w.text.toPlainText() == 'const rawReady = true;',
          ),
        );
        expect(keywordText(authored.text).join(), 'consttrue');
        await tap(find.text('Copy'));
        expect(
          (await Clipboard.getData(Clipboard.kTextPlain))?.text,
          'const ready = true;',
        );
        final svg = find.descendant(
          of: find.byType(NativeMarkdownImage),
          matching: find.byType(SvgPicture),
        );
        await until(
          () => svg.evaluate().isNotEmpty,
          'authenticated redirected HTML image',
        );
        expect(t.getSize(svg), const Size(300, 140));
        await tap(svg);
        await until(
          () => find.byType(NativeFileSource).evaluate().isNotEmpty,
          'HTML image file link',
        );
        final source = t.widget<NativeFileSource>(
          find.byType(NativeFileSource),
        );
        expect(source.file['path'], 'src/main.ts');
        expect(source.line, 4);
        expect(source.file['content'], contains('Hello Flutter'));
        final sourceText = t.widget<SelectableText>(
          find.descendant(
            of: find.byType(NativeFileSource),
            matching: find.byType(SelectableText),
          ),
        );
        expect(keywordText(sourceText.textSpan!).join(), contains('export'));

        debugPrint(
          'REAL_GATEWAY:html-native-details-table-highlight-copy-authenticated-image-highlighted-file',
        );
      } finally {
        await g.call('savePreferences', preferences);
        await t.pumpWidget(const SizedBox());
        await g.call('unwatch');
      }
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
