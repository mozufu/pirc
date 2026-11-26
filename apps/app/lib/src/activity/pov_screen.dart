import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:pirc_client/pirc_client.dart';
import 'package:pirc_ui/pirc_ui.dart';

import '../../l10n/app_localizations.dart';
import '../chat/chat_list_screen.dart';
import '../chat/pot_conversation_screen.dart';
import '../chat/thread_cards.dart';
import '../chat/thread_data.dart';
import '../chat/thread_view.dart';
import '../connection/data.dart';
import '../format.dart';
import '../me/me_screen.dart';
import '../work/work_data.dart';
import '../work/work_side.dart';
import 'activity_data.dart';

/// [text] with every [name] in it bold (`e-pov b`); the translations put
/// the name in different places.
TextSpan boldName(BuildContext context, String text, String name) {
  if (name.isEmpty) return TextSpan(text: text);
  final parts = text.split(name);
  return TextSpan(
    children: [
      for (final (i, part) in parts.indexed) ...[
        if (i > 0) PovBar.name(context, name),
        TextSpan(text: part),
      ],
    ],
  );
}

/// A pot's point of view (E18), read only: the note, the threads it is in
/// (its direct thread with the user, groups, pot DMs), the works it sent
/// instructions into and the messages it sent. Nothing here posts.
class PovScreen extends ConsumerStatefulWidget {
  const PovScreen({super.key, required this.potId, this.showBack = true});

  final String potId;

  /// False at 1200 and wider, where the Activity list stays beside it.
  final bool showBack;

  @override
  ConsumerState<PovScreen> createState() => _PovScreenState();
}

class _PovScreenState extends ConsumerState<PovScreen> {
  /// Older pages of sent messages, loaded with "Show older".
  final _older = <ThreadMessage>[];
  String? _cursor;
  bool _loading = false;

