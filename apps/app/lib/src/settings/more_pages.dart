import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:pirc_client/pirc_client.dart';

import '../../l10n/app_localizations.dart';
import '../connection/data.dart';
import '../connection/hints.dart';
import 'settings_widgets.dart';

/// Reads a settings page's data; read again on `memory_changed` for memory
/// and `schedules_changed` for calendar access (which the Gateway also
/// announces with it).
final _memoryProvider = FutureProvider.autoDispose<Map<String, Object?>>((ref) {
  watchHint(ref, 'memory_changed');
  return MemoryApi(requireApi(ref)).view();
});

final _modesProvider = FutureProvider.autoDispose<List<Map<String, Object?>>>(
  (ref) => ModesApi(requireApi(ref)).list(),
);

final _calendarAccessProvider =
    FutureProvider.autoDispose<Map<String, Object?>>((ref) async {
      watchHint(ref, 'schedules_changed');
      return (await requireApi(ref).get('/api/calendar/permissions') as Map)
          .cast<String, Object?>();
    });

/// Loading and failed states of a settings page; [onRetry] reads again.
List<Widget> _states<T>(
  BuildContext context,
  AsyncValue<T> value,
  VoidCallback onRetry,
  List<Widget> Function(T data) builder,
) {
  final l10n = AppLocalizations.of(context);
  return switch (value) {
    AsyncValue(:final value?) => builder(value),
    AsyncValue(:final error?) when error is! NotConnected => [
      ListTile(
        leading: const Icon(LucideIcons.circleAlert),
        title: Text(l10n.listFailed),
        trailing: TextButton(onPressed: onRetry, child: Text(l10n.retry)),
      ),
    ],
    _ => [
      const Padding(
        padding: EdgeInsets.all(24),
        child: Center(child: CircularProgressIndicator()),
      ),
    ],
  };
}

Future<void> _run(
  BuildContext context,
  WidgetRef ref,
  Future<Object?> Function() action,
  VoidCallback refresh,
) async {
  try {
    await action();
    refresh();
  } on PircException catch (error) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            AppLocalizations.of(context).actionFailed(error.message),
          ),
        ),
      );
    }
  }
}

/// Memory: what the agent remembers about the user, its notes, its
/// proposals to approve or reject, and removed entries to restore. Only the
/// agent writes entries; the user can forget one.
class MemoryPage extends ConsumerWidget {
  const MemoryPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final value = ref.watch(_memoryProvider);
    final memory = MemoryApi(
      ref.watch(apiProvider) ?? ApiClient(_NoTransport()),
    );
    void act(Future<Object?> Function() action) =>
        _run(context, ref, action, () => ref.invalidate(_memoryProvider));
    Widget entry(Map e, {bool removed = false}) => ListTile(
      title: Text('${e['content']}'),
      trailing: removed
          ? TextButton(
              onPressed: () => act(() => memory.restore('${e['id']}')),
              child: Text(l10n.memoryRestore),
            )
          : TextButton(
              onPressed: () => act(() => memory.forget('${e['id']}')),
              child: Text(l10n.memoryForget),
            ),
    );
    return SettingsPage(
      title: l10n.settingsMemory,
      children: _states(context, value, () => ref.invalidate(_memoryProvider), (
        data,
      ) {
        final proposals = (data['proposals'] as List? ?? const []).cast<Map>();
        final user = (data['user'] as List? ?? const []).cast<Map>();
        final notes = (data['notes'] as List? ?? const []).cast<Map>();
        final removed = (data['removed'] as List? ?? const []).cast<Map>();
        return [
          if (proposals.isNotEmpty)
            SettingsGroup(
              title: l10n.memoryProposals,
              children: [
                for (final p in proposals)
                  ListTile(
                    title: Text('${p['content'] ?? p['action']}'),
                    subtitle: Text('${p['action']}'),
                    trailing: Wrap(
                      children: [
                        TextButton(
                          onPressed: () =>
                              act(() => memory.reject('${p['id']}')),
                          child: Text(l10n.memoryReject),
                        ),
                        FilledButton(
                          onPressed: () =>
                              act(() => memory.approve('${p['id']}')),
                          child: Text(l10n.memoryApprove),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          SettingsGroup(
            title: l10n.memoryAboutYou,
            children: user.isEmpty
                ? [ListTile(title: Text(l10n.memoryNone))]
                : [for (final e in user) entry(e)],
          ),
          if (notes.isNotEmpty)
            SettingsGroup(
              title: l10n.memoryNotes,
              children: [for (final e in notes) entry(e)],
            ),
          if (removed.isNotEmpty)
            SettingsGroup(
              title: l10n.memoryRemoved,
              children: [for (final e in removed) entry(e, removed: true)],
            ),
        ];
      }),
    );
  }
}

/// Calendar and agent access: may agents read the calendar, and may they
/// propose changes (`/api/calendar/permissions`).
class CalendarAccessPage extends ConsumerWidget {
  const CalendarAccessPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final value = ref.watch(_calendarAccessProvider);
    return SettingsPage(
      title: l10n.settingsCalendar,
      children: _states(
        context,
        value,
        () => ref.invalidate(_calendarAccessProvider),
        (data) {
          final read = data['allowRead'] == true;
          final propose = data['allowPropose'] == true;
          void set(bool read, bool propose) => _run(
            context,
            ref,
            () => ref.read(apiProvider)!.patch('/api/calendar/permissions', {
              'allowRead': read,
              'allowPropose': propose,
            }),
            () => ref.invalidate(_calendarAccessProvider),
          );
          return [
            SettingsGroup(
              children: [
                SwitchListTile(
                  title: Text(l10n.calendarAllowRead),
                  value: read,
                  onChanged: (on) => set(on, on && propose),
                ),
                SwitchListTile(
                  title: Text(l10n.calendarAllowPropose),
                  subtitle: Text(l10n.calendarAllowProposeNote),
                  value: propose,
                  onChanged: read ? (on) => set(read, on) : null,
                ),
              ],
            ),
          ];
        },
      ),
    );
  }
}

/// Modes (read only): each mode the Gateway serves. Source files and
/// validation warnings are not reported by the Gateway yet.
class ModesPage extends ConsumerWidget {
  const ModesPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final value = ref.watch(_modesProvider);
    return SettingsPage(
      title: l10n.settingsModes,
      children: _states(context, value, () => ref.invalidate(_modesProvider), (
        modes,
      ) {
        return [
          SettingsGroup(
            children: [
              for (final m in modes)
                ListTile(
                  title: Text('${m['label'] ?? m['id']}'),
                  subtitle: Text(
                    [
                      '${m['id']}',
                      if ('${m['description'] ?? ''}'.isNotEmpty)
                        '${m['description']}',
                    ].join(' · '),
                  ),
                ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.all(24),
            child: Text(
              l10n.modesNoWarnings,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        ];
      }),
    );
  }
}

/// Stands in until the connection exists; every call fails.
class _NoTransport implements Transport {
  @override
  TransportConfig get config => TransportConfig(baseUri: Uri());
  @override
  Future<ApiResponse> send(ApiRequest request) =>
      Future.error(const TransportException('Not connected'));
  @override
  Future<EventSocket> connectEvents(Uri target) =>
      Future.error(const TransportException('Not connected'));
  @override
  void close() {}
}
