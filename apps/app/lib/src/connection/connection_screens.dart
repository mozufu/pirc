import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:pirc_ui/pirc_ui.dart';

import '../../l10n/app_localizations.dart';
import '../format.dart';
import '../platform/scanner.dart';
import 'connection.dart';
import 'hints.dart';
import 'pairing.dart';
import 'pairing_v2.dart';
import 'rotation.dart';
import 'storage.dart';

/// The pairing page (M6 step 2, M8 step 2). Pairing v1: the user pastes the
/// link the Gateway's web page shows, scans its QR code (Android), or opens
/// it as a `pirc://pair` link, which only fills the field. Pairing v2, when
/// [pairingV2EnabledProvider] is on: the user gives the Gateway address and
/// approves this device in a browser. The Web build has no page.
class PairingScreen extends ConsumerStatefulWidget {
  const PairingScreen({super.key});

  @override
  ConsumerState<PairingScreen> createState() => _PairingScreenState();
}

class _PairingScreenState extends ConsumerState<PairingScreen> {
  final _link = TextEditingController();
  final _address = TextEditingController();
  final _name = TextEditingController();
  bool _named = false;
  String? _scanProblem;

  /// The Gateway of a link that opened the app or was scanned; the user
  /// checks it and taps Pair.
  String? _opened;
  bool _scanned = false;

