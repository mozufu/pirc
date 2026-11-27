import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_app/src/connection/storage.dart';
import 'package:pirc_app/src/format.dart';
import 'package:pirc_app/src/preferences.dart';
import 'package:pirc_app/src/work/work_data.dart';
import 'package:pirc_client/pirc_client.dart';
import 'package:pirc_ui/pirc_ui.dart';

import 'support/fonts.dart';
import 'support/harness.dart';
import 'support/work_fixtures.dart';

WorkList _build(
  WorkFixture f, [
  WorkFilter filter = WorkFilter.all,
  String q = '',
]) => buildWorkList(
  sessions: f.parsedSessions,
  workspaces: f.parsedWorkspaces,
  works: f.parsedWorks,
  pots: f.parsedPots,
  approvals: f.parsedApprovals,
  filter: filter,
  query: q,
);

List<String> _titles(WorkList list) => [
  for (final group in list.groups)
    for (final item in group.items) item.title,
];

Future<FakeGateway> _pumpWork(
  WidgetTester tester, {
  WorkFixture? fixture,
  double width = 375,
}) async {
  final gateway = (fixture ?? WorkFixture()).install();
  await pumpApp(
    tester,
    gateway: gateway,
    width: width,
    location: '/work',
    overrides: [clockProvider.overrideWithValue(() => fixedNow)],
  );
  return gateway;
}

void _placeholderNameTests() {
  testWidgets('a new session\'s placeholder name is in the app\'s language', (
    tester,
  ) async {
    final fixture = WorkFixture();
    fixture.sessions.add(
      sessionJson(
        's-new',
        placeholderSessionName,
        pinned: true,
        updatedAt: fixedNow.millisecondsSinceEpoch,
      ),
    );
    await pumpApp(
      tester,
      gateway: fixture.install(),
      width: 375,
      location: '/work',
      saved: Saved(
        prefs: {
          PrefKeys.gatewayUrl: 'https://gateway.test/',
          PrefKeys.language: 'zh-TW',
        },
      ),
      overrides: [clockProvider.overrideWithValue(() => fixedNow)],
    );
    expect(find.textContaining('新對話', findRichText: true), findsOneWidget);
    expect(
      find.textContaining(placeholderSessionName, findRichText: true),
      findsNothing,
    );
  });
}

Future<void> _openActions(WidgetTester tester, String title) async {
  await tester.longPress(find.textContaining(title, findRichText: true));
  await tester.pumpAndSettle();
}

/// The second line of a row: `host · <symbol> state`.
Finder _stateLine(String host, String state) => find.textContaining(
  RegExp('^${RegExp.escape(host)} · \uFFFC ${RegExp.escape(state)}\$'),
  findRichText: true,
);

Future<void> _chip(WidgetTester tester, String label) async {
  final chip = find.descendant(
    of: find.byType(FilterChips<WorkFilter>),
    matching: find.text(label),
  );
  await tester.dragUntilVisible(
    chip,
    find.byType(FilterChips<WorkFilter>),
    const Offset(-80, 0),
  );
  await tester.tap(chip);
  await tester.pumpAndSettle();
}

