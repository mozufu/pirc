import 'package:flutter/material.dart' hide DrawerButton;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:pirc_client/pirc_client.dart';
import 'package:pirc_ui/pirc_ui.dart';

import '../../l10n/app_localizations.dart';
import '../connection/connection.dart';
import '../connection/data.dart';
import '../connection/hints.dart';
import '../format.dart';
import '../shell/app_drawer.dart';
import '../work/work_data.dart';
import 'chat_data.dart';

/// The Chat tab's list (E1): pots and groups, newest first, with search
/// and filters; ＋ opens New (E6).
class ChatListScreen extends ConsumerWidget {
  const ChatListScreen({super.key, this.openId});

  /// The open thread, highlighted where the list stays visible.
  final String? openId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final text = Theme.of(context).textTheme;
    final colors = PircColorTokens.of(context);
    final filter = ref.watch(chatFilterProvider);
    final query = ref.watch(chatQueryProvider);
    final list = ref.watch(chatListProvider);
    final (dot, status) = switch (ref.watch(appConnectionStateProvider)) {
      AppConnectionState.online => (colors['status.success'], l10n.chatOnline),
      AppConnectionState.reconnecting || AppConnectionState.connecting => (
        colors['status.warning'],
        l10n.reconnecting,
      ),
      _ => (colors['text.faint'], l10n.chatOffline),
    };
    return Scaffold(
      appBar: AppBar(
        leading: const DrawerButton(),
        centerTitle: true,
        title: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(l10n.tabChat, style: text.titleSmall),
            Row(
              mainAxisSize: MainAxisSize.min,
              spacing: 5,
              children: [
                Container(
                  width: PircSize.stateDot,
                  height: PircSize.stateDot,
                  decoration: BoxDecoration(color: dot, shape: BoxShape.circle),
                ),
                Text(status, style: text.labelSmall),
              ],
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: l10n.chatNewTooltip,
            icon: const Icon(LucideIcons.userPlus),
            onPressed: () => showNewSheet(context, ref),
          ),
        ],
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
              PircSpacing.gutterPhone,
              PircSpacing.stackXs,
              PircSpacing.gutterPhone,
              PircSpacing.stackSm,
            ),
            child: _Search(hint: l10n.searchChat),
          ),
          FilterChips<ChatFilter>(
            selected: filter,
            onSelected: ref.read(chatFilterProvider.notifier).select,
            items: [
              FilterChipItem(ChatFilter.all, l10n.filterAll),
              FilterChipItem(ChatFilter.unread, l10n.chatFilterUnread),
              FilterChipItem(ChatFilter.pots, l10n.chatFilterPots),
              FilterChipItem(ChatFilter.groups, l10n.chatFilterGroups),
            ],
          ),
          Expanded(
            child: switch (list) {
              AsyncValue(:final value?) => _Rows(
                list: value,
                rows: value.shown(filter, query),
                filter: filter,
                searching: query.trim().isNotEmpty,
                openId: openId,
              ),
              AsyncValue(:final error?) when error is! NotConnected => _Failed(
                onRetry: () {
                  ref.invalidate(threadsProvider);
                  ref.invalidate(potsProvider);
                },
              ),
              _ => const Center(child: CircularProgressIndicator()),
            },
          ),
        ],
      ),
    );
  }
}

class _Search extends ConsumerStatefulWidget {
  const _Search({required this.hint});
  final String hint;

  @override
  ConsumerState<_Search> createState() => _SearchState();
}

class _SearchState extends ConsumerState<_Search> {
  late final _controller = TextEditingController(
    text: ref.read(chatQueryProvider),
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = PircColorTokens.of(context);
    return TextField(
      controller: _controller,
      onChanged: ref.read(chatQueryProvider.notifier).set,
      textInputAction: TextInputAction.search,
      decoration: InputDecoration(
        isDense: true,
        hintText: widget.hint,
        prefixIcon: const Icon(LucideIcons.search, size: PircSize.iconRow),
        filled: true,
        fillColor: colors['fill.hover'],
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(PircRadius.lg),
          borderSide: BorderSide.none,
        ),
      ),
    );
  }
}

class _Rows extends ConsumerWidget {
  const _Rows({
    required this.list,
    required this.rows,
    required this.filter,
    required this.searching,
    this.openId,
  });

