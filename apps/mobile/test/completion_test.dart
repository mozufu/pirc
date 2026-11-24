import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_mobile/live/app.dart';
import 'package:pirc_mobile/live/gateway.dart';
import 'package:pirc_mobile/live/interaction.dart';
import 'package:pirc_mobile/live/settings.dart';
import 'live_test.dart' show FakeGateway, theme;

class CompleteGateway extends FakeGateway {
  Json prefs = {'q': true, 'quiet': false, 'lock': 'hide', 'muted': <String>[]};
  @override
  dynamic normal(String method, Json args) {
    if (method == 'preferences') return prefs;
    if (method == 'savePreferences') return prefs = {...prefs, ...args};
    if (method == 'permissions') {
      return {'notifications': true, 'overlay': true};
    }
    if (method == 'pushStatus') {
      return {
        'state': '已啟用',
        'distributors': ['test'],
      };
    }
    if (method == 'fileLink') return {'path': args['href']};
    if (method == 'request') {
      final path = '${args['path']}';
      if (path.contains('/files?')) {
        return {
          'entries': [
            {'name': 'src', 'kind': 'dir'},
            {'name': 'readme.md', 'kind': 'file'},
          ],
        };
      }
      if (path.contains('/files/content')) return {'content': '# 閱讀檔案\n\n內容'};
      if (path.endsWith('/git/status')) {
        return {'repo': true, 'branch': 'main', 'files': []};
      }
      if (path.endsWith('/panel/state')) {
        return {
          'memory': {'enabled': true},
          'team': {},
        };
      }
    }
    return super.normal(method, args);
  }
}

