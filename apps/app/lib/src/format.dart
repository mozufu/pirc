import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../l10n/app_localizations.dart';

/// The current time; tests fix it.
final clockProvider = Provider<DateTime Function()>((ref) => DateTime.now);

/// List time: the time today, "Yesterday", the weekday within a week, else
/// the date.
String listTime(BuildContext context, int millis, {DateTime? now}) {
  if (millis <= 0) return '';
  final locale = Localizations.localeOf(context).toLanguageTag();
  final time = DateTime.fromMillisecondsSinceEpoch(millis);
  final today = DateUtils.dateOnly(now ?? DateTime.now());
  final day = DateUtils.dateOnly(time);
  final days = today.difference(day).inDays;
  if (days <= 0) return DateFormat.Hm(locale).format(time);
  if (days == 1) return AppLocalizations.of(context).yesterday;
  if (days < 7) return DateFormat.E(locale).format(time);
  return DateFormat.Md(locale).format(time);
}

/// A clock time with the date when it is not today.
String clockTime(BuildContext context, int millis, {DateTime? now}) {
  final locale = Localizations.localeOf(context).toLanguageTag();
  final time = DateTime.fromMillisecondsSinceEpoch(millis);
  final today = DateUtils.dateOnly(now ?? DateTime.now());
  return DateUtils.isSameDay(time, today)
      ? DateFormat.Hm(locale).format(time)
      : DateFormat.MMMd(locale).add_Hm().format(time);
}
