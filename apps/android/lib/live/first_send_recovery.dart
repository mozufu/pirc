import '../l10n/app_i18n.dart';
import 'package:flutter/material.dart';
import 'common.dart';
import 'gateway.dart';
import 'web_controls.dart';

String _preview(Object? value, [int limit = 120]) {
  final text = '${value ?? ''}';
  return text.length <= limit ? text : '${text.substring(0, limit)}…';
}

String firstSendLabel(Json row) {
  if (row['recoveredFrom'] is String && row['frozen'] != true) {
    return tr('Unsent edits');
  }
  final prep = obj(row['preparation']);
  final phase = prep['state'];
  if (phase == 'cancelled') {
    return tr(prep['cleanupPending'] == true ? 'Deletion pending' : 'Deleted');
  }
  if (row['cancelRequested'] == true) return tr('Deletion not yet confirmed');
  if (phase == 'admitted') return tr('First message admitted');
  if (phase == 'stopped') return tr('First message stopped');
  if (phase == 'stopping') return tr('Stopping first message');
  if (row['uncertain'] == true || phase == 'outcome_unknown') {
    return tr('First message outcome is unknown');
  }
  if (phase == 'admission_failed')
    return tr('First message was not executed. You can retry.');
  if (prep['accepted'] == true) {
    return tr('First message accepted — delivery pending');
  }
  return tr('First message saved on this device');
}

Future<void> discardFirstSend(
  BuildContext context,
  LiveController controller,
  Json row,
) async {
  if (!controller.firstSend.owns(row)) return;
  final fresh = await controller.firstSend.inspect(row) ?? row;
  if (!context.mounted || !controller.firstSend.owns(fresh)) return;
  final accepted = obj(fresh['preparation'])['accepted'] == true;
  if (accepted && fresh['deleteAcceptedRequested'] != true) {
    final allowed = await confirm(
      context,
      tr('Delete chat?'),
      tr(
        'This conversation and its chat files will be permanently deleted. This also deletes USER memories and MEMORY notes created by this chat, and its pending memory proposals. Memories created by other chats are kept. Copies already present in other chats are not erased. Any running reply will stop. This cannot be undone.',
      ),
      action: tr('Delete chat and memories'),
      cancelLabel: tr('Cancel'),
    );
    if (!allowed || !context.mounted) return;
  }
  await controller.firstSend.discard(fresh, deleteAccepted: accepted);
}

/// Small recovery entry in the existing sidebar; no navigation redesign.
class SavedFirstSends extends StatelessWidget {
  const SavedFirstSends({super.key, required this.controller});
  final LiveController controller;
  @override
  Widget build(BuildContext context) {
    final first = controller.firstSend;
    if (first.saved.isEmpty) return const SizedBox.shrink();
    return Material(
      type: MaterialType.transparency,
      child: ExpansionTile(
        key: const ValueKey('saved-first-sends'),
        initiallyExpanded: false,
        tilePadding: const EdgeInsets.symmetric(horizontal: 12),
        title: Text(
          '${tr('Saved drafts and pending sends')} (${first.saved.length})',
          style: webText(context, size: 12),
        ),
        children: [
          for (final row in first.saved)
            ListTile(
              dense: true,
              title: Text(
                '${row['message'] ?? ''}'.isEmpty
                    ? tr('Pending cleanup')
                    : _preview(row['message'], 65),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: webText(context, size: 12),
              ),
              subtitle: Text(
                firstSendLabel(row),
                style: webText(context, size: 11, color: 'text.muted'),
              ),
              onTap: () => guarded(context, () => first.resume(row)),
              trailing: row['frozen'] != true
                  ? TextButton(
                      onPressed: () => guarded(
                        context,
                        () => discardFirstSend(context, controller, row),
                      ),
                      child: Text(tr('Discard draft')),
                    )
                  : obj(row['preparation'])['state'] == 'cancelled' &&
                        obj(row['preparation'])['cleanupPending'] != true
                  ? TextButton(
                      onPressed: () =>
                          guarded(context, () => first.dismiss(row)),
                      child: Text(tr('Dismiss')),
                    )
                  : null,
            ),
        ],
      ),
    );
  }
}

