import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:pirc_client/pirc_client.dart';

import '../../l10n/app_localizations.dart';
import '../connection/data.dart';
import 'devices_page.dart' show AccessCard;
import 'management_access.dart';
import 'settings_widgets.dart';

/// The providers snapshot; read only with the `providers` grant.
final providersProvider = FutureProvider.autoDispose<Map<String, Object?>?>((
  ref,
) {
  if (!ref.watch(managementAccessProvider).covers('providers')) {
    return Future.value(null);
  }
  return ProvidersApi(requireApi(ref)).snapshot();
});

/// Model providers and the default model (`/api/providers*`,
/// `/api/provider-auth/*`). A paired app needs the `providers` grant.
class ProvidersPage extends ConsumerWidget {
  const ProvidersPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final snapshot = ref.watch(providersProvider);
    final api = ref.watch(apiProvider);
    Future<void> run(Future<Object?> Function(ProvidersApi p) action) async {
      try {
        await action(ProvidersApi(api!));
        ref.invalidate(providersProvider);
      } on PircException catch (error) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(l10n.actionFailed(error.message))),
          );
        }
      }
    }

    return SettingsPage(
      title: l10n.settingsProviders,
      children: switch (snapshot) {
        AsyncValue(:final error?) when error is! NotConnected => [
          ListTile(title: Text(l10n.listFailed), subtitle: Text('$error')),
        ],
        AsyncValue(:final value) when value == null && !snapshot.isLoading => [
          AccessCard(
            capabilities: const ['providers'],
            reason: l10n.accessProvidersReason,
          ),
        ],
        AsyncValue(:final value?) => [
          SettingsGroup(
            title: l10n.providersDefaultModel,
            children: [_DefaultModel(snapshot: value, run: run)],
          ),
          SettingsGroup(
            title: l10n.providersList,
            children: [
              for (final p
                  in (value['providers'] as List? ?? const []).cast<Map>())
                ListTile(
                  leading: const Icon(LucideIcons.server, size: 20),
                  title: Text('${p['name'] ?? p['id']}'),
                  subtitle: Text(
                    l10n.providersRow(
                      '${p['api']}',
                      ((p['models'] as List?) ?? const []).length,
                    ),
                  ),
                  trailing: p['readOnly'] == true || p['source'] == 'oauth'
                      ? null
                      : PopupMenuButton<String>(
                          onSelected: (action) async {
                            if (action == 'remove') {
                              await run((api) => api.remove('${p['id']}'));
                            } else {
                              final key = await _askKey(context);
                              if (key != null) {
                                await run(
                                  (api) => api.edit('${p['id']}', {
                                    'api': p['api'],
                                    'baseUrl': p['baseUrl'],
                                    'models': [
                                      for (final m
                                          in (p['models'] as List).cast<Map>())
                                        {'id': m['id']},
                                    ],
                                    'apiKey': key,
                                  }),
                                );
                              }
                            }
                          },
                          itemBuilder: (_) => [
                            PopupMenuItem(
                              value: 'key',
                              child: Text(l10n.providersReplaceKey),
                            ),
                            PopupMenuItem(
                              value: 'remove',
                              child: Text(l10n.providersRemove),
                            ),
                          ],
                        ),
                ),
              ListTile(
                leading: const Icon(LucideIcons.plus, size: 20),
                title: Text(l10n.providersAdd),
                onTap: () async {
                  final body = await showDialog<Map<String, Object?>>(
                    context: context,
                    builder: (_) => const _AddProvider(),
                  );
                  if (body != null) await run((api) => api.add(body));
                },
              ),
            ],
          ),
          SettingsGroup(
            title: l10n.providersAccounts,
            children: [
              for (final o
                  in (value['oauthProviders'] as List? ?? const []).cast<Map>())
                ListTile(
                  leading: const Icon(LucideIcons.keyRound, size: 20),
                  title: Text('${o['name']}'),
                  subtitle: Text(
                    o['connected'] == true
                        ? l10n.providersConnected
                        : l10n.providersNotConnected,
                  ),
                  trailing: o['connected'] == true
                      ? TextButton(
                          onPressed: () =>
                              run((api) => api.remove('${o['providerId']}')),
                          child: Text(l10n.providersSignOut),
                        )
                      : TextButton(
                          onPressed: () async {
                            await showDialog<void>(
                              context: context,
                              builder: (_) => _SignIn(
                                providerId: '${o['id']}',
                                name: '${o['name']}',
                                consent: o['requiresPolicyConsent'] == true,
                              ),
                            );
                            ref.invalidate(providersProvider);
                          },
                          child: Text(l10n.providersSignIn),
                        ),
                ),
            ],
          ),
        ],
        AsyncValue(:final error?) => [
          ListTile(title: Text(l10n.listFailed), subtitle: Text('$error')),
        ],
        _ => [const Center(child: CircularProgressIndicator())],
      },
    );
  }

  static Future<String?> _askKey(BuildContext context) =>
      showDialog<String>(context: context, builder: (_) => const _KeyDialog());
}

