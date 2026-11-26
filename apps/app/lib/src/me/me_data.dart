import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:pirc_client/pirc_client.dart';

import '../../l10n/app_localizations.dart';
import '../connection/data.dart';
import '../format.dart';

/// The signed-in user's profile (`GET /api/me`). There is no hint for it:
/// it is read again after this device saves it.
final meProvider = FutureProvider<UserProfile>(
  (ref) => MeApi(requireApi(ref)).read(),
);

/// Heatmap weeks by window width (E spec § 8 and the prototypes): 18 on
/// phones, 26 and 30 on tablets (portrait, landscape), 40 on desktops.
int heatmapWeeks(double width) => width >= 1200
    ? 40
    : width >= 900
    ? 30
    : width >= 600
    ? 26
    : 18;

/// The Sunday that starts [day]'s week.
DateTime weekStart(DateTime day) =>
    DateTime(day.year, day.month, day.day - day.weekday % 7);

/// The shown range: [weeks] whole weeks (Sunday first) ending with this
/// week, read up to today.
({DateTime from, DateTime to}) usageRange(DateTime now, int weeks) {
  final start = weekStart(now);
  return (
    from: DateTime(start.year, start.month, start.day - 7 * (weeks - 1)),
    to: DateTime(now.year, now.month, now.day),
  );
}

/// The owner's usage over the shown range of [weeks] weeks. No usage hint
/// exists; it is read when the page opens.
final usageRangeProvider = FutureProvider.autoDispose.family<UsageReport, int>((
  ref,
  weeks,
) {
  final range = usageRange(ref.watch(clockProvider)(), weeks);
  return UsageApi(requireApi(ref)).usage(from: range.from, to: range.to);
});

/// The owner's usage from the 1st of this month to today: the money spent
/// and the two bar lists (a report's model and actor rows cover its whole
/// range).
final usageMonthProvider = FutureProvider.autoDispose<UsageReport>((ref) {
  final now = ref.watch(clockProvider)();
  return UsageApi(
    requireApi(ref),
  ).usage(from: DateTime(now.year, now.month), to: now);
});

/// A large count in three significant digits: en `1.24B`, `108M`, `4.1K`;
/// zh `12.4 億`, `1,080 萬`.
String bigCount(BuildContext context, int value) {
  final zh = Localizations.localeOf(context).languageCode == 'zh';
  final units = zh
      ? const [(100000000, ' 億'), (10000, ' 萬')]
      : const [(1000000000, 'B'), (1000000, 'M'), (1000, 'K')];
  for (final (size, suffix) in units) {
    if (value.abs() >= size) {
      final v = value / size;
      final digits = v.abs() >= 100
          ? 0
          : v.abs() >= 10
          ? 1
          : 2;
      var text = v.toStringAsFixed(digits);
      if (text.contains('.')) {
        text = text.replaceFirst(RegExp(r'\.?0+$'), '');
      }
      return '${zh && v.abs() >= 1000 ? grouped(context, v.round()) : text}'
          '$suffix';
    }
  }
  return grouped(context, value);
}

/// One day of the range: its date and tokens; null tokens after today.
typedef UsageDay = ({DateTime date, int? tokens, int requests});

/// Every day of the shown range's weeks, Sunday first, with the days
/// after today left empty.
List<UsageDay> rangeDays(UsageReport report, DateTime now, int weeks) {
  final range = usageRange(now, weeks);
  final byDate = {for (final day in report.days) day.date: day};
  final today = DateTime(now.year, now.month, now.day);
  return [
    for (var i = 0; i < weeks * 7; i++)
      () {
        final date = DateTime(
          range.from.year,
          range.from.month,
          range.from.day + i,
        );
        final row = byDate[UsageApi.day(date)];
        return (
          date: date,
          tokens: date.isAfter(today) ? null : row?.tokens.total ?? 0,
          requests: row?.requests ?? 0,
        );
      }(),
  ];
}

