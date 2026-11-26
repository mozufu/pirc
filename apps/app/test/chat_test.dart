import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_app/src/chat/chat_data.dart';
import 'package:pirc_app/src/chat/chat_list_screen.dart';
import 'package:pirc_app/src/chat/new_group_screen.dart';
import 'package:pirc_app/src/chat/pot_conversation_screen.dart';
import 'package:pirc_app/src/format.dart';
import 'package:pirc_app/src/preferences.dart';
import 'package:pirc_client/pirc_client.dart';
import 'package:pirc_ui/pirc_ui.dart';

import 'support/chat_fixtures.dart';
import 'support/fonts.dart';
import 'support/harness.dart';
import 'support/work_fixtures.dart';

Future<FakeGateway> _pumpChat(
  WidgetTester tester, {
  ChatFixture? fixture,
  double width = 375,
  String location = '/chat',
}) async {
  final gateway = (fixture ?? ChatFixture()).install();
  await pumpApp(
    tester,
    gateway: gateway,
    width: width,
    location: location,
    overrides: [clockProvider.overrideWithValue(() => fixedNow)],
    reduceMotion: true,
  );
  return gateway;
}

List<String> _rowTitles(WidgetTester tester) => [
  for (final row in tester.widgetList<ChatRow>(
    find.descendant(
      of: find.byType(ChatListScreen),
      matching: find.byType(ChatRow),
    ),
  ))
    row.title,
];

ChatRow _row(WidgetTester tester, String title) => tester.widget<ChatRow>(
  find.byWidgetPredicate((w) => w is ChatRow && w.title == title),
);

Finder _rowFinder(String title) =>
    find.byWidgetPredicate((w) => w is ChatRow && w.title == title);

Future<void> _chip(WidgetTester tester, String label) async {
  final chip = find.descendant(
    of: find.byType(FilterChips<ChatFilter>),
    matching: find.text(label),
  );
  await tester.dragUntilVisible(
    chip,
    find.byType(FilterChips<ChatFilter>),
    const Offset(-80, 0),
  );
  await tester.tap(chip);
  await tester.pumpAndSettle();
}

/// A 1 × 1 PNG.
final _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGNgYGD4DwABBAEAwS2OUAAAAABJRU5ErkJggg==',
);

