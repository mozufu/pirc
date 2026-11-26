import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:pirc_client/pirc_client.dart';
import 'package:pirc_ui/pirc_ui.dart';

import '../../l10n/app_localizations.dart';
import '../format.dart';
import 'thread_cards.dart';
import 'thread_data.dart';

/// The messages of a pot conversation or a group (`e-thread`), newest at
/// the bottom: the user's bubbles on the right without an avatar, the
/// pots' on the left with theirs, system messages as notices and their
/// cards indented under the bubbles. Scrolling up loads older pages; the
/// newest message on screen reports [onNewestShown].
class ThreadMessageList extends ConsumerStatefulWidget {
  const ThreadMessageList({
    super.key,
    required this.view,
    required this.avatarOf,
    required this.onLoadOlder,
    required this.onNewestShown,
    this.nameOf,
  });

  final ThreadView view;

  /// The avatar of a pot's message (28).
  final Widget Function(ThreadMessage message) avatarOf;

  /// The name above a pot's bubble (groups); null shows none.
  final String? Function(ThreadMessage message)? nameOf;
  final VoidCallback onLoadOlder;
  final VoidCallback onNewestShown;

  @override
  ConsumerState<ThreadMessageList> createState() => _ThreadMessageListState();
}

/// How close to an end counts as being there.
const _nearEnd = 48.0;

class _ThreadMessageListState extends ConsumerState<ThreadMessageList> {
  final _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_check);
    _afterFrame();
  }

  @override
  void didUpdateWidget(ThreadMessageList old) {
    super.didUpdateWidget(old);
    if (old.view.messages != widget.view.messages) _afterFrame();
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _afterFrame() => WidgetsBinding.instance.addPostFrameCallback((_) {
    if (mounted) _check();
  });

  /// The list is reversed: 0 is the bottom (the newest message).
  void _check() {
    if (!_scroll.hasClients) return;
    final position = _scroll.position;
    if (position.pixels <= _nearEnd) widget.onNewestShown();
    if (widget.view.hasOlder &&
        position.pixels >= position.maxScrollExtent - 300) {
      widget.onLoadOlder();
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = PircColorTokens.of(context);
    final now = ref.read(clockProvider)();
    final messages = widget.view.messages;
    final entries = <Widget>[];
    ThreadMessage? previous;
    for (final message in messages) {
      if (_newDay(previous, message)) {
        entries.add(
          _DayLine(
            key: ValueKey('day-${message.seq}'),
            text: dayLine(context, message.createdAt, now),
          ),
        );
      }
      entries.add(
        KeyedSubtree(
          key: ValueKey('message-${message.seq}'),
          child: _message(message),
        ),
      );
      previous = message;
    }
    if (entries.isEmpty) {
      return Center(
        child: Text(
          AppLocalizations.of(context).chatNoMessages,
          style: TextStyle(fontSize: 13.5, color: colors['text.muted']),
        ),
      );
    }
    final ordered = entries.reversed.toList();
    final older = widget.view.hasOlder;
    return ListView.separated(
      key: const ValueKey('thread-list'),
      controller: _scroll,
      reverse: true,
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 20),
      itemCount: ordered.length + (older ? 1 : 0),
      separatorBuilder: (_, _) => const SizedBox(height: 10),
      itemBuilder: (context, index) => index < ordered.length
          ? ordered[index]
          : Center(
              child: SizedBox.square(
                dimension: 20,
                child: widget.view.loadingOlder
                    ? const CircularProgressIndicator(strokeWidth: 2)
                    : null,
              ),
            ),
    );
  }

  Widget _message(ThreadMessage message) {
    if (message.fromUser) return Bubble.mine(text: message.body);
    if (message.fromPot) {
      return Bubble(
        text: message.body,
        avatar: widget.avatarOf(message),
        name: widget.nameOf?.call(message),
      );
    }
    final card = message.card;
    if (card == null || card is UnknownCard) {
      return ThreadCardView(
        card: card ?? const UnknownCard('', {}),
        body: message.body,
      );
    }
    final view = Padding(
      padding: const EdgeInsets.only(left: 36),
      child: ThreadCardView(
        card: card,
        threadPots: widget.view.thread?.pots ?? const [],
      ),
    );
    // A work card comes with the line that says who asked for it.
    if (card is WorkSessionCard && message.body.isNotEmpty) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: 10,
        children: [
          ThreadNotice(text: message.body),
          view,
        ],
      );
    }
    return view;
  }

  /// A time line before the first message, a new day, or after an hour
  /// without messages.
  static bool _newDay(ThreadMessage? previous, ThreadMessage message) {
    if (previous == null) return true;
    final a = DateTime.fromMillisecondsSinceEpoch(previous.createdAt);
    final b = DateTime.fromMillisecondsSinceEpoch(message.createdAt);
    return !DateUtils.isSameDay(a, b) || b.difference(a).inMinutes >= 60;
  }
}

