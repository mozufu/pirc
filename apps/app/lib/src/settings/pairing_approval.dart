import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:pirc_client/pirc_client.dart';
import 'package:pirc_ui/pirc_ui.dart';

import '../../l10n/app_localizations.dart';
import '../connection/data.dart';
import '../format.dart';

final _pairingApprovalProvider = FutureProvider.autoDispose
    .family<PairingApproval, String>(
      (ref, id) => PairingApi(requireApi(ref)).view(id),
    );

/// The Web build's pairing v2 approval page (`/?pair=<id>`, plans/roadmap.md
/// M8 step 2; served from M9): the device name, its platform, how long the
/// device stays paired, and Approve or Deny. After Approve it shows the
/// 6-digit code to type in the app; on a reload it shows it again while the
/// Gateway still gives it (only to the user who approved, while the app can
/// claim). The Gateway accepts these calls only from a browser identity.
class PairingApprovalScreen extends ConsumerStatefulWidget {
  const PairingApprovalScreen({super.key, required this.requestId});
  final String requestId;

  @override
  ConsumerState<PairingApprovalScreen> createState() =>
      _PairingApprovalScreenState();
}

class _PairingApprovalScreenState extends ConsumerState<PairingApprovalScreen> {
  PairingApproval? _decided;
  String? _error;
  bool _busy = false;

  Future<void> _decide(bool approve) async {
    final api = ref.read(apiProvider);
    if (api == null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final pairing = PairingApi(api);
      final result = approve
          ? await pairing.approve(widget.requestId)
          : await pairing.deny(widget.requestId);
      if (mounted) setState(() => _decided = result);
    } on ApiError catch (error) {
      if (!mounted) return;
      if (error.status == 409 || error.status == 404) {
        // Decided elsewhere or gone: show what the Gateway says now.
        ref.invalidate(_pairingApprovalProvider(widget.requestId));
      } else {
        setState(() => _error = error.message);
      }
    } on PircException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _code(BuildContext context, PairingApproval approved) {
    final l10n = AppLocalizations.of(context);
    final text = Theme.of(context).textTheme;
    final code = approved.code ?? '';
    final expires = ref
        .read(clockProvider)()
        .add(Duration(milliseconds: approved.expiresAt - approved.serverNow));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(l10n.pairApprovalCodeTitle, style: text.titleMedium),
        const SizedBox(height: 12),
        SelectableText(
          // Two groups of three, read aloud more easily.
          code.length == 6
              ? '${code.substring(0, 3)} ${code.substring(3)}'
              : code,
          key: const Key('pairing-approval-code'),
          style: text.displayMedium?.copyWith(
            fontFeatures: const [FontFeature.tabularFigures()],
            letterSpacing: 4,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          l10n.pairApprovalCodeNote(
            clockTime(
              context,
              expires.millisecondsSinceEpoch,
              now: ref.read(clockProvider)(),
            ),
          ),
          style: text.bodySmall,
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final text = Theme.of(context).textTheme;
    final request = ref.watch(_pairingApprovalProvider(widget.requestId));
    final decided = _decided;
    final Widget body = switch (request) {
      AsyncValue(:final value?) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            l10n.pairApprovalTitle(value.deviceName),
            style: text.titleLarge,
          ),
          const SizedBox(height: 12),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(LucideIcons.smartphone),
            title: Text(value.deviceName),
            subtitle: Text(l10n.pairApprovalPlatform(value.platform)),
          ),
          if (value.maxDays != null)
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(LucideIcons.clock),
              title: Text(
                l10n.approvalPairingLifetime(
                  value.idleDays ?? 0,
                  value.maxDays!,
                ),
              ),
            ),
          const SizedBox(height: 4),
          Text(l10n.pairApprovalNote, style: text.bodySmall),
          const SizedBox(height: 16),
          if (decided != null && decided.status == 'approved')
            _code(context, decided)
          // Approved by this user, reloaded: the Gateway gives the code
          // again while the app can still claim, so the approver can finish.
          else if (decided == null &&
              value.status == 'approved' &&
              (value.code ?? '').isNotEmpty)
            _code(context, value)
          else if (decided != null)
            Text(l10n.pairApprovalDenied, style: text.titleMedium)
          else if (value.status == 'expired')
            Text(l10n.pairApprovalExpired, style: text.titleMedium)
          else if (value.status != 'pending')
            Text(l10n.pairApprovalDecided, style: text.titleMedium)
          else
            Row(
              children: [
                OutlinedButton(
                  key: const Key('pairing-approval-deny'),
                  onPressed: _busy ? null : () => _decide(false),
                  child: Text(l10n.approvalDeny),
                ),
                const SizedBox(width: 12),
                FilledButton(
                  key: const Key('pairing-approval-approve'),
                  onPressed: _busy ? null : () => _decide(true),
                  child: Text(l10n.approvalApprove),
                ),
              ],
            ),
          if (_error != null) Text(_error!, style: text.bodySmall),
        ],
      ),
      AsyncValue(:final error?) when error is! NotConnected => Text(
        l10n.approvalMissing,
      ),
      _ => const Center(child: CircularProgressIndicator()),
    };
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(PircSpacing.stackXl),
              child: body,
            ),
          ),
        ),
      ),
    );
  }
}
