import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:pirc_client/pirc_client.dart';
import 'package:pirc_ui/pirc_ui.dart';

import '../../l10n/app_localizations.dart';
import '../connection/connection.dart';
import '../connection/data.dart';
import '../connection/hints.dart';
import '../work/work_data.dart';
import 'chat_data.dart';
import 'chat_list_screen.dart';
import 'group_data.dart';
import 'pot_conversation_screen.dart';
import 'thread_cards.dart';
import 'thread_data.dart';
import 'thread_view.dart';

/// A group's conversation (E33): the header (the group's avatar, name and
/// members with the host; it opens the group's info), each pot's bubble
/// with its avatar and name (the host tagged), the user's on the right,
/// notices and cards as in a pot's conversation. The composer's @ opens
/// the members (E34) with their reach and budget, and "@all"; without a
/// mention the host answers. Opened by the group's thread ID.
class GroupConversationScreen extends ConsumerStatefulWidget {
  const GroupConversationScreen({
    super.key,
    required this.threadId,
    this.showBack = true,
  });

  final String threadId;

  /// False at 1200 and wider, where the list stays beside it.
  final bool showBack;

  @override
  ConsumerState<GroupConversationScreen> createState() =>
      _GroupConversationScreenState();
}

class _GroupConversationScreenState
    extends ConsumerState<GroupConversationScreen> {
  String? _postError;
  List<RefusedWake> _refused = const [];
  GroupTargets _targets = const GroupTargets();
  bool _mentionOpen = false;

  ThreadController get _controller =>
      ref.read(threadControllerProvider(widget.threadId).notifier);

  /// The member pots' IDs, as last built (targets outside them are not
  /// shown and not sent).
  List<String> _memberIds = const [];

  Future<bool> _send(String body) async {
    final targets = _targets.within(_memberIds);
    setState(() {
      _postError = null;
      _refused = const [];
      _mentionOpen = false;
    });
    try {
      final posted = await _controller.post(
        body,
        mentions: targets.all ? const [] : targets.mentions,
        all: targets.all,
      );
      if (mounted) {
        setState(() {
          _refused = posted.refused;
          _targets = const GroupTargets();
        });
      }
      return true;
    } on PircException catch (error) {
      if (mounted) setState(() => _postError = error.message);
      return false;
    } on NotConnected {
      return false;
    }
  }

  void _pick(String? potId) => setState(() {
    _targets = _targets.pick(potId);
    _mentionOpen = false;
  });

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final colors = PircColorTokens.of(context);
    // The members' names and states change with the pots.
    ref.listen(
      hintRevisionsProvider.select((r) => r['pots_changed'] ?? 0),
      (_, _) => _controller.refresh(),
    );
    final view = ref.watch(threadControllerProvider(widget.threadId));
    final thread = view.thread;
    final pots = ref.watch(potsProvider).value ?? const <PotSummary>[];
    final members = thread == null
        ? const <PotSummary>[]
        : groupMembers(thread, pots);
    final host = members.where((p) => p.id == thread?.hostPotId).firstOrNull;
    _memberIds = [for (final p in members) p.id];
    final targets = _targets.within(_memberIds);
    final online =
        ref.watch(appConnectionStateProvider) == AppConnectionState.online;
    String nameOf(String id) =>
        members.where((p) => p.id == id).firstOrNull?.name ?? '';

    final Widget list;
    if (!view.loaded) {
      list = view.error == null || view.error is NotConnected
          ? const Center(child: CircularProgressIndicator())
          : Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                spacing: 8,
                children: [
                  Text(l10n.threadFailed),
                  OutlinedButton(
                    onPressed: _controller.refresh,
                    child: Text(l10n.retry),
                  ),
                ],
              ),
            );
    } else {
      list = ThreadMessageList(
        view: view,
        avatarOf: (message) => MessageAvatar(message: message, deletedName: ''),
        nameOf: (message) => message.authorDeleted
            ? message.authorName
            : potById(ref, message.authorId)?.name ?? message.authorName,
        hostLabelOf: (message) =>
            !message.authorDeleted &&
                message.authorId != null &&
                message.authorId == thread?.hostPotId
            ? l10n.groupHostTag
            : null,
        mineTextOf: (message) => mentionText(context, message, nameOf),
        onLoadOlder: _controller.loadOlder,
        onNewestShown: _controller.markNewestRead,
      );
    }

    final full = watchFullPots(ref, [for (final p in members) p.id]);
    final popover = MentionPopover<String?>(
      key: const ValueKey('group-mentions'),
      header: l10n.groupMentionHeader,
      semanticLabel: l10n.groupMentionLabel,
      onSelected: _pick,
      options: [
        for (final pot in members)
          MentionOption(
            value: pot.id,
            avatar: PotAvatar(pot: pot, size: AvatarSize.md),
            name: pot.name,
            detail: potReachBudgetLine(l10n, pot, full[pot.id]),
            hostLabel: pot.id == thread?.hostPotId ? l10n.groupHostTag : null,
          ),
        MentionOption(
          value: null,
          avatar: const _EveryoneAvatar(),
          name: l10n.groupMentionAll,
          detail: l10n.groupMentionAllWarning,
        ),
      ],
    );

    final names = [
      if (targets.all) l10n.groupMentionAll,
      for (final id in targets.mentions) nameOf(id),
    ];
    final hint = names.isNotEmpty
        ? l10n.groupComposerTo(names.join(l10n.potListSeparator))
        : host != null
        ? l10n.groupComposerHint(host.name)
        : l10n.groupComposerHintNoHost;
    final notes = [
      ?_postError,
      for (final wake in _refused)
        l10n.threadRefused(
          potById(ref, wake.potId)?.name ?? wake.potId,
          wake.reason.isNotEmpty ? wake.reason : wake.code,
        ),
      if (!online) l10n.composerOffline,
    ];
    final bottom = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final note in notes)
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
            child: Text(
              note,
              style: TextStyle(
                fontSize: 12.5,
                height: 18 / 12.5,
                color: note == l10n.composerOffline
                    ? colors['text.muted']
                    : colors['status.danger'],
              ),
            ),
          ),
        ThreadComposer(
          hint: hint,
          enabled: online && view.loaded,
          onSend: _send,
          above: targets.isEmpty
              ? null
              : _TargetRow(
                  targets: [
                    if (targets.all) (null, l10n.groupMentionAll),
                    for (final id in targets.mentions) (id, nameOf(id)),
                  ],
                  onRemove: (id) =>
                      setState(() => _targets = _targets.remove(id)),
                ),
          tools: [
            Semantics(
              expanded: _mentionOpen,
              child: SizedBox.square(
                dimension: PircSize.composerButton,
                child: IconButton(
                  key: const ValueKey('group-mention'),
                  tooltip: l10n.groupMention,
                  padding: EdgeInsets.zero,
                  color: colors['text.secondary'],
                  onPressed: view.loaded && members.isNotEmpty
                      ? () => setState(() => _mentionOpen = !_mentionOpen)
                      : null,
                  icon: const Icon(LucideIcons.atSign, size: 21),
                ),
              ),
            ),
          ],
        ),
      ],
    );

    final memberLine = [
      l10n.chatAuthorYou,
      for (final pot in members)
        pot.id == thread?.hostPotId ? l10n.groupMemberHost(pot.name) : pot.name,
    ].join(l10n.potListSeparator);
    final openInfo = thread == null
        ? null
        : () => context.go(groupInfoLocation(thread.id));
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): () {
          if (_mentionOpen) setState(() => _mentionOpen = false);
        },
      },
      child: Scaffold(
        backgroundColor: colors['surface.page'],
        body: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ThreadHeader(
              avatar: thread == null
                  ? const SizedBox.square(dimension: 36)
                  : GroupThreadAvatar.of(
                      thread,
                      members: members,
                      size: AvatarSize.md,
                    ),
              name: thread?.name ?? '',
              line: thread == null ? '' : memberLine,
              showBack: widget.showBack,
              onOpen: openInfo,
              openTooltip: l10n.groupInfo,
            ),
            Expanded(
              child: Stack(
                children: [
                  Positioned.fill(child: list),
                  if (_mentionOpen) ...[
                    Positioned.fill(
                      child: GestureDetector(
                        key: const ValueKey('group-mentions-barrier'),
                        behavior: HitTestBehavior.opaque,
                        onTap: () => setState(() => _mentionOpen = false),
                      ),
                    ),
                    Positioned(left: 12, right: 12, bottom: 0, child: popover),
                  ],
                ],
              ),
            ),
            SafeArea(top: false, child: bottom),
          ],
        ),
      ),
    );
  }
}

