import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:pirc_ui/pirc_ui.dart';

import '../../l10n/app_localizations.dart';
import 'connection.dart';
import 'hints.dart';
import 'pairing.dart';

/// Pairing v1: the user pastes the link the Gateway's web page shows. The QR
/// scanner and the `pirc` URL scheme come in M8; the Web build has no page.
class PairingScreen extends ConsumerStatefulWidget {
  const PairingScreen({super.key});

  @override
  ConsumerState<PairingScreen> createState() => _PairingScreenState();
}

class _PairingScreenState extends ConsumerState<PairingScreen> {
  final _link = TextEditingController();

  @override
  void dispose() {
    _link.dispose();
    super.dispose();
  }

  void _submit() => ref.read(pairingProvider.notifier).submit(_link.text);

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final text = Theme.of(context).textTheme;
    final colors = PircColorTokens.of(context);
    final pairing = ref.watch(pairingProvider);
    final checking = pairing.phase == PairingPhase.checking;
    final problem = switch (pairing.problem) {
      PairingProblem.notALink => l10n.pairNotALink,
      PairingProblem.tokenRefused => l10n.pairTokenRefused,
      PairingProblem.appTooOld => l10n.pairAppTooOld,
      PairingProblem.unreachable => l10n.pairUnreachable,
      PairingProblem.failed => l10n.pairFailed,
      null => null,
    };
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(PircSpacing.stackXl),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 440),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(l10n.pairTitle, style: text.headlineSmall),
                  const SizedBox(height: PircSpacing.stackSm),
                  Text(l10n.pairBody, style: text.bodySmall),
                  const SizedBox(height: PircSpacing.stackXl),
                  TextField(
                    key: const Key('pairing-link'),
                    controller: _link,
                    enabled: !checking,
                    autocorrect: false,
                    enableSuggestions: false,
                    keyboardType: TextInputType.url,
                    decoration: InputDecoration(
                      labelText: l10n.pairLinkLabel,
                      hintText: 'pirc://pair?url=…&token=…',
                      border: const OutlineInputBorder(),
                    ),
                    onChanged: (_) {
                      if (pairing.phase == PairingPhase.invalid) {
                        ref.read(pairingProvider.notifier).reset();
                      }
                    },
                    onSubmitted: (_) => _submit(),
                  ),
                  if (problem != null) ...[
                    const SizedBox(height: PircSpacing.stackSm),
                    Row(
                      children: [
                        Icon(
                          LucideIcons.circleX,
                          size: PircSize.iconInline,
                          color: colors['status.danger'],
                        ),
                        const SizedBox(width: PircSpacing.stackXs),
                        Expanded(
                          child: Text(
                            problem,
                            style: text.bodySmall?.copyWith(
                              color: colors['status.danger'],
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                  const SizedBox(height: PircSpacing.stackLg),
                  FilledButton(
                    onPressed: checking ? null : _submit,
                    child: Text(switch (pairing.phase) {
                      PairingPhase.checking => l10n.pairChecking,
                      PairingPhase.paired => l10n.pairPaired,
                      _ => l10n.pairAction,
                    }),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The Gateway refused this build (426).
class UpgradeScreen extends StatelessWidget {
  const UpgradeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return BlockingPage(
      icon: LucideIcons.circleArrowUp,
      title: l10n.upgradeTitle,
      body: l10n.upgradeBody,
    );
  }
}

/// The Web build's sign-in ended.
class SignedOutScreen extends StatelessWidget {
  const SignedOutScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return BlockingPage(
      icon: LucideIcons.logIn,
      title: l10n.signedOutTitle,
      body: l10n.signedOutBody,
    );
  }
}

/// Wraps every page: the offline or reconnecting bar on top, and the loading
/// page (no buttons) until the first connection is known.
class ConnectionFrame extends ConsumerWidget {
  const ConnectionFrame({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final state = ref.watch(appConnectionStateProvider);
    final hadConnection = ref.watch(
      connectionProvider.select((status) => status.connection != null),
    );
    if (state == AppConnectionState.connecting && !hadConnection) {
      return LoadingOverlay(title: l10n.loadingTitle, note: l10n.loadingNote);
    }
    final banner = switch (state) {
      AppConnectionState.offline => ConnectionBanner(text: l10n.offlineBanner),
      AppConnectionState.reconnecting || AppConnectionState.connecting =>
        ConnectionBanner(text: l10n.reconnecting, reconnecting: true),
      _ => null,
    };
    if (banner == null) return child;
    return Column(
      children: [
        banner,
        Expanded(
          child: MediaQuery.removePadding(
            context: context,
            removeTop: true,
            child: child,
          ),
        ),
      ],
    );
  }
}
