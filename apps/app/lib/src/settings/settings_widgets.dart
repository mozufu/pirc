import 'package:flutter/material.dart';
import 'package:pirc_ui/pirc_ui.dart';

/// The app version; `test/version_test.dart` keeps it equal to pubspec.yaml.
const appVersion = '0.10.0';

/// A settings page: at most 720 wide, grouped rows on `surface.grouped`.
class SettingsPage extends StatelessWidget {
  const SettingsPage({
    super.key,
    required this.title,
    required this.children,
    this.actions,
  });

  final String title;
  final List<Widget> children;
  final List<Widget>? actions;

  @override
  Widget build(BuildContext context) {
    final colors = PircColorTokens.of(context);
    return Scaffold(
      backgroundColor: colors['surface.grouped'],
      appBar: AppBar(
        title: Text(title),
        backgroundColor: colors['surface.grouped'],
        actions: actions,
      ),
      body: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: ListView(
            padding: const EdgeInsets.only(bottom: PircSpacing.stackXl),
            children: children,
          ),
        ),
      ),
    );
  }
}

/// `c-group`: a titled group of rows on `surface.layer`, radius 16.
class SettingsGroup extends StatelessWidget {
  const SettingsGroup({super.key, this.title, required this.children});

  final String? title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final colors = PircColorTokens.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (title != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(
              PircSpacing.gutterGroupedText,
              PircSpacing.stackXl,
              PircSpacing.gutterGroupedText,
              PircSpacing.stackSm,
            ),
            child: Text(title!, style: Theme.of(context).textTheme.labelMedium),
          )
        else
          const SizedBox(height: PircSpacing.stackLg),
        Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: PircSpacing.gutterPhone,
          ),
          child: Material(
            color: colors['surface.layer'],
            borderRadius: BorderRadius.circular(PircRadius.lg),
            clipBehavior: Clip.antiAlias,
            child: Column(
              children: [
                for (final (i, child) in children.indexed) ...[
                  if (i > 0)
                    Divider(
                      height: 1,
                      indent: PircSpacing.gutterPhone,
                      color: colors['line.hairline'],
                    ),
                  child,
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// A row with a check mark when selected.
class ChoiceRow extends StatelessWidget {
  const ChoiceRow({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => ListTile(
    title: Text(label),
    selected: selected,
    trailing: selected ? const Icon(Icons.check) : null,
    onTap: onTap,
  );
}
