import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:xterm/xterm.dart';
import 'gateway.dart';
import 'common.dart';

class CodeDocument extends StatelessWidget {
  const CodeDocument({super.key, required this.text, this.diff = false});
  final String text;
  final bool diff;
  @override
  Widget build(BuildContext context) => SingleChildScrollView(
    scrollDirection: Axis.horizontal,
    child: SelectionArea(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final line in text.split('\n'))
            Text(
              line.isEmpty ? ' ' : line,
              style: TextStyle(
                fontFamily: 'monospace',
                fontSize: 13,
                height: 1.6,
                backgroundColor:
                    diff && (line.startsWith('+') || line.startsWith('-'))
                    ? palette(context)[line.startsWith('+')
                              ? 'status.success'
                              : 'status.danger']
                          .withValues(alpha: .08)
                    : null,
                color: diff
                    ? (line.startsWith('+')
                          ? palette(context)['text.success']
                          : line.startsWith('-')
                          ? palette(context)['status.danger']
                          : null)
                    : null,
              ),
            ),
        ],
      ),
    ),
  );
}

class WorkPanel extends StatelessWidget {
  const WorkPanel({
    super.key,
    required this.controller,
    required this.kind,
    required this.onOpen,
    this.path,
  });
  final LiveController controller;
  final String kind;
  final String? path;
  final void Function(Widget) onOpen;
  @override
  Widget build(BuildContext context) {
    final c = controller;
    final id = c.sessionId!;
    final base = sessionPath(id);
    if (kind == 'browser') return BrowserPane(controller: c);
    if (kind == 'files') {
      return FilesPane(controller: c, initialPath: path ?? '');
    }
    return RemotePage(
      load: () => c.gateway.request(
        kind == 'git'
            ? '$base/git/status'
            : kind == 'terminals'
            ? '$base/terminals'
            : '$base/panel/state',
      ),
      builder: (context, data, reload) => ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  {
                        'git': 'Git',
                        'terminals': '終端',
                        'tasks': 'Tasks',
                        'memory': '記憶',
                      }[kind] ??
                      kind,
                  style: const TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              IconButton(
                tooltip: '重新整理',
                onPressed: reload,
                icon: const Icon(LucideIcons.refreshCw),
              ),
            ],
          ),
          if (kind == 'git') ...[
            if (data['repo'] != true)
              const Text('此工作空間不是 Git 儲存庫')
            else ...[
              Text(
                '${data['branch'] ?? 'detached'} · ↑ ${data['ahead'] ?? 0} ↓ ${data['behind'] ?? 0}',
              ),
              const SizedBox(height: 16),
              if (rows(data['files']).isEmpty)
                const SupportingState(title: '工作目錄乾淨', detail: '目前沒有尚未提交的變更。'),
              if (data['truncated'] == true) const Text('變更較多，僅顯示部分檔案'),
              for (final (index, f) in rows(data['files']).indexed)
                GitDiffCard(
                  key: ValueKey(f['path']),
                  controller: c,
                  file: f,
                  initiallyExpanded: index == 0,
                ),
              TextButton(
                onPressed: () => onOpen(CommitHistory(controller: c)),
                child: const Text('提交紀錄'),
              ),
            ],
          ],
          if (kind == 'terminals') ...[
            const Padding(
              padding: EdgeInsets.only(bottom: 16),
              child: Text('在工作空間執行指令。點選終端可開啟完整字元畫面。'),
            ),
            FilledButton.icon(
              onPressed: c.connection != 'live'
                  ? null
                  : () => guarded(context, () async {
                      await c.takeControl();
                      if (c.control['held'] != true) {
                        throw StateError('請先取得控制權');
                      }
                      final d = await c.gateway.request(
                        '$base/terminals',
                        method: 'POST',
                        body: {
                          'clientId': c.clientId,
                          'generation': c.control['generation'],
                          'cols': 80,
                          'rows': 24,
                        },
                      );
                      if (context.mounted) {
                        Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) => TerminalPage(
                              controller: c,
                              terminal: obj(d['terminal']),
                            ),
                          ),
                        );
                      }
                      reload();
                    }),
              icon: const Icon(LucideIcons.plus),
              label: const Text('新終端'),
            ),
            if (rows(data['terminals']).isEmpty)
              const Padding(padding: EdgeInsets.all(20), child: Text('尚未建立終端')),
            for (final t in rows(data['terminals']))
              ListTile(
                title: Text('${t['title'] ?? t['id']}'),
                subtitle: Text(
                  '${t['cwd'] ?? ''}\n${t['cols']} × ${t['rows']} · ${t['exited'] == true ? '已結束' : '執行中'}',
                ),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => TerminalPage(controller: c, terminal: t),
                  ),
                ),
                trailing: IconButton(
                  tooltip: t['exited'] == true ? '移除終端' : '結束終端',
                  icon: const Icon(LucideIcons.x),
                  onPressed: () => guarded(context, () async {
                    if (await confirm(
                      context,
                      t['exited'] == true ? '移除終端' : '結束終端',
                      t['exited'] == true ? '從列表移除已結束的終端。' : '此終端中的程序將被停止。',
                    )) {
                      await c.takeControl();
                      if (c.control['held'] != true) {
                        throw StateError('請先取得控制權');
                      }
                      await c.gateway.request(
                        '$base/terminals/${enc('${t['id']}')}/close',
                        method: 'POST',
                        body: {
                          'clientId': c.clientId,
                          'generation': c.control['generation'],
                        },
                      );
                      reload();
                    }
                  }),
                ),
              ),
          ],
          if (kind == 'tasks') ...[
            const Text('背景指令', style: TextStyle(fontWeight: FontWeight.w600)),
            if (rows(data['backgroundTasks']).isEmpty)
              const Padding(padding: EdgeInsets.all(16), child: Text('沒有背景指令')),
            for (final task in rows(data['backgroundTasks']))
              ListTile(
                title: Text('${task['command']}'),
                subtitle: Text('${task['status']}'),
                onTap: () => onOpen(
                  RemotePage(
                    load: () => c.gateway.request(
                      '$base/panel/background/${enc('${task['id']}')}?lines=400',
                    ),
                    builder: (_, d, reload) => ListView(
                      padding: const EdgeInsets.all(16),
                      children: [CodeDocument(text: '${d['output'] ?? ''}')],
                    ),
                  ),
                ),
                trailing: task['status'] == 'running'
                    ? TextButton(
                        onPressed: () => guarded(context, () async {
                          if (await confirm(
                            context,
                            '停止背景指令',
                            '${task['command']}',
                          )) {
                            await c.takeControl();
                            if (c.control['held'] != true) {
                              throw StateError('請先取得控制權');
                            }
                            await c.gateway.request(
                              '$base/panel/background/${enc('${task['id']}')}/stop',
                              method: 'POST',
                              body: {
                                'clientId': c.clientId,
                                'generation': c.control['generation'],
                              },
                            );
                            reload();
                          }
                        }),
                        child: const Text('停止'),
                      )
                    : null,
              ),
            const SizedBox(height: 16),
            const Text(
              'Teammates',
              style: TextStyle(fontWeight: FontWeight.w600),
            ),
            if (rows(obj(data['team'])['agents']).isEmpty)
              const ListTile(
                title: Text('目前沒有隊友'),
                subtitle: Text('Agent 委派的工作會顯示在這裡。'),
              ),
            for (final member in rows(obj(data['team'])['agents']))
              ListTile(
                title: Text('${member['name']}'),
                subtitle: Text('${member['status']} · ${member['task'] ?? ''}'),
              ),
            const Text('任務板', style: TextStyle(fontWeight: FontWeight.w600)),
            if (rows(obj(data['team'])['tasks']).isEmpty)
              const ListTile(
                title: Text('尚無任務'),
                subtitle: Text('任務進度與負責人會同步顯示。'),
              ),
            for (final task in rows(obj(data['team'])['tasks']))
              ExpansionTile(
                title: Text('${task['subject']}'),
                subtitle: Text('${task['status']} · ${task['owner'] ?? ''}'),
                children: [Text('${task['description'] ?? ''}')],
              ),
            const Text('訊息', style: TextStyle(fontWeight: FontWeight.w600)),
            if (rows(obj(data['team'])['events']).isEmpty)
              const ListTile(title: Text('尚無訊息')),
            for (final event in rows(obj(data['team'])['events']))
              ListTile(
                title: Text(
                  '${event['from'] ?? event['kind']} → ${event['to'] ?? ''}',
                ),
                subtitle: Text('${event['body'] ?? ''}'),
              ),
          ],
          if (kind == 'memory') ...[
            Text(
              data['memory'] == null
                  ? '目前無法取得記憶'
                  : obj(data['memory'])['enabled'] == true
                  ? ({
                          'working': '正在整理記憶',
                          'observing': '正在整理觀察',
                          'reflecting': '正在反思',
                          'idle': '記憶已就緒',
                        }[obj(data['memoryRuntime'])['phase']] ??
                        '記憶已就緒')
                  : '記憶已停用',
            ),
            const SizedBox(height: 16),
            if (data['memory'] != null &&
                rows(obj(data['memory'])['observations']).isEmpty)
              const SupportingState(
                title: '還沒有觀察紀錄',
                detail: '累積對話後，最近觀察與反思會顯示在這裡。',
              ),
            for (final entry in obj(
              obj(data['memoryRuntime'])['lastErrors'],
            ).entries)
              Text(
                '${entry.key}：${entry.value}',
                style: TextStyle(color: palette(context)['status.danger']),
              ),
            for (final observation in rows(obj(data['memory'])['observations']))
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Surface(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      RichTextBody(
                        '${observation['content']}',
                        gateway: c.gateway,
                      ),
                      const SizedBox(height: 8),
                      Text(
                        '${observation['timestamp'] ?? ''} · ${observation['relevance'] ?? 'medium'}',
                        style: TextStyle(
                          fontSize: 12,
                          color: palette(context)['text.muted'],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            for (final reflection in rows(obj(data['memory'])['reflections']))
              ExpansionTile(
                title: const Text('反思'),
                children: [
                  RichTextBody('${reflection['content']}', gateway: c.gateway),
                  if ((reflection['supportingObservationIds'] as List? ?? [])
                      .isNotEmpty)
                    Text(
                      '來源觀察：${(reflection['supportingObservationIds'] as List).join('、')}',
                    ),
                ],
              ),
          ],
        ],
      ),
    );
  }
}

