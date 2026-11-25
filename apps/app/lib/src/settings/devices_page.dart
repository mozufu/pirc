import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:pirc_client/pirc_client.dart';
import 'package:pirc_ui/pirc_ui.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../l10n/app_localizations.dart';
import '../connection/connection.dart';
import '../connection/data.dart';
import '../format.dart';
import 'management_access.dart';

/// Paired devices, read with the `devices:read` grant.
final devicesProvider = FutureProvider.autoDispose<List<DeviceSummary>>((ref) {
  final access = ref.watch(managementAccessProvider);
  if (!access.covers('devices:read')) return const [];
  return DevicesApi(requireApi(ref)).list();
});

/// Asks for management access and shows where to approve it.
class AccessCard extends ConsumerWidget {
  const AccessCard({
    super.key,
    required this.capabilities,
    required this.reason,
  });

  final List<String> capabilities;
  final String reason;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final text = Theme.of(context).textTheme;
    final access = ref.watch(managementAccessProvider);
    final actions = ref.read(managementAccessProvider.notifier);
    // Several cards may ask for different access: each shows its own request.
    final mine =
        access.capabilities.length == capabilities.length &&
        access.capabilities.every(capabilities.contains);
    final waiting = mine && access.phase == AccessPhase.waiting;
    return Card(
      margin: const EdgeInsets.all(16),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(l10n.accessNeeded, style: text.titleMedium),
            const SizedBox(height: 4),
            Text(reason, style: text.bodySmall),
            if (waiting && access.address != null) ...[
              const SizedBox(height: 12),
              Text(l10n.accessOpenInBrowser, style: text.bodySmall),
              const SizedBox(height: 4),
              SelectableText(
                access.address.toString(),
                key: const Key('access-address'),
                style: text.bodyMedium,
              ),
              if (access.expiresAt != null)
                Text(
                  l10n.accessRequestExpires(
                    clockTime(
                      context,
                      access.expiresAt!.millisecondsSinceEpoch,
                      now: ref.read(clockProvider)(),
                    ),
                  ),
                  style: text.bodySmall,
                ),
            ],
            if (mine && access.phase == AccessPhase.denied)
              Text(l10n.accessDenied, style: text.bodySmall),
            if (mine && access.phase == AccessPhase.expired)
              Text(l10n.accessExpired, style: text.bodySmall),
            if (mine && access.error != null)
              Text(access.error!, style: text.bodySmall),
            const SizedBox(height: 12),
            Row(
              children: [
                if (waiting) ...[
                  OutlinedButton.icon(
                    onPressed: () => Clipboard.setData(
                      ClipboardData(text: access.address.toString()),
                    ),
                    icon: const Icon(LucideIcons.copy, size: 16),
                    label: Text(l10n.copy),
                  ),
                  const SizedBox(width: 8),
                  TextButton(
                    onPressed: actions.cancel,
                    child: Text(l10n.cancel),
                  ),
                ] else
                  FilledButton(
                    onPressed: access.phase == AccessPhase.requesting
                        ? null
                        : () => actions.request(capabilities),
                    child: Text(l10n.accessAsk),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Settings → Devices: list (`devices:read`), revoke (`devices:revoke`) and
/// "Pair a new device" (`devices:pair`), which shows the link and its QR
/// code one time, with the new device's lifetime.
class DevicesPage extends ConsumerWidget {
  const DevicesPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final access = ref.watch(managementAccessProvider);
    final devices = ref.watch(devicesProvider);
    return Scaffold(
      appBar: AppBar(title: Text(l10n.settingsDevices)),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: ListView(
            children: [
              if (!access.covers('devices:read'))
                AccessCard(
                  capabilities: const ['devices:read', 'devices:revoke'],
                  reason: l10n.accessDevicesReason,
                )
              else ...[
                ...switch (devices) {
                  AsyncValue(:final value?) => [
                    for (final device in value)
                      ListTile(
                        leading: const Icon(LucideIcons.smartphone),
                        title: Text(device.name),
                        subtitle: Text(
                          l10n.deviceLastUsed(
                            listTime(
                              context,
                              device.lastUsedAt,
                              now: ref.read(clockProvider)(),
                            ),
                          ),
                        ),
                        trailing: access.covers('devices:revoke')
                            ? TextButton(
                                onPressed: () => _revoke(context, ref, device),
                                child: Text(l10n.deviceRevoke),
                              )
                            : null,
                      ),
                  ],
                  AsyncValue(:final error?) => [
                    ListTile(
                      title: Text(l10n.listFailed),
                      subtitle: Text('$error'),
                    ),
                  ],
                  _ => [const Center(child: CircularProgressIndicator())],
                },
                if (!access.covers('devices:revoke'))
                  ListTile(
                    leading: const Icon(LucideIcons.lock),
                    title: Text(l10n.deviceRevokeNeedsAccess),
                  ),
              ],
              const Divider(),
              if (access.covers('devices:pair'))
                ListTile(
                  leading: const Icon(LucideIcons.qrCode),
                  title: Text(l10n.devicePair),
                  onTap: () => _pair(context, ref),
                )
              else
                AccessCard(
                  capabilities: const ['devices:pair', 'devices:read'],
                  reason: l10n.accessPairReason,
                ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _revoke(
    BuildContext context,
    WidgetRef ref,
    DeviceSummary device,
  ) async {
    final l10n = AppLocalizations.of(context);
    final sure = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.deviceRevokeTitle(device.name)),
        content: Text(l10n.deviceRevokeBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(l10n.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(l10n.deviceRevoke),
          ),
        ],
      ),
    );
    if (sure != true) return;
    try {
      await DevicesApi(ref.read(apiProvider)!).revoke(device.id);
      ref.invalidate(devicesProvider);
    } on PircException catch (error) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l10n.actionFailed(error.message))),
        );
      }
    }
  }

  Future<void> _pair(BuildContext context, WidgetRef ref) async {
    final l10n = AppLocalizations.of(context);
    final name = await showDialog<String>(
      context: context,
      builder: (context) => _NameDialog(title: l10n.devicePair),
    );
    if (name == null || name.isEmpty || !context.mounted) return;
    try {
      final (device, token) = await DevicesApi(
        ref.read(apiProvider)!,
      ).pair(name);
      final gateway = ref.read(connectionProvider).connection!.gateway;
      final link = Uri(
        scheme: 'pirc',
        host: 'pair',
        queryParameters: {
          'url': gateway.replace(path: '').toString(),
          'token': token,
        },
      ).toString();
      ref.invalidate(devicesProvider);
      if (!context.mounted) return;
      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (context) => AlertDialog(
          title: Text(l10n.devicePaired(device.name)),
          content: SizedBox(
            width: 320,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(l10n.devicePairOnce),
                const SizedBox(height: 12),
                ColoredBox(
                  color: Colors.white,
                  child: QrImageView(data: link, size: 220),
                ),
                const SizedBox(height: 12),
                SelectableText(link, key: const Key('pair-link')),
                if (device.expiresAt > 0)
                  Text(
                    l10n.deviceExpires(
                      listTime(
                        context,
                        device.expiresAt,
                        now: ref.read(clockProvider)(),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Clipboard.setData(ClipboardData(text: link)),
              child: Text(l10n.copy),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context),
              child: Text(l10n.done),
            ),
          ],
        ),
      );
    } on PircException catch (error) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l10n.actionFailed(error.message))),
        );
      }
    }
  }
}

