import 'package:flutter/material.dart' hide DrawerButton;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:pirc_ui/pirc_ui.dart';

import '../l10n/app_localizations.dart';
import 'calendar/calendar_detail.dart';
import 'calendar/calendar_screen.dart';
import 'router.dart';
import 'shell/app_drawer.dart';
import 'work/new_conversation/new_conversation_screen.dart';
import 'work/project_screen.dart';
import 'work/work_conversation.dart';
import 'work/work_side.dart';
import 'work/work_data.dart';
import 'work/work_list_screen.dart';

/// One tab in the adaptive frame: the Work and Calendar lists and items;
/// Chat and Activity stay placeholders until M7.
class TabScreen extends ConsumerWidget {
  const TabScreen({super.key, required this.tab, this.openItem, this.side});

  final AppTab tab;
  final String? openItem;

  /// What the side pane shows (`result:<id>`, `panel:<section>`).
  final String? side;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final shell = StatefulNavigationShell.maybeOf(context);
    final desktop =
        PircLayout.forWidth(MediaQuery.sizeOf(context).width) ==
        PircLayout.desktop;
    final open = openItem;
    return PopScope(
      // Back closes the open item first (one-pane layouts show it alone).
      canPop: open == null,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && open != null) {
          context.go(tab == AppTab.work ? workBackLocation(context) : tab.path);
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
            AppTab.work => WorkListScreen(
              openId: open,
              onNew: () => context.go('/work?open=$newConversationKey'),
            ),
            AppTab.calendar => const CalendarScreen(),
            _ => _TabList(tab: tab),
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
          side: tab == AppTab.work && open != null && side != null
              ? workSide(context, open, side!)
              : null,
          sideFullPage: true,
          placeholder: _Empty(text: l10n.nothingOpen),
        ),
      ),
    );
  }
}

/// The Chat and Activity tabs until M7 builds them.
class _TabList extends StatelessWidget {
  const _TabList({required this.tab});

  final AppTab tab;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final (title, empty) = switch (tab) {
      AppTab.chat => (l10n.tabChat, l10n.emptyChat),
      _ => (l10n.tabActivity, l10n.emptyActivity),
    };
    return Scaffold(
      appBar: AppBar(leading: const DrawerButton(), title: Text(title)),
      body: _Empty(text: empty),
    );
  }
}

/// An open Chat or Activity item until M7.
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
