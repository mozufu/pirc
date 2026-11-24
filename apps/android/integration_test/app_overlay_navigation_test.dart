import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:pirc_mobile/live/app.dart';
import 'package:pirc_mobile/live/document_navigation.dart';
import 'package:pirc_mobile/live/document_navigation_state.dart';
import 'package:pirc_mobile/live/gateway.dart';
import 'package:pirc_mobile/live/native_app_surface.dart';
import 'package:pirc_mobile/live/scoped_gateway.dart';
import 'package:pirc_mobile/live/settings_dialog.dart';
import 'package:pirc_render/src/html_form_submission.dart';
import 'package:pirc_mobile/theme.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('real Android App modal belongs to its native history surface', (
    t,
  ) async {
    expect(const bool.fromEnvironment('PIRC_REAL_GATEWAY'), isTrue);
    final raw = Gateway();
    await raw.call('pair', {
      'link': const String.fromEnvironment('PIRC_PAIR_LINK'),
    });
    await raw.call('completeOnboarding');
    final workspaces = rows(
      (await raw.request('/api/workspaces'))['workspaces'],
    );
    final workspace = workspaces.firstWhere((w) => w['kind'] == 'chat');
    final created = await raw.request(
      '/api/sessions',
      method: 'POST',
      body: {'workspaceId': workspace['id']},
    );
    final sessionId = '${obj(created['session'])['id']}';
    final root = DartScopedGateway(raw);
    final controller = LiveController(root);
    final theme = await PircTheme.load();
    Future<void> until(bool Function() ready, String label) async {
      for (var i = 0; i < 150 && !ready(); i++) {
        await t.pump(const Duration(milliseconds: 200));
      }
      expect(ready(), isTrue, reason: label);
      await t.pumpAndSettle();
      expect(t.takeException(), isNull, reason: label);
    }

    try {
      await t.pumpWidget(MobileApp(theme: theme, controller: controller));
      await until(
        () =>
            !controller.booting &&
            controller.sessionId == sessionId &&
            controller.state.isNotEmpty,
        'real LiveShell boots the disposable session',
      );
      final settings = find.text('Settings');
      await t.ensureVisible(settings);
      await t.tap(settings);
      await t.pumpAndSettle();
      expect(find.byType(NativeSettingsDialog), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('settings-tab-Memory')));
      await t.pumpAndSettle();
      final originalDialogState = t.state(find.byType(NativeSettingsDialog));
      final surface = t.state<NativeAppSurfaceState>(
        find.byType(NativeAppSurface),
      );
      final appContext = surface.ownedAppContext!;
      if (!appContext.mounted) {
        throw StateError('The source App surface was disposed.');
      }
      final scope = NativeDocumentScope.maybeOf(appContext)!;
      final host = NativeDocumentHost.maybeOf(appContext)!;
      final windows = scope.windows;
      final sourceSession = controller.sessionId;
      await openNativeDocument(
        appContext,
        scope,
        const NativeHtmlFormRequest(
          url: '/parity-documents/next',
          method: 'GET',
          target: '',
        ),
      );
      await t.pumpAndSettle();
      expect(
        windows.active?.currentDocument?.url,
        endsWith('/parity-documents/next'),
      );
      expect(find.byType(NativeSettingsDialog), findsNothing);
      expect(find.byType(NativeFetchedDocumentView), findsOneWidget);
      expect(
        find.byType(NativeSettingsDialog, skipOffstage: false),
        findsOneWidget,
      );
      await host.back();
      await t.pumpAndSettle();
      expect(controller.sessionId, sourceSession);
      expect(find.byType(NativeSettingsDialog), findsOneWidget);
      expect(
        t.state(find.byType(NativeSettingsDialog)),
        same(originalDialogState),
      );
      expect(surface.canPop, isTrue);
      final selected = t.widget<TextButton>(
        find.byKey(const ValueKey('settings-tab-Memory')),
      );
      expect(selected.focusNode!.skipTraversal, isFalse);
      final sourceIndex = windows.active?.index;
      await t.binding.handlePopRoute();
      await t.pumpAndSettle();
      expect(find.byType(NativeSettingsDialog), findsNothing);
      expect(
        windows.active?.index,
        sourceIndex,
        reason:
            'System Back closes the modal, preserving native document history.',
      );
      expect(controller.sessionId, sourceSession);
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
      await root.closeContext();
    }
  });
}
