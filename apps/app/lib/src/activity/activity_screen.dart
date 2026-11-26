import 'package:flutter/material.dart' hide DrawerButton;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:pirc_client/pirc_client.dart';
import 'package:pirc_ui/pirc_ui.dart';

import '../../l10n/app_localizations.dart';
import '../chat/chat_data.dart';
import '../chat/chat_list_screen.dart';
import '../chat/decision_sheet.dart';
import '../chat/thread_cards.dart';
import '../connection/data.dart';
import '../format.dart';
import '../shell/app_drawer.dart';
import '../work/work_data.dart';
import '../work/work_side.dart';
import 'activity_data.dart';
import 'activity_kinds.dart';

/// Opens what an activity row points at.
void openActivity(BuildContext context, ActivityOpen open) => switch (open) {
  OpenLocation(:final location) => context.go(location),
  OpenApproval(:final id) => showApprovalSheet(context, id),
  OpenBudgetRequest(:final id) => showBudgetRequestSheet(context, id),
};

/// The Activity tab's list (E5, E27): the pot chips and the type filter,
/// "See ○○'s point of view" when one pot is chosen, the "Noticed"
/// section, then the rows by day, newest first; older pages load near the
/// end. The filters live in the [location] (`pot`, `kind`); a push lands
/// on `notification=<id>`, which is scrolled into view and marked.
class ActivityListScreen extends ConsumerStatefulWidget {
  const ActivityListScreen({super.key, required this.location});

  final Uri location;

  @override
  ConsumerState<ActivityListScreen> createState() => _ActivityListState();
}

class _ActivityListState extends ConsumerState<ActivityListScreen> {
  final _scroll = ScrollController();
  final _noticeKey = GlobalKey(debugLabel: 'pushed notification');
  String? _shownNotification;