class GitDiffCard extends StatefulWidget {
  const GitDiffCard({
    super.key,
    required this.controller,
    required this.file,
    this.initiallyExpanded = false,
  });
  final LiveController controller;
  final Json file;
  final bool initiallyExpanded;
  @override
  State<GitDiffCard> createState() => _GitDiffCardState();
}

class _GitDiffCardState extends State<GitDiffCard> {
  Future<List<Json>>? future;
  @override
  void initState() {
    super.initState();
    if (widget.initiallyExpanded) future = load();
  }

  @override
  void didUpdateWidget(covariant GitDiffCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.file, widget.file) && future != null) {
      future = load();
    }
  }

  Future<List<Json>> load() async {
    final f = widget.file;
    final base = sessionPath(widget.controller.sessionId!);
    final diffs = <Json>[];
    if (f['index'] != ' ' && f['index'] != '?' && f['index'] != null) {
      diffs.add({
        'title': '已暫存',
        ...await widget.controller.gateway.request(
          '$base/git/diff?path=${enc('${f['path']}')}&staged=1',
        ),
      });
    }
    if (f['worktree'] != ' ' && f['worktree'] != null) {
      diffs.add({
        'title': f['worktree'] == '?' ? '未追蹤' : '工作目錄',
        ...await widget.controller.gateway.request(
          '$base/git/diff?path=${enc('${f['path']}')}${f['worktree'] == '?' ? '&untracked=1' : ''}',
        ),
      });
    }
    return diffs;
  }

  @override
  Widget build(BuildContext context) => ExpansionTile(
    key: PageStorageKey('diff:${widget.file['path']}'),
    initiallyExpanded: widget.initiallyExpanded,
    tilePadding: EdgeInsets.zero,
    shape: const Border(),
    collapsedShape: const Border(),
    leading: Text(
      '${widget.file['index'] != ' ' ? widget.file['index'] : widget.file['worktree']}',
      style: TextStyle(color: palette(context)['text.warning']),
    ),
    title: Text(
      '${widget.file['path']}',
      style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
    ),
    onExpansionChanged: (open) {
      if (open && future == null) setState(() => future = load());
    },
    children: [
      if (future != null)
        FutureBuilder<List<Json>>(
          future: future,
          builder: (context, snapshot) {
            if (snapshot.hasError) {
              return SupportingState(
                title: '無法載入差異',
                detail: LiveController.describe(snapshot.error!),
                onRetry: () => setState(() => future = load()),
              );
            }
            if (!snapshot.hasData) {
              return const Padding(
                padding: EdgeInsets.all(16),
                child: Text('正在載入差異…'),
              );
            }
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final diff in snapshot.data!) ...[
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Text(
                      '${diff['title']}',
                      style: TextStyle(
                        fontSize: 12.5,
                        color: palette(context)['text.muted'],
                      ),
                    ),
                  ),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: palette(context)['code.bg'],
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: CodeDocument(
                      text: '${diff['diff'] ?? ''}',
                      diff: true,
                    ),
                  ),
                  if (diff['truncated'] == true) const Text('內容已截斷'),
                ],
              ],
            );
          },
        ),
    ],
  );
}

