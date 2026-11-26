import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:pirc_client/pirc_client.dart';
import 'package:pirc_ui/pirc_ui.dart';

import '../../l10n/app_localizations.dart';
import '../chat/chat_data.dart';
import '../chat/chat_list_screen.dart';
import '../chat/handover_parts.dart';
import '../chat/new_pot_screen.dart';
import '../chat/pot_conversation_screen.dart';
import '../chat/pot_form.dart';
import '../connection/data.dart';
import '../connection/hints.dart';
import '../format.dart';
import '../work/composer/model_sheet.dart';
import '../work/work_data.dart';

/// The owner's limits for all pots; read again on `pots_changed` (the
/// Gateway sends it when they change).
final potLimitsProvider = FutureProvider<PotSettings>((ref) {
  watchHint(ref, 'pots_changed');
  return PotsApi(requireApi(ref)).settings();
});

/// Every pot in full, archived ones included (models, budgets and the
/// revision Restore sends); read again on `pots_changed`.
final potListProvider = FutureProvider<List<Pot>>((ref) {
  watchHint(ref, 'pots_changed');
  return PotsApi(requireApi(ref)).list();
});

/// What all pots used in the owner-wide windows (`GET /api/usage`, the
/// `pot` actor rows): this month's money and today's tokens.
@immutable
class PotTotals {
  const PotTotals({
    this.billedMicros = 0,
    this.subscriptionMicros = 0,
    this.tokensToday = 0,
  });

  /// Money billed by API keys this month.
  final int billedMicros;

  /// Subscription use this month at API prices (an estimate).
  final int subscriptionMicros;
  final int tokensToday;

  /// This month's money as the owner-wide cap counts it: subscription use
  /// only with "show API-equivalent price" (P20).
  int moneyMicros({required bool countSubscription}) =>
      billedMicros + (countSubscription ? subscriptionMicros : 0);
}

/// Two reads, because a report's actor rows cover its whole range: the
/// 1st of this month to today, and today. Without `tz` the Gateway uses
/// its own zone, as its budget windows do. Read again on `pots_changed`.
final potTotalsProvider = FutureProvider<PotTotals>((ref) async {
  watchHint(ref, 'pots_changed');
  final usage = UsageApi(requireApi(ref));
  final now = ref.watch(clockProvider)();
  final month = await usage.usage(from: DateTime(now.year, now.month), to: now);
  final today = await usage.usage(from: now, to: now);
  Iterable<UsageRow> pots(UsageReport report) =>
      report.byActor.where((row) => row.actorKind == 'pot');
  return PotTotals(
    billedMicros: pots(month).fold(0, (sum, row) => sum + row.billedMicros),
    subscriptionMicros: pots(
      month,
    ).fold(0, (sum, row) => sum + row.subscriptionApiEquivalentMicros),
    tokensToday: pots(today).fold(0, (sum, row) => sum + row.tokens.total),
  );
});

/// The settings row of pots (E22): how many there are and this month's
/// money of all of them against the owner-wide cap; null until known.
String? potsSettingsSummary(AppLocalizations l10n, WidgetRef ref) {
  final pots = ref.watch(potsProvider).value;
  if (pots == null) return null;
  final count = l10n.settingsPotsCount(
    pots.where((pot) => pot.state != 'archived').length,
  );
  final limits = ref.watch(potLimitsProvider).value;
  final totals = ref.watch(potTotalsProvider).value;
  if (limits == null || totals == null) return count;
  final used = dollars(
    totals.moneyMicros(countSubscription: limits.countSubscriptionMoney),
  );
  final month = limits.capMoneyMonthMicros > 0
      ? l10n.settingsPotsMonth(used, dollars(limits.capMoneyMonthMicros))
      : l10n.settingsPotsMonthNoCap(used);
  return '$count · $month';
}

