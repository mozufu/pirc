import 'package:flutter/material.dart';
import '../l10n/app_i18n.dart';
import 'common.dart';
import 'environment_transitions.dart';
import 'gateway.dart';
import 'web_controls.dart';

/// Minimal, throwaway environment-switch controls; the new design replaces
/// them. All behavior lives in [EnvironmentTransitionFlow].
class EnvironmentSwitchCard extends StatefulWidget {
  const EnvironmentSwitchCard({super.key, required this.controller, this.flow});
  final LiveController controller;

  /// Injected by tests; otherwise one flow per open conversation.
  final EnvironmentTransitionFlow Function(String session)? flow;
  @override
  State<EnvironmentSwitchCard> createState() => _EnvironmentSwitchCardState();
}

class _EnvironmentSwitchCardState extends State<EnvironmentSwitchCard> {
  EnvironmentTransitionFlow? flow;
  String? session, target;

  LiveController get c => widget.controller;
  TransitionLease? lease() {
    final client = c.clientId, generation = c.control['generation'];
    return c.control['held'] == true && client != null && generation != null
        ? TransitionLease(client, generation)
        : null;
  }

  @override
  void initState() {
    super.initState();
    c.addListener(observe);
    observe();
  }

  void observe() {
    if (session == c.sessionId) {
      if (mounted) setState(() {});
      return;
    }
    flow?.dispose();
    session = c.sessionId;
    target = null;
    final id = session;
    if (id == null) {
      flow = null;
    } else {
      final next =
          widget.flow?.call(id) ??
          EnvironmentTransitionFlow(
            api: EnvironmentTransitionApi(c.gateway),
            session: id,
            lease: lease,
            onBinding: (binding) => c.adoptBinding(id, binding),
          );
      next.addListener(() {
        if (mounted) setState(() {});
      });
      flow = next;
      next.load();
    }
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    c.removeListener(observe);
    flow?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    AppI18n.watch(context);
    final f = flow;
    if (f == null) return const SizedBox.shrink();
    final session = obj(c.state['session']);
    final current = c.workspaces
        .where((w) => w['id'] == session['workspaceId'])
        .firstOrNull;
    final candidates = [
      for (final w in c.workspaces)
        if (w['id'] != session['workspaceId'] &&
            (current == null || w['hostId'] == current['hostId']))
          w,
    ];
    final small = webText(context, size: 12.5, color: 'text.secondary');
    final revocation = f.transition?.revocation;
    final showItems =
        f.status == EnvironmentSwitchStatus.unproven ||
        f.status == EnvironmentSwitchStatus.revocationBlocked ||
        f.status == EnvironmentSwitchStatus.reauthorizationRequired;
    final actions = f.actions;
    return Container(
      key: const Key('environment-switch'),
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        border: Border.all(color: palette(context)['web.line']),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(tr("Switch environment"), style: webText(context, size: 14)),
          if (f.status == EnvironmentSwitchStatus.idle) ...[
            if (f.lastFinished != null)
              Text(lastFinishedText(f.lastFinished!), style: small),
            if (candidates.isEmpty)
              Text(tr("No other workspace on this Node."), style: small)
            else
              DropdownButton<String>(
                value: target,
                hint: Text(tr("Target workspace")),
                isExpanded: true,
                items: [
                  for (final w in candidates)
                    DropdownMenuItem(
                      value: '${w['id']}',
                      child: Text('${w['displayName'] ?? w['id']}'),
                    ),
                ],
                onChanged: (value) => setState(() => target = value),
              ),
            if (target != null &&
                actions.contains(EnvironmentSwitchAction.preview))
              TextButton(
                onPressed: () => f.startPreview(target!),
                child: Text(
                  environmentSwitchActionLabel(EnvironmentSwitchAction.preview),
                ),
              ),
          ] else ...[
            Text(environmentSwitchMessage(f), style: small),
            if (f.status == EnvironmentSwitchStatus.previewBlocked)
              for (final reason in f.preview?.blockedBy ?? const <String>[])
                Text('• ${transitionReasonText(reason)}', style: small),
            // C1: the finite authority is shown before Confirm.
            if (f.preview != null &&
                (f.status == EnvironmentSwitchStatus.readyToConfirm ||
                    f.status == EnvironmentSwitchStatus.previewBlocked))
              Text(operationAuthorityPreviewText(f.preview!), style: small),
            if (showItems && revocation != null) ...[
              Text(
                tr("Showing {0} of {1} items", [
                  f.shownItems.length,
                  revocation.itemsTotal,
                ]),
                style: small,
              ),
              for (final item in f.shownItems)
                Text('• ${revocationItemText(item)}', style: small),
            ],
            Wrap(
              spacing: 4,
              children: [
                for (final action in EnvironmentSwitchAction.values)
                  if (actions.contains(action))
                    TextButton(
                      onPressed: () => f.perform(action),
                      child: Text(
                        action == EnvironmentSwitchAction.acknowledge
                            ? acknowledgeLabel(f)
                            : environmentSwitchActionLabel(action),
                      ),
                    ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}
