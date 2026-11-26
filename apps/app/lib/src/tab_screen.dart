import 'package:flutter/material.dart' hide DrawerButton;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:pirc_ui/pirc_ui.dart';

import '../l10n/app_localizations.dart';
import 'calendar/calendar_detail.dart';
import 'calendar/calendar_screen.dart';
import 'chat/chat_data.dart';
import 'chat/chat_list_screen.dart';
import 'chat/decision_sheet.dart';
import 'chat/group_conversation_screen.dart';
import 'chat/group_info_screen.dart';
import 'chat/handover_screen.dart';
import 'chat/new_group_screen.dart';
import 'chat/new_pot_screen.dart';
import 'chat/pot_conversation_screen.dart';
import 'chat/pot_profile_screen.dart';
import 'chat/pot_settings_screen.dart';
import 'chat/retire_screen.dart';
import 'router.dart';
import 'shell/app_drawer.dart';
import 'work/new_conversation/new_conversation_screen.dart';
import 'work/project_screen.dart';
import 'work/work_conversation.dart';
import 'work/work_side.dart';
import 'work/work_data.dart';
import 'work/work_list_screen.dart';

/// One tab in the adaptive frame: the Chat, Work and Calendar lists and
/// items; Activity and the Chat items not built yet stay placeholders.
class TabScreen extends ConsumerWidget {
  const TabScreen({
    super.key,
    required this.tab,
    this.openItem,
    this.side,
    this.location,
  });

  final AppTab tab;
  final String? openItem;

  /// The whole location: `approval=<id>` or `budget=<id>` (where a push
  /// lands) opens that decision's sheet over the tab.
  final Uri? location;

  /// What the side pane shows (`result:<id>`, `panel:<section>`, a pot's
  /// `profile`, a group's `group-info`).
  final String? side;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final shell = StatefulNavigationShell.maybeOf(context);
    final desktop =
        PircLayout.forWidth(MediaQuery.sizeOf(context).width) ==
        PircLayout.desktop;
    final open = openItem;
    final page = PopScope(
      // Back closes the open item first (one-pane layouts show it alone).
      canPop: open == null,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && open != null) {
          context.go(switch (tab) {
            AppTab.work => workBackLocation(context),
            // The profile closes first, back to its conversation.
            AppTab.chat when side != null => chatLocation(open),
            // A pot's settings go back to its profile.
            AppTab.chat when open.startsWith('settings:') => potProfileLocation(
              open.substring('settings:'.length),
            ),
            // Starting a handover goes back to the pot's profile, archive
            // or delete to its settings.
            AppTab.chat when open.startsWith('handover-new:') =>
              potProfileLocation(open.substring('handover-new:'.length)),
            AppTab.chat when open.startsWith('retire:') => potSettingsLocation(
              open.substring('retire:'.length),
            ),
            _ => tab.path,
          });
        }
      },
      child: PushDrawer(
        open: ref.watch(drawerOpenProvider),
        onClose: ref.read(drawerOpenProvider.notifier).close,
        closeLabel: l10n.closeDrawer,
        drawer: const AppDrawer(),
        child: AdaptiveScaffold(
          destinations: [
            PircDestination(
              icon: LucideIcons.messageCircle,
              label: l10n.tabChat,
              badge: ref.watch(chatBadgeProvider),
            ),
            PircDestination(
              icon: LucideIcons.briefcase,
              label: l10n.tabWork,
              badge: ref.watch(workBadgeProvider),
            ),
            PircDestination(
              icon: LucideIcons.activity,
              label: l10n.tabActivity,
            ),
            PircDestination(
              icon: LucideIcons.calendar,
              label: l10n.tabCalendar,
            ),
          ],
          selectedIndex: tab.index,
          onDestinationSelected: (index) => shell?.goBranch(
            index,
            initialLocation: index == shell.currentIndex,
          ),
          list: switch (tab) {
            AppTab.chat => ChatListScreen(openId: open),
            AppTab.work => WorkListScreen(
              openId: open,
              onNew: () => context.go('/work?open=$newConversationKey'),
            ),
            AppTab.calendar => const CalendarScreen(),
            _ => const _TabList(),
          },
          content: open == null
              ? null
              : switch (tab) {
                  AppTab.work when open.startsWith('project:') => ProjectScreen(
                    key: ValueKey(open),
                    workspaceId: open.substring('project:'.length),
                    showBack: !desktop,
                  ),
                  AppTab.work when open == newConversationKey =>
                    NewConversationScreen(
                      key: const ValueKey(newConversationKey),
                      showBack: !desktop,
                    ),
                  AppTab.work => WorkConversation(
                    key: ValueKey(open),
                    sessionId: open,
                    showBack: !desktop,
                  ),
                  AppTab.chat when open.startsWith('settings:') =>
                    PotSettingsScreen(
                      key: ValueKey(open),
                      potId: open.substring('settings:'.length),
                      section: location?.queryParameters['section'],
                    ),
                  AppTab.chat when open.startsWith('handover-new:') =>
                    HandoverScreen.start(
                      key: ValueKey(open),
                      potId: open.substring('handover-new:'.length),
                    ),
                  AppTab.chat when open.startsWith('handover:') =>
                    HandoverScreen.existing(
                      key: ValueKey(open),
                      handoverId: open.substring('handover:'.length),
                    ),
                  AppTab.chat when open.startsWith('retire:') => RetireScreen(
                    key: ValueKey(open),
                    potId: open.substring('retire:'.length),
                  ),
                  AppTab.chat when open == newPotKey => NewPotScreen(
                    key: const ValueKey(newPotKey),
                    showBack: !desktop,
                  ),
                  AppTab.chat when open == newGroupKey => NewGroupScreen(
                    key: const ValueKey(newGroupKey),
                    showBack: !desktop,
                  ),
                  // A pot's conversation, a direct thread by its ID (a
                  // deleted pot's, read-only) or a group by its ID. A pot
                  // DM (step 10) keeps the placeholder.
                  AppTab.chat
                      when open.startsWith('pot:') || !open.contains(':') =>
                    PotConversationScreen(
                      key: ValueKey(open),
                      chatKey: open,
                      showBack: !desktop,
                      otherThread: (context, thread) => thread.isGroup
                          ? GroupConversationScreen(
                              threadId: open,
                              showBack: !desktop,
                            )
                          : _ItemPlaceholder(
                              title: l10n.openItem(open),
                              onBack: () => context.go(tab.path),
                            ),
                    ),
                  AppTab.calendar => CalendarDetail(
                    key: ValueKey(open),
                    itemId: open,
                    showBack: !desktop,
                  ),
                  _ => _ItemPlaceholder(
                    key: ValueKey(open),
                    title: l10n.openItem(open),
                    onBack: () => context.go(tab.path),
                  ),
                },
          side: open == null || side == null
              ? null
              : tab == AppTab.work
              ? workSide(context, open, side!)
              : tab == AppTab.chat &&
                    side == profileSide &&
                    open.startsWith('pot:')
              ? PotProfileScreen(
                  key: ValueKey('profile:$open'),
                  potId: open.substring('pot:'.length),
                  closeIcon: desktop,
                  onClose: () => context.go(chatLocation(open)),
                )
              : tab == AppTab.chat &&
                    side == groupInfoSide &&
                    !open.contains(':')
              ? GroupInfoScreen(
                  key: ValueKey('group-info:$open'),
                  threadId: open,
                  closeIcon: desktop,
                  onClose: () => context.go(chatLocation(open)),
                )
              : null,
          // Rule C makes work panels a page below 900; information about a
          // chat item slides in from the right at 600–899 (E spec § 9).
          sideFullPage: tab == AppTab.work,
          placeholder: _Empty(text: l10n.nothingOpen),
        ),
      ),
    );
    final at = location;
    return at == null ? page : _DecisionOpener(location: at, child: page);
  }
}

