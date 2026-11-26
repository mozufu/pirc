import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_app/src/chat/group_conversation_screen.dart';
import 'package:pirc_app/src/chat/group_info_screen.dart';
import 'package:pirc_app/src/chat/new_group_screen.dart';
import 'package:pirc_app/src/format.dart';
import 'package:pirc_app/src/preferences.dart';
import 'package:pirc_app/src/router.dart';
import 'package:pirc_ui/pirc_ui.dart';

import 'support/chat_fixtures.dart';
import 'support/fonts.dart';
import 'support/harness.dart';
import 'support/work_fixtures.dart';

const _newGroup = '/chat?open=new-group';
const _group = '/chat?open=t-mobile';
const _info = '/chat?open=t-mobile&side=group-info';

Future<(FakeGateway, ProviderContainer)> _pump(
  WidgetTester tester,
  GroupFixture fixture, {
  String location = _group,
  double width = 375,
  double height = 2000,
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

Future<void> _tap(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

Future<void> _key(WidgetTester tester, String key) =>
    _tap(tester, find.byKey(ValueKey(key)));

Future<void> _type(WidgetTester tester, String key, String text) async {
  final field = find.byKey(ValueKey(key));
  await tester.ensureVisible(field);
  await tester.enterText(field, text);
  await tester.pumpAndSettle();
}

Future<void> _send(WidgetTester tester, String text) async {
  await _type(tester, 'thread-composer-field', text);
  await _key(tester, 'thread-send');
}

/// The popover's row of [name].
Finder _option(String name) => find.descendant(
  of: find.byKey(const ValueKey('group-mentions')),
  matching: find.text(name),
);

Future<void> _mention(WidgetTester tester, String name) async {
  await _key(tester, 'group-mention');
  await _tap(tester, _option(name));
}

void _hint(FakeGateway gateway, String type) =>
    gateway.socket('/api/hints')!.push({'type': type});

final _potBubble = find.byWidgetPredicate((w) => w is Bubble && !w.mine);
final _myBubble = find.byWidgetPredicate((w) => w is Bubble && w.mine);

void main() {
  group('New group (E32)', () {
    appTest('offers the pots that are not archived and creates the group '
        'once, then opens it', (tester) async {
      final fixture = GroupFixture();
      final (gateway, container) = await _pump(
        tester,
        fixture,
        location: _newGroup,
      );
      expect(find.byType(NewGroupScreen), findsOneWidget);
      for (final id in ['p-butler', 'p-tester', 'p-research', 'p-travel']) {
        expect(find.byKey(ValueKey('member-$id')), findsOneWidget);
      }
      expect(find.byKey(const ValueKey('member-p-old')), findsNothing);
      expect(find.text('Testing · Can open work'), findsOneWidget);
      expect(find.text('Travel · Paused'), findsOneWidget);
      expect(find.text('No pots selected'), findsOneWidget);
      await _type(tester, 'group-name', '  Mobile crew ');
      // Ticked in another order than the list's.
      for (final id in ['p-tester', 'p-butler', 'p-research']) {
        await _key(tester, 'member-$id');
      }
      expect(find.text('3 pots selected'), findsOneWidget);
      await _key(tester, 'host-p-butler');
      await _key(tester, 'swatch-2');
      await _key(tester, 'group-create');
      expect(fixture.creates, [
        {
          'name': 'Mobile crew',
          'hostPotId': 'p-butler',
          'memberPotIds': ['p-butler', 'p-tester', 'p-research'],
          'avatarColor': 2,
        },
      ]);
      expect(gateway.sent('POST', '/api/threads'), hasLength(1));
      expect(_location(container).toString(), '/chat?open=t-new');
      expect(find.byType(GroupConversationScreen), findsOneWidget);
      // The list was read again: the new group is a row.
      expect(gateway.sent('GET', '/api/threads').length, greaterThan(1));
    });

    appTest('the members\' faces send no colour', (tester) async {
      final fixture = GroupFixture();
      await _pump(tester, fixture, location: _newGroup);
      await _type(tester, 'group-name', 'Pair');
      await _key(tester, 'member-p-butler');
      await _key(tester, 'member-p-research');
      await _key(tester, 'host-p-research');
      await _key(tester, 'swatch-4');
      await _key(tester, 'swatch-faces');
      await _key(tester, 'group-create');
      expect(fixture.creates.single, {
        'name': 'Pair',
        'hostPotId': 'p-research',
        'memberPotIds': ['p-butler', 'p-research'],
      });
    });

    appTest('needs a name, 2 to 16 members and a host among them', (
      tester,
    ) async {
      final fixture = GroupFixture();
      await _pump(tester, fixture, location: _newGroup);
      await _key(tester, 'member-p-butler');
      await _key(tester, 'group-create');
      expect(find.text('Give the group a name'), findsOneWidget);
      expect(find.text('A group has 2 to 16 pots'), findsOneWidget);
      expect(find.text('Choose a host among the members'), findsOneWidget);
      await _type(tester, 'group-name', 'Team');
      await _key(tester, 'member-p-tester');
      await _key(tester, 'host-p-tester');
      expect(find.text('A group has 2 to 16 pots'), findsNothing);
      expect(find.text('Choose a host among the members'), findsNothing);
      // Unticking the host clears it: only members can host.
      await _key(tester, 'member-p-tester');
      expect(find.byKey(const ValueKey('host-p-tester')), findsNothing);
      await _key(tester, 'member-p-research');
      await _key(tester, 'group-create');
      expect(find.text('Choose a host among the members'), findsOneWidget);
      expect(fixture.creates, isEmpty);
      await _key(tester, 'host-p-butler');
      await _key(tester, 'group-create');
      expect(fixture.creates.single['hostPotId'], 'p-butler');
      expect(fixture.creates.single['memberPotIds'], [
        'p-butler',
        'p-research',
      ]);
    });

    appTest('stops at 16 members', (tester) async {
      final fixture = GroupFixture();
      fixture.pots.addAll([
        for (var i = 0; i < 13; i++) potJson('p-x$i', 'Extra $i'),
      ]);
      await _pump(tester, fixture, location: _newGroup, height: 4000);
      final ids = [
        'p-butler',
        'p-tester',
        'p-research',
        'p-travel',
        for (var i = 0; i < 12; i++) 'p-x$i',
      ];
      for (final id in ids) {
        await _key(tester, 'member-$id');
      }
      expect(find.text('16 pots selected'), findsOneWidget);
      MemberCheckRow row(String id) =>
          tester.widget<MemberCheckRow>(find.byKey(ValueKey('member-$id')));
      expect(row('p-x12').onChanged, isNull);
      expect(row('p-x11').onChanged, isNotNull);
    });

    appTest('shows the Gateway\'s refusal as it is', (tester) async {
      final fixture = GroupFixture()
        ..createRefusal = apiError(
          400,
          'limit_reached',
          'You have 200 threads; delete one first',
        );
      final (_, container) = await _pump(tester, fixture, location: _newGroup);
      await _type(tester, 'group-name', 'Team');
      await _key(tester, 'member-p-butler');
      await _key(tester, 'member-p-tester');
      await _key(tester, 'host-p-butler');
      await _key(tester, 'group-create');
      expect(
        find.text('You have 200 threads; delete one first'),
        findsOneWidget,
      );
      expect(_location(container).toString(), _newGroup);
    });

    appTest('E6\'s "Create group" opens it', (tester) async {
      await _pump(tester, GroupFixture(), location: '/chat');
      await tester.tap(find.byTooltip('New pot or group'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Create group'));
      await tester.pumpAndSettle();
      expect(find.byType(NewGroupScreen), findsOneWidget);
    });
  });

  group('the group conversation (E33)', () {
    appTest('a group opened by its thread ID shows its conversation, not '
        'the placeholder', (tester) async {
      await _pump(tester, GroupFixture());
      expect(find.byType(GroupConversationScreen), findsOneWidget);
      expect(find.text('Item t-mobile'), findsNothing);
      expect(find.text('Mobile team'), findsOneWidget);
      expect(
        find.text('You, Butler (host), Researcher, Tester'),
        findsOneWidget,
      );
    });

    appTest('each pot\'s bubble has its avatar and name, the host tagged; '
        'the user\'s are on the right without an avatar', (tester) async {
      await _pump(tester, GroupFixture());
      // The list is reversed: newest first in the tree.
      final pots = tester.widgetList<Bubble>(_potBubble).toList().reversed;
      expect(
        [for (final b in pots) (b.name, b.hostLabel)],
        [('Butler', 'Host'), ('Researcher', null), ('Tester', null)],
      );
      for (final bubble in pots) {
        expect(bubble.avatar, isNotNull);
      }
      final mine = tester
          .widgetList<Bubble>(_myBubble)
          .toList()
          .reversed
          .toList();
      expect(mine, hasLength(2));
      for (final bubble in mine) {
        expect(bubble.avatar, isNull);
      }
      // The mention is in front of the body.
      final mentioned = mine[1].text as TextSpan;
      expect(
        mentioned.toPlainText(),
        '@Tester add a test for the iPad floating keyboard',
      );
      final screen = tester.getRect(find.byType(GroupConversationScreen));
      expect(
        tester.getRect(_myBubble.first).right,
        greaterThan(screen.right - 40),
      );
      expect(find.byType(HandoffLine), findsOneWidget);
      expect(find.byType(WorkCard), findsOneWidget);
    });

    appTest('without a mention the host answers: the post is the body', (
      tester,
    ) async {
      final fixture = GroupFixture();
      await _pump(tester, fixture);
      expect(find.text('Without @, Butler answers…'), findsOneWidget);
      await _send(tester, 'Any news?');
      expect(fixture.posts, [
        {'body': 'Any news?'},
      ]);
      expect(tester.widget<Bubble>(_myBubble.first).text, 'Any news?');
    });

    appTest('@ lists the members with their reach and budget; the post '
        'sends their IDs', (tester) async {
      final fixture = GroupFixture();
      await _pump(tester, fixture);
      await _key(tester, 'group-mention');
      final popover = tester.widget<MentionPopover<String?>>(
        find.byType(MentionPopover<String?>),
      );
      expect(
        [
          for (final o in popover.options)
            (o.value, o.name, o.detail, o.hostLabel),
        ],
        [
          (
            'p-butler',
            'Butler',
            'Can open work · This month \$4.20 / \$20',
            'Host',
          ),
          (
            'p-research',
            'Researcher',
            'Observing · This month \$1 / \$5',
            null,
          ),
          (
            'p-tester',
            'Tester',
            'Can open work · Today 0.8M / 2M tokens',
            null,
          ),
          (
            null,
            'Everyone',
            'Every member will be woken and reply, each on its own budget',
            null,
          ),
        ],
      );
      await _tap(tester, _option('Tester'));
      expect(find.byType(MentionPopover<String?>), findsNothing);
      expect(find.text('To Tester…'), findsOneWidget);
      await _mention(tester, 'Researcher');
      expect(find.text('To Tester, Researcher…'), findsOneWidget);
      // A target is taken out by tapping it.
      await _key(tester, 'group-target-p-research');
      expect(find.text('To Tester…'), findsOneWidget);
      await _mention(tester, 'Butler');
      await _send(tester, 'add a test');
      expect(fixture.posts, [
        {
          'body': 'add a test',
          'mentions': ['p-tester', 'p-butler'],
        },
      ]);
      // The targets are cleared after sending.
      expect(find.byKey(const ValueKey('group-targets')), findsNothing);
      expect(find.text('Without @, Butler answers…'), findsOneWidget);
      expect(
        (tester.widget<Bubble>(_myBubble.first).text as TextSpan).toPlainText(),
        '@Tester @Butler add a test',
      );
    });

    appTest('"@all" warns that every member wakes and sends all', (
      tester,
    ) async {
      final fixture = GroupFixture();
      await _pump(tester, fixture);
      await _mention(tester, 'Tester');
      await _key(tester, 'group-mention');
      expect(
        find.text(
          'Every member will be woken and reply, each on its own budget',
        ),
        findsOneWidget,
      );
      await _tap(tester, _option('Everyone'));
      // "@all" replaces the single members.
      expect(find.text('To Everyone…'), findsOneWidget);
      expect(find.byKey(const ValueKey('group-target-p-tester')), findsNothing);
      await _send(tester, 'Status, please');
      expect(fixture.posts, [
        {'body': 'Status, please', 'all': true},
      ]);
    });

    appTest('the popover closes with a tap outside', (tester) async {
      await _pump(tester, GroupFixture());
      await _key(tester, 'group-mention');
      expect(find.byType(MentionPopover<String?>), findsOneWidget);
      await tester.tapAt(const Offset(180, 120));
      await tester.pumpAndSettle();
      expect(find.byType(MentionPopover<String?>), findsNothing);
    });

    appTest('refused wakes and refusals are shown', (tester) async {
      final fixture = GroupFixture()
        ..refused = [
          {
            'potId': 'p-tester',
            'code': 'budget_exhausted',
            'reason': 'Out of budget for today',
          },
        ];
      await _pump(tester, fixture);
      await _mention(tester, 'Tester');
      await _send(tester, 'run it');
      expect(
        find.text('Tester was not woken: Out of budget for today'),
        findsOneWidget,
      );
      fixture.postRefusal = apiError(
        400,
        'invalid_input',
        'Mentions must be members of the thread',
      );
      await _send(tester, 'again');
      expect(
        find.text('Mentions must be members of the thread'),
        findsOneWidget,
      );
      // The draft stays.
      expect(find.text('again'), findsOneWidget);
    });

    appTest('reads again on threads_changed and pots_changed', (tester) async {
      final fixture = GroupFixture();
      final (gateway, _) = await _pump(tester, fixture);
      int reads() => gateway.sent('GET', '/api/threads/t-mobile').length;
      final before = reads();
      fixture.group['name'] = 'Mobile crew';
      _hint(gateway, 'threads_changed');
      await tester.pumpAndSettle();
      expect(reads(), before + 1);
      expect(find.text('Mobile crew'), findsOneWidget);
      fixture.pots[2]['profile'] = {'name': 'Scholar', 'avatarColor': 3};
      _hint(gateway, 'pots_changed');
      await tester.pumpAndSettle();
      expect(reads(), before + 2);
      expect(find.text('You, Butler (host), Scholar, Tester'), findsOneWidget);
    });

    appTest('the header opens the group\'s info', (tester) async {
      final (_, container) = await _pump(tester, GroupFixture());
      await _tap(tester, find.byTooltip('Group info'));
      expect(_location(container).toString(), _info);
      expect(find.byType(GroupInfoScreen), findsOneWidget);
    });
  });

  group('group info (E35)', () {
    appTest('lists you and the members with the host, and opens a member\'s '
        'profile', (tester) async {
      final (_, container) = await _pump(
        tester,
        GroupFixture(),
        location: _info,
      );
      expect(find.text('Group info'), findsOneWidget);
      expect(find.text('Members · 4'), findsOneWidget);
      expect(
        find.text('Creator · can change the members and the host'),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('group-member-p-butler')),
          matching: find.byType(HostTag),
        ),
        findsOneWidget,
      );
      expect(
        find.text('Manager · Can open work · This month \$4.20 / \$20'),
        findsOneWidget,
      );
      await _key(tester, 'group-member-p-research');
      expect(
        _location(container).toString(),
        '/chat?open=pot%3Ap-research&side=profile',
      );
    });

    appTest('changes the name and the avatar with the revision', (
      tester,
    ) async {
      final fixture = GroupFixture();
      await _pump(tester, fixture, location: _info);
      await _key(tester, 'group-edit-look');
      await _type(tester, 'group-edit-name', 'Mobile crew');
      await _key(tester, 'swatch-2');
      await _key(tester, 'group-edit-save');
      expect(fixture.patches, [
        {'revision': 1, 'name': 'Mobile crew', 'avatarColor': 2},
      ]);
      expect(find.byKey(const ValueKey('group-edit-save')), findsNothing);
      expect(find.text('Mobile crew'), findsOneWidget);
      // Back to the members' faces: the colour is removed.
      await _key(tester, 'group-edit-look');
      await _key(tester, 'swatch-faces');
      await _key(tester, 'group-edit-save');
      expect(fixture.patches.last, {'revision': 2, 'avatarColor': null});
    });

    appTest('changes the members: 2 to 16, and the host stays', (tester) async {
      final fixture = GroupFixture();
      await _pump(tester, fixture, location: _info);
      await _key(tester, 'group-edit-members');
      MemberCheckRow row(String id) =>
          tester.widget<MemberCheckRow>(find.byKey(ValueKey('member-$id')));
      expect(row('p-butler').onChanged, isNull);
      expect(find.byKey(const ValueKey('member-p-old')), findsNothing);
      await _key(tester, 'member-p-research');
      await _key(tester, 'member-p-tester');
      expect(find.text('A group has 2 to 16 pots'), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(find.byKey(const ValueKey('group-edit-save')))
            .onPressed,
        isNull,
      );
      await _key(tester, 'member-p-travel');
      await _key(tester, 'group-edit-save');
      expect(fixture.patches, [
        {
          'revision': 1,
          'memberPotIds': ['p-butler', 'p-travel'],
        },
      ]);
      expect(find.text('Members · 3'), findsOneWidget);
    });

    appTest('changes the host among the members', (tester) async {
      final fixture = GroupFixture();
      await _pump(tester, fixture, location: _info);
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('group-edit-host')),
          matching: find.text('Butler'),
        ),
        findsOneWidget,
      );
      await _key(tester, 'group-edit-host');
      expect(find.byKey(const ValueKey('host-p-travel')), findsNothing);
      await _key(tester, 'host-p-tester');
      await _key(tester, 'group-edit-save');
      expect(fixture.patches, [
        {'revision': 1, 'hostPotId': 'p-tester'},
      ]);
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('group-edit-host')),
          matching: find.text('Tester'),
        ),
        findsOneWidget,
      );
    });

    appTest('a 409 reads the group again and keeps the edit', (tester) async {
      final fixture = GroupFixture()..conflictOnce = true;
      final (gateway, _) = await _pump(tester, fixture, location: _info);
      final reads = gateway.sent('GET', '/api/threads/t-mobile').length;
      await _key(tester, 'group-edit-look');
      await _type(tester, 'group-edit-name', 'Mobile squad');
      await _key(tester, 'group-edit-save');
      expect(find.byKey(const ValueKey('group-conflict')), findsOneWidget);
      expect(
        find.text(
          'The group changed on another device. Your edit is kept; check '
          'it and save again.',
        ),
        findsOneWidget,
      );
      expect(
        gateway.sent('GET', '/api/threads/t-mobile').length,
        greaterThan(reads),
      );
      // The edit is still there; the next save uses the new revision.
      expect(find.text('Mobile squad'), findsOneWidget);
      await _key(tester, 'group-edit-save');
      expect(fixture.patches, [
        {'revision': 1, 'name': 'Mobile squad'},
        {'revision': 2, 'name': 'Mobile squad'},
      ]);
      expect(find.byKey(const ValueKey('group-edit-save')), findsNothing);
      expect(find.byKey(const ValueKey('group-info-name')), findsOneWidget);
      expect(find.text('Mobile squad'), findsOneWidget);
    });

    appTest('another refusal shows its message', (tester) async {
      final fixture = GroupFixture()
        ..patchRefusal = apiError(
          400,
          'invalid_input',
          'A group name is 1 to 60 characters',
        );
      await _pump(tester, fixture, location: _info);
      await _key(tester, 'group-edit-look');
      await _type(tester, 'group-edit-name', 'Crew');
      await _key(tester, 'group-edit-save');
      expect(find.text('A group name is 1 to 60 characters'), findsOneWidget);
      expect(find.byKey(const ValueKey('group-edit-save')), findsOneWidget);
    });

    appTest('delete asks first, then returns to the Chat tab', (tester) async {
      final fixture = GroupFixture();
      final (gateway, container) = await _pump(
        tester,
        fixture,
        location: _info,
      );
      await _key(tester, 'group-delete');
      expect(find.text('Delete Mobile team?'), findsOneWidget);
      await _tap(tester, find.text('Cancel'));
      expect(gateway.sent('DELETE', '/api/threads/t-mobile'), isEmpty);
      await _key(tester, 'group-delete');
      await _key(tester, 'confirm-delete-group');
      expect(fixture.deletes, 1);
      expect(_location(container).toString(), '/chat');
      expect(find.text('Mobile team'), findsNothing);
    });

    appTest('at 1200 and wider it is the right column beside the '
        'conversation', (tester) async {
      final (_, container) = await _pump(
        tester,
        GroupFixture(),
        location: _info,
        width: 1300,
        height: 900,
      );
      expect(find.byType(GroupConversationScreen), findsOneWidget);
      expect(find.byType(GroupInfoScreen), findsOneWidget);
      await _tap(tester, find.byTooltip('Close'));
      expect(_location(container).toString(), _group);
      expect(find.byType(GroupInfoScreen), findsNothing);
    });
  });

  group('golden images', () {
    Future<void> golden(
      WidgetTester tester,
      String location,
      ThemeMode mode,
    ) async {
      await tester.runAsync(loadGoldenFonts);
      final (_, container) = await _pump(
        tester,
        GroupFixture(),
        location: location,
        height: 812,
      );
      container.read(themeModeProvider.notifier).select(mode);
      await tester.pumpAndSettle();
    }

    for (final mode in [ThemeMode.light, ThemeMode.dark]) {
      testWidgets('new group 375 ${mode.name}', (tester) async {
        await golden(tester, _newGroup, mode);
        await _type(tester, 'group-name', 'Mobile team');
        for (final id in ['p-butler', 'p-research', 'p-tester']) {
          await _key(tester, 'member-$id');
        }
        await _key(tester, 'host-p-butler');
        await tester.drag(
          find.byKey(const ValueKey('group-scroll')),
          const Offset(0, 3000),
        );
        await tester.pumpAndSettle();
        FocusManager.instance.primaryFocus?.unfocus();
        await tester.pumpAndSettle();
        await expectLater(
          find.byType(MaterialApp),
          matchesGoldenFile('goldens/new_group_375_${mode.name}.png'),
        );
        await disposeApp(tester);
      }, tags: ['golden']);

      testWidgets('group mention 375 ${mode.name}', (tester) async {
        await golden(tester, _group, mode);
        await _key(tester, 'group-mention');
        await expectLater(
          find.byType(MaterialApp),
          matchesGoldenFile('goldens/group_mention_375_${mode.name}.png'),
        );
        await disposeApp(tester);
      }, tags: ['golden']);

      testWidgets('group info 375 ${mode.name}', (tester) async {
        await golden(tester, _info, mode);
        await expectLater(
          find.byType(MaterialApp),
          matchesGoldenFile('goldens/group_info_375_${mode.name}.png'),
        );
        await disposeApp(tester);
      }, tags: ['golden']);
    }
  });
}