  Map<String, String> get _params => widget.location.queryParameters;
  String? get _potId => _params['pot'];
  String? get _kind => _params['kind'];
  String? get _notification => _params['notification'];
  ActivityQuery get _query => (potId: _potId, kind: _kind);

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_check);
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _check() {
    if (!_scroll.hasClients) return;
    final position = _scroll.position;
    if (position.pixels >= position.maxScrollExtent - 300) {
      ref.read(activityFeedProvider(_query).notifier).loadOlder();
    }
  }

  /// The list with [pot] and [kind] as its filters (the open item stays).
  void _filter({required String? pot, required String? kind}) {
    final open = _params['open'];
    context.go(
      activityLocation(
        potId: pot,
        kind: kind,
        // A point of view follows the chosen pot.
        open: povPotOf(open) == null || pot == null ? null : povKey(pot),
      ),
    );
  }

  /// Scrolls the pushed notification into view once it is built.
  void _reveal() {
    final id = _notification;
    if (id == null || id == _shownNotification) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final target = _noticeKey.currentContext;
      if (!mounted || target == null) return;
      _shownNotification = id;
      Scrollable.ensureVisible(target, alignment: 0.1);
    });
  }

  Future<void> _pickKind() async {
    final l10n = AppLocalizations.of(context);
    final picked = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (context) {
        final text = Theme.of(context).textTheme;
        final colors = PircColorTokens.of(context);
        Widget row(String label, String value) {
          final on = (_kind ?? '') == value;
          return InkWell(
            key: ValueKey('kind-filter-${value.isEmpty ? 'all' : value}'),
            onTap: () => Navigator.pop(context, value),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
              child: Row(
                children: [
                  Expanded(child: Text(label, style: text.bodyMedium)),
                  if (on)
                    Icon(
                      LucideIcons.check,
                      size: 18,
                      color: colors['accent.default'],
                    ),
                ],
              ),
            ),
          );
        }

        return ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(context).height * 0.8,
          ),
          child: SafeArea(
            child: ListView(
              key: const ValueKey('kind-filters'),
              shrinkWrap: true,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                  child: Text(
                    l10n.activityFilterKind,
                    style: text.titleLarge?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                row(l10n.activityAllKinds, ''),
                for (final kinds in activityKindFilters)
                  row(activityKindLabel(l10n, kinds.first), kinds.join(',')),
              ],
            ),
          ),
        );
      },
    );
    if (picked == null || !mounted) return;
    _filter(pot: _potId, kind: picked.isEmpty ? null : picked);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final text = Theme.of(context).textTheme;
    final colors = PircColorTokens.of(context);
    final feed = ref.watch(activityFeedProvider(_query));
    final notices = ref.watch(notificationsProvider).value ?? const [];
    final pots = ref.watch(potsProvider).value ?? const <PotSummary>[];
    final works = watchPotWorks(ref);
    final threads = ref.watch(threadsProvider).value ?? const <PotThread>[];
    final now = ref.watch(clockProvider)();
    final potId = _potId;
    final pot = potById(ref, potId);
    final locale = Localizations.localeOf(context).toLanguageTag();

    final shownNotices = _kind != null
        ? const <ObservationNotification>[]
        : [
            for (final n in notices)
              if (potId == null ||
                  n.issuerPotId == potId ||
                  n.observations.any((o) => o.potId == potId))
                n,
          ];

    // The point-of-view entry and the notices are one child, always
    // built, so a pushed notification can be scrolled to.
    final top = <Widget>[
      if (pot != null)
        Padding(
          padding: const EdgeInsets.only(top: 2),
          child: PovBar(
            key: const ValueKey('see-pov'),
            avatar: PotAvatar(pot: pot, size: AvatarSize.md),
            title: l10n.activitySeePov(pot.name),
            subtitle: l10n.activitySeePovDetail,
            onTap: () => context.go(povLocation(pot.id)),
          ),
        ),
      if (shownNotices.isNotEmpty) ...[
        _SectionLabel(l10n.activityNoticed),
        for (final n in shownNotices)
          _NoticeRow(
            key: n.id == _notification
                ? _noticeKey
                : ValueKey('notice-${n.id}'),
            notification: n,
            selected: n.id == _notification,
          ),
      ],
    ];
    final children = <Widget>[
      Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: top),
    ];
    DateTime? day;
    for (final entry in feed.entries) {
      final time = DateTime.fromMillisecondsSinceEpoch(entry.at);
      final date = DateUtils.dateOnly(time);
      if (date != day) {
        day = date;
        final days = DateUtils.dateOnly(now).difference(date).inDays;
        children.add(
          _SectionLabel(switch (days) {
            0 => l10n.calendarToday,
            1 => l10n.yesterday,
            _ => DateFormat.MMMEd(locale).format(time),
          }),
        );
      }
      final summary = potById(ref, entry.potId);
      final open = activityOpenOf(entry, threads, pots: pots);
      children.add(
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
          target: activityTarget(
            l10n,
            entry,
            pots: pots,
            works: works,
            threads: threads,
          ),
          time: DateFormat.Hm(locale).format(time),
          tag: LogTag(
            activityKindLabel(l10n, entry.kind),
            tone: activityKindTone(entry.kind),
          ),
          quote: entry.summary.isEmpty ? null : entry.summary,
          onTap: open == null ? null : () => openActivity(context, open),
        ),
      );
    }
    if (feed.nextBefore != null) {
      children.add(
        Center(
          key: const ValueKey('activity-more'),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: SizedBox.square(
              dimension: 20,
              child: feed.loadingOlder
                  ? const CircularProgressIndicator(strokeWidth: 2)
                  : null,
            ),
          ),
        ),
      );
    }

    final Widget body;
    if (!feed.loaded && feed.error != null && feed.error is! NotConnected) {
      body = _Failed(
        onRetry: ref.read(activityFeedProvider(_query).notifier).refresh,
      );
    } else if (!feed.loaded) {
      body = const Center(child: CircularProgressIndicator());
    } else {
      if (feed.entries.isEmpty) {
        children.add(
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 32, 16, 8),
            child: Text(
              potId == null && _kind == null
                  ? l10n.emptyActivity
                  : l10n.activityEmptyFilter,
              textAlign: TextAlign.center,
              style: text.bodySmall,
            ),
          ),
        );
      }
      children.add(
        Padding(
          padding: const EdgeInsets.all(16),
          child: Text(
            l10n.activityFootnote,
            style: TextStyle(
              fontSize: 12.5,
              height: 18 / 12.5,
              color: colors['text.muted'],
            ),
          ),
        ),
      );
      _reveal();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _check();
      });
      body = ListView(
        key: const ValueKey('activity-list'),
        controller: _scroll,
        padding: const EdgeInsets.only(bottom: PircSpacing.stackLg),
        children: children,
      );
    }

    return Scaffold(
      appBar: AppBar(
        leading: const DrawerButton(),
        centerTitle: true,
        title: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(l10n.tabActivity, style: text.titleSmall),
            Text(
              l10n.activitySubtitle,
              style: TextStyle(
                fontSize: 12,
                height: 16 / 12,
                color: colors['text.muted'],
              ),
            ),
          ],
        ),
        actions: [
          IconButton(
            key: const ValueKey('activity-kind'),
            tooltip: l10n.activityFilterKind,
            isSelected: _kind != null,
            color: colors['text.primary'],
            selectedIcon: Icon(
              LucideIcons.listFilter,
              color: colors['accent.default'],
            ),
            icon: const Icon(LucideIcons.listFilter),
            onPressed: _pickKind,
          ),
        ],
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _PotChips(
            pots: [
              for (final p in pots)
                if (p.state != 'archived' || p.id == potId) p,
            ],
            selected: potId,
            onSelected: (id) => _filter(pot: id, kind: _kind),
          ),
          Expanded(child: body),
        ],
      ),
    );
  }
}