void main() {
  _placeholderNameTests();
  group('the list', () {
    test('rows are grouped by project, newest group first; '
        'unknown projects are "No project", last', () {
      final list = _build(WorkFixture());
      expect(
        [for (final g in list.groups) g.workspaceId],
        ['laptop:pirc', 'ci:pirc', 'laptop:travel', null],
      );
      expect(
        [for (final g in list.groups) g.name],
        ['pirc mobile', 'pirc mobile', 'Travel', null],
      );
    });

    test('pinned first, then newest; settled last', () {
      final fixture = WorkFixture()
        ..sessions.add(
          sessionJson(
            's-old',
            'Old and settled',
            settled: true,
            updatedAt: at(10, 59),
          ),
        );
      final group = _build(fixture).groups.first;
      expect(
        [for (final item in group.items) item.title],
        [
          'Flutter tablet layouts',
          'Compare three API specs',
          'Fix the login keyboard',
          'Old and settled',
        ],
      );
    });

    test('each filter keeps its rows', () {
      final f = WorkFixture();
      expect(_titles(_build(f, WorkFilter.needsYou)), [
        'Compare three API specs',
        'Check the nightly test',
      ]);
      expect(_titles(_build(f, WorkFilter.running)), [
        'Add iPad keyboard tests',
        'Fix the login keyboard',
      ]);
      expect(_titles(_build(f, WorkFilter.mine)), [
        'Flutter tablet layouts',
        'Fix the login keyboard',
        'Weekend trip budget',
      ]);
      expect(_titles(_build(f, WorkFilter.pots)), [
        'Compare three API specs',
        'Check the nightly test',
        'Add iPad keyboard tests',
      ]);
      expect(_build(f).needsYou, 2);
      expect(_build(f, WorkFilter.running).needsYou, 2, reason: 'all rows');
    });

    test('who started a row: a pot work, a schedule or the user', () {
      final items = {
        for (final g in _build(WorkFixture()).groups)
          for (final i in g.items) i.title: i,
      };
      final nightly = items['Check the nightly test']! as SessionItem;
      expect((nightly.source as FromPot).potName, 'Tester');
      final daily = items['Morning test run']! as SessionItem;
      expect((daily.source as FromSchedule).title, 'Every morning');
      expect(daily.mine, isFalse, reason: 'a schedule is not "Mine"');
      expect((items['Fix the login keyboard']! as SessionItem).mine, isTrue);
      final approval = items['Compare three API specs']! as ApprovalItem;
      expect(approval.potName, 'Butler');
    });

    test('search matches names and project names on the device', () {
      final f = WorkFixture();
      expect(_titles(_build(f, WorkFilter.all, 'IPAD')), [
        'Add iPad keyboard tests',
      ]);
      expect(_titles(_build(f, WorkFilter.all, 'travel')), [
        'Weekend trip budget',
      ]);
    });
  });

  testWidgets('rows show the source, the host and the state with text', (
    tester,
  ) async {
    await _pumpWork(tester);
    expect(
      find.text('Fix the login keyboard  You', findRichText: true),
      findsOneWidget,
    );
    expect(
      find.text('Check the nightly test  From Tester', findRichText: true),
      findsOneWidget,
    );
    expect(_stateLine('Laptop', 'Running'), findsOneWidget);
    expect(_stateLine('CI-runner', 'Waiting for your answer'), findsOneWidget);
    expect(_stateLine('Laptop', 'Settled'), findsOneWidget);
    expect(
      find.textContaining(
        'Not started · waiting for you to approve Claude Opus',
        findRichText: true,
      ),
      findsOneWidget,
    );
    expect(find.text('Needs you'), findsWidgets);
    expect(find.text('10:42'), findsOneWidget);
    expect(find.text('Yesterday'), findsOneWidget);
    // The Work tab badge counts Needs you.
    final scaffold = tester.widget<AdaptiveScaffold>(
      find.byType(AdaptiveScaffold),
    );
    expect(scaffold.destinations[1].badge, 2);
  });

  testWidgets('each filter shows its note', (tester) async {
    await _pumpWork(tester);
    await _chip(tester, 'Needs you');
    expect(
      find.textContaining('Reading it is not handling it'),
      findsOneWidget,
    );
    expect(
      find.textContaining('Fix the login keyboard', findRichText: true),
      findsNothing,
    );
    await _chip(tester, 'Mine');
    expect(find.text('Only the work you opened.'), findsOneWidget);
    await _chip(tester, 'Opened by pots');
    expect(find.textContaining('take it over'), findsOneWidget);
    await tester.drag(
      find.byType(FilterChips<WorkFilter>),
      const Offset(400, 0),
    );
    await tester.pumpAndSettle();
    await _chip(tester, 'Running');
    expect(find.textContaining('Reading it'), findsNothing);
    expect(find.textContaining('take it over'), findsNothing);
  });

  testWidgets('the search field filters on the device', (tester) async {
    final gateway = await _pumpWork(tester);
    final reads = gateway.sent('GET', '/api/sessions').length;
    await tester.enterText(find.byType(TextField), 'travel');
    await tester.pumpAndSettle();
    expect(
      find.text('Weekend trip budget  You', findRichText: true),
      findsOneWidget,
    );
    expect(
      find.text('Fix the login keyboard  You', findRichText: true),
      findsNothing,
    );
    expect(gateway.sent('GET', '/api/sessions').length, reads);
  });

  for (final (hint, path) in [
    ('sessions_changed', '/api/sessions'),
    ('pots_changed', '/api/pot-works'),
    ('approvals_changed', '/api/model-approvals'),
  ]) {
    testWidgets('$hint reads $path again', (tester) async {
      final fixture = WorkFixture();
      final gateway = await _pumpWork(tester, fixture: fixture);
      final before = gateway.sent('GET', path).length;
      fixture.sessions.add(
        sessionJson('s-new', 'A new one', updatedAt: at(10, 59)),
      );
      fixture.approvals.clear();
      fixture.works.clear();
      gateway.socket('/api/hints')!.push({'type': hint});
      await tester.pumpAndSettle();
      expect(gateway.sent('GET', path).length, before + 1);
      switch (hint) {
        case 'sessions_changed':
          expect(
            find.text('A new one  You', findRichText: true),
            findsOneWidget,
          );
        case 'pots_changed':
          expect(
            find.text('Check the nightly test  You', findRichText: true),
            findsOneWidget,
            reason: 'without its pot work the row is the user\'s',
          );
        case 'approvals_changed':
          expect(
            find.textContaining('approve Claude Opus', findRichText: true),
            findsNothing,
          );
      }
    });
  }

  group('row actions', () {
    testWidgets('rename sends the new name', (tester) async {
      final gateway = await _pumpWork(tester);
      gateway.json['PATCH /api/sessions/s-fix'] = (r) => {
        'session': sessionJson('s-fix', 'Fixed'),
      };
      await _openActions(tester, 'Fix the login keyboard  You');
      await tester.tap(find.text('Rename'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('rename-field')), 'Keyboard');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(gateway.sent('PATCH', '/api/sessions/s-fix').single.json, {
        'name': 'Keyboard',
      });
    });

    testWidgets('pin and settle toggle', (tester) async {
      final gateway = await _pumpWork(tester);
      gateway.json['PATCH /api/sessions/s-fix'] = (r) => {
        'session': sessionJson('s-fix', 'x'),
      };
      gateway.json['PATCH /api/sessions/s-flutter'] = (r) => {
        'session': sessionJson('s-flutter', 'x'),
      };
      await _openActions(tester, 'Fix the login keyboard  You');
      await tester.tap(find.text('Pin'));
      await tester.pumpAndSettle();
      await _openActions(tester, 'Flutter tablet layouts  You');
      await tester.tap(find.text('Unpin'));
      await tester.pumpAndSettle();
      await _openActions(tester, 'Fix the login keyboard  You');
      await tester.tap(find.text('Settle'));
      await tester.pumpAndSettle();
      expect(
        [
          for (final r in gateway.requests.where((r) => r.method == 'PATCH'))
            r.json,
        ],
        [
          {'pinned': true},
          {'pinned': false},
          {'settled': true},
        ],
      );
    });

    testWidgets('delete asks first; a refusal is shown', (tester) async {
      final gateway = await _pumpWork(tester);
      gateway.json['DELETE /api/sessions/s-fix'] = (r) =>
          apiError(409, 'run_active', 'Stop the work before deleting it');
      await _openActions(tester, 'Fix the login keyboard  You');
      await tester.tap(find.text('Delete…'));
      await tester.pumpAndSettle();
      expect(find.text('Delete this work?'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(gateway.sent('DELETE', '/api/sessions/s-fix'), isEmpty);
      await _openActions(tester, 'Fix the login keyboard  You');
      await tester.tap(find.text('Delete…'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
      await tester.pumpAndSettle();
      expect(gateway.sent('DELETE', '/api/sessions/s-fix'), hasLength(1));
      expect(
        find.text('That did not work: Stop the work before deleting it'),
        findsOneWidget,
      );
    });

    testWidgets('a work conversation a pot opened can be deleted', (
      tester,
    ) async {
      final gateway = await _pumpWork(tester);
      gateway.json['DELETE /api/sessions/s-ipad'] = (r) => {'ok': true};
      await _openActions(tester, 'Add iPad keyboard tests  From Tester');
      await tester.tap(find.text('Delete…'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
      await tester.pumpAndSettle();
      expect(gateway.sent('DELETE', '/api/sessions/s-ipad'), hasLength(1));
      expect(find.textContaining('That did not work'), findsNothing);
    });

    testWidgets('opening an unread session marks it read', (tester) async {
      final gateway = await _pumpWork(tester);
      gateway.json['POST /api/sessions/s-nightly/read'] = (r) => {
        'session': sessionJson('s-nightly', 'x'),
      };
      await tester.tap(
        find.text('Check the nightly test  From Tester', findRichText: true),
      );
      await tester.pumpAndSettle();
      expect(
        gateway.sent('POST', '/api/sessions/s-nightly/read'),
        hasLength(1),
      );
      // A read row does not mark again.
      await tester.pageBack();
      await tester.pumpAndSettle();
      await tester.tap(
        find.text('Fix the login keyboard  You', findRichText: true),
      );
      await tester.pumpAndSettle();
      expect(gateway.sent('POST', '/api/sessions/s-fix/read'), isEmpty);
    });

    testWidgets('a model approval row opens its sheet, not a conversation', (
      tester,
    ) async {
      final gateway = await _pumpWork(tester);
      await tester.tap(
        find.text('Compare three API specs  From Butler', findRichText: true),
      );
      await tester.pumpAndSettle();
      expect(gateway.sent('GET', '/api/model-approvals/a-api'), hasLength(1));
      expect(find.byType(BottomSheet), findsOneWidget);
      expect(
        gateway.requests.where((r) => r.path.startsWith('/api/sessions/')),
        isEmpty,
      );
    });
  });

  group('golden images', () {
    for (final width in [375.0, 700.0, 1000.0, 1300.0]) {
      for (final mode in [ThemeMode.light, ThemeMode.dark]) {
        testWidgets('Work list $width ${mode.name}', (tester) async {
          await tester.runAsync(loadGoldenFonts);
          final gateway = WorkFixture().install();
          final container = await pumpApp(
            tester,
            gateway: gateway,
            width: width,
            height: 900,
            location: '/work',
            overrides: [clockProvider.overrideWithValue(() => fixedNow)],
          );
          container.read(themeModeProvider.notifier).select(mode);
          await tester.pumpAndSettle();
          await expectLater(
            find.byType(MaterialApp),
            matchesGoldenFile(
              'goldens/work_list_${width.toInt()}_${mode.name}.png',
            ),
          );
        }, tags: ['golden']);
      }
    }
  });
}
