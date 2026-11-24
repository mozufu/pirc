import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:flutter/material.dart';
import '../theme.dart';
import 'permissions.dart';
import '../demo.dart' as demo;
import 'gateway.dart';
import 'common.dart';

class ManagementPage extends StatelessWidget {
  const ManagementPage({
    super.key,
    required this.kind,
    required this.controller,
    required this.theme,
  });
  final String kind;
  final LiveController controller;
  final PircTheme theme;
  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: kind == 'settings'
        ? palette(context)['surface.grouped']
        : null,
    appBar: AppBar(
      title: Text(
        {
              'settings': '設定',
              'schedules': '排程',
              'memory': '記憶提案',
              'activity': '待處理與動態',
            }[kind] ??
            kind,
      ),
    ),
    body: SafeArea(
      child: switch (kind) {
        'settings' => SettingsContent(controller: controller, theme: theme),
        'schedules' => SchedulesPage(controller: controller),
        'memory' => MemoryProposals(controller: controller),
        _ => ActivityPage(controller: controller, theme: theme),
      },
    ),
  );
}

class SettingsContent extends StatelessWidget {
  const SettingsContent({
    super.key,
    required this.controller,
    required this.theme,
  });
  final LiveController controller;
  final PircTheme theme;
  @override
  Widget build(BuildContext context) {
    final c = controller;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Surface(
          layer: true,
          padding: EdgeInsets.zero,
          child: Column(
            children: [
              ListTile(title: const Text('連線'), subtitle: Text(c.origin ?? '')),
              ListTile(
                title: const Text('此裝置'),
                subtitle: Text(c.clientId ?? ''),
              ),
              TextButton(
                onPressed: () => guarded(context, () async {
                  if (await confirm(context, '解除配對', '這會清除此 App 的配對憑證與草稿。')) {
                    await c.unpair();
                    if (context.mounted) Navigator.pop(context);
                  }
                }),
                child: const Text('解除配對'),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        Surface(
          layer: true,
          padding: EdgeInsets.zero,
          child: Column(
            children: [
              ListTile(
                leading: const Icon(LucideIcons.shieldCheck, size: 18),
                title: const Text('權限與快速回應'),
                subtitle: const Text('查看通知、浮窗的授權狀態'),
                trailing: const Icon(LucideIcons.chevronRight),
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute<void>(
                    builder: (_) => PermissionPage(gateway: c.gateway),
                  ),
                ),
              ),
              ListTile(
                title: const Text('通知'),
                trailing: const Icon(LucideIcons.chevronRight),
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute<void>(
                    builder: (_) => Scaffold(
                      appBar: AppBar(title: const Text('通知設定')),
                      backgroundColor: palette(context)['surface.grouped'],
                      body: SafeArea(child: PushSettings(controller: c)),
                    ),
                  ),
                ),
              ),
              ListTile(
                title: const Text('外觀'),
                subtitle: Text(
                  {
                    'system': '跟隨系統',
                    'light': '淺色',
                    'dark': '深色',
                  }[c.preferences['appearance'] ?? 'system']!,
                ),
                trailing: const Icon(LucideIcons.chevronRight),
                onTap: () => showModalBottomSheet<void>(
                  context: context,
                  useSafeArea: true,
                  builder: (sheet) => Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      for (final choice in [
                        ('system', '跟隨系統'),
                        ('light', '淺色'),
                        ('dark', '深色'),
                      ])
                        ListTile(
                          title: Text(choice.$2),
                          trailing: c.preferences['appearance'] == choice.$1
                              ? const Icon(LucideIcons.check)
                              : null,
                          onTap: () => guarded(sheet, () async {
                            await c.savePreferences({'appearance': choice.$1});
                            if (sheet.mounted) Navigator.pop(sheet);
                          }),
                        ),
                    ],
                  ),
                ),
              ),
              ListTile(
                title: const Text('記憶提案'),
                trailing: const Icon(LucideIcons.chevronRight),
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute<void>(
                    builder: (_) => ManagementPage(
                      kind: 'memory',
                      controller: c,
                      theme: theme,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        Surface(
          layer: true,
          padding: EdgeInsets.zero,
          child: Column(
            children: [
              ListTile(
                title: const Text('新增工作空間'),
                onTap: () => _workspace(context, c),
              ),
              ListTile(
                title: const Text('模型後端與裝置管理'),
                subtitle: const Text('在網頁管理'),
                onTap: () => guarded(context, () async {
                  await c.gateway.call('external', {'url': c.origin});
                }),
              ),
              if (const bool.fromEnvironment('PIRC_DEMO'))
                ListTile(
                  title: const Text('離線驗證工具'),
                  subtitle: const Text('使用本機測試資料'),
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute<void>(
                      builder: (_) => demo.PircApp(theme: theme),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }

  Future<void> _workspace(BuildContext context, LiveController c) async {
    final node = await showModalBottomSheet<String>(
      context: context,
      useSafeArea: true,
      builder: (sheet) => ListView(
        shrinkWrap: true,
        children: [
          for (final n in c.nodes)
            ListTile(
              title: Text('${n['id']}'),
              onTap: () => Navigator.pop(sheet, '${n['id']}'),
            ),
        ],
      ),
    );
    if (node == null || !context.mounted) return;
    final path = await input(context, 'Node 上的資料夾路徑');
    if (path == null || !context.mounted) return;
    final name = await input(context, '顯示名稱');
    if (name == null || !context.mounted) return;
    await guarded(context, () async {
      await c.gateway.request(
        '/api/workspaces',
        method: 'POST',
        body: {'nodeId': node, 'path': path, 'displayName': name},
      );
      await c.refreshList();
    });
  }
}

class PushSettings extends StatefulWidget {
  const PushSettings({super.key, required this.controller});
  final LiveController controller;
  @override
  State<PushSettings> createState() => _PushSettingsState();
}

class _PushSettingsState extends State<PushSettings>
    with WidgetsBindingObserver {
  LiveController get c => widget.controller;
  Json prefs = {}, push = {}, permission = {}, server = {};
  String? error;
  bool loading = true, saving = false;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    load();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) load();
  }

  Future<void> load() async {
    try {
      final values = await Future.wait([
        c.gateway.call('preferences'),
        c.gateway.call('pushStatus'),
        c.gateway.call('permissions'),
        c.gateway.request('/api/push'),
      ]);
      if (!mounted) return;
      setState(() {
        prefs = obj(values[0]);
        push = obj(values[1]);
        permission = obj(values[2]);
        server = obj(values[3]);
        error = null;
        loading = false;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          error = LiveController.describe(e);
          loading = false;
        });
      }
    }
  }

  Future<void> save(Json patch) async {
    if (saving) return;
    setState(() => saving = true);
    await guarded(context, () async {
      await c.savePreferences(patch);
      if (mounted) setState(() => prefs = {...c.preferences});
    });
    if (mounted) setState(() => saving = false);
  }

  Widget group(String title, List<Widget> children) => Padding(
    padding: const EdgeInsets.only(bottom: 20),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Text(
            title,
            style: TextStyle(
              fontSize: 12,
              color: palette(context)['text.muted'],
            ),
          ),
        ),
        Surface(
          layer: true,
          padding: EdgeInsets.zero,
          child: Column(
            children: [
              for (final (i, child) in children.indexed) ...[
                if (i > 0)
                  const Padding(
                    padding: EdgeInsets.only(left: 16),
                    child: Divider(height: 1),
                  ),
                child,
              ],
            ],
          ),
        ),
      ],
    ),
  );
  Widget toggle(
    String key,
    String title,
    String detail, {
    bool defaultValue = true,
  }) => SwitchListTile.adaptive(
    title: Text(title),
    subtitle: Text(detail),
    value: prefs[key] as bool? ?? defaultValue,
    onChanged: saving ? null : (value) => save({key: value}),
  );
  String time(String key, int fallback) {
    final n = (prefs[key] as num?)?.toInt() ?? fallback;
    return '${(n ~/ 60).toString().padLeft(2, '0')}:${(n % 60).toString().padLeft(2, '0')}';
  }

  Future<void> chooseTime(String key, int fallback) async {
    final n = (prefs[key] as num?)?.toInt() ?? fallback;
    final picked = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(hour: n ~/ 60, minute: n % 60),
    );
    if (picked != null) await save({key: picked.hour * 60 + picked.minute});
  }

  Future<void> mute() async {
    final selected = (prefs['muted'] as List? ?? []).map((e) => '$e').toSet();
    final result = await showModalBottomSheet<List<String>>(
      context: context,
      useSafeArea: true,
      isScrollControlled: true,
      builder: (sheet) => StatefulBuilder(
        builder: (sheet, update) => FractionallySizedBox(
          heightFactor: .7,
          child: Column(
            children: [
              const Padding(
                padding: EdgeInsets.all(16),
                child: Text(
                  '依工作空間靜音',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
                ),
              ),
              Expanded(
                child: ListView(
                  children: [
                    for (final w in c.workspaces)
                      CheckboxListTile(
                        title: Text('${w['displayName']}'),
                        value: selected.contains(w['id']),
                        onChanged: (on) => update(() {
                          if (on == true) {
                            selected.add('${w['id']}');
                          } else {
                            selected.remove(w['id']);
                          }
                        }),
                      ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(16),
                child: FinalButton(
                  onPressed: () => Navigator.pop(sheet, selected.toList()),
                  child: const Text('儲存'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    if (result != null) await save({'muted': result});
  }

  @override
  Widget build(BuildContext context) {
    if (loading) return const SupportingLoading();
    return ColoredBox(
      color: palette(context)['surface.grouped'],
      child: RefreshIndicator(
        onRefresh: load,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            if (error != null)
              SupportingState(title: '部分設定無法載入', detail: error!, onRetry: load),
            group('此手機', [
              ListTile(
                leading: Icon(
                  permission['notifications'] == true
                      ? LucideIcons.bell
                      : LucideIcons.bellOff,
                  size: 20,
                ),
                title: Text(
                  permission['notifications'] == true ? '通知權限已開啟' : '通知權限未開啟',
                ),
                subtitle: Text('${push['state'] ?? '尚未註冊推播'}'),
              ),
              Wrap(
                spacing: 8,
                children: [
                  TextButton(
                    onPressed: () => guarded(context, () async {
                      await c.gateway.call('pushEnable');
                      await load();
                    }),
                    child: const Text('啟用推播'),
                  ),
                  TextButton(
                    onPressed: () => guarded(context, () async {
                      await c.gateway.call('pushDisable');
                      await load();
                    }),
                    child: const Text('停用推播'),
                  ),
                  TextButton(
                    onPressed: () => guarded(context, () async {
                      final d = await c.gateway.request(
                        '/api/push/test',
                        method: 'POST',
                        body: {},
                      );
                      if (context.mounted) {
                        showNotice(context, '已送達 ${d['delivered'] ?? 0} 個目標');
                      }
                    }),
                    child: const Text('傳送測試'),
                  ),
                ],
              ),
              if ((push['distributors'] as List? ?? []).isEmpty)
                const Padding(
                  padding: EdgeInsets.all(16),
                  child: Text('請先安裝 UnifiedPush 推播服務（例如 ntfy），再啟用此手機推播。'),
                ),
            ]),
            group('通知類別', [
              toggle('q', '需要你回應', '問題、確認與等待回覆'),
              toggle('missed', '錯過的排程', '需要你決定執行或略過'),
              toggle('deleg', '委派的工作', '其他對話交付的工作'),
              toggle('mem', '記憶提案', '助手想記住的新內容', defaultValue: false),
              toggle('done', '工作完成或失敗', '通知此手機已連線對話的執行結果', defaultValue: false),
              toggle('live', '執行中的即時進度', '顯示此手機已連線對話的目前步驟'),
              ListTile(
                title: const Text('系統通知設定'),
                subtitle: const Text('聲音、震動與彈出方式'),
                trailing: const Icon(LucideIcons.externalLink, size: 18),
                onTap: () => guarded(context, () async {
                  await c.gateway.call('notificationSettings');
                }),
              ),
            ]),
            group('樣式', [
              toggle(
                'popup',
                '下方快速回應視窗',
                permission['overlay'] == true
                    ? '從通知開啟，在其他 App 上層確認並回答'
                    : '尚未授權浮窗；通知仍可開啟完整對話',
              ),
              if (permission['overlay'] != true)
                ListTile(
                  title: const Text('授權浮窗'),
                  trailing: const Icon(LucideIcons.chevronRight, size: 18),
                  onTap: () => guarded(context, () async {
                    await c.gateway.call('requestOverlay');
                  }),
                ),
              toggle('rich', '大型互動通知', '顯示最多三個選項；點選後仍須確認'),
              toggle('recall', '處理後自動收回', '收到最新狀態時，收回已處理的問題通知'),
              Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('鎖定畫面顯示'),
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 6,
                      children: [
                        for (final item in [
                          ('hide', '隱藏內容'),
                          ('summary', '只顯示標題'),
                          ('all', '全部顯示'),
                        ])
                          ChoiceChip(
                            label: Text(item.$2),
                            selected: (prefs['lock'] ?? 'hide') == item.$1,
                            onSelected: (_) => save({'lock': item.$1}),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            ]),
            group('勿擾與範圍', [
              toggle(
                'quiet',
                '勿擾時段',
                '${time('start', 1380)}–${time('end', 450)} · 需要你回應仍會通知',
                defaultValue: false,
              ),
              if (prefs['quiet'] == true) ...[
                ListTile(
                  title: const Text('開始時間'),
                  trailing: Text(time('start', 1380)),
                  onTap: () => chooseTime('start', 1380),
                ),
                ListTile(
                  title: const Text('結束時間'),
                  trailing: Text(time('end', 450)),
                  onTap: () => chooseTime('end', 450),
                ),
              ],
              ListTile(
                title: const Text('依工作空間靜音'),
                subtitle: Text(
                  '已靜音 ${(prefs['muted'] as List? ?? []).length} 個',
                ),
                trailing: const Icon(LucideIcons.chevronRight, size: 18),
                onTap: mute,
              ),
            ]),
            group('推送目標', [
              if (rows(server['subscriptions']).isEmpty)
                const ListTile(title: Text('尚未設定推送目標')),
              for (final target in rows(server['subscriptions']))
                ListTile(
                  title: Text('${target['name']}'),
                  subtitle: Text(
                    '${target['host']} · ${target['failing'] == true ? '最近傳送失敗' : '已註冊'}',
                  ),
                  trailing: IconButton(
                    tooltip: '移除目標',
                    icon: const Icon(LucideIcons.trash2, size: 18),
                    onPressed: () => guarded(context, () async {
                      if (await confirm(
                        context,
                        '移除通知目標',
                        '${target['name']}',
                      )) {
                        await c.gateway.request(
                          '/api/push/subscriptions',
                          method: 'DELETE',
                          body: {'id': target['id']},
                        );
                        await load();
                      }
                    }),
                  ),
                ),
            ]),
          ],
        ),
      ),
    );
  }
}

class SchedulesPage extends StatelessWidget {
  const SchedulesPage({super.key, required this.controller});
  final LiveController controller;
  @override
  Widget build(BuildContext context) => RemotePage(
    load: () => controller.gateway.request('/api/schedules'),
    builder: (context, data, reload) => ListView(
      padding: const EdgeInsets.all(16),
      children: [
        FilledButton.icon(
          onPressed: () async {
            await Navigator.push(
              context,
              MaterialPageRoute<void>(
                builder: (_) => ScheduleEditor(
                  controller: controller,
                  timezone: '${data['timezone'] ?? 'UTC'}',
                ),
              ),
            );
            reload();
          },
          icon: const Icon(LucideIcons.plus),
          label: const Text('新增排程'),
        ),
        if (rows(data['schedules']).isEmpty)
          const Padding(padding: EdgeInsets.all(24), child: Text('尚未建立排程')),
        for (final schedule in rows(data['schedules']))
          ListTile(
            title: Text('${schedule['title']}'),
            subtitle: Text(
              '${schedule['cron'] ?? _date(schedule['runAt'])}\n${schedule['timezone']} · ${schedule['status']}',
            ),
            trailing: (schedule['attention'] as num? ?? 0) > 0
                ? Badge(label: Text('${schedule['attention']}'))
                : null,
            onTap: () async {
              await Navigator.push(
                context,
                MaterialPageRoute<void>(
                  builder: (_) => ScheduleDetailPage(
                    controller: controller,
                    id: '${schedule['id']}',
                  ),
                ),
              );
              reload();
            },
          ),
      ],
    ),
  );
}

String _date(dynamic value) => value is num
    ? DateTime.fromMillisecondsSinceEpoch(
        value.toInt(),
      ).toLocal().toString().split('.').first
    : '—';

class ScheduleDetailPage extends StatefulWidget {
  const ScheduleDetailPage({
    super.key,
    required this.controller,
    required this.id,
  });
  final LiveController controller;
  final String id;
  @override
  State<ScheduleDetailPage> createState() => _ScheduleDetailPageState();
}

class _ScheduleDetailPageState extends State<ScheduleDetailPage> {
  LiveController get controller => widget.controller;
  String get id => widget.id;
  bool mutating = false;
  Future<void> action(Future<void> Function() work) async {
    if (mutating) return;
    setState(() => mutating = true);
    try {
      await guarded(context, work);
    } finally {
      if (mounted) setState(() => mutating = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('排程詳情')),
    body: AbsorbPointer(
      absorbing: mutating,
      child: RemotePage(
        load: () => controller.gateway.request('/api/schedules/${enc(id)}'),
        builder: (context, data, reload) {
          final s = obj(data['schedule']);
          final base = '/api/schedules/${enc(id)}';
          Future<void> mutate(
            String title,
            String suffix, {
            Json body = const {},
            String method = 'POST',
          }) => action(() async {
            final latest = await controller.gateway.request(base);
            if (!context.mounted) return;
            if (await confirm(
              context,
              title,
              '${obj(latest['schedule'])['title']}',
            )) {
              await controller.gateway.request(
                '$base$suffix',
                method: method,
                body: body,
              );
              reload();
            }
          });
          return ListView(
            padding: const EdgeInsets.all(20),
            children: [
              Text(
                '${s['title']}',
                style: const TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 12),
              RichTextBody('${s['prompt']}', gateway: controller.gateway),
              Text('${s['cron'] ?? _date(s['runAt'])} · ${s['timezone']}'),
              Wrap(
                spacing: 8,
                children: [
                  TextButton(
                    onPressed: () async {
                      await Navigator.push(
                        context,
                        MaterialPageRoute<void>(
                          builder: (_) => ScheduleEditor(
                            controller: controller,
                            timezone: '${s['timezone']}',
                            existing: s,
                          ),
                        ),
                      );
                      reload();
                    },
                    child: const Text('編輯'),
                  ),
                  TextButton(
                    onPressed: () => mutate(
                      s['status'] == 'active' ? '暫停排程' : '啟用排程',
                      '',
                      method: 'PATCH',
                      body: {
                        'status': s['status'] == 'active' ? 'paused' : 'active',
                      },
                    ),
                    child: Text(s['status'] == 'active' ? '暫停' : '啟用'),
                  ),
                  TextButton(
                    onPressed: () => mutate('立即執行這個排程？', '/run'),
                    child: const Text('執行一次…'),
                  ),
                  TextButton(
                    onPressed: () => action(() async {
                      if (await confirm(context, '刪除排程', '${s['title']}')) {
                        await controller.gateway.request(
                          base,
                          method: 'DELETE',
                        );
                        if (context.mounted) Navigator.pop(context);
                      }
                    }),
                    child: const Text('刪除'),
                  ),
                ],
              ),
              const SizedBox(height: 20),
              const Text('執行紀錄', style: TextStyle(fontWeight: FontWeight.w600)),
              if (rows(data['runs']).any((r) => r['status'] == 'missed'))
                TextButton.icon(
                  onPressed: () => guarded(context, () async {
                    final notice = await controller.gateway.call('overlay', {
                      'scheduleId': id,
                    });
                    if (notice != null && context.mounted) {
                      showNotice(context, '$notice');
                    }
                  }),
                  icon: const Icon(LucideIcons.panelsTopLeft, size: 18),
                  label: const Text('快速處理浮窗'),
                ),
              for (final run in rows(data['runs']))
                ListTile(
                  title: Text('${run['status']} · ${_date(run['dueAt'])}'),
                  subtitle: Text('${run['result'] ?? run['session'] ?? ''}'),
                  onTap: run['sessionId'] == null
                      ? null
                      : () => guarded(context, () async {
                          await controller.open('${run['sessionId']}');
                          if (context.mounted) {
                            Navigator.of(context).popUntil((r) => r.isFirst);
                          }
                        }),
                  trailing: run['status'] == 'missed'
                      ? PopupMenuButton<String>(
                          onSelected: (action) => mutate(
                            action == 'run' ? '執行錯過的工作？' : '略過這次執行？',
                            action == 'run'
                                ? '/run'
                                : '/runs/${enc('${run['id']}')}/dismiss',
                            body: action == 'run' ? {'runId': run['id']} : {},
                          ),
                          itemBuilder: (_) => const [
                            PopupMenuItem(value: 'run', child: Text('查看並執行…')),
                            PopupMenuItem(value: 'dismiss', child: Text('略過…')),
                          ],
                        )
                      : null,
                ),
            ],
          );
        },
      ),
    ),
  );
}

class ScheduleEditor extends StatefulWidget {
  const ScheduleEditor({
    super.key,
    required this.controller,
    required this.timezone,
    this.existing,
  });
  final LiveController controller;
  final String timezone;
  final Json? existing;
  @override
  State<ScheduleEditor> createState() => _ScheduleEditorState();
}

class _ScheduleEditorState extends State<ScheduleEditor> {
  late final title = TextEditingController(
    text: '${widget.existing?['title'] ?? ''}',
  );
  late final prompt = TextEditingController(
    text: '${widget.existing?['prompt'] ?? ''}',
  );
  late final timing = TextEditingController(
    text: '${widget.existing?['cron'] ?? '0 9 * * *'}',
  );
  late final zone = TextEditingController(text: widget.timezone);
  late String? workspace = widget.existing?['workspaceId'] as String?;
  late bool once = widget.existing != null && widget.existing!['cron'] == null;
  bool busy = false, wallLoading = false;
  String notify = 'all', thinking = '';
  String? modelKey, error;
  List<Json> models = [];
  @override
  void initState() {
    super.initState();
    notify = '${widget.existing?['notify'] ?? 'all'}';
    thinking = '${widget.existing?['thinking'] ?? ''}';
    final model = obj(widget.existing?['model']);
    if (model.isNotEmpty) modelKey = '${model['provider']}/${model['id']}';
    final at = widget.existing?['runAt'];
    if (once && at is num) {
      wallLoading = true;
      widget.controller.gateway
          .call('wallInput', {'at': at, 'timezone': widget.timezone})
          .then((value) {
            if (mounted) {
              setState(() {
                timing.text = '$value';
                wallLoading = false;
              });
            }
          })
          .catchError((Object e) {
            if (mounted) setState(() => error = LiveController.describe(e));
          });
    }
    loadModels();
  }

  Future<void> loadModels() async {
    try {
      final d = await widget.controller.gateway.request('/api/models');
      if (mounted) setState(() => models = rows(d['models']));
    } catch (e) {
      if (mounted) setState(() => error = LiveController.describe(e));
    }
  }

  @override
  void dispose() {
    title.dispose();
    prompt.dispose();
    timing.dispose();
    zone.dispose();
    super.dispose();
  }

  Future<void> save() async {
    if (busy || wallLoading) return;
    if (workspace == null ||
        title.text.trim().isEmpty ||
        prompt.text.trim().isEmpty) {
      setState(() => error = '請填寫工作空間、標題與指令');
      return;
    }
    setState(() => busy = true);
    try {
      final model = models
          .where((m) => '${m['provider']}/${m['id']}' == modelKey)
          .firstOrNull;
      await widget.controller.gateway.request(
        '/api/schedules${widget.existing == null ? '' : '/${enc('${widget.existing!['id']}')}'}',
        method: widget.existing == null ? 'POST' : 'PATCH',
        body: {
          'workspaceId': workspace,
          'title': title.text.trim(),
          'prompt': prompt.text.trim(),
          'timezone': zone.text.trim(),
          if (once) 'at': timing.text.trim() else 'cron': timing.text.trim(),
          'model': model == null
              ? ((modelKey?.isEmpty ?? true) ? null : widget.existing?['model'])
              : {'provider': model['provider'], 'id': model['id']},
          'thinking': thinking.isEmpty ? null : thinking,
          'notify': notify,
        },
      );
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) setState(() => error = LiveController.describe(e));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Theme(
    data: Theme.of(context).copyWith(
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: palette(context)['surface.subtle'],
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 16,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: palette(context)['accent.default']),
        ),
      ),
    ),
    child: Scaffold(
      appBar: AppBar(title: Text(widget.existing == null ? '新增排程' : '編輯排程')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const SizedBox(height: 16),
          DropdownButtonFormField<String>(
            isExpanded: true,
            initialValue:
                widget.controller.workspaces.any((w) => w['id'] == workspace)
                ? workspace
                : null,
            decoration: const InputDecoration(labelText: '工作空間'),
            items: [
              for (final w in widget.controller.workspaces)
                DropdownMenuItem(
                  value: '${w['id']}',
                  child: Text(
                    '${w['displayName']}',
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
            ],
            onChanged: (v) => workspace = v,
          ),
          const SizedBox(height: 16),
          TextField(
            controller: title,
            decoration: const InputDecoration(labelText: '標題'),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: prompt,
            minLines: 3,
            maxLines: 10,
            decoration: const InputDecoration(labelText: '給 agent 的指令'),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('只執行一次'),
            value: once,
            onChanged: (v) => setState(() {
              once = v;
              timing.text = v ? '' : '0 9 * * *';
            }),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: timing,
            decoration: InputDecoration(
              labelText: once ? '當地日期時間（YYYY-MM-DDTHH:mm）' : 'Cron（分 時 日 月 週）',
              hintText: once ? '2026-10-01T09:00' : '0 9 * * *',
            ),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: zone,
            decoration: const InputDecoration(
              labelText: 'IANA 時區',
              hintText: 'Asia/Taipei',
            ),
          ),
          const SizedBox(height: 16),
          DropdownButtonFormField<String>(
            key: ValueKey('models-${models.length}'),
            isExpanded: true,
            initialValue:
                models.any((m) => '${m['provider']}/${m['id']}' == modelKey)
                ? modelKey
                : '',
            decoration: InputDecoration(
              labelText: '模型',
              helperText:
                  modelKey != null &&
                      modelKey!.isNotEmpty &&
                      !models.any(
                        (m) => '${m['provider']}/${m['id']}' == modelKey,
                      )
                  ? '保留原模型：$modelKey'
                  : null,
            ),
            items: [
              const DropdownMenuItem(value: '', child: Text('預設')),
              for (final m in models)
                DropdownMenuItem(
                  value: '${m['provider']}/${m['id']}',
                  child: Text(
                    '${m['name'] ?? m['id']}',
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
            ],
            onChanged: (v) => modelKey = v,
          ),
          const SizedBox(height: 16),
          DropdownButtonFormField<String>(
            initialValue: thinking,
            decoration: const InputDecoration(labelText: '思考強度'),
            items: [
              for (final level in [
                '',
                'off',
                'minimal',
                'low',
                'medium',
                'high',
                'xhigh',
                'max',
              ])
                DropdownMenuItem(
                  value: level,
                  child: Text(level.isEmpty ? '預設' : level),
                ),
            ],
            onChanged: (v) => thinking = v ?? '',
          ),
          const SizedBox(height: 16),
          DropdownButtonFormField<String>(
            initialValue: notify,
            decoration: const InputDecoration(labelText: '通知'),
            items: const [
              DropdownMenuItem(value: 'all', child: Text('每次執行')),
              DropdownMenuItem(value: 'problems', child: Text('只通知需要注意的工作')),
              DropdownMenuItem(value: 'none', child: Text('不通知')),
            ],
            onChanged: (v) => notify = v ?? 'all',
          ),
          if (error != null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Text(error!),
            ),
          const SizedBox(height: 20),
          FilledButton(
            onPressed: busy ? null : save,
            child: Text(busy ? '儲存中…' : '儲存'),
          ),
        ],
      ),
    ),
  );
}

class MemoryProposals extends StatelessWidget {
  const MemoryProposals({super.key, required this.controller});
  final LiveController controller;
  @override
  Widget build(BuildContext context) => RemotePage(
    load: () => controller.gateway.request('/api/memory'),
    builder: (context, data, reload) => ListView(
      padding: const EdgeInsets.all(20),
      children: [
        if (rows(
          data['proposals'],
        ).where((p) => p['status'] == 'pending').isEmpty)
          const Text('沒有待審核的記憶提案'),
        for (final proposal in rows(
          data['proposals'],
        ).where((p) => p['status'] == 'pending'))
          Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: Surface(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${proposal['action']}',
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  if (obj(proposal['target'])['content'] != null)
                    Text('目前：${obj(proposal['target'])['content']}'),
                  RichTextBody(
                    '${proposal['content'] ?? ''}',
                    gateway: controller.gateway,
                  ),
                  Text('來源：${proposal['quote'] ?? ''}'),
                  Wrap(
                    children: [
                      for (final action in ['approve', 'reject'])
                        TextButton(
                          onPressed: () => guarded(context, () async {
                            final latest = await controller.gateway.request(
                              '/api/memory',
                            );
                            final p = rows(latest['proposals'])
                                .where((p) => p['id'] == proposal['id'])
                                .firstOrNull;
                            if (p == null || p['status'] != 'pending') {
                              throw StateError('這個提案已處理');
                            }
                            if (obj(p['target'])['revision'] !=
                                obj(proposal['target'])['revision']) {
                              reload();
                              throw StateError('內容已更新，請重新檢視後確認');
                            }
                            if (context.mounted &&
                                await confirm(
                                  context,
                                  action == 'approve' ? '核准記憶提案' : '拒絕記憶提案',
                                  '${p['content'] ?? obj(p['target'])['content'] ?? ''}',
                                )) {
                              await controller.gateway.request(
                                '/api/memory/proposals/${enc('${p['id']}')}/$action',
                                method: 'POST',
                                body: action == 'approve'
                                    ? {
                                        'targetRevision': obj(
                                          p['target'],
                                        )['revision'],
                                      }
                                    : {},
                              );
                              reload();
                            }
                          }),
                          child: Text(action == 'approve' ? '核准…' : '拒絕…'),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ),
      ],
    ),
  );
}

class ActivityPage extends StatelessWidget {
  const ActivityPage({
    super.key,
    required this.controller,
    required this.theme,
  });
  final LiveController controller;
  final PircTheme theme;
  @override
  Widget build(BuildContext context) => RemotePage(
    load: () async {
      await controller.refreshList();
      final pending = <Json>[];
      final waiting = controller.sessions
          .where((s) => s['runStatus'] == 'waiting_input')
          .toList();
      for (var start = 0; start < waiting.length; start += 4) {
        await Future.wait(
          waiting.skip(start).take(4).map((session) async {
            try {
              final snapshot = obj(
                await controller.gateway.call('refresh', {
                  'sessionId': session['id'],
                }),
              );
              for (final q in rows(
                snapshot['interactions'],
              ).where((q) => q['status'] == 'pending')) {
                pending.add({
                  ...q,
                  'sessionId': session['id'],
                  'sessionName': session['name'],
                });
              }
            } catch (_) {
              pending.add({
                'title': '開啟對話確認狀態',
                'sessionId': session['id'],
                'sessionName': session['name'],
              });
            }
          }),
        );
      }
      pending.sort(
        (a, b) => ((a['expiresAt'] as num?) ?? 9007199254740991).compareTo(
          (b['expiresAt'] as num?) ?? 9007199254740991,
        ),
      );
      final unavailable = <String>[];
      Future<Json> source(String path, String label) async {
        try {
          return await controller.gateway.request(path);
        } catch (_) {
          unavailable.add(label);
          return {};
        }
      }

      final responses = await Future.wait([
        source('/api/schedules', '排程'),
        source('/api/memory', '記憶提案'),
      ]);
      final data = responses[0], memory = responses[1];
      return {
        'unavailable': unavailable,
        'pending': pending,
        'schedules': data['schedules'],
        'proposals': memory['proposals'],
        'recent': await controller.gateway.call('activity'),
      };
    },
    builder: (context, data, reload) => ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Row(
          children: [
            const Expanded(
              child: Text(
                '待你處理',
                style: TextStyle(fontSize: 22, fontWeight: FontWeight.w600),
              ),
            ),
            IconButton(
              tooltip: '重新整理',
              onPressed: reload,
              icon: const Icon(LucideIcons.refreshCw),
            ),
          ],
        ),
        if ((data['unavailable'] as List? ?? []).isNotEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Text(
              '${(data['unavailable'] as List).join('、')} 暫時無法載入，請重新整理。',
            ),
          ),
        if (rows(data['pending']).isEmpty &&
            !rows(
              data['schedules'],
            ).any((s) => (s['attention'] as num? ?? 0) > 0) &&
            !rows(data['proposals']).any((p) => p['status'] == 'pending'))
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 24),
            child: SupportingState(
              title: '目前沒有待處理項目',
              detail: '需要你回答的問題與錯過排程會顯示在這裡。',
            ),
          ),
        for (final s in rows(data['pending']))
          ListTile(
            leading: const Icon(LucideIcons.circleHelp),
            title: Text('${s['title']}'),
            subtitle: Text(
              '${s['sessionName']}${s['expiresAt'] == null ? '' : ' · 到期 ${_date(s['expiresAt'])}'}',
            ),
            onTap: () => guarded(context, () async {
              await controller.open('${s['sessionId']}');
              if (context.mounted) Navigator.pop(context);
            }),
          ),
        for (final s in rows(
          data['schedules'],
        ).where((s) => (s['attention'] as num? ?? 0) > 0))
          ListTile(
            leading: const Icon(LucideIcons.clock),
            title: Text('${s['title']}'),
            subtitle: Text('${s['attention']} 次執行待處理'),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute<void>(
                builder: (_) => ScheduleDetailPage(
                  controller: controller,
                  id: '${s['id']}',
                ),
              ),
            ),
          ),
        if (rows(data['proposals']).any((p) => p['status'] == 'pending'))
          ListTile(
            leading: const Icon(LucideIcons.brain),
            title: const Text('記憶提案'),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute<void>(
                builder: (_) => ManagementPage(
                  kind: 'memory',
                  controller: controller,
                  theme: theme,
                ),
              ),
            ),
          ),
        const SizedBox(height: 24),
        const Text(
          '最近動態',
          style: TextStyle(fontSize: 22, fontWeight: FontWeight.w600),
        ),
        const Text('此裝置收到的通知', style: TextStyle(fontSize: 12)),
        for (final entry in rows(data['recent']))
          ListTile(
            title: Text('${entry['title']}'),
            subtitle: Text('${entry['body']}\n${_date(entry['at'])}'),
            onTap: entry['sessionId'] == null
                ? null
                : () => guarded(context, () async {
                    await controller.open('${entry['sessionId']}');
                    if (context.mounted) Navigator.pop(context);
                  }),
          ),
        if (rows(data['recent']).isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 20),
            child: Text('尚未收到通知'),
          ),
      ],
    ),
  );
}
