import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_app/src/format.dart';
import 'package:pirc_app/src/preferences.dart';
import 'package:pirc_app/src/router.dart';

import 'support/chat_fixtures.dart';
import 'support/fonts.dart';
import 'support/harness.dart';
import 'support/work_fixtures.dart';

const _page = '/settings/pots';

Map<String, Object?> _full(
  Map<String, Object?> summary, {
  String provider = 'anthropic',
  String model = 'claude-sonnet',
  String thinking = 'medium',
  bool auto = false,
  int? money = 20000000,
  int? tokens = 2000000,
  int revision = 7,
  int updatedAt = 0,
}) {
  final pot = fullPotJson(
    summary,
    moneyMicros: money,
    tokens: tokens,
    revision: revision,
  );
  return {
    ...pot,
    'updatedAt': updatedAt,
    'models': {
      'main': {'provider': provider, 'model': model},
      'thinking': thinking,
      'thinkingAuto': auto,
    },
  };
}

/// E23: four pots (one working, one paused) and an archived one, the
/// owner-wide limits ($50 a month, 5M tokens a day) and the pots' usage
/// ($12.40 this month, 1.6M tokens today).
class PotsSettingsFixture extends ChatFixture {
  PotsSettingsFixture() {
    pots = [
      _full(
        potJson(
          'p-butler',
          'Butler',
          color: 1,
          intro: 'Manager',
          budgetLeft: {'moneyMicros': 15800000, 'tokens': 1500000},
        ),
        auto: true,
      ),
      _full(
        potJson(
          'p-research',
          'Researcher',
          color: 3,
          intro: 'Research',
          budgetLeft: {'moneyMicros': 3900000, 'tokens': 900000},
        ),
        thinking: 'high',
        money: 5000000,
      ),
      _full(
        potJson(
          'p-tester',
          'Tester',
          color: 2,
          intro: 'Testing',
          status: 'working',
          budgetLeft: {'tokens': 1200000},
        ),
        provider: 'openai',
        model: 'gpt-5',
        auto: true,
        money: null,
      ),
      _full(
        potJson(
          'p-travel',
          'Travel buddy',
          color: 4,
          intro: 'Travel',
          state: 'paused',
          status: 'unavailable',
          budgetLeft: {'moneyMicros': 2600000, 'tokens': 500000},
        ),
        model: 'claude-haiku',
        money: 3000000,
      ),
      _full(
        potJson('p-old', 'Translator', color: 5, state: 'archived'),
        revision: 3,
        updatedAt: DateTime(2026, 10, 30, 18).millisecondsSinceEpoch,
      ),
    ];
  }

  Map<String, Object?> settings = {
    'capMoneyMonthMicros': 50000000,
    'capTokensDay': 5000000,
    'onExhausted': 'ask',
    'activityRetentionDays': 90,
    'countSubscriptionMoney': false,
    'loopDepth': 4,
    'loopFanout': 4,
    'loopNoProgressWakes': 12,
    'loopNoProgressMessages': 30,
    'loopPairMessagesMinute': 12,
    'loopPairMessagesHour': 120,
    'loopRootWakesMinute': 20,
    'handbackCooldownS': 3600,
    'revision': 4,
  };

  /// This month: $12.40 billed and $2.00 of subscriptions at API prices.
  int billedMicros = 12400000;
  int subscriptionMicros = 2000000;
  int tokensToday = 1600000;

  /// The next settings PATCH is answered 409 after another device saved.
  bool conflictNext = false;

  /// The next restore is answered 409.
  bool restoreConflict = false;

  static Map<String, Object?> _row(
    String actorKind, {
    int billed = 0,
    int subscription = 0,
    int tokens = 0,
  }) => {
    'actorKind': actorKind,
    'billedMicros': billed,
    'subscriptionApiEquivalentMicros': subscription,
    'tokens': {'total': tokens},
  };

