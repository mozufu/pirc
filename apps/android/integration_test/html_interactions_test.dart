import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:pirc_mobile/live/app.dart';
import 'package:pirc_mobile/live/gateway.dart';
import 'package:pirc_mobile/theme.dart';
import 'package:pirc_render/src/html_controls.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'real Android authenticated HTML control labels and exclusive disclosures',
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

      final semantics = t.ensureSemantics();
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
          () => find.text('html-interactions.md').evaluate().isNotEmpty,
          'HTML interaction fixture directory',
        );
        await tap(find.text('html-interactions.md'));
        await until(
          () => find.byType(NativeHtmlControlWidget).evaluate().isNotEmpty,
          'native HTML controls',
        );
        bool checked(String label) =>
            t
                .getSemantics(find.bySemanticsLabel(label))
                .getSemanticsData()
                .flagsCollection
                .isChecked ==
            ui.CheckedState.isTrue;
        Finder label(String text) =>
            find.textContaining(text, findRichText: true);
        Future<void> tapLabel(String value) async {
          final finder = find
              .byWidgetPredicate(
                (w) => w is RichText && w.text.toPlainText().contains(value),
              )
              .first;
          await t.ensureVisible(finder);
          await t.pumpAndSettle();
          final rich = t.widget<RichText>(finder);
          final render = t.renderObject<RenderParagraph>(finder);
          final start = rich.text.toPlainText().indexOf(value);
          final box = render
              .getBoxesForSelection(
                TextSelection(baseOffset: start, extentOffset: start + 1),
              )
              .first
              .toRect();
          await t.tapAt(render.localToGlobal(box.center));
          await t.pumpAndSettle();
        }

        await tapLabel('Enable the option');
        expect(checked('Enabled unchecked checkbox'), isTrue);
        await tapLabel('Keep this option');
        expect(checked('Keep this option'), isFalse);
        await tapLabel('Unavailable option');
        expect(checked('Unavailable option'), isFalse);
        await tapLabel('Beta answer');
        expect(checked('Beta answer'), isTrue);
        expect(checked('Alpha answer'), isFalse);
        await tapLabel('Delta answer');
        expect(checked('Beta answer'), isFalse);
        expect(checked('Delta answer'), isTrue);
        await tapLabel('Second named disclosure');
        expect(label('First disclosure content.').hitTestable(), findsNothing);
        await t.ensureVisible(label('Second disclosure content.'));
        expect(
          label('Second disclosure content.').hitTestable(),
          findsOneWidget,
        );
        await tapLabel('Outer disclosure');
        await t.ensureVisible(label('Nested content.'));
        expect(label('Nested content.').hitTestable(), findsOneWidget);
        await tapLabel('Nested disclosure');
        expect(label('Nested content.').hitTestable(), findsNothing);
        expect(t.takeException(), isNull);
        debugPrint(
          'REAL_GATEWAY:html-native-checkbox-radio-labels-exclusive-nested-details',
        );
      } finally {
        semantics.dispose();
        await g.call('savePreferences', preferences);
        await t.pumpWidget(const SizedBox());
        await g.call('unwatch');
      }
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
