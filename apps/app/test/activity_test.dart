import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_app/src/activity/pov_screen.dart';
import 'package:pirc_app/src/format.dart';
import 'package:pirc_app/src/preferences.dart';
import 'package:pirc_app/src/router.dart';
import 'package:pirc_ui/pirc_ui.dart';

import 'support/activity_fixtures.dart';
import 'support/chat_fixtures.dart';
import 'support/fonts.dart';
import 'support/harness.dart';
import 'support/work_fixtures.dart';

const _pov = '/activity?pot=p-tester&open=pov:p-tester';

Future<(FakeGateway, ProviderContainer)> _pump(
  WidgetTester tester,
  ActivityFixture fixture, {
  String location = '/activity',
  double width = 375,
  double height = 812,
}) async {
  final gateway = fixture.install();
  final container = await pumpApp(
    tester,
    gateway: gateway,
    width: width,
    height: height,
    location: location,
    overrides: [clockProvider.overrideWithValue(() => fixedNow)],
    reduceMotion: true,
  );
  return (gateway, container);
}

Uri _location(ProviderContainer container) =>
    container.read(routerProvider).routeInformationProvider.value.uri;

void _hint(FakeGateway gateway, String type) =>
    gateway.socket('/api/hints')!.push({'type': type});

Future<void> _tap(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

Finder _row(String id) => find.byKey(ValueKey('activity-$id'));

/// Scrolls [finder] into the built part of the list it is in, then taps it.
Future<void> _scrollTap(
  WidgetTester tester,
  Finder finder, {
  String list = 'activity-list',
  double delta = 200,
}) async {
  if (finder.evaluate().isNotEmpty) return _tap(tester, finder);
  await tester.scrollUntilVisible(
    finder,
    delta,
    scrollable: find.descendant(
      of: find.byKey(ValueKey(list)),
      matching: find.byType(Scrollable),
    ),
  );
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

Future<void> _chip(WidgetTester tester, String id) => _scrollTap(
  tester,
  find.byKey(ValueKey('pot-filter-$id')),
  list: 'pot-filters',
  // "All" is first: back to the start.
  delta: id == 'all' ? -80 : 80,
);

/// The Activity list's reads (the profile's carry a `limit`).
List<Map<String, String>> _reads(FakeGateway gateway) => [
  for (final r in gateway.sent('GET', '/api/activity'))
    if (!r.query.containsKey('limit')) r.query,
];

int? _activityBadge(WidgetTester tester) => tester
    .widget<AdaptiveScaffold>(find.byType(AdaptiveScaffold))
    .destinations[AppTab.activity.index]
    .badge;

void main() {
  appTest('rows are newest first by day with who → target and the tag', (
    tester,
  ) async {
    await _pump(tester, ActivityFixture(), height: 3000);
    expect(find.text('What pots are doing'), findsOneWidget);
    final order = [
      for (final id in ['e1', 'e3', 'e6', 'e9', 'e10']) _row(id),
    ];
    for (var i = 1; i < order.length; i++) {
      expect(
        tester.getTopLeft(order[i]).dy,
        greaterThan(tester.getTopLeft(order[i - 1]).dy),
      );
    }
    expect(find.text('Today'), findsOneWidget);
    expect(find.text('Yesterday'), findsOneWidget);
    Finder within(String id, String text) =>
        find.descendant(of: _row(id), matching: find.text(text));
    expect(within('e1', '→ You'), findsOneWidget);
    expect(within('e1', 'Needs approval'), findsOneWidget);
    expect(within('e2', '→ Check the nightly test'), findsOneWidget);
    expect(within('e2', 'To you'), findsOneWidget);
    expect(within('e3', '→ Butler'), findsOneWidget);
    expect(within('e3', 'Message'), findsOneWidget);
    expect(within('e6', '→ Mobile team'), findsOneWidget);
    expect(within('e6', 'Group'), findsOneWidget);
    expect(within('e10', 'Status'), findsOneWidget);
    expect(within('e3', '10:42'), findsOneWidget);
    expect(find.textContaining('there is no channel you can'), findsOneWidget);
  });

  appTest('scrolling to the end loads the page before the oldest row', (
    tester,
  ) async {
    final fixture = ActivityFixture()..nextBefore = 'cursor-1';
    fixture.olderPages['cursor-1'] = {
      'activity': [
        activityJson(
          'old1',
          'review',
          'p-butler',
          'Looked at its duties',
          at(9, 0, 2),
        ),
      ],
    };
    final (gateway, _) = await _pump(tester, fixture);
    expect(_row('old1'), findsNothing);
    await tester.scrollUntilVisible(
      _row('old1'),
      300,
      scrollable: find.descendant(
        of: find.byKey(const ValueKey('activity-list')),
        matching: find.byType(Scrollable),
      ),
    );
    await tester.pumpAndSettle();
    expect(_row('old1'), findsOneWidget);
    expect(_reads(gateway).last, {'before': 'cursor-1'});
    // The last page: no more reads.
    expect(find.byKey(const ValueKey('activity-more')), findsNothing);
    final count = _reads(gateway).length;
    await tester.drag(find.byType(ListView).first, const Offset(0, -500));
    await tester.pumpAndSettle();
    expect(_reads(gateway).length, count);
  });

  appTest('a hint reads the newest page again and keeps older pages', (
    tester,
  ) async {
    final fixture = ActivityFixture();
    final (gateway, _) = await _pump(tester, fixture, height: 3000);
    fixture.activity.insert(
      0,
      activityJson('e0', 'review', 'p-butler', 'Reviewed', at(10, 55)),
    );
    _hint(gateway, 'activity_changed');
    await tester.pumpAndSettle();
    expect(_row('e0'), findsOneWidget);
    expect(_row('e11'), findsOneWidget);
  });

  appTest('a pot chip filters by pot and shows its point of view entry', (
    tester,
  ) async {
    final (gateway, container) = await _pump(tester, ActivityFixture());
    await _chip(tester, 'p-research');
    expect(_location(container).toString(), '/activity?pot=p-research');
    expect(_reads(gateway).last, {'potId': 'p-research'});
    expect(_row('e6'), findsOneWidget);
    expect(_row('e1'), findsNothing);
    final see = find.textContaining(
      "See Researcher's point of view",
      findRichText: true,
    );
    expect(see, findsOneWidget);
    await _tap(tester, see);
    expect(
      _location(container).toString(),
      '/activity?pot=p-research&open=pov%3Ap-research',
    );
    await _tap(tester, find.byTooltip('Back'));
    expect(_location(container).toString(), '/activity?pot=p-research');
    await _chip(tester, 'all');
    expect(_location(container).toString(), '/activity');
    expect(_reads(gateway).last, isEmpty);
  });

  appTest('the type filter sends the chosen kinds', (tester) async {
    final (gateway, container) = await _pump(tester, ActivityFixture());
    await _tap(tester, find.byKey(const ValueKey('activity-kind')));
    await _tap(tester, find.byKey(const ValueKey('kind-filter-dm')));
    expect(_reads(gateway).last, {'kind': 'dm'});
    expect(_row('e3'), findsOneWidget);
    expect(_row('e1'), findsNothing);
    // The notices are not activity: a type filter hides them.
    expect(find.text('Noticed'), findsNothing);

    await _tap(tester, find.byKey(const ValueKey('activity-kind')));
    await _scrollTap(
      tester,
      find.byKey(
        const ValueKey(
          'kind-filter-created,updated,paused,resumed,archived,restored,deleted',
        ),
      ),
      list: 'kind-filters',
    );
    expect(_reads(gateway).last, {
      'kind': 'created,updated,paused,resumed,archived,restored,deleted',
    });
    expect(_row('e10'), findsOneWidget);
    expect(_location(container).queryParameters['kind'], startsWith('created'));

    // Both filters together.
    await _chip(tester, 'p-travel');
    expect(_reads(gateway).last, {
      'potId': 'p-travel',
      'kind': 'created,updated,paused,resumed,archived,restored,deleted',
    });

    await _tap(tester, find.byKey(const ValueKey('activity-kind')));
    await _tap(tester, find.byKey(const ValueKey('kind-filter-all')));
    expect(_reads(gateway).last, {'potId': 'p-travel'});
  });

  group('a row opens its reference', () {
    for (final (id, expected) in [
      ('e2', '/work?open=s-nightly'),
      ('e5', '/work?open=s-ipad'),
      ('e4', '/chat?open=handover%3Ah1'),
      ('e6', '/chat?open=t-mobile'),
      ('e3', '/activity?pot=p-tester&open=pov%3Ap-tester&thread=t-dm'),
    ]) {
      appTest('$id → $expected', (tester) async {
        final (_, container) = await _pump(tester, ActivityFixture());
        await _scrollTap(tester, _row(id));
        expect(_location(container).toString(), expected);
      });
    }

    appTest('a direct thread opens the pot conversation', (tester) async {
      final fixture = ActivityFixture();
      fixture.activity.first['refs'] = {'thread': 't-butler'};
      fixture.activity.first['kind'] = 'review';
      final (_, container) = await _pump(tester, fixture);
      await _tap(tester, _row('e1'));
      expect(_location(container).toString(), '/chat?open=pot%3Ap-butler');
    });

    appTest('an approval opens its sheet', (tester) async {
      final (gateway, _) = await _pump(tester, ActivityFixture());
      await _tap(tester, _row('e1'));
      expect(gateway.sent('GET', '/api/model-approvals/a1'), isNotEmpty);
      expect(find.byType(BottomSheet), findsOneWidget);
    });

    appTest('a budget request opens its sheet', (tester) async {
      final (gateway, _) = await _pump(tester, ActivityFixture());
      await _scrollTap(tester, _row('e11'));
      expect(gateway.sent('GET', '/api/budget-requests/b1'), isNotEmpty);
      expect(find.byType(BottomSheet), findsOneWidget);
    });

    appTest('a row without a reference opens nothing', (tester) async {
      final (_, container) = await _pump(tester, ActivityFixture());
      await _scrollTap(tester, _row('e9'));
      expect(_location(container).toString(), '/activity');
    });
  });

  group('noticed', () {
    appTest('open notifications come first, each with Mark read', (
      tester,
    ) async {
      final fixture = ActivityFixture();
      final (gateway, _) = await _pump(tester, fixture);
      expect(find.text('Noticed'), findsOneWidget);
      final open = find.text('A work is waiting for you');
      final read = find.text('A work finished its run');
      expect(tester.getTopLeft(open).dy, lessThan(tester.getTopLeft(read).dy));
      expect(find.text('2 pots'), findsOneWidget);
      expect(find.byKey(const ValueKey('mark-read-n1')), findsOneWidget);
      expect(find.byKey(const ValueKey('mark-read-n2')), findsNothing);
      expect(_activityBadge(tester), 1);

      await _tap(tester, find.byKey(const ValueKey('mark-read-n1')));
      expect(
        gateway.sent('POST', '/api/observation-notifications/n1/read'),
        hasLength(1),
      );
      expect(find.byKey(const ValueKey('mark-read-n1')), findsNothing);
      expect(_activityBadge(tester), 0);
    });

    appTest('the badge follows notifications_changed', (tester) async {
      final fixture = ActivityFixture();
      final (gateway, _) = await _pump(tester, fixture, location: '/chat');
      expect(_activityBadge(tester), 1);
      fixture.notifications.last['state'] = 'read';
      _hint(gateway, 'notifications_changed');
      await tester.pumpAndSettle();
      expect(_activityBadge(tester), 0);
    });

    appTest('a work notification opens the work', (tester) async {
      final (_, container) = await _pump(tester, ActivityFixture());
      await _tap(tester, find.text('A work is waiting for you'));
      expect(_location(container).toString(), '/work?open=s-nightly');
    });

    appTest('a push lands on its notification, scrolled into view', (
      tester,
    ) async {
      final fixture = ActivityFixture();
      // Twelve newer open notifications push n2 below the screen.
      fixture.notifications.insertAll(0, [
        for (var i = 0; i < 12; i++)
          {
            'id': 'x$i',
            'sourceKind': 'schedules',
            'condition': 'starting_soon',
            'issuerPotId': 'p-butler',
            'observations': [
              {'potId': 'p-butler', 'note': 'Note $i'},
            ],
            'state': 'open',
            'createdAt': at(10, 55),
          },
      ]);
      final (_, container) = await _pump(
        tester,
        fixture,
        location: '/activity?notification=n2',
        height: 700,
      );
      expect(_location(container).queryParameters['notification'], 'n2');
      final row = find.text('A work finished its run');
      expect(row, findsOneWidget);
      final rect = tester.getRect(row);
      expect(rect.top, greaterThan(0));
      expect(rect.bottom, lessThan(700 - 56));
      // It is marked.
      final marked = tester.widget<Material>(
        find.ancestor(of: row, matching: find.byType(Material)).first,
      );
      expect(marked.color, isNot(Colors.transparent));
    });

    appTest('filtered to a pot, only its notices show', (tester) async {
      await _pump(
        tester,
        ActivityFixture(),
        location: '/activity?pot=p-butler',
      );
      expect(find.text('A work finished its run'), findsOneWidget);
      expect(find.text('A work is waiting for you'), findsNothing);
    });
  });

  group('point of view', () {
    appTest('E18 lists its threads, works and sent messages', (tester) async {
      final (gateway, _) = await _pump(
        tester,
        ActivityFixture(),
        location: _pov,
      );
      expect(find.text("Tester's point of view"), findsOneWidget);
      expect(find.text('Read only · the chat list it sees'), findsOneWidget);
      expect(
        find.textContaining('This is what Tester sees', findRichText: true),
        findsOneWidget,
      );
      final threads = [
        for (final id in ['t-tester', 't-dm', 't-mobile'])
          find.byKey(ValueKey('pov-thread-$id')),
      ];
      for (final t in threads) {
        expect(t, findsOneWidget);
      }
      Finder inRow(String id, Finder f) => find.descendant(
        of: find.byKey(ValueKey('pov-thread-$id')),
        matching: f,
      );
      expect(inRow('t-tester', find.text('You (user)')), findsOneWidget);
      expect(
        inRow('t-tester', find.text('Me: nightly has a question for you')),
        findsOneWidget,
      );
      expect(inRow('t-dm', find.text('Butler')), findsOneWidget);
      expect(
        inRow(
          't-mobile',
          find.text('You: @Tester add an iPad floating keyboard test'),
        ),
        findsOneWidget,
      );
      expect(find.text('Works I coordinate'), findsOneWidget);
      await tester.ensureVisible(
        find.byKey(const ValueKey('pov-work-w-nightly')),
      );
      expect(find.text('Messages it sent'), findsOneWidget);
      expect(gateway.sent('GET', '/api/pots/p-tester/view'), isNotEmpty);
    });

    appTest('E19: a work shows its instructions and opens the work', (
      tester,
    ) async {
      final (gateway, container) = await _pump(
        tester,
        ActivityFixture(),
        location: _pov,
      );
      await _tap(tester, find.byKey(const ValueKey('pov-work-w-nightly')));
      expect(
        _location(container).toString(),
        '/activity?pot=p-tester&open=pov%3Ap-tester&work=w-nightly',
      );
      expect(find.text('Check the nightly test'), findsOneWidget);
      final bubble = tester.widget<Bubble>(
        find.byKey(const ValueKey('instruction-i2')),
      );
      expect(bubble.rightSide, isTrue);
      expect(bubble.tint, 2);
      expect(bubble.meta, '10:40 · Delivered');
      expect(find.byKey(const ValueKey('instruction-i1')), findsNothing);
      await _tap(tester, find.text('Go to work'));
      expect(_location(container).toString(), '/work?open=s-nightly');
      expect(gateway.requests.where((r) => r.method == 'POST'), isEmpty);
    });

    appTest('E20: a pot DM is read only with its messages on the right', (
      tester,
    ) async {
      final (gateway, container) = await _pump(
        tester,
        ActivityFixture(),
        location: _pov,
      );
      await _tap(tester, find.byKey(const ValueKey('pov-thread-t-dm')));
      expect(find.byType(PovThreadScreen), findsOneWidget);
      expect(
        find.text('Message · you can see every message between pots'),
        findsOneWidget,
      );
      Bubble bubble(String text) => tester.widget<Bubble>(
        find.ancestor(of: find.text(text), matching: find.byType(Bubble)),
      );
      final mine = bubble("Got it, I'm opening a work on CI-runner.");
      expect((mine.rightSide, mine.tint, mine.name), (true, 2, 'Me (Tester)'));
      final other = bubble("OK, I'll put it in today's summary reminder.");
      expect(
        (other.rightSide, other.tint, other.name),
        (false, null, 'Butler'),
      );
      expect(
        find.text(
          'Handed over: Check the nightly test · Butler → Tester',
          findRichText: true,
        ),
        findsNothing,
      );
      expect(find.byType(HandoffLine), findsOneWidget);
      expect(find.byKey(const ValueKey('thread-composer-field')), findsNothing);
      expect(find.text('Read only: Tester\'s record'), findsOneWidget);
      // Back goes to the point of view, then to the filtered list.
      await _tap(tester, find.byTooltip('Back'));
      expect(_location(container).toString(), _pov.replaceAll(':', '%3A'));
      await _tap(tester, find.byKey(const ValueKey('pov-thread-t-dm')));
      await _tap(tester, find.text('Back to activity'));
      expect(_location(container).toString(), '/activity?pot=p-tester');
      expect(gateway.requests.where((r) => r.method == 'POST'), isEmpty);
    });

    appTest('a group in a point of view shows the user with its avatar', (
      tester,
    ) async {
      await _pump(tester, ActivityFixture(), location: _pov);
      await _tap(tester, find.byKey(const ValueKey('pov-thread-t-mobile')));
      final user = tester.widget<Bubble>(
        find.ancestor(
          of: find.text('@Tester add an iPad floating keyboard test'),
          matching: find.byType(Bubble),
        ),
      );
      expect(user.rightSide, isFalse);
      expect(user.avatar, isNotNull);
      expect(user.name, 'You');
      final mine = tester.widget<Bubble>(
        find.ancestor(
          of: find.text('OK, I opened a work.'),
          matching: find.byType(Bubble),
        ),
      );
      expect(mine.rightSide, isTrue);
    });

    appTest('a pot DM opened in the Chat tab is read only', (tester) async {
      final (gateway, container) = await _pump(
        tester,
        ActivityFixture(),
        location: '/chat?open=t-dm',
      );
      expect(find.byType(PovThreadScreen), findsOneWidget);
      expect(find.byKey(const ValueKey('pov-read-only')), findsOneWidget);
      expect(find.byKey(const ValueKey('thread-composer-field')), findsNothing);
      expect(gateway.sent('POST', '/api/threads/t-dm/read'), isEmpty);
      await _tap(tester, find.byTooltip('Back'));
      expect(_location(container).toString(), '/chat');
    });
  });

  appTest("the profile's See all opens Activity filtered to the pot", (
    tester,
  ) async {
    final fixture = PotProfileFixture();
    final gateway = fixture.install();
    final container = await pumpApp(
      tester,
      gateway: gateway,
      width: 375,
      height: 2400,
      location: '/chat?open=pot:p-butler&side=profile',
      overrides: [clockProvider.overrideWithValue(() => fixedNow)],
      reduceMotion: true,
    );
    await _tap(tester, find.byKey(const ValueKey('profile-see-all')));
    expect(_location(container).toString(), '/activity?pot=p-butler');
    expect(_reads(gateway).last, {'potId': 'p-butler'});
    expect(
      find.textContaining("See Butler's point of view", findRichText: true),
      findsOneWidget,
    );
    final chip = tester.widget<Material>(
      find.byKey(const ValueKey('pot-filter-p-butler')),
    );
    expect(
      chip.color,
      isNot(
        tester
            .widget<Material>(find.byKey(const ValueKey('pot-filter-all')))
            .color,
      ),
    );
  });

  group('golden images', () {
    for (final (name, location, tap) in [
      ('activity_pot', '/activity?pot=p-research', null),
      ('pov', _pov, null),
      ('pov_work', _pov, 'pov-work-w-nightly'),
      ('pov_dm', _pov, 'pov-thread-t-dm'),
    ]) {
      for (final mode in [ThemeMode.light, ThemeMode.dark]) {
        testWidgets('$name 375 ${mode.name}', (tester) async {
          await tester.runAsync(loadGoldenFonts);
          final (_, container) = await _pump(
            tester,
            ActivityFixture(),
            location: location,
          );
          container.read(themeModeProvider.notifier).select(mode);
          await tester.pumpAndSettle();
          if (tap != null) {
            await _tap(tester, find.byKey(ValueKey(tap)));
          }
          await expectLater(
            find.byType(MaterialApp),
            matchesGoldenFile('goldens/${name}_375_${mode.name}.png'),
          );
          await disposeApp(tester);
        }, tags: ['golden']);
      }
    }
  });
}
