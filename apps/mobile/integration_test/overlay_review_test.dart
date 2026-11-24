// Deliberately pauses each live native overlay for external adb screenshots.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:pirc_mobile/live/gateway.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('native overlay states with real HTTP snapshot and lease', (
    t,
  ) async {
    expect(const bool.fromEnvironment('PIRC_LOCAL_SMOKE'), true);
    await Future<void>.delayed(const Duration(seconds: 6));
    final g = Gateway();
    await g.call('pair', {
      'link': Uri(
        scheme: 'pirc',
        host: 'pair',
        queryParameters: {
          'url': 'http://10.0.2.2:8800',
          'token': 'pirc_dev_${List.filled(43, 'd').join()}',
        },
      ).toString(),
    });
    await t.pumpWidget(
      const MaterialApp(home: Scaffold(body: Text('Native overlay review'))),
    );
    for (final scenario in [
      'ready',
      'handled',
      'expired',
      'offline',
      'controlled',
      'schedule',
      'submit',
    ]) {
      await g.request(
        '/api/review/scenario?kind=${scenario == 'schedule' || scenario == 'submit' ? 'ready' : scenario}',
      );
      await g.call('savePreferences', {
        'appearance': scenario == 'ready' ? 'dark' : 'light',
      });
      await g.call('overlay',scenario=='schedule'?{'scheduleId':'review'}:{'sessionId':'s1','interactionId':'review-q'});
      // The external review captures and verifies Android views during this window.
      debugPrint('OVERLAY_REVIEW:$scenario');
      await Future<void>.delayed(const Duration(seconds: 12));
    }
    await g.call('savePreferences', {'appearance': 'system'});
    await t.pumpWidget(const SizedBox());
  });
}