  final ChatList list;
  final List<ChatEntry> rows;
  final ChatFilter filter;
  final bool searching;
  final String? openId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final text = Theme.of(context).textTheme;
    if (list.all.isEmpty && !searching) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(PircSpacing.stackXl),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                l10n.emptyChat,
                textAlign: TextAlign.center,
                style: text.bodySmall,
              ),
              const SizedBox(height: PircSpacing.stackMd),
              FilledButton(
                onPressed: () => context.go(chatLocation(newPotKey)),
                child: Text(l10n.chatNewPot),
              ),
            ],
          ),
        ),
      );
    }
    final add = switch (filter) {
      ChatFilter.pots => _AddRow(
        title: l10n.chatNewPot,
        onTap: () => context.go(chatLocation(newPotKey)),
      ),
      ChatFilter.groups => _AddRow(
        title: l10n.chatNewGroup,
        onTap: list.activePots >= 2
            ? () => context.go(chatLocation(newGroupKey))
            : null,
      ),
      _ => null,
    };
    if (rows.isEmpty && add == null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(PircSpacing.stackXl),
          child: Text(
            l10n.chatEmptyFilter,
            textAlign: TextAlign.center,
            style: text.bodySmall,
          ),
        ),
      );
    }
    return ListView(
      padding: const EdgeInsets.only(bottom: PircSpacing.stackXl),
      children: [
        for (final (index, entry) in rows.indexed)
          ChatEntryRow(
            key: ValueKey(entry.key),
            entry: entry,
            list: list,
            divider: index > 0,
            selected: entry.key == openId,
            previousSelected: index > 0 && rows[index - 1].key == openId,
          ),
        ?add,
      ],
    );
  }
}

/// One row of the Chat tab (`e-row`).
class ChatEntryRow extends ConsumerWidget {
  const ChatEntryRow({
    super.key,
    required this.entry,
    required this.list,
    this.divider = true,
    this.selected = false,
    this.previousSelected = false,
  });

  final ChatEntry entry;
  final ChatList list;
  final bool divider;
  final bool selected;
  final bool previousSelected;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final now = ref.watch(clockProvider)();
    final last = entry.thread?.lastMessage;
    final attention = entry.needsYou > 0;
    String? preview;
    if (last != null && last.firstLine.isNotEmpty) {
      final author = switch (last.authorKind) {
        'user' => l10n.chatAuthorYou,
        _ => list.authorName(last),
      };
      preview = entry is GroupChat && author != null
          ? l10n.chatPreviewBy(author, last.firstLine)
          : last.firstLine;
    }
    final (Widget avatar, String role) = switch (entry) {
      PotChat(:final pot) => (
        PotAvatar(pot: pot, withStatus: true),
        [
          if (pot.intro.isNotEmpty) pot.intro,
          if (pot.state == 'paused') l10n.potPaused,
        ].join(' · '),
      ),
      GroupChat(:final thread, :final members) => (
        GroupThreadAvatar(thread: thread, members: members),
        l10n.groupMemberCount(members.length),
      ),
    };
    return ChatRow(
      avatar: avatar,
      title: entry.name,
      role: role,
      time: listTime(context, entry.time, now: now),
      preview: preview ?? l10n.chatNoMessages,
      previewWarning: attention,
      previewLeading: attention ? const _Diamond() : null,
      badge: attention
          ? ChatBadge.attention('${entry.needsYou}')
          : entry.unread > 0
          ? ChatBadge.unread('${entry.unread}')
          : null,
      divider: divider,
      selected: selected,
      previousSelected: previousSelected,
      onTap: () => context.go(chatLocation(entry.key)),
    );
  }
}

/// A pot's avatar with its picture and, when [withStatus], its status.
class PotAvatar extends ConsumerWidget {
  const PotAvatar({
    super.key,
    required this.pot,
    this.size = AvatarSize.standard,
    this.withStatus = false,
  });

  final PotSummary pot;
  final AvatarSize size;
  final bool withStatus;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final status = withStatus
        ? switch (pot.status) {
            'working' => AvatarStatus.working,
            'unavailable' => AvatarStatus.unavailable,
            _ => AvatarStatus.none,
          }
        : AvatarStatus.none;
    return Avatar(
      name: pot.name,
      color: pot.avatarColor,
      size: size,
      image: watchAvatarImage(ref, pot.avatarImage),
      status: status,
      statusLabel: switch (status) {
        AvatarStatus.working => l10n.potWorking,
        AvatarStatus.unavailable => l10n.potUnavailable,
        AvatarStatus.none => null,
      },
    );
  }
}