/// Settings → pots (E23): the totals of all pots against the owner-wide
/// caps, the caps, what happens when they are used up, how long activity
/// is kept and "show API-equivalent price" (each saved with the settings
/// revision), then the pots (each opens its settings, E24) and the
/// archived pots (each opens its old conversation read-only, with
/// Restore).
class PotsSettingsPage extends ConsumerStatefulWidget {
  const PotsSettingsPage({super.key});

  @override
  ConsumerState<PotsSettingsPage> createState() => _PotsSettingsPageState();
}

class _PotsSettingsPageState extends ConsumerState<PotsSettingsPage> {
  bool _saving = false;
  String? _error;
  String? _restoreError;
  final _restoring = <String>{};

  Future<void> _setApiEquivalent(PotSettings limits, bool value) async {
    final api = ref.read(apiProvider);
    if (api == null) return;
    final l10n = AppLocalizations.of(context);
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await PotsApi(
        api,
      ).updateSettings(limits.copyWith(countSubscriptionMoney: value));
    } on PircException catch (error) {
      _error = error is ApiError && error.status == 409
          ? l10n.potsSettingsConflict
          : error.message;
    }
    ref.invalidate(potLimitsProvider);
    if (mounted) setState(() => _saving = false);
  }

  Future<void> _restore(Pot pot) async {
    final l10n = AppLocalizations.of(context);
    final yes = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.potsRestoreTitle(pot.name)),
        content: Text(l10n.potsRestoreBody(pot.name)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(l10n.cancel),
          ),
          FilledButton(
            key: const ValueKey('pots-restore-confirm'),
            onPressed: () => Navigator.pop(context, true),
            child: Text(l10n.potsRestoreConfirm),
          ),
        ],
      ),
    );
    final api = ref.read(apiProvider);
    if (yes != true || api == null || !mounted) return;
    setState(() {
      _restoring.add(pot.id);
      _restoreError = null;
    });
    try {
      await PotsApi(api).restore(pot.id, revision: pot.revision);
    } on PircException catch (error) {
      _restoreError = error is ApiError && error.status == 409
          ? l10n.potsRestoreConflict(pot.name)
          : error.message;
    }
    ref.invalidate(potListProvider);
    ref.invalidate(potsProvider);
    if (mounted) setState(() => _restoring.remove(pot.id));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final colors = PircColorTokens.of(context);
    final limitsValue = ref.watch(potLimitsProvider);
    final listValue = ref.watch(potListProvider);
    final limits = limitsValue.value;
    final list = listValue.value;

    final Widget body;
    if (limits == null || list == null) {
      final failed = limitsValue.hasError || listValue.hasError;
      body = failed
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                spacing: 8,
                children: [
                  Text(l10n.listFailed),
                  OutlinedButton(
                    onPressed: () {
                      ref.invalidate(potLimitsProvider);
                      ref.invalidate(potListProvider);
                    },
                    child: Text(l10n.retry),
                  ),
                ],
              ),
            )
          : const Center(child: CircularProgressIndicator());
    } else {
      final active = [
        for (final pot in list)
          if (pot.state != 'archived') pot,
      ];
      final archived = [
        for (final pot in list)
          if (pot.state == 'archived') pot,
      ];
      body = ListView(
        key: const ValueKey('pots-settings-scroll'),
        padding: const EdgeInsets.only(bottom: 24),
        children: [
          GroupLabel(l10n.potsTotals),
          _Totals(limits: limits),
          const SizedBox(height: 8),
          GroupedList(
            children: [
              _ValueRow(
                key: const ValueKey('pots-caps'),
                title: l10n.potsCaps,
                value: capsText(context, limits),
                onTap: () => _showLimitsSheet(
                  context,
                  (start) => _CapsSheet(start: start),
                ),
              ),
              _ValueRow(
                key: const ValueKey('pots-exhausted'),
                title: l10n.potsExhausted,
                value: limits.onExhausted == 'pause_all'
                    ? l10n.potsExhaustedPause
                    : l10n.potsExhaustedAsk,
                onTap: () => _showLimitsSheet(
                  context,
                  (start) => _ExhaustedSheet(start: start),
                ),
              ),
              _ValueRow(
                key: const ValueKey('pots-retention'),
                title: l10n.potsRetention,
                value: l10n.potsRetentionDays(limits.activityRetentionDays),
                onTap: () => _showLimitsSheet(
                  context,
                  (start) => _RetentionSheet(start: start),
                ),
              ),
              GroupedRow(
                key: const ValueKey('pots-api-equivalent'),
                title: l10n.potsApiEquivalent,
                subtitle: l10n.potsApiEquivalentDetail,
                wrapSubtitle: true,
                trailing: PircSwitch(
                  value: limits.countSubscriptionMoney,
                  semanticLabel: l10n.potsApiEquivalent,
                  onChanged: _saving
                      ? null
                      : (value) => _setApiEquivalent(limits, value),
                ),
              ),
            ],
          ),
          if (_error != null)
            GroupNote(_error!, error: true, key: const ValueKey('pots-error')),
          GroupNote(l10n.potsCapsNote),
          GroupLabel(l10n.settingsPotsCount(active.length)),
          if (active.isEmpty)
            GroupNote(l10n.potsNone)
          else
            GroupedList(
              children: [
                for (final pot in active)
                  GroupedRow(
                    key: ValueKey('pots-row-${pot.id}'),
                    leading: PotAvatar(
                      pot: _summary(pot),
                      size: AvatarSize.md,
                      withStatus: true,
                      ring: colors['surface.grouped'],
                    ),
                    titleWidget: _NameLine(
                      name: pot.name,
                      intro: pot.work.intro,
                    ),
                    subtitle: _potLine(context, ref, pot),
                    trailing: const _Chevron(),
                    onTap: () => context.go(potSettingsLocation(pot.id)),
                  ),
              ],
            ),
          if (archived.isNotEmpty) ...[
            GroupLabel(l10n.potsArchived),
            GroupedList(
              children: [
                for (final pot in archived)
                  GroupedRow(
                    key: ValueKey('pots-archived-${pot.id}'),
                    leading: PotAvatar(pot: _summary(pot), size: AvatarSize.md),
                    title: pot.name,
                    subtitle: pot.updatedAt > 0
                        ? l10n.potsArchivedOn(
                            DateFormat.Md(
                              Localizations.localeOf(context).toLanguageTag(),
                            ).format(
                              DateTime.fromMillisecondsSinceEpoch(
                                pot.updatedAt,
                              ),
                            ),
                          )
                        : l10n.potsArchived,
                    trailing: FilledButton(
                      key: ValueKey('pots-restore-${pot.id}'),
                      style: plainButtonStyle(context).copyWith(
                        minimumSize: const WidgetStatePropertyAll(Size(0, 36)),
                        padding: const WidgetStatePropertyAll(
                          EdgeInsets.symmetric(horizontal: 14),
                        ),
                        textStyle: WidgetStatePropertyAll(
                          Theme.of(context).textTheme.labelLarge?.copyWith(
                            fontSize: 14,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                      onPressed: _restoring.contains(pot.id)
                          ? null
                          : () => _restore(pot),
                      child: Text(l10n.potsRestore),
                    ),
                    onTap: () => context.go(chatLocation(potChatKey(pot.id))),
                  ),
              ],
            ),
            if (_restoreError != null)
              GroupNote(
                _restoreError!,
                error: true,
                key: const ValueKey('pots-restore-error'),
              ),
          ],
        ],
      );
    }

    return Scaffold(
      key: const ValueKey('pots-settings'),
      backgroundColor: colors['surface.grouped'],
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            PotTopBar(
              title: l10n.settingsPots,
              subtitle: l10n.potsPageSubtitle,
              leading: IconButton(
                tooltip: l10n.back,
                color: colors['text.secondary'],
                onPressed: () =>
                    context.canPop() ? context.pop() : context.go('/settings'),
                icon: const Icon(
                  LucideIcons.chevronLeft,
                  size: PircSize.iconBar,
                ),
              ),
              trailing: IconButton(
                key: const ValueKey('pots-new'),
                tooltip: l10n.newPotTitle,
                color: colors['text.primary'],
                onPressed: () => context.go(chatLocation(newPotKey)),
                icon: const Icon(LucideIcons.userPlus, size: PircSize.iconBar),
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
}

PotSummary _summary(Pot pot) => PotSummary(
  id: pot.id,
  name: pot.name,
  state: pot.state,
  avatarColor: pot.profile.avatarColor,
  avatarImage: pot.profile.avatarImage,
  intro: pot.work.intro,
  status: pot.status,
);

/// "Paused · Claude Sonnet · Medium (auto) · This month $4.20 / $20".
String _potLine(BuildContext context, WidgetRef ref, Pot pot) {
  final l10n = AppLocalizations.of(context);
  final models = ref.watch(modelsProvider).value ?? const <ModelInfo>[];
  final main = pot.models.main;
  final info = currentModel(models, main.provider, main.model);
  final model = main.model.isEmpty ? null : info?.name ?? main.model;
  final level = thinkingLabel(l10n, pot.models.thinking);
  // A model known to have no thinking shows no level.
  final thinks =
      info == null || info.reasoning || info.thinkingLevels.isNotEmpty;
  return [
    if (pot.state == 'paused') l10n.potPaused,
    ?model,
    if (thinks) pot.models.thinkingAuto ? l10n.potsThinkingAuto(level) : level,
    ?potBudgetLine(l10n, pot),
  ].join(' · ');
}

/// "$50 a month · 5M tokens a day", or "No limit".
String capsText(BuildContext context, PotSettings limits) {
  final l10n = AppLocalizations.of(context);
  final money = limits.capMoneyMonthMicros;
  final tokens = limits.capTokensDay;
  if (money > 0 && tokens > 0) {
    return l10n.potsCapsBoth(dollars(money), compactTokens(tokens));
  }
  if (money > 0) return l10n.potsCapsMoney(dollars(money));
  if (tokens > 0) return l10n.potsCapsTokens(compactTokens(tokens));
  return l10n.potsNoLimit;
}

/// `d-pstat`: this month's money and today's tokens of all pots, each
/// with a meter against its owner-wide cap (none when it is 0).
class _Totals extends ConsumerWidget {
  const _Totals({required this.limits});
  final PotSettings limits;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final colors = PircColorTokens.of(context);
    final totals = ref.watch(potTotalsProvider).value;
    final meta = TextStyle(
      fontSize: 13.5,
      height: 18 / 13.5,
      color: colors['text.muted'],
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    Widget row(
      String key,
      String label,
      int? used,
      int cap,
      String Function(int) unit,
    ) {
      final usedText = used == null ? '–' : unit(used);
      final value = cap > 0
          ? '$usedText / ${unit(cap)}'
          : l10n.potsTotalNoCap(usedText);
      final labelBox = ConstrainedBox(
        constraints: const BoxConstraints(minWidth: 64),
        child: Text(label, style: meta),
      );
      if (cap <= 0) {
        return Row(
          key: ValueKey(key),
          spacing: 8,
          children: [
            labelBox,
            Expanded(
              child: Text(
                value,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.end,
                style: meta,
              ),
            ),
          ],
        );
      }
      return Row(
        key: ValueKey(key),
        spacing: 8,
        children: [
          labelBox,
          Expanded(
            child: Container(
              height: 6,
              alignment: Alignment.centerLeft,
              decoration: BoxDecoration(
                color: colors['line.default'],
                borderRadius: BorderRadius.circular(3),
              ),
              child: FractionallySizedBox(
                widthFactor: ((used ?? 0) / cap).clamp(0.0, 1.0),
                heightFactor: 1,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: colors['text.primary'],
                    borderRadius: BorderRadius.circular(3),
                  ),
                ),
              ),
            ),
          ),
          Flexible(
            child: Text(
              value,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: meta,
            ),
          ),
        ],
      );
    }

    return Container(
      margin: const EdgeInsets.fromLTRB(16, 4, 16, 0),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: colors['surface.layer'],
        borderRadius: BorderRadius.circular(PircRadius.lg),
      ),
      child: Column(
        spacing: 8,
        children: [
          row(
            'pots-total-month',
            l10n.potsTotalMonth,
            totals?.moneyMicros(
              countSubscription: limits.countSubscriptionMoney,
            ),
            limits.capMoneyMonthMicros,
            dollars,
          ),
          row(
            'pots-total-today',
            l10n.potsTotalToday,
            totals?.tokensToday,
            limits.capTokensDay,
            compactTokens,
          ),
        ],
      ),
    );
  }
}

/// A pot's name with its intro beside it in `c-meta`.
class _NameLine extends StatelessWidget {
  const _NameLine({required this.name, required this.intro});
  final String name;
  final String intro;

  @override
  Widget build(BuildContext context) {
    final colors = PircColorTokens.of(context);
    final text = Theme.of(context).textTheme;
    return Text.rich(
      TextSpan(
        children: [
          TextSpan(text: name),
          if (intro.isNotEmpty)
            TextSpan(
              text: ' $intro',
              style: TextStyle(fontSize: 12.5, color: colors['text.muted']),
            ),
        ],
      ),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: text.bodyMedium,
    );
  }
}

/// A row with its value at the end (`c-row-s` at 15) and a chevron.
class _ValueRow extends StatelessWidget {
  const _ValueRow({
    super.key,
    required this.title,
    required this.value,
    required this.onTap,
  });

  final String title;
  final String value;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = PircColorTokens.of(context);
    return Semantics(
      button: true,
      child: InkWell(
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 56),
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: PircSpacing.gutterPhone,
              vertical: 8,
            ),
            child: Row(
              spacing: 12,
              children: [
                Text(title, style: Theme.of(context).textTheme.bodyMedium),
                Expanded(
                  child: Text(
                    value,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.end,
                    style: TextStyle(
                      fontSize: 15,
                      height: 18 / 15,
                      color: colors['text.muted'],
                    ),
                  ),
                ),
                const _Chevron(),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Chevron extends StatelessWidget {
  const _Chevron();

  @override
  Widget build(BuildContext context) => Icon(
    LucideIcons.chevronRight,
    size: PircSize.iconInline,
    color: PircColorTokens.of(context)['text.faint'],
  );
}

Future<void> _showLimitsSheet(
  BuildContext context,
  Widget Function(PotSettings start) builder,
) async {
  final container = ProviderScope.containerOf(context);
  final start = container.read(potLimitsProvider).value;
  if (start == null) return;
  await showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    backgroundColor: PircColorTokens.of(context)['surface.grouped'],
    builder: (context) => SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(context).height * 0.85,
          ),
          child: builder(start),
        ),
      ),
    ),
  );
}

