import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../l10n/app_localizations.dart';
import '../../format.dart';
import 'panel_common.dart';

/// 10a. Git (read only): `git/status` and `git/diff` for changes,
/// `git/log` and `git/commits/:sha` for history.
class GitPanel extends ConsumerStatefulWidget {
  const GitPanel({super.key, required this.sessionId});
  final String sessionId;

  @override
  ConsumerState<GitPanel> createState() => _GitPanelState();
}

class _GitPanelState extends ConsumerState<GitPanel> {
  bool _history = false;

  /// The open diff: a changed file or a commit.
  PanelKey? _detail;
  String? _detailTitle;

  void _open(PanelKey key, String title) => setState(() {
    _detail = key;
    _detailTitle = title;
  });

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final id = widget.sessionId;
    final detail = _detail;
    if (detail != null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ListTile(
            dense: true,
            leading: IconButton(
              tooltip: l10n.back,
              icon: const Icon(LucideIcons.chevronLeft),
              onPressed: () => setState(() => _detail = null),
            ),
            title: Text(_detailTitle ?? ''),
          ),
          Expanded(
            child: PanelBody<Object?>(
              value: ref.watch(panelReadProvider(detail)),
              onRetry: () => ref.invalidate(panelReadProvider(detail)),
              emptyText: l10n.gitNoDiff,
              isEmpty: (d) => '${(d as Map?)?['diff'] ?? ''}'.isEmpty,
              builder: (d) {
                final data = d! as Map;
                return ListView(
                  padding: const EdgeInsets.all(12),
                  children: [
                    if (data['message'] != null)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: SelectableText('${data['message']}'),
                      ),
                    DiffView(
                      diff: '${data['diff']}',
                      truncated: data['truncated'] == true,
                    ),
                  ],
                );
              },
            ),
          ),
        ],
      );
    }
    final key = _history
        ? panelKey(id, 'git/log', query: {'limit': '50'})
        : panelKey(id, 'git/status');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.all(8),
          child: Row(
            children: [
              Expanded(
                child: SegmentedButton<bool>(
                  showSelectedIcon: false,
                  segments: [
                    ButtonSegment(value: false, label: Text(l10n.gitChanges)),
                    ButtonSegment(value: true, label: Text(l10n.gitHistory)),
                  ],
                  selected: {_history},
                  onSelectionChanged: (v) =>
                      setState(() => _history = v.single),
                ),
              ),
              IconButton(
                tooltip: l10n.refresh,
                icon: const Icon(LucideIcons.refreshCw, size: 18),
                onPressed: () => ref.invalidate(panelReadProvider(key)),
              ),
            ],
          ),
        ),
        Expanded(
          child: PanelBody<Object?>(
            value: ref.watch(panelReadProvider(key)),
            onRetry: () => ref.invalidate(panelReadProvider(key)),
            emptyText: _history ? l10n.gitNoCommits : l10n.gitClean,
            isEmpty: (d) {
              final data = d as Map?;
              return _history
                  ? (data?['commits'] as List?)?.isEmpty ?? true
                  : data?['repo'] == true &&
                        ((data?['files'] as List?)?.isEmpty ?? true);
            },
            builder: (d) {
              final data = d! as Map;
              if (!_history && data['repo'] != true) {
                return PanelNote(
                  text: l10n.gitNotRepo,
                  icon: LucideIcons.gitBranch,
                );
              }
              return _history
                  ? _Log(
                      data: data,
                      onOpen: (sha, subject) =>
                          _open(panelKey(id, 'git/commits/$sha'), subject),
                    )
                  : _Status(
                      data: data,
                      onOpen: (file) {
                        final index = '${file['index']}';
                        final worktree = '${file['worktree']}';
                        _open(
                          panelKey(
                            id,
                            'git/diff',
                            query: {
                              'path': '${file['path']}',
                              if (index == '?') 'untracked': '1',
                              if (index != '?' &&
                                  index != ' ' &&
                                  worktree == ' ')
                                'staged': '1',
                            },
                          ),
                          '${file['path']}',
                        );
                      },
                    );
            },
          ),
        ),
      ],
    );
  }
}

class _Status extends StatelessWidget {
  const _Status({required this.data, required this.onOpen});
  final Map data;
  final ValueChanged<Map> onOpen;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final files = (data['files'] as List? ?? const []).cast<Map>();
    return ListView(
      children: [
        ListTile(
          leading: const Icon(LucideIcons.gitBranch, size: 18),
          title: Text('${data['branch'] ?? l10n.gitDetached}'),
          subtitle: data['upstream'] == null
              ? null
              : Text(
                  l10n.gitAheadBehind(
                    '${data['upstream']}',
                    (data['ahead'] as num?)?.toInt() ?? 0,
                    (data['behind'] as num?)?.toInt() ?? 0,
                  ),
                ),
        ),
        for (final file in files)
          ListTile(
            dense: true,
            leading: Text(
              '${file['index']}${file['worktree']}',
              style: const TextStyle(fontFamily: 'monospace'),
            ),
            title: Text('${file['path']}'),
            onTap: () => onOpen(file),
          ),
        if (data['truncated'] == true)
          ListTile(dense: true, title: Text(l10n.panelTruncated)),
      ],
    );
  }
}

class _Log extends ConsumerWidget {
  const _Log({required this.data, required this.onOpen});
  final Map data;
  final void Function(String sha, String subject) onOpen;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final commits = (data['commits'] as List? ?? const []).cast<Map>();
    return ListView(
      children: [
        for (final commit in commits)
          ListTile(
            dense: true,
            title: Text('${commit['subject']}'),
            subtitle: Text(
              '${commit['short']} · ${commit['author']} · '
              '${listTime(context, (commit['time'] as num?)?.toInt() ?? 0, now: ref.read(clockProvider)())}',
            ),
            onTap: () => onOpen('${commit['sha']}', '${commit['subject']}'),
          ),
      ],
    );
  }
}