/// `e-favs`: "All" and one chip per pot with its avatar (36 high, the
/// avatar 28), the chosen one in ink; they scroll sideways.
class _PotChips extends StatefulWidget {
  const _PotChips({
    required this.pots,
    required this.selected,
    required this.onSelected,
  });

  final List<PotSummary> pots;
  final String? selected;
  final ValueChanged<String?> onSelected;

  @override
  State<_PotChips> createState() => _PotChipsState();
}

class _PotChipsState extends State<_PotChips> {
  final _selectedKey = GlobalKey(debugLabel: 'chosen pot');

  @override
  void initState() {
    super.initState();
    _reveal();
  }

  @override
  void didUpdateWidget(_PotChips old) {
    super.didUpdateWidget(old);
    if (old.selected != widget.selected ||
        old.pots.length != widget.pots.length) {
      _reveal();
    }
  }

  /// Scrolls the chosen pot's chip into view (from the profile's "See
  /// all", or after the pots load).
  void _reveal() => WidgetsBinding.instance.addPostFrameCallback((_) {
    final chip = _selectedKey.currentContext;
    if (mounted && chip != null) {
      Scrollable.ensureVisible(
        chip,
        alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtEnd,
      );
    }
  });

  @override
  Widget build(BuildContext context) {
    final pots = widget.pots, selected = widget.selected;
    final onSelected = widget.onSelected;
    final l10n = AppLocalizations.of(context);
    final colors = PircColorTokens.of(context);
    Widget chip(String? id, String label, Widget? avatar) {
      final on = id == selected;
      return Semantics(
        key: on && id != null ? _selectedKey : null,
        selected: on,
        button: true,
        child: Material(
          key: ValueKey('pot-filter-${id ?? 'all'}'),
          color: on ? colors['action.primary'] : colors['fill.hover'],
          shape: const StadiumBorder(),
          child: InkWell(
            customBorder: const StadiumBorder(),
            onTap: () => onSelected(id),
            child: Container(
              height: 36,
              padding: avatar == null
                  ? const EdgeInsets.symmetric(horizontal: 14)
                  : const EdgeInsets.fromLTRB(4, 0, 12, 0),
              alignment: Alignment.center,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                spacing: 6,
                children: [
                  ?avatar,
                  Text(
                    label,
                    style: TextStyle(
                      fontSize: 14,
                      height: 20 / 14,
                      fontWeight: on ? FontWeight.w500 : FontWeight.w400,
                      color: on
                          ? colors['action.onPrimary']
                          : colors['text.secondary'],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }

    return Semantics(
      label: l10n.activityFilterPots,
      child: SizedBox(
        height: 44,
        child: ListView(
          key: const ValueKey('pot-filters'),
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          children: [
            for (final (i, w) in [
              chip(null, l10n.filterAll, null),
              for (final pot in pots)
                chip(
                  pot.id,
                  pot.name,
                  PotAvatar(pot: pot, size: AvatarSize.sm),
                ),
            ].indexed) ...[if (i > 0) const SizedBox(width: 6), w],
          ],
        ),
      ),
    );
  }
}

/// `c-sec`: a day or the "Noticed" title (12.5/600, muted).
class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Semantics(
    header: true,
    child: Padding(
      padding: const EdgeInsets.fromLTRB(16, 22, 16, 6),
      child: Text(text, style: Theme.of(context).textTheme.labelMedium),
    ),
  );
}

/// One observation notification in the "Noticed" section, laid out as a
/// log row: the pot that told the user (or how many noted it, merged),
/// what happened, the time; a "New" or "Seen" tag and the pot's note; open
/// ones end with "Mark read". A work's notification opens the work.
class _NoticeRow extends ConsumerStatefulWidget {
  const _NoticeRow({
    super.key,
    required this.notification,
    this.selected = false,
  });

  final ObservationNotification notification;
  final bool selected;

  @override
  ConsumerState<_NoticeRow> createState() => _NoticeRowState();
}

class _NoticeRowState extends ConsumerState<_NoticeRow> {
  bool _marking = false;

  Future<void> _markRead() async {
    final api = ref.read(apiProvider);
    if (api == null) return;
    final messenger = ScaffoldMessenger.maybeOf(context);
    setState(() => _marking = true);
    try {
      await ActivityApi(api).markNotificationRead(widget.notification.id);
      ref.invalidate(notificationsProvider);
    } on PircException catch (error) {
      messenger?.showSnackBar(SnackBar(content: Text(error.message)));
    } finally {
      if (mounted) setState(() => _marking = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final colors = PircColorTokens.of(context);
    final n = widget.notification;
    final now = ref.watch(clockProvider)();
    final issuer = potById(ref, n.issuerPotId);
    final first = n.observations.firstOrNull;
    final face = issuer ?? potById(ref, first?.potId);
    final who = n.issuerPotId == null && n.observations.length > 1
        ? l10n.activityNoticedMerged(n.observations.length)
        : issuer?.name ?? face?.name ?? first?.potName ?? '';
    final note = [
      for (final o in n.observations)
        if (o.potId == n.issuerPotId && o.note.isNotEmpty) o.note,
      for (final o in n.observations)
        if (o.note.isNotEmpty) o.note,
    ].firstOrNull;
    final source = switch (n.sourceKind) {
      'session' when n.sourceRef.isNotEmpty => workLocation(n.sourceRef),
      'calendar' => '/calendar',
      _ => null,
    };
    final title = TextStyle(
      fontSize: 14,
      height: 20 / 14,
      color: colors['text.primary'],
    );
    return Material(
      color: widget.selected ? colors['fill.active'] : Colors.transparent,
      child: InkWell(
        onTap: source == null ? null : () => context.go(source),
        hoverColor: colors['fill.hover'],
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            spacing: 10,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 1),
                child: face != null
                    ? PotAvatar(pot: face, size: AvatarSize.sm)
                    : Avatar(name: who, size: AvatarSize.sm),
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  spacing: 3,
                  children: [
                    Row(
                      spacing: 6,
                      children: [
                        Text(
                          who,
                          style: title.copyWith(fontWeight: FontWeight.w600),
                        ),
                        Expanded(
                          child: Text(
                            conditionLabel(l10n, n.condition),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: title,
                          ),
                        ),
                        Text(
                          listTime(context, n.createdAt, now: now),
                          style: TextStyle(
                            fontSize: 12,
                            color: colors['text.muted'],
                            fontFeatures: const [FontFeature.tabularFigures()],
                          ),
                        ),
                      ],
                    ),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      spacing: 6,
                      children: [
                        LogTag(
                          n.open
                              ? l10n.activityNoticeOpen
                              : l10n.activityNoticeSeen,
                          tone: n.open
                              ? LogTagTone.attention
                              : LogTagTone.plain,
                        ),
                        if (note != null)
                          Expanded(
                            child: Text(
                              note,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 13.5,
                                height: 20 / 13.5,
                                color: colors['text.secondary'],
                              ),
                            ),
                          ),
                      ],
                    ),
                    if (n.open)
                      Align(
                        alignment: AlignmentDirectional.centerEnd,
                        child: TextButton(
                          key: ValueKey('mark-read-${n.id}'),
                          onPressed: _marking ? null : _markRead,
                          style: TextButton.styleFrom(
                            backgroundColor: colors['fill.hover'],
                            foregroundColor: colors['text.primary'],
                            minimumSize: const Size(0, 32),
                            padding: const EdgeInsets.symmetric(horizontal: 12),
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                            shape: const StadiumBorder(),
                            textStyle: Theme.of(context).textTheme.labelLarge
                                ?.copyWith(
                                  fontSize: 13.5,
                                  fontWeight: FontWeight.w500,
                                ),
                          ),
                          child: Text(l10n.activityMarkRead),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// What an observed event's condition means, in the user's words.
String conditionLabel(AppLocalizations l10n, String condition) =>
    switch (condition) {
      'run_finished' => l10n.activityConditionRunFinished,
      'waiting_input' => l10n.activityConditionWaitingInput,
      'starting_soon' => l10n.activityConditionStartingSoon,
      'run_failed' => l10n.activityConditionRunFailed,
      _ => condition.replaceAll('_', ' '),
    };

class _Failed extends StatelessWidget {
  const _Failed({required this.onRetry});
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(l10n.listFailed, style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: PircSpacing.stackSm),
          OutlinedButton(onPressed: onRetry, child: Text(l10n.retry)),
        ],
      ),
    );
  }
}
