import 'package:pirc_client/pirc_client.dart';

import 'chat_fixtures.dart';
import 'harness.dart';
import 'work_fixtures.dart';

/// E28–E31: the user's profile, their usage and the pots' names.
///
/// [days] are the tokens of each day by `YYYY-MM-DD` (each with one
/// request); [MeFixture.e28] fills 40 weeks the way E28 looks.
class MeFixture extends ChatFixture {
  MeFixture({Map<String, int>? days}) : days = days ?? _simpleDays;

  /// A few days: 5.3M tokens in all, the busiest day 2.5M (Nov 24), a
  /// current streak of 3 days and a longest one of 6 (Nov 10–15).
  static final _simpleDays = <String, int>{
    '2026-11-25': 1000000,
    '2026-11-24': 2500000,
    '2026-11-23': 500000,
    '2026-11-21': 100000,
    for (var d = 10; d <= 15; d++) '2026-11-$d': 200000,
  };

  /// E28's look: use rising over the months, with quiet days, ending in a
  /// five-day streak.
  factory MeFixture.e28() {
    var seed = 7;
    double rnd() {
      seed = (seed * 9301 + 49297) % 233280;
      return seed / 233280;
    }

    // As the prototype draws it: quiet until a third of the phone's 18
    // weeks, then rising; weekends quieter. Weeks before those 18 (wider
    // layouts) stay as quiet as the first of them.
    final days = <String, int>{};
    final first = DateTime(2026, 2, 22);
    const phoneWeeks = 18;
    for (var i = 0; i < 40 * 7; i++) {
      final date = DateTime(first.year, first.month, first.day + i);
      if (date.isAfter(fixedNow)) break;
      final week = i ~/ 7 - (40 - phoneWeeks);
      final ramp = ((week - phoneWeeks * 0.35) / (phoneWeeks * 0.65)).clamp(
        0.0,
        1.0,
      );
      final weekend =
          date.weekday == DateTime.saturday || date.weekday == DateTime.sunday;
      final x = rnd() * 0.6 + ramp * 0.9 - (weekend ? 0.25 : 0);
      final level = x < 0.35
          ? 0
          : x < 0.6
          ? 1
          : x < 0.8
          ? 2
          : x < 1.0
          ? 3
          : 4;
      final recent = fixedNow.difference(date).inDays;
      // A five-day streak up to today.
      final used = recent < 5 ? true : recent > 5 && level > 0;
      if (!used) continue;
      days[UsageApi.day(
        date,
      )] = ([0.8, 0.8, 2.6, 5.1, 9.4][level] * 10000000 * (0.8 + rnd() * 0.4))
          .round();
    }
    return MeFixture(days: days)
      ..profile = {'displayName': 'coffeecat', 'avatarColor': 4, 'revision': 2};
  }

  Map<String, int> days;

  Map<String, Object?> profile = {
    'displayName': 'Ice Bear',
    'avatarColor': 4,
    'revision': 2,
  };

  /// "Show API-equivalent price".
  bool apiEquivalent = false;

  /// The next PATCH /api/me is answered 409 after another device saved.
  bool conflictNext = false;

  final patches = <Map<String, Object?>>[];
  final uploads = <ApiRequest>[];

  static Map<String, Object?> _row(
    int tokens, {
    int billed = 0,
    int subscription = 0,
    Map<String, Object?> keys = const {},
  }) => {
    ...keys,
    'requests': tokens > 0 ? 1 : 0,
    'tokens': {'total': tokens},
    'billedMicros': billed,
    'subscriptionApiEquivalentMicros': subscription,
  };

  Map<String, Object?> _report(DateTime from, DateTime to) {
    final rows = [
      for (
        var d = from;
        !d.isAfter(to);
        d = DateTime(d.year, d.month, d.day + 1)
      )
        _row(days[UsageApi.day(d)] ?? 0, keys: {'date': UsageApi.day(d)}),
    ];
    var streak = 0;
    for (final row in rows.reversed) {
      if (row['requests'] == 0) break;
      streak++;
    }
    final month = from.day == 1 && from.month == to.month;
    return {
      'days': rows,
      'byActor': month
          ? [
              _row(400000000, keys: {'actorKind': 'user'}),
              _row(10000000, keys: {'actorKind': 'schedule'}),
              _row(
                160000000,
                keys: {'actorKind': 'pot', 'actorId': 'p-butler'},
              ),
              _row(
                110000000,
                keys: {'actorKind': 'pot', 'actorId': 'p-tester'},
              ),
              _row(
                50000000,
                keys: {'actorKind': 'pot', 'actorId': 'p-research'},
              ),
              _row(15000000, keys: {'actorKind': 'pot', 'actorId': 'p-travel'}),
              _row(5000000, keys: {'actorKind': 'pot', 'actorId': 'p-gone'}),
            ]
          : const [],
      'byModel': month
          ? [
              for (final (provider, model, auth, tokens) in [
                ('anthropic', 'claude-sonnet', 'api_key', 400000000),
                ('anthropic', 'claude-sonnet', 'subscription', 110000000),
                ('openai', 'gpt-5', 'api_key', 130000000),
                ('anthropic', 'claude-opus', 'api_key', 70000000),
                ('ollama', 'qwen3', 'local', 45000000),
              ])
                _row(
                  tokens,
                  keys: {
                    'provider': provider,
                    'model': model,
                    'authKind': auth,
                  },
                ),
            ]
          : const [],
      'total': {
        ..._row(
          rows.fold(
            0,
            (sum, row) => sum + ((row['tokens']! as Map)['total']! as int),
          ),
          billed: month ? 38200000 : 0,
          subscription: month ? 12000000 : 0,
        ),
        'requests': rows.fold(0, (sum, row) => sum + (row['requests']! as int)),
      },
      'streakDays': streak,
    };
  }

  @override
  FakeGateway install([FakeGateway? gateway]) {
    final g = super.install(gateway);
    g.json['GET /api/me'] = (_) => {'profile': profile};
    g.json['PATCH /api/me'] = (request) {
      final body = Map<String, Object?>.from(request.json! as Map);
      patches.add(body);
      if (conflictNext) {
        conflictNext = false;
        profile = {...profile, 'revision': (profile['revision']! as int) + 1};
        return apiError(409, 'revision_conflict');
      }
      if (body['revision'] != profile['revision']) {
        return apiError(409, 'revision_conflict');
      }
      profile = {
        ...profile,
        for (final key in ['displayName', 'avatarColor', 'avatarImage'])
          if (body.containsKey(key)) key: body[key],
        'revision': (profile['revision']! as int) + 1,
      };
      return {'profile': profile};
    };
    g.json['POST /api/images'] = (request) {
      uploads.add(request);
      return {'imageId': 'img-me'};
    };
    g.json['GET /api/usage'] = (request) => _report(
      DateTime.parse(request.query['from']!),
      DateTime.parse(request.query['to']!),
    );
    g.json['GET /api/pots/settings'] = (_) => {
      'settings': {'countSubscriptionMoney': apiEquivalent, 'revision': 1},
    };
    g.json['GET /api/models'] = (_) => {
      'models': [
        {
          'provider': 'anthropic',
          'id': 'claude-sonnet',
          'name': 'Claude Sonnet',
        },
        {'provider': 'anthropic', 'id': 'claude-opus', 'name': 'Claude Opus'},
        {'provider': 'openai', 'id': 'gpt-5', 'name': 'GPT-5'},
        {'provider': 'ollama', 'id': 'qwen3', 'name': 'Ollama · qwen3'},
      ],
    };
    return g;
  }
}
