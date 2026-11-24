import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'gateway.dart';
import 'common.dart';

/// Read OS truth on every return from Settings; opening Settings is not approval.
class PermissionPage extends StatefulWidget {
  const PermissionPage({super.key, required this.gateway, this.onComplete});
  final Gateway gateway;
  final Future<void> Function()? onComplete;
  @override
  State<PermissionPage> createState() => _PermissionPageState();
}

class _PermissionPageState extends State<PermissionPage>
    with WidgetsBindingObserver {
  Json? permissions;
  bool busy = false;
  String? error;
  bool get firstRun => widget.onComplete != null;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    refresh();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) refresh();
  }

  Future<void> refresh() async {
    try {
      final next = obj(await widget.gateway.call('permissions'));
      if (mounted) {
        setState(() {
          permissions = next;
          error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => error = LiveController.describe(e));
    }
  }

  Future<void> request(String method) async {
    if (busy) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await widget.gateway.call(method);
      await refresh();
    } catch (e) {
      if (mounted) setState(() => error = LiveController.describe(e));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> finish() async {
    if (busy) return;
    setState(() => busy = true);
    try {
      await widget.gateway.call('completeOnboarding');
      await widget.onComplete!();
    } catch (e) {
      if (mounted) setState(() => error = LiveController.describe(e));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Widget permissionCard(
    String name,
    String title,
    String detail,
    String fallback,
    IconData icon,
    String method,
  ) {
    final granted = permissions?[name] == true;
    return Surface(
      layer: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 22),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  title,
                  style: TextStyle(
                    fontSize: 17,
                    height: 24 / 17,
                    fontWeight: FontWeight.w600,
                    color: palette(context)['text.primary'],
                  ),
                ),
              ),
              Icon(
                granted ? LucideIcons.circleCheck : LucideIcons.circle,
                size: 18,
                color: granted
                    ? palette(context)['text.success']
                    : palette(context)['text.muted'],
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(detail),
          const SizedBox(height: 8),
          Text(
            fallback,
            style: TextStyle(
              fontSize: 13,
              height: 18 / 13,
              color: palette(context)['text.muted'],
            ),
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 12,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(
                permissions == null
                    ? '正在確認…'
                    : granted
                    ? '已開啟'
                    : '尚未開啟',
                key: Key('permission-status-$name'),
                style: TextStyle(
                  color: granted
                      ? palette(context)['text.success']
                      : palette(context)['text.secondary'],
                ),
              ),
              if (!granted)
                FilledButton.tonal(
                  style: FilledButton.styleFrom(
                    backgroundColor: palette(context)['accent.soft'],
                    foregroundColor: palette(context)['accent.onSoft'],
                  ),
                  key: Key('permission-$name'),
                  onPressed: busy || permissions == null
                      ? null
                      : () => request(method),
                  child: Text(
                    name == 'notifications' &&
                            permissions?['notificationSettings'] == true
                        ? '前往系統設定'
                        : '開啟$title',
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: palette(context)['surface.grouped'],
    appBar: AppBar(
      title: Text(firstRun ? '歡迎使用 pirc' : '權限與快速回應'),
      backgroundColor: palette(context)['surface.grouped'],
    ),
    body: SafeArea(
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              const SizedBox(height: 16),
              Text(
                firstRun ? '讓重要的回應找得到你' : '依照你的使用方式設定',
                style: TextStyle(
                  fontSize: 24,
                  height: 32 / 24,
                  fontWeight: FontWeight.w600,
                  color: palette(context)['text.primary'],
                ),
              ),
              const SizedBox(height: 12),
              const Text('開啟需要的權限，也可以稍後到設定調整。'),
              const SizedBox(height: 24),
              permissionCard(
                'notifications',
                '通知',
                '工作完成、執行失敗，或 agent 需要你回答時，顯示系統通知。',
                '未開啟時，仍可在 App 內查看工作與待處理問題。',
                LucideIcons.bell,
                'requestNotifications',
              ),
              const SizedBox(height: 16),
              permissionCard(
                'overlay',
                '快速回應浮窗',
                '允許顯示在其他 App 上層，讓你主動開啟小視窗回答問題。',
                '未開啟時，點通知即可回到完整對話。權限名稱為「顯示在其他應用程式上層」。',
                LucideIcons.panelsTopLeft,
                'requestOverlay',
              ),
              const SizedBox(height: 16),
              Text(
                '背景推播需在配對後，到「設定 → 推播與通知目標」完成服務註冊。系統權限開啟不代表推播服務已連線。',
                style: TextStyle(
                  fontSize: 13,
                  height: 18 / 13,
                  color: palette(context)['text.muted'],
                ),
              ),
              if (error != null) ...[
                const SizedBox(height: 16),
                Text(
                  error!,
                  style: TextStyle(color: palette(context)['status.danger']),
                ),
                TextButton(onPressed: refresh, child: const Text('重新確認權限')),
              ],
              const SizedBox(height: 24),
              if (firstRun)
                FinalButton(
                  key: const Key('finish-onboarding'),
                  onPressed: busy ? null : finish,
                  child: Text(
                    busy
                        ? '處理中…'
                        : permissions?['notifications'] == true &&
                              permissions?['overlay'] == true
                        ? '開始使用'
                        : '先開始使用，稍後設定',
                  ),
                ),
              const SizedBox(height: 16),
            ],
          ),
        ),
      ),
    ),
  );
}