/// "Today 09:00", "Yesterday 18:00", else the date and time.
String dayLine(BuildContext context, int millis, DateTime now) {
  final l10n = AppLocalizations.of(context);
  final locale = Localizations.localeOf(context).toLanguageTag();
  final time = DateTime.fromMillisecondsSinceEpoch(millis);
  final days = DateUtils.dateOnly(
    now,
  ).difference(DateUtils.dateOnly(time)).inDays;
  final clock = DateFormat.Hm(locale).format(time);
  return switch (days) {
    0 => l10n.threadDayToday(clock),
    1 => l10n.threadDayYesterday(clock),
    _ => DateFormat.MMMd(locale).add_Hm().format(time),
  };
}

/// `e-day`: the time, centred (12, muted).
class _DayLine extends StatelessWidget {
  const _DayLine({super.key, required this.text});
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 4),
    child: Text(
      text,
      textAlign: TextAlign.center,
      style: TextStyle(
        fontSize: 12,
        height: 16 / 12,
        color: PircColorTokens.of(context)['text.muted'],
      ),
    ),
  );
}

/// The composer of a pot conversation or a group (`c-wrap` /
/// `c-composer`): the field over the tools row with the send button.
/// [onSend] gets the trimmed text and answers whether it was sent (the
/// field is then emptied; otherwise the draft stays).
class ThreadComposer extends StatefulWidget {
  const ThreadComposer({
    super.key,
    required this.hint,
    required this.onSend,
    this.enabled = true,
    this.above,
  });

  final String hint;
  final Future<bool> Function(String body) onSend;

  /// False while offline: the field and the button are disabled and the
  /// draft is kept.
  final bool enabled;

  /// Shown inside the composer above the field (group targets).
  final Widget? above;

  @override
  State<ThreadComposer> createState() => _ThreadComposerState();
}

class _ThreadComposerState extends State<ThreadComposer> {
  final _text = TextEditingController();
  bool _sending = false;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final body = _text.text.trim();
    if (body.isEmpty || _sending) return;
    setState(() => _sending = true);
    final sent = await widget.onSend(body);
    if (!mounted) return;
    setState(() {
      _sending = false;
      if (sent) _text.clear();
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final colors = PircColorTokens.of(context);
    final elevation = Theme.of(context).extension<PircElevationTokens>();
    final canSend = widget.enabled && !_sending && _text.text.trim().isNotEmpty;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        PircSpacing.composerSideInset,
        0,
        PircSpacing.composerSideInset,
        8,
      ),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: colors['surface.input'],
          borderRadius: BorderRadius.circular(PircRadius.panel),
          boxShadow: elevation?.float,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ?widget.above,
            TextField(
              key: const ValueKey('thread-composer-field'),
              controller: _text,
              enabled: widget.enabled,
              minLines: 1,
              maxLines: 8,
              onChanged: (_) => setState(() {}),
              style: TextStyle(
                fontSize: 16,
                height: 24 / 16,
                color: colors['text.primary'],
              ),
              decoration: InputDecoration(
                hintText: widget.hint,
                hintStyle: TextStyle(
                  fontSize: 16,
                  height: 24 / 16,
                  color: colors['text.faint'],
                ),
                filled: false,
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                disabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
                isCollapsed: true,
                contentPadding: const EdgeInsets.fromLTRB(20, 14, 20, 14),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 6, 8, 8),
              child: Row(
                children: [
                  const Spacer(),
                  SizedBox.square(
                    dimension: PircSize.composerButton,
                    child: IconButton(
                      key: const ValueKey('thread-send'),
                      tooltip: l10n.send,
                      padding: EdgeInsets.zero,
                      style: IconButton.styleFrom(
                        minimumSize: const Size.square(PircSize.composerButton),
                        backgroundColor: colors['action.primary'],
                        foregroundColor: colors['action.onPrimary'],
                        disabledBackgroundColor: colors['surface.subtle'],
                        disabledForegroundColor: colors['text.faint'],
                      ),
                      onPressed: canSend ? _send : null,
                      icon: _sending
                          ? const SizedBox.square(
                              dimension: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(LucideIcons.arrowUp, size: 18),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
