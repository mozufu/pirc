import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:pirc_client/pirc_client.dart';
import 'package:pirc_ui/pirc_ui.dart';

import '../../l10n/app_localizations.dart';
import '../activity/activity_kinds.dart';
import '../connection/data.dart';
import '../connection/hints.dart';
import '../format.dart';
import '../work/work_data.dart';
import 'chat_data.dart';
import 'chat_list_screen.dart';
import 'new_pot_screen.dart';
import 'pot_conversation_screen.dart';
import 'pot_form.dart';
import 'pot_pause.dart';
import 'thread_cards.dart';
import 'thread_data.dart';

/// How many activity rows the profile shows.
const profileActivityRows = 5;

/// A pot's newest activity rows; read again on `activity_changed`.
final potActivityProvider = FutureProvider.autoDispose
    .family<List<ActivityEntry>, String>((ref, id) async {
      watchHint(ref, 'activity_changed');
      final page = await ActivityApi(
        requireApi(ref),
      ).activity(potId: id, limit: profileActivityRows);
      return page.entries.take(profileActivityRows).toList();
    });

/// A pot's own notes. The Gateway tells of a note written or forgotten
/// with `pots_changed` (`memory_changed` is the assistant's memory).
final potMemoryProvider = FutureProvider.autoDispose.family<PotMemory, String>((
  ref,
  id,
) {
  watchHint(ref, 'pots_changed');
  return PotsApi(requireApi(ref)).memory(id);
});

/// A pot's profile (E12): the header with its state, Message / Pause or
/// Resume / Hand over / Activity, what it is responsible for, what it may
/// do, its recent activity and its memory. Settings (E24) is at the top
/// right. It sits in the Chat tab's side pane (`side=profile`).
class PotProfileScreen extends ConsumerWidget {
  const PotProfileScreen({
    super.key,
    required this.potId,
    required this.onClose,
    this.closeIcon = false,
  });

  final String potId;
  final VoidCallback onClose;

  /// An ✕ instead of Back (the right column at 1200 and wider).
  final bool closeIcon;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final colors = PircColorTokens.of(context);
    final value = ref.watch(potProvider(potId));
    final pot = value.value;
    final Widget body;
    if (pot == null) {
      body = value.hasError
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                spacing: 8,
                children: [
                  Text(l10n.listFailed),
                  OutlinedButton(
                    onPressed: () => ref.invalidate(potProvider(potId)),
                    child: Text(l10n.retry),
                  ),
                ],
              ),
            )
          : const Center(child: CircularProgressIndicator());
    } else {
      body = SingleChildScrollView(
        key: const ValueKey('profile-scroll'),
        padding: const EdgeInsets.only(bottom: 24),
        child: _ProfileBody(pot: pot),
      );
    }
    return Scaffold(
      key: const ValueKey('pot-profile'),
      backgroundColor: colors['surface.grouped'],
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            PotTopBar(
              leading: IconButton(
                tooltip: closeIcon ? l10n.close : l10n.back,
                color: colors['text.secondary'],
                onPressed: onClose,
                icon: Icon(
                  closeIcon ? LucideIcons.x : LucideIcons.chevronLeft,
                  size: PircSize.iconBar,
                ),
              ),
              trailing: TextButton(
                key: const ValueKey('profile-settings'),
                onPressed: () => context.go(potSettingsLocation(potId)),
                style: TextButton.styleFrom(
                  foregroundColor: colors['text.primary'],
                  minimumSize: const Size(0, 36),
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  shape: const StadiumBorder(),
                  textStyle: Theme.of(
                    context,
                  ).textTheme.labelLarge?.copyWith(fontSize: 14),
                ),
                child: Text(l10n.settings),
              ),
            ),
            Expanded(child: body),
          ],
        ),
      ),
    );
  }
}

