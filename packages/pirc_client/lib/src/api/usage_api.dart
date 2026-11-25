import 'package:meta/meta.dart';

import '../api_client.dart';
import '../json.dart';

/// Token counts of a usage row.
@immutable
class UsageTokens {
  const UsageTokens({
    this.input = 0,
    this.output = 0,
    this.cacheRead = 0,
    this.cacheWrite = 0,
    this.total = 0,
  });

  factory UsageTokens.fromJson(Object? json) => UsageTokens(
    input: number(field(json, 'input')) ?? 0,
    output: number(field(json, 'output')) ?? 0,
    cacheRead: number(field(json, 'cacheRead')) ?? 0,
    cacheWrite: number(field(json, 'cacheWrite')) ?? 0,
    total: number(field(json, 'total')) ?? 0,
  );

  final int input;
  final int output;
  final int cacheRead;
  final int cacheWrite;
  final int total;
}

/// One row of the usage report: a day, a model, an actor, a purpose or the
/// total. Only the keys of its group are set.
@immutable
class UsageRow {
  const UsageRow({
    this.requests = 0,
    this.tokens = const UsageTokens(),
    this.billedMicros = 0,
    this.subscriptionApiEquivalentMicros = 0,
    this.subscriptionTokens = 0,
    this.date,
    this.provider,
    this.model,
    this.authKind,
    this.plan,
    this.actorKind,
    this.actorId,
    this.purpose,
  });

  factory UsageRow.fromJson(Object? json) => UsageRow(
    requests: number(field(json, 'requests')) ?? 0,
    tokens: UsageTokens.fromJson(field(json, 'tokens')),
    billedMicros: number(field(json, 'billedMicros')) ?? 0,
    subscriptionApiEquivalentMicros:
        number(field(json, 'subscriptionApiEquivalentMicros')) ?? 0,
    subscriptionTokens: number(field(json, 'subscriptionTokens')) ?? 0,
    date: str(field(json, 'date')),
    provider: str(field(json, 'provider')),
    model: str(field(json, 'model')),
    authKind: str(field(json, 'authKind')),
    plan: str(field(json, 'plan')),
    actorKind: str(field(json, 'actorKind')),
    actorId: text(field(json, 'actorId')),
    purpose: str(field(json, 'purpose')),
  );

  final int requests;
  final UsageTokens tokens;

  /// Money billed by API keys, in micro-dollars.
  final int billedMicros;

  /// What subscription use would cost at API prices. It is an estimate,
  /// never spending.
  final int subscriptionApiEquivalentMicros;
  final int subscriptionTokens;

  /// `YYYY-MM-DD` in a day row.
  final String? date;
  final String? provider;
  final String? model;

  /// How the model was paid for, in a model row.
  final String? authKind;
  final String? plan;

  /// Who used it (`user`, `pot` and so on), in an actor row.
  final String? actorKind;
  final String? actorId;
  final String? purpose;
}

/// The owner's usage over a range of days (`GET /api/usage`).
@immutable
class UsageReport {
  const UsageReport({
    this.days = const [],
    this.byModel = const [],
    this.byActor = const [],
    this.byPurpose = const [],
    this.total = const UsageRow(),
    this.streakDays = 0,
    this.pricingRevision,
    this.timezone,
  });

  factory UsageReport.fromJson(Object? json) {
    List<UsageRow> rows(String key) => [
      for (final row in array(field(json, key)) ?? const [])
        UsageRow.fromJson(row),
    ];
    return UsageReport(
      days: rows('days'),
      byModel: rows('byModel'),
      byActor: rows('byActor'),
      byPurpose: rows('byPurpose'),
      total: UsageRow.fromJson(field(json, 'total')),
      streakDays: number(field(json, 'streakDays')) ?? 0,
      pricingRevision: text(field(json, 'pricingRevision')),
      timezone: str(field(json, 'timezone')),
    );
  }

  /// One row per day of the range, oldest first.
  final List<UsageRow> days;
  final List<UsageRow> byModel;
  final List<UsageRow> byActor;
  final List<UsageRow> byPurpose;
  final UsageRow total;

  /// Days in a row with any request, ending on the last day of the range.
  final int streakDays;
  final String? pricingRevision;
  final String? timezone;
}

/// `GET /api/usage`.
class UsageApi {
  const UsageApi(this.api);
  final ApiClient api;

  /// `YYYY-MM-DD` of the date's own year, month and day.
  static String day(DateTime date) =>
      '${date.year.toString().padLeft(4, '0')}-'
      '${date.month.toString().padLeft(2, '0')}-'
      '${date.day.toString().padLeft(2, '0')}';

  /// The days [from] to [to], both included (1 to 400 days). [tz] is an
  /// IANA zone; without it the Gateway uses its own.
  Future<UsageReport> usage({
    required DateTime from,
    required DateTime to,
    String? tz,
  }) async => UsageReport.fromJson(
    await api.get(
      '/api/usage',
      query: {'from': day(from), 'to': day(to), 'tz': ?tz},
    ),
  );
}