class _NameDialog extends StatefulWidget {
  const _NameDialog({required this.title});
  final String title;

  @override
  State<_NameDialog> createState() => _NameDialogState();
}

class _NameDialogState extends State<_NameDialog> {
  final _name = TextEditingController();

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return AlertDialog(
      title: Text(widget.title),
      content: TextField(
        key: const Key('device-name'),
        controller: _name,
        autofocus: true,
        maxLength: 100,
        decoration: InputDecoration(labelText: l10n.deviceName),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(l10n.cancel),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, _name.text.trim()),
          child: Text(l10n.devicePairAction),
        ),
      ],
    );
  }
}

/// The Web build's approval screen (`/?nativeManagement=<id>`): the device,
/// each capability in its own words, the pairing lifetime for
/// `devices:pair`, and Approve or Deny. The Gateway accepts these two calls
/// only from a browser identity.
class ManagementApprovalScreen extends ConsumerStatefulWidget {
  const ManagementApprovalScreen({super.key, required this.requestId});
  final String requestId;

  @override
  ConsumerState<ManagementApprovalScreen> createState() =>
      _ManagementApprovalScreenState();
}

final _approvalRequestProvider = FutureProvider.autoDispose
    .family<ManagementRequest, String>(
      (ref, id) => ManagementApi(requireApi(ref)).view(id),
    );

class _ManagementApprovalScreenState
    extends ConsumerState<ManagementApprovalScreen> {
  ManagementRequest? _decided;
  String? _error;
  bool _busy = false;

  Future<void> _decide(bool approve) async {
    setState(() => _busy = true);
    try {
      final api = ManagementApi(ref.read(apiProvider)!);
      final result = approve
          ? await api.approve(widget.requestId)
          : await api.deny(widget.requestId);
      setState(() => _decided = result);
    } on PircException catch (error) {
      setState(() => _error = error.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final text = Theme.of(context).textTheme;
    final request = ref.watch(_approvalRequestProvider(widget.requestId));
    String capability(String c) => switch (c) {
      'providers' => l10n.capabilityProviders,
      'devices:read' => l10n.capabilityDevicesRead,
      'devices:revoke' => l10n.capabilityDevicesRevoke,
      'devices:pair' => l10n.capabilityDevicesPair,
      _ => c,
    };
    final Widget body = switch (request) {
      AsyncValue(:final value?) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(l10n.approvalTitle(value.deviceName), style: text.titleLarge),
          const SizedBox(height: 12),
          for (final c in value.capabilities)
            ListTile(
              leading: const Icon(LucideIcons.keyRound),
              title: Text(capability(c)),
              subtitle: c == 'devices:pair' && value.pairingMaxDays != null
                  ? Text(
                      l10n.approvalPairingLifetime(
                        value.pairingIdleDays ?? 0,
                        value.pairingMaxDays!,
                      ),
                    )
                  : null,
            ),
          const SizedBox(height: 12),
          Text(l10n.approvalGrantLifetime, style: text.bodySmall),
          const SizedBox(height: 16),
          if (_decided != null)
            Text(
              _decided!.status == 'approved'
                  ? l10n.approvalApproved
                  : l10n.approvalDenied,
              style: text.titleMedium,
            )
          else if (value.status != 'pending')
            Text(l10n.approvalNotPending, style: text.titleMedium)
          else
            Row(
              children: [
                OutlinedButton(
                  onPressed: _busy ? null : () => _decide(false),
                  child: Text(l10n.approvalDeny),
                ),
                const SizedBox(width: 12),
                FilledButton(
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
            child: Padding(
              padding: const EdgeInsets.all(PircSpacing.stackXl),
              child: body,
            ),
          ),
        ),
      ),
    );
  }
}