class _ProfileBody extends ConsumerWidget {
  const _ProfileBody({required this.pot});
  final Pot pot;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final colors = PircColorTokens.of(context);
    final summary = potById(ref, pot.id);
    final paused = pot.state == 'paused';
    final archived = pot.state == 'archived';
    final hosts = [
      for (final thread
          in ref.watch(threadsProvider).value ?? const <PotThread>[])
        if (thread.isGroup && thread.hostPotId == pot.id) thread,
    ].length;
    final status = summary?.status ?? pot.status;
    final chips = [
      if (paused)
        ProfileChip(l10n.potPaused, dot: 'status.warning')
      else if (archived)
        ProfileChip(l10n.potProfileArchived)
      else if (status == 'working')
        ProfileChip(
          l10n.potWorking,
          dot: 'status.success',
          labelColor: 'text.success',
        )
      else if (status == 'unavailable')
        ProfileChip(l10n.potUnavailable, dot: 'text.faint'),
      switch (pot.permissions.reach) {
        'observe' => ProfileChip(
          l10n.potHeaderObserve,
          dot: paused ? null : 'accent.default',
          labelColor: paused ? null : 'accent.pressed',
        ),
        'work' => ProfileChip(l10n.potHeaderWork),
        _ => ProfileChip(l10n.potHeaderAnswer),
      },
      if (hosts > 0) ProfileChip(l10n.potHostsGroups(hosts)),
    ];
    final actions = [
      ProfileAction(
        icon: LucideIcons.messageSquare,
        label: l10n.potActionMessage,
        onTap: () => context.go(chatLocation(potChatKey(pot.id))),
      ),
      if (!archived)
        ProfileAction(
          icon: paused ? LucideIcons.play : LucideIcons.pause,
          label: paused ? l10n.potActionResume : l10n.potActionPause,
          onTap: () => paused
              ? resumePot(context, ref, pot.id)
              : showPotPauseSheet(context, pot.id),
        ),
      if (!archived)
        ProfileAction(
          icon: LucideIcons.arrowRightLeft,
          label: l10n.potActionHandOver,
          onTap: () => context.go(chatLocation(handoverNewKey(pot.id))),
        ),
      ProfileAction(
        icon: LucideIcons.activity,
        label: l10n.potActionActivity,
        onTap: () => context.go(potActivityLocation(pot.id)),
      ),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ProfileHeader(
          avatar: Avatar(
            name: pot.name,
            color: pot.profile.avatarColor,
            size: AvatarSize.lg,
            image: watchAvatarImage(ref, pot.profile.avatarImage),
          ),
          name: pot.name,
          intro: pot.work.intro,
          chips: chips,
          actions: actions,
        ),
        if (paused)
          Container(
            key: const ValueKey('profile-paused'),
            margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: colors['status.warningSoft'],
              borderRadius: BorderRadius.circular(PircRadius.md),
            ),
            child: Text.rich(
              TextSpan(
                children: [
                  TextSpan(
                    text: '${l10n.potPausedBannerTitle} ',
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  TextSpan(text: l10n.potPausedBannerText),
                ],
              ),
              style: TextStyle(
                fontSize: 13.5,
                height: 20 / 13.5,
                color: colors['text.warning'],
              ),
            ),
          ),
        GroupLabel(l10n.potGroupResponsibilities),
        if (pot.work.responsibilities.isEmpty)
          GroupNote(l10n.potProfileNoResponsibilities)
        else
          GroupedList(
            children: [
              for (final r in pot.work.responsibilities)
                GroupedRow(
                  title: r.title,
                  subtitle: r.detail,
                  wrapSubtitle: true,
                ),
            ],
          ),
        GroupLabel(l10n.potProfileMayDo),
        GroupedList(
          key: const ValueKey('profile-may-do'),
          children: _mayDo(context, ref, pot),
        ),
        _ActivitySection(pot: pot),
        _MemorySection(pot: pot),
      ],
    );
  }

  /// The permissions in plain words, one row each.
  static List<Widget> _mayDo(BuildContext context, WidgetRef ref, Pot pot) {
    final l10n = AppLocalizations.of(context);
    final p = pot.permissions;
    final separator = l10n.potListSeparator;
    final pots = ref.watch(potsProvider).value ?? const <PotSummary>[];
    final workspaces =
        ref.watch(workspacesProvider).value ?? const <WorkspaceInfo>[];
    final sessions = ref.watch(sessionsProvider).value ?? const <Session>[];
    String potName(String id) =>
        pots.where((x) => x.id == id).firstOrNull?.name ?? id;
    String workspaceName(String id) =>
        workspaces.where((w) => w.id == id).firstOrNull?.displayName ?? id;
    String dm(String rule, List<String> ids) => switch (rule) {
      'off' => l10n.potDmOff,
      'selected' =>
        ids.isEmpty
            ? l10n.potProfileObserveNothing
            : ids.map(potName).join(separator),
      _ => l10n.potDmAll,
    };
    final observed = [
      for (final scope in p.observe)
        switch (scope.kind) {
          'calendar' => l10n.potObserveCalendar,
          'schedules' => l10n.potObserveSchedules,
          'session' =>
            sessions.where((s) => s.id == scope.ref).firstOrNull?.name ??
                scope.ref,
          _ => workspaceName(scope.ref),
        },
    ];
    final money = p.budgetMoneyMonthMicros;
    final tokens = p.budgetTokensDay;
    final interval = pot.autonomy.intervalS;
    Widget row(String key, String title, String value) => GroupedRow(
      key: ValueKey('may-do-$key'),
      title: title,
      subtitle: value,
      wrapSubtitle: true,
    );
    return [
      row('reach', reachLabel(l10n, p.reach), switch (p.reach) {
        'observe' => l10n.potReachObserveDetail,
        'work' => l10n.potReachWorkDetail(pot.name),
        _ => l10n.potReachAnswerDetail,
      }),
      if (p.reach != 'answer')
        row(
          'observe',
          l10n.potGroupObserve,
          observed.isEmpty
              ? l10n.potProfileObserveNothing
              : observed.join(separator),
        ),
      row('dm-send', l10n.potGroupDmSend, dm(p.dm.send, p.dm.sendTo)),
      row(
        'dm-receive',
        l10n.potGroupDmReceive,
        dm(p.dm.receive, p.dm.receiveFrom),
      ),
      if (p.reach == 'work') ...[
        row(
          'places',
          l10n.potProfileWorkPlaces,
          p.workLocations.isEmpty
              ? l10n.potProfileNoPlaces
              : [
                  for (final location in p.workLocations)
                    l10n.potProfilePlace(
                      workspaceName(location.workspaceId),
                      location.access == 'write'
                          ? l10n.potAccessWrite
                          : l10n.potAccessRead,
                    ),
                ].join(separator),
        ),
        row(
          'works',
          l10n.potMaxWorks,
          l10n.potMaxWorksValue(p.maxConcurrentWorks),
        ),
      ],
      row(
        'budget',
        l10n.potGroupBudget,
        [
          if (money != null) l10n.potProfileMoneyMonth(dollars(money)),
          if (tokens != null)
            l10n.potProfileTokensDay(grouped(context, tokens)),
        ].join(' · '),
      ),
      row(
        'review',
        l10n.potGroupReview,
        interval == null
            ? l10n.potReviewOff
            : interval == 604800
            ? l10n.potProfileReviewWeekly
            : l10n.potProfileReviewDays(
                (interval / 86400).round().clamp(1, 365),
              ),
      ),
    ];
  }
}