/// The heatmap level of [tokens] against the busiest day: none, then four
/// quarters.
int heatLevel(int? tokens, int top) {
  if (tokens == null || tokens <= 0 || top <= 0) return 0;
  return (4 * tokens / top).ceil().clamp(1, 4);
}

/// The longest run of days in a row with any request.
int longestStreak(List<UsageDay> days) {
  var best = 0, run = 0;
  for (final day in days) {
    if (day.tokens == null) break;
    run = day.requests > 0 ? run + 1 : 0;
    best = math.max(best, run);
  }
  return best;
}

/// The tokens of each week, oldest first.
List<int> weeklyTokens(List<UsageDay> days) => [
  for (var w = 0; w < days.length ~/ 7; w++)
    days
        .sublist(w * 7, w * 7 + 7)
        .fold(0, (sum, day) => sum + (day.tokens ?? 0)),
];

/// The running total up to today, oldest first.
List<int> runningTotals(List<UsageDay> days) {
  var sum = 0;
  return [
    for (final day in days)
      if (day.tokens != null) sum += day.tokens!,
  ];
}

/// The month names under the heatmap: each month that starts inside the
/// range.
List<String> monthLabels(BuildContext context, List<UsageDay> days) {
  final format = DateFormat.MMM(
    Localizations.localeOf(context).toLanguageTag(),
  );
  return [
    for (final (i, day) in days.indexed)
      if (day.date.day == 1 || (i == 0 && day.date.day <= 7))
        format.format(day.date),
  ];
}

/// What a heatmap cell says on hover: "Nov 24 · 1.2M tokens".
String dayTip(BuildContext context, UsageDay day) {
  final tokens = day.tokens;
  if (tokens == null) return '';
  final l10n = AppLocalizations.of(context);
  final date = DateFormat.MMMd(
    Localizations.localeOf(context).toLanguageTag(),
  ).format(day.date);
  return tokens == 0
      ? l10n.meDayTipNone(date)
      : l10n.meDayTip(date, bigCount(context, tokens));
}

/// Who used how much: the user (with their schedules and delegations)
/// or a pot, by tokens.
typedef ActorTokens = ({String? potId, int tokens});

/// [report]'s actor rows by who: the user first when present, then pots,
/// most tokens first.
List<ActorTokens> tokensByWho(UsageReport report) {
  var mine = 0;
  final pots = <String, int>{};
  for (final row in report.byActor) {
    final tokens = row.tokens.total;
    if (row.actorKind == 'pot' && row.actorId != null) {
      pots[row.actorId!] = (pots[row.actorId!] ?? 0) + tokens;
    } else if (row.actorKind != 'system') {
      mine += tokens;
    }
  }
  final list = <ActorTokens>[
    if (mine > 0) (potId: null, tokens: mine),
    for (final MapEntry(:key, :value) in pots.entries)
      if (value > 0) (potId: key, tokens: value),
  ];
  list.sort((a, b) => b.tokens.compareTo(a.tokens));
  return list;
}

/// [report]'s model rows merged by provider and model (the Gateway also
/// splits them by how they were paid), most tokens first.
List<({String provider, String model, int tokens})> tokensByModel(
  UsageReport report,
) {
  final merged = <(String, String), int>{};
  for (final row in report.byModel) {
    final key = (row.provider ?? '', row.model ?? '');
    merged[key] = (merged[key] ?? 0) + row.tokens.total;
  }
  final list = [
    for (final MapEntry(key: (provider, model), :value) in merged.entries)
      if (value > 0) (provider: provider, model: model, tokens: value),
  ];
  list.sort((a, b) => b.tokens.compareTo(a.tokens));
  return list;
}

/// A model's mark: the first letter of its name's last word (`S` for
/// Claude Sonnet, `G` for GPT-5).
String modelMark(String name) {
  final words = name.trim().split(RegExp(r'\s+'));
  final last = words.isEmpty ? '' : words.last;
  return last.isEmpty ? '?' : last.characters.first.toUpperCase();
}
