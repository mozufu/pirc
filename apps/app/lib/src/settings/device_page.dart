import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pirc_client/pirc_client.dart';
import 'package:pirc_ui/pirc_ui.dart';

import '../../l10n/app_localizations.dart';
import '../connection/connection.dart';
import '../connection/connection_screens.dart';
import '../connection/data.dart';
import '../work/client_names.dart';
import '../work/session_controller.dart';
import 'settings_widgets.dart';

/// This paired device's own record (`GET /api/device`).
final thisDeviceProvider = FutureProvider.autoDispose<DeviceSummary>(
  (ref) => DeviceApi(requireApi(ref)).read(),
);

/// Settings → This device: a paired app reads and renames its device record;
/// the Web build keeps a browser name in app storage (empty lets the Gateway
/// name it from the user agent).
class ThisDevicePage extends ConsumerStatefulWidget {
  const ThisDevicePage({super.key});

  @override
  ConsumerState<ThisDevicePage> createState() => _ThisDevicePageState();
}

class _ThisDevicePageState extends ConsumerState<ThisDevicePage> {
  final _name = TextEditingController();
  String? _error;
  bool _saving = false;
  bool _edited = false;

  @override
  void initState() {
    super.initState();
    if (ref.read(isWebProvider)) {
      _name.text = ref.read(webClientNameProvider) ?? '';
    }
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final l10n = AppLocalizations.of(context);
    final web = ref.read(isWebProvider);
    final name = _name.text.trim();
    final length = name.runes.length;
    if ((!web && length == 0) || length > 60) {
      setState(() => _error = l10n.thisDeviceNameRule);
      return;
    }
    final api = ref.read(apiProvider);
    if (api == null) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      if (web) {
        await ref
            .read(webClientNameProvider.notifier)
            .set(name.isEmpty ? null : name);
        _name.text = name;
        _edited = true;
        if (name.isNotEmpty) {
          final client = await ClientsApi(
            api,
          ).rename(ref.read(clientIdProvider), name);
          ref.read(clientNamesProvider.notifier).remember(client);
        }
      } else {
        final device = await DeviceApi(api).rename(name);
        _name.text = device.name;
        _edited = true;
      }
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l10n.thisDeviceSaved)));
    } on PircException catch (error) {
      if (mounted) setState(() => _error = l10n.actionFailed(error.message));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Widget _form(AppLocalizations l10n, {required bool web}) => Padding(
    padding: const EdgeInsets.all(PircSpacing.stackLg),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          key: const Key('this-device-name'),
          controller: _name,
          autofocus: false,
          decoration: InputDecoration(
            labelText: l10n.deviceName,
            hintText: web ? l10n.thisDeviceWebHint : null,
            errorText: _error,
          ),
          onChanged: (_) => setState(() => _edited = true),
          onSubmitted: (_) => _save(),
        ),
        if (web)
          Text(
            l10n.thisDeviceWebHint,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        const SizedBox(height: PircSpacing.stackMd),
        Align(
          alignment: AlignmentDirectional.centerEnd,
          child: FilledButton(
            key: const Key('this-device-save'),
            onPressed: _saving ? null : _save,
            child: Text(l10n.save),
          ),
        ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final web = ref.watch(isWebProvider);
    final Widget body;
    if (web) {
      body = _form(l10n, web: true);
    } else {
      final device = ref.watch(thisDeviceProvider);
      ref.listen(thisDeviceProvider, (_, next) {
        final name = next.value?.name;
        if (name != null && !_edited && _name.text != name) {
          _name.text = name;
        }
      });
      body = switch (device) {
        AsyncValue(:final hasValue) when hasValue => _form(l10n, web: false),
        AsyncValue(:final error?) when error is! NotConnected => ListTile(
          title: Text(l10n.listFailed),
          subtitle: Text('$error'),
          trailing: TextButton(
            onPressed: () => ref.invalidate(thisDeviceProvider),
            child: Text(l10n.retry),
          ),
        ),
        _ => const Padding(
          padding: EdgeInsets.all(PircSpacing.stackXl),
          child: Center(child: CircularProgressIndicator()),
        ),
      };
    }
    return SettingsPage(
      title: l10n.settingsThisDevice,
      children: [
        SettingsGroup(children: [if (!web) const PairingEndWarning(), body]),
      ],
    );
  }
}
