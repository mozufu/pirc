import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import '../theme.dart';
import 'gateway.dart';
import 'common.dart';
import 'panels.dart';
import 'settings.dart';
import 'interaction.dart';
import 'permissions.dart';
import 'artifacts.dart';

class MobileApp extends StatelessWidget {
  const MobileApp({super.key, required this.theme, required this.controller});
  final PircTheme theme;
  final LiveController controller;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) => MaterialApp(
      title: 'pirc',
      themeMode: switch (controller.preferences['appearance']) {
        'light' => ThemeMode.light,
        'dark' => ThemeMode.dark,
        _ => ThemeMode.system,
      },
      debugShowCheckedModeBanner: false,
      theme: theme.build(Brightness.light),
      darkTheme: theme.build(Brightness.dark),
      home: LiveShell(controller: controller, theme: theme),
    ),
  );
}

class LiveShell extends StatefulWidget {
  const LiveShell({super.key, required this.controller, required this.theme});
  final LiveController controller;
  final PircTheme theme;
  @override
  State<LiveShell> createState() => _LiveShellState();
}

class _LiveShellState extends State<LiveShell> with WidgetsBindingObserver {
  LiveController get c => widget.controller;
  final scaffold = GlobalKey<ScaffoldState>();
  final paneKey = GlobalKey();
  final chatKey = GlobalKey();
  final panelCache = <String, Widget>{};
  final panelCounts = <String, int>{};
  final paneHistory = <Widget>[];
  String? highlightedMessage;
  String? readingMessage;
  Timer? highlightTimer;
  final chatScroll = ScrollController();
  final composer = TextEditingController();
  final search = TextEditingController();
  final homeComposer = TextEditingController();
  String? homeWorkspace;
  Json? homeModel;
  String homeThinking = 'medium';
  bool creating = false;
  Widget? pane;
  String? seenSession;
  String? panelKind;
  String seenContent = '';
  bool newContent = false;
  bool queue = false;
  bool _syncing = false;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    c.addListener(_update);
    composer.addListener(_typed);
    unawaited(c.boot());
  }

  void _typed() {
    if (!_syncing) c.editDraft(composer.text);
  }

  void _update() {
    if (!mounted) return;
    if (seenSession != c.sessionId) {
      pane = null;
      panelCounts.clear();
      panelCache.clear();
      paneHistory.clear();
      panelKind = null;
      seenSession = c.sessionId;
      seenContent = '';
      newContent = false;
    }
    if (composer.text != c.draft) {
      _syncing = true;
      composer.value = TextEditingValue(
        text: c.draft,
        selection: TextSelection.collapsed(offset: c.draft.length),
      );
      _syncing = false;
    }
    final last = c.messages.lastOrNull;
    final fingerprint =
        '${last?['id']}:${last?['content']}:${c.questions.length}';
    if (fingerprint != seenContent) {
      final bottom =
          !chatScroll.hasClients || chatScroll.position.extentAfter < 100;
      seenContent = fingerprint;
      if (bottom) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && chatScroll.hasClients) {
            chatScroll.jumpTo(chatScroll.position.maxScrollExtent);
          }
        });
      } else {
        newContent = true;
      }
    }
    if (c.notificationQuestion != null && c.sessionId != null) {
      final intent = c.notificationQuestion!;
      c.notificationQuestion = null;
      final q = rows(c.state['interactions'])
          .where(
            (q) => intent['interactionId'] == null
                ? q['status'] == 'pending'
                : q['id'] == intent['interactionId'],
          )
          .firstOrNull;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          showModalBottomSheet<void>(
            context: context,
            isScrollControlled: true,
            useSafeArea: true,
            builder: (_) => QuestionSheet(
              controller: c,
              question: q ?? {'id': intent['interactionId'], 'title': '確認通知狀態'},
              initialChoice: intent['answerChoice'] as String?,
            ),
          );
        }
      });
    }
    if (c.routePage != null && c.origin != null && c.onboardingComplete) {
      final route = c.routePage!;
      c.routePage = null;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _page(route);
      });
    }
    setState(() {});
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    unawaited(c.lifecycle(state == AppLifecycleState.resumed));
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    c.removeListener(_update);
    unawaited(c.flushDraft());
    c.dispose();
    highlightTimer?.cancel();
    composer.dispose();
    search.dispose();
    homeComposer.dispose();
    chatScroll.dispose();
    super.dispose();
  }

  void _page(String name) {
    if (name.startsWith('schedule:')) {
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) =>
              ScheduleDetailPage(controller: c, id: name.substring(9)),
        ),
      );
      return;
    }
    if (name == 'activity') {
      showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        builder: (_) => FractionallySizedBox(
          heightFactor: .85,
          child: Column(
            children: [
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 0, 16, 16),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    '待處理與動態',
                    style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
                  ),
                ),
              ),
              Expanded(
                child: ActivityPage(controller: c, theme: widget.theme),
              ),
            ],
          ),
        ),
      );
    } else {
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) =>
              ManagementPage(kind: name, controller: c, theme: widget.theme),
        ),
      );
    }
  }

  void _closePane() {
    setState(() {
      if (paneHistory.isNotEmpty) {
        pane = paneHistory.removeLast();
        return;
      }
      pane = null;
      if (readingMessage != null) {
        highlightedMessage = readingMessage;
        readingMessage = null;
        highlightTimer?.cancel();
        highlightTimer = Timer(const Duration(seconds: 1), () {
          if (mounted) setState(() => highlightedMessage = null);
        });
      }
    });
  }

  Future<void> _panelCounts() async {
    final id = c.sessionId;
    if (id == null) return;
    final values = await Future.wait([
      if (!c.chat)
        c.gateway
            .request('${sessionPath(id)}/git/status')
            .catchError((Object _) => <String, dynamic>{}),
      if (!c.chat)
        c.gateway
            .request('${sessionPath(id)}/terminals')
            .catchError((Object _) => <String, dynamic>{}),
      c.gateway
          .request('${sessionPath(id)}/panel/state')
          .catchError((Object _) => <String, dynamic>{}),
    ]);
    if (!mounted || c.sessionId != id) return;
    setState(() {
      for (final d in values) {
        if (d.containsKey('files')) {
          panelCounts['git'] = rows(d['files']).length;
        }
        if (d.containsKey('terminals')) {
          panelCounts['terminals'] = rows(d['terminals']).length;
        }
        if (d.containsKey('backgroundTasks')) {
          panelCounts['tasks'] = rows(d['backgroundTasks'])
              .where(
                (t) => t['status'] == 'running' || t['status'] == 'stopping',
              )
              .length;
        }
      }
    });
  }

  void _panel(String kind, {String? path}) {
    if (c.sessionId == null) return;
    unawaited(_panelCounts());
    setState(() {
      paneHistory.clear();
      readingMessage = null;
      panelKind = kind;
      if (path != null) panelCache.remove(kind);
      panelCache.putIfAbsent(
        kind,
        () => WorkPanel(
          key: GlobalKey(),
          controller: c,
          kind: kind,
          path: path,
          onOpen: (w) => setState(() {
            paneHistory.add(pane!);
            pane = w;
          }),
        ),
      );
      pane = IndexedStack(
        index: panelCache.keys.toList().indexOf(kind),
        children: panelCache.values.toList(),
      );
    });
  }

  void _document(Json message) {
    panelKind = null;
    paneHistory.clear();
    readingMessage = '${message['id']}';
    setState(
      () => pane = DocumentPane(
        controller: c,
        messageId: '${message['id']}',
        initial: '${message['content']}',
        title: '${message['content']}'
            .split('\n')
            .first
            .replaceFirst(RegExp(r'^#+\s*'), '')
            .trim(),
      ),
    );
  }

  Future<void> _chooseWorkspace({bool selectOnly = false}) async {
    final list = c.workspaces.toList();
    await showModalBottomSheet<void>(
      context: context,
      useSafeArea: true,
      isScrollControlled: true,
      builder: (sheet) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(sheet).height * .7,
          ),
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.all(16),
            children: [
              const Padding(
                padding: EdgeInsets.all(12),
                child: Text(
                  '在哪裡開始',
                  style: TextStyle(fontSize: 22, fontWeight: FontWeight.w600),
                ),
              ),
              if (list.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(16),
                  child: Text('目前沒有可用的工作空間，請先啟動對應 node 或在設定加入工作空間。'),
                ),
              for (final w in list)
                ListTile(
                  leading: Icon(
                    w['kind'] == 'chat'
                        ? LucideIcons.messageCircle
                        : LucideIcons.folder,
                  ),
                  title: Text('${w['displayName']}'),
                  subtitle: Text('${w['path'] ?? w['kind'] ?? ''}'),
                  onTap: () {
                    Navigator.pop(sheet);
                    if (selectOnly) {
                      setState(() {
                        homeWorkspace = '${w['id']}';
                        c.mode = w['kind'] == 'chat' ? 'chat' : 'work';
                      });
                    } else {
                      guarded(context, () => c.create('${w['id']}'));
                    }
                  },
                ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (c.booting) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (!c.onboardingComplete) {
      return PermissionPage(
        gateway: c.gateway,
        onComplete: () async {
          c.onboardingComplete = true;
          c.changed();
        },
      );
    }
    if (c.origin == null || c.pairLink != null) {
      return PairingScreen(
        controller: c,
        onCancel: c.origin == null
            ? null
            : () {
                c.pairLink = null;
                c.changed();
              },
      );
    }
    return LayoutBuilder(
      builder: (context, size) {
        final wide = size.maxWidth >= 600;
        return PopScope(
          canPop: pane == null && !c.fromNotification,
          onPopInvokedWithResult: (didPop, result) {
            if (!didPop) {
              if (pane != null) {
                _closePane();
              } else if (c.fromNotification) {
                c.fromNotification = false;
                c.mode = 'work';
                scaffold.currentState?.openDrawer();
              }
            }
          },
          child: Scaffold(
            key: scaffold,
            drawer: Drawer(width: 318, child: SafeArea(child: _sidebar())),
            body: SafeArea(
              top: true,
              child: Column(
                children: [
                  if (c.error != null ||
                      (c.sessionId != null && c.connection != 'live'))
                    Material(
                      color: palette(context)['status.warningSoft'],
                      child: ListTile(
                        dense: true,
                        title: Text(
                          c.error ??
                              (c.connection == 'connecting'
                                  ? '連線中…'
                                  : '重新連線中，顯示的可能不是最新狀態'),
                        ),
                        trailing: IconButton(
                          tooltip: '重試',
                          icon: const Icon(LucideIcons.refreshCw),
                          onPressed: () => guarded(context, () async {
                            await c.refreshList();
                            if (c.sessionId != null) {
                              await c.gateway.call('watch', {
                                'sessionId': c.sessionId,
                              });
                            }
                          }),
                        ),
                      ),
                    ),
                  Expanded(
                    child: Stack(
                      children: [
                        Row(
                          children: [
                            if (wide && pane == null)
                              SizedBox(width: 280, child: _sidebar()),
                            Expanded(
                              child: Column(
                                key: chatKey,
                                children: [
                                  _header(),
                                  Expanded(child: _chat()),
                                ],
                              ),
                            ),
                            if (wide && pane != null)
                              SizedBox(
                                width: size.maxWidth >= 840
                                    ? size.maxWidth - 480
                                    : size.maxWidth / 2,
                                child: _pane(),
                              ),
                          ],
                        ),
                        if (!wide && pane != null)
                          Positioned.fill(child: _pane()),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  PreferredSizeWidget _header() => AppBar(
    primary: false,
    leading: IconButton(
      tooltip: '側欄',
      onPressed: () => scaffold.currentState!.openDrawer(),
      icon: const Icon(LucideIcons.menu),
    ),
    title: InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: c.sessionId == null
          ? () => _chooseWorkspace(selectOnly: true)
          : () => _sessionMenu(),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            c.sessionId == null
                ? '${_homeTarget?['displayName'] ?? '選擇工作空間'}'
                : c.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontSize: 15,
              height: 20 / 15,
              fontWeight: FontWeight.w600,
            ),
          ),
          if (MediaQuery.textScalerOf(context).scale(16) <= 22)
            Text(
              c.sessionId == null
                  ? (c.mode == 'chat' ? '一般對話' : '新工作')
                  : _sessionSubtitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12,
                height: 16 / 12,
                color: palette(context)['text.muted'],
              ),
            ),
        ],
      ),
    ),
    actions: [
      IconButton(
        tooltip: '待處理與動態',
        onPressed: () => _page('activity'),
        icon: Badge(
          isLabelVisible: c.sessions.any(
            (s) => s['runStatus'] == 'waiting_input',
          ),
          child: const Icon(LucideIcons.bell),
        ),
      ),
      IconButton(
        tooltip: c.sessionId == null ? '新對話' : '工作面板',
        onPressed: c.sessionId == null
            ? () => setState(homeComposer.clear)
            : () => _panel(c.chat ? 'files' : 'git'),
        icon: Icon(
          c.sessionId == null ? LucideIcons.squarePen : LucideIcons.panelRight,
        ),
      ),
    ],
  );

  Widget _pane() => Material(
    key: paneKey,
    color: palette(context)['surface.page'],
    child: Column(
      children: [
        SizedBox(
          height: 56,
          child: Row(
            children: [
              IconButton(
                tooltip: paneHistory.isEmpty ? '返回對話' : '返回工作面板',
                onPressed: _closePane,
                icon: const Icon(LucideIcons.arrowLeft, size: 22),
              ),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      panelKind == null ? '閱讀內容' : '工作面板',
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    if (MediaQuery.textScalerOf(context).scale(16) <= 22)
                      Text(
                        c.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12,
                          color: palette(context)['text.muted'],
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(width: 48),
            ],
          ),
        ),
        if (panelKind != null && paneHistory.isEmpty)
          Row(
            children: [
              for (final tab in [
                ('files', '檔案', LucideIcons.folder),
                if (!c.chat) ('git', 'Git', LucideIcons.gitBranch),
                if (!c.chat) ('terminals', '終端', LucideIcons.terminal),
                ('tasks', 'Tasks', LucideIcons.listTodo),
                ('memory', '記憶', LucideIcons.bookOpen),
                ('browser', '瀏覽器', LucideIcons.globe),
              ])
                Expanded(
                  child: InkWell(
                    onTap: () => _panel(tab.$1),
                    child: Container(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      decoration: BoxDecoration(
                        color: panelKind == tab.$1
                            ? palette(context)['surface.subtle']
                            : Colors.transparent,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Column(
                        children: [
                          Badge(
                            isLabelVisible: (panelCounts[tab.$1] ?? 0) > 0,
                            label: Text('${panelCounts[tab.$1] ?? 0}'),
                            child: Icon(
                              tab.$3,
                              size: 18,
                              color:
                                  palette(context)[panelKind == tab.$1
                                      ? 'text.primary'
                                      : 'text.muted'],
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            tab.$2,
                            style: TextStyle(
                              fontSize: 12.5,
                              color:
                                  palette(context)[panelKind == tab.$1
                                      ? 'text.primary'
                                      : 'text.muted'],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
            ],
          ),
        Expanded(child: pane!),
      ],
    ),
  );
  Widget _sidebar() {
    final ids = c.workspaces
        .where(
          (w) => c.mode == 'chat' ? w['kind'] == 'chat' : w['kind'] != 'chat',
        )
        .map((w) => w['id'])
        .toSet();
    final list = c.sessions
        .where(
          (s) =>
              ids.contains(s['workspaceId']) &&
              (c.workspaceFilter == null ||
                  s['workspaceId'] == c.workspaceFilter) &&
              '${s['name']}'.toLowerCase().contains(search.text.toLowerCase()),
        )
        .toList();
    list.sort((a, b) {
      final ap = a['pinnedAt'] != null, bp = b['pinnedAt'] != null;
      if (ap != bp) return ap ? -1 : 1;
      return ((b['updatedAt'] as num?) ?? 0).compareTo(
        (a['updatedAt'] as num?) ?? 0,
      );
    });
    return Material(
      color: palette(context)['surface.sidebar'],
      child: Column(
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(24, 20, 24, 12),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                'pirc',
                style: TextStyle(fontSize: 26, fontWeight: FontWeight.w600),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Material(
              color: palette(context)['fill.hover'],
              borderRadius: BorderRadius.circular(12),
              child: Padding(
                padding: const EdgeInsets.all(3),
                child: Row(
                  children: [
                    for (final mode in [('chat', '聊天'), ('work', '工作')])
                      Expanded(
                        child: Material(
                          color: c.mode == mode.$1
                              ? palette(context)['surface.layer']
                              : Colors.transparent,
                          borderRadius: BorderRadius.circular(9),
                          child: InkWell(
                            borderRadius: BorderRadius.circular(9),
                            onTap: () {
                              c.mode = mode.$1;
                              c.workspaceFilter = null;
                              c.changed();
                            },
                            child: Padding(
                              padding: const EdgeInsets.symmetric(vertical: 10),
                              child: Text(
                                mode.$2,
                                textAlign: TextAlign.center,
                                style: const TextStyle(fontSize: 14),
                              ),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
          ListTile(
            leading: const Icon(LucideIcons.squarePen),
            title: Text(c.mode == 'chat' ? '新聊天' : '新工作'),
            onTap: () {
              scaffold.currentState?.closeDrawer();
              guarded(context, c.home);
            },
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: TextField(
              controller: search,
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(
                hintText: '搜尋對話',
                prefixIcon: Icon(LucideIcons.search),
              ),
            ),
          ),
          if (c.mode == 'work')
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: DropdownButton<String>(
                isExpanded: true,
                value: c.workspaces.any((w) => w['id'] == c.workspaceFilter)
                    ? c.workspaceFilter!
                    : '',
                items: [
                  const DropdownMenuItem(value: '', child: Text('所有工作空間')),
                  for (final w in c.workspaces.where(
                    (w) => w['kind'] != 'chat',
                  ))
                    DropdownMenuItem(
                      value: '${w['id']}',
                      child: Text(
                        '${w['displayName']}',
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                ],
                onChanged: (v) {
                  c.workspaceFilter = v == '' ? null : v;
                  c.changed();
                },
              ),
            ),
          Expanded(
            child: RefreshIndicator(
              onRefresh: c.refreshList,
              child: ListView(
                children: [
                  if (list.isEmpty)
                    const Padding(
                      padding: EdgeInsets.all(24),
                      child: Text('還沒有對話'),
                    ),
                  for (final group in ['待你處理', '執行中', '最近']) ...[
                    if (list.any((s) => _group(s) == group))
                      Padding(
                        padding: const EdgeInsets.fromLTRB(24, 16, 24, 6),
                        child: Text(
                          group,
                          style: TextStyle(
                            fontSize: 12,
                            color: palette(context)['text.muted'],
                          ),
                        ),
                      ),
                    for (final s in list.where((s) => _group(s) == group))
                      ListTile(
                        selected: s['id'] == c.sessionId,
                        title: Text(
                          '${s['name']}',
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        leading: Icon(
                          s['pinnedAt'] != null
                              ? LucideIcons.pin
                              : LucideIcons.messageCircle,
                          size: 18,
                        ),
                        subtitle: s['settledAt'] != null
                            ? const Text('已完成')
                            : null,
                        onTap: () {
                          scaffold.currentState?.closeDrawer();
                          guarded(context, () => c.open('${s['id']}'));
                        },
                        onLongPress: () => showModalBottomSheet<void>(
                          context: context,
                          useSafeArea: true,
                          builder: (sheet) => Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              for (final item in [
                                ('rename', '重新命名'),
                                ('pin', s['pinnedAt'] == null ? '釘選' : '取消釘選'),
                                (
                                  'settle',
                                  s['settledAt'] == null ? '標記完成' : '重新開啟',
                                ),
                              ])
                                ListTile(
                                  title: Text(item.$2),
                                  onTap: () {
                                    Navigator.pop(sheet);
                                    guarded(context, () async {
                                      Json patch = {};
                                      if (item.$1 == 'rename') {
                                        final name = await input(
                                          context,
                                          '重新命名',
                                          value: '${s['name']}',
                                        );
                                        if (name == null ||
                                            name.trim().isEmpty) {
                                          return;
                                        }
                                        patch = {'name': name.trim()};
                                      } else if (item.$1 == 'pin') {
                                        patch = {
                                          'pinned': s['pinnedAt'] == null,
                                        };
                                      } else {
                                        patch = {
                                          'settled': s['settledAt'] == null,
                                        };
                                      }
                                      await c.updateSession(
                                        patch,
                                        targetId: '${s['id']}',
                                      );
                                    });
                                  },
                                ),
                            ],
                          ),
                        ),
                      ),
                  ],
                ],
              ),
            ),
          ),
          const Divider(height: 1),
          ListTile(
            leading: const Icon(LucideIcons.calendarClock),
            title: const Text('排程'),
            onTap: () {
              scaffold.currentState?.closeDrawer();
              _page('schedules');
            },
          ),
          ListTile(
            leading: const Icon(LucideIcons.settings2),
            title: const Text('設定'),
            subtitle: Text(
              c.origin ?? '',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            onTap: () {
              scaffold.currentState?.closeDrawer();
              _page('settings');
            },
          ),
        ],
      ),
    );
  }

  String _group(Json s) => s['runStatus'] == 'waiting_input'
      ? '待你處理'
      : ['running', 'queued', 'stopping'].contains(s['runStatus'])
      ? '執行中'
      : '最近';
  Json? get _homeTarget =>
      c.workspaces
          .where(
            (w) =>
                w['id'] == homeWorkspace &&
                (c.mode == 'chat' ? w['kind'] == 'chat' : w['kind'] != 'chat'),
          )
          .firstOrNull ??
      c.workspaces
          .where(
            (w) => c.mode == 'chat' ? w['kind'] == 'chat' : w['kind'] != 'chat',
          )
          .firstOrNull;

  String get _sessionSubtitle {
    final w = c.workspaces
        .where((w) => w['id'] == obj(c.state['session'])['workspaceId'])
        .firstOrNull;
    final status = c.questions.isNotEmpty
        ? '等待你回答'
        : c.running
        ? '執行中'
        : '已連線';
    return '${w?['displayName'] ?? ''} · $status';
  }

  void _sessionMenu() => showModalBottomSheet<void>(
    context: context,
    builder: (sheet) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final entry in {
            'rename': '重新命名',
            'pin': obj(c.state['session'])['pinnedAt'] == null ? '釘選' : '取消釘選',
            'settle': obj(c.state['session'])['settledAt'] == null
                ? '標記完成'
                : '重新開啟',
          }.entries)
            ListTile(
              title: Text(entry.value),
              onTap: () {
                Navigator.pop(sheet);
                _sessionAction(entry.key);
              },
            ),
        ],
      ),
    ),
  );

  Widget _workspaceChip(String label, IconData icon, VoidCallback onTap) =>
      Padding(
        padding: const EdgeInsets.only(right: 6),
        child: TextButton.icon(
          onPressed: onTap,
          icon: Icon(icon, size: 14),
          label: Text(label),
          style: TextButton.styleFrom(
            backgroundColor: palette(context)['surface.subtle'],
            foregroundColor: palette(context)['text.primary'],
            textStyle: Theme.of(
              context,
            ).textTheme.labelLarge?.copyWith(fontSize: 12),
            minimumSize: const Size(48, 32),
            padding: const EdgeInsets.symmetric(horizontal: 12),
          ),
        ),
      );

  Future<void> _startHome({bool attach = false}) async {
    if (creating) return;
    if (_homeTarget == null) {
      await _chooseWorkspace(selectOnly: true);
      if (_homeTarget == null) return;
    }
    setState(() => creating = true);
    final text = homeComposer.text;
    try {
      await c.create('${_homeTarget!['id']}');
      final id = c.sessionId;
      c.editDraft(text);
      await c.flushDraft();
      homeComposer.clear();
      // Wait for the real snapshot/lease; never mark the connection live locally.
      final ready = Completer<void>();
      void check() {
        if ((c.canWrite || c.sessionId != id) && !ready.isCompleted) {
          ready.complete();
        }
      }

      c.addListener(check);
      check();
      try {
        await ready.future.timeout(const Duration(seconds: 15));
      } finally {
        c.removeListener(check);
      }
      if (c.sessionId != id) return;
      if (homeModel != null) {
        if (!await c.sendCommand({
          'type': 'set_model',
          'provider': homeModel!['provider'],
          'modelId': homeModel!['id'],
        })) {
          return;
        }
        if (homeModel!['reasoning'] == true &&
            !await c.sendCommand({
              'type': 'set_thinking',
              'level': homeThinking,
            })) {
          return;
        }
      }
      if (attach) {
        await c.attach();
      } else {
        await c.send('prompt');
      }
    } on TimeoutException {
      if (mounted) showNotice(context, '對話已建立，訊息保留在輸入框。連線恢復後可送出。');
    } catch (e) {
      if (mounted) showNotice(context, LiveController.describe(e));
    } finally {
      if (mounted) setState(() => creating = false);
    }
  }

  Widget _home() {
    final recent = [...c.sessions]
      ..sort(
        (a, b) => ((b['updatedAt'] as num?) ?? 0).compareTo(
          (a['updatedAt'] as num?) ?? 0,
        ),
      );
    final pending = c.sessions
        .where((s) => s['runStatus'] == 'waiting_input')
        .length;
    return Column(
      children: [
        Expanded(
          child: RefreshIndicator(
            onRefresh: c.refreshList,
            child: ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 64, 24, 20),
                  child: Column(
                    children: [
                      Container(
                        width: 44,
                        height: 44,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: palette(context)['accent.default'],
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Text(
                          'π',
                          style: TextStyle(
                            color: palette(context)['accent.on'],
                            fontFamily: 'monospace',
                            fontSize: 20,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      const SizedBox(height: 14),
                      const Text(
                        '今天想處理什麼？',
                        style: TextStyle(
                          fontSize: 24,
                          height: 32 / 24,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
                if (pending > 0)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Material(
                      color: palette(context)['status.warningSoft'],
                      borderRadius: BorderRadius.circular(16),
                      child: ListTile(
                        leading: Icon(
                          LucideIcons.clock,
                          size: 20,
                          color: palette(context)['text.warning'],
                        ),
                        title: Text(
                          '$pending 個對話待你處理',
                          style: const TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        trailing: const Icon(
                          LucideIcons.chevronRight,
                          size: 18,
                        ),
                        onTap: () => _page('activity'),
                      ),
                    ),
                  ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 24, 16, 6),
                  child: Text(
                    '最近',
                    style: TextStyle(
                      fontSize: 12.5,
                      color: palette(context)['text.muted'],
                    ),
                  ),
                ),
                if (recent.isEmpty)
                  const Padding(
                    padding: EdgeInsets.all(16),
                    child: Text('還沒有對話，從下方開始。'),
                  ),
                for (final item in recent.take(8))
                  ListTile(
                    contentPadding: const EdgeInsets.symmetric(horizontal: 16),
                    title: Text(
                      '${item['name']}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text(
                      '${c.workspaces.where((w) => w['id'] == item['workspaceId']).firstOrNull?['displayName'] ?? ''} · ${_group(item)}',
                    ),
                    onTap: creating
                        ? null
                        : () => guarded(context, () => c.open('${item['id']}')),
                  ),
              ],
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
          child: Container(
            padding: const EdgeInsets.fromLTRB(16, 4, 8, 6),
            decoration: BoxDecoration(
              color: palette(context)['surface.input'],
              borderRadius: BorderRadius.circular(28),
              boxShadow: pircShadow(context),
            ),
            child: Column(
              children: [
                TextField(
                  key: const Key('home-draft'),
                  controller: homeComposer,
                  enabled: !creating,
                  minLines: 1,
                  maxLines: 5,
                  onChanged: (_) => setState(() {}),
                  decoration: const InputDecoration(
                    hintText: '問點什麼…',
                    contentPadding: EdgeInsets.symmetric(vertical: 12),
                  ),
                ),
                Row(
                  children: [
                    IconButton(
                      tooltip: '加入附件',
                      onPressed: creating
                          ? null
                          : () => _startHome(attach: true),
                      icon: const Icon(LucideIcons.plus),
                    ),
                    Expanded(
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: TextButton(
                          onPressed: creating
                              ? null
                              : () => guarded(
                                  context,
                                  () => _modelSheet(forHome: true),
                                ),
                          style: TextButton.styleFrom(
                            backgroundColor: palette(context)['surface.subtle'],
                            foregroundColor: palette(context)['text.primary'],
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Flexible(
                                child: Text(
                                  '${homeModel?['name'] ?? homeModel?['id'] ?? '預設模型'}',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              const SizedBox(width: 4),
                              const Icon(LucideIcons.chevronDown, size: 12),
                            ],
                          ),
                        ),
                      ),
                    ),
                    IconButton.filled(
                      tooltip: '開始對話',
                      style: IconButton.styleFrom(
                        backgroundColor: palette(context)['action.primary'],
                        foregroundColor: palette(context)['action.onPrimary'],
                      ),
                      onPressed: creating || homeComposer.text.trim().isEmpty
                          ? null
                          : () => _startHome(),
                      icon: const Icon(LucideIcons.arrowUp, size: 20),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  void _keepBottomAfterLayout() {
    if (!chatScroll.hasClients || chatScroll.position.extentAfter >= 100) {
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && chatScroll.hasClients) {
        chatScroll.jumpTo(chatScroll.position.maxScrollExtent);
      }
    });
  }

  Widget _chat() {
    if (c.sessionId == null) return _home();
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                if (!c.chat)
                  _workspaceChip(
                    'Git',
                    LucideIcons.gitBranch,
                    () => _panel('git'),
                  ),
                if (!c.chat)
                  _workspaceChip(
                    '終端',
                    LucideIcons.terminal,
                    () => _panel('terminals'),
                  ),
                _workspaceChip('檔案', LucideIcons.folder, () => _panel('files')),
              ],
            ),
          ),
        ),
        Expanded(
          child: Stack(
            children: [
              ListView(
                controller: chatScroll,
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 16,
                ),
                children: [
                  for (final message in c.messages)
                    Align(
                      alignment: message['role'] == 'user'
                          ? Alignment.centerRight
                          : Alignment.centerLeft,
                      child: ConstrainedBox(
                        constraints: BoxConstraints(
                          maxWidth: message['role'] == 'user'
                              ? (MediaQuery.sizeOf(context).width * .82).clamp(
                                  0,
                                  560,
                                )
                              : 680,
                        ),
                        child: Padding(
                          padding: const EdgeInsets.only(bottom: 24),
                          child: _message(message),
                        ),
                      ),
                    ),
                  for (final q in c.questions)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 16),
                      child: Container(
                        decoration: BoxDecoration(
                          color: palette(context)['surface.layer'],
                          borderRadius: BorderRadius.circular(16),
                          boxShadow: pircShadow(context),
                        ),
                        child: Column(
                          children: [
                            QuestionSheet(
                              key: ValueKey(
                                '${c.sessionId}:${q['id']}:${q['epoch']}',
                              ),
                              controller: c,
                              question: q,
                              embedded: true,
                              onLayout: _keepBottomAfterLayout,
                            ),
                            TextButton.icon(
                              onPressed: () => guarded(context, () async {
                                final notice = await c.gateway.call('overlay', {
                                  'sessionId': c.sessionId,
                                  'interactionId': q['id'],
                                });
                                if (notice != null && mounted) {
                                  showNotice(context, '$notice');
                                }
                              }),
                              icon: const Icon(
                                LucideIcons.panelsTopLeft,
                                size: 16,
                              ),
                              label: const Text('快速回應浮窗'),
                            ),
                          ],
                        ),
                      ),
                    ),
                  if (c.state.isEmpty)
                    const Center(
                      child: Padding(
                        padding: EdgeInsets.all(32),
                        child: CircularProgressIndicator(),
                      ),
                    ),
                ],
              ),
              if (newContent)
                Align(
                  alignment: Alignment.bottomCenter,
                  child: FilledButton.tonal(
                    onPressed: () {
                      setState(() => newContent = false);
                      chatScroll.animateTo(
                        chatScroll.position.maxScrollExtent,
                        duration: const Duration(milliseconds: 200),
                        curve: Curves.easeOut,
                      );
                    },
                    child: Text(
                      c.questions.isNotEmpty ? '有問題等你回答 ↓' : '有新內容 ↓',
                    ),
                  ),
                ),
            ],
          ),
        ),
        _composer(),
      ],
    );
  }

  Widget _message(Json m) => AnimatedContainer(
    duration: const Duration(milliseconds: 180),
    padding: const EdgeInsets.all(2),
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(16),
      color: highlightedMessage == m['id']
          ? palette(context)['accent.soft']
          : Colors.transparent,
    ),
    child: _messageBody(m),
  );

  Widget _messageBody(Json m) {
    if (m['role'] == 'user') {
      return Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: palette(context)['surface.bubble'],
          borderRadius: BorderRadius.circular(20),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SelectableText(
              '${m['content']}',
              style: const TextStyle(fontSize: 16, height: 24 / 16),
            ),
            inlineImages(rows(m['images'])),
          ],
        ),
      );
    }
    final artifacts = messageArtifacts(m);
    final prose = artifacts.isEmpty
        ? '${m['content'] ?? ''}'
        : artifactProse(m);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final artifact in artifacts)
          ArtifactCard(
            artifact: artifact,
            onOpen: () {
              setState(() {
                panelKind = null;
                paneHistory.clear();
                readingMessage = artifact.messageId;
                pane = ArtifactPane(controller: c, initial: artifact);
              });
            },
          ),
        if ('${m['thinking'] ?? ''}'.isNotEmpty)
          ExpansionTile(
            tilePadding: EdgeInsets.zero,
            title: const Text('思考過程'),
            children: [SelectableText('${m['thinking']}')],
          ),
        if (prose.isNotEmpty && (prose.length < 1200 || artifacts.isNotEmpty))
          RichTextBody(
            prose,
            gateway: c.gateway,
            onFile: (path) => _panel('files', path: path),
          ),
        inlineImages(rows(m['images'])),
        if (rows(m['tools']).isNotEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Surface(
              padding: EdgeInsets.zero,
              child: ExpansionTile(
                key: PageStorageKey('run:${m['id']}'),
                title: Text('${rows(m['tools']).length} 個步驟'),
                subtitle: Text(
                  rows(m['tools']).any((t) => t['status'] == 'failed')
                      ? '${rows(m['tools']).where((t) => t['status'] == 'failed').length} 個失敗 · 展開查看輸出'
                      : rows(m['tools']).any((t) => t['status'] == 'running')
                      ? '執行中'
                      : '已完成',
                ),
                leading: Icon(
                  rows(m['tools']).any((t) => t['status'] == 'failed')
                      ? LucideIcons.circleAlert
                      : LucideIcons.listChecks,
                  size: 18,
                ),
                initiallyExpanded: rows(
                  m['tools'],
                ).any((t) => t['status'] == 'failed'),
                children: [
                  for (final t in rows(m['tools']))
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: Material(
                          color: palette(context)['surface.subtle'],
                          child: ExpansionTile(
                            key: PageStorageKey(t['id']),
                            initiallyExpanded: t['status'] == 'failed',
                            tilePadding: const EdgeInsets.symmetric(
                              horizontal: 12,
                            ),
                            childrenPadding: const EdgeInsets.all(12),
                            shape: const Border(),
                            collapsedShape: const Border(),
                            leading: Icon(
                              t['status'] == 'failed'
                                  ? LucideIcons.circleAlert
                                  : t['status'] == 'running'
                                  ? LucideIcons.loader
                                  : LucideIcons.check,
                              size: 18,
                            ),
                            title: Text('${t['title'] ?? t['name']}'),
                            subtitle: Text('${t['status']}'),
                            children: [
                              if (t['input'] != null)
                                SelectableText(
                                  '${t['input']}',
                                  style: const TextStyle(
                                    fontFamily: 'monospace',
                                  ),
                                ),
                              if (t['diff'] != null)
                                CodeDocument(text: '${t['diff']}', diff: true),
                              if (t['output'] != null)
                                RichTextBody(
                                  '${t['output']}',
                                  gateway: c.gateway,
                                  onFile: (path) => _panel('files', path: path),
                                ),
                              inlineImages(rows(t['images'])),
                              if (t['recording'] != null)
                                TextButton.icon(
                                  onPressed: () => guarded(
                                    context,
                                    () => c.gateway.call('recording', {
                                      'sessionId': c.sessionId,
                                      'path': t['recording'],
                                    }),
                                  ),
                                  icon: const Icon(LucideIcons.play),
                                  label: const Text('播放瀏覽器錄影'),
                                ),
                            ],
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        if (m['error'] != null)
          Text(
            '${m['error']}',
            style: TextStyle(color: palette(context)['status.danger']),
          ),
        if (artifacts.isEmpty && '${m['content'] ?? ''}'.isNotEmpty) ...[
          IconButton(
            tooltip: '複製',
            onPressed: () =>
                Clipboard.setData(ClipboardData(text: '${m['content']}')),
            icon: const Icon(LucideIcons.copy, size: 17),
          ),
          if ('${m['content']}'.length >= 240 ||
              '${m['content']}'.contains('\n|'))
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Material(
                color: palette(context)['surface.subtle'],
                borderRadius: BorderRadius.circular(16),
                child: InkWell(
                  borderRadius: BorderRadius.circular(16),
                  onTap: () => _document(m),
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Row(
                      children: [
                        Icon(
                          LucideIcons.fileText,
                          size: 22,
                          color: palette(context)['accent.default'],
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                '${m['content']}'
                                    .split('\n')
                                    .first
                                    .replaceFirst(RegExp(r'^#+\s*'), '')
                                    .trim(),
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontSize: 17,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              const SizedBox(height: 6),
                              const Text(
                                '開啟閱讀',
                                style: TextStyle(
                                  fontSize: 17,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                '${m['content']}'
                                    .replaceAll(RegExp(r'[#*`>]'), '')
                                    .trim(),
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 13,
                                  color: palette(context)['text.secondary'],
                                ),
                              ),
                            ],
                          ),
                        ),
                        const Icon(LucideIcons.chevronRight, size: 18),
                      ],
                    ),
                  ),
                ),
              ),
            )
          else
            TextButton.icon(
              onPressed: () => _document(m),
              icon: const Icon(LucideIcons.panelRightOpen, size: 17),
              label: const Text('開啟閱讀'),
            ),
        ],
      ],
    );
  }

  Widget _composer() {
    final widgets = obj(c.state['widgets']);
    final queued = rows(c.state['queue']);
    final keyboard = MediaQuery.viewInsetsOf(context).bottom > 0;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (widgets.isNotEmpty || queued.isNotEmpty)
            ConstrainedBox(
              constraints: BoxConstraints(maxHeight: keyboard ? 100 : 200),
              child: SingleChildScrollView(
                child: ExpansionTile(
                  dense: true,
                  initiallyExpanded: false,
                  title: Text('目標與工作進度 · ${queued.length} 則排隊'),
                  children: [
                    for (final e in widgets.entries)
                      Padding(
                        padding: const EdgeInsets.all(8),
                        child: Text(
                          e.value is List
                              ? (e.value as List).join('\n')
                              : '${e.value}',
                        ),
                      ),
                    Wrap(
                      children: [
                        TextButton(
                          onPressed: () => c.sendCommand({
                            'type': 'steer',
                            'message': '/goal pause',
                          }),
                          child: const Text('暫停目標'),
                        ),
                        TextButton(
                          onPressed: () => c.sendCommand({
                            'type': 'steer',
                            'message': '/goal resume',
                          }),
                          child: const Text('繼續目標'),
                        ),
                      ],
                    ),
                    for (final q in queued)
                      ListTile(
                        title: Text('${q['content']}'),
                        trailing: TextButton(
                          onPressed: c.canWrite
                              ? () => c.sendCommand({
                                  'type': 'send_now',
                                  'queue': q['kind'] == 'follow_up'
                                      ? 'followUp'
                                      : 'steering',
                                  'index': q['index'],
                                  'message': q['content'],
                                })
                              : null,
                          child: const Text('立即送出'),
                        ),
                      ),
                    if (queued.isNotEmpty)
                      TextButton(
                        onPressed: c.canWrite
                            ? () => c.sendCommand({'type': 'clear_queue'})
                            : null,
                        child: const Text('清除佇列'),
                      ),
                  ],
                ),
              ),
            ),
          if (c.control['held'] != true)
            Wrap(
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text(c.control['holder'] != null ? '由其他裝置控制中' : '正在確認控制權'),
                TextButton(
                  onPressed: () => guarded(context, () async {
                    final force = c.control['holder'] != null;
                    if (!force ||
                        await confirm(context, '取得控制權', '這會讓目前控制此對話的裝置變成唯讀。')) {
                      await c.takeControl(force: force);
                    }
                  }),
                  child: const Text('取得控制權'),
                ),
              ],
            ),
          if (c.actionError != null)
            Text(
              c.actionError!,
              style: TextStyle(color: palette(context)['text.warning']),
            ),
          if (c.unknownCommand)
            Wrap(
              children: [
                TextButton(
                  onPressed: () => guarded(context, c.refreshSession),
                  child: const Text('檢查最新狀態'),
                ),
                TextButton(
                  onPressed: () => guarded(context, () async {
                    await c.refreshSession();
                    if (!mounted) return;
                    if (await confirm(
                      context,
                      '已檢查對話，繼續操作？',
                      '請確認上一則訊息是否已送達。繼續會解除送出限制，不會重送上一個操作。',
                    )) {
                      await c.acknowledgeCommand();
                    }
                  }),
                  child: const Text('已檢查，繼續…'),
                ),
              ],
            ),
          Container(
            padding: const EdgeInsets.fromLTRB(16, 4, 8, 6),
            decoration: BoxDecoration(
              color: palette(context)['surface.input'],
              borderRadius: BorderRadius.circular(28),
              boxShadow: pircShadow(context),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  key: const Key('live-draft'),
                  controller: composer,
                  minLines: 1,
                  maxLines: 5,
                  onChanged: (_) => setState(() {}),
                  decoration: const InputDecoration(
                    hintText: '輸入訊息…',
                    contentPadding: EdgeInsets.symmetric(vertical: 12),
                  ),
                ),
                if (c.attachments.isNotEmpty)
                  Wrap(
                    spacing: 4,
                    children: [
                      for (final a in c.attachments)
                        InputChip(
                          label: Text('${a['name']}'),
                          onDeleted: () {
                            c.attachments.remove(a);
                            c.changed();
                          },
                        ),
                    ],
                  ),
                Row(
                  children: [
                    IconButton(
                      tooltip: '加入附件',
                      onPressed: c.canWrite
                          ? () => guarded(context, c.attach)
                          : null,
                      icon: const Icon(LucideIcons.plus),
                    ),
                    Expanded(
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: TextButton(
                          onPressed: c.running
                              ? () => setState(() => queue = !queue)
                              : c.canWrite
                              ? _modelSheet
                              : null,
                          style: TextButton.styleFrom(
                            backgroundColor: palette(context)['fill.hover'],
                            foregroundColor: palette(context)['text.primary'],
                            minimumSize: const Size(48, 36),
                            padding: const EdgeInsets.symmetric(horizontal: 12),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (c.running) ...[
                                Icon(
                                  queue
                                      ? LucideIcons.cornerDownRight
                                      : LucideIcons.navigation,
                                  size: 14,
                                ),
                                const SizedBox(width: 4),
                              ],
                              Flexible(
                                child: Text(
                                  c.running
                                      ? (queue ? '排隊' : '引導')
                                      : '${c.models.where((m) => m['id'] == c.state['modelId'] && m['provider'] == c.state['modelProvider']).firstOrNull?['name'] ?? c.state['modelId'] ?? '模型與思考'}',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(fontSize: 13),
                                ),
                              ),
                              if (!c.running) ...[
                                const SizedBox(width: 4),
                                const Icon(LucideIcons.chevronDown, size: 12),
                              ],
                            ],
                          ),
                        ),
                      ),
                    ),
                    if (c.running && composer.text.isNotEmpty)
                      IconButton(
                        tooltip: '停止目前工作',
                        onPressed: c.canWrite
                            ? () => c.sendCommand({'type': 'stop'})
                            : null,
                        icon: const Icon(LucideIcons.square, size: 18),
                      ),
                    IconButton.filled(
                      tooltip: c.running && composer.text.isEmpty
                          ? '停止目前工作'
                          : '送出',
                      style: IconButton.styleFrom(
                        backgroundColor: palette(context)['action.primary'],
                        foregroundColor: palette(context)['action.onPrimary'],
                      ),
                      onPressed:
                          c.canWrite &&
                              (c.running || composer.text.trim().isNotEmpty) &&
                              (!c.unknownCommand ||
                                  (c.running && composer.text.isEmpty))
                          ? () => c.running && composer.text.isEmpty
                                ? c.sendCommand({'type': 'stop'})
                                : c.send(
                                    c.running
                                        ? (queue ? 'follow_up' : 'steer')
                                        : 'prompt',
                                  )
                          : null,
                      icon: Icon(
                        c.running && composer.text.isEmpty
                            ? LucideIcons.square
                            : LucideIcons.arrowUp,
                        size: 20,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _modelSheet({bool forHome = false}) async {
    final choices = forHome
        ? rows((await c.gateway.request('/api/models'))['models'])
        : c.models;
    if (!mounted) return;
    var page = 'root';
    Json? selectedModel = forHome ? homeModel : null;
    String? selectedThinking = forHome ? homeThinking : null;
    var saving = false;
    await showModalBottomSheet<void>(
      context: context,
      useSafeArea: true,
      isScrollControlled: true,
      builder: (sheet) => StatefulBuilder(
        builder: (sheet, update) {
          final model =
              selectedModel ??
              choices
                  .where(
                    (m) =>
                        m['id'] == c.state['modelId'] &&
                        m['provider'] == c.state['modelProvider'],
                  )
                  .firstOrNull;
          final thinking =
              selectedThinking ?? '${c.state['thinking'] ?? 'off'}';
          const levels = {
            'off': '關閉',
            'minimal': '最少',
            'low': '低',
            'medium': '中',
            'high': '高',
            'xhigh': '更高',
          };
          Future<void> save(Json payload, {Json? model, String? level}) async {
            update(() => saving = true);
            final ok = forHome ? true : await c.sendCommand(payload);
            if (forHome && mounted) {
              setState(() {
                homeModel = model ?? homeModel;
                homeThinking = level ?? homeThinking;
              });
            }
            if (!sheet.mounted) return;
            update(() {
              saving = false;
              if (ok) {
                selectedModel = model ?? selectedModel;
                selectedThinking = level ?? selectedThinking;
                page = 'root';
              }
            });
            if (!ok) showNotice(sheet, c.actionError ?? '目前無法變更，請確認連線與控制權。');
          }

          return SafeArea(
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.sizeOf(sheet).height * .75,
              ),
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 20),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        if (page != 'root')
                          IconButton(
                            tooltip: '返回模型與思考',
                            onPressed: saving
                                ? null
                                : () => update(() => page = 'root'),
                            icon: const Icon(LucideIcons.arrowLeft, size: 20),
                          ),
                        Expanded(
                          child: Padding(
                            padding: const EdgeInsets.only(bottom: 12),
                            child: Text(
                              page == 'root'
                                  ? '模型與思考'
                                  : page == 'model'
                                  ? '模型'
                                  : '思考強度',
                              style: const TextStyle(
                                fontSize: 17,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                    Surface(
                      padding: EdgeInsets.zero,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (page == 'root') ...[
                            ListTile(
                              title: const Text('模型'),
                              trailing: const Icon(
                                LucideIcons.chevronRight,
                                size: 18,
                              ),
                              subtitle: Text(
                                '${model?['name'] ?? c.state['modelId'] ?? '預設模型'}',
                              ),
                              enabled: !saving && (forHome || !c.running),
                              onTap: () => update(() => page = 'model'),
                            ),
                            const Divider(height: 1, indent: 16),
                            ListTile(
                              title: const Text('思考強度'),
                              trailing: const Icon(
                                LucideIcons.chevronRight,
                                size: 18,
                              ),
                              subtitle: Text(levels[thinking] ?? thinking),
                              enabled: !saving && model?['reasoning'] == true,
                              onTap: () => update(() => page = 'thinking'),
                            ),
                          ],
                          if (page == 'model') ...[
                            if (choices.isEmpty)
                              const Padding(
                                padding: EdgeInsets.all(16),
                                child: Text('目前沒有可選模型'),
                              ),
                            for (final m in choices)
                              ListTile(
                                title: Text('${m['name'] ?? m['id']}'),
                                subtitle: Text('${m['provider']}'),
                                trailing:
                                    m['id'] == model?['id'] &&
                                        m['provider'] == model?['provider']
                                    ? const Icon(LucideIcons.check, size: 18)
                                    : null,
                                enabled: !saving && (forHome || !c.running),
                                onTap: () => save({
                                  'type': 'set_model',
                                  'provider': m['provider'],
                                  'modelId': m['id'],
                                }, model: m),
                              ),
                          ],
                          if (page == 'thinking')
                            for (final level in levels.entries)
                              ListTile(
                                title: Text(level.value),
                                trailing: thinking == level.key
                                    ? const Icon(LucideIcons.check, size: 18)
                                    : null,
                                enabled: !saving,
                                onTap: () => save({
                                  'type': 'set_thinking',
                                  'level': level.key,
                                }, level: level.key),
                              ),
                        ],
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(12, 10, 12, 0),
                      child: Text(
                        saving
                            ? '正在套用…'
                            : !forHome && c.running
                            ? '工作執行中，暫時無法切換模型。'
                            : forHome
                            ? '套用在下一個新對話。'
                            : '只套用在這個對話。',
                        style: TextStyle(
                          fontSize: 12.5,
                          color: palette(sheet)['text.muted'],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  void _sessionAction(String action) => guarded(context, () async {
    if (action == 'rename') {
      final name = await input(context, '重新命名', value: c.title);
      if (name != null && name.trim().isNotEmpty) {
        await c.updateSession({'name': name.trim()});
      }
    }
    if (action == 'pin') {
      await c.updateSession({
        'pinned': obj(c.state['session'])['pinnedAt'] == null,
      });
    }
    if (action == 'settle') {
      await c.updateSession({
        'settled': obj(c.state['session'])['settledAt'] == null,
      });
    }
  });
}

class PairingScreen extends StatefulWidget {
  const PairingScreen({super.key, required this.controller, this.onCancel});
  final LiveController controller;
  final VoidCallback? onCancel;
  @override
  State<PairingScreen> createState() => _PairingScreenState();
}

class _PairingScreenState extends State<PairingScreen> {
  late final field = TextEditingController(
    text: widget.controller.pairLink ?? '',
  );
  @override
  void dispose() {
    field.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('連接 pirc'),
      leading: widget.onCancel == null
          ? null
          : IconButton(
              onPressed: widget.onCancel,
              icon: const Icon(LucideIcons.x),
            ),
    ),
    body: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.all(16),
          children: [
            const Icon(LucideIcons.messagesSquare, size: 48),
            const SizedBox(height: 24),
            const Text(
              '讓工作跟著你',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 24,
                height: 32 / 24,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 16),
            const Text(
              '在網頁版「設定 → 裝置」建立配對，掃描 QR code 或貼上配對連結。',
              style: TextStyle(fontSize: 16, height: 28 / 16),
            ),
            const SizedBox(height: 20),
            TextField(
              controller: field,
              obscureText: true,
              autocorrect: false,
              enableSuggestions: false,
              decoration: supportingField(
                context,
                label: '配對連結',
                hint: 'pirc://pair?…',
              ),
            ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: widget.controller.busy
                  ? null
                  : () => widget.controller.pair(field.text),
              child: Text(widget.controller.busy ? '確認連線中…' : '連接'),
            ),
            TextButton.icon(
              onPressed: widget.controller.busy
                  ? null
                  : () => guarded(context, () async {
                      final value = await widget.controller.gateway.call(
                        'scan',
                      );
                      if (value != null && mounted) {
                        setState(() => field.text = '$value');
                        await widget.controller.pair('$value');
                      }
                    }),
              icon: const Icon(LucideIcons.scanLine),
              label: const Text('掃描 QR code'),
            ),
            if (widget.controller.error != null)
              Text(
                widget.controller.error!,
                style: TextStyle(color: palette(context)['status.danger']),
              ),
          ],
        ),
      ),
    ),
  );
}
