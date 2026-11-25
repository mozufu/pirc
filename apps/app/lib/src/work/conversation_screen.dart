import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:pirc_client/pirc_client.dart';
import 'package:pirc_ui/pirc_ui.dart';

import '../../l10n/app_localizations.dart';
import '../connection/data.dart';
import 'session_controller.dart';
import 'timeline.dart';

/// Extra parts of the conversation that later steps add (composer, panels,
/// the From line). Kept as builders so this screen stays small.
class ConversationParts {
  const ConversationParts({
    this.bottom,
    this.banner,
    this.footer,
    this.messageBuilder,
    this.actions,
    this.onTitleTap,
  });

  /// Under the timeline (the composer).
  final Widget Function(BuildContext context, SessionView view)? bottom;

  /// Under the top bar (the pot bar, transitions).
  final Widget? Function(BuildContext context, SessionView view)? banner;

  /// Below the last message (question cards).
  final List<Widget> Function(BuildContext context, SessionView view)? footer;
  final MessageBuilder? messageBuilder;

  /// Top bar actions (the panel button).
  final List<Widget> Function(BuildContext context, SessionView view)? actions;

  /// A tap on the name and environment line (the workspace sheet).
  final VoidCallback? onTitleTap;
}

/// A work conversation: top bar, the timeline and what is below it.
class ConversationScreen extends ConsumerWidget {
  const ConversationScreen({
    super.key,
    required this.sessionId,
    this.parts = const ConversationParts(),
    this.showBack = true,
  });

  final String sessionId;
  final ConversationParts parts;

  /// False at 1200 and wider, where the list stays beside the conversation.
  final bool showBack;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final view = ref.watch(sessionControllerProvider(sessionId));
    final listed = ref
        .watch(sessionsProvider)
        .value
        ?.where((s) => s.id == sessionId)
        .firstOrNull;
    final session = view.state?.session ?? listed;
    final state = view.state;
    final Widget body;
    if (view.deleted) {
      body = _Note(text: l10n.sessionDeleted);
    } else if (state == null) {
      body = view.error == null
          ? const Center(child: CircularProgressIndicator())
          : _Note(
              text: l10n.sessionFailed,
              action: OutlinedButton(
                onPressed: () => ref
                    .read(sessionControllerProvider(sessionId).notifier)
                    .reload(),
                child: Text(l10n.retry),
              ),
            );
    } else {
      body = WorkTimeline(
        messages: state.messages,
        footer: parts.footer?.call(context, view) ?? const [],
        questionWaiting: state.interactions.any((i) => i.status == 'pending'),
        messageBuilder: parts.messageBuilder,
      );
    }
    final banner = state == null ? null : parts.banner?.call(context, view);
    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: false,
        leading: showBack
            ? IconButton(
                tooltip: l10n.back,
                icon: const Icon(LucideIcons.chevronLeft),
                onPressed: () => context.go('/work'),
              )
            : null,
        centerTitle: true,
        title: session == null
            ? null
            : InkWell(
                key: const Key('environment-line'),
                onTap: parts.onTitleTap,
                child: _Title(session: session),
              ),
        actions: state == null ? null : parts.actions?.call(context, view),
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ?banner,
          if (view.partialOutputLost)
            Padding(
              padding: const EdgeInsets.all(PircSpacing.stackSm),
              child: Text(
                l10n.partialOutputLost,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          Expanded(child: body),
          if (state != null && !view.deleted) ...[
            if (view.control == ControlState.other)
              ControlBar(sessionId: sessionId),
            ?parts.bottom?.call(context, view),
          ],
        ],
      ),
    );
  }
}

/// The name and the environment line: state dot, project and host.
class _Title extends ConsumerWidget {
  const _Title({required this.session});
  final Session session;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final text = Theme.of(context).textTheme;
    final project = ref
        .watch(workspacesProvider)
        .value
        ?.where((w) => w.id == session.workspaceId)
        .firstOrNull
        ?.displayName;
    final hostOnline =
        session.nodeId != null &&
        (ref.watch(nodesProvider).value?.any((n) => n.id == session.nodeId) ??
            true);
    final line = [?project, ?session.nodeId].join(' · ');
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          session.name,
          style: text.titleSmall,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        if (line.isNotEmpty)
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              StateDot(hostOnline ? DotState.done : DotState.idle),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  line,
                  style: text.labelSmall,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
      ],
    );
  }
}

/// Another client controls the session: the composer is read-only and
/// "Take control" acquires the lease with `force`.
class ControlBar extends ConsumerWidget {
  const ControlBar({super.key, required this.sessionId});
  final String sessionId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final colors = PircColorTokens.of(context);
    return Material(
      color: colors['surface.subtle'],
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: PircSpacing.gutterPhone,
            vertical: PircSpacing.stackSm,
          ),
          child: Row(
            children: [
              Icon(
                LucideIcons.monitorSmartphone,
                size: PircSize.iconRow,
                color: colors['text.secondary'],
              ),
              const SizedBox(width: PircSpacing.stackSm),
              Expanded(
                child: Text(
                  l10n.controlledElsewhere,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
              TextButton(
                onPressed: () => ref
                    .read(sessionControllerProvider(sessionId).notifier)
                    .takeControl(force: true),
                child: Text(l10n.takeControl),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Note extends StatelessWidget {
  const _Note({required this.text, this.action});
  final String text;
  final Widget? action;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(PircSpacing.stackXl),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            text,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodySmall,
          ),
          if (action != null) ...[
            const SizedBox(height: PircSpacing.stackSm),
            action!,
          ],
        ],
      ),
    ),
  );
}