/// A title row like `c-gl` with a button at its right ("See all").
class _LabelRow extends StatelessWidget {
  const _LabelRow({required this.text, this.action});
  final String text;
  final Widget? action;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(right: 16),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Expanded(child: GroupLabel(text)),
        ?action,
      ],
    ),
  );
}

TextButton _smallButton(
  BuildContext context, {
  Key? key,
  required String label,
  required VoidCallback? onPressed,
  Color? color,
}) {
  final colors = PircColorTokens.of(context);
  return TextButton(
    key: key,
    onPressed: onPressed,
    style: TextButton.styleFrom(
      foregroundColor: color ?? colors['accent.pressed'],
      minimumSize: const Size(0, 32),
      padding: const EdgeInsets.symmetric(horizontal: 10),
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      shape: const StadiumBorder(),
      textStyle: Theme.of(
        context,
      ).textTheme.labelLarge?.copyWith(fontSize: 13.5),
    ),
    child: Text(label),
  );
}

/// The pot's five newest activity rows and "See all" (the Activity tab
/// filtered to it).
class _ActivitySection extends ConsumerWidget {
  const _ActivitySection({required this.pot});
  final Pot pot;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final entries = ref.watch(potActivityProvider(pot.id));
    final summary = potById(ref, pot.id);
    final now = ref.watch(clockProvider)();
    final pots = ref.watch(potsProvider).value ?? const <PotSummary>[];
    final rows = entries.value ?? const <ActivityEntry>[];
    String? target(ActivityEntry entry) {
      final counterpart = entry.counterpart;
      return switch (counterpart?.kind) {
        'user' => '→ ${l10n.activityToYou}',
        'pot' => () {
          final name = pots
              .where((p) => p.id == counterpart!.id)
              .firstOrNull
              ?.name;
          return name == null ? null : '→ $name';
        }(),
        _ => null,
      };
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _LabelRow(
          text: l10n.potProfileActivity,
          action: _smallButton(
            context,
            key: const ValueKey('profile-see-all'),
            label: l10n.potProfileSeeAll,
            onPressed: () => context.go(potActivityLocation(pot.id)),
          ),
        ),
        if (entries.hasError && rows.isEmpty)
          GroupNote(l10n.listFailed, error: true)
        else if (entries.isLoading && rows.isEmpty)
          const SizedBox(height: 56)
        else if (rows.isEmpty)
          GroupNote(l10n.potProfileNoActivity)
        else
          GroupedList(
            key: const ValueKey('profile-activity'),
            children: [
              for (final entry in rows)
                LogRow(
                  key: ValueKey('activity-${entry.id}'),
                  avatar: summary != null
                      ? PotAvatar(pot: summary, size: AvatarSize.sm)
                      : Avatar(
                          name: entry.potName,
                          color: entry.potAvatarColor,
                          size: AvatarSize.sm,
                        ),
                  who: summary?.name ?? entry.potName,
                  target: target(entry),
                  time: listTime(context, entry.at, now: now),
                  tag: LogTag(
                    activityKindLabel(l10n, entry.kind),
                    tone: activityKindTone(entry.kind),
                  ),
                  quote: entry.summary.isEmpty ? null : entry.summary,
                ),
            ],
          ),
      ],
    );
  }
}

