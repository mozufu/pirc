// Optional render check: flutter test tool/capture_ui_test.dart --dart-define=PIRC_REVIEW_FONT=/path/to/CJK-font.ttf
import 'dart:io';
import 'dart:convert';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_mobile/live/app.dart';
import 'package:pirc_mobile/live/gateway.dart';
import 'package:pirc_mobile/live/common.dart';
import 'package:pirc_mobile/live/settings.dart';
import 'package:pirc_mobile/live/artifacts.dart';
import 'package:pirc_mobile/live/panels.dart';
import '../test/live_test.dart' show theme, FakeGateway;
import '../test/completion_test.dart' show CompleteGateway;
import '../test/permissions_test.dart' show PermissionGateway;

void main() {
  for (final brightness in Brightness.values) {
    for (final screen in [
      'permissions',
      'pairing',
      'schedule',
      'error',
      'home',
      'session',
      'settings',
      'panel',
      'model',
      'question',
      'files',
      'terminals',
      'tasks',
      'memory',
      'browser',
      'reader',
      'notifications',
      'activity',
      'sidebar',
      'artifact',
      'terminalFull',
    ]) {
      testWidgets('render $screen ${brightness.name}', (t) async {
        await t.runAsync(() async {
          final manifest =
              jsonDecode(await rootBundle.loadString('FontManifest.json'))
                  as List;
          for (final entry in manifest) {
            final loader = FontLoader(entry['family'] as String);
            for (final font in entry['fonts'] as List) {
              loader.addFont(rootBundle.load(font['asset'] as String));
            }
            await loader.load();
          }
        });
        const font = String.fromEnvironment('PIRC_REVIEW_FONT');
        if (font.isNotEmpty) {
          await t.runAsync(() async {
            for (final family in ['Roboto', 'Ahem', 'monospace']) {
              final loader = FontLoader(family)
                ..addFont(File(font).readAsBytes().then(ByteData.sublistView));
              await loader.load();
            }
          });
        }
        t.view.devicePixelRatio = 1;
        final width = double.parse(
          const String.fromEnvironment(
            'PIRC_REVIEW_WIDTH',
            defaultValue: '390',
          ),
        );
        t.view.physicalSize = Size(width, width >= 600 ? 900 : 844);
        addTearDown(t.view.reset);
        t.platformDispatcher.platformBrightnessTestValue = brightness;
        addTearDown(t.platformDispatcher.clearPlatformBrightnessTestValue);
        final live = [
          'home',
          'session',
          'settings',
          'panel',
          'model',
          'question',
          'files',
          'terminals',
          'tasks',
          'memory',
          'browser',
          'reader',
          'notifications',
          'activity',
          'sidebar',
          'artifact',
          'terminalFull',
        ].contains(screen);
        final FakeGateway g = live
            ? CompleteGateway()
            : (PermissionGateway()..complete = screen != 'permissions');
        final c = LiveController(g)
          ..workspaces = [
            {'id': 'w', 'displayName': '我的專案'},
          ];
        final key = GlobalKey();
        final Widget child = screen == 'schedule'
            ? MaterialApp(
                debugShowCheckedModeBanner: false,
                theme: theme.build(brightness),
                home: ScheduleEditor(controller: c, timezone: 'Asia/Taipei'),
              )
            : screen == 'error'
            ? MaterialApp(
                debugShowCheckedModeBanner: false,
                theme: theme.build(brightness),
                home: Scaffold(
                  appBar: AppBar(title: const Text('排程')),
                  body: SupportingState(
                    title: '暫時無法載入',
                    detail: '連線已中斷，請確認網路後再試一次。',
                    onRetry: () {},
                  ),
                ),
              )
            : MobileApp(theme: theme, controller: c);
        await t.pumpWidget(RepaintBoundary(key: key, child: child));
        await t.pumpAndSettle();
        if ([
          'session',
          'panel',
          'question',
          'files',
          'terminals',
          'tasks',
          'memory',
          'browser',
          'reader',
        ].contains(screen)) {
          await c.open('s');
          g.snapshot['messages'] = [
            {
              'id': 'u',
              'role': 'user',
              'content': '檢查昨晚的 nightly test，失敗的話先分析原因。',
            },
            {
              'id': 'm',
              'role': 'assistant',
              'content': screen == 'reader'
                  ? '# Nightly 測試報告\n\n## 結果摘要\n\n本輪測試完成，失敗案例集中在登入流程。\n\n| 測試 | 結果 |\n| --- | --- |\n| 登入 | 需修復 |\n| 權限 | 通過 |\n\n## 後續步驟\n\n1. 修正鍵盤遮擋\n2. 重新驗證登入'
                  : '我先執行 nightly 測試並讀取報告。',
              'tools': [
                {
                  'id': 't',
                  'name': 'pnpm test:nightly',
                  'status': 'completed',
                  'output': '212 passed · 3 failed',
                },
              ],
            },
          ];
          if (screen == 'question') {
            g.snapshot['interactions'] = [
              {
                'id': 'q',
                'epoch': 'e',
                'kind': 'select',
                'status': 'pending',
                'title': '是否只重新執行失敗案例？',
                'description': '只重跑約 4 分鐘；全部重跑約 38 分鐘，會占用 CI-runner。',
                'options': [
                  {'value': 'one', 'label': '只重跑失敗的 3 個案例'},
                  {'value': 'all', 'label': '全部重跑'},
                  {'value': 'report', 'label': '先不要重跑，只給我報告'},
                ],
              },
            ];
          }
          g.publish('s');
          await t.pumpAndSettle();
          if (screen == 'panel') {
            await t.tap(find.byTooltip('工作面板'));
            await t.pumpAndSettle();
          }
        }
        if (screen == 'model') {
          await t.tap(find.text('預設模型'));
          await t.pumpAndSettle();
        }
        if (screen == 'settings') {
          await t.tap(find.byTooltip('側欄'));
          await t.pumpAndSettle();
          await t.tap(find.text('設定').last);
          await t.pumpAndSettle();
        }
        if ([
          'files',
          'terminals',
          'tasks',
          'memory',
          'browser',
        ].contains(screen)) {
          await t.tap(find.byTooltip('工作面板'));
          await t.pumpAndSettle();
          await t.tap(
            find
                .text(
                  {
                    'files': '檔案',
                    'terminals': '終端',
                    'tasks': 'Tasks',
                    'memory': '記憶',
                    'browser': '瀏覽器',
                  }[screen]!,
                )
                .last,
          );
          await t.pumpAndSettle();
        }
        if (screen == 'reader') {
          await t.ensureVisible(find.text('開啟閱讀'));
          await t.tap(find.text('開啟閱讀'));
          await t.pumpAndSettle();
        }
        if (screen == 'notifications') {
          Navigator.of(t.element(find.byType(LiveShell))).push(
            MaterialPageRoute<void>(
              builder: (_) => Scaffold(
                appBar: AppBar(title: const Text('通知')),
                body: PushSettings(controller: c),
              ),
            ),
          );
          await t.pumpAndSettle();
        }
        if (screen == 'activity') {
          await t.tap(find.byTooltip('待處理與動態'));
          await t.pumpAndSettle();
        }
        if (screen == 'sidebar') {
          await t.tap(find.byTooltip('側欄'));
          await t.pumpAndSettle();
        }
        if (screen == 'artifact' || screen == 'terminalFull') {
          await c.open('s');
          g.publish('s');
          await t.pumpAndSettle();
          final a = Artifact({
            'id': 'report',
            'version': 1,
            'title': 'Nightly 測試報告',
            'type': 'markdown',
            'summary': '本輪測試已完成',
            'content':
                '## 結果摘要\n\n212 項通過，3 項需要修正。\n\n| 項目 | 結果 |\n| --- | --- |\n| 登入 | 需修復 |\n| 權限 | 通過 |',
          }, 'm');
          Navigator.of(t.element(find.byType(LiveShell))).push(
            MaterialPageRoute<void>(
              builder: (_) => screen == 'artifact'
                  ? Scaffold(
                      appBar: AppBar(title: const Text('成果')),
                      body: ArtifactPane(controller: c, initial: a),
                    )
                  : TerminalPage(
                      controller: c,
                      terminal: const {'id': 't', 'title': 'fish'},
                    ),
            ),
          );
          await t.pumpAndSettle();
          if (screen == 'terminalFull') {
            final tag = g.calls
                .lastWhere((x) => x.$1 == 'socketOpen')
                .$2['tag'];
            g.stream.add({
              'type': 'socket',
              'data': {
                'tag': tag,
                'frame': {
                  'type': 'ready',
                  'replay':
                      'pirc ~/workspace % bun test\r\n\u001b[32m✓ 212 passed\u001b[0m\r\n3 failed\r\npirc ~/workspace % ',
                },
              },
            });
            await t.pump(const Duration(milliseconds: 100));
          }
        }
        expect(t.takeException(), isNull);
        await t.runAsync(() async {
          final boundary =
              key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
          final capture = await boundary.toImage(pixelRatio: 1);
          final data = await capture.toByteData(format: ui.ImageByteFormat.png);
          final dir = Directory('build/ui-review')..createSync(recursive: true);
          File(
            '${dir.path}/$screen-${brightness.name}-${width.toInt()}.png',
          ).writeAsBytesSync(data!.buffer.asUint8List());
          capture.dispose();
        });
        await t.pumpWidget(const SizedBox());
        await t.pump();
        if (screen == 'schedule' || screen == 'error') c.dispose();
        await g.stream.close();
      });
    }
  }
}
