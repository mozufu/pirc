import 'dart:async';
import 'package:flutter/material.dart';
import 'bridge.dart';
import 'reply_controller.dart';
import 'theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(PircApp(theme: await PircTheme.load()));
}

class PircApp extends StatelessWidget {
  const PircApp({super.key, required this.theme});
  final PircTheme theme;
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'pirc · 行動版驗證',
    debugShowCheckedModeBanner: false,
    theme: theme.build(Brightness.light),
    darkTheme: theme.build(Brightness.dark),
    home: const WorkspaceScreen(),
  );
}

class WorkspaceScreen extends StatefulWidget {
  const WorkspaceScreen({super.key});
  @override
  State<WorkspaceScreen> createState() => _WorkspaceScreenState();
}

class _WorkspaceScreenState extends State<WorkspaceScreen>
    with WidgetsBindingObserver {
  final bridge = MobileBridge();
  late final reply = ReplyController(bridge);
  final draft = TextEditingController();
  final artifact = ArtifactSelection();
  final readerScroll = ScrollController();
  final chatScroll = ScrollController();
  final readerKey = GlobalKey();
  final scaffoldKey = GlobalKey<ScaffoldState>();
  bool artifactOpen = false;
  bool draftLoaded = false;
  Timer? draftTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    reply.addListener(_update);
    draft.addListener(_draftChanged);
    MobileBridge.channel.setMethodCallHandler((call) async {
      if (call.method == 'openConversation') {
        if (mounted) _closeArtifact();
        await reply.refresh();
      }
    });
    unawaited(reply.refresh());
  }

  void _update() {
    final snapshot = reply.snapshot;
    if (snapshot != null) {
      if (!draftLoaded) {
        draftLoaded = true;
        draft.text = snapshot.draft;
      }
      artifact.receive(snapshot.latestVersion);
    }
    if (mounted) setState(() {});
  }

  void _draftChanged() {
    draftTimer?.cancel();
    draftTimer = Timer(const Duration(milliseconds: 250), _saveDraft);
  }

  Future<void> _saveDraft() async {
    try {
      await bridge.invoke<void>('saveDraft', draft.text);
    } catch (_) {
      /* Local fixture may be unavailable during shutdown. */
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(reply.refresh());
    } else {
      draftTimer?.cancel();
      unawaited(_saveDraft());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    MobileBridge.channel.setMethodCallHandler(null);
    draftTimer?.cancel();
    reply.removeListener(_update);
    reply.dispose();
    draft.dispose();
    readerScroll.dispose();
    chatScroll.dispose();
    super.dispose();
  }

  Future<void> _native(String method, [Object? args]) async {
    try {
      final message = await bridge.invoke<String>(method, args);
      if (message != null && mounted) _message(message);
    } catch (error) {
      if (mounted) _message('操作未完成：$error');
    }
  }

  void _message(String text) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

  void _switchVersion(int version) {
    artifact.switchTo(
      version,
      readerScroll.hasClients ? readerScroll.offset : 0,
    );
    setState(() {});
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (readerScroll.hasClients) {
        readerScroll.jumpTo(
          artifact.offset.clamp(0, readerScroll.position.maxScrollExtent),
        );
      }
    });
  }

  void _closeArtifact() {
    if (readerScroll.hasClients) {
      artifact.offsets[artifact.selected] = readerScroll.offset;
    }
    setState(() => artifactOpen = false);
  }

  void _openArtifact() {
    setState(() => artifactOpen = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (readerScroll.hasClients) {
        readerScroll.jumpTo(
          artifact.offset.clamp(0, readerScroll.position.maxScrollExtent),
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final wide = constraints.maxWidth >= 600;
      final c = Theme.of(context).extension<PircColors>()!;
      return PopScope(
        canPop: !artifactOpen,
        onPopInvokedWithResult: (didPop, result) {
          if (!didPop) _closeArtifact();
        },
        child: Scaffold(
          key: scaffoldKey,
          appBar: AppBar(
            leading: IconButton(
              tooltip: '開啟側欄',
              onPressed: () => scaffoldKey.currentState!.openDrawer(),
              icon: const Icon(Icons.menu),
            ),
            title: const Text(
              '行動版設計',
              style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
            ),
            actions: [
              IconButton(
                tooltip: '驗證工具',
                onPressed: _showLab,
                icon: const Icon(Icons.tune),
              ),
            ],
          ),
          drawer: Drawer(child: SafeArea(child: _sidebar(c))),
          body: SafeArea(
            top: false,
            child: Column(
              children: [
                Container(
                  width: double.infinity,
                  color: c['surface.subtle'],
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 6,
                  ),
                  child: Text(
                    '本機驗證版 · 使用測試資料',
                    style: TextStyle(fontSize: 12, color: c['text.secondary']),
                  ),
                ),
                Expanded(
                  child: Stack(
                    children: [
                      Row(
                        children: [
                          if (wide && !artifactOpen)
                            SizedBox(width: 280, child: _sidebar(c)),
                          Expanded(child: _chat(c)),
                          if (wide && artifactOpen)
                            SizedBox(
                              width: constraints.maxWidth >= 840
                                  ? constraints.maxWidth - 480
                                  : constraints.maxWidth / 2,
                              child: _reader(c),
                            ),
                        ],
                      ),
                      if (!wide && artifactOpen)
                        Positioned.fill(child: _reader(c)),
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

  Widget _sidebar(PircColors c) => Material(
    color: c['surface.sidebar'],
    child: ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const Padding(
          padding: EdgeInsets.all(12),
          child: Text(
            'pirc',
            style: TextStyle(fontSize: 24, fontWeight: FontWeight.w600),
          ),
        ),
        const Padding(
          padding: EdgeInsets.all(12),
          child: Text('工作', style: TextStyle(fontWeight: FontWeight.w600)),
        ),
        ListTile(
          selected: true,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          leading: const Icon(Icons.chat_bubble_outline),
          title: const Text('行動版設計'),
          subtitle: Text(
            reply.snapshot?.status == ReplyStatus.handled ? '已回覆' : '待你處理',
          ),
          onTap: () {
            scaffoldKey.currentState?.closeDrawer();
            _closeArtifact();
          },
        ),
        const SizedBox(height: 24),
        ListTile(
          leading: const Icon(Icons.tune),
          title: const Text('驗證工具'),
          onTap: () {
            scaffoldKey.currentState?.closeDrawer();
            _showLab();
          },
        ),
      ],
    ),
  );

  Widget _chat(PircColors c) => Column(
    children: [
      Expanded(
        child: ListView(
          controller: chatScroll,
          padding: const EdgeInsets.all(20),
          children: [
            Align(
              alignment: Alignment.centerRight,
              child: Container(
                constraints: const BoxConstraints(maxWidth: 440),
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: c['surface.bubble'],
                  borderRadius: BorderRadius.circular(20),
                ),
                child: const Text(
                  '先做好手機與平板，成果有新版時讓我自己切換。',
                  style: TextStyle(height: 1.7),
                ),
              ),
            ),
            const SizedBox(height: 28),
            const Text(
              '我們先驗證這段工作流程。你可以在浮窗回覆問題，再回到這裡繼續閱讀。',
              style: TextStyle(fontSize: 16, height: 1.8),
            ),
            const SizedBox(height: 20),
            _replyCard(c),
            const SizedBox(height: 20),
            Container(
              decoration: BoxDecoration(
                color: c['surface.subtle'],
                borderRadius: BorderRadius.circular(16),
              ),
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '文件 · v${artifact.latest}',
                    style: TextStyle(color: c['text.secondary'], fontSize: 12),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    '行動版實作筆記',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 8),
                  const Text('先把一段完整流程跑通，再擴展介面。'),
                  const SizedBox(height: 8),
                  TextButton.icon(
                    key: const Key('open-artifact'),
                    onPressed: _openArtifact,
                    icon: const Icon(Icons.open_in_full, size: 18),
                    label: const Text('開啟成果'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          decoration: BoxDecoration(
            color: c['surface.input'],
            borderRadius: BorderRadius.circular(28),
            boxShadow: [
              BoxShadow(
                color: c['line.hairline'],
                blurRadius: 20,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                key: const Key('draft'),
                controller: draft,
                minLines: 1,
                maxLines: 3,
                decoration: const InputDecoration(
                  hintText: '寫下想法…',
                  contentPadding: EdgeInsets.symmetric(vertical: 12),
                ),
              ),
              Text(
                '草稿會保留 · 此版尚未連接 agent',
                style: TextStyle(fontSize: 12, color: c['text.muted']),
              ),
              const SizedBox(height: 6),
            ],
          ),
        ),
      ),
    ],
  );

  Widget _replyCard(PircColors c) {
    final snapshot = reply.snapshot;
    String? stateText;
    if (reply.busy) {
      stateText = '正在確認最新狀態…';
    } else if (reply.outcomeUnknown) {
      stateText = '不確定是否已送達，請檢查狀態';
    } else {
      stateText = switch (snapshot?.status) {
        ReplyStatus.handled =>
          '已回覆：${snapshot?.answer ?? '已處理'}\n${snapshot?.actor ?? ''} ${snapshot?.answeredAt ?? ''}',
        ReplyStatus.expired => '這個問題已過期',
        ReplyStatus.controlledElsewhere => '由另一台裝置控制中，請在完整客戶端處理控制權',
        ReplyStatus.offline => '無法確認最新狀態，請檢查連線',
        _ => null,
      };
    }
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: c['accent.soft'],
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '待你確認',
            style: TextStyle(
              color: c['accent.default'],
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 10),
          const Text(
            '這一輪先驗證快速回應浮窗嗎？',
            style: TextStyle(fontSize: 17, height: 1.6),
          ),
          const SizedBox(height: 10),
          if (stateText != null)
            Text(
              stateText,
              key: const Key('reply-state'),
              style: const TextStyle(height: 1.6),
            ),
          if (reply.error != null && !reply.outcomeUnknown)
            Text(reply.error!, style: TextStyle(color: c['text.warning'])),
          if (!reply.busy &&
              !reply.outcomeUnknown &&
              snapshot?.status == ReplyStatus.pending)
            Wrap(
              spacing: 8,
              children: [
                for (final option in ['先驗證浮窗', '先看完整對話'])
                  ChoiceChip(
                    label: Text(option),
                    selected: reply.choice == option,
                    materialTapTargetSize: MaterialTapTargetSize.padded,
                    onSelected: (_) => reply.select(option),
                  ),
              ],
            ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              if (snapshot?.status == ReplyStatus.pending &&
                  !reply.outcomeUnknown)
                FilledButton(
                  key: const Key('submit-answer'),
                  onPressed: reply.canSubmit ? reply.submit : null,
                  child: const Text('送出答案'),
                ),
              TextButton(
                onPressed: reply.busy ? null : reply.refresh,
                child: Text(reply.outcomeUnknown ? '檢查狀態' : '重新整理'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _reader(PircColors c) => Material(
    key: readerKey,
    color: c['surface.page'],
    child: Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Row(
            children: [
              IconButton(
                key: const Key('close-artifact'),
                tooltip: '關閉成果',
                onPressed: _closeArtifact,
                icon: const Icon(Icons.arrow_back),
              ),
              Expanded(
                child: Text(
                  '實作筆記 · v${artifact.selected}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              PopupMenuButton<int>(
                tooltip: '選擇版本',
                onSelected: _switchVersion,
                itemBuilder: (_) => [
                  for (var i = 1; i <= artifact.latest; i++)
                    PopupMenuItem(value: i, child: Text('v$i')),
                ],
              ),
            ],
          ),
        ),
        if (artifact.hasUpdate)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Wrap(
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 12,
              children: [
                Text('已有 v${artifact.latest}，目前內容保留'),
                TextButton(
                  key: const Key('switch-version'),
                  onPressed: () => _switchVersion(artifact.latest),
                  child: const Text('切換新版'),
                ),
              ],
            ),
          ),
        Expanded(
          child: ListView(
            key: const Key('artifact-reader'),
            controller: readerScroll,
            padding: const EdgeInsets.all(24),
            children: [
              Text(
                '先把一段流程做好',
                style: Theme.of(context).textTheme.headlineSmall,
              ),
              const SizedBox(height: 20),
              Text(
                artifact.selected == 1
                    ? '版本 1：讓問題在需要你的時候出現。'
                    : '版本 ${artifact.selected}：加入背景返回與閱讀位置保留。',
                style: const TextStyle(fontSize: 17, height: 1.8),
              ),
              for (final heading in [
                '快速回應',
                '確認最新狀態',
                '明確送出',
                '返回對話',
                '保留閱讀位置',
                '手機與平板',
              ]) ...[
                const SizedBox(height: 28),
                Text(
                  heading,
                  style: const TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 12),
                const Text(
                  '這份文件用來驗證閱讀體驗。介面尺寸改變時，保留正在進行的工作；內容更新時，先提示你，再由你決定何時切換。',
                  style: TextStyle(fontSize: 16, height: 1.9),
                ),
              ],
            ],
          ),
        ),
      ],
    ),
  );

  Future<void> _showLab() => showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (sheetContext) => FractionallySizedBox(
      heightFactor: .86,
      child: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          const Text(
            '驗證工具',
            style: TextStyle(fontSize: 22, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          const Text('這些操作只改變本機測試資料。浮窗與通知使用 Android 原生功能。'),
          const SizedBox(height: 16),
          for (final action in <(String, String)>[
            ('通知權限', 'requestNotifications'),
            ('浮窗權限', 'requestOverlay'),
            ('發出測試通知', 'notify'),
            ('切到背景並開浮窗', 'showOverlay'),
          ])
            ListTile(
              title: Text(action.$1),
              trailing: const Icon(Icons.chevron_right),
              onTap: () async {
                Navigator.pop(sheetContext);
                await _native(action.$2);
              },
            ),
          ListTile(
            title: const Text('模擬成果新版本'),
            onTap: () async {
              Navigator.pop(sheetContext);
              await _native('newVersion');
              await reply.refresh();
            },
          ),
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text('問題情境', style: TextStyle(fontWeight: FontWeight.w600)),
          ),
          for (final scenario in <(String, String)>[
            ('pending', '可回答'),
            ('handled', '已由桌面處理'),
            ('expired', '問題已過期'),
            ('controlledElsewhere', '控制權在另一台裝置'),
            ('offline', '離線'),
            ('race', '送出時被其他裝置搶先回答'),
            ('unknown', '已送達，但回應遺失'),
          ])
            ListTile(
              title: Text(scenario.$2),
              onTap: () async {
                Navigator.pop(sheetContext);
                await _native('configure', scenario.$1);
                reply.resetSelection();
                await reply.refresh();
              },
            ),
        ],
      ),
    ),
  );
}
