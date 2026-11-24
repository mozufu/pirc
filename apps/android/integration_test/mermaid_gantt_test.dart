import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:pirc_mobile/live/app.dart';
import 'package:pirc_mobile/live/gateway.dart';
import 'package:pirc_mobile/live/scoped_gateway.dart';
import 'package:pirc_render/src/mermaid/gantt_rendering.dart';
import 'package:pirc_mobile/theme.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'real Android renders agent streamed Gantt with native Flutter paint',
    (t) async {
      expect(const bool.fromEnvironment('PIRC_REAL_GATEWAY'), isTrue);
      final raw = Gateway();
      await raw.call('pair', {
        'link': const String.fromEnvironment('PIRC_PAIR_LINK'),
      });
      await raw.call('completeOnboarding');
      final workspace = rows(
        (await raw.request('/api/workspaces'))['workspaces'],
      ).firstWhere((w) => w['kind'] == 'chat');
      final response = await raw.request(
        '/api/sessions',
        method: 'POST',
        body: {'workspaceId': workspace['id']},
      );
      final sessionId = '${obj(response['session'])['id']}';
      final scoped = DartScopedGateway(raw);
      final controller = LiveController(scoped);
      final theme = await PircTheme.load();
      Future<void> until(bool Function() ready, String label) async {
        for (var i = 0; i < 200 && !ready(); i++) {
          await t.pump(const Duration(milliseconds: 200));
        }
        expect(
          ready(),
          isTrue,
          reason:
              '$label: ${controller.error ?? controller.actionError ?? controller.connection}',
        );
        expect(t.takeException(), isNull, reason: label);
      }

      try {
        await t.pumpWidget(MobileApp(theme: theme, controller: controller));
        await until(
          () =>
              !controller.booting &&
              controller.sessionId == sessionId &&
              controller.canWrite,
          'disposable chat is writable',
        );
        await controller.open(sessionId);
        controller.editDraft('/parity-gantt weekend-dependencies-status');
        await controller.send('prompt');
        await until(
          () =>
              !controller.running &&
              find.byType(NativeMermaidGantt).evaluate().isNotEmpty,
          'real agent stream completes into a native chart',
        );
        await t.pumpAndSettle();
        final chart = t.widget<NativeMermaidGantt>(
          find.byType(NativeMermaidGantt),
        );
        expect(chart.diagram.tasks, hasLength(13));
        expect(chart.diagram.sections.map((section) => section.name), [
          'Planning',
          'Delivery',
        ]);
        expect(
          chart.layout!.tasks.every((task) => task.bounds.height == 20),
          isTrue,
        );
        expect(chart.layout!.exclusions, hasLength(2));
        expect(find.textContaining('Mermaid:'), findsNothing);
        final paints = t.widgetList<CustomPaint>(
          find.descendant(
            of: find.byType(NativeMermaidGantt),
            matching: find.byType(CustomPaint),
          ),
        );
        expect(
          paints.any((widget) => widget.painter is NativeGanttPainter),
          isTrue,
        );
        for (final endpoint in ['devices', 'providers', 'provider-auth']) {
          final reply = obj(
            await raw.call('document', {
              'url': '${controller.origin}/api/$endpoint',
              'method': 'GET',
              'pairingStamp': controller.pairingStamp,
            }),
          );
          expect(reply['status'], 403);
        }
        expect(t.takeException(), isNull);
      } finally {
        await t.pumpWidget(const SizedBox());
        try {
          await raw.request(sessionPath(sessionId), method: 'DELETE');
        } finally {
          await raw.call('unpair');
        }
        await scoped.closeContext();
      }
    },
  );
}
