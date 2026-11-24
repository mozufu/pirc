// Run only against apps/android/dev/fake-gateway.ts on an isolated emulator.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:pirc_mobile/live/app.dart';
import 'package:pirc_mobile/live/gateway.dart';
import 'package:pirc_mobile/theme.dart';
import 'package:pirc_mobile/live/panels.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('Android bridge: pair, stream, send, panels, reconnect, home draft', (
    t,
  ) async {
    const enabled = bool.fromEnvironment('PIRC_LOCAL_SMOKE');
    expect(
      enabled,
      isTrue,
      reason:
          'Run with --dart-define=PIRC_LOCAL_SMOKE=true on an isolated emulator',
    );
    final gateway = Gateway();
    final link = Uri(
      scheme: 'pirc',
      host: 'pair',
      queryParameters: {
        'url': 'http://10.0.2.2:8799',
        'token': 'pirc_dev_${List.filled(43, 'd').join()}',
      },
    ).toString();
    await gateway.call('pair', {'link': link});
    await gateway.call('completeOnboarding');
    final oldPreferences = obj(await gateway.call('preferences'));
    await gateway.call('savePreferences', {
      'quiet': true,
      'start': 1320,
      'end': 480,
      'lock': 'summary',
    });
    final saved = obj(await gateway.call('preferences'));
    expect(saved['quiet'], true);
    expect(saved['start'], 1320);
    expect(saved['lock'], 'summary');
    await gateway.call('savePreferences', oldPreferences);
    final c = LiveController(gateway);
    final theme = await PircTheme.load();
    await t.pumpWidget(MobileApp(theme: theme, controller: c));
    Future<void> until(bool Function() ready) async {
      for (var i = 0; i < 100 && !ready(); i++) {
        await t.pump(const Duration(milliseconds: 200));
      }
      expect(ready(), isTrue, reason: c.error ?? c.actionError ?? 'Timed out');
    }

    await until(() => !c.booting && c.sessions.isNotEmpty);
    // An Android deep-link intent from a previous manual test is consumed by boot.
    if (c.pairLink != null) {
      c.pairLink = null;
      c.changed();
      await t.pump();
    }
    final id = '${c.sessions.first['id']}';
    await c.open(id);
    await until(() => c.canWrite && c.messages.isNotEmpty);
    expect(c.error, isNull);
    expect(c.models, isNotEmpty);
    c.editDraft('android smoke round trip');
    await c.send('prompt');
    await until(
      () => c.messages.any(
        (m) => '${m['content']}'.contains('android smoke round trip'),
      ),
    );
    expect(c.draft, isEmpty);
    expect(c.unknownCommand, isFalse);
    await t.pump(const Duration(seconds: 2));
    await t.tap(find.byTooltip('工作面板'));
    await t.pump(const Duration(seconds: 1));
    expect(find.textContaining('main'), findsWidgets);
    await t.tap(find.text('檔案').last);
    await t.pump(const Duration(seconds: 1));
    expect(find.text('src'), findsOneWidget);
    await t.tap(find.text('src'));
    await t.pump(const Duration(seconds: 1));
    final fileRow = find.descendant(
      of: find.byType(FilesPane),
      matching: find.widgetWithText(ListTile, 'parser.ts'),
    );
    expect(fileRow, findsOneWidget);
    await t.tap(fileRow);
    await t.pump(const Duration(seconds: 1));
    expect(find.textContaining('parse'), findsWidgets);
    await t.tap(find.byTooltip('返回對話'));
    await t.pump();
    c.editDraft('keep after home');
    await c.home();
    await t.pump();
    expect(find.text('今天想處理什麼？'), findsOneWidget);
    await c.open(id);
    await until(() => c.canWrite);
    expect(c.draft, 'keep after home');
    await c.lifecycle(false);
    await c.lifecycle(true);
    await until(() => c.connection == 'live');
    expect(c.draft, 'keep after home');
    // Exercise the raw terminal transport through the native WebSocket bridge.
    final terminal = obj(
      (await gateway.request(
        '${sessionPath(id)}/terminals',
        method: 'POST',
        body: {
          'clientId': c.clientId,
          'generation': c.control['generation'],
          'cols': 80,
          'rows': 24,
        },
      ))['terminal'],
    );
    final ready = gateway.events.firstWhere(
      (e) =>
          e['type'] == 'socket' &&
          obj(e['data'])['tag'] == 'smoke' &&
          obj(obj(e['data'])['frame'])['type'] == 'ready',
    );
    await gateway.call('socketOpen', {
      'tag': 'smoke',
      'path': '${sessionPath(id)}/terminals/${terminal['id']}/stream',
    });
    await ready.timeout(const Duration(seconds: 10));
    await gateway.call('socketClose', {'tag': 'smoke'});
    await gateway.request(
      '${sessionPath(id)}/terminals/${terminal['id']}/close',
      method: 'POST',
      body: {'clientId': c.clientId, 'generation': c.control['generation']},
    );
    await c.home();
    await t.pump();
    await t.enterText(
      find.byKey(const Key('home-draft')),
      'new session from home',
    );
    await t.pump(); // Rebuild the enabled submit button after editing.
    await t.tap(find.byTooltip('開始對話'));
    await t.pump();
    await until(() => c.sessionId != null && c.sessionId != id && c.canWrite);
    await until(
      () => c.messages.any(
        (m) => '${m['content']}'.contains('new session from home'),
      ),
    );
    expect(c.draft, isEmpty);
    expect(t.takeException(), isNull);
    await t.pumpWidget(const SizedBox());
    await t.pump();
  });
}