/// Opens the sheet of `approval=<id>` or `budget=<id>` once and takes the
/// parameter out of the location, so Back and a rebuild do not open it
/// again.
class _DecisionOpener extends StatefulWidget {
  const _DecisionOpener({required this.location, required this.child});

  final Uri location;
  final Widget child;

  @override
  State<_DecisionOpener> createState() => _DecisionOpenerState();
}

class _DecisionOpenerState extends State<_DecisionOpener> {
  @override
  void initState() {
    super.initState();
    _check();
  }

  @override
  void didUpdateWidget(_DecisionOpener old) {
    super.didUpdateWidget(old);
    if (old.location != widget.location) _check();
  }

  void _check() {
    final params = widget.location.queryParameters;
    final approval = params['approval'], budget = params['budget'];
    if (approval == null && budget == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final rest = {...params}
        ..remove('approval')
        ..remove('budget');
      context.go(
        Uri(
          path: widget.location.path,
          queryParameters: rest.isEmpty ? null : rest,
        ).toString(),
      );
      if (approval != null) {
        showApprovalSheet(context, approval);
      } else {
        showBudgetRequestSheet(context, budget!);
      }
    });
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// The Activity tab until M7 step 10 builds it.
class _TabList extends StatelessWidget {
  const _TabList();

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(
        leading: const DrawerButton(),
        title: Text(l10n.tabActivity),
      ),
      body: _Empty(text: l10n.emptyActivity),
    );
  }
}

/// An open Chat or Activity item whose screen is not built yet.
class _ItemPlaceholder extends StatelessWidget {
  const _ItemPlaceholder({
    super.key,
    required this.title,
    required this.onBack,
  });

  final String title;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(title),
        leading: IconButton(
          tooltip: l10n.back,
          icon: const Icon(LucideIcons.arrowLeft),
          onPressed: onBack,
        ),
      ),
      body: const SizedBox.expand(),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(PircSpacing.stackXl),
      child: Text(
        text,
        textAlign: TextAlign.center,
        style: Theme.of(context).textTheme.bodySmall,
      ),
    ),
  );
}