/// Saving one of the owner-wide settings: every field goes back with the
/// revision, built from the settings as last read, so the loop guard's
/// thresholds and the other fields are kept. A 409 reads them again, keeps
/// the edit and says so; the next save sends the new revision.
abstract class _LimitsState<T extends ConsumerStatefulWidget>
    extends ConsumerState<T> {
  PotSettings get start;

  late PotSettings _base = start;
  bool _busy = false;
  bool _conflict = false;
  String? _error;

  /// The settings with the edit applied, or null while it is invalid.
  PotSettings? edited(PotSettings base);

  /// Why the edit cannot be saved, if it cannot.
  String? get problem => null;

  bool get changed {
    final next = edited(_base);
    return next != null &&
        next.toJson().toString() != _base.toJson().toString();
  }

  Future<void> save() async {
    final api = ref.read(apiProvider);
    final next = edited(_base);
    if (api == null || next == null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final pots = PotsApi(api);
    try {
      await pots.updateSettings(next);
      ref.invalidate(potLimitsProvider);
      if (mounted) Navigator.pop(context);
    } on PircException catch (error) {
      if (error is ApiError && error.status == 409) {
        try {
          _base = await pots.settings();
        } on PircException {
          // The next save is answered 409 again and reads once more.
        }
        ref.invalidate(potLimitsProvider);
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

  Widget sheet({
    required String title,
    required List<Widget> children,
    String? note,
  }) {
    final l10n = AppLocalizations.of(context);
    final colors = PircColorTokens.of(context);
    final problem = this.problem;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
          child: Text(title, style: Theme.of(context).textTheme.titleLarge),
        ),
        Flexible(
          child: SingleChildScrollView(
            padding: const EdgeInsets.only(top: 8, bottom: 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (_conflict)
                  Container(
                    key: const ValueKey('pots-limits-conflict'),
                    margin: const EdgeInsets.fromLTRB(16, 4, 16, 12),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 10,
                    ),
                    decoration: BoxDecoration(
                      color: colors['status.warningSoft'],
                      borderRadius: BorderRadius.circular(PircRadius.md),
                    ),
                    child: Text(
                      l10n.potsSettingsConflict,
                      style: TextStyle(
                        fontSize: 13.5,
                        height: 20 / 13.5,
                        color: colors['text.warning'],
                      ),
                    ),
                  ),
                if (_error != null)
                  ErrorBox(_error!, key: const ValueKey('pots-limits-error')),
                ...children,
                if (problem != null)
                  GroupNote(
                    problem,
                    error: true,
                    key: const ValueKey('pots-limits-problem'),
                  ),
                if (note != null) GroupNote(note),
              ],
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 8),
          child: FilledButton(
            key: const ValueKey('pots-limits-save'),
            style: inkButtonStyle(context),
            onPressed: _busy || !changed || problem != null ? null : save,
            child: Text(l10n.save),
          ),
        ),
      ],
    );
  }
}

