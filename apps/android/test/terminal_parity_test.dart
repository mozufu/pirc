import 'dart:async';
import 'dart:ui' show SemanticsAction, SemanticsRole, Tristate;
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart' show SemanticsNode;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_mobile/live/gateway.dart';
import 'package:pirc_mobile/l10n/app_i18n.dart';
import 'package:pirc_mobile/live/terminal_state.dart';
import 'package:pirc_mobile/live/terminal_pane.dart';
import 'package:xterm/xterm.dart';
import 'live_test.dart' show FakeGateway, theme;

Json terminalInfo(String id, {bool exited = false}) => {
  'id': id,
  'title': 'bash',
  'exited': exited,
  'exitCode': exited ? 7 : null,
  'cols': 80,
  'rows': 24,
};
const isolatedCaps = {
  'terminalCapabilities': {
    'version': 1,
    'enabled': true,
    'isolatedTerminalVersion': 1,
    'hostTerminalReviewVersion': 1,
    'workTerminalRequestVersion': 2,
  },
};
Json isolatedResult(dynamic requestId, Json terminal) => {
  'workRequest': {
    'version': 1,
    'requestId': requestId,
    'state': 'running',
    'errorCode': null,
    'terminalId': terminal['id'],
  },
  'terminal': terminal,
};
void frame(FakeGateway g, NativeTerminalSession s, Json message) =>
    g.stream.add({
      'type': 'socket',
      'data': {'tag': s.tag, 'frame': message},
    });
