import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'common.dart';
import 'gateway.dart';

/// Versioned display blocks travel inside existing persisted assistant messages.
/// Malformed/unsupported blocks keep their ordinary Markdown fallback.
class Artifact {
  Artifact(this.data, this.messageId);
  final Json data;
  final String messageId;
  String get id => data['id'] as String;
  int get version => (data['version'] as num).toInt();
  String get title => '${data['title']}';
  String get kind => '${data['type'] ?? 'markdown'}';
  String get content => '${data['content'] ?? ''}';
  String get summary => '${data['summary'] ?? ''}';
  String get status => '${data['status'] ?? 'complete'}';
  String get identity => '$id:$version';
  String get shareText => kind == 'table'
      ? '$title\n${(data['columns'] is List ? data['columns'] as List : <dynamic>[]).join('\t')}\n${(data['rows'] is List ? data['rows'] as List : <dynamic>[]).whereType<List>().map((row) => row.join('\t')).join('\n')}'
      : content;
}

final _blocks = RegExp(
  r'^```pirc-artifact\s*\n([\s\S]*?)\n```\s*$',
  multiLine: true,
);
List<Artifact> messageArtifacts(Json message) {
  if (message['role'] != 'assistant') return [];
  final found = <Artifact>[];
  for (final match in _blocks.allMatches('${message['content'] ?? ''}')) {
    if (match.group(1)!.length > 1024 * 1024) continue;
    try {
      final data = obj(jsonDecode(match.group(1)!));
      if (data['id'] is! String ||
          (data['id'] as String).isEmpty ||
          data['title'] is! String ||
          (data['title'] as String).trim().isEmpty ||
          data['version'] is! int ||
          (data['version'] as int) < 1) {
        continue;
      }
      if (message['partial'] == true) data['status'] = 'generating';
      found.add(Artifact(data, '${message['id']}'));
    } catch (_) {
      /* Display original Markdown instead. */
    }
  }
  return found;
}

String artifactProse(Json message) =>
    '${message['content'] ?? ''}'.replaceAllMapped(_blocks, (match) {
      final candidate = {...message, 'content': match.group(0)};
      return messageArtifacts(candidate).isEmpty ? match.group(0)! : '';
    }).trim();
List<Artifact> artifactVersions(List<Json> messages, String id) {
  final versions = <int, Artifact>{};
  for (final message in messages) {
    for (final artifact in messageArtifacts(message).where((a) => a.id == id)) {
      final old = versions[artifact.version];
      // Completed revisions are immutable. A later duplicate cannot rewrite one.
      if (old == null || old.status == 'generating') {
        versions[artifact.version] = artifact;
      }
    }
  }
  final result = versions.values.toList()
    ..sort((a, b) => a.version.compareTo(b.version));
  return result;
}

class ArtifactCard extends StatelessWidget {
  const ArtifactCard({super.key, required this.artifact, required this.onOpen});
  final Artifact artifact;
  final VoidCallback onOpen;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 12),
    child: Surface(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                LucideIcons.fileText,
                size: 18,
                color: palette(context)['accent.default'],
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '${artifact.kind} · v${artifact.version}',
                  style: TextStyle(
                    fontSize: 12,
                    color: palette(context)['text.muted'],
                  ),
                ),
              ),
              if (artifact.status == 'generating') const Text('生成中…'),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            artifact.title,
            style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
          ),
          if (artifact.summary.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                artifact.summary,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          if (artifact.status == 'failed')
            const Padding(
              padding: EdgeInsets.only(top: 8),
              child: Text('生成未完成 · 可查看最後可用版本'),
            ),
          TextButton.icon(
            onPressed: onOpen,
            icon: const Icon(LucideIcons.arrowUpRight, size: 18),
            label: Text(artifact.status == 'generating' ? '閱讀已產生內容' : '開啟成果'),
          ),
        ],
      ),
    ),
  );
}

class ArtifactPane extends StatefulWidget {
  const ArtifactPane({
    super.key,
    required this.controller,
    required this.initial,
  });
  final LiveController controller;
  final Artifact initial;
  @override
  State<ArtifactPane> createState() => _ArtifactPaneState();
}

class _ArtifactPaneState extends State<ArtifactPane> {
  late final cache = widget.controller.panelState.putIfAbsent(
    '${widget.controller.sessionId}:artifact:${widget.initial.id}',
    () => {},
  );
  late Artifact selected;
  late final ScrollController scroll;
  List<Artifact> get versions =>
      artifactVersions(widget.controller.messages, widget.initial.id);
  String offsetKey(Artifact a) => '${a.identity}:${a.content.hashCode}';
  @override
  void initState() {
    super.initState();
    selected = cache['selected'] is Artifact
        ? cache['selected'] as Artifact
        : widget.initial.status == 'failed'
        ? versions.where((a) => a.status == 'complete').lastOrNull ??
              widget.initial
        : widget.initial;
    scroll = ScrollController(
      initialScrollOffset: (cache[offsetKey(selected)] as double?) ?? 0,
    )..addListener(save);
    widget.controller.addListener(update);
  }

  void update() {
    if (mounted) setState(() {});
  }

  void save() {
    cache['selected'] = selected;
    if (scroll.hasClients) cache[offsetKey(selected)] = scroll.offset;
  }