/// The text of the user's bubble in a group: the mentions (`e-at`, or
/// "@Everyone") in front of the body.
Object mentionText(
  BuildContext context,
  ThreadMessage message,
  String Function(String potId) nameOf,
) {
  final names = [
    if (message.all) AppLocalizations.of(context).groupMentionAll,
    for (final id in message.mentions)
      if (nameOf(id).isNotEmpty) nameOf(id),
  ];
  if (names.isEmpty) return message.body;
  return TextSpan(
    children: [
      for (final name in names) ...[
        Bubble.mention(context, '@$name'),
        const TextSpan(text: ' '),
      ],
      TextSpan(text: message.body),
    ],
  );
}

/// "@all"'s avatar: the neutral fill with the people icon.
class _EveryoneAvatar extends StatelessWidget {
  const _EveryoneAvatar();

  @override
  Widget build(BuildContext context) {
    final colors = PircColorTokens.of(context);
    return Container(
      width: 36,
      height: 36,
      decoration: BoxDecoration(
        color: colors['fill.hoverStrong'],
        shape: BoxShape.circle,
      ),
      child: Icon(LucideIcons.users, size: 20, color: colors['text.secondary']),
    );
  }
}

/// `d-targetrow`: "To" and a pill (`d-target`) per target; tapping one
/// takes it out.
class _TargetRow extends StatelessWidget {
  const _TargetRow({required this.targets, required this.onRemove});

  /// (pot ID or null for everyone, name).
  final List<(String?, String)> targets;
  final ValueChanged<String?> onRemove;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final colors = PircColorTokens.of(context);
    return Padding(
      key: const ValueKey('group-targets'),
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 0),
      child: Wrap(
        spacing: 6,
        runSpacing: 6,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Text(
            l10n.groupTargetTo,
            style: TextStyle(
              fontSize: 12.5,
              height: 18 / 12.5,
              color: colors['text.muted'],
            ),
          ),
          for (final (id, name) in targets)
            Semantics(
              button: true,
              label: l10n.groupTargetRemove(name),
              excludeSemantics: true,
              child: Material(
                color: colors['fill.hover'],
                shape: const StadiumBorder(),
                child: InkWell(
                  key: ValueKey('group-target-${id ?? 'all'}'),
                  customBorder: const StadiumBorder(),
                  onTap: () => onRemove(id),
                  child: Container(
                    height: 30,
                    constraints: const BoxConstraints(maxWidth: 200),
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      spacing: 5,
                      children: [
                        Flexible(
                          child: Text(
                            name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 12.5,
                              fontWeight: FontWeight.w500,
                              color: colors['text.primary'],
                            ),
                          ),
                        ),
                        Icon(
                          LucideIcons.x,
                          size: 12,
                          color: colors['text.muted'],
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
