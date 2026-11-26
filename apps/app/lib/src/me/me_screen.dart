import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:pirc_client/pirc_client.dart';
import 'package:pirc_ui/pirc_ui.dart';

import '../../l10n/app_localizations.dart';
import '../chat/chat_data.dart';
import '../chat/chat_list_screen.dart';
import '../chat/handover_parts.dart';
import '../chat/new_pot_screen.dart';
import '../chat/pot_form.dart';
import '../connection/connection.dart';
import '../connection/data.dart';
import '../format.dart';
import '../settings/pots_page.dart';
import '../work/composer/model_sheet.dart';
import '../work/work_data.dart';
import 'me_data.dart';

/// The You page's location, opened from the drawer's user row.
const meLocation = '/me';

/// The user as the app shows them: the profile once read, else the
/// account name with the neutral avatar.
({String name, int? color, String? image}) watchMe(WidgetRef ref) {
  final me = ref.watch(meProvider).value;
  final account =
      ref.watch(connectionProvider.select((s) => s.connection?.account)) ?? '';
  if (me == null) return (name: account, color: null, image: null);
  return (
    name: me.displayName.isEmpty ? account : me.displayName,
    color: me.avatarColor,
    image: me.avatarImage,
  );
}

/// The user's avatar: their colour and picture, or the neutral `me` fill
/// until the profile is read.
class MeAvatar extends ConsumerWidget {
  const MeAvatar({
    super.key,
    this.size = AvatarSize.md,
    this.color,
    this.image,
    this.picture,
    this.name,
  });

  final AvatarSize size;

  /// Overrides for the edit sheet's preview.
  final int? color;
  final String? image;
  final ImageProvider? picture;
  final String? name;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final me = watchMe(ref);
    final color = this.color ?? me.color;
    return Avatar(
      name: name ?? me.name,
      color: color ?? 1,
      me: color == null,
      size: size,
      image: picture ?? watchAvatarImage(ref, image ?? me.image),
    );
  }
}