/// A group's avatar: its picture, else two members stacked, else its
/// colour.
class GroupThreadAvatar extends ConsumerWidget {
  const GroupThreadAvatar({
    super.key,
    required this.thread,
    required this.members,
  });

  final PotThread thread;
  final List<PotSummary> members;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final picture = watchAvatarImage(ref, thread.avatarImage);
    if (picture == null && members.length >= 2) {
      AvatarFace face(PotSummary pot) => AvatarFace(
        pot.name,
        color: pot.avatarColor,
        image: watchAvatarImage(ref, pot.avatarImage),
      );
      return GroupAvatar(
        first: face(members[0]),
        second: face(members[1]),
        semanticLabel: thread.name,
      );
    }
    return Avatar(
      name: thread.name,
      color: thread.avatarColor ?? 1,
      image: picture,
    );
  }
}

/// The ◆ before a preview that waits on the user, in `text.warning`.
class _Diamond extends StatelessWidget {
  const _Diamond();

  @override
  Widget build(BuildContext context) => Transform.rotate(
    angle: 0.785398,
    child: Container(
      width: 9,
      height: 9,
      color: PircColorTokens.of(context)['text.warning'],
    ),
  );
}

/// `e-addrow`: "New pot" or "Create group" at the end of a filtered list.
class _AddRow extends StatelessWidget {
  const _AddRow({required this.title, this.onTap});

  final String title;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final colors = PircColorTokens.of(context);
    final enabled = onTap != null;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          spacing: 12,
          children: [
            Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                color: colors['fill.hover'],
                shape: BoxShape.circle,
              ),
              child: Icon(
                LucideIcons.plus,
                size: 20,
                color: colors[enabled ? 'text.secondary' : 'text.faint'],
              ),
            ),
            Text(
              title,
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w500,
                color: colors[enabled ? 'text.primary' : 'text.faint'],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Failed extends StatelessWidget {
  const _Failed({required this.onRetry});
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(l10n.listFailed, style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: PircSpacing.stackSm),
          OutlinedButton(onPressed: onRetry, child: Text(l10n.retry)),
        ],
      ),
    );
  }
}

/// New (E6): "New pot" and "Create group" (disabled with a note until two
/// pots exist).
Future<void> showNewSheet(BuildContext context, WidgetRef ref) async {
  final l10n = AppLocalizations.of(context);
  final pots = ref.read(potsProvider).value ?? const <PotSummary>[];
  final canGroup = pots.where((p) => p.state != 'archived').length >= 2;
  final choice = await showModalBottomSheet<String>(
    context: context,
    showDragHandle: true,
    builder: (context) {
      final text = Theme.of(context).textTheme;
      return SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 2),
              child: Text(
                l10n.newSheetTitle,
                style: text.titleLarge?.copyWith(fontWeight: FontWeight.w700),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
              child: Text(l10n.newSheetNote, style: text.bodySmall),
            ),
            ChatRow(
              key: const ValueKey('new-pot'),
              avatar: const _IconAvatar(icon: LucideIcons.userPlus, color: 3),
              title: l10n.chatNewPot,
              preview: l10n.newPotDetail,
              previewMaxLines: null,
              divider: false,
              onTap: () => Navigator.pop(context, newPotKey),
            ),
            ChatRow(
              key: const ValueKey('new-group'),
              avatar: const _IconAvatar(icon: LucideIcons.users, color: 1),
              title: l10n.chatNewGroup,
              preview: canGroup ? l10n.newGroupDetail : l10n.newGroupNeedsTwo,
              previewMaxLines: null,
              onTap: canGroup
                  ? () => Navigator.pop(context, newGroupKey)
                  : null,
            ),
            const SizedBox(height: PircSpacing.stackMd),
          ],
        ),
      );
    },
  );
  if (choice != null && context.mounted) context.go(chatLocation(choice));
}

class _IconAvatar extends StatelessWidget {
  const _IconAvatar({required this.icon, required this.color});
  final IconData icon;
  final int color;

  @override
  Widget build(BuildContext context) {
    final colors = PircColorTokens.of(context);
    return Container(
      width: 48,
      height: 48,
      decoration: BoxDecoration(
        color: colors[avatarColorToken(color)],
        shape: BoxShape.circle,
      ),
      child: Icon(icon, size: 20, color: colors['avatar.ink']),
    );
  }
}
