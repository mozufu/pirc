import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_app/src/settings/management_access.dart';
import 'package:pirc_client/pirc_client.dart';

import 'support/harness.dart';

/// Already holds a grant for [capabilities].
class _Granted extends ManagementAccess {
  _Granted(this.capabilities);
  final List<String> capabilities;

  @override
  AccessState build() =>
      AccessState(phase: AccessPhase.granted, capabilities: capabilities);
}

Future<FakeGateway> _page(
  WidgetTester tester,
  String path,
  void Function(FakeGateway g) routes, {
  List<String> granted = const [],
  bool settle = true,
}) async {
  final gateway = FakeGateway();
  routes(gateway);
  await pumpApp(
    tester,
    gateway: gateway,
    location: '/settings/$path',
    settle: settle,
    overrides: [
      if (granted.isNotEmpty)
        managementAccessProvider.overrideWith(() => _Granted(granted)),
    ],
  );
  if (!settle) {
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }
  return gateway;
}

final _snapshot = {
  'providers': [
    {
      'id': 'openrouter',
      'name': 'OpenRouter',
      'source': 'ui',
      'readOnly': false,
      'api': 'openai-chat',
      'baseUrl': 'https://openrouter.ai/api/v1',
      'hasApiKey': true,
      'models': [
        {'id': 'm1', 'name': 'Model one'},
        {'id': 'm2', 'name': 'Model two'},
      ],
    },
  ],
  'oauthProviders': [
    {
      'id': 'anthropic',
      'name': 'Anthropic',
      'providerId': 'oauth:anthropic',
      'connected': true,
      'requiresPolicyConsent': false,
    },
  ],
  'defaultModel': {'provider': 'openrouter', 'id': 'm1'},
};

