import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'connection/connection.dart';
import 'connection/connection_screens.dart';
import 'me/me_screen.dart';
import 'preferences.dart';
import 'settings/basic_pages.dart';
import 'settings/device_page.dart';
import 'settings/devices_page.dart';
import 'settings/more_pages.dart';
import 'settings/pots_page.dart';
import 'settings/providers_page.dart';
import 'settings/settings_screen.dart';
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

/// Where the router starts (the start tab setting); tests override it.
final initialLocationProvider = Provider<String>(
  (ref) => ref.read(startTabProvider),
);

/// Pages shown instead of the app while the connection needs something.
const _gatePaths = {'/pair', '/upgrade', '/signed-out'};

/// The page the connection [phase] requires, or null when the app may show
/// any page.
String? gateFor(ConnectionPhase phase) => switch (phase) {
  ConnectionPhase.unpaired => '/pair',
  ConnectionPhase.upgradeRequired => '/upgrade',
  ConnectionPhase.signedOut => '/signed-out',
  _ => null,
};

/// Each tab is one page whose open item is the `open` query parameter, so
/// opening or closing an item updates the page instead of pushing another
/// one: the list keeps its state in every layout.
final routerProvider = Provider<GoRouter>((ref) {
  final phase = ValueNotifier(ref.read(connectionProvider).phase);
  ref.listen(
    connectionProvider.select((status) => status.phase),
    (_, next) => phase.value = next,
  );
  final router = GoRouter(
    initialLocation: ref.watch(initialLocationProvider),
    refreshListenable: phase,
    redirect: (context, state) {
      final gate = gateFor(phase.value);
      final here = state.matchedLocation;
      if (gate != null) return here == gate ? null : gate;
      if (_gatePaths.contains(here)) return ref.read(startTabProvider);
      // `/` is only the Web build's management approval screen.
      if (here == '/' &&
          !(ref.read(isWebProvider) &&
              state.uri.queryParameters.containsKey('nativeManagement'))) {
        return ref.read(startTabProvider);
      }
      return null;
    },
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
                      side: state.uri.queryParameters['side'],
                      location: state.uri,
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
      GoRoute(
        path: meLocation,
        builder: (context, state) =>
            MeScreen(chart: state.uri.queryParameters['chart']),
      ),
      GoRoute(
        path: '/pair',
        builder: (context, state) => const PairingScreen(),
      ),
      GoRoute(
        path: '/',
        builder: (context, state) => ManagementApprovalScreen(
          requestId: state.uri.queryParameters['nativeManagement'] ?? '',
        ),
      ),
      for (final (path, page) in [
        ('device', const ThisDevicePage()),
        ('devices', const DevicesPage()),
        ('general', const GeneralPage()),
        ('account', const AccountPage()),
        ('about', const AboutPage()),
        ('providers', const ProvidersPage()),
        ('pots', const PotsSettingsPage()),
        ('memory', const MemoryPage()),
        ('notifications', const NotificationsPage()),
        ('calendar', const CalendarAccessPage()),
        ('modes', const ModesPage()),
      ])
        GoRoute(path: '/settings/$path', builder: (context, state) => page),
      GoRoute(
        path: '/upgrade',
        builder: (context, state) => const UpgradeScreen(),
      ),
      GoRoute(
        path: '/signed-out',
        builder: (context, state) => const SignedOutScreen(),
      ),
    ],
  );
  ref.onDispose(router.dispose);
  ref.onDispose(phase.dispose);
  return router;
});