/// The drawer's user row (E21): the user's avatar and name, this month's
/// money and the current streak; it opens the You page.
class MeDrawerRow extends ConsumerWidget {
  const MeDrawerRow({super.key, required this.onOpen});

  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final colors = PircColorTokens.of(context);
    final me = watchMe(ref);
    final month = ref.watch(usageMonthProvider).value;
    final weeks = heatmapWeeks(MediaQuery.sizeOf(context).width);
    final streak = ref.watch(usageRangeProvider(weeks)).value?.streakDays;
    final line = [
      if (month != null) l10n.meDrawerMonth(usd(month.total.billedMicros)),
      if (streak != null && streak > 0) l10n.meDrawerStreak(streak),
    ].join(' · ');
    return Semantics(
      button: true,
      label: l10n.meOpen,
      child: InkWell(
        key: const ValueKey('drawer-me'),
        onTap: onOpen,
        borderRadius: BorderRadius.circular(10),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 60),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            child: Row(
              spacing: 10,
              children: [
                const MeAvatar(),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        me.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 15,
                          height: 22 / 15,
                          fontWeight: FontWeight.w500,
                          color: colors['text.primary'],
                        ),
                      ),
                      if (line.isNotEmpty)
                        Text(
                          line,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 13,
                            height: 18 / 13,
                            color: colors['text.muted'],
                          ),
                        ),
                    ],
                  ),
                ),
                Icon(
                  LucideIcons.chevronRight,
                  size: PircSize.iconInline,
                  color: colors['text.faint'],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

enum _Chart { day, week, total }

/// You and usage (E28–E30): the user's avatar and name, six numbers, the
/// token activity (each day as a heatmap, each week, the running total)
/// over the shown range, and this month by who and by model. "Edit" opens
/// the profile sheet (E31).
class MeScreen extends ConsumerStatefulWidget {
  const MeScreen({super.key, this.chart});

  /// The chart shown first (`day`, `week` or `total`).
  final String? chart;

  @override
  ConsumerState<MeScreen> createState() => _MeScreenState();
}

class _MeScreenState extends ConsumerState<MeScreen> {
  late _Chart _chart = _Chart.values.firstWhere(
    (c) => c.name == widget.chart,
    orElse: () => _Chart.day,
  );

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final colors = PircColorTokens.of(context);
    final width = MediaQuery.sizeOf(context).width;
    final weeks = heatmapWeeks(width);
    final me = watchMe(ref);
    final rangeValue = ref.watch(usageRangeProvider(weeks));
    final monthValue = ref.watch(usageMonthProvider);
    final range = rangeValue.value;
    final month = monthValue.value;

    final Widget body;
    if (range == null || month == null) {
      body = rangeValue.hasError || monthValue.hasError
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                spacing: 8,
                children: [
                  Text(l10n.listFailed),
                  OutlinedButton(
                    onPressed: () {
                      ref.invalidate(usageRangeProvider(weeks));
                      ref.invalidate(usageMonthProvider);
                    },
                    child: Text(l10n.retry),
                  ),
                ],
              ),
            )
          : const Center(child: CircularProgressIndicator());
    } else {
      final now = ref.watch(clockProvider)();
      final days = rangeDays(range, now, weeks);
      final columns = width >= 600 ? 3 : 2;
      final estimate =
          ref.watch(potLimitsProvider).value?.countSubscriptionMoney == true &&
              month.total.subscriptionApiEquivalentMicros > 0
          ? month.total.subscriptionApiEquivalentMicros
          : null;
      body = ListView(
        key: const ValueKey('me-scroll'),
        padding: const EdgeInsets.only(bottom: 24),
        children: [
          ProfileHeader(
            avatar: const MeAvatar(size: AvatarSize.lg),
            name: me.name,
          ),
          GroupLabel(l10n.meOverview),
          StatGrid(
            key: const ValueKey('me-stats'),
            columns: columns,
            values: _stats(context, range, month, days),
          ),
          GroupNote(l10n.meStatsNote),
          if (estimate != null)
            GroupNote(
              l10n.meEstimate(usd(estimate)),
              key: const ValueKey('me-estimate'),
            ),
          GroupLabel(l10n.meActivity),
          _Activity(
            chart: _chart,
            days: days,
            weeks: weeks,
            onChart: (chart) => setState(() => _chart = chart),
          ),
          GroupLabel(l10n.meByWho),
          _ByWho(report: month),
          GroupLabel(l10n.meByModel),
          _ByModel(report: month),
          GroupNote(l10n.meOnlyYou),
        ],
      );
    }

    return Scaffold(
      key: const ValueKey('me'),
      backgroundColor: colors['surface.grouped'],
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            PotTopBar(
              leading: IconButton(
                tooltip: l10n.back,
                color: colors['text.secondary'],
                onPressed: () =>
                    context.canPop() ? context.pop() : context.go('/chat'),
                icon: const Icon(
                  LucideIcons.chevronLeft,
                  size: PircSize.iconBar,
                ),
              ),
              trailing: TextButton(
                key: const ValueKey('me-edit'),
                style: TextButton.styleFrom(
                  foregroundColor: colors['text.primary'],
                  minimumSize: const Size(0, 36),
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  textStyle: Theme.of(context).textTheme.labelLarge?.copyWith(
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                onPressed: ref.watch(meProvider).value == null
                    ? null
                    : () => showEditProfileSheet(context),
                child: Text(l10n.meEdit),
              ),
            ),
            Expanded(
              child: Align(
                alignment: Alignment.topCenter,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 720),
                  child: body,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// The six numbers (E28) over the shown range; money and requests are
  /// this month's. E28's "longest work" is "requests this month": the
  /// overview is built from `GET /api/usage` alone (usage.md), which has no
  /// work durations.
  List<StatValue> _stats(
    BuildContext context,
    UsageReport range,
    UsageReport month,
    List<UsageDay> days,
  ) {
    final l10n = AppLocalizations.of(context);
    final top = days.fold(
      0,
      (best, day) => (day.tokens ?? 0) > best ? day.tokens! : best,
    );
    return [
      StatValue(bigCount(context, range.total.tokens.total), l10n.meStatTotal),
      StatValue(bigCount(context, top), l10n.meStatTopDay),
      StatValue(usd(month.total.billedMicros), l10n.meStatSpent),
      StatValue(grouped(context, month.total.requests), l10n.meStatRequests),
      StatValue(l10n.meDays(longestStreak(days)), l10n.meStatLongestStreak),
      StatValue(l10n.meDays(range.streakDays), l10n.meStatStreak),
    ];
  }
}

/// The token activity card: the heatmap (each day), 12 weekly bars or
/// the running total.
class _Activity extends StatelessWidget {
  const _Activity({
    required this.chart,
    required this.days,
    required this.weeks,
    required this.onChart,
  });

  final _Chart chart;
  final List<UsageDay> days;
  final int weeks;
  final ValueChanged<_Chart> onChart;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final top = days.fold(
      0,
      (best, day) => (day.tokens ?? 0) > best ? day.tokens! : best,
    );
    final Widget child;
    switch (chart) {
      case _Chart.day:
        child = Heatmap(
          key: const ValueKey('me-heatmap'),
          levels: [for (final day in days) heatLevel(day.tokens, top)],
          tips: [for (final day in days) dayTip(context, day)],
          monthLabels: monthLabels(context, days),
          lessLabel: l10n.meLess,
          moreLabel: l10n.meMore,
          semanticLabel: l10n.meHeatmapLabel(weeks),
        );
      case _Chart.week:
        final totals = weeklyTokens(days);
        final last = totals.sublist(totals.length - 12);
        child = WeeklyBars(
          key: const ValueKey('me-weeks'),
          values: [for (final week in last) week.toDouble()],
          labels: [
            l10n.meTwelveWeeksAgo,
            l10n.meThisWeek(bigCount(context, last.last)),
          ],
          semanticLabel: l10n.meWeeksLabel,
        );
      case _Chart.total:
        final totals = runningTotals(days);
        final labels = monthLabels(context, days);
        child = CumulativeArea(
          key: const ValueKey('me-total'),
          totals: [for (final total in totals) total.toDouble()],
          labels: [
            if (labels.isNotEmpty) labels.first,
            l10n.meNow(bigCount(context, totals.isEmpty ? 0 : totals.last)),
          ],
          semanticLabel: l10n.meTotalLabel,
        );
    }
    return StatCard(
      title: switch (chart) {
        _Chart.day => l10n.meDaily,
        _Chart.week => l10n.meWeekly,
        _Chart.total => l10n.meCumulative,
      },
      tabs: [l10n.meTabDay, l10n.meTabWeek, l10n.meTabTotal],
      selectedTab: chart.index,
      onTab: (i) => onChart(_Chart.values[i]),
      child: child,
    );
  }
}

/// This month by who: the user, then the pots, by tokens.
class _ByWho extends ConsumerWidget {
  const _ByWho({required this.report});
  final UsageReport report;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final pots = ref.watch(potsProvider).value ?? const <PotSummary>[];
    final me = watchMe(ref);
    final rows = tokensByWho(report);
    if (rows.isEmpty) return GroupNote(l10n.meNothingThisMonth);
    final top = rows.first.tokens;
    return StatCard(
      key: const ValueKey('me-by-who'),
      child: BarList(
        items: [
          for (final row in rows)
            () {
              final pot = row.potId == null
                  ? null
                  : pots.where((p) => p.id == row.potId).firstOrNull;
              return BarListItem(
                leading: row.potId == null
                    ? const MeAvatar(size: AvatarSize.sm)
                    : pot != null
                    ? PotAvatar(pot: pot, size: AvatarSize.sm)
                    : Avatar(name: '?', size: AvatarSize.sm, me: true),
                name: row.potId == null
                    ? l10n.meYou(me.name)
                    : pot?.name ?? l10n.meDeletedPot,
                value: bigCount(context, row.tokens),
                fraction: top <= 0 ? 0 : row.tokens / top,
              );
            }(),
        ],
      ),
    );
  }
}

/// This month by model: each model's share of the tokens.
class _ByModel extends ConsumerWidget {
  const _ByModel({required this.report});
  final UsageReport report;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final models = ref.watch(modelsProvider).value ?? const <ModelInfo>[];
    final rows = tokensByModel(report);
    if (rows.isEmpty) return GroupNote(l10n.meNothingThisMonth);
    final all = rows.fold(0, (sum, row) => sum + row.tokens);
    final top = rows.first.tokens;
    return StatCard(
      key: const ValueKey('me-by-model'),
      child: BarList(
        items: [
          for (final row in rows)
            () {
              final name =
                  currentModel(models, row.provider, row.model)?.name ??
                  row.model;
              return BarListItem(
                leading: BarListMark(modelMark(name)),
                name: name,
                value: '${(100 * row.tokens / all).round()}%',
                fraction: top <= 0 ? 0 : row.tokens / top,
              );
            }(),
        ],
      ),
    );
  }
}