String contents(Terminal t) => List.generate(
  t.buffer.lines.length,
  (i) => t.buffer.lines[i].getText(),
).join('\n');
void main() {
  testWidgets('terminal list lease guards, removal and scope races', (t) async {
    final g = FakeGateway(), c = LiveController(g)..sessionId = 's';
    g.handler = (_, _) async => {
      'terminals': [terminalInfo('a'), terminalInfo('b', exited: true)],
    };
    c.clientId = 'phone';
    final s = TerminalPaneState(c);
    await t.pump();
    expect(s.current, 'b');
    await s.create();
    expect(s.error, contains('Take control'));
    expect(g.calls.where((x) => x.$2['method'] == 'POST'), isEmpty);
    await s.close(s.terminals.last);
    expect(s.current, 'a');
    c.control = {'held': true, 'generation': 8};
    c.changed();
    final pending = Completer<Json>();
    g.handler = (_, a) async => '${a['path']}'.endsWith('?capabilities=1')
        ? isolatedCaps
        : pending.future;
    final create = s.create();
    await s.create();
    await t.pump();
    expect(g.calls.where((x) => x.$2['method'] == 'POST').length, 1);
    final body = g.calls.last.$2['body'];
    expect(body['generation'], 8);
    expect(body['cols'], 80);
    expect(body['rows'], 24);
    expect(body['executionPath'], 'isolated_work');
    g.handler = (_, _) async => {'terminals': []};
    c.sessionId = 'next';
    c.changed();
    pending.complete(isolatedResult(body['requestId'], terminalInfo('late')));
    await create;
    await t.pump();
    expect(s.terminals, isEmpty);
    expect(s.busy, false);
    s.dispose();
    c.dispose();
    await g.stream.close();
  });
  for (final language in ['en', 'zh-TW']) {
    testWidgets('terminal close errors and not-found removal in $language', (
      t,
    ) async {
      AppI18n.instance.setLanguage(language);
      addTearDown(() => AppI18n.instance.setLanguage('en'));
      final g = FakeGateway();
      final c = LiveController(g)
        ..sessionId = 's'
        ..control = {'held': true, 'generation': 3};
      g.handler = (_, _) async => {
        'terminals': [terminalInfo('a'), terminalInfo('b')],
      };
      final s = TerminalPaneState(c);
      await t.pump();
      expect(s.current, 'b');
      g.handler = (_, _) async =>
          throw PlatformException(code: 'bad', message: 'Permission denied');
      await s.close(s.terminals.last);
      expect(s.terminals.map((v) => v['id']), ['a', 'b']);
      expect(s.current, 'b');
      expect(s.error, 'Permission denied');
      expect(s.closing, isEmpty);
      g.handler = (_, _) async =>
          throw PlatformException(code: '404', message: 'Terminal not found');
      await s.close(s.terminals.last);
      expect(s.terminals.map((v) => v['id']), ['a']);
      expect(s.current, 'a');
      expect(s.closing, isEmpty);
      s.dispose();
      c.dispose();
      await g.stream.close();
    });
  }
  testWidgets(
    'PTY replay resets ANSI state, control gates and debounced visible resize',
    (t) async {
      final g = FakeGateway(),
          c = LiveController(g)
            ..sessionId = 's'
            ..clientId = 'phone'
            ..control = {'held': true, 'generation': 2};
      g.handler = (_, _) async => null;
      int? exit;
      final s = NativeTerminalSession(
        c,
        terminalInfo('a'),
        onExit: (code) => exit = code,
      );
      s.setVisible(true);
      await t.pump();
      frame(g, s, {'type': 'ready', 'replay': '\x1b[31mred\x1b[0m\r\nhello'});
      await t.pump(const Duration(milliseconds: 60));
      s.terminal.resize(100, 30);
      s.terminal.resize(110, 35);
      await t.pump(const Duration(milliseconds: 60));
      final resize = g.calls
          .where(
            (x) => x.$1 == 'socketSend' && x.$2['data']['type'] == 'resize',
          )
          .toList();
      expect(resize.length, 2);
      expect(resize.last.$2['data']['cols'], 110);
      s.scheduleResize();
      await t.pump(const Duration(milliseconds: 60));
      expect(g.calls.where((x) => x.$1 == 'socketSend').length, 2);
      s.input('pwd\r');
      await t.pump();
      expect(g.calls.last.$2['data']['generation'], 2);
      c.control = {'held': false};
      c.changed();
      final count = g.calls.length;
      s.input('no');
      await t.pump();
      expect(g.calls.length, count);
      expect(s.notice, 'Take control of the session to type here.');
      c.control = {'held': true, 'generation': 4};
      c.changed();
      expect(s.notice, '');
      s.setVisible(false);
      s.terminal.resize(120, 40);
      await t.pump(const Duration(milliseconds: 60));
      expect(g.calls.length, count);
      s.setVisible(true);
      await t.pump(const Duration(milliseconds: 60));
      expect(g.calls.last.$2['data']['cols'], 120);
      final old = s.terminal;
      frame(g, s, {'type': 'ready', 'replay': 'new replay'});
      expect(identical(old, s.terminal), false);
      expect(contents(s.terminal), contains('new replay'));
      expect(contents(s.terminal), isNot(contains('hello')));
      frame(g, s, {'type': 'exit', 'exitCode': 7});
      expect(exit, 7);
      expect(contents(s.terminal), contains('[process exited with code 7]'));
      s.dispose();
      c.dispose();
      await g.stream.close();
      await t.pump();
    },
  );
  testWidgets('PTY reconnect backoff, stale tags, 4404 and app lifecycle', (
    t,
  ) async {
    final g = FakeGateway(), c = LiveController(g)..sessionId = 's';
    g.handler = (_, _) async => null;
    var exits = 0;
    final s = NativeTerminalSession(
      c,
      terminalInfo('a'),
      onExit: (_) => exits++,
    );
    await t.pump();
    final old = s.tag;
    g.stream.add({
      'type': 'socketClosed',
      'data': {'tag': old, 'code': 1006},
    });
    expect(s.notice, 'Reconnecting…');
    await t.pump(const Duration(milliseconds: 500));
    expect(s.tag, isNot(old));
    g.stream.add({
      'type': 'socket',
      'data': {
        'tag': old,
        'frame': {'type': 'output', 'data': 'stale'},
      },
    });
    expect(contents(s.terminal), isNot(contains('stale')));
    s.setForeground(false);
    final calls = g.calls.length;
    await t.pump(const Duration(seconds: 12));
    expect(g.calls.length, calls);
    s.setForeground(true);
    await t.pump();
    g.stream.add({
      'type': 'socketClosed',
      'data': {'tag': s.tag, 'code': 4404},
    });
    expect(s.exited, true);
    expect(exits, 1);
    expect(s.notice, 'This terminal no longer exists.');
    final last = g.calls.length;
    await t.pump(const Duration(seconds: 12));
    expect(g.calls.length, last);
    s.dispose();
    c.dispose();
    await g.stream.close();
    await t.pump();
  });
  for (final scale in [1.0, 2.0]) {
    testWidgets(
      'native terminal panel creation, tab keys and no full-screen route at $scale',
      (t) async {
        t.view.devicePixelRatio = 1;
        t.view.physicalSize = const Size(390, 700);
        addTearDown(t.view.reset);
        final g = FakeGateway(),
            c = LiveController(g)
              ..sessionId = 's'
              ..control = {'held': true, 'generation': 2};
        var next = 0;
        c.clientId = 'phone';
        g.handler = (method, a) async {
          if (method != 'request') return null;
          if ('${a['path']}'.endsWith('?capabilities=1')) return isolatedCaps;
          return a['method'] == 'POST'
              ? isolatedResult(
                  a['body']['requestId'],
                  terminalInfo('${++next}'),
                )
              : {'terminals': []};
        };
        await t.pumpWidget(
          MaterialApp(
            theme: theme.build(Brightness.light),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.linear(scale)),
              child: child!,
            ),
            home: Scaffold(body: TerminalPane(controller: c, touch: true)),
          ),
        );
        await t.pumpAndSettle();
        await t.tap(find.text('Open terminal'));
        await t.pumpAndSettle();
        expect(find.byType(TerminalView), findsOneWidget);
        expect(find.byType(AppBar), findsNothing);
        await t.tap(find.byTooltip('New terminal'));
        await t.pumpAndSettle();
        expect(find.text('bash 2'), findsOneWidget);
        final second = find.byKey(const ValueKey('terminal-tab-2'));
        t.widget<InkWell>(second).focusNode!.requestFocus();
        await t.pump();
        await t.sendKeyEvent(LogicalKeyboardKey.home);
        await t.pumpAndSettle();
        expect(
          t
              .widget<InkWell>(find.byKey(const ValueKey('terminal-tab-1')))
              .focusNode!
              .hasFocus,
          true,
        );
        await t.sendKeyEvent(LogicalKeyboardKey.delete);
        await t.pumpAndSettle();
        expect(find.byKey(const ValueKey('terminal-tab-1')), findsNothing);
        expect(g.calls.where((x) => x.$1 == 'control'), isEmpty);
        expect(t.takeException(), isNull);
        await t.pumpWidget(const SizedBox());
        c.dispose();
        await g.stream.close();
        await t.pump();
      },
    );
  }

  testWidgets(
    'terminal tabs, close buttons and PTY input expose Web semantics and keep lease guards',
    (t) async {
      t.view.devicePixelRatio = 1;
      t.view.physicalSize = const Size(390, 700);
      addTearDown(t.view.reset);
      final semantics = t.ensureSemantics();
      final g = FakeGateway(),
          c = LiveController(g)
            ..sessionId = 's'
            ..control = {'held': true, 'generation': 5};
      g.handler = (_, _) async => {
        'terminals': [terminalInfo('a'), terminalInfo('b')],
      };
      await t.pumpWidget(
        MaterialApp(
          theme: theme.build(Brightness.light),
          home: Scaffold(body: TerminalPane(controller: c, touch: true)),
        ),
      );
      await t.pumpAndSettle();

      final tabBar = t.getSemantics(find.bySemanticsLabel('Terminals'));
      expect(tabBar.getSemanticsData().role, SemanticsRole.tabBar);
      final tabs = <SemanticsNode>[];
      tabBar.visitChildren((node) {
        if (node.getSemanticsData().role == SemanticsRole.tab) tabs.add(node);
        return true;
      });
      expect(tabs, hasLength(2));
      expect(
        tabs.map((node) => node.getSemanticsData().label),
        containsAll(['bash 1', 'bash 2']),
      );
      expect(
        tabs.where(
          (node) =>
              node.getSemanticsData().flagsCollection.isSelected ==
              Tristate.isTrue,
        ),
        hasLength(1),
      );
      String selectedTabLabel() {
        final currentTabBar = t.getSemantics(
          find.bySemanticsLabel('Terminals'),
        );
        final selected = <String>[];
        currentTabBar.visitChildren((node) {
          final data = node.getSemanticsData();
          if (data.role == SemanticsRole.tab &&
              data.flagsCollection.isSelected == Tristate.isTrue) {
            selected.add(data.label);
          }
          return true;
        });
        expect(selected, hasLength(1));
        return selected.single;
      }

      expect(selectedTabLabel(), 'bash 2');
      t
          .widget<InkWell>(find.byKey(const ValueKey('terminal-tab-b')))
          .focusNode!
          .requestFocus();
      await t.pump();
      await t.sendKeyEvent(LogicalKeyboardKey.home);
      await t.pumpAndSettle();
      expect(selectedTabLabel(), 'bash 1');
      await t.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await t.pumpAndSettle();
      expect(selectedTabLabel(), 'bash 2');
      expect(
        t
            .widget<InkWell>(find.byKey(const ValueKey('terminal-tab-b')))
            .focusNode!
            .hasFocus,
        isTrue,
      );
      await t.sendKeyEvent(LogicalKeyboardKey.space);
      await t.pumpAndSettle();
      expect(selectedTabLabel(), 'bash 2');
      await t.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await t.pumpAndSettle();
      expect(selectedTabLabel(), 'bash 1');
      await t.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await t.pumpAndSettle();
      expect(selectedTabLabel(), 'bash 2');
      await t.sendKeyEvent(LogicalKeyboardKey.home);
      await t.pumpAndSettle();
      expect(selectedTabLabel(), 'bash 1');
      final close = t
          .getSemantics(find.bySemanticsLabel('Close terminal 1'))
          .getSemanticsData();
      expect(close.flagsCollection.isButton, isTrue);
      expect(close.hasAction(SemanticsAction.tap), isTrue);

      final input = t
          .getSemantics(find.bySemanticsLabel('Terminal input'))
          .getSemanticsData();
      expect(input.flagsCollection.isTextField, isTrue);
      expect(input.flagsCollection.isEnabled, Tristate.isTrue);
      expect(input.hasAction(SemanticsAction.tap), isTrue);

      await t.tap(find.bySemanticsLabel('Close terminal 1'));
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('terminal-tab-a')), findsNothing);
      expect(find.byKey(const ValueKey('terminal-tab-b')), findsOneWidget);

      c.control = {'held': false};
      c.changed();
      await t.pumpAndSettle();
      expect(
        t
            .getSemantics(find.bySemanticsLabel('Terminal input'))
            .getSemanticsData()
            .flagsCollection
            .isEnabled,
        Tristate.isTrue,
        reason:
            'the terminal input stays enabled; the gateway rejects writes without the lease',
      );
      final closesBefore = g.calls
          .where(
            (call) =>
                call.$1 == 'request' &&
                '${call.$2['path']}'.endsWith('/terminals/b/close'),
          )
          .length;
      await t.tap(find.bySemanticsLabel('Close terminal 1'));
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('terminal-tab-b')), findsOneWidget);
      expect(
        g.calls
            .where(
              (call) =>
                  call.$1 == 'request' &&
                  '${call.$2['path']}'.endsWith('/terminals/b/close'),
            )
            .length,
        closesBefore,
      );
      expect(
        find.text('Take control of the session to close a terminal.'),
        findsOneWidget,
      );
      final newTerminal = t
          .getSemantics(find.byTooltip('Take control to open a terminal'))
          .getSemanticsData();
      expect(newTerminal.flagsCollection.isEnabled, Tristate.isFalse);

      await t.pumpWidget(const SizedBox());
      semantics.dispose();
      c.dispose();
      await g.stream.close();
      await t.pump();
    },
  );
}