class _DefaultModel extends StatelessWidget {
  const _DefaultModel({required this.snapshot, required this.run});
  final Map<String, Object?> snapshot;
  final Future<void> Function(Future<Object?> Function(ProvidersApi p)) run;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final current = snapshot['defaultModel'] as Map?;
    final options = [
      for (final p in (snapshot['providers'] as List? ?? const []).cast<Map>())
        for (final m in (p['models'] as List? ?? const []).cast<Map>())
          ('${p['id']}', '${m['id']}', '${m['name'] ?? m['id']}'),
    ];
    final selected = current == null
        ? null
        : '${current['provider']}/${current['id']}';
    return ListTile(
      title: Text(l10n.providersDefaultModel),
      trailing: DropdownButton<String?>(
        key: const Key('default-model'),
        value: options.any((o) => '${o.$1}/${o.$2}' == selected)
            ? selected
            : null,
        hint: Text(l10n.modelDefault),
        items: [
          for (final (provider, id, name) in options)
            DropdownMenuItem(value: '$provider/$id', child: Text(name)),
        ],
        onChanged: (value) {
          if (value == null) return;
          final slash = value.indexOf('/');
          run(
            (api) => api.setDefault(
              value.substring(0, slash),
              value.substring(slash + 1),
            ),
          );
        },
      ),
    );
  }
}

class _KeyDialog extends StatefulWidget {
  const _KeyDialog();

  @override
  State<_KeyDialog> createState() => _KeyDialogState();
}

class _KeyDialogState extends State<_KeyDialog> {
  final _key = TextEditingController();

  @override
  void dispose() {
    _key.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return AlertDialog(
      title: Text(l10n.providersReplaceKey),
      content: TextField(
        controller: _key,
        obscureText: true,
        decoration: InputDecoration(labelText: l10n.providersApiKey),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(l10n.cancel),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, _key.text),
          child: Text(l10n.save),
        ),
      ],
    );
  }
}

/// Adds a provider from a preset: its API key, then the models it lists.
class _AddProvider extends ConsumerStatefulWidget {
  const _AddProvider();

  @override
  ConsumerState<_AddProvider> createState() => _AddProviderState();
}

class _AddProviderState extends ConsumerState<_AddProvider> {
  List<Map<String, Object?>>? _presets;
  Map<String, Object?>? _preset;
  final _key = TextEditingController();
  final _id = TextEditingController();
  List<Map<String, Object?>>? _models;
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    ProvidersApi(ref.read(apiProvider)!).presets().then(
      (presets) => mounted ? setState(() => _presets = presets) : null,
      onError: (Object e) => mounted ? setState(() => _error = '$e') : null,
    );
  }

  @override
  void dispose() {
    _key.dispose();
    _id.dispose();
    super.dispose();
  }

  Map<String, Object?> get _form => {
    'api': _preset!['api'],
    'baseUrl': _preset!['baseUrl'],
    'preset': _preset!['id'],
    if (_key.text.isNotEmpty) 'apiKey': _key.text,
  };

  Future<void> _discover() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final models = await ProvidersApi(ref.read(apiProvider)!).discover(_form);
      setState(() => _models = models);
    } on PircException catch (error) {
      setState(() => _error = error.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final presets = _presets;
    return AlertDialog(
      title: Text(l10n.providersAdd),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (presets == null && _error == null)
              const Center(child: CircularProgressIndicator())
            else if (presets != null)
              DropdownButton<Map<String, Object?>>(
                isExpanded: true,
                value: _preset,
                hint: Text(l10n.providersPreset),
                items: [
                  for (final p in presets)
                    DropdownMenuItem(value: p, child: Text('${p['name']}')),
                ],
                onChanged: (p) => setState(() {
                  _preset = p;
                  _models = null;
                  _id.text = '${p?['id'] ?? ''}';
                }),
              ),
            TextField(
              controller: _id,
              decoration: InputDecoration(labelText: l10n.providersId),
            ),
            if (_preset?['keyless'] != true)
              TextField(
                controller: _key,
                obscureText: true,
                decoration: InputDecoration(labelText: l10n.providersApiKey),
              ),
            if (_models != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(l10n.providersModelsFound(_models!.length)),
              ),
            if (_error != null) Text(_error!),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(l10n.cancel),
        ),
        if (_models == null)
          FilledButton(
            onPressed: _preset == null || _busy ? null : _discover,
            child: Text(l10n.providersFindModels),
          )
        else
          FilledButton(
            onPressed: _models!.isEmpty
                ? null
                : () => Navigator.pop(context, {
                    ..._form,
                    'id': _id.text.trim(),
                    'models': [
                      for (final m in _models!)
                        {
                          'id': m['id'],
                          'name': ?m['name'],
                          'reasoning': ?m['reasoning'],
                        },
                    ],
                  }),
            child: Text(l10n.save),
          ),
      ],
    );
  }
}