class FirstSendRecovery extends StatelessWidget {
  const FirstSendRecovery({super.key, required this.controller});
  final LiveController controller;
  @override
  Widget build(BuildContext context) {
    final first = controller.firstSend, row = first.current;
    if (row == null) return const SizedBox.shrink();
    final prep = obj(row['preparation']), phase = prep['state'];
    final workspace = controller.workspaces
        .where((w) => w['id'] == row['workspaceId'])
        .firstOrNull;
    final canDelete =
        workspace != null && controller.catalog.of(workspace).deleteSessions;
    final message = '${row['message'] ?? ''}';
    Widget action(
      String label,
      Future<void> Function() callback, {
      bool enabled = true,
    }) => TextButton(
      onPressed: enabled ? () => guarded(context, callback) : null,
      child: Text(tr(label)),
    );
    return SingleChildScrollView(
      key: const ValueKey('first-send-recovery'),
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      child: Material(
        color: palette(context)['surface.page'],
        shape: RoundedRectangleBorder(
          side: BorderSide(color: palette(context)['line.default']),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                firstSendLabel(row),
                style: webText(context, weight: FontWeight.w600),
              ),
              if (message.isNotEmpty)
                ExpansionTile(
                  key: const ValueKey('first-send-original'),
                  initiallyExpanded: false,
                  tilePadding: EdgeInsets.zero,
                  title: Text(
                    _preview(message),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: webText(context, size: 12),
                  ),
                  children: [
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxHeight: 160),
                      child: SingleChildScrollView(
                        child: SelectableText(
                          message,
                          style: webText(context, size: 12),
                        ),
                      ),
                    ),
                  ],
                ),
              if (first.stopped &&
                  obj(prep['messageAdmission'])['outcome'] == 'outcome_unknown')
                Text(
                  tr(
                    'The first message admission is still unknown; Stop does not undo completed work.',
                  ),
                  style: webText(context, size: 12, color: 'text.muted'),
                ),
              Text(
                tr('Check result never resends the message or takes control.'),
                style: webText(context, size: 12, color: 'text.muted'),
              ),
              if (controller.actionError != null ||
                  row['error'] != null ||
                  prep['cleanupError'] != null ||
                  prep['deliveryError'] != null)
                Text(
                  tr(
                    '${controller.actionError ?? row['error'] ?? prep['cleanupError'] ?? prep['deliveryError']}',
                  ),
                  style: webText(context, size: 12, color: 'status.danger'),
                ),
              if (first.canRecoverRetry)
                Text(
                  tr(
                    'Recovery blocks a retry the server has not received. It never resends the message.',
                  ),
                  style: webText(context, size: 12, color: 'text.muted'),
                ),
              Wrap(
                spacing: 4,
                children: [
                  action(
                    'Check result',
                    first.check,
                    enabled: !first.controlBusy,
                  ),
                  if (![
                        'admitted',
                        'sending',
                        'outcome_unknown',
                        'stopped',
                        'stopping',
                        'cancelled',
                        'admission_failed',
                      ].contains(phase) &&
                      row['uncertain'] != true &&
                      row['cancelRequested'] != true)
                    action(
                      'Continue sending',
                      first.submit,
                      enabled: first.enabled && !controller.busy,
                    ),
                  if (first.canRecoverRetry)
                    action(
                      'Recover interrupted retry',
                      first.recoverRetry,
                      enabled: !first.controlBusy && !controller.busy,
                    ),
                  if (first.canRetry)
                    action(
                      'Retry original message',
                      first.retry,
                      enabled: !first.controlBusy && !controller.busy,
                    ),
                  if (first.canStop && !first.stopRequested)
                    action(
                      'Take control',
                      first.takeControl,
                      enabled: !first.controlBusy,
                    ),
                  if (first.admitted || first.stopped)
                    action(
                      'Open conversation',
                      first.openKnown,
                      enabled: !first.controlBusy,
                    )
                  else if (first.canStop && !first.stopRequested)
                    action(
                      'Stop pending message',
                      first.stop,
                      enabled: !first.controlBusy,
                    ),
                  if (phase == 'cancelled' && prep['cleanupPending'] != true)
                    action('Dismiss', () => first.dismiss(row))
                  else if (phase != 'cancelled' &&
                      (prep['accepted'] != true || canDelete))
                    action(
                      prep['accepted'] == true
                          ? 'Delete chat and memories'
                          : 'Discard draft',
                      () => discardFirstSend(context, controller, row),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
