import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_mobile/live/app.dart';
import 'package:pirc_mobile/live/gateway.dart';
import 'package:pirc_mobile/live/interaction.dart';
import 'package:pirc_mobile/live/settings.dart';
import 'package:pirc_mobile/theme.dart';

class FakeGateway extends Gateway {
  final stream = StreamController<Json>.broadcast(sync: true);
  @override
  Stream<Json> get events => stream.stream;
  final calls = <(String, Json)>[];
  final drafts = <String, String>{};
  Json snapshot = {
    'session': {'id': 's', 'name': '測試對話', 'workspaceId': 'w'},
    'runnerEpoch': 'e',
    'messages': [
      {
        'id': 'm',
        'role': 'assistant',
        'content': '# 測試成果\n\n${List.filled(30, '這是閱讀內容。\n\n').join()}',
      },
    ],
    'interactions': [],
    'widgets': {},
    'queue': [],
  };
  Future<dynamic> Function(String, Json)? handler;
  bool unknown = false;
  @override
  Future<dynamic> call(String method, [Json args = const {}]) async {
    calls.add((method, args));
    if (handler != null) return handler!(method, args);
    return normal(method, args);
  }

  dynamic normal(String method, Json args) {
    switch (method) {
      case 'boot':
        return {'origin': 'https://gateway.example', 'clientId': 'phone'};
      case 'watch':
        return drafts[args['sessionId']] ?? '';
      case 'draft':
        drafts['${args['sessionId']}'] = '${args['text']}';
        return null;
      case 'commandStatus':
        return unknown;
      case 'acknowledgeCommand':
        unknown = false;
        return null;
      case 'refresh':
        return snapshot;
      case 'control':
        return {'held': true, 'generation': 3};
      case 'command':
        return {'status': 'accepted'};
      case 'wallInput':
        return '2026-10-01T09:00';
      case 'request':
        final path = args['path'];
        if (path == '/api/sessions') {
          return {
            'sessions': [snapshot['session']],
          };
        }
        if (path == '/api/workspaces') {
          return {
            'workspaces': [
              {'id': 'w', 'displayName': '工作目錄', 'kind': 'directory'},
            ],
          };
        }
        if (path == '/api/nodes') return {'nodes': []};
        if ('$path'.startsWith('/api/models')) {
          return {
            'models': [
              {'id': 'm1', 'provider': 'p', 'name': '模型一'},
            ],
          };
        }
        return <String, dynamic>{};
      default:
        return null;
    }
  }

  void publish(String id, {String? text}) {
    stream.add({
      'type': 'snapshot',
      'sessionId': id,
      'data': {
        ...snapshot,
        if (text != null)
          'messages': [
            {'id': 'm', 'role': 'assistant', 'content': text},
          ],
      },
    });
    stream.add({
      'type': 'control',
      'sessionId': id,
      'data': {'held': true, 'generation': 3},
    });
    stream.add({'type': 'connection', 'sessionId': id, 'data': 'live'});
  }
}

