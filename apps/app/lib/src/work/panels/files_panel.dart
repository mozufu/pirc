import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:pirc_ui/pirc_ui.dart';

import '../../../l10n/app_localizations.dart';
import 'panel_common.dart';
import '../session_controller.dart';

/// 10a. Files (read only): `GET …/files?path=` with a path bar, and
/// `…/files/content?path=` for one file.
class FilesPanel extends ConsumerStatefulWidget {
  const FilesPanel({super.key, required this.sessionId});
  final String sessionId;

  @override
  ConsumerState<FilesPanel> createState() => _FilesPanelState();
}

class _FilesPanelState extends ConsumerState<FilesPanel> {
  String _dir = '';
  String? _file;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final key = _file == null
        ? panelKey(
            widget.sessionId,
            'files',
            query: {if (_dir.isNotEmpty) 'path': _dir},
            sections: const [anyPanelChange],
          )
        : panelKey(
            widget.sessionId,
            'files/content',
            query: {'path': _file!},
            sections: const [anyPanelChange],
          );
    final value = ref.watch(panelReadProvider(key));
    final parts = [
      for (final part in (_file ?? _dir).split('/'))
        if (part.isNotEmpty) part,
    ];
    // System Back leaves an open file for its folder, then goes up one
    // folder at a time; at the root it closes the panel (tab_screen.dart).
    return BackButtonListener(
      onBackButtonPressed: () async {
        if (_file == null && _dir.isEmpty) return false;
        setState(() {
          if (_file != null) {
            _file = null;
          } else {
            final cut = _dir.lastIndexOf('/');
            _dir = cut < 0 ? '' : _dir.substring(0, cut);
          }
        });
        return true;
      },
      child: _body(context, l10n, key, value, parts),
    );
  }

  Widget _body(
    BuildContext context,
    AppLocalizations l10n,
    PanelKey key,
    AsyncValue<Object?> value,
    List<String> parts,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // The path bar: each part opens that folder.
        SizedBox(
          height: 44,
          child: Row(
            children: [
              Expanded(
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  children: [
                    TextButton.icon(
                      onPressed: () => setState(() {
                        _dir = '';
                        _file = null;
                      }),
                      icon: const Icon(LucideIcons.house, size: 16),
                      label: Text(l10n.filesRoot),
                    ),
                    for (final (i, part) in parts.indexed)
                      TextButton(
                        onPressed: i == parts.length - 1 && _file != null
                            ? null
                            : () => setState(() {
                                _dir = parts.take(i + 1).join('/');
                                _file = null;
                              }),
                        child: Text('/ $part'),
                      ),
                  ],
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
            value: value,
            onRetry: () => ref.invalidate(panelReadProvider(key)),
            emptyText: l10n.filesEmpty,
            isEmpty: (data) =>
                _file == null &&
                ((data as Map?)?['entries'] as List?)?.isEmpty == true,
            builder: (data) => _file == null
                ? _Listing(
                    data: data! as Map,
                    onOpen: (name, kind) => setState(() {
                      final path = _dir.isEmpty ? name : '$_dir/$name';
                      if (kind == 'dir') {
                        _dir = path;
                      } else {
                        _file = path;
                      }
                    }),
                  )
                : _FileView(data: data! as Map),
          ),
        ),
      ],
    );
  }
}

class _Listing extends StatelessWidget {
  const _Listing({required this.data, required this.onOpen});
  final Map data;
  final void Function(String name, String kind) onOpen;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final entries = (data['entries'] as List? ?? const []).cast<Map>();
    return ListView(
      children: [
        for (final entry in entries)
          ListTile(
            dense: true,
            leading: Icon(switch (entry['kind']) {
              'dir' => LucideIcons.folder,
              'symlink' => LucideIcons.link,
              _ => LucideIcons.file,
            }, size: 18),
            title: Text('${entry['name']}'),
            trailing: entry['size'] is num
                ? Text(_bytes(entry['size'] as num))
                : null,
            onTap: entry['kind'] == 'dir' || entry['kind'] == 'file'
                ? () => onOpen('${entry['name']}', '${entry['kind']}')
                : null,
          ),
        if (data['truncated'] == true)
          ListTile(dense: true, title: Text(l10n.panelTruncated)),
      ],
    );
  }
}

String _bytes(num size) => size < 1024
    ? '$size B'
    : size < 1024 * 1024
    ? '${(size / 1024).toStringAsFixed(1)} KB'
    : '${(size / 1024 / 1024).toStringAsFixed(1)} MB';

class _FileView extends StatelessWidget {
  const _FileView({required this.data});
  final Map data;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final colors = PircColorTokens.of(context);
    final image = data['image'] as Map?;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text(
          '${data['path']} · ${_bytes((data['size'] as num?) ?? 0)}',
          style: Theme.of(context).textTheme.labelSmall,
        ),
        const SizedBox(height: 8),
        if (image != null)
          Image.memory(base64Decode('${image['dataBase64']}'))
        else if (data['binary'] == true)
          Text(
            data['imageTooLarge'] == true
                ? l10n.filesImageTooLarge
                : l10n.filesBinary,
          )
        else
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: SelectableText(
              '${data['content'] ?? ''}',
              style: PircType.monoCode.style(color: colors['code.text']),
            ),
          ),
        if (data['truncated'] == true)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(l10n.panelTruncated),
          ),
      ],
    );
  }
}
