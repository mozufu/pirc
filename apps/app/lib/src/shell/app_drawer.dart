import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:pirc_client/pirc_client.dart';
import 'package:pirc_ui/pirc_ui.dart';

import '../../l10n/app_localizations.dart';
import '../connection/connection.dart';
import '../connection/data.dart';
import '../connection/hints.dart';
import '../preferences.dart';

/// Whether the ☰ drawer is open. Opening or closing it never changes the
/// selected tab or the open item.
final drawerOpenProvider = NotifierProvider<DrawerOpen, bool>(DrawerOpen.new);

class DrawerOpen extends Notifier<bool> {
  @override
  bool build() => false;

  void open() => state = true;
  void close() => state = false;
}

/// The ☰ button of a list header.
class DrawerButton extends ConsumerWidget {
  const DrawerButton({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) => IconButton(
    tooltip: AppLocalizations.of(context).openDrawer,
    icon: const Icon(LucideIcons.menu),
    onPressed: ref.read(drawerOpenProvider.notifier).open,
  );
}

/// The drawer (E21): connection state, hosts, Settings, the light/dark
/// switch and the user row (name only; usage is M7).
class AppDrawer extends ConsumerWidget {
  const AppDrawer({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final colors = PircColorTokens.of(context);
    final text = Theme.of(context).textTheme;
    final state = ref.watch(appConnectionStateProvider);
    final account = ref.watch(
      connectionProvider.select((s) => s.connection?.account),
    );
    final (dot, label) = switch (state) {
      AppConnectionState.online => (
        colors['status.success'],
        l10n.gatewayConnected,
      ),
      AppConnectionState.reconnecting || AppConnectionState.connecting => (
        colors['status.warning'],
        l10n.reconnecting,
      ),
      _ => (colors['text.faint'], l10n.gatewayOffline),
    };
    final dark = Theme.of(context).brightness == Brightness.dark;
    void close() => ref.read(drawerOpenProvider.notifier).close();
    return SafeArea(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
              PircSpacing.stackXl,
              PircSpacing.stackXl,
              PircSpacing.stackLg,
              PircSpacing.stackLg,
            ),
            child: Row(
              children: [
                const _Mark(),
                const SizedBox(width: PircSpacing.stackMd),
                Text(l10n.appTitle, style: text.titleLarge),
                const Spacer(),
                _Dot(color: dot),
                const SizedBox(width: PircSpacing.stackXs),
                Flexible(
                  child: Text(
                    label,
                    style: text.bodySmall,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(
              PircSpacing.stackXl,
              PircSpacing.stackLg,
              PircSpacing.stackXl,
              PircSpacing.stackSm,
            ),
            child: Text(l10n.hosts, style: text.labelMedium),
          ),
          const Expanded(child: _Hosts()),
          ListTile(
            contentPadding: const EdgeInsets.symmetric(
              horizontal: PircSpacing.stackXl,
            ),
            leading: const Icon(LucideIcons.settings, size: PircSize.iconBar),
            title: Text(l10n.settings),
            trailing: IconButton(
              tooltip: dark ? l10n.switchToLight : l10n.switchToDark,
              icon: Icon(dark ? LucideIcons.sun : LucideIcons.moon),
              onPressed: () => ref
                  .read(themeModeProvider.notifier)
                  .select(dark ? ThemeMode.light : ThemeMode.dark),
            ),
            onTap: () {
              close();
              context.push('/settings');
            },
          ),
          if (account != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(
                PircSpacing.stackXl,
                PircSpacing.stackSm,
                PircSpacing.stackXl,
                PircSpacing.stackXl,
              ),
              child: Row(
                children: [
                  CircleAvatar(
                    radius: PircSize.avatarDefault / 2,
                    backgroundColor: colors['avatar.4'],
                    child: Text(
                      account.isEmpty ? '?' : account[0].toUpperCase(),
                      style: text.titleMedium?.copyWith(
                        color: colors['avatar.ink'],
                      ),
                    ),
                  ),
                  const SizedBox(width: PircSpacing.stackMd),
                  Expanded(
                    child: Text(
                      account,
                      style: text.titleMedium,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _Hosts extends ConsumerWidget {
  const _Hosts();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final colors = PircColorTokens.of(context);
    final text = Theme.of(context).textTheme;
    final nodes = ref.watch(nodesProvider);
    final sessions = ref.watch(sessionsProvider).value ?? const <Session>[];
    final list = nodes.value;
    if (list == null) {
      return nodes.hasError
          ? _Note(text: l10n.hostsFailed)
          : const SizedBox.shrink();
    }
    if (list.isEmpty) return _Note(text: l10n.noHosts);
    return ListView(
      padding: EdgeInsets.zero,
      children: [
        for (final node in list)
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: PircSpacing.stackXl,
              vertical: PircSpacing.stackSm,
            ),
            child: Row(
              children: [
                _Dot(color: colors['status.success']),
                const SizedBox(width: PircSpacing.stackLg),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(node.id, style: text.bodyLarge),
                      Text(
                        _running(l10n, sessions, node.id),
                        style: text.bodySmall,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  static String _running(
    AppLocalizations l10n,
    List<Session> sessions,
    String nodeId,
  ) {
    final count = sessions
        .where((s) => s.nodeId == nodeId && s.runStatus == 'running')
        .length;
    return count == 0 ? l10n.hostIdle : l10n.hostRunning(count);
  }
}

class _Note extends StatelessWidget {
  const _Note({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: PircSpacing.stackXl),
    child: Text(text, style: Theme.of(context).textTheme.bodySmall),
  );
}

class _Dot extends StatelessWidget {
  const _Dot({required this.color});
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    width: PircSize.stateDot + 1,
    height: PircSize.stateDot + 1,
    decoration: BoxDecoration(color: color, shape: BoxShape.circle),
  );
}

/// The π mark.
class _Mark extends StatelessWidget {
  const _Mark();

  @override
  Widget build(BuildContext context) {
    final colors = PircColorTokens.of(context);
    return Container(
      width: 36,
      height: 36,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: colors['accent.default'],
        borderRadius: BorderRadius.circular(PircRadius.sm),
      ),
      child: Text(
        'π',
        style: TextStyle(
          color: colors['accent.on'],
          fontWeight: FontWeight.w600,
          fontSize: 17,
        ),
      ),
    );
  }
}