/// A provider account sign-in: open the address, answer the prompts, and
/// wait until it succeeds, fails or expires.
class _SignIn extends ConsumerStatefulWidget {
  const _SignIn({
    required this.providerId,
    required this.name,
    required this.consent,
  });

  final String providerId;
  final String name;
  final bool consent;

  @override
  ConsumerState<_SignIn> createState() => _SignInState();
}

class _SignInState extends ConsumerState<_SignIn> {
  Map<String, Object?>? _session;
  Timer? _poll;
  String? _error;
  final _answer = TextEditingController();
  bool _agreed = false;

  ProvidersApi get _api => ProvidersApi(ref.read(apiProvider)!);
  bool get _pending => _session?['status'] == 'pending';

  Future<void> _start() async {
    try {
      final session = await _api.signIn(
        widget.providerId,
        policyConsent: _agreed,
      );
      setState(() => _session = session);
      _poll = Timer.periodic(const Duration(seconds: 1), (_) async {
        try {
          final next = await _api.signInStatus('${_session!['id']}');
          if (!mounted) return;
          setState(() => _session = next);
          if (next['status'] != 'pending') _poll?.cancel();
        } on PircException {
          // Try again on the next tick.
        }
      });
    } on PircException catch (error) {
      setState(() => _error = error.message);
    }
  }

  @override
  void dispose() {
    _poll?.cancel();
    if (_pending) _api.cancelSignIn('${_session!['id']}').ignore();
    _answer.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final session = _session;
    final auth = session?['auth'] as Map?;
    final prompts = (session?['prompts'] as List? ?? const []).cast<Map>();
    return AlertDialog(
      title: Text(l10n.providersSignInTo(widget.name)),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (session == null && widget.consent)
              CheckboxListTile(
                value: _agreed,
                onChanged: (v) => setState(() => _agreed = v ?? false),
                title: Text(l10n.providersConsent),
              ),
            if (auth != null) ...[
              Text(l10n.providersOpenAddress),
              SelectableText('${auth['url']}'),
              if (auth['userCode'] != null)
                SelectableText(
                  '${auth['userCode']}',
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
              TextButton.icon(
                onPressed: () =>
                    Clipboard.setData(ClipboardData(text: '${auth['url']}')),
                icon: const Icon(LucideIcons.copy, size: 16),
                label: Text(l10n.copy),
              ),
            ],
            for (final prompt in prompts) ...[
              Text('${prompt['message']}'),
              TextField(
                controller: _answer,
                decoration: InputDecoration(
                  hintText: '${prompt['placeholder'] ?? ''}',
                ),
              ),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: () async {
                    try {
                      final next = await _api.answerSignIn(
                        '${session!['id']}',
                        '${prompt['id']}',
                        _answer.text,
                      );
                      setState(() => _session = next);
                      _answer.clear();
                    } on PircException catch (error) {
                      setState(() => _error = error.message);
                    }
                  },
                  child: Text(l10n.send),
                ),
              ),
            ],
            if (session != null && !_pending)
              Text(switch (session['status']) {
                'succeeded' => l10n.providersSignedIn,
                _ => '${session['error'] ?? session['status']}',
              }),
            if (_error != null) Text(_error!),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(session == null || _pending ? l10n.cancel : l10n.done),
        ),
        if (session == null)
          FilledButton(
            onPressed: widget.consent && !_agreed ? null : _start,
            child: Text(l10n.providersSignIn),
          ),
      ],
    );
  }
}