  Future<void> _loadOlder(String before) async {
    final api = ref.read(apiProvider);
    if (api == null || _loading) return;
    setState(() => _loading = true);
    try {
      final page = await ActivityApi(api).view(widget.potId, before: before);
      if (!mounted) return;
      setState(() {
        _older.addAll(page.sent);
        _cursor = page.nextBefore ?? '';
      });
    } on PircException {
      // The button stays; another tap tries again.
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final colors = PircColorTokens.of(context);
    final potId = widget.potId;
    final pot = potById(ref, potId);
    final name = pot?.name ?? '';
    final view = ref.watch(potViewProvider(potId));
    final now = ref.watch(clockProvider)();

    final Widget body;
    final value = view.value;
    if (value == null) {
      body = view.hasError
          ? _Failed(onRetry: () => ref.invalidate(potViewProvider(potId)))
          : const Center(child: CircularProgressIndicator());
    } else {
      final threads = [...value.threads]
        ..sort((a, b) => _threadTime(b).compareTo(_threadTime(a)));
      final works = povWorks(value, watchPotWorks(ref));
      final sent = [...value.sent, ..._older];
      final cursor = _cursor ?? value.nextBefore;
      body = ListView(
        key: const ValueKey('pov-list'),
        padding: const EdgeInsets.only(bottom: 16),
        children: [
          _Head(title: l10n.tabChat),
          if (threads.isEmpty) GroupNote(l10n.povNoThreads),
          for (final (i, thread) in threads.indexed)
            _threadRow(context, thread, divider: i > 0, now: now),
          if (works.isNotEmpty) ...[
            _Head(
              title: l10n.povWorks,
              folder: true,
              count: l10n.groupCount(works.length),
            ),
            for (final (i, work) in works.indexed)
              ChatRow(
                key: ValueKey('pov-work-${work.workId}'),
                title: work.title,
                time: work.time == 0
                    ? null
                    : listTime(context, work.time, now: now),
                preview: work.instructions.isEmpty
                    ? null
                    : l10n.chatPreviewBy(
                        l10n.povAuthorMe,
                        _firstLine(work.instructions.first.body),
                      ),
                divider: i > 0,
                minHeight: 64,
                onTap: () => context.go(povWorkLocation(potId, work.workId)),
              ),
          ],
          if (sent.isNotEmpty) ...[
            _Head(title: l10n.povSent),
            for (final (i, message) in sent.indexed)
              ChatRow(
                key: ValueKey('pov-sent-${message.id}'),
                title: _threadName(
                  l10n,
                  value.threads
                      .where((t) => t.id == message.threadId)
                      .firstOrNull,
                ),
                time: listTime(context, message.createdAt, now: now),
                preview: _firstLine(message.body),
                divider: i > 0,
                minHeight: 64,
                onTap: () =>
                    context.go(povThreadLocation(potId, message.threadId)),
              ),
            if (cursor != null && cursor.isNotEmpty)
              Align(
                child: TextButton(
                  key: const ValueKey('pov-sent-older'),
                  onPressed: _loading ? null : () => _loadOlder(cursor),
                  child: Text(l10n.povShowOlder),
                ),
              ),
          ],
        ],
      );
    }

    return Scaffold(
      backgroundColor: colors['surface.page'],
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ThreadHeader(
            avatar: pot == null
                ? null
                : PotAvatar(pot: pot, size: AvatarSize.md),
            name: l10n.povTitle(name),
            line: l10n.povSubtitle,
            showBack: widget.showBack,
            onBack: () => context.go(activityLocation(potId: potId)),
            onOpen: null,
            openTooltip: '',
          ),
          PovBar.note(note: boldName(context, l10n.povNote(name), name)),
          Expanded(child: body),
        ],
      ),
    );
  }

  static int _threadTime(PotThread t) =>
      t.lastMessage?.createdAt ?? t.updatedAt;

  /// A thread's name as the pot sees it: the user, a group, the other pot.
  String _threadName(AppLocalizations l10n, PotThread? thread) {
    if (thread == null) return '';
    return switch (thread.kind) {
      'direct' => l10n.povYou,
      'pot_dm' => _otherName(thread),
      _ => thread.name,
    };
  }

  String _otherName(PotThread thread) {
    final other = thread.pots.where((p) => p != widget.potId).firstOrNull;
    return potById(ref, other)?.name ?? thread.name;
  }

  Widget _threadRow(
    BuildContext context,
    PotThread thread, {
    required bool divider,
    required DateTime now,
  }) {
    final l10n = AppLocalizations.of(context);
    final last = thread.lastMessage;
    String? preview;
    if (last != null && last.firstLine.isNotEmpty) {
      final author = switch (last.authorKind) {
        'user' => l10n.chatAuthorYou,
        'pot' when last.authorId == widget.potId => l10n.povAuthorMe,
        'pot' => potById(ref, last.authorId)?.name ?? last.authorName,
        _ => null,
      };
      preview = author == null
          ? last.firstLine
          : l10n.chatPreviewBy(author, last.firstLine);
    }
    final pots = ref.watch(potsProvider).value ?? const <PotSummary>[];
    final (Widget avatar, String title, String? role) = switch (thread.kind) {
      'direct' => (
        const MeAvatar(size: AvatarSize.standard),
        l10n.povYou,
        null,
      ),
      'pot_dm' => () {
        final other = potById(
          ref,
          thread.pots.where((p) => p != widget.potId).firstOrNull,
        );
        final name = other?.name ?? thread.name;
        return (
          other != null
              ? PotAvatar(pot: other) as Widget
              : Avatar(name: name, color: thread.avatarColor ?? 1),
          name,
          null,
        );
      }(),
      _ => (
        GroupThreadAvatar.of(
          thread,
          members: [
            for (final id in thread.pots)
              ?pots.where((p) => p.id == id).firstOrNull,
          ],
        ),
        thread.name,
        l10n.groupMemberCount(thread.pots.length),
      ),
    };
    return ChatRow(
      key: ValueKey('pov-thread-${thread.id}'),
      avatar: avatar,
      title: title,
      role: role,
      time: listTime(context, _threadTime(thread), now: now),
      preview: preview ?? l10n.chatNoMessages,
      divider: divider,
      onTap: () => context.go(povThreadLocation(widget.potId, thread.id)),
    );
  }
}

String _firstLine(String text) => text.split('\n').first.trim();

/// A section title of the point of view (as the Work tab's project
/// header): an optional folder, the title and a count.
class _Head extends StatelessWidget {
  const _Head({required this.title, this.folder = false, this.count});

