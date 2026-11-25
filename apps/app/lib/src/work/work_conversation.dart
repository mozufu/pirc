import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../l10n/app_localizations.dart';
import 'composer/composer.dart';
import 'composer/composer_controller.dart';
import 'conversation_screen.dart';
import 'panels/panel_container.dart';
import 'pot_bar.dart';
import 'questions.dart';
import 'result_reader.dart';
import 'session_controller.dart';
import 'work_data.dart';

/// A work conversation with everything the Work tab adds: the pot bar and
/// the From line, question cards, the approval mode and the composer.
class WorkConversation extends ConsumerWidget {
  const WorkConversation({
    super.key,
    required this.sessionId,
    this.showBack = true,
  });

  final String sessionId;
  final bool showBack;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    // While the pot work is open, only answers and Stop: the Gateway does
    // not refuse a user command first, so the app applies this rule.
    final coordinated =
        ref.watch(potWorkOfSessionProvider(sessionId))?.open ?? false;
    return ConversationScreen(
      sessionId: sessionId,
      showBack: showBack,
      parts: ConversationParts(
        banner: (context, view) => PotBar(sessionId: sessionId),
        messageBuilder: (context, message) =>
            potInstructionEntry(context, message) ??
            artifactEntry(sessionId)(context, message),
        footer: (context, view) => questionCards(sessionId, view),
        actions: (context, view) => [
          IconButton(
            tooltip: l10n.panelsOpen,
            icon: const Icon(LucideIcons.panelRight),
            onPressed: () => context.go(
              Uri(
                path: '/work',
                queryParameters: {
                  'open': sessionId,
                  'side': panelSide(PanelSection.files),
                },
              ).toString(),
            ),
          ),
          ApprovalModeButton(
            mode: view.state?.approvalMode,
            enabled: view.control == ControlState.mine && !coordinated,
            onSelected: (mode) => ref
                .read(composerProvider(sessionId).notifier)
                .setApprovalMode(mode),
          ),
        ],
        bottom: (context, view) => SessionComposer(
          sessionId: sessionId,
          view: view,
          messagesAllowed: !coordinated,
          lockedHint: l10n.composerLocked,
        ),
      ),
    );
  }
}