/// Dollars for a field: `50`, `12.5`, `0`.
String _plainDollars(int micros) {
  final text = (micros / 1000000).toStringAsFixed(2);
  return text.replaceFirst(RegExp(r'\.?0+$'), '');
}

/// Micro-dollars of a typed amount (an empty field is 0), or null.
int? _parseDollars(String text) {
  final clean = text.trim().replaceAll(',', '').replaceFirst(r'$', '');
  if (clean.isEmpty) return 0;
  final value = double.tryParse(clean);
  if (value == null || value < 0 || !value.isFinite) return null;
  return (value * 1000000).round();
}

/// A whole number typed with or without grouping (an empty field is 0),
/// or null.
int? _parseCount(String text) {
  final clean = text.trim().replaceAll(RegExp(r'[,\s_]'), '');
  if (clean.isEmpty) return 0;
  final value = int.tryParse(clean);
  return value == null || value < 0 ? null : value;
}

/// The owner-wide caps: money a month and tokens a day; 0 is no cap.
class _CapsSheet extends ConsumerStatefulWidget {
  const _CapsSheet({required this.start});
  final PotSettings start;

  @override
  ConsumerState<_CapsSheet> createState() => _CapsSheetState();
}

class _CapsSheetState extends _LimitsState<_CapsSheet> {
  @override
  PotSettings get start => widget.start;

