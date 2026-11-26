import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:pirc_client/pirc_client.dart';
import 'package:pirc_ui/pirc_ui.dart';

import '../../l10n/app_localizations.dart';
import '../chat/chat_data.dart';
import '../chat/chat_list_screen.dart';
import '../chat/thread_cards.dart';
import '../connection/connection.dart';
import '../connection/data.dart';
import 'timeline.dart';
import 'work_data.dart';

/// Takes the work over: the pot sends no more instructions to it. A second
/// device's `409 taken_over` is success.
Future<void> takeOverWork(
  BuildContext context,
  WidgetRef ref,
  PotWork work,
) async {
  final l10n = AppLocalizations.of(context);
  final api = ref.read(apiProvider);
  if (api == null) return;
  try {
    await PotsApi(api).takeOver(work.id);
  } on TakenOver {
    // Another device took it over first: the result is the same.
  } on PircException catch (error) {
    if (ref.read(connectionProvider.notifier).report(error)) return;
    if (context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l10n.actionFailed(error.message))));
    }
    return;
  }
  ref.invalidate(potWorksProvider);
}

/// While a pot coordinates the work (E36): a dark bar with the pot's avatar
/// and 接管 (Take over). After a take-over, from this device or another: a
/// plain banner. The avatar and the text link back to the pot's
/// conversation while the pot is known.
class PotBar extends ConsumerWidget {
  const PotBar({super.key, required this.sessionId});
  final String sessionId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final colors = PircColorTokens.of(context);
    final text = Theme.of(context).textTheme;
    final work = ref.watch(potWorkOfSessionProvider(sessionId));
    if (work == null) return const SizedBox.shrink();
    final pot = potById(ref, work.potId);
    final name = pot?.name ?? '';
    final VoidCallback? openPot = pot == null
        ? null
        : () => context.go(chatLocation(potChatKey(pot.id)));
    // On the dark bar the ripple needs its own Material and a light colour.
    Widget link(Widget child, {Color? ink}) => openPot == null
        ? child
        : Semantics(
            link: true,
            onTapHint: l10n.potBarOpen(name),
            child: Material(
              type: MaterialType.transparency,
              child: InkWell(
                onTap: openPot,
                borderRadius: BorderRadius.circular(PircRadius.md),
                splashColor: ink?.withValues(alpha: 0.16),
                highlightColor: ink?.withValues(alpha: 0.08),
                child: child,
              ),
            ),
          );
    if (!work.open) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
        child: link(
          Text(
            l10n.takenOver(name),
            textAlign: TextAlign.center,
            style: text.bodySmall,
          ),
        ),
      );
    }
    final dark = colors['action.primary'];
    final onDark = colors['action.onPrimary'];
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      padding: const EdgeInsets.fromLTRB(10, 10, 12, 10),
      decoration: BoxDecoration(
        color: dark,
        borderRadius: BorderRadius.circular(PircRadius.lg),
      ),
      child: Row(
        children: [
          Expanded(
            child: link(
              Row(
                spacing: 10,
                children: [
                  if (pot != null)
                    // `box-shadow: 0 0 0 2px var(--bg)` in the prototype.
                    DecoratedBox(
                      key: const Key('pot-bar-avatar'),
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: colors['surface.page'],
                          width: 2,
                          strokeAlign: BorderSide.strokeAlignOutside,
                        ),
                      ),
                      child: PotAvatar(pot: pot, size: AvatarSize.sm),
                    ),
                  Expanded(
                    child: Text(
                      l10n.potCoordinates(name),
                      style: text.bodyMedium?.copyWith(color: onDark),
                    ),
                  ),
                ],
              ),
              ink: onDark,
            ),
          ),
          const SizedBox(width: 12),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: onDark,
              foregroundColor: dark,
              shape: const StadiumBorder(),
            ),
            onPressed: () => takeOverWork(context, ref, work),
            child: Text(l10n.takeOver),
          ),
        ],
      ),
    );
  }
}

/// A `pot-instruction` message: "From `pot`" above, "Not sent by you" under.
/// The name comes from the message `details`, never from its text.
Widget? potInstructionEntry(BuildContext context, Message message) {
  final pot = message.pot;
  if (message.systemKind != 'pot-instruction' || pot == null) return null;
  final l10n = AppLocalizations.of(context);
  final colors = PircColorTokens.of(context);
  return UserMessage(
    message: message,
    tag: Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        decoration: BoxDecoration(
          color: colors['action.primary'],
          borderRadius: BorderRadius.circular(PircRadius.pill),
        ),
        child: Text(
          l10n.fromPot(pot.potName),
          style: Theme.of(
            context,
          ).textTheme.labelLarge?.copyWith(color: colors['action.onPrimary']),
        ),
      ),
    ),
    source: l10n.notSentByYou,
  );
}