void main() {
  group('the list', () {
    test('pots and groups, newest first; archived pots, deleted pots and '
        'pot DMs are left out; a pot without a thread comes last', () {
      final fixture = ChatFixture();
      fixture.pots.add(potJson('p-new', 'Newcomer'));
      fixture.threads.add(
        threadJson('t-gone', pots: ['p-deleted'], updatedAt: at(10, 58)),
      );
      final list = ChatList.build(fixture.parsedThreads, fixture.parsedPots);
      expect(
        [for (final e in list.all) e.name],
        [
          'Tester',
          'Mobile team',
          'Researcher',
          'Butler',
          'Travel buddy',
          'Trip plan',
          'Newcomer',
        ],
      );
      final newcomer = list.all.last as PotChat;
      expect(newcomer.thread, isNull);
      expect(newcomer.key, 'pot:p-new');
      expect(list.all[1].key, 't-mobile');
    });

    test('updatedAt orders the list, so a renamed group moves to the top', () {
      final fixture = ChatFixture();
      // The group's last message is older; its rename is newer than every
      // other thread.
      fixture.threads[1]['updatedAt'] = at(10, 59);
      final list = ChatList.build(fixture.parsedThreads, fixture.parsedPots);
      expect(list.all.first.name, 'Mobile team');
      expect(list.all.first.time, at(10, 34), reason: 'shows the message time');
      expect(list.all.first.updatedAt, at(10, 59));
    });

    test('filters and search', () {
      final fixture = ChatFixture();
      final list = ChatList.build(fixture.parsedThreads, fixture.parsedPots);
      List<String> names(ChatFilter f, [String q = '']) => [
        for (final e in list.shown(f, q)) e.name,
      ];
      expect(names(ChatFilter.unread), ['Tester', 'Mobile team', 'Butler']);
      expect(names(ChatFilter.pots), [
        'Tester',
        'Researcher',
        'Butler',
        'Travel buddy',
      ]);
      expect(names(ChatFilter.groups), ['Mobile team', 'Trip plan']);
      expect(names(ChatFilter.all, 'hotel'), ['Trip plan']);
      expect(names(ChatFilter.all, 'RESEARCH'), ['Researcher']);
      expect(names(ChatFilter.groups, 'tester'), isEmpty);
    });
  });

  group('the screen', () {
    appTest('rows show role, time, preview and the order', (tester) async {
      await _pumpChat(tester);
      expect(_rowTitles(tester), [
        'Tester',
        'Mobile team',
        'Researcher',
        'Butler',
        'Travel buddy',
        'Trip plan',
      ]);
      final butler = _row(tester, 'Butler');
      expect(butler.role, 'Manager');
      expect(butler.time, '09:00');
      final travel = _row(tester, 'Travel buddy');
      expect(travel.role, 'Travel · Paused');
      expect(travel.time, 'Yesterday');
      expect(_row(tester, 'Trip plan').time, 'Sat');
      final group = _row(tester, 'Mobile team');
      expect(group.role, '4 people');
      expect(group.preview, 'Tester: OK, I opened a work.');
      expect(
        _row(tester, 'Tester').preview,
        'I passed the nightly problem '
        'to you',
      );
    });

    appTest('waiting on you wins over unread: a yellow count and a warning '
        'preview; unread uses the ink badge', (tester) async {
      final fixture = ChatFixture();
      fixture.threads[0]['unread'] = 2;
      await _pumpChat(tester, fixture: fixture);
      final butler = _row(tester, 'Butler');
      expect(butler.badge!.attention, isTrue);
      expect(butler.badge!.text, '1');
      expect(butler.previewWarning, isTrue);
      expect(butler.previewLeading, isNotNull);
      final tester2 = _row(tester, 'Tester');
      expect(tester2.badge!.attention, isFalse);
      expect(tester2.badge!.text, '1');
      expect(tester2.previewWarning, isFalse);
      expect(_row(tester, 'Mobile team').badge!.text, '3');
      expect(_row(tester, 'Researcher').badge, isNull);
    });

    appTest('the status dots follow each pot\'s status', (tester) async {
      await _pumpChat(tester);
      Avatar avatarOf(String title) => tester.widget<Avatar>(
        find.descendant(
          of: find.byWidgetPredicate((w) => w is ChatRow && w.title == title),
          matching: find.byType(Avatar),
        ),
      );
      expect(avatarOf('Tester').status, AvatarStatus.working);
      expect(avatarOf('Tester').statusLabel, 'Working');
      expect(avatarOf('Travel buddy').status, AvatarStatus.unavailable);
      expect(avatarOf('Researcher').status, AvatarStatus.none);
      expect(
        find.descendant(
          of: find.byWidgetPredicate(
            (w) => w is ChatRow && w.title == 'Mobile team',
          ),
          matching: find.byType(GroupAvatar),
        ),
        findsOneWidget,
      );
    });

    appTest('the tab badge counts what waits on the user', (tester) async {
      final fixture = ChatFixture();
      fixture.pots[1]['needsYou'] = 2;
      fixture.pots.last['needsYou'] = 5; // archived: not counted
      await _pumpChat(tester, fixture: fixture);
      final scaffold = tester.widget<AdaptiveScaffold>(
        find.byType(AdaptiveScaffold),
      );
      expect(scaffold.destinations.first.badge, 3);
    });

    appTest('a row opens its conversation', (tester) async {
      await _pumpChat(tester);
      await tester.tap(_rowFinder('Researcher'));
      await tester.pumpAndSettle();
      expect(find.byType(PotConversationScreen), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(PotConversationScreen),
          matching: find.text('Researcher'),
        ),
        findsOneWidget,
      );
    });

    appTest('the open row is highlighted where the list stays', (tester) async {
      await _pumpChat(tester, width: 1300, location: '/chat?open=t-mobile');
      expect(_row(tester, 'Mobile team').selected, isTrue);
      expect(_row(tester, 'Researcher').previousSelected, isTrue);
    });

    appTest('filters narrow the rows and add a "New" row', (tester) async {
      await _pumpChat(tester);
      await _chip(tester, 'Unread');
      expect(_rowTitles(tester), ['Tester', 'Mobile team', 'Butler']);
      await _chip(tester, 'Groups');
      expect(_rowTitles(tester), ['Mobile team', 'Trip plan']);
      expect(find.text('Create group'), findsOneWidget);
      await _chip(tester, 'Pots');
      expect(_rowTitles(tester), [
        'Tester',
        'Researcher',
        'Butler',
        'Travel buddy',
      ]);
      await tester.tap(find.text('New pot'));
      await tester.pumpAndSettle();
      expect(find.text('1 / 4 · Look and personality'), findsOneWidget);
    });

    appTest('search matches names, intros and last messages', (tester) async {
      await _pumpChat(tester);
      await tester.enterText(find.byType(TextField), 'hotel');
      await tester.pumpAndSettle();
      expect(_rowTitles(tester), ['Trip plan']);
      await tester.enterText(find.byType(TextField), 'nobody');
      await tester.pumpAndSettle();
      expect(_rowTitles(tester), isEmpty);
      expect(find.text('No chats here.'), findsOneWidget);
    });

    appTest('empty state: one line and "New pot"', (tester) async {
      final fixture = ChatFixture()
        ..pots.clear()
        ..threads.clear();
      await _pumpChat(tester, fixture: fixture);
      expect(find.text('No pots or groups yet'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, 'New pot'));
      await tester.pumpAndSettle();
      expect(find.text('1 / 4 · Look and personality'), findsOneWidget);
    });

    appTest('a failed read offers to try again', (tester) async {
      final fixture = ChatFixture();
      final gateway = fixture.install();
      var fail = true;
      gateway.json['GET /api/threads'] = (_) =>
          fail ? apiError(500, 'internal') : {'threads': fixture.threads};
      await pumpApp(
        tester,
        gateway: gateway,
        width: 375,
        location: '/chat',
        overrides: [clockProvider.overrideWithValue(() => fixedNow)],
        reduceMotion: true,
      );
      expect(find.text('The list could not be loaded.'), findsOneWidget);
      fail = false;
      await tester.tap(find.text('Try again'));
      await tester.pumpAndSettle();
      expect(_rowTitles(tester), hasLength(6));
    });

    for (final (hint, path) in [
      ('pots_changed', '/api/pots'),
      ('threads_changed', '/api/threads'),
    ]) {
      appTest('$hint reads $path again', (tester) async {
        final fixture = ChatFixture();
        final gateway = await _pumpChat(tester, fixture: fixture);
        final before = gateway.sent('GET', path).length;
        if (hint == 'pots_changed') {
          fixture.pots[2] = potJson(
            'p-research',
            'Scholar',
            color: 3,
            intro: 'Research',
          );
        } else {
          fixture.threads[3]['lastMessage'] = lastJson(
            'A newer line',
            at(10, 59),
            authorId: 'p-research',
          );
          fixture.threads[3]['updatedAt'] = at(10, 59);
        }
        gateway.socket('/api/hints')!.push({'type': hint});
        await tester.pumpAndSettle();
        expect(gateway.sent('GET', path).length, before + 1);
        if (hint == 'pots_changed') {
          expect(_rowTitles(tester), contains('Scholar'));
        } else {
          expect(_rowTitles(tester).first, 'Researcher');
          expect(_row(tester, 'Researcher').preview, 'A newer line');
        }
      });
    }

    appTest('an uploaded picture is read with the device token', (
      tester,
    ) async {
      final fixture = ChatFixture();
      fixture.pots[2]['profile'] = {
        'name': 'Researcher',
        'avatarColor': 3,
        'avatarImage': 'img1',
      };
      final gateway = fixture.install();
      gateway.json['GET /api/images/img1'] = (_) => ApiResponse(200, _png);
      await pumpApp(
        tester,
        gateway: gateway,
        width: 375,
        location: '/chat',
        overrides: [clockProvider.overrideWithValue(() => fixedNow)],
        reduceMotion: true,
      );
      expect(gateway.sent('GET', '/api/images/img1'), hasLength(1));
      final avatar = tester.widget<Avatar>(
        find.descendant(
          of: find.byWidgetPredicate(
            (w) => w is ChatRow && w.title == 'Researcher',
          ),
          matching: find.byType(Avatar),
        ),
      );
      expect(avatar.image, isA<MemoryImage>());
    });
  });

  group('New (E6)', () {
    appTest('offers a pot and a group', (tester) async {
      await _pumpChat(tester);
      await tester.tap(find.byTooltip('New pot or group'));
      await tester.pumpAndSettle();
      expect(find.text('New'), findsOneWidget);
      expect(
        find.text(
          'New conversations (work) start from the top right of the '
          'Work tab.',
        ),
        findsOneWidget,
      );
      await tester.tap(find.text('Create group'));
      await tester.pumpAndSettle();
      expect(find.byType(NewGroupScreen), findsOneWidget);
    });

    appTest('"Create group" waits for two pots', (tester) async {
      final fixture = ChatFixture();
      fixture.pots
        ..removeRange(1, 4)
        ..add(potJson('p-x', 'Archived', state: 'archived'));
      await _pumpChat(tester, fixture: fixture);
      await tester.tap(find.byTooltip('New pot or group'));
      await tester.pumpAndSettle();
      expect(find.text('Create at least two pots first'), findsOneWidget);
      await tester.tap(find.text('Create group'));
      await tester.pumpAndSettle();
      expect(find.text('Create group'), findsOneWidget, reason: 'still open');
      await tester.tap(find.text('New pot').last);
      await tester.pumpAndSettle();
      expect(find.text('1 / 4 · Look and personality'), findsOneWidget);
    });
  });

  group('golden images', () {
    for (final width in [375.0, 700.0, 1000.0, 1300.0]) {
      for (final mode in [ThemeMode.light, ThemeMode.dark]) {
        testWidgets('New sheet $width ${mode.name}', (tester) async {
          await tester.runAsync(loadGoldenFonts);
          final container = await pumpApp(
            tester,
            gateway: ChatFixture().install(),
            width: width,
            height: 812,
            location: '/chat',
            overrides: [clockProvider.overrideWithValue(() => fixedNow)],
            reduceMotion: true,
          );
          container.read(themeModeProvider.notifier).select(mode);
          await tester.pumpAndSettle();
          await tester.tap(find.byTooltip('New pot or group'));
          await tester.pumpAndSettle();
          await expectLater(
            find.byType(MaterialApp),
            matchesGoldenFile(
              'goldens/chat_new_${width.toInt()}_${mode.name}.png',
            ),
          );
          await disposeApp(tester);
        }, tags: ['golden']);
      }
    }
  });
}