class FilesPane extends StatefulWidget {
  const FilesPane({
    super.key,
    required this.controller,
    required this.initialPath,
  });
  final LiveController controller;
  final String initialPath;
  @override
  State<FilesPane> createState() => _FilesPaneState();
}

class _FilesPaneState extends State<FilesPane> {
  late final cache = widget.controller.panelState.putIfAbsent(
    '${widget.controller.sessionId}:files',
    () => {},
  );
  late String path = widget.initialPath.isNotEmpty
      ? widget.initialPath
      : '${cache['path'] ?? ''}';
  late bool file = widget.initialPath.isEmpty && cache['file'] == true;
  Set<String> changes = {};
  @override
  void initState() {
    super.initState();
    if (!widget.controller.chat) {
      widget.controller.gateway
          .request('${sessionPath(widget.controller.sessionId!)}/git/status')
          .then((v) {
            if (mounted) {
              setState(
                () => changes = rows(
                  v['files'],
                ).map((f) => '${f['path']}').toSet(),
              );
            }
          })
          .catchError((Object _) {});
    }
  }

  late Future<Json> data = load();
  Future<Json> load() async {
    final target = obj(
      await widget.controller.gateway.call('fileLink', {'href': path}),
    );
    path = '${target['path'] ?? path}';
    final base = sessionPath(widget.controller.sessionId!);
    if (file) {
      return widget.controller.gateway.request(
        '$base/files/content?path=${enc(path)}',
      );
    }
    try {
      return await widget.controller.gateway.request(
        '$base/files?path=${enc(path)}',
      );
    } catch (e) {
      if (path.isEmpty ||
          e is! PlatformException ||
          !['HTTP_400', 'HTTP_404', 'HTTP_409'].contains(e.code)) {
        rethrow;
      }
      final value = await widget.controller.gateway.request(
        '$base/files/content?path=${enc(path)}',
      );
      file = true;
      return value;
    }
  }