  @override
  FakeGateway install([FakeGateway? gateway]) {
    final g = super.install(gateway);
    g.json['GET /api/pots/settings'] = (_) => {'settings': settings};
    g.json['PATCH /api/pots/settings'] = (request) {
      final body = Map<String, Object?>.from(request.json! as Map);
      if (conflictNext) {
        conflictNext = false;
        settings = {
          ...settings,
          'revision': (settings['revision']! as int) + 1,
        };
        return apiError(409, 'revision_conflict');
      }
      if (body['revision'] != settings['revision']) {
        return apiError(409, 'revision_conflict');
      }
      settings = {...body, 'revision': (body['revision']! as int) + 1};
      return {'settings': settings};
    };
    g.json['GET /api/usage'] = (request) {
      final today = request.query['from'] == request.query['to'];
      return {
        'days': const [],
        'byActor': [
          _row('user', billed: 9000000, tokens: 4000000),
          if (today)
            _row('pot', tokens: tokensToday - 100000)
          else
            _row(
              'pot',
              billed: billedMicros - 400000,
              subscription: subscriptionMicros,
              tokens: 30000000,
            ),
          if (today)
            _row('pot', tokens: 100000)
          else
            _row('pot', billed: 400000, tokens: 1000000),
        ],
        'total': const <String, Object?>{},
        'streakDays': 1,
      };
    };
    g.json['GET /api/models'] = (_) => {
      'models': [
        {
          'provider': 'anthropic',
          'id': 'claude-sonnet',
          'name': 'Claude Sonnet',
          'reasoning': true,
          'thinkingLevels': ['low', 'medium', 'high'],
        },
        // No thinking: its rows show no level.
        {'provider': 'anthropic', 'id': 'claude-haiku', 'name': 'Claude Haiku'},
        {
          'provider': 'openai',
          'id': 'gpt-5',
          'name': 'GPT-5',
          'reasoning': true,
          'thinkingLevels': ['low', 'medium', 'high'],
        },
      ],
    };
    g.json['GET /api/pots/p-old/thread'] = (_) => {
      'thread': threadJson('t-old', pots: ['p-old'], updatedAt: at(9)),
    };
    g.json['GET /api/threads/t-old/messages'] = (_) => {
      'messages': [
        messageJson(1, 'The guide is translated.', authorId: 'p-old'),
      ],
    };
    g.json['POST /api/threads/t-old/read'] = (_) => <String, Object?>{};
    g.json['POST /api/pots/p-old/restore'] = (request) {
      final revision = (request.json! as Map)['revision'];
      if (restoreConflict || revision != 3) {
        return apiError(409, 'revision_conflict');
      }
      final i = pots.indexWhere((pot) => pot['id'] == 'p-old');
      pots[i] = {...pots[i], 'state': 'paused', 'revision': 4};
      return {'pot': pots[i]};
    };
    return g;
  }
}

Future<(FakeGateway, ProviderContainer)> _pump(
  WidgetTester tester,
  PotsSettingsFixture fixture, {
  String location = _page,
  double width = 375,
  double height = 1600,
}) async {
  final gateway = fixture.install();
  final container = await pumpApp(
    tester,
    gateway: gateway,
    width: width,
    height: height,
    location: location,
    overrides: [clockProvider.overrideWithValue(() => fixedNow)],
    reduceMotion: true,
  );
  return (gateway, container);
}

Uri _location(ProviderContainer container) =>
    container.read(routerProvider).routeInformationProvider.value.uri;