void main() {
  testWidgets(
    'notification preferences persist and lock selection changes native preferences',
    (t) async {
      final g = CompleteGateway();
      final c = LiveController(g);
      await t.pumpWidget(
        MaterialApp(
          theme: theme.build(Brightness.light),
          home: Scaffold(body: PushSettings(controller: c)),
        ),
      );
      await t.pumpAndSettle();
      await t.tap(find.text('需要你回應'));
      await t.pumpAndSettle();
      expect(g.prefs['q'], false);
      await t.scrollUntilVisible(
        find.text('只顯示標題'),
        300,
        scrollable: find.byType(Scrollable).first,
      );
      await t.ensureVisible(find.text('只顯示標題'));
      await t.pumpAndSettle();
      await t.tap(find.text('只顯示標題'));
      await t.pumpAndSettle();
      expect(g.prefs['lock'], 'summary');
      await t.pumpWidget(const SizedBox());
      c.dispose();
      await g.stream.close();
    },
  );
  testWidgets(
    'file position survives panel changes, close, and phone/tablet resize',
    (t) async {
      t.view.devicePixelRatio = 1;
      t.view.physicalSize = const Size(1024, 900);
      addTearDown(t.view.reset);
      final g = CompleteGateway();
      final c = LiveController(g);
      await t.pumpWidget(MobileApp(theme: theme, controller: c));
      await t.pumpAndSettle();
      await c.open('s');
      g.publish('s');
      await t.pumpAndSettle();
      await t.tap(find.byTooltip('工作面板'));
      await t.pumpAndSettle();
      await t.tap(find.text('檔案').last);
      await t.pumpAndSettle();
      await t.tap(find.widgetWithText(ListTile, 'readme.md'));
      await t.pumpAndSettle();
      expect(find.text('閱讀檔案'), findsOneWidget);
      await t.tap(find.text('Git').last);
      await t.pumpAndSettle();
      await t.tap(find.text('檔案').last);
      await t.pumpAndSettle();
      expect(find.text('閱讀檔案'), findsOneWidget);
      t.view.physicalSize = const Size(390, 844);
      await t.pumpAndSettle();
      expect(find.text('閱讀檔案'), findsOneWidget);
      await t.tap(find.byTooltip('返回對話'));
      await t.pumpAndSettle();
      await t.tap(find.byTooltip('工作面板'));
      await t.pumpAndSettle();
      await t.tap(find.text('檔案').last);
      await t.pumpAndSettle();
      expect(find.text('閱讀檔案'), findsOneWidget);
      expect(t.takeException(), isNull);
      await t.pumpWidget(const SizedBox());
      await g.stream.close();
    },
  );
  testWidgets(
    'notification choice remains unsent and control denial blocks submission',
    (t) async {
      final g = CompleteGateway();
      final c = LiveController(g)..sessionId = 's';
      final q = <String, dynamic>{
        'id': 'q',
        'epoch': 'e',
        'kind': 'select',
        'title': '選擇',
        'status': 'pending',
        'options': [
          {'value': 'one', 'label': '第一個'},
        ],
      };
      g.snapshot['interactions'] = [q];
      g.handler = (m, a) async =>
          m == 'control' ? {'held': false} : g.normal(m, a);
      await t.pumpWidget(
        MaterialApp(
          theme: theme.build(Brightness.light),
          home: Scaffold(
            body: QuestionSheet(
              controller: c,
              question: q,
              initialChoice: 'one',
            ),
          ),
        ),
      );
      await t.pumpAndSettle();
      expect(g.calls.where((x) => x.$1 == 'answer'), isEmpty);
      expect(
        t
            .widget<FilledButton>(find.widgetWithText(FilledButton, '送出答案'))
            .onPressed,
        isNull,
      );
      expect(find.text('取得控制權'), findsOneWidget);
      await t.pumpWidget(const SizedBox());
      c.dispose();
      await g.stream.close();
    },
  );
  testWidgets(
    'notification without an id resolves current question and drops stale choice',
    (t) async {
      final g = CompleteGateway();
      final c = LiveController(g)..sessionId = 's';
      g.snapshot['interactions'] = [
        {
          'id': 'latest',
          'epoch': 'e',
          'kind': 'select',
          'title': '最新問題',
          'status': 'pending',
          'options': [
            {'value': 'new', 'label': '新選項'},
          ],
        },
      ];
      await t.pumpWidget(
        MaterialApp(
          theme: theme.build(Brightness.light),
          home: Scaffold(
            body: QuestionSheet(
              controller: c,
              question: const {'title': '確認通知'},
              initialChoice: 'old',
            ),
          ),
        ),
      );
      await t.pumpAndSettle();
      expect(find.text('最新問題'), findsOneWidget);
      expect(
        t
            .widget<FilledButton>(find.widgetWithText(FilledButton, '送出答案'))
            .onPressed,
        isNull,
      );
      expect(g.calls.where((x) => x.$1 == 'answer'), isEmpty);
      await t.pumpWidget(const SizedBox());
      c.dispose();
      await g.stream.close();
    },
  );
  for (final width in [390.0, 600.0, 768.0, 1024.0]) {
    for (final brightness in Brightness.values) {
      testWidgets(
        'all six work panes at $width ${brightness.name}, large text',
        (t) async {
          t.view.devicePixelRatio = 1;
          t.view.physicalSize = Size(width, 1024);
          addTearDown(t.view.reset);
          t.platformDispatcher.textScaleFactorTestValue = 2;
          addTearDown(t.platformDispatcher.clearTextScaleFactorTestValue);
          t.platformDispatcher.platformBrightnessTestValue = brightness;
          addTearDown(t.platformDispatcher.clearPlatformBrightnessTestValue);
          final g = CompleteGateway();
          final c = LiveController(g);
          await t.pumpWidget(MobileApp(theme: theme, controller: c));
          await t.pumpAndSettle();
          await c.open('s');
          g.publish('s');
          await t.pumpAndSettle();
          await t.tap(find.byTooltip('工作面板'));
          await t.pumpAndSettle();
          for (final label in ['檔案', 'Git', '終端', 'Tasks', '記憶', '瀏覽器']) {
            await t.tap(find.text(label).last);
            await t.pumpAndSettle();
            expect(t.takeException(), isNull, reason: label);
          }
          await t.pumpWidget(const SizedBox());
          await g.stream.close();
        },
      );
    }
  }
}
