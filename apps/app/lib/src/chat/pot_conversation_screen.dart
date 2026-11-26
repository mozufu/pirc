import 'package:flutter/material.dart';
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
import 'thread_cards.dart';
import 'thread_data.dart';
import 'thread_view.dart';

/// A pot's conversation (E11): its direct thread with the header (avatar,
/// name, status; it opens the profile), the messages and cards, and the
/// composer. Opened by `pot:<id>`, or by a direct thread's ID (a deleted
/// pot's old thread, read-only). Any other thread (a group, a pot DM)
/// shows what [otherThread] builds for it once the thread is read.
class PotConversationScreen extends ConsumerStatefulWidget {
  const PotConversationScreen({
    super.key,
    required this.chatKey,
    this.showBack = true,
    this.otherThread,
  });

  /// `pot:<id>` or a thread ID.
  final String chatKey;

  /// False at 1200 and wider, where the list stays beside it.
  final bool showBack;
  final Widget Function(BuildContext context, PotThread thread)? otherThread;

  @override
  ConsumerState<PotConversationScreen> createState() =>
      _PotConversationScreenState();
}

class _PotConversationScreenState extends ConsumerState<PotConversationScreen> {
  String? _postError;
  List<RefusedWake> _refused = const [];

  ThreadController get _controller =>
      ref.read(threadControllerProvider(widget.chatKey).notifier);

  Future<bool> _send(String body) async {
    setState(() {
      _postError = null;
      _refused = const [];
    });
    try {
      final posted = await _controller.post(body);
      if (mounted) setState(() => _refused = posted.refused);
      return true;
    } on PircException catch (error) {
      if (mounted) setState(() => _postError = error.message);
      return false;
    } on NotConnected {
      return false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final colors = PircColorTokens.of(context);
    final view = ref.watch(threadControllerProvider(widget.chatKey));
    final thread = view.thread;
    if (thread != null && !thread.isDirect && widget.otherThread != null) {
      return widget.otherThread!(context, thread);
    }
    final key = widget.chatKey;
    final potId = key.startsWith('pot:')
        ? key.substring('pot:'.length)
        : thread?.pots.firstOrNull;
    final pots = ref.watch(potsProvider).value;
    final pot = potById(ref, potId);
    final deleted = pots != null && thread != null && pot == null;
    final archived = pot?.state == 'archived';
    final name = pot?.name ?? _deletedName(view);
    final online =
        ref.watch(appConnectionStateProvider) == AppConnectionState.online;

    final Widget body;
    if (!view.loaded) {
      body = view.error == null || view.error is NotConnected
          ? const Center(child: CircularProgressIndicator())
          : _Failed(onRetry: _controller.refresh);
    } else {
      body = ThreadMessageList(
        view: view,
        avatarOf: (message) => MessageAvatar(
          message: message,
          deletedName: name,
          deletedColor: thread?.avatarColor,
        ),
        onLoadOlder: _controller.loadOlder,
        onNewestShown: _controller.markNewestRead,
      );
    }

    final Widget bottom;
    if (deleted || archived) {
      bottom = Padding(
        key: const ValueKey('thread-read-only'),
        padding: const EdgeInsets.fromLTRB(24, 12, 24, 16),
        child: Text(
          deleted
              ? l10n.threadReadOnlyDeleted(name)
              : l10n.threadReadOnlyArchived(name),
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 13.5,
            height: 19 / 13.5,
            color: colors['text.muted'],
          ),
        ),
      );
    } else {
      final notes = [
        ?_postError,
        for (final wake in _refused)
          l10n.threadRefused(
            potById(ref, wake.potId)?.name ?? name,
            wake.reason.isNotEmpty ? wake.reason : wake.code,
          ),
        if (!online) l10n.composerOffline,
      ];
      bottom = Column(
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
            hint: l10n.threadComposerHint(name),
            enabled: online && view.loaded,
            onSend: _send,
          ),
        ],
      );
    }

    return Scaffold(
      backgroundColor: colors['surface.page'],
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _Header(
            pot: pot,
            name: name,
            deletedColor: thread?.avatarColor,
            showBack: widget.showBack,
            onOpen: pot == null || deleted
                ? null
                : () => context.go(potProfileLocation(pot.id)),
          ),
          Expanded(child: body),
          SafeArea(top: false, child: bottom),
        ],
      ),
    );
  }

  /// A deleted pot's name: the thread's, else its messages'.
  static String _deletedName(ThreadView view) {
    final thread = view.thread;
    if (thread != null && thread.name.isNotEmpty) return thread.name;
    for (final message in view.messages.reversed) {
      if (message.authorName != null) return message.authorName!;
    }
    return '';
  }
}

/// The avatar of a pot's bubble: the pot's, or a deleted pot's letter.
class MessageAvatar extends ConsumerWidget {
  const MessageAvatar({
    super.key,
    required this.message,
    required this.deletedName,
    this.deletedColor,
  });

  final ThreadMessage message;
  final String deletedName;
  final int? deletedColor;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pot = message.authorDeleted ? null : potById(ref, message.authorId);
    if (pot != null) return PotAvatar(pot: pot, size: AvatarSize.sm);
    return Avatar(
      name: message.authorName ?? deletedName,
      color: deletedColor ?? 1,
      size: AvatarSize.sm,
    );
  }
}

/// `c-top` with `e-head`: Back, the avatar (36), the name (16/600) over the
/// status line (12 muted), and the profile button.
class _Header extends ConsumerWidget {
  const _Header({
    required this.pot,
    required this.name,
    required this.showBack,
    required this.onOpen,
    this.deletedColor,
  });

