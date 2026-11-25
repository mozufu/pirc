import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../l10n/app_localizations.dart';
import '../connection/connection.dart';
import '../preferences.dart';
import 'settings_widgets.dart';

/// General: language, appearance, text size and the tab the app opens on.
class GeneralPage extends ConsumerWidget {
  const GeneralPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final language = ref.watch(languageProvider);
    final mode = ref.watch(themeModeProvider);
    final scale = ref.watch(textScaleProvider);
    final start = ref.watch(startTabProvider);
    final languages = ref.read(languageProvider.notifier);
    final modes = ref.read(themeModeProvider.notifier);
    return SettingsPage(
      title: l10n.settingsGeneral,
      children: [
        SettingsGroup(
          title: l10n.language,
          children: [
            ChoiceRow(
              label: l10n.languageSystem,
              selected: language == null,
              onTap: () => languages.select(null),
            ),
            ChoiceRow(
              label: l10n.languageEnglish,
              selected: language == 'en',
              onTap: () => languages.select('en'),
            ),
            ChoiceRow(
              label: l10n.languageTraditionalChinese,
              selected: language == 'zh-TW',
              onTap: () => languages.select('zh-TW'),
            ),
          ],
        ),
        SettingsGroup(
          title: l10n.appearance,
          children: [
            for (final (value, label) in [
              (ThemeMode.system, l10n.appearanceSystem),
              (ThemeMode.light, l10n.appearanceLight),
              (ThemeMode.dark, l10n.appearanceDark),
            ])
              ChoiceRow(
                label: label,
                selected: mode == value,
                onTap: () => modes.select(value),
              ),
          ],
        ),
        SettingsGroup(
          title: l10n.textSize,
          children: [
            for (final (value, label) in [
              (0.9, l10n.textSmall),
              (1.0, l10n.textDefault),
              (1.15, l10n.textLarge),
              (1.3, l10n.textLarger),
            ])
              ChoiceRow(
                label: label,
                selected: scale == value,
                onTap: () => ref.read(textScaleProvider.notifier).select(value),
              ),
          ],
        ),
        SettingsGroup(
          title: l10n.startTab,
          children: [
            for (final (path, label) in [
              ('/chat', l10n.tabChat),
              ('/work', l10n.tabWork),
              ('/activity', l10n.tabActivity),
              ('/calendar', l10n.tabCalendar),
            ])
              ChoiceRow(
                label: label,
                selected: start == path,
                onTap: () => ref.read(startTabProvider.notifier).select(path),
              ),
          ],
        ),
      ],
    );
  }
}

/// Account and this device: the account name, the Gateway, and "Unpair this
/// device…" (native builds), which removes the token and local data.
class AccountPage extends ConsumerWidget {
  const AccountPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final connection = ref.watch(connectionProvider).connection;
    final web = ref.watch(isWebProvider);
    return SettingsPage(
      title: l10n.settingsAccount,
      children: [
        SettingsGroup(
          children: [
            ListTile(
              title: Text(l10n.accountName),
              trailing: Text(connection?.account ?? '—'),
            ),
            ListTile(
              title: Text(l10n.accountGateway),
              subtitle: Text(connection?.gateway.toString() ?? '—'),
            ),
          ],
        ),
        if (!web)
          SettingsGroup(
            children: [
              ListTile(
                title: Text(
                  l10n.unpair,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
                onTap: () async {
                  final sure = await showDialog<bool>(
                    context: context,
                    builder: (context) => AlertDialog(
                      title: Text(l10n.unpairTitle),
                      content: Text(l10n.unpairBody),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.pop(context, false),
                          child: Text(l10n.cancel),
                        ),
                        FilledButton(
                          onPressed: () => Navigator.pop(context, true),
                          child: Text(l10n.unpairConfirm),
                        ),
                      ],
                    ),
                  );
                  if (sure == true) {
                    await ref.read(connectionProvider.notifier).unpair();
                  }
                },
              ),
            ],
          ),
      ],
    );
  }
}

/// About: the app and Gateway versions, and the licences.
class AboutPage extends ConsumerWidget {
  const AboutPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final server = ref.watch(
      connectionProvider.select(
        (s) => s.connection?.capabilities.serverVersion,
      ),
    );
    return SettingsPage(
      title: l10n.settingsAbout,
      children: [
        SettingsGroup(
          children: [
            ListTile(
              title: Text(l10n.aboutApp),
              trailing: const Text(appVersion),
            ),
            ListTile(
              title: Text(l10n.aboutGateway),
              trailing: Text(server ?? '—'),
            ),
            ListTile(
              title: Text(l10n.aboutLicences),
              onTap: () => showLicensePage(
                context: context,
                applicationName: l10n.appTitle,
                applicationVersion: appVersion,
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// A row that opens a settings sub-page.
class SettingsLink extends StatelessWidget {
  const SettingsLink({
    super.key,
    required this.icon,
    required this.label,
    required this.path,
    this.subtitle,
  });

  final IconData icon;
  final String label;
  final String path;
  final String? subtitle;

  @override
  Widget build(BuildContext context) => ListTile(
    leading: Icon(icon, size: 20),
    title: Text(label),
    subtitle: subtitle == null ? null : Text(subtitle!),
    trailing: const Icon(Icons.chevron_right),
    onTap: () => context.push(path),
  );
}
