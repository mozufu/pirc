import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:pirc_client/pirc_client.dart';
import 'package:pirc_ui/pirc_ui.dart';

import '../../../l10n/app_localizations.dart';
import '../../connection/connection.dart';
import '../../connection/data.dart';
import '../../connection/hints.dart';
import '../session_controller.dart';

/// The path of a session sub-route.
String sessionPath(String sessionId, String rest) =>
    '/api/sessions/${Uri.encodeComponent(sessionId)}/$rest';

/// Reads [rest] of a session; the panel reads again when a `panel_changed`
/// names one of [sections].
Future<Object?> readPanel(
  Ref ref,
  String sessionId,
  String rest, {
  List<String> sections = const [],
  Map<String, String> query = const {},
}) {
  for (final section in sections) {
    ref.watch(
      sessionControllerProvider(
        sessionId,
      ).select((view) => view.panels[section] ?? 0),
    );
  }
  return requireApi(ref).get(sessionPath(sessionId, rest), query: query);
}

/// Loading, empty, offline and failed states around a panel's content.
/// Offline keeps what was loaded, marked as possibly out of date.
class PanelBody<T> extends ConsumerWidget {
  const PanelBody({
    super.key,
    required this.value,
    required this.builder,
    required this.isEmpty,
    required this.emptyText,
    required this.onRetry,
  });

  final AsyncValue<T> value;
  final Widget Function(T data) builder;
  final bool Function(T data) isEmpty;
  final String emptyText;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final offline =
        ref.watch(appConnectionStateProvider) == AppConnectionState.offline;
    final data = value.value;
    if (data != null) {
      final content = isEmpty(data)
          ? PanelNote(text: emptyText, icon: LucideIcons.inbox)
          : builder(data);
      if (!offline) return content;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PanelNote(
            text: l10n.offlineBanner,
            icon: LucideIcons.cloudOff,
            compact: true,
          ),
          Expanded(child: content),
        ],
      );
    }
    if (offline) {
      return PanelNote(text: l10n.panelOffline, icon: LucideIcons.cloudOff);
    }
    final error = value.error;
    if (error != null && error is! NotConnected) {
      return PanelNote(
        text: error is ApiError && error.status == 503
            ? l10n.panelHostOffline
            : l10n.panelFailed,
        icon: LucideIcons.circleAlert,
        action: OutlinedButton(onPressed: onRetry, child: Text(l10n.retry)),
      );
    }
    return const Center(child: CircularProgressIndicator());
  }
}

class PanelNote extends StatelessWidget {
  const PanelNote({
    super.key,
    required this.text,
    required this.icon,
    this.action,
    this.compact = false,
  });

  final String text;
  final IconData icon;
  final Widget? action;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final colors = PircColorTokens.of(context);
    final note = Text(
      text,
      textAlign: compact ? TextAlign.start : TextAlign.center,
      style: Theme.of(context).textTheme.bodySmall,
    );
    if (compact) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(
          children: [
            Icon(icon, size: 16, color: colors['text.warning']),
            const SizedBox(width: 8),
            Expanded(child: note),
          ],
        ),
      );
    }
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(PircSpacing.stackXl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 28, color: colors['text.faint']),
            const SizedBox(height: 8),
            note,
            if (action != null) ...[const SizedBox(height: 8), action!],
          ],
        ),
      ),
    );
  }
}

/// Whether this device may act in the panel (create, type, stop, recover).
bool canControl(WidgetRef ref, String sessionId) =>
    ref.watch(sessionControllerProvider(sessionId)).control ==
        ControlState.mine &&
    ref.watch(appConnectionStateProvider) == AppConnectionState.online;

/// The read-only note shown where an action needs the control lease.
class ReadOnlyNote extends ConsumerWidget {
  const ReadOnlyNote({super.key, required this.sessionId});
  final String sessionId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    return PanelNote(
      text: l10n.panelReadOnly,
      icon: LucideIcons.lock,
      compact: true,
    );
  }
}

/// One panel read: a session sub-route with its query, read again when a
/// `panel_changed` names one of [sections] (comma-separated).
typedef PanelKey = ({
  String sessionId,
  String rest,
  String query,
  String sections,
});

PanelKey panelKey(
  String sessionId,
  String rest, {
  Map<String, String> query = const {},
  List<String> sections = const [],
}) => (
  sessionId: sessionId,
  rest: rest,
  query: Uri(queryParameters: query.isEmpty ? null : query).query,
  sections: sections.join(','),
);

final panelReadProvider = FutureProvider.autoDispose.family<Object?, PanelKey>(
  (ref, key) => readPanel(
    ref,
    key.sessionId,
    key.rest,
    sections: key.sections.isEmpty ? const [] : key.sections.split(','),
    query: key.query.isEmpty ? const {} : Uri.splitQueryString(key.query),
  ),
);

/// The held lease as a request body, or null when this device does not
/// control the session.
Map<String, Object?>? leaseBody(WidgetRef ref, String sessionId) {
  final lease = ref
      .read(sessionControllerProvider(sessionId).notifier)
      .heldLease;
  return lease == null
      ? null
      : {'clientId': lease.clientId, 'generation': lease.generation};
}

/// A unified diff, one line per row, added and removed lines marked.
class DiffView extends StatelessWidget {
  const DiffView({super.key, required this.diff, this.truncated = false});
  final String diff;
  final bool truncated;

  @override
  Widget build(BuildContext context) {
    final colors = PircColorTokens.of(context);
    final l10n = AppLocalizations.of(context);
    final base = PircType.monoCode.style(color: colors['code.text']);
    final lines = diff.split('\n');
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: SelectionArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final line in lines)
              Container(
                color: line.startsWith('+') && !line.startsWith('+++')
                    ? colors['status.success'].withValues(alpha: 0.12)
                    : line.startsWith('-') && !line.startsWith('---')
                    ? colors['status.danger'].withValues(alpha: 0.12)
                    : null,
                child: Text(
                  line.isEmpty ? ' ' : line,
                  style: line.startsWith('@@')
                      ? base.copyWith(color: colors['accent.default'])
                      : base,
                ),
              ),
            if (truncated)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(l10n.panelTruncated),
              ),
          ],
        ),
      ),
    );
  }
}
