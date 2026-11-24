import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:pirc_mobile/live/app.dart';
import 'package:pirc_mobile/live/gateway.dart';
import 'package:pirc_mobile/theme.dart';
import 'package:pirc_render/src/mermaid/native_mermaid.dart';
import 'package:pirc_render/src/mermaid/class_diagram.dart';
import 'package:pirc_render/src/mermaid/state_diagram.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'real Android native UML class and state diagrams from authenticated file',
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
          () => find.text('mermaid-uml.md').evaluate().isNotEmpty,
          'Mermaid fixture directory',
        );
        await tap(find.text('mermaid-uml.md'));
        await until(
          () => find.byType(NativeMermaidStateDiagram).evaluate().length == 2,
          'native Mermaid figures',
        );
        expect(find.byType(NativeMermaid), findsNWidgets(4));
        for (final type in [
          NativeMermaidClassDiagram,
          NativeMermaidStateDiagram,
        ]) {
          final figures = find.byType(type);
          expect(figures, findsNWidgets(2));
          for (var i = 0; i < 2; i++) {
            final figure = figures.at(i);
            await t.ensureVisible(figure);
            await t.pumpAndSettle();
            expect(t.getSize(figure).width, greaterThan(0));
            expect(t.getSize(figure).height, greaterThan(0));
            expect(t.takeException(), isNull);
          }
        }
        expect(find.textContaining('Mermaid:'), findsNothing);
        expect(find.textContaining('classDiagram'), findsNothing);
        expect(find.textContaining('stateDiagram-v2'), findsNothing);
        debugPrint(
          'REAL_GATEWAY:mermaid-native-class-state-authenticated-file',
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