/// Edit profile (E31): the colour or a picture, and the name.
Future<void> showEditProfileSheet(BuildContext context) {
  final start = ProviderScope.containerOf(context).read(meProvider).value;
  if (start == null) return Future.value();
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    backgroundColor: PircColorTokens.of(context)['surface.layer'],
    builder: (context) => SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(context).height * 0.86,
          ),
          child: _EditProfileSheet(start: start),
        ),
      ),
    ),
  );
}

class _EditProfileSheet extends ConsumerStatefulWidget {
  const _EditProfileSheet({required this.start});
  final UserProfile start;

  @override
  ConsumerState<_EditProfileSheet> createState() => _EditProfileSheetState();
}

class _EditProfileSheetState extends ConsumerState<_EditProfileSheet> {
  UserProfile get start => widget.start;

  late final _name = TextEditingController(text: start.displayName);
  late int _color = start.avatarColor;
  late String? _image = start.avatarImage;
  Uint8List? _bytes;

  /// The revision the next save sends: the profile's when the sheet
  /// opened, or after a 409 the one read again.
  late int _revision = start.revision;
  bool _busy = false;
  bool _conflict = false;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  /// The name as the Gateway counts it: trimmed, 1–60 characters, no
  /// control characters.
  bool get _nameOk {
    final name = _name.text.trim();
    final length = name.runes.length;
    return length >= 1 &&
        length <= 60 &&
        !name.runes.any((r) => r < 0x20 || (r >= 0x7f && r < 0xa0));
  }

