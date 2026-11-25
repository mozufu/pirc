import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pirc_client/pirc_client.dart';
import 'package:pirc_ui/pirc_ui.dart';

import '../../l10n/app_localizations.dart';
import '../connection/connection.dart';
import '../connection/data.dart';
import 'timeline.dart';
import 'work_data.dart';

/// The name of the pot that opened [work], if known.
String potName(WidgetRef ref, PotWork work) =>
    ref
        .watch(potsProvider)
        .value
        ?.where((pot) => pot.id == work.potId)
        .firstOrNull
        ?.name ??
    '';

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

/// While a pot coordinates the work: a dark bar with 接管 (Take over). After
/// a take-over, from this device or another: a plain banner.
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
    final name = potName(ref, work);
    if (!work.open) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
        child: Text(
          l10n.takenOver(name),
          textAlign: TextAlign.center,
          style: text.bodySmall,
        ),
      );
    }
    final dark = colors['action.primary'];
    final onDark = colors['action.onPrimary'];
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
      decoration: BoxDecoration(
        color: dark,
        borderRadius: BorderRadius.circular(PircRadius.lg),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              l10n.potCoordinates(name),
              style: text.bodyMedium?.copyWith(color: onDark),
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