  void go(String next, {bool isFile = false}) => setState(() {
    path = next;
    file = isFile;
    cache.addAll({'path': path, 'file': file});
    data = load();
  });
  @override
  Widget build(BuildContext context) => Column(
    children: [
      Row(
        children: [
          IconButton(
            tooltip: '上層資料夾',
            onPressed: path.isEmpty
                ? null
                : () => go(
                    path.contains('/')
                        ? path.substring(0, path.lastIndexOf('/'))
                        : '',
                  ),
            icon: const Icon(LucideIcons.arrowUp),
          ),
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  TextButton(
                    onPressed: () => go(''),
                    child: const Text('工作空間'),
                  ),
                  for (final (i, segment)
                      in path
                          .split('/')
                          .where((s) => s.isNotEmpty)
                          .indexed) ...[
                    const Icon(LucideIcons.chevronRight, size: 14),
                    TextButton(
                      onPressed: () => go(
                        path.split('/').take(i + 1).join('/'),
                        isFile: file && i == path.split('/').length - 1,
                      ),
                      child: Text(segment),
                    ),
                  ],
                ],
              ),
            ),
          ),
          IconButton(
            tooltip: '重新整理',
            onPressed: () => go(path, isFile: file),
            icon: const Icon(LucideIcons.refreshCw),
          ),
        ],
      ),
      Expanded(
        child: FutureBuilder<Json>(
          future: data,
          builder: (context, s) {
            if (s.hasError) {
              return SupportingState(
                title: '無法讀取檔案',
                detail: LiveController.describe(s.error!),
                onRetry: () => go(path, isFile: file),
              );
            }
            if (!s.hasData) {
              return const Center(child: CircularProgressIndicator());
            }
            final d = s.data!;
            if (file) {
              return ListView(
                key: PageStorageKey('file:$path'),
                padding: const EdgeInsets.all(16),
                children: [
                  if (d['binary'] == true)
                    const Text('二進位檔案，無法以文字顯示')
                  else ...[
                    Row(
                      children: [
                        TextButton.icon(
                          onPressed: () => Clipboard.setData(
                            ClipboardData(text: '${d['content'] ?? ''}'),
                          ),
                          icon: const Icon(LucideIcons.copy),
                          label: const Text('複製'),
                        ),
                      ],
                    ),
                    path.endsWith('.md')
                        ? RichTextBody(
                            '${d['content'] ?? ''}',
                            gateway: widget.controller.gateway,
                            onFile: (link) => go(link),
                          )
                        : CodeDocument(text: '${d['content'] ?? ''}'),
                    if (d['truncated'] == true) const Text('檔案過大，僅顯示前段內容'),
                  ],
                ],
              );
            }
            return ListView(
              key: PageStorageKey('directory:$path'),
              children: [
                if (path.isEmpty) ...[
                  for (final recent
                      in widget.controller.messages
                          .expand((m) => rows(m['tools']))
                          .where(
                            (t) => [
                              'read',
                              'read_file',
                              'edit',
                              'write',
                            ].contains(t['name']),
                          )
                          .map(
                            (t) =>
                                obj(t['input'])['path'] ??
                                obj(t['input'])['file_path'],
                          )
                          .whereType<String>()
                          .toSet()
                          .take(5))
                    ListTile(
                      leading: const Icon(LucideIcons.history, size: 18),
                      title: Text(recent),
                      subtitle: const Text('Agent 最近開啟'),
                      onTap: () => go(recent, isFile: true),
                    ),
                ],
                if (rows(d['entries']).isEmpty)
                  const Padding(
                    padding: EdgeInsets.all(24),
                    child: Text('資料夾是空的'),
                  ),
                for (final entry in rows(d['entries']))
                  ListTile(
                    leading: Icon(
                      entry['kind'] == 'dir'
                          ? LucideIcons.folder
                          : LucideIcons.fileText,
                    ),
                    title: Text('${entry['name']}'),
                    trailing:
                        changes.any(
                          (f) =>
                              f ==
                                  '${path.isEmpty ? '' : '$path/'}${entry['name']}' ||
                              f.startsWith(
                                '${path.isEmpty ? '' : '$path/'}${entry['name']}/',
                              ),
                        )
                        ? Text(
                            '已變更',
                            style: TextStyle(
                              fontSize: 12,
                              color: palette(context)['text.warning'],
                            ),
                          )
                        : null,
                    subtitle: entry['size'] == null
                        ? null
                        : Text('${entry['size']} bytes'),
                    onTap: () => go(
                      '${path.isEmpty ? '' : '$path/'}${entry['name']}',
                      isFile: entry['kind'] != 'dir',
                    ),
                  ),
              ],
            );
          },
        ),
      ),
    ],
  );
}

class CommitHistory extends StatefulWidget {
  const CommitHistory({super.key, required this.controller});
  final LiveController controller;
  @override
  State<CommitHistory> createState() => _CommitHistoryState();
}

class _CommitHistoryState extends State<CommitHistory> {
  final commits = <Json>[];
  bool more = true, busy = false;
  String? error;
  Json? detail;
  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    if (busy) return;
    setState(() => busy = true);
    try {
      final d = await widget.controller.gateway.request(
        '${sessionPath(widget.controller.sessionId!)}/git/log?skip=${commits.length}&limit=50',
      );
      if (mounted) {
        commits.addAll(rows(d['commits']));
        more = d['more'] == true;
      }
    } catch (e) {
      error = LiveController.describe(e);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => ListView(
    padding: const EdgeInsets.all(16),
    children: [
      if (detail != null) ...[
        TextButton(
          onPressed: () => setState(() => detail = null),
          child: const Text('返回紀錄'),
        ),
        Text('${detail!['message']}'),
        CodeDocument(text: '${detail!['diff'] ?? ''}', diff: true),
      ] else ...[
        const Text(
          '提交紀錄',
          style: TextStyle(fontSize: 22, fontWeight: FontWeight.w600),
        ),
        for (final commit in commits)
          ListTile(
            title: Text('${commit['subject']}'),
            subtitle: Text('${commit['short']} · ${commit['author']}'),
            onTap: () => guarded(context, () async {
              final d = await widget.controller.gateway.request(
                '${sessionPath(widget.controller.sessionId!)}/git/commits/${enc('${commit['sha']}')}',
              );
              if (mounted) setState(() => detail = d);
            }),
          ),
        if (error != null) Text(error!),
        if (more)
          TextButton(
            onPressed: busy ? null : load,
            child: Text(busy ? '載入中…' : '載入更多'),
          ),
      ],
    ],
  );
}

class DocumentPane extends StatefulWidget {
  const DocumentPane({
    super.key,
    required this.controller,
    required this.messageId,
    required this.initial,
    required this.title,
  });
  final LiveController controller;
  final String messageId, initial, title;
  @override
  State<DocumentPane> createState() => _DocumentPaneState();
}

class _DocumentPaneState extends State<DocumentPane> {
  late final reading = widget.controller.readers.putIfAbsent(
    '${widget.controller.sessionId}:${widget.messageId}',
    () => ReadingState(widget.initial),
  );
  List<String> get versions => reading.versions;
  int get selected => reading.selected;
  set selected(int value) => reading.selected = value;
  Map<int, double> get offsets => reading.offsets;
  late final scroll = ScrollController(
    initialScrollOffset: offsets[selected] ?? 0,
  );
  @override
  void initState() {
    super.initState();
    widget.controller.addListener(update);
    scroll.addListener(saveOffset);
    update();
  }