  void select(Artifact value) {
    save();
    setState(() => selected = value);
    cache['selected'] = value;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (scroll.hasClients) {
        scroll.jumpTo(
          ((cache[offsetKey(value)] as double?) ?? 0).clamp(
            0,
            scroll.position.maxScrollExtent,
          ),
        );
      }
    });
  }

  @override
  void dispose() {
    save();
    widget.controller.removeListener(update);
    scroll.dispose();
    super.dispose();
  }

  Widget content() {
    final a = selected;
    switch (a.kind) {
      case 'markdown':
        return RichTextBody(
          a.content,
          reader: true,
          gateway: widget.controller.gateway,
        );
      case 'code':
        return SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: SelectableText(
            a.content,
            style: const TextStyle(
              fontFamily: 'monospace',
              fontSize: 13,
              height: 1.6,
            ),
          ),
        );
      case 'table':
        final columns =
            (a.data['columns'] is List
                    ? a.data['columns'] as List
                    : <dynamic>[])
                .map((c) => '$c')
                .toList();
        final records =
            (a.data['rows'] is List ? a.data['rows'] as List : <dynamic>[])
                .whereType<List>()
                .toList();
        if (columns.isEmpty) return const Text('此表格沒有欄位');
        return SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: DataTable(
            columns: [for (final col in columns) DataColumn(label: Text(col))],
            rows: [
              for (final row in records)
                DataRow(
                  cells: [
                    for (var i = 0; i < columns.length; i++)
                      DataCell(
                        SelectableText(i < row.length ? '${row[i]}' : ''),
                      ),
                  ],
                ),
            ],
          ),
        );
      case 'image':
        final uri = Uri.tryParse(a.content);
        if (uri?.scheme == 'data' &&
            [
              'image/png',
              'image/jpeg',
              'image/webp',
            ].contains(uri?.data?.mimeType)) {
          try {
            return InteractiveViewer(
              child: Image.memory(
                uri!.data!.contentAsBytes(),
                errorBuilder: (_, e, s) =>
                    Text(a.summary.isEmpty ? '圖片無法顯示' : a.summary),
              ),
            );
          } catch (_) {
            return Text(a.summary);
          }
        }
        return Text(a.summary.isEmpty ? '開啟網頁查看圖片' : a.summary);
      default:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '此成果類型以摘要顯示',
              style: TextStyle(color: palette(context)['text.muted']),
            ),
            const SizedBox(height: 12),
            RichTextBody(
              a.summary.isNotEmpty ? a.summary : a.content,
              gateway: widget.controller.gateway,
            ),
          ],
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final list = versions;
    final latest = list.lastOrNull;
    final available =
        latest != null &&
        (latest.version > selected.version ||
            latest.version == selected.version &&
                (latest.content != selected.content ||
                    latest.status != selected.status));
    final url = Uri.tryParse('${selected.data['url'] ?? ''}');
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  '${selected.title} · v${selected.version}',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              PopupMenuButton<int>(
                tooltip: '成果版本',
                onSelected: (v) =>
                    select(list.firstWhere((a) => a.version == v)),
                itemBuilder: (_) => [
                  for (final a in list)
                    PopupMenuItem(
                      value: a.version,
                      child: Text('v${a.version}'),
                    ),
                ],
              ),
              IconButton(
                tooltip: '複製成果',
                onPressed: () =>
                    Clipboard.setData(ClipboardData(text: selected.shareText)),
                icon: const Icon(LucideIcons.copy, size: 18),
              ),
              IconButton(
                tooltip: '分享成果',
                onPressed: () => guarded(context, () async {
                  await widget.controller.gateway.call('share', {
                    'text': selected.shareText,
                  });
                }),
                icon: const Icon(LucideIcons.share2, size: 18),
              ),
            ],
          ),
        ),
        if (available)
          TextButton(
            onPressed: () => select(latest),
            child: Text(
              latest.version > selected.version
                  ? '已有 v${latest.version} · 切換新版'
                  : '內容已更新 · 切換',
            ),
          ),
        Expanded(
          child: ListView(
            key: const Key('artifact-content'),
            controller: scroll,
            padding: const EdgeInsets.all(24),
            children: [
              content(),
              if (selected.status == 'generating')
                const Padding(
                  padding: EdgeInsets.only(top: 20),
                  child: Text('仍在生成 · 新內容不會取代目前閱讀位置'),
                ),
              if (latest?.status == 'failed' || selected.status == 'failed')
                TextButton(
                  onPressed:
                      widget.controller.canWrite &&
                          !widget.controller.unknownCommand
                      ? () => guarded(context, () async {
                          final sent = await widget.controller.sendCommand({
                            'type': 'prompt',
                            'message':
                                '請重試產生成果「${selected.title}」（id: ${selected.id}），以新版本保留既有內容。',
                          });
                          if (context.mounted) {
                            showNotice(
                              context,
                              sent
                                  ? '已請 agent 重試'
                                  : widget.controller.actionError ?? '暫時無法送出',
                            );
                          }
                        })
                      : null,
                  child: const Text('請 agent 重試…'),
                ),
              if (url != null && ['https', 'http'].contains(url.scheme))
                TextButton.icon(
                  onPressed: () => guarded(context, () async {
                    await widget.controller.gateway.call('external', {
                      'url': url.toString(),
                    });
                  }),
                  icon: const Icon(LucideIcons.externalLink, size: 16),
                  label: const Text('在網頁開啟'),
                ),
              if (rows(selected.data['sources']).isNotEmpty) ...[
                const SizedBox(height: 24),
                const Text('來源', style: TextStyle(fontWeight: FontWeight.w600)),
                for (final source in rows(selected.data['sources']))
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text('${source['title'] ?? source['url']}'),
                    onTap: () => guarded(context, () async {
                      final link = Uri.tryParse('${source['url']}');
                      if (link != null &&
                          ['http', 'https'].contains(link.scheme)) {
                        await widget.controller.gateway.call('external', {
                          'url': link.toString(),
                        });
                      }
                    }),
                  ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}
