import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:pirc_ui/pirc_ui.dart';

import '../../../l10n/app_localizations.dart';
import 'browser_panel.dart';
import 'checkpoints_panel.dart';
import 'context_panel.dart';
import 'files_panel.dart';
import 'git_panel.dart';
import 'tasks_panel.dart';
import 'terminal_panel.dart';

enum PanelSection {
  files,
  git,
  terminal,
  tasks,
  browser,
  context,
  checkpoints;

  static PanelSection? parse(String name) =>
      values.where((s) => s.name == name).firstOrNull;
}

/// The `side` value that opens [section] beside the conversation.
String panelSide(PanelSection section) => 'panel:${section.name}';

/// The work panels: five tabs, then "More" for Context and Checkpoints
/// (default F). A panel loads when it opens and again when a
/// `panel_changed` names its section.
class PanelContainer extends StatelessWidget {
  const PanelContainer({
    super.key,
    required this.sessionId,
    required this.section,
    required this.onSelect,
    required this.onClose,
  });

  final String sessionId;
  final PanelSection section;
  final ValueChanged<PanelSection> onSelect;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          tooltip: l10n.close,
          icon: const Icon(LucideIcons.x),
          onPressed: onClose,
        ),
        title: Text(l10n.panelsTitle),
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PanelTabs<PanelSection>(
            selected: section,
            onSelected: onSelect,
            moreLabel: l10n.panelMore,
            moreIcon: LucideIcons.ellipsis,
            tabs: [
              PanelTab(PanelSection.files, LucideIcons.folder, l10n.panelFiles),
              PanelTab(PanelSection.git, LucideIcons.gitBranch, l10n.panelGit),
              PanelTab(
                PanelSection.terminal,
                LucideIcons.squareTerminal,
                l10n.panelTerminal,
              ),
              PanelTab(
                PanelSection.tasks,
                LucideIcons.listChecks,
                l10n.panelTasks,
              ),
              PanelTab(
                PanelSection.browser,
                LucideIcons.globe,
                l10n.panelBrowser,
              ),
            ],
            more: [
              PanelTab(
                PanelSection.context,
                LucideIcons.gauge,
                l10n.panelContext,
              ),
              PanelTab(
                PanelSection.checkpoints,
                LucideIcons.history,
                l10n.panelCheckpoints,
              ),
            ],
          ),
          Expanded(
            child: KeyedSubtree(
              key: ValueKey(section),
              child: switch (section) {
                PanelSection.files => FilesPanel(sessionId: sessionId),
                PanelSection.git => GitPanel(sessionId: sessionId),
                PanelSection.terminal => TerminalsPanel(sessionId: sessionId),
                PanelSection.tasks => TasksPanel(sessionId: sessionId),
                PanelSection.browser => BrowserPanel(sessionId: sessionId),
                PanelSection.context => ContextPanel(sessionId: sessionId),
                PanelSection.checkpoints => CheckpointsPanel(
                  sessionId: sessionId,
                ),
              },
            ),
          ),
        ],
      ),
    );
  }
}