  late final _money = TextEditingController(
    text: _plainDollars(start.capMoneyMonthMicros),
  );
  late final _tokens = TextEditingController(text: '${start.capTokensDay}');

  @override
  void dispose() {
    _money.dispose();
    _tokens.dispose();
    super.dispose();
  }

  @override
  PotSettings? edited(PotSettings base) {
    final money = _parseDollars(_money.text);
    final tokens = _parseCount(_tokens.text);
    if (money == null || tokens == null) return null;
    return base.copyWith(capMoneyMonthMicros: money, capTokensDay: tokens);
  }

  @override
  String? get problem {
    final l10n = AppLocalizations.of(context);
    if (_parseDollars(_money.text) == null) return l10n.potsCapsMoneyInvalid;
    if (_parseCount(_tokens.text) == null) return l10n.potsCapsTokensInvalid;
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return sheet(
      title: l10n.potsCaps,
      note: l10n.potsCapsSheetNote,
      children: [
        GroupedList(
          children: [
            FormInputRow(
              label: l10n.potsCapsMonth,
              suffix: l10n.potsCapsUsd,
              field: TextField(
                key: const ValueKey('pots-cap-money'),
                controller: _money,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                onChanged: (_) => setState(() {}),
                style: formFieldStyle(context, size: 15.5),
                decoration: plainField(context, '0'),
              ),
            ),
            FormInputRow(
              label: l10n.potsCapsDay,
              suffix: l10n.potsCapsTokensUnit,
              field: TextField(
                key: const ValueKey('pots-cap-tokens'),
                controller: _tokens,
                keyboardType: TextInputType.number,
                onChanged: (_) => setState(() {}),
                style: formFieldStyle(context, size: 15.5),
                decoration: plainField(context, '0'),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// What happens when an owner-wide cap is used up.
class _ExhaustedSheet extends ConsumerStatefulWidget {
  const _ExhaustedSheet({required this.start});
  final PotSettings start;

  @override
  ConsumerState<_ExhaustedSheet> createState() => _ExhaustedSheetState();
}

class _ExhaustedSheetState extends _LimitsState<_ExhaustedSheet> {
  @override
  PotSettings get start => widget.start;

  late String _choice = start.onExhausted;

  @override
  PotSettings? edited(PotSettings base) => base.copyWith(onExhausted: _choice);

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return sheet(
      title: l10n.potsExhausted,
      children: [
        GroupedList(
          children: [
            for (final (value, title, detail) in [
              ('ask', l10n.potsExhaustedAsk, l10n.potsExhaustedAskDetail),
              (
                'pause_all',
                l10n.potsExhaustedPause,
                l10n.potsExhaustedPauseDetail,
              ),
            ])
              RadioRow(
                key: ValueKey('pots-exhausted-$value'),
                title: title,
                subtitle: detail,
                selected: _choice == value,
                onTap: () => setState(() => _choice = value),
              ),
          ],
        ),
      ],
    );
  }
}

/// How long activity is kept: 1–3650 days.
class _RetentionSheet extends ConsumerStatefulWidget {
  const _RetentionSheet({required this.start});
  final PotSettings start;

  @override
  ConsumerState<_RetentionSheet> createState() => _RetentionSheetState();
}

class _RetentionSheetState extends _LimitsState<_RetentionSheet> {
  @override
  PotSettings get start => widget.start;

  late final _days = TextEditingController(
    text: '${start.activityRetentionDays}',
  );

  @override
  void dispose() {
    _days.dispose();
    super.dispose();
  }

  int? get _value {
    final days = int.tryParse(_days.text.trim());
    return days == null || days < 1 || days > 3650 ? null : days;
  }

  @override
  PotSettings? edited(PotSettings base) {
    final days = _value;
    return days == null ? null : base.copyWith(activityRetentionDays: days);
  }

  @override
  String? get problem =>
      _value == null ? AppLocalizations.of(context).potsRetentionInvalid : null;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return sheet(
      title: l10n.potsRetention,
      note: l10n.potsRetentionNote,
      children: [
        GroupedList(
          children: [
            FormInputRow(
              suffix: l10n.potsRetentionUnit,
              field: TextField(
                key: const ValueKey('pots-retention-days'),
                controller: _days,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                onChanged: (_) => setState(() {}),
                style: formFieldStyle(context, size: 15.5),
                decoration: plainField(context, '90'),
              ),
            ),
          ],
        ),
      ],
    );
  }
}