  void update() {
    final message = widget.controller.messages
        .where((m) => m['id'] == widget.messageId)
        .firstOrNull;
    if (message != null &&
        message['partial'] != true &&
        message['content'] != versions.last &&
        '${message['content']}'.isNotEmpty) {
      if (mounted) setState(() => versions.add('${message['content']}'));
    }
  }

  void saveOffset() {
    if (scroll.hasClients) offsets[selected] = scroll.offset;
  }

  void select(int v) {
    offsets[selected] = scroll.hasClients ? scroll.offset : 0;
    setState(() => selected = v);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (scroll.hasClients) {
        scroll.jumpTo(
          (offsets[v] ?? 0).clamp(0, scroll.position.maxScrollExtent),
        );
      }
    });
  }

  @override
  void dispose() {
    if (scroll.hasClients) offsets[selected] = scroll.offset;
    widget.controller.removeListener(update);
    scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Column(
    children: [
      Row(
        children: [
          Expanded(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                '${versions[selected].split('\n').first.replaceFirst(RegExp(r'^#+\s*'), '').trim()} · v${selected + 1}',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
          IconButton(
            tooltip: '分享',
            icon: const Icon(LucideIcons.share2, size: 18),
            onPressed: () => guarded(context, () async {
              await widget.controller.gateway.call('share', {
                'text': versions[selected],
              });
            }),
          ),
          PopupMenuButton<int>(
            tooltip: '閱讀版本',
            onSelected: select,
            itemBuilder: (_) => [
              for (var i = 0; i < versions.length; i++)
                PopupMenuItem(value: i, child: Text('v${i + 1}')),
            ],
          ),
          IconButton(
            tooltip: '複製',
            onPressed: () =>
                Clipboard.setData(ClipboardData(text: versions[selected])),
            icon: const Icon(LucideIcons.copy),
          ),
        ],
      ),
      if (selected < versions.length - 1)
        TextButton(
          onPressed: () => select(versions.length - 1),
          child: Text('已有 v${versions.length} · 切換新版'),
        ),
      if (widget.controller.messages.any(
        (m) => m['id'] == widget.messageId && m['partial'] == true,
      ))
        const Padding(
          padding: EdgeInsets.all(8),
          child: Text('仍在生成 · 保留目前閱讀內容，完成後可切換新版'),
        ),
      if (widget.controller.messages.any(
        (m) => m['id'] == widget.messageId && m['error'] != null,
      ))
        const Padding(
          padding: EdgeInsets.all(8),
          child: Text('生成遇到問題 · 目前顯示最後可讀內容'),
        ),
      Expanded(
        child: ListView(
          key: const Key('live-reader'),
          controller: scroll,
          padding: const EdgeInsets.all(24),
          children: [
            RichTextBody(
              versions[selected],
              reader: true,
              gateway: widget.controller.gateway,
            ),
          ],
        ),
      ),
    ],
  );
}

class TerminalPage extends StatefulWidget {
  const TerminalPage({
    super.key,
    required this.controller,
    required this.terminal,
  });
  final LiveController controller;
  final Json terminal;
  @override
  State<TerminalPage> createState() => _TerminalPageState();
}

class _TerminalPageState extends State<TerminalPage>
    with WidgetsBindingObserver {
  final terminal = Terminal(maxLines: 5000);
  final viewController = TerminalController();
  final tag = 'terminal-${DateTime.now().microsecondsSinceEpoch}';
  StreamSubscription<Json>? events;
  Timer? retry;
  String? notice = '連線中…';
  bool exited = false, visible = true;
  int attempts = 0;
  double fontSize = 13;
  bool ctrl = false, alt = false;
  LiveController get c => widget.controller;
  late final String session = c.sessionId!;
  void controlChanged() {
    if (mounted) setState(() {});
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    c.addListener(controlChanged);
    events = c.gateway.events.listen(frame);
    terminal.onOutput = (text) {
      var output = text;
      if (ctrl && text.length == 1) {
        final code = text.toUpperCase().codeUnitAt(0);
        if (code >= 64 && code <= 95) output = String.fromCharCode(code & 31);
      }
      if (alt) output = '\x1b$output';
      if (ctrl || alt) {
        setState(() {
          ctrl = false;
          alt = false;
        });
      }
      send({'type': 'input', 'data': output});
    };
    terminal.onResize = (w, h, pw, ph) =>
        send({'type': 'resize', 'cols': w, 'rows': h});
    connect();
  }

  Future<void> connect() async {
    try {
      await c.gateway.call('socketOpen', {
        'tag': tag,
        'path':
            '${sessionPath(session)}/terminals/${enc('${widget.terminal['id']}')}/stream',
      });
    } catch (e) {
      if (mounted) setState(() => notice = LiveController.describe(e));
    }
  }

  void frame(Json e) {
    final d = obj(e['data']);
    if (d['tag'] != tag) return;
    if (e['type'] == 'socketClosed') {
      if (!mounted) return;
      setState(
        () => notice = [401, 403, 404, 4401, 4403, 4404].contains(d['code'])
            ? '無法存取終端，請返回對話檢查連線與權限'
            : '連線中斷，重新連線中…',
      );
      if (visible &&
          !exited &&
          ![401, 403, 404, 4401, 4403, 4404].contains(d['code'])) {
        retry?.cancel();
        retry = Timer(
          Duration(milliseconds: 500 * (1 << attempts.clamp(0, 4))),
          connect,
        );
        attempts++;
      }
      return;
    }
    if (e['type'] != 'socket') return;
    final f = obj(d['frame']);
    switch (f['type']) {
      case 'ready':
        attempts = 0;
        terminal.write('\x1b[3J\x1b[2J\x1b[H${f['replay'] ?? ''}');
        notice = null;
        send({
          'type': 'resize',
          'cols': terminal.viewWidth,
          'rows': terminal.viewHeight,
        });
      case 'output':
        terminal.write('${f['data'] ?? ''}');
      case 'exit':
        exited = true;
        notice = '程序已結束：${f['exitCode'] ?? ''}';
      case 'error':
        notice = '${f['message']}';
    }
    if (mounted) setState(() {});
  }

  Future<void> send(Json data) async {
    if (exited || c.sessionId != session || c.control['held'] != true) return;
    try {
      await c.gateway.call('socketSend', {
        'tag': tag,
        'data': {
          ...data,
          'clientId': c.clientId,
          'generation': c.control['generation'],
        },
      });
    } catch (e) {
      if (mounted) setState(() => notice = LiveController.describe(e));
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    visible = state == AppLifecycleState.resumed;
    if (visible) {
      connect();
    } else {
      retry?.cancel();
      c.gateway.call('socketClose', {'tag': tag});
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    c.removeListener(controlChanged);
    events?.cancel();
    retry?.cancel();
    c.gateway.call('socketClose', {'tag': tag});
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Theme(
    data: Theme.of(context).copyWith(
      brightness: Brightness.dark,
      colorScheme: ColorScheme.dark(
        primary: palette(context)['terminal.blue'],
        surface: palette(context)['terminal.bg'],
        onSurface: palette(context)['terminal.text'],
      ),
      scaffoldBackgroundColor: palette(context)['terminal.bg'],
      appBarTheme: AppBarTheme(
        backgroundColor: palette(context)['terminal.bg'],
        foregroundColor: palette(context)['terminal.text'],
        surfaceTintColor: Colors.transparent,
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: palette(context)['terminal.key.text'],
          backgroundColor: palette(context)['terminal.key'],
        ),
      ),
    ),
    child: Scaffold(
      backgroundColor: palette(context)['terminal.bg'],
      appBar: AppBar(
        title: Text('${widget.terminal['title'] ?? '終端'}'),
        actions: [
          PopupMenuButton<String>(
            tooltip: '終端選項',
            onSelected: (action) => guarded(context, () async {
              if (action == 'larger') {
                setState(() => fontSize = (fontSize + 1).clamp(10, 24));
              }
              if (action == 'smaller') {
                setState(() => fontSize = (fontSize - 1).clamp(10, 24));
              }
              if (action == 'clear') terminal.write('\x1b[3J\x1b[2J\x1b[H');
              if (action == 'close' &&
                  await confirm(context, '結束終端', '此終端中的程序將被停止。')) {
                await c.takeControl();
                if (c.control['held'] != true) throw StateError('請先取得控制權');
                await c.gateway.request(
                  '${sessionPath(session)}/terminals/${enc('${widget.terminal['id']}')}/close',
                  method: 'POST',
                  body: {
                    'clientId': c.clientId,
                    'generation': c.control['generation'],
                  },
                );
                if (context.mounted) Navigator.pop(context);
              }
            }),
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'larger', child: Text('放大字體')),
              PopupMenuItem(value: 'smaller', child: Text('縮小字體')),
              PopupMenuItem(value: 'clear', child: Text('清除本機畫面')),
              PopupMenuItem(value: 'close', child: Text('結束終端…')),
            ],
          ),
          IconButton(
            tooltip: '貼上',
            onPressed: () async {
              final value = await Clipboard.getData('text/plain');
              if (value?.text != null) terminal.paste(value!.text!);
            },
            icon: const Icon(LucideIcons.clipboardPaste),
          ),
          IconButton(
            tooltip: '複製選取內容',
            onPressed: () {
              final selection = viewController.selection;
              if (selection != null) {
                Clipboard.setData(
                  ClipboardData(text: terminal.buffer.getText(selection)),
                );
              }
            },
            icon: const Icon(LucideIcons.copy),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            if (notice != null) Text(notice!),
            if (c.control['held'] != true)
              TextButton(
                onPressed: () => guarded(context, () async {
                  if (await confirm(context, '取得控制權', '取得控制權後才能操作此終端。')) {
                    await c.takeControl(force: true);
                    if (mounted) setState(() {});
                  }
                }),
                child: const Text('目前唯讀 · 取得控制權'),
              ),
            Expanded(
              child: TerminalView(
                terminal,
                controller: viewController,
                readOnly: c.control['held'] != true,
                autofocus: true,
                textStyle: TerminalStyle(fontSize: fontSize),
                theme: TerminalTheme(
                  cursor: palette(context)['terminal.cursor'],
                  selection: palette(
                    context,
                  )['terminal.blue'].withValues(alpha: .3),
                  foreground: palette(context)['terminal.text'],
                  background: palette(context)['terminal.bg'],
                  black: palette(context)['terminal.bg'],
                  white: palette(context)['terminal.text'],
                  red: palette(context)['terminal.red'],
                  green: palette(context)['terminal.green'],
                  yellow: palette(context)['terminal.yellow'],
                  blue: palette(context)['terminal.blue'],
                  magenta: TerminalThemes.defaultTheme.magenta,
                  cyan: TerminalThemes.defaultTheme.cyan,
                  brightBlack: palette(context)['terminal.dim'],
                  brightWhite: palette(context)['terminal.text'],
                  brightRed: palette(context)['terminal.red'],
                  brightGreen: palette(context)['terminal.green'],
                  brightYellow: palette(context)['terminal.yellow'],
                  brightBlue: palette(context)['terminal.blue'],
                  brightMagenta: TerminalThemes.defaultTheme.brightMagenta,
                  brightCyan: TerminalThemes.defaultTheme.brightCyan,
                  searchHitBackground: palette(context)['terminal.yellow'],
                  searchHitBackgroundCurrent: palette(
                    context,
                  )['terminal.green'],
                  searchHitForeground: palette(context)['terminal.bg'],
                ),
              ),
            ),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  for (final modifier in ['Ctrl', 'Alt'])
                    TextButton(
                      onPressed: c.control['held'] != true
                          ? null
                          : () => setState(() {
                              if (modifier == 'Ctrl') {
                                ctrl = !ctrl;
                              } else {
                                alt = !alt;
                              }
                            }),
                      child: Text(
                        '$modifier${(modifier == 'Ctrl' ? ctrl : alt) ? ' ●' : ''}',
                      ),
                    ),
                  for (final key in <(String, String)>[
                    ('Esc', '\x1b'),
                    ('Tab', '\t'),
                    ('Ctrl+C', '\x03'),
                    ('Ctrl+D', '\x04'),
                    ('↑', '\x1b[A'),
                    ('↓', '\x1b[B'),
                    ('←', '\x1b[D'),
                    ('→', '\x1b[C'),
                    ('/', '/'),
                    ('-', '-'),
                    ('|', '|'),
                    ('~', '~'),
                  ])
                    TextButton(
                      onPressed: c.control['held'] != true
                          ? null
                          : () => guarded(
                              context,
                              () => send({'type': 'input', 'data': key.$2}),
                            ),
                      child: Text(key.$1),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

class BrowserPane extends StatefulWidget {
  const BrowserPane({super.key, required this.controller});
  final LiveController controller;
  @override
  State<BrowserPane> createState() => _BrowserPaneState();
}

class _BrowserPaneState extends State<BrowserPane> with WidgetsBindingObserver {
  final tag = 'browser-${DateTime.now().microsecondsSinceEpoch}';
  StreamSubscription<Json>? subscription;
  Json state = {};
  List<Json> log = [];
  final logImages = <int, Uint8List>{};
  Uint8List? image;
  String? error;
  int width = 1280, height = 800;
  Timer? retry;
  bool visible = true;
  final address = TextEditingController(), typing = TextEditingController();
  LiveController get c => widget.controller;
  late final String session = c.sessionId!;
  void controlChanged() {
    if (mounted) setState(() {});
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    c.addListener(controlChanged);
    subscription = c.gateway.events.listen(event);
    connect();
  }

  Future<void> connect() async {
    try {
      await c.gateway.call('socketOpen', {
        'tag': tag,
        'path': '${sessionPath(session)}/browser/stream',
      });
    } catch (e) {
      if (mounted) setState(() => error = LiveController.describe(e));
    }
  }

  void event(Json e) {
    final d = obj(e['data']);
    if (d['tag'] != tag || !mounted) return;
    if (e['type'] == 'socketClosed') {
      setState(() => error = '瀏覽器連線已中斷');
      if (visible && ![401, 403, 404, 4401, 4403, 4404].contains(d['code'])) {
        retry?.cancel();
        retry = Timer(const Duration(seconds: 2), connect);
      }
      return;
    }
    final f = obj(d['frame']);
    switch (f['type']) {
      case 'state':
        state = obj(f['state']);
        if (address.text.isEmpty) address.text = '${state['url'] ?? ''}';
        error = null;
      case 'frame':
        try {
          image = base64Decode('${f['data']}');
          width = (f['width'] as num?)?.toInt() ?? 1280;
          height = (f['height'] as num?)?.toInt() ?? 800;
        } catch (_) {
          error = '無法讀取畫面';
        }
      case 'log':
        log = rows(f['entries']);
      case 'log_entry':
        log = [
          ...log,
          obj(f['entry']),
        ].reversed.take(150).toList().reversed.toList();
      case 'log_image':
        if (f['data'] is String && f['index'] is num) {
          try {
            logImages[(f['index'] as num).toInt()] = base64Decode(f['data']);
          } catch (_) {
            error = '無法讀取操作截圖';
          }
        }
      case 'error':
        error = '${f['message']}';
    }
    setState(() {});
  }

  Future<void> send(Json data) async {
    if (c.sessionId != session) throw StateError('此對話已切換，請重新開啟瀏覽器');
    if (c.control['held'] != true) await c.takeControl();
    if (c.control['held'] != true) throw StateError('請先取得對話控制權');
    await c.gateway.call('socketSend', {
      'tag': tag,
      'data': {
        ...data,
        'clientId': c.clientId,
        'generation': c.control['generation'],
      },
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState value) {
    visible = value == AppLifecycleState.resumed;
    if (visible) {
      connect();
    } else {
      retry?.cancel();
      c.gateway.call('socketClose', {'tag': tag});
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    c.removeListener(controlChanged);
    subscription?.cancel();
    retry?.cancel();
    c.gateway.call('socketClose', {'tag': tag});
    address.dispose();
    typing.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListView(
    padding: const EdgeInsets.all(16),
    children: [
      const Text(
        '瀏覽器',
        style: TextStyle(fontSize: 22, fontWeight: FontWeight.w600),
      ),
      Text(
        state['active'] == true
            ? '${state['title'] ?? state['url']}'
            : 'Agent 尚未開啟瀏覽器',
      ),
      if (error != null)
        SupportingState(title: '瀏覽器連線需要重試', detail: error!, onRetry: connect),
      if (state['handoff'] != null)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Surface(child: Text('${state['handoff']}')),
        ),
      if (state['action'] != null)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Text('Agent：${state['action']}'),
        ),
      if (state['recording'] != null)
        Text(
          '● 錄影中',
          style: TextStyle(color: palette(context)['status.danger']),
        ),
      if (state['active'] != true)
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 24),
          child: SupportingState(
            title: '尚未開啟瀏覽器',
            detail: 'Agent 開啟網頁後，預覽與操作紀錄會出現在這裡。',
          ),
        ),
      Wrap(
        children: [
          TextButton(
            onPressed: state['active'] != true
                ? null
                : () => guarded(
                    context,
                    () => send({
                      'type': state['mode'] == 'user' ? 'release' : 'takeover',
                    }),
                  ),
            child: Text(state['mode'] == 'user' ? '歸還給 agent' : '接管'),
          ),
          for (final action in <(String, String)>[
            ('back', '上一頁'),
            ('forward', '下一頁'),
            ('reload', '重新整理'),
          ])
            TextButton(
              onPressed: state['mode'] == 'user'
                  ? () => guarded(context, () => send({'type': action.$1}))
                  : null,
              child: Text(action.$2),
            ),
          TextButton(
            onPressed: state['active'] != true
                ? null
                : () => guarded(
                    context,
                    () => send({
                      'type': 'record',
                      'action': state['recording'] == null ? 'start' : 'stop',
                    }),
                  ),
            child: Text(state['recording'] == null ? '開始錄影' : '停止錄影'),
          ),
        ],
      ),
      TextField(
        controller: address,
        decoration: InputDecoration(
          hintText: '網址',
          suffixIcon: IconButton(
            tooltip: '前往',
            onPressed: state['mode'] == 'user'
                ? () => guarded(
                    context,
                    () => send({'type': 'navigate', 'url': address.text}),
                  )
                : null,
            icon: const Icon(LucideIcons.arrowRight),
          ),
        ),
      ),
      if (rows(state['tabs']).isNotEmpty)
        Wrap(
          children: [
            for (final tab in rows(state['tabs']))
              TextButton(
                onPressed: () => guarded(
                  context,
                  () => send({'type': 'tab', 'index': tab['index']}),
                ),
                child: Text('${tab['title'] ?? tab['index']}'),
              ),
          ],
        ),
      if (image != null)
        LayoutBuilder(
          builder: (context, constraints) => GestureDetector(
            onTapUp: state['mode'] == 'user'
                ? (details) => guarded(context, () async {
                    final x =
                        (details.localPosition.dx /
                                constraints.maxWidth *
                                width)
                            .round();
                    final y =
                        (details.localPosition.dy /
                                constraints.maxWidth *
                                width)
                            .round();
                    for (final a in ['down', 'up']) {
                      await send({
                        'type': 'mouse',
                        'action': a,
                        'x': x,
                        'y': y,
                        'button': 'left',
                        'clickCount': 1,
                      });
                    }
                  })
                : null,
            onVerticalDragUpdate: state['mode'] == 'user'
                ? (d) => guarded(
                    context,
                    () => send({
                      'type': 'wheel',
                      'x': width ~/ 2,
                      'y': height ~/ 2,
                      'dx': 0,
                      'dy': -d.delta.dy * 3,
                    }),
                  )
                : null,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: Image.memory(
                image!,
                gaplessPlayback: true,
                fit: BoxFit.fitWidth,
              ),
            ),
          ),
        ),
      if (state['mode'] == 'user')
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: typing,
                decoration: const InputDecoration(hintText: '輸入到網頁'),
              ),
            ),
            IconButton(
              tooltip: '送出文字',
              onPressed: () => guarded(context, () async {
                await send({'type': 'text', 'text': typing.text});
                typing.clear();
              }),
              icon: const Icon(LucideIcons.send),
            ),
            IconButton(
              tooltip: 'Enter',
              onPressed: () =>
                  guarded(context, () => send({'type': 'key', 'key': 'Enter'})),
              icon: const Icon(LucideIcons.cornerDownLeft),
            ),
          ],
        ),
      ExpansionTile(
        title: Text('操作紀錄 · ${log.length}'),
        children: [
          for (final entry in log.reversed)
            Column(
              children: [
                ListTile(
                  title: Text('${entry['actor']} · ${entry['action']}'),
                  subtitle: Text('${entry['url'] ?? ''}'),
                  trailing: entry['image'] == true
                      ? IconButton(
                          tooltip: '查看操作截圖',
                          icon: const Icon(LucideIcons.image, size: 18),
                          onPressed: () => guarded(
                            context,
                            () => send({
                              'type': 'log_image',
                              'index': entry['index'],
                            }),
                          ),
                        )
                      : null,
                ),
                if (logImages[entry['index']] != null)
                  Padding(
                    padding: const EdgeInsets.all(12),
                    child: Image.memory(logImages[entry['index']]!),
                  ),
              ],
            ),
        ],
      ),
    ],
  );
}
