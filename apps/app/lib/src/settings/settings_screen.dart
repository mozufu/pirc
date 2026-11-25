import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../l10n/app_localizations.dart';
import '../connection/connection.dart';
import 'basic_pages.dart';
import 'settings_widgets.dart';

/// Settings (E22), opened from the drawer. A row is shown only when it does
/// something; the pots and usage rows are M7.
class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final account = ref.watch(
      connectionProvider.select((s) => s.connection?.account),
    );
    final web = ref.watch(isWebProvider);
    return SettingsPage(
      title: l10n.settings,
      children: [
        SettingsGroup(
          children: [
            SettingsLink(
              icon: LucideIcons.circleUser,
              label: l10n.settingsAccount,
              subtitle: account,
              path: '/settings/account',
            ),
          ],
        ),
        SettingsGroup(
          title: l10n.settingsAi,
          children: [
            SettingsLink(
              icon: LucideIcons.cpu,
              label: l10n.settingsProviders,
              path: '/settings/providers',
            ),
            SettingsLink(
              icon: LucideIcons.brain,
              label: l10n.settingsMemory,
              path: '/settings/memory',
            ),
            SettingsLink(
              icon: LucideIcons.layers,
              label: l10n.settingsModes,
              path: '/settings/modes',
            ),
          ],
        ),
        SettingsGroup(
          title: l10n.settingsNotificationsAndAccess,
          children: [
            SettingsLink(
              icon: LucideIcons.bell,
              label: l10n.settingsNotifications,
              path: '/settings/notifications',
            ),
            SettingsLink(
              icon: LucideIcons.calendarCog,
              label: l10n.settingsCalendar,
              path: '/settings/calendar',
            ),
            if (!web)
              SettingsLink(
                icon: LucideIcons.smartphone,
                label: l10n.settingsDevices,
                path: '/settings/devices',
              ),
          ],
        ),
        SettingsGroup(
          children: [
            SettingsLink(
              icon: LucideIcons.slidersHorizontal,
              label: l10n.settingsGeneral,
              path: '/settings/general',
            ),
            SettingsLink(
              icon: LucideIcons.info,
              label: l10n.settingsAbout,
              path: '/settings/about',
            ),
          ],
        ),
      ],
    );
  }
}
