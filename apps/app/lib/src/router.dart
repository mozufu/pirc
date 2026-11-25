import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'settings_screen.dart';
import 'tab_screen.dart';

/// The four tabs, in rail and tab-bar order.
enum AppTab {
  chat('/chat'),
  work('/work'),
  activity('/activity'),
  calendar('/calendar');

  const AppTab(this.path);
  final String path;
}

/// Where the router starts; tests override it.
final initialLocationProvider = Provider<String>((ref) => AppTab.chat.path);

/// Each tab is one page whose open item is the `open` query parameter, so
/// opening or closing an item updates the page instead of pushing another
/// one: the list keeps its state in every layout.
final routerProvider = Provider<GoRouter>((ref) {
  final router = GoRouter(
    initialLocation: ref.watch(initialLocationProvider),
    routes: [
      StatefulShellRoute.indexedStack(
        builder: (context, state, shell) => shell,
        branches: [
          for (final tab in AppTab.values)
            StatefulShellBranch(
              routes: [
                GoRoute(
                  path: tab.path,
                  pageBuilder: (context, state) => NoTransitionPage(
                    key: ValueKey(tab),
                    child: TabScreen(
                      tab: tab,
                      openItem: state.uri.queryParameters['open'],
                    ),
                  ),
                ),
              ],
            ),
        ],
      ),
      GoRoute(
        path: '/settings',
        builder: (context, state) => const SettingsScreen(),
      ),
    ],
  );
  ref.onDispose(router.dispose);
  return router;
});