void main() {
  group('providers', () {
    appTest('without the grant, it asks for access', (tester) async {
      await _page(tester, 'providers', (_) {});
      expect(find.text('Approval needed'), findsOneWidget);
    });

    appTest('lists providers and accounts; sets the default model', (
      tester,
    ) async {
      final g = await _page(tester, 'providers', (g) {
        g.json['GET /api/providers'] = (_) => _snapshot;
        g.json['PUT /api/providers/default-model'] = (_) => _snapshot;
      }, granted: ['providers']);
      expect(find.text('OpenRouter'), findsOneWidget);
      expect(find.text('Anthropic'), findsOneWidget);
      expect(find.text('Signed in'), findsOneWidget);
      await tester.tap(find.byKey(const Key('default-model')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Model two').last);
      await tester.pumpAndSettle();
      expect(g.sent('PUT', '/api/providers/default-model').single.json, {
        'provider': 'openrouter',
        'id': 'm2',
      });
    });

    appTest('signing out of an account removes oauth:<id>', (tester) async {
      final g = await _page(tester, 'providers', (g) {
        g.json['GET /api/providers'] = (_) => _snapshot;
        g.json['DELETE /api/providers/oauth%3Aanthropic'] = (_) => _snapshot;
      }, granted: ['providers']);
      await tester.tap(find.text('Sign out'));
      await tester.pumpAndSettle();
      expect(
        g.sent('DELETE', '/api/providers/oauth%3Aanthropic'),
        hasLength(1),
      );
    });

    appTest('failed', (tester) async {
      await _page(tester, 'providers', (g) {
        g.json['GET /api/providers'] = (_) => apiError(500, 'internal');
      }, granted: ['providers']);
      expect(find.text('The list could not be loaded.'), findsOneWidget);
    });
  });

  group('memory', () {
    final view = {
      'user': [
        {'id': 'e1', 'kind': 'user', 'content': 'Prefers short answers'},
      ],
      'notes': <Object?>[],
      'removed': [
        {'id': 'e2', 'kind': 'user', 'content': 'Old fact'},
      ],
      'proposals': [
        {'id': 'p1', 'action': 'add', 'content': 'Lives in Taipei'},
      ],
    };

    appTest('loading', (tester) async {
      final never = Completer<ApiResponse?>();
      await _page(tester, 'memory', (g) {
        g.routes.add((r) => r.path == '/api/memory' ? never.future : null);
      }, settle: false);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      never.complete(reply(200, view));
      await tester.pumpAndSettle();
    });

    appTest('approve a proposal, forget and restore entries', (tester) async {
      final g = await _page(tester, 'memory', (g) {
        g.json['GET /api/memory'] = (_) => view;
        for (final path in [
          '/api/memory/proposals/p1/approve',
          '/api/memory/entries/e1/forget',
          '/api/memory/entries/e2/restore',
        ]) {
          g.json['POST $path'] = (_) => view;
        }
      });
      await tester.tap(find.text('Approve'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Forget'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Restore'));
      await tester.pumpAndSettle();
      expect(
        [for (final r in g.requests.where((r) => r.method == 'POST')) r.path],
        [
          '/api/memory/proposals/p1/approve',
          '/api/memory/entries/e1/forget',
          '/api/memory/entries/e2/restore',
        ],
      );
    });

    appTest('failed, then retried', (tester) async {
      var fail = true;
      await _page(tester, 'memory', (g) {
        g.json['GET /api/memory'] = (_) =>
            fail ? apiError(500, 'internal') : view;
      });
      expect(find.text('The list could not be loaded.'), findsOneWidget);
      fail = false;
      await tester.tap(find.text('Try again'));
      await tester.pumpAndSettle();
      expect(find.text('Prefers short answers'), findsOneWidget);
    });
  });

  group('notifications', () {
    final status = {
      'publicKey': 'k',
      'subscriptions': [
        {'id': 'sub1', 'kind': 'web', 'name': 'Firefox', 'failing': false},
      ],
    };

    appTest('lists targets; remove and send a test', (tester) async {
      final g = await _page(tester, 'notifications', (g) {
        g.json['GET /api/push'] = (_) => status;
        g.json['DELETE /api/push/subscriptions'] = (_) => reply(204);
        g.json['POST /api/push/test'] = (_) => {'delivered': 1};
      });
      expect(find.text('Firefox'), findsOneWidget);
      await tester.tap(find.text('Send a test'));
      await tester.pumpAndSettle();
      expect(find.text('Sent to 1 targets.'), findsOneWidget);
      await tester.tap(find.text('Remove'));
      await tester.pumpAndSettle();
      expect(g.sent('DELETE', '/api/push/subscriptions').single.json, {
        'id': 'sub1',
      });
    });

    appTest('failed', (tester) async {
      await _page(tester, 'notifications', (g) {
        g.json['GET /api/push'] = (_) => apiError(500, 'internal');
      });
      expect(find.text('The list could not be loaded.'), findsOneWidget);
    });
  });

  group('calendar and agent access', () {
    appTest('switches send both values', (tester) async {
      var current = {'allowRead': false, 'allowPropose': false};
      final g = await _page(tester, 'calendar', (g) {
        g.json['GET /api/calendar/permissions'] = (_) => current;
        g.json['PATCH /api/calendar/permissions'] = (r) {
          current = (r.json! as Map).cast();
          return current;
        };
      });
      final propose = tester.widget<SwitchListTile>(
        find.widgetWithText(SwitchListTile, 'Agents may propose changes'),
      );
      expect(propose.onChanged, isNull, reason: 'needs read first');
      await tester.tap(find.text('Agents may read the calendar'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Agents may propose changes'));
      await tester.pumpAndSettle();
      expect(
        [for (final r in g.sent('PATCH', '/api/calendar/permissions')) r.json],
        [
          {'allowRead': true, 'allowPropose': false},
          {'allowRead': true, 'allowPropose': true},
        ],
      );
    });

    appTest('failed', (tester) async {
      await _page(tester, 'calendar', (g) {
        g.json['GET /api/calendar/permissions'] = (_) =>
            apiError(500, 'internal');
      });
      expect(find.text('The list could not be loaded.'), findsOneWidget);
    });
  });

  group('modes', () {
    appTest('lists each mode, read only', (tester) async {
      await _page(tester, 'modes', (g) {
        g.json['GET /api/modes'] = (_) => {
          'modes': [
            {'id': 'default', 'label': 'Coding', 'description': 'Edits code'},
          ],
        };
      });
      expect(find.text('Coding'), findsOneWidget);
      expect(find.text('default · Edits code'), findsOneWidget);
    });

    appTest('failed', (tester) async {
      await _page(tester, 'modes', (g) {
        g.json['GET /api/modes'] = (_) => apiError(500, 'internal');
      });
      expect(find.text('The list could not be loaded.'), findsOneWidget);
    });
  });
}