  @override
  void initState() {
    super.initState();
    // Pairing again keeps the Gateway address that was used.
    _address.text =
        ref.read(sharedPreferencesProvider).getString(PrefKeys.gatewayUrl) ??
        '';
    final link = ref.read(pairLinkInboxProvider);
    if (link != null) _fill(link);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_named) {
      _named = true;
      _name.text = AppLocalizations.of(context).pairV2DefaultName;
    }
  }

  @override
  void dispose() {
    _link.dispose();
    _address.dispose();
    _name.dispose();
    super.dispose();
  }

  /// Fills in a link that opened the app; the user still taps Pair.
  void _fill(String link) {
    // Providers do not change while the page builds.
    scheduleMicrotask(() {
      if (!mounted) return;
      ref.read(pairLinkInboxProvider.notifier).take();
      ref.read(pairingProvider.notifier).reset();
    });
    _link.text = link;
    _opened = PairingLink.parse(link)?.gateway.host;
    _scanned = false;
  }

  void _submit() => ref.read(pairingProvider.notifier).submit(_link.text);

  Future<void> _scan() async {
    final scanner = ref.read(scannerProvider);
    if (scanner == null) return;
    final l10n = AppLocalizations.of(context);
    final v2 = ref.read(pairingV2EnabledProvider);
    setState(() => _scanProblem = null);
    final String? text;
    try {
      text = await scanner.scan();
    } on ScanFailure catch (failure) {
      if (!mounted) return;
      setState(
        () => _scanProblem = switch (failure.code) {
          'SCAN_DOWNLOADING' => l10n.pairScanDownloading,
          'SCAN_UNSUPPORTED' => l10n.pairScanUnsupported,
          _ => l10n.pairScanFailed,
        },
      );
      return;
    }
    if (!mounted || text == null) return;
    final scanned = text;
    final link = PairingLink.parse(scanned);
    if (link != null) {
      // As an opened link: show where it pairs, and wait for Pair.
      ref.read(pairingProvider.notifier).reset();
      setState(() {
        _link.text = scanned;
        _opened = link.gateway.host;
        _scanned = true;
      });
    } else if (v2 && gatewayOrigin(text) != null) {
      // A QR code that holds only the Gateway address (pairing v2).
      setState(() => _address.text = text!.trim());
    } else {
      setState(
        () => _scanProblem = v2 ? l10n.pairNotACodeV2 : l10n.pairNotACode,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final text = Theme.of(context).textTheme;
    final pairing = ref.watch(pairingProvider);
    final v2 = ref.watch(pairingV2EnabledProvider);
    final flow = v2 ? ref.watch(pairingV2Provider) : null;
    final scanner = ref.watch(scannerProvider);
    final expired = ref.watch(
      connectionProvider.select((status) => status.pairingExpired),
    );
    ref.listen(pairLinkInboxProvider, (_, link) {
      if (link != null) setState(() => _fill(link));
    });
    final checking = pairing.phase == PairingPhase.checking;
    final problem = switch (pairing.problem) {
      PairingProblem.notALink => l10n.pairNotALink,
      PairingProblem.tokenRefused => l10n.pairTokenRefused,
      PairingProblem.appTooOld => l10n.pairAppTooOld,
      PairingProblem.unreachable => l10n.pairUnreachable,
      PairingProblem.failed => l10n.pairFailed,
      null => _scanProblem,
    };
    final List<Widget> children;
    if (flow != null && flow.phase != PairingV2Phase.address) {
      children = [PairingV2Flow(state: flow)];
    } else {
      children = [
        Text(l10n.pairTitle, style: text.headlineSmall),
        if (expired) ...[
          const SizedBox(height: PircSpacing.stackSm),
          _Notice(key: const Key('pairing-expired'), text: l10n.pairExpired),
        ],
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
            if (_opened != null || _scanProblem != null) {
              setState(() {
                _opened = null;
                _scanProblem = null;
              });
            }
            if (pairing.phase == PairingPhase.invalid) {
              ref.read(pairingProvider.notifier).reset();
            }
          },
          onSubmitted: (_) => _submit(),
        ),
        if (_opened != null && problem == null) ...[
          const SizedBox(height: PircSpacing.stackSm),
          Text(
            _scanned
                ? l10n.pairLinkScanned(_opened!)
                : l10n.pairLinkOpened(_opened!),
            style: text.bodySmall,
          ),
        ],
        if (problem != null) ...[
          const SizedBox(height: PircSpacing.stackSm),
          _Problem(text: problem),
        ],
        const SizedBox(height: PircSpacing.stackLg),
        Row(
          children: [
            if (scanner != null) ...[
              OutlinedButton.icon(
                key: const Key('pairing-scan'),
                onPressed: checking ? null : _scan,
                icon: const Icon(LucideIcons.scanQrCode),
                label: Text(l10n.pairScan),
              ),
              const SizedBox(width: PircSpacing.stackSm),
            ],
            Expanded(
              child: FilledButton(
                key: const Key('pairing-submit'),
                onPressed: checking ? null : _submit,
                child: Text(switch (pairing.phase) {
                  PairingPhase.checking => l10n.pairChecking,
                  PairingPhase.paired => l10n.pairPaired,
                  _ => l10n.pairAction,
                }),
              ),
            ),
          ],
        ),
        if (flow != null) ...[
          const SizedBox(height: PircSpacing.stackXl),
          const Divider(),
          const SizedBox(height: PircSpacing.stackXl),
          Text(l10n.pairV2Title, style: text.titleMedium),
          const SizedBox(height: PircSpacing.stackSm),
          Text(l10n.pairV2Body, style: text.bodySmall),
          const SizedBox(height: PircSpacing.stackLg),
          TextField(
            key: const Key('pairing-v2-address'),
            controller: _address,
            autocorrect: false,
            enableSuggestions: false,
            keyboardType: TextInputType.url,
            decoration: InputDecoration(
              labelText: l10n.pairV2AddressLabel,
              hintText: 'https://pirc.example',
              border: const OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: PircSpacing.stackMd),
          TextField(
            key: const Key('pairing-v2-name'),
            controller: _name,
            maxLength: 100,
            decoration: InputDecoration(
              labelText: l10n.deviceName,
              border: const OutlineInputBorder(),
            ),
          ),
          if (flow.problem != null) ...[
            const SizedBox(height: PircSpacing.stackSm),
            _Problem(text: pairingV2ProblemText(l10n, flow.problem!)),
          ],
          const SizedBox(height: PircSpacing.stackLg),
          FilledButton(
            key: const Key('pairing-v2-start'),
            onPressed: () => ref
                .read(pairingV2Provider.notifier)
                .start(_address.text, _name.text),
            child: Text(l10n.pairV2Start),
          ),
        ],
      ];
    }
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(PircSpacing.stackXl),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 440),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: children,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

String pairingV2ProblemText(AppLocalizations l10n, PairingV2Problem problem) =>
    switch (problem) {
      PairingV2Problem.notAnAddress => l10n.pairV2NotAnAddress,
      PairingV2Problem.badName => l10n.pairV2BadName,
      PairingV2Problem.unreachable => l10n.pairUnreachable,
      PairingV2Problem.appTooOld => l10n.pairAppTooOld,
      PairingV2Problem.tooManyRequests => l10n.pairV2TooManyRequests,
      PairingV2Problem.tooManyPhones => l10n.pairV2TooManyPhones,
      PairingV2Problem.failed => l10n.pairV2Failed,
    };

/// A pairing v2 request after it was created: the device name, where to
/// approve it, the code, and each state with its own text.
class PairingV2Flow extends ConsumerStatefulWidget {
  const PairingV2Flow({super.key, required this.state});

  final PairingV2State state;

  @override
  ConsumerState<PairingV2Flow> createState() => _PairingV2FlowState();
}

class _PairingV2FlowState extends ConsumerState<PairingV2Flow> {
  final _code = TextEditingController();

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  void _claim() => ref.read(pairingV2Provider.notifier).claim(_code.text);

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final text = Theme.of(context).textTheme;
    final flow = widget.state;
    final controller = ref.read(pairingV2Provider.notifier);
    final status = switch (flow.phase) {
      PairingV2Phase.creating => l10n.pairV2Creating,
      PairingV2Phase.waiting => l10n.pairV2Waiting,
      PairingV2Phase.approved => l10n.pairV2Approved,
      PairingV2Phase.claiming => l10n.pairV2Claiming,
      PairingV2Phase.wrongCode when (flow.attemptsLeft ?? 0) > 0 =>
        l10n.pairV2WrongCode(flow.attemptsLeft!),
      PairingV2Phase.wrongCode => l10n.pairV2TooManyCodes,
      PairingV2Phase.denied => l10n.pairV2Denied,
      PairingV2Phase.expired => l10n.pairV2Expired,
      PairingV2Phase.failed => pairingV2ProblemText(
        l10n,
        flow.problem ?? PairingV2Problem.failed,
      ),
      PairingV2Phase.paired => l10n.pairV2Paired,
      PairingV2Phase.address => '',
    };
    final ended = switch (flow.phase) {
      PairingV2Phase.denied ||
      PairingV2Phase.expired ||
      PairingV2Phase.failed => true,
      PairingV2Phase.wrongCode => !flow.open,
      _ => false,
    };
    final address = flow.approveAddress;
    return Column(
      key: ValueKey('pairing-v2-${flow.phase.name}'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(l10n.pairV2Title, style: text.headlineSmall),
        const SizedBox(height: PircSpacing.stackSm),
        if (flow.deviceName.isNotEmpty)
          Text(l10n.pairV2Device(flow.deviceName), style: text.bodyMedium),
        if (address != null && !ended) ...[
          const SizedBox(height: PircSpacing.stackLg),
          Text(l10n.pairV2OpenInBrowser, style: text.titleSmall),
          const SizedBox(height: PircSpacing.stackXs),
          if (flow.browserFailed)
            Text(l10n.pairV2BrowserFailed, style: text.bodySmall),
          SelectableText(
            address.toString(),
            key: const Key('pairing-v2-approve-address'),
            style: text.bodyMedium,
          ),
          if (flow.expiresAt != null)
            Text(
              l10n.pairV2Expires(
                clockTime(
                  context,
                  flow.expiresAt!.millisecondsSinceEpoch,
                  now: ref.read(clockProvider)(),
                ),
              ),
              style: text.bodySmall,
            ),
          const SizedBox(height: PircSpacing.stackSm),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: OutlinedButton.icon(
              key: const Key('pairing-v2-open'),
              onPressed: controller.openBrowser,
              icon: const Icon(LucideIcons.externalLink),
              label: Text(l10n.pairV2OpenBrowser),
            ),
          ),
        ],
        const SizedBox(height: PircSpacing.stackLg),
        if (ended)
          _Problem(key: const Key('pairing-v2-status'), text: status)
        else
          Text(
            status,
            key: const Key('pairing-v2-status'),
            style: text.bodyMedium,
          ),
        if (flow.open && flow.problem != null) ...[
          const SizedBox(height: PircSpacing.stackSm),
          _Problem(text: pairingV2ProblemText(l10n, flow.problem!)),
        ],
        if (flow.open) ...[
          const SizedBox(height: PircSpacing.stackLg),
          TextField(
            key: const Key('pairing-v2-code'),
            controller: _code,
            enabled: flow.phase != PairingV2Phase.claiming,
            keyboardType: TextInputType.number,
            maxLength: 6,
            autocorrect: false,
            enableSuggestions: false,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            decoration: InputDecoration(
              labelText: l10n.pairV2CodeLabel,
              border: const OutlineInputBorder(),
            ),
            onSubmitted: (_) => _claim(),
          ),
          const SizedBox(height: PircSpacing.stackSm),
          FilledButton(
            key: const Key('pairing-v2-claim'),
            onPressed: flow.phase == PairingV2Phase.claiming ? null : _claim,
            child: Text(l10n.pairV2Claim),
          ),
        ],
        if (flow.phase != PairingV2Phase.paired) ...[
          const SizedBox(height: PircSpacing.stackLg),
          TextButton(
            key: const Key('pairing-v2-restart'),
            onPressed: controller.restart,
            child: Text(l10n.pairV2StartAgain),
          ),
        ],
      ],
    );
  }
}