  final String title;
  final bool folder;
  final String? count;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final colors = PircColorTokens.of(context);
    return Semantics(
      header: true,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          PircSpacing.gutterPhone,
          PircSpacing.stackXl,
          PircSpacing.gutterPhone,
          PircSpacing.stackSm,
        ),
        child: Row(
          spacing: PircSpacing.stackSm,
          children: [
            if (folder)
              Icon(
                LucideIcons.folder,
                size: PircSize.iconRow,
                color: colors['text.secondary'],
              ),
            Expanded(
              child: Text(
                title,
                style: text.titleMedium?.copyWith(fontWeight: FontWeight.w500),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (count != null) Text(count!, style: text.bodyMedium),
          ],
        ),
      ),
    );
  }
}

/// One of a pot's threads as it sees it (E20), read only: its own messages
/// on the right tinted with its colour, the other pots and the user (with
/// the user's avatar) on the left, notices without buttons, and the
/// read-only bar with "Back to activity". Opened from the point of view,
/// an Activity row (a pot DM) or a pot DM's thread ID in the Chat tab.
class PovThreadScreen extends ConsumerWidget {
  const PovThreadScreen({
    super.key,
    required this.potId,
    required this.threadId,
    this.showBack = true,
    this.onBack,
  });

  /// The pot whose point of view this is.
  final String potId;
  final String threadId;
  final bool showBack;

  /// Where Back goes; the point of view by default.
  final VoidCallback? onBack;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final colors = PircColorTokens.of(context);
    final controller = ref.read(threadControllerProvider(threadId).notifier);
    final view = ref.watch(threadControllerProvider(threadId));
    final thread = view.thread;
    final pot = potById(ref, potId);
    final name = pot?.name ?? _authorName(view, potId);
    final pots = ref.watch(potsProvider).value ?? const <PotSummary>[];

    final (Widget? avatar, String title, String line) = switch (thread?.kind) {
      'direct' => (
        const MeAvatar(size: AvatarSize.md) as Widget,
        l10n.povYou,
        l10n.povDirectSubtitle,
      ),
      'group' => (
        GroupThreadAvatar.of(
          thread!,
          size: AvatarSize.md,
          members: [
            for (final id in thread.pots)
              ?pots.where((p) => p.id == id).firstOrNull,
          ],
        ),
        thread.name,
        l10n.groupMemberCount(thread.pots.length),
      ),
      'pot_dm' => () {
        final otherId = thread!.pots.where((p) => p != potId).firstOrNull;
        final other = potById(ref, otherId);
        final otherName = other?.name ?? _authorName(view, otherId);
        return (
          other != null
              ? PotAvatar(pot: other, size: AvatarSize.md) as Widget
              : Avatar(name: otherName, size: AvatarSize.md),
          otherName,
          l10n.povDmSubtitle,
        );
      }(),
      _ => (null, '', ''),
    };

    final Widget body;
    if (!view.loaded) {
      body = view.error == null || view.error is NotConnected
          ? const Center(child: CircularProgressIndicator())
          : _Failed(onRetry: controller.refresh);
    } else {
      body = ThreadMessageList(
        view: view,
        avatarOf: (message) => MessageAvatar(message: message, deletedName: ''),
        bubbleOf: (message) {
          if (message.fromPot && message.authorId == potId) {
            return Bubble(
              text: message.body,
              avatar: MessageAvatar(message: message, deletedName: name),
              name: l10n.povMe(name),
              rightSide: true,
              tint: pot?.avatarColor ?? 1,
            );
          }
          if (message.fromPot) {
            return Bubble(
              text: message.body,
              avatar: MessageAvatar(message: message, deletedName: ''),
              name: message.authorDeleted
                  ? message.authorName
                  : potById(ref, message.authorId)?.name ?? message.authorName,
            );
          }
          return Bubble(
            text: message.body,
            avatar: const MeAvatar(size: AvatarSize.sm),
            name: l10n.chatAuthorYou,
          );
        },
        onLoadOlder: controller.loadOlder,
        // The user reads it as the pot: the read position stays.
        onNewestShown: () {},
      );
    }