  bool get _changed =>
      _name.text.trim() != start.displayName ||
      _color != start.avatarColor ||
      _image != start.avatarImage;

  Future<void> _save() async {
    final api = ref.read(apiProvider);
    if (api == null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final me = MeApi(api);
    final name = _name.text.trim();
    try {
      await me.update(
        revision: _revision,
        displayName: name != start.displayName ? name : null,
        avatarColor: _color != start.avatarColor ? _color : null,
        avatarImage: _image != start.avatarImage ? _image : null,
        removeAvatarImage: _image == null && start.avatarImage != null,
      );
      ref.invalidate(meProvider);
      if (mounted) Navigator.pop(context);
    } on PircException catch (error) {
      if (error is ApiError && error.status == 409) {
        try {
          _revision = (await me.read()).revision;
        } on PircException {
          // The next save is answered 409 again and reads once more.
        }
        ref.invalidate(meProvider);
        if (mounted) {
          setState(() {
            _busy = false;
            _conflict = true;
          });
        }
        return;
      }
      if (mounted) {
        setState(() {
          _busy = false;
          _conflict = false;
          _error = error.message;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final colors = PircColorTokens.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
          child: Text(
            l10n.meEditTitle,
            style: Theme.of(context).textTheme.titleLarge,
          ),
        ),
        Flexible(
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (_conflict)
                  Container(
                    key: const ValueKey('me-conflict'),
                    margin: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 10,
                    ),
                    decoration: BoxDecoration(
                      color: colors['status.warningSoft'],
                      borderRadius: BorderRadius.circular(PircRadius.md),
                    ),
                    child: Text(
                      l10n.meConflict,
                      style: TextStyle(
                        fontSize: 13.5,
                        height: 20 / 13.5,
                        color: colors['text.warning'],
                      ),
                    ),
                  ),
                if (_error != null)
                  ErrorBox(_error!, key: const ValueKey('me-edit-error')),
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Center(
                    child: MeAvatar(
                      key: const ValueKey('me-edit-avatar'),
                      size: AvatarSize.lg,
                      name: _name.text.trim(),
                      color: _color,
                      image: _image,
                      picture: avatarPicture(ref, _image, _bytes),
                    ),
                  ),
                ),
                AvatarPicker(
                  color: _color,
                  image: _image,
                  bytes: _bytes,
                  note: '',
                  onColor: (color) => setState(() => _color = color),
                  onPicture: (id, bytes) => setState(() {
                    _image = id;
                    _bytes = bytes;
                  }),
                ),
                Container(
                  margin: const EdgeInsets.fromLTRB(16, 4, 16, 0),
                  decoration: BoxDecoration(
                    color: colors['surface.subtle'],
                    borderRadius: BorderRadius.circular(PircRadius.lg),
                  ),
                  child: FormInputRow(
                    label: l10n.meName,
                    field: TextField(
                      key: const ValueKey('me-edit-name'),
                      controller: _name,
                      onChanged: (_) => setState(() {}),
                      style: formFieldStyle(context, size: 15.5),
                      decoration: plainField(context, l10n.meNameHint),
                    ),
                  ),
                ),
                if (!_nameOk)
                  GroupNote(
                    l10n.meNameInvalid,
                    error: true,
                    key: const ValueKey('me-edit-problem'),
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                  ),
                GroupNote(
                  l10n.meNameNote,
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                ),
              ],
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
          child: Row(
            spacing: 8,
            children: [
              Expanded(
                child: FilledButton(
                  style: plainButtonStyle(context),
                  onPressed: () => Navigator.pop(context),
                  child: Text(l10n.cancel),
                ),
              ),
              Expanded(
                child: FilledButton(
                  key: const ValueKey('me-edit-save'),
                  style: inkButtonStyle(context),
                  onPressed: _busy || !_changed || !_nameOk ? null : _save,
                  child: Text(l10n.save),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