Future<void> _tap(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

Future<void> _tapKey(WidgetTester tester, String key) =>
    _tap(tester, find.byKey(ValueKey(key)));

Map<String, Object?> _patched(FakeGateway gateway) =>
    Map.from(gateway.sent('PATCH', '/api/pots/settings').last.json! as Map);

Finder _inRow(String key, String text) => find.descendant(
  of: find.byKey(ValueKey(key)),
  matching: find.textContaining(text),
);

void main() {
  appTest('the totals, the limits, the pots and the archived pots', (
    tester,
  ) async {
    final (gateway, _) = await _pump(tester, PotsSettingsFixture());
    expect(find.text('Pots'), findsOneWidget);
    expect(find.text('Tap one to open its settings'), findsOneWidget);
    // This month's money and today's tokens of the pot rows only, in the
    // Gateway's windows (no tz).
    final reads = gateway.sent('GET', '/api/usage').toList();
    expect(
      [for (final r in reads) r.query],
      containsAll([
        {'from': '2026-11-01', 'to': '2026-11-25'},
        {'from': '2026-11-25', 'to': '2026-11-25'},
      ]),
    );
    expect(_inRow('pots-total-month', r'$12.40 / $50'), findsOneWidget);
    expect(_inRow('pots-total-today', '1.6M / 5M'), findsOneWidget);
    expect(_inRow('pots-caps', r'$50/month · 5M/day'), findsOneWidget);
    expect(_inRow('pots-exhausted', 'Stop and tell you'), findsOneWidget);
    expect(_inRow('pots-retention', '90 days'), findsOneWidget);
    expect(find.text('4 pots'), findsOneWidget);
    expect(
      _inRow(
        'pots-row-p-butler',
        r'Claude Sonnet · Medium (auto) · This month $4.20 / $20',
      ),
      findsOneWidget,
    );
    expect(
      _inRow('pots-row-p-research', r'Claude Sonnet · High · This month'),
      findsOneWidget,
    );
    expect(
      _inRow(
        'pots-row-p-tester',
        'GPT-5 · Medium (auto) · Today 0.8M / 2M tokens',
      ),
      findsOneWidget,
    );
    expect(
      _inRow(
        'pots-row-p-travel',
        r'Paused · Claude Haiku · This month $0.40 / $3',
      ),
      findsOneWidget,
    );
    // The archived pot is listed on its own, not with the others.
    expect(find.byKey(const ValueKey('pots-row-p-old')), findsNothing);
    expect(_inRow('pots-archived-p-old', 'Archived 10/30'), findsOneWidget);
    expect(find.byKey(const ValueKey('pots-restore-p-old')), findsOneWidget);
  });

  appTest('a cap of 0 is no limit', (tester) async {
    final fixture = PotsSettingsFixture();
    fixture.settings = {
      ...fixture.settings,
      'capMoneyMonthMicros': 0,
      'capTokensDay': 0,
    };
    await _pump(tester, fixture);
    expect(_inRow('pots-caps', 'No limit'), findsOneWidget);
    expect(_inRow('pots-total-month', r'$12.40 · no limit'), findsOneWidget);
    expect(_inRow('pots-total-today', '1.6M · no limit'), findsOneWidget);
  });

  appTest('the caps are sent as micro-dollars and tokens with the revision, '
      'keeping every other field', (tester) async {
    final (gateway, _) = await _pump(tester, PotsSettingsFixture());
    await _tapKey(tester, 'pots-caps');
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('pots-cap-money')))
          .controller!
          .text,
      '50',
    );
    await tester.enterText(find.byKey(const ValueKey('pots-cap-money')), 'x');
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('pots-limits-problem')), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(find.byKey(const ValueKey('pots-limits-save')))
          .onPressed,
      isNull,
    );
    await tester.enterText(find.byKey(const ValueKey('pots-cap-money')), '60');
    await tester.enterText(
      find.byKey(const ValueKey('pots-cap-tokens')),
      '3,000,000',
    );
    await tester.pumpAndSettle();
    await _tapKey(tester, 'pots-limits-save');
    final body = _patched(gateway);
    expect(body['capMoneyMonthMicros'], 60000000);
    expect(body['capTokensDay'], 3000000);
    expect(body['revision'], 4);
    expect(body['onExhausted'], 'ask');
    expect(body['activityRetentionDays'], 90);
    expect(body['loopDepth'], 4);
    expect(body['loopPairMessagesHour'], 120);
    expect(body['handbackCooldownS'], 3600);
    // The sheet closes and the row shows what was saved.
    expect(find.byKey(const ValueKey('pots-cap-money')), findsNothing);
    expect(_inRow('pots-caps', r'$60/month · 3M/day'), findsOneWidget);
    // An empty field is 0: no cap.
    await _tapKey(tester, 'pots-caps');
    await tester.enterText(find.byKey(const ValueKey('pots-cap-money')), '');
    await tester.pumpAndSettle();
    await _tapKey(tester, 'pots-limits-save');
    expect(_patched(gateway)['capMoneyMonthMicros'], 0);
    expect(_patched(gateway)['revision'], 5);
    expect(_inRow('pots-caps', '3M tokens/day'), findsOneWidget);
  });

  appTest('when used up: pause all or ask', (tester) async {
    final (gateway, _) = await _pump(tester, PotsSettingsFixture());
    await _tapKey(tester, 'pots-exhausted');
    expect(
      tester
          .widget<FilledButton>(find.byKey(const ValueKey('pots-limits-save')))
          .onPressed,
      isNull,
      reason: 'nothing changed yet',
    );
    await _tapKey(tester, 'pots-exhausted-pause_all');
    await _tapKey(tester, 'pots-limits-save');
    expect(_patched(gateway)['onExhausted'], 'pause_all');
    expect(_patched(gateway)['capMoneyMonthMicros'], 50000000);
    expect(_inRow('pots-exhausted', 'Pause all pots'), findsOneWidget);
    await _tapKey(tester, 'pots-exhausted');
    await _tapKey(tester, 'pots-exhausted-ask');
    await _tapKey(tester, 'pots-limits-save');
    expect(_patched(gateway)['onExhausted'], 'ask');
  });

  appTest('activity retention takes 1 to 3650 days', (tester) async {
    final (gateway, _) = await _pump(tester, PotsSettingsFixture());
    await _tapKey(tester, 'pots-retention');
    final field = find.byKey(const ValueKey('pots-retention-days'));
    final save = find.byKey(const ValueKey('pots-limits-save'));
    for (final wrong in ['0', '3651', '']) {
      await tester.enterText(field, wrong);
      await tester.pumpAndSettle();
      expect(
        find.text('Enter a number of days from 1 to 3650.'),
        findsOneWidget,
        reason: wrong,
      );
      expect(tester.widget<FilledButton>(save).onPressed, isNull);
    }
    await tester.enterText(field, '3650');
    await tester.pumpAndSettle();
    await _tapKey(tester, 'pots-limits-save');
    expect(gateway.sent('PATCH', '/api/pots/settings'), hasLength(1));
    expect(_patched(gateway)['activityRetentionDays'], 3650);
    expect(_inRow('pots-retention', '3650 days'), findsOneWidget);
  });

  appTest('"Show API-equivalent price" counts subscription money', (
    tester,
  ) async {
    final (gateway, _) = await _pump(tester, PotsSettingsFixture());
    expect(_inRow('pots-total-month', r'$12.40 / $50'), findsOneWidget);
    await _tap(
      tester,
      find.descendant(
        of: find.byKey(const ValueKey('pots-api-equivalent')),
        matching: find.bySemanticsLabel('Show API-equivalent price'),
      ),
    );
    final body = _patched(gateway);
    expect(body['countSubscriptionMoney'], isTrue);
    expect(body['revision'], 4);
    expect(body['capMoneyMonthMicros'], 50000000);
    expect(body['loopNoProgressWakes'], 12);
    expect(_inRow('pots-total-month', r'$14.40 / $50'), findsOneWidget);
  });

  appTest('a 409 reads the settings again and keeps the edit', (tester) async {
    final fixture = PotsSettingsFixture()..conflictNext = true;
    final (gateway, _) = await _pump(tester, fixture);
    await _tapKey(tester, 'pots-retention');
    await tester.enterText(
      find.byKey(const ValueKey('pots-retention-days')),
      '30',
    );
    await tester.pumpAndSettle();
    await _tapKey(tester, 'pots-limits-save');
    expect(find.byKey(const ValueKey('pots-limits-conflict')), findsOneWidget);
    expect(find.text('30'), findsOneWidget, reason: 'the edit is kept');
    await _tapKey(tester, 'pots-limits-save');
    expect(gateway.sent('PATCH', '/api/pots/settings'), hasLength(2));
    expect(_patched(gateway)['revision'], 5);
    expect(_patched(gateway)['activityRetentionDays'], 30);
    expect(_inRow('pots-retention', '30 days'), findsOneWidget);
  });

  appTest('the settings are read again on pots_changed', (tester) async {
    final fixture = PotsSettingsFixture();
    final (gateway, _) = await _pump(tester, fixture);
    fixture.settings = {...fixture.settings, 'activityRetentionDays': 7};
    gateway.socket('/api/hints')!.push({'type': 'pots_changed'});
    await tester.pumpAndSettle();
    expect(_inRow('pots-retention', '7 days'), findsOneWidget);
  });

  appTest('a pot opens its settings; ＋ opens New pot', (tester) async {
    final (_, container) = await _pump(tester, PotsSettingsFixture());
    await _tapKey(tester, 'pots-row-p-research');
    expect(_location(container).queryParameters['open'], 'settings:p-research');
    container.read(routerProvider).go(_page);
    await tester.pumpAndSettle();
    await _tapKey(tester, 'pots-new');
    expect(_location(container).queryParameters['open'], 'new-pot');
  });

  appTest('an archived pot opens its old conversation read-only', (
    tester,
  ) async {
    final (_, container) = await _pump(tester, PotsSettingsFixture());
    await _tapKey(tester, 'pots-archived-p-old');
    expect(_location(container).path, '/chat');
    expect(_location(container).queryParameters['open'], 'pot:p-old');
    expect(find.text('The guide is translated.'), findsOneWidget);
    expect(find.byKey(const ValueKey('thread-read-only')), findsOneWidget);
    expect(
      find.text('Translator is archived. This conversation is read-only.'),
      findsOneWidget,
    );
  });

  appTest('Restore asks first, then restores with the revision', (
    tester,
  ) async {
    final (gateway, _) = await _pump(tester, PotsSettingsFixture());
    await _tapKey(tester, 'pots-restore-p-old');
    expect(find.text('Restore Translator?'), findsOneWidget);
    await _tap(tester, find.text('Cancel'));
    expect(gateway.sent('POST', '/api/pots/p-old/restore'), isEmpty);
    await _tapKey(tester, 'pots-restore-p-old');
    await _tapKey(tester, 'pots-restore-confirm');
    final sent = gateway.sent('POST', '/api/pots/p-old/restore');
    expect(sent, hasLength(1));
    expect(sent.single.json, {'revision': 3});
    // Read again: it is listed with the pots, paused.
    expect(find.byKey(const ValueKey('pots-archived-p-old')), findsNothing);
    expect(find.text('5 pots'), findsOneWidget);
    expect(_inRow('pots-row-p-old', 'Paused'), findsOneWidget);
  });

  appTest('a refused restore says so', (tester) async {
    final fixture = PotsSettingsFixture()..restoreConflict = true;
    await _pump(tester, fixture);
    await _tapKey(tester, 'pots-restore-p-old');
    await _tapKey(tester, 'pots-restore-confirm');
    expect(
      find.text('Translator changed elsewhere and was read again. Try again.'),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('pots-archived-p-old')), findsOneWidget);
  });

  appTest('the settings row counts the pots and this month\'s money', (
    tester,
  ) async {
    final (_, container) = await _pump(
      tester,
      PotsSettingsFixture(),
      location: '/settings',
      width: 1300,
      height: 900,
    );
    expect(find.text(r'4 pots · this month $12.40 / $50'), findsOneWidget);
    await _tap(tester, find.text('Pots'));
    expect(find.text('Tap one to open its settings'), findsOneWidget);
    // Back returns to Settings.
    await _tap(tester, find.byTooltip('Back'));
    expect(find.text('Tap one to open its settings'), findsNothing);
    expect(find.text(r'4 pots · this month $12.40 / $50'), findsOneWidget);
    expect(_location(container).path, '/settings');
  });

  group('golden images', () {
    for (final mode in [ThemeMode.light, ThemeMode.dark]) {
      testWidgets('settings_pots 375 ${mode.name}', (tester) async {
        await tester.runAsync(loadGoldenFonts);
        final (_, container) = await _pump(
          tester,
          PotsSettingsFixture(),
          height: 812,
        );
        container.read(themeModeProvider.notifier).select(mode);
        await tester.pumpAndSettle();
        await expectLater(
          find.byType(MaterialApp),
          matchesGoldenFile('goldens/settings_pots_375_${mode.name}.png'),
        );
        await disposeApp(tester);
      }, tags: ['golden']);
    }
  });
}