    return Scaffold(
      backgroundColor: colors['surface.page'],
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ThreadHeader(
            avatar: avatar,
            name: title,
            line: line,
            showBack: showBack,
            onBack: onBack ?? () => context.go(povLocation(potId)),
            onOpen: null,
            openTooltip: '',
          ),
          PovBar.note(
            avatar: pot == null
                ? null
                : PotAvatar(pot: pot, size: AvatarSize.sm),
            note: boldName(context, l10n.povThreadNote(name), name),
          ),
          Expanded(child: body),
          SafeArea(
            top: false,
            child: PovReadOnlyBar(
              key: const ValueKey('pov-read-only'),
              text: l10n.povReadOnly(name),
              actionLabel: l10n.povBackToActivity,
              onAction: () => context.go(activityLocation(potId: potId)),
            ),
          ),
        ],
      ),
    );
  }

  /// A deleted pot's name from its messages.
  static String _authorName(ThreadView view, String? id) {
    for (final message in view.messages.reversed) {
      if (message.authorId == id && message.authorName != null) {
        return message.authorName!;
      }
    }
    return '';
  }
}

/// The instructions a pot sent into one work (E19), read only: each on the
/// right with its time and delivery, and "Go to work" opening the work
/// conversation. The work's own replies are in that conversation; the
/// point of view has only what the pot sent.
class PovWorkScreen extends ConsumerWidget {
  const PovWorkScreen({super.key, required this.potId, required this.workId});

  final String potId;
  final String workId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final colors = PircColorTokens.of(context);
    final pot = potById(ref, potId);
    final name = pot?.name ?? '';
    final view = ref.watch(potViewProvider(potId));
    final value = view.value;
    final work = value == null
        ? null
        : povWorks(
            value,
            watchPotWorks(ref),
          ).where((w) => w.workId == workId).firstOrNull;
    final now = ref.watch(clockProvider)();

    final Widget body;
    if (value == null) {
      body = view.hasError
          ? _Failed(onRetry: () => ref.invalidate(potViewProvider(potId)))
          : const Center(child: CircularProgressIndicator());
    } else if (work == null || work.instructions.isEmpty) {
      body = Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            l10n.povNoInstructions,
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 13.5, color: colors['text.muted']),
          ),
        ),
      );
    } else {
      final list = work.instructions;
      body = ListView.separated(
        key: const ValueKey('pov-instructions'),
        reverse: true,
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 20),
        itemCount: list.length,
        separatorBuilder: (_, _) => const SizedBox(height: 10),
        itemBuilder: (context, index) {
          final item = list[index];
          return Bubble(
            key: ValueKey('instruction-${item.id}'),
            text: item.body,
            avatar: pot == null
                ? null
                : PotAvatar(pot: pot, size: AvatarSize.sm),
            name: l10n.povMe(name),
            rightSide: true,
            tint: pot?.avatarColor ?? 1,
            meta: [
              clockTime(context, item.createdAt, now: now),
              ?switch (item.delivery) {
                'delivered' => l10n.povDelivered,
                'refused' => l10n.povRefused,
                'uncertain' => l10n.povUncertain,
                _ => null,
              },
            ].join(' · '),
          );
        },
      );
    }

    final session = work?.sessionId ?? '';
    return Scaffold(
      backgroundColor: colors['surface.page'],
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ThreadHeader(
            name: work?.title ?? '',
            line: l10n.povTitle(name),
            showBack: true,
            onBack: () => context.go(povLocation(potId)),
            onOpen: null,
            openTooltip: '',
          ),
          PovBar.note(
            avatar: pot == null
                ? null
                : PotAvatar(pot: pot, size: AvatarSize.sm),
            note: boldName(context, l10n.povThreadNote(name), name),
          ),
          Expanded(child: body),
          SafeArea(
            top: false,
            child: PovReadOnlyBar(
              key: const ValueKey('pov-read-only'),
              text: l10n.povReadOnly(name),
              actionLabel: l10n.povGoToWork,
              onAction: session.isEmpty
                  ? null
                  : () => context.go(workLocation(session)),
            ),
          ),
        ],
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
        spacing: 8,
        children: [
          Text(l10n.listFailed),
          OutlinedButton(onPressed: onRetry, child: Text(l10n.retry)),
        ],
      ),
    );
  }
}