  final PotSummary? pot;
  final String name;
  final int? deletedColor;
  final bool showBack;
  final VoidCallback? onOpen;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final summary = pot;
    final full = summary == null
        ? null
        : ref.watch(potProvider(summary.id)).value;
    final status = summary == null ? null : potStateLine(l10n, summary, full);
    final line = [
      if (summary != null && summary.intro.isNotEmpty) summary.intro,
      ?status,
      if (full != null) ?potBudgetLine(l10n, full),
    ].join(' · ');
    return ThreadHeader(
      avatar: summary != null
          ? PotAvatar(pot: summary, size: AvatarSize.md)
          : Avatar(name: name, color: deletedColor ?? 1, size: AvatarSize.md),
      name: name,
      line: line,
      showBack: showBack,
      onOpen: onOpen,
      openTooltip: l10n.potProfileOf(name),
    );
  }
}

/// `c-top` with `e-head`: Back, the [avatar] (36), the [name] (16/600)
/// over a [line] (12 muted), and the info button; the header and the
/// button call [onOpen] (a pot's profile, a group's info).
class ThreadHeader extends StatelessWidget {
  const ThreadHeader({
    super.key,
    this.avatar,
    required this.name,
    required this.line,
    required this.showBack,
    required this.onOpen,
    required this.openTooltip,
    this.onBack,
  });

  final Widget? avatar;
  final String name;
  final String line;
  final bool showBack;
  final VoidCallback? onOpen;
  final String openTooltip;

  /// Where Back goes; the Chat tab's list by default.
  final VoidCallback? onBack;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final colors = PircColorTokens.of(context);
    return SizedBox(
      height: PircSize.topBar,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6),
        child: Row(
          spacing: 4,
          children: [
            if (showBack)
              IconButton(
                tooltip: l10n.back,
                color: colors['text.secondary'],
                onPressed: onBack ?? () => context.go('/chat'),
                icon: const Icon(LucideIcons.chevronLeft, size: 22),
              )
            else
              const SizedBox(width: 10),
            Expanded(
              child: InkWell(
                key: const ValueKey('thread-header'),
                onTap: onOpen,
                borderRadius: BorderRadius.circular(PircRadius.md),
                child: Row(
                  spacing: 8,
                  children: [
                    ?avatar,
                    Expanded(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 16,
                              height: 22 / 16,
                              fontWeight: FontWeight.w600,
                              color: colors['text.primary'],
                            ),
                          ),
                          if (line.isNotEmpty)
                            Text(
                              line,
                              key: const ValueKey('thread-status'),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 12,
                                height: 16 / 12,
                                color: colors['text.muted'],
                              ),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
            if (onOpen != null)
              IconButton(
                tooltip: openTooltip,
                color: colors['text.secondary'],
                onPressed: onOpen,
                icon: const Icon(LucideIcons.info, size: 21),
              ),
          ],
        ),
      ),
    );
  }
}

/// Paused, working or unavailable; else what it may do ([full]'s reach).
String? potStateLine(AppLocalizations l10n, PotSummary pot, Pot? full) {
  if (pot.state == 'paused') return l10n.potPaused;
  if (pot.status == 'working') return l10n.potWorking;
  if (pot.status == 'unavailable') return l10n.potUnavailable;
  return potReachLine(l10n, full);
}

/// What [pot] may do, in the conversation header's words.
String? potReachLine(AppLocalizations l10n, Pot? pot) =>
    switch (pot?.permissions.reach) {
      'answer' => l10n.potHeaderAnswer,
      'observe' => l10n.potHeaderObserve,
      'work' => l10n.potHeaderWork,
      _ => null,
    };

/// "This month $4.20 / $20", or today's tokens when money has no limit.
String? potBudgetLine(AppLocalizations l10n, Pot pot) {
  final left = pot.budgetLeft;
  final money = pot.permissions.budgetMoneyMonthMicros;
  if (money != null && left?.moneyMicros != null) {
    return l10n.potBudgetMonthUsed(
      dollars(money - left!.moneyMicros!),
      dollars(money),
    );
  }
  final tokens = pot.permissions.budgetTokensDay;
  if (tokens != null && left?.tokens != null) {
    return l10n.potBudgetDayUsed(
      compactTokens(tokens - left!.tokens!),
      compactTokens(tokens),
    );
  }
  return null;
}

/// Dollars without cents when they are whole: `$20`, `$4.20`.
String dollars(int micros) {
  final cents = (micros / 10000).round();
  final sign = cents < 0 ? '-' : '';
  final abs = cents.abs();
  final whole = '$sign\$${abs ~/ 100}';
  return abs % 100 == 0
      ? whole
      : '$whole.${(abs % 100).toString().padLeft(2, '0')}';
}

/// Tokens in M or K with at most one decimal: `2M`, `0.8M`, `950K`.
String compactTokens(int tokens) {
  String one(double value) {
    final text = value.toStringAsFixed(1);
    return text.endsWith('.0') ? text.substring(0, text.length - 2) : text;
  }

  if (tokens.abs() >= 100000) return '${one(tokens / 1000000)}M';
  if (tokens.abs() >= 1000) return '${one(tokens / 1000)}K';
  return '$tokens';
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
          Text(l10n.threadFailed),
          OutlinedButton(onPressed: onRetry, child: Text(l10n.retry)),
        ],
      ),
    );
  }
}
