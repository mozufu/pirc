import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../l10n/app_localizations.dart';
import 'preferences.dart';

/// Language and appearance; the full settings pages come in M6.
class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final language = ref.watch(languageProvider);
    final mode = ref.watch(themeModeProvider);
    Widget choice(String label, bool selected, VoidCallback onTap) => ListTile(
      title: Text(label),
      trailing: selected ? const Icon(LucideIcons.check) : null,
      selected: selected,
      onTap: onTap,
    );
    final languages = ref.read(languageProvider.notifier);
    final modes = ref.read(themeModeProvider.notifier);
    return Scaffold(
      appBar: AppBar(title: Text(l10n.settings)),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: ListView(
            children: [
              ListTile(title: Text(l10n.language)),
              choice(
                l10n.languageSystem,
                language == null,
                () => languages.select(null),
              ),
              choice(
                l10n.languageEnglish,
                language == 'en',
                () => languages.select('en'),
              ),
              choice(
                l10n.languageTraditionalChinese,
                language == 'zh-TW',
                () => languages.select('zh-TW'),
              ),
              ListTile(title: Text(l10n.appearance)),
              choice(
                l10n.appearanceSystem,
                mode == ThemeMode.system,
                () => modes.select(ThemeMode.system),
              ),
              choice(
                l10n.appearanceLight,
                mode == ThemeMode.light,
                () => modes.select(ThemeMode.light),
              ),
              choice(
                l10n.appearanceDark,
                mode == ThemeMode.dark,
                () => modes.select(ThemeMode.dark),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