class _Problem extends StatelessWidget {
  const _Problem({super.key, required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final colors = PircColorTokens.of(context);
    return Row(
      children: [
        Icon(
          LucideIcons.circleX,
          size: PircSize.iconInline,
          color: colors['status.danger'],
        ),
        const SizedBox(width: PircSpacing.stackXs),
        Expanded(
          child: Text(
            text,
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: colors['status.danger']),
          ),
        ),
      ],
    );
  }
}

class _Notice extends StatelessWidget {
  const _Notice({super.key, required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final colors = PircColorTokens.of(context);
    return Row(
      children: [
        Icon(
          LucideIcons.clock,
          size: PircSize.iconInline,
          color: colors['status.warning'],
        ),
        const SizedBox(width: PircSpacing.stackXs),
        Expanded(
          child: Text(text, style: Theme.of(context).textTheme.bodyMedium),
        ),
      ],
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

/// "Pairing ends on (date)…" once token rotation failed and less than three
/// days of the effective expiry are left (Settings → This device and the
/// drawer's user row); nothing otherwise.
class PairingEndWarning extends ConsumerWidget {
  const PairingEndWarning({super.key, this.compact = false});

  /// One line of small text, for the drawer.
  final bool compact;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ends = ref.watch(pairingEndWarningProvider);
    if (ends == null) return const SizedBox.shrink();
    final l10n = AppLocalizations.of(context);
    final colors = PircColorTokens.of(context);
    final date = DateFormat.yMMMd(
      Localizations.localeOf(context).toLanguageTag(),
    ).format(ends);
    final message = l10n.pairingEndsWarning(date);
    if (compact) {
      return Text(
        message,
        key: const Key('pairing-end-warning'),
        style: TextStyle(
          fontSize: 13,
          height: 18 / 13,
          color: colors['status.warning'],
        ),
      );
    }
    return ListTile(
      key: const Key('pairing-end-warning'),
      leading: Icon(LucideIcons.clock, color: colors['status.warning']),
      title: Text(message),
    );
  }
}
