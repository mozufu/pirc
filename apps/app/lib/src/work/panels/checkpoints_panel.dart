import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:pirc_client/pirc_client.dart';

import '../../../l10n/app_localizations.dart';
import '../../connection/data.dart';
import '../../format.dart';
import 'panel_common.dart';
import '../labels.dart';

/// 10e. Checkpoints (default F): the list, a preview, the recovery job and
/// "continue". Recovery is a user action and needs the control lease.
class CheckpointsPanel extends ConsumerStatefulWidget {
  const CheckpointsPanel({super.key, required this.sessionId});
  final String sessionId;

  @override
  ConsumerState<CheckpointsPanel> createState() => _CheckpointsPanelState();
}

class _CheckpointsPanelState extends ConsumerState<CheckpointsPanel> {
  Map? _capture;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final capture = _capture;
    if (capture != null) {
      return _Capture(
        sessionId: widget.sessionId,
        capture: capture,
        onBack: () => setState(() => _capture = null),
      );
    }
    final key = panelKey(
      widget.sessionId,
      'checkpoints',
      sections: const ['checkpoints'],
    );
    return PanelBody<Object?>(
      value: ref.watch(panelReadProvider(key)),
      onRetry: () => ref.invalidate(panelReadProvider(key)),
      emptyText: l10n.checkpointsEmpty,
      isEmpty: (d) => ((d as Map?)?['captures'] as List?)?.isEmpty ?? true,
      builder: (d) {
        final data = d! as Map;
        if (data['enabled'] == false) {
          return PanelNote(
            text: l10n.checkpointsOff,
            icon: LucideIcons.history,
          );
        }
        return ListView(
          children: [
            for (final c in (data['captures'] as List).cast<Map>())
              ListTile(
                leading: Icon(
                  c['pinned'] == true ? LucideIcons.pin : LucideIcons.history,
                  size: 18,
                ),
                title: Text(
                  listTime(
                    context,
                    (c['created'] as num?)?.toInt() ?? 0,
                    now: ref.read(clockProvider)(),
                  ),
                ),
                subtitle: Text(
                  l10n.checkpointsFiles(
                    (c['operations'] as List? ?? const []).length,
                    '${c['coverage']}',
                  ),
                ),
                onTap: () => setState(() => _capture = c),
              ),
          ],
        );
      },
    );
  }
}

class _Capture extends ConsumerStatefulWidget {
  const _Capture({
    required this.sessionId,
    required this.capture,
    required this.onBack,
  });

  final String sessionId;
  final Map capture;
  final VoidCallback onBack;

  @override
  ConsumerState<_Capture> createState() => _CaptureState();
}

class _CaptureState extends ConsumerState<_Capture> {
  late final _picked = {
    for (final op
        in (widget.capture['operations'] as List? ?? const []).cast<Map>())
      '${op['id']}',
  };
  Map? _preview;
  Map? _job;
  String? _error;
  bool _busy = false;

  String get _base =>
      'checkpoints/${Uri.encodeComponent('${widget.capture['id']}')}';

  Future<void> _run(Future<void> Function(ApiClient api) action) async {
    final api = ref.read(apiProvider);
    if (api == null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action(api);
    } on PircException catch (error) {
      setState(() => _error = error.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _previewIt() => _run((api) async {
    final reply = await api.post(
      sessionPath(widget.sessionId, '$_base/preview'),
      {'operations': _picked.toList(), 'reviewObservational': false},
    );
    setState(() => _preview = reply as Map?);
  });

  Future<void> _recover() => _run((api) async {
    final lease = leaseBody(ref, widget.sessionId);
    if (lease == null) return;
    final reply = await api
        .post(sessionPath(widget.sessionId, '$_base/recoveries'), {
          'version': _preview!['version'],
          'key': randomId(),
          'previewRevision': _preview!['revision'],
          'operations': _picked.toList(),
          'reviewObservational': false,
          ...lease,
        });
    setState(() => _job = reply as Map?);
  });

  Future<void> _continue() => _run((api) async {
    final lease = leaseBody(ref, widget.sessionId);
    if (lease == null) return;
    final reply = await api.post(
      sessionPath(
        widget.sessionId,
        '$_base/recoveries/${Uri.encodeComponent('${_job!['id']}')}/continue',
      ),
      {'revision': _job!['revision'], 'acceptUnresolved': false, ...lease},
    );
    final session = (reply as Map?)?['session'];
    if (session is Map && mounted) {
      context.go(
        Uri(
          path: '/work',
          queryParameters: {'open': '${session['id']}'},
        ).toString(),
      );
    }
  });

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final control = canControl(ref, widget.sessionId);
    final operations = (widget.capture['operations'] as List? ?? const [])
        .cast<Map>();
    final job = _job;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            IconButton(
              tooltip: l10n.back,
              icon: const Icon(LucideIcons.chevronLeft),
              onPressed: widget.onBack,
            ),
            Expanded(child: Text('${widget.capture['coverage']}')),
          ],
        ),
        if (!control) ReadOnlyNote(sessionId: widget.sessionId),
        Expanded(
          child: ListView(
            children: [
              for (final op in operations)
                CheckboxListTile(
                  dense: true,
                  value: _picked.contains('${op['id']}'),
                  onChanged: job == null
                      ? (on) => setState(() {
                          on == true
                              ? _picked.add('${op['id']}')
                              : _picked.remove('${op['id']}');
                          _preview = null;
                        })
                      : null,
                  title: Text('${op['path']}'),
                  subtitle: Text(
                    '${op['tool']} · '
                    '${l10n.checkpointOperationState('${op['state']}')}',
                  ),
                ),
              if (_preview != null)
                ListTile(
                  title: Text(l10n.checkpointsPreview),
                  subtitle: Text(
                    l10n.checkpointsPreviewBody(
                      (_preview!['copiedBytes'] as num?)?.toInt() ?? 0,
                      ((_preview!['exclusions'] as Map?) ?? const {}).length,
                    ),
                  ),
                ),
              if (job != null)
                ListTile(
                  title: Text(
                    l10n.checkpointsJob(
                      l10n.checkpointJobState('${job['state']}'),
                    ),
                  ),
                  subtitle: Text(
                    '${((job['manifest'] as Map?)?['paths'] as List? ?? const []).length}',
                  ),
                ),
              if (_error != null) ListTile(title: Text(_error!)),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(12),
          child: Align(
            alignment: Alignment.centerRight,
            child: job != null
                ? FilledButton(
                    onPressed: _busy || !control ? null : _continue,
                    child: Text(l10n.checkpointsContinue),
                  )
                : _preview != null
                ? FilledButton(
                    onPressed: _busy || !control ? null : _recover,
                    child: Text(l10n.checkpointsRecover),
                  )
                : OutlinedButton(
                    onPressed: _busy || _picked.isEmpty ? null : _previewIt,
                    child: Text(l10n.checkpointsPreviewAction),
                  ),
          ),
        ),
      ],
    );
  }
}