final theme = PircTheme(
  jsonDecode(File('assets/design-tokens.json').readAsStringSync()),
);
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'ignores late events from another session and saves each draft separately',
    () async {
      final g = FakeGateway();
      final c = LiveController(g);
      await c.boot();
      await c.open('one');
      g.publish('one');
      c.editDraft('第一段');
      await c.open('two');
      g.publish('two', text: '第二個對話');
      g.publish('one', text: '不應顯示');
      expect(c.messages.single['content'], '第二個對話');
      expect(g.drafts['one'], '第一段');
      expect(c.draft, '');
      c.dispose();
      await g.stream.close();
    },
  );
  test(
    'unknown command stays blocked across reselect; acknowledgement never resends',
    () async {
      final g = FakeGateway()..unknown = true;
      final c = LiveController(g);
      await c.boot();
      await c.open('s');
      g.publish('s');
      c.editDraft('操作');
      await c.send('prompt');
      expect(g.calls.where((x) => x.$1 == 'command'), isEmpty);
      await c.open('s');
      expect(c.unknownCommand, isTrue);
      await c.acknowledgeCommand();
      expect(c.unknownCommand, isFalse);
      expect(g.calls.where((x) => x.$1 == 'command'), isEmpty);
      c.dispose();
      await g.stream.close();
    },
  );
  test('network uncertainty keeps draft and does not auto retry', () async {
    final g = FakeGateway();
    final c = LiveController(g);
    await c.boot();
    await c.open('s');
    g.publish('s');
    c.editDraft('保留');
    g.handler = (m, a) async {
      if (m == 'command') throw PlatformException(code: 'NETWORK');
      return g.normal(m, a);
    };
    await c.send('prompt');
    await c.refreshSession();
    await c.send('prompt');
    expect(c.draft, '保留');
    expect(c.unknownCommand, isTrue);
    expect(g.calls.where((x) => x.$1 == 'command').length, 1);
    c.dispose();
    await g.stream.close();
  });
  test('accepted old-session command cannot erase new-session draft', () async {
    final g = FakeGateway();
    final c = LiveController(g);
    final receipt = Completer<Json>();
    await c.boot();
    await c.open('s');
    g.publish('s');
    c.editDraft('原始訊息');
    g.handler = (m, a) async =>
        m == 'command' ? receipt.future : g.normal(m, a);
    final sending = c.send('prompt');
    await c.open('second');
    c.editDraft('新對話草稿');
    receipt.complete({'status': 'accepted'});
    await sending;
    expect(c.draft, '新對話草稿');
    c.dispose();
    await g.stream.close();
  });
  test('read-only and disconnected clients cannot send commands', () async {
    final g = FakeGateway();
    final c = LiveController(g);
    await c.boot();
    await c.open('s');
    c.editDraft('不能送');
    await c.send('prompt');
    g.publish('s');
    c.control = {'held': false};
    await c.sendCommand({'type': 'stop'});
    expect(g.calls.where((x) => x.$1 == 'command'), isEmpty);
    c.dispose();
    await g.stream.close();
  });
  for (final width in [390.0, 507.0, 600.0, 768.0, 840.0, 1024.0]) {
    testWidgets('live $width width, 2x text, keyboard and long widget fit', (
      tester,
    ) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = Size(width, 1000);
      tester.view.viewInsets = const FakeViewPadding(bottom: 300);
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.view.reset);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final g = FakeGateway();
      final c = LiveController(g);
      g.snapshot['widgets'] = {'goal': List.filled(20, '處理目標中')};
      await tester.pumpWidget(MobileApp(theme: theme, controller: c));
      await tester.pumpAndSettle();
      await c.open('s');
      g.publish('s');
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('live-draft')), '測試中文草稿');
      await tester.pump(const Duration(milliseconds: 300));
      expect(tester.takeException(), isNull);
      expect(
        tester.getRect(find.byKey(const Key('live-draft'))).bottom,
        lessThanOrEqualTo(700),
      );
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      await g.stream.close();
    });
  }
  testWidgets(
    'live reader keeps version and scroll across resize and reopening',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1024, 900);
      addTearDown(tester.view.reset);
      final g = FakeGateway();
      final c = LiveController(g);
      await tester.pumpWidget(MobileApp(theme: theme, controller: c));
      await tester.pumpAndSettle();
      await c.open('s');
      g.publish('s');
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('live-draft')), '草稿不變');
      await tester.ensureVisible(find.text('開啟閱讀'));
      await tester.tap(find.text('開啟閱讀'));
      await tester.pumpAndSettle();
      final reader = find.byKey(const Key('live-reader'));
      await tester.drag(reader, const Offset(0, -250));
      await tester.pumpAndSettle();
      final offset = tester.widget<ListView>(reader).controller!.offset;
      expect(offset, greaterThan(0));
      tester.view.physicalSize = const Size(390, 844);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(tester.widget<ListView>(reader).controller!.offset, offset);
      g.publish('s', text: '# 新版完成\n\n新版內容');
      await tester.pumpAndSettle();
      expect(find.text('測試成果 · v1'), findsOneWidget);
      expect(find.text('已有 v2 · 切換新版'), findsOneWidget);
      await tester.tap(find.byTooltip('返回對話'));
      await tester.pumpAndSettle();
      expect(find.text('草稿不變'), findsOneWidget);
      await tester.ensureVisible(find.text('開啟閱讀'));
      await tester.tap(find.text('開啟閱讀'));
      await tester.pumpAndSettle();
      expect(find.text('測試成果 · v1'), findsOneWidget);
      expect(tester.widget<ListView>(reader).controller!.offset, offset);
      await tester.tap(find.text('已有 v2 · 切換新版'));
      await tester.pumpAndSettle();
      expect(find.text('新版完成 · v2'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      await g.stream.close();
    },
  );
  testWidgets('answered question refresh removes submission choices', (
    tester,
  ) async {
    final g = FakeGateway();
    final c = LiveController(g)..sessionId = 's';
    final q = {
      'id': 'q',
      'epoch': 'e',
      'kind': 'confirm',
      'title': '確定？',
      'status': 'answered',
    };
    g.snapshot['interactions'] = [q];
    await tester.pumpWidget(
      MaterialApp(
        theme: theme.build(Brightness.light),
        home: Scaffold(
          body: QuestionSheet(controller: c, question: q),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('這個問題已處理或不再有效'), findsOneWidget);
    expect(find.text('送出答案'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    c.dispose();
    await g.stream.close();
  });
  testWidgets('editing one-off schedule preserves wall time and model', (
    tester,
  ) async {
    final g = FakeGateway();
    final c = LiveController(g)
      ..workspaces = [
        {'id': 'w', 'displayName': '目錄'},
      ];
    await tester.pumpWidget(
      MaterialApp(
        theme: theme.build(Brightness.light),
        home: ScheduleEditor(
          controller: c,
          timezone: 'Asia/Taipei',
          existing: {
            'id': 'job',
            'workspaceId': 'w',
            'title': '工作',
            'prompt': '執行',
            'runAt': 1790816400000,
            'cron': null,
            'model': {'provider': 'p', 'id': 'm1'},
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value,
      isTrue,
    );
    expect(
      find.byWidgetPredicate(
        (w) => w is TextField && w.controller?.text == '2026-10-01T09:00',
      ),
      findsOneWidget,
    );
    await tester.scrollUntilVisible(
      find.text('儲存'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('儲存'));
    await tester.pumpAndSettle();
    final body = obj(
      g.calls
          .lastWhere((x) => x.$1 == 'request' && x.$2['method'] == 'PATCH')
          .$2['body'],
    );
    expect(body['at'], '2026-10-01T09:00');
    expect(body.containsKey('cron'), isFalse);
    expect(body['model'], {'provider': 'p', 'id': 'm1'});
    await tester.pumpWidget(const SizedBox());
    c.dispose();
    await g.stream.close();
  });
}