/// The pot's own notes, each with Forget.
class _MemorySection extends ConsumerStatefulWidget {
  const _MemorySection({required this.pot});
  final Pot pot;

  @override
  ConsumerState<_MemorySection> createState() => _MemorySectionState();
}

class _MemorySectionState extends ConsumerState<_MemorySection> {
  final _forgetting = <String>{};

  Future<void> _forget(PotNote note) async {
    final api = ref.read(apiProvider);
    if (api == null) return;
    final messenger = ScaffoldMessenger.maybeOf(context);
    setState(() => _forgetting.add(note.id));
    try {
      await PotsApi(api).forget(widget.pot.id, note.id);
    } on PircException catch (error) {
      messenger?.showSnackBar(SnackBar(content: Text(error.message)));
    } finally {
      if (mounted) setState(() => _forgetting.remove(note.id));
      ref.invalidate(potMemoryProvider(widget.pot.id));
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final colors = PircColorTokens.of(context);
    final memory = ref.watch(potMemoryProvider(widget.pot.id));
    final notes = memory.value?.notes ?? const <PotNote>[];
    final used = notes.fold(0, (sum, note) => sum + note.content.runes.length);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        GroupLabel(l10n.potProfileMemory),
        if (memory.hasError && memory.value == null)
          GroupNote(l10n.listFailed, error: true)
        else if (memory.value == null)
          const SizedBox(height: 56)
        else if (notes.isEmpty)
          GroupNote(l10n.potProfileNoMemory)
        else ...[
          GroupedList(
            key: const ValueKey('profile-memory'),
            children: [
              for (final note in notes)
                GroupedRow(
                  key: ValueKey('note-${note.id}'),
                  titleWidget: Text(
                    note.content,
                    style: TextStyle(
                      fontSize: 14,
                      height: 21 / 14,
                      color: colors['text.primary'],
                    ),
                  ),
                  trailing: _smallButton(
                    context,
                    key: ValueKey('forget-${note.id}'),
                    label: l10n.potProfileForget,
                    color: colors['status.danger'],
                    onPressed: _forgetting.contains(note.id)
                        ? null
                        : () => _forget(note),
                  ),
                ),
            ],
          ),
          GroupNote(
            l10n.potProfileMemoryNote(
              widget.pot.name,
              grouped(context, used),
              grouped(context, memory.value!.budget),
            ),
          ),
        ],
      ],
    );
  }
}
