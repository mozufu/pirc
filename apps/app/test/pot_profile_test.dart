import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_app/src/chat/pot_conversation_screen.dart';
import 'package:pirc_app/src/chat/pot_form.dart';
import 'package:pirc_app/src/chat/pot_profile_screen.dart';
import 'package:pirc_app/src/chat/pot_settings_screen.dart';
import 'package:pirc_app/src/format.dart';
import 'package:pirc_app/src/preferences.dart';
import 'package:pirc_app/src/router.dart';
import 'package:pirc_ui/pirc_ui.dart';

import 'support/chat_fixtures.dart';
import 'support/fonts.dart';
import 'support/harness.dart';
import 'support/work_fixtures.dart';

const _profile = '/chat?open=pot:p-butler&side=profile';
const _settings = '/chat?open=settings:p-butler';

const _personality =
    'Brief, conclusion first. Reminds you without pushing. Asks you when '
    'unsure instead of guessing.';

Future<(FakeGateway, ProviderContainer)> _pump(
  WidgetTester tester,
  PotProfileFixture fixture, {
  String location = _profile,
  double width = 375,
  double height = 2400,
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

Future<void> _tapKey(WidgetTester tester, String key) =>
    _tap(tester, find.byKey(ValueKey(key)));

Finder _in(String key, Finder matching) =>
    find.descendant(of: find.byKey(ValueKey(key)), matching: matching);

Finder _action(String label) =>
    find.descendant(of: find.byType(ProfileHeader), matching: find.text(label));

/// The body every section sends unchanged.
Map<String, Object?> _profileJson({int color = 1, String name = 'Butler'}) => {
  'name': name,
  'avatarColor': color,
  'personality': _personality,
};

Map<String, Object?> _workJson({
  String intro = 'Manager: sorts your to-dos and gives work to the right pots',
}) => {
  'intro': intro,
  'description':
      'Looks at what needs your decision first; picks pots with just enough '
      'permissions; doesn\'t edit files.',
  'responsibilities': [
    {'title': 'Sort your decisions every morning', 'detail': '09:00 · summary'},
    {
      'title': 'Watch for stuck work in pirc mobile',
      'detail': 'Suggests something when one is stuck over 30 minutes',
    },
  ],
};

String _fieldText(WidgetTester tester, String key) =>
    tester.widget<TextField>(find.byKey(ValueKey(key))).controller!.text;

Map<String, Object?> _permissionsJson({
  List<Map<String, Object?>> extraObserve = const [],
}) => {
  'reach': 'observe',
  'observe': [
    {'kind': 'workspace', 'ref': 'laptop:pirc', 'lead': false},
    ...extraObserve,
  ],
  'dm': {
    'send': 'all',
    'receive': 'selected',
    'sendTo': <String>[],
    'receiveFrom': ['p-tester', 'p-research'],
  },
  'workLocations': <Object?>[],
  'maxConcurrentWorks': 2,
  'budgetMoneyMonthMicros': 20000000,
  'budgetTokensDay': 2000000,
};

void main() {
  group('the profile', () {
    appTest('shows the header, the actions, the responsibilities, what it '
        'may do, its recent activity and its memory', (tester) async {
      final (gateway, _) = await _pump(tester, PotProfileFixture());
      expect(find.byType(PotProfileScreen), findsOneWidget);
      final header = tester.widget<ProfileHeader>(find.byType(ProfileHeader));
      expect(header.name, 'Butler');
      expect(
        header.intro,
        'Manager: sorts your to-dos and gives work to the right pots',
      );
      expect(
        [for (final chip in header.chips) (chip.label, chip.dot)],
        [('Observing', 'accent.default'), ('Hosts 1 group', null)],
      );
      expect(
        [for (final action in header.actions) action.label],
        ['Message', 'Pause', 'Hand over', 'Activity'],
      );
      expect(
        find.byWidgetPredicate((w) => w is Avatar && w.size == AvatarSize.lg),
        findsOneWidget,
      );
      expect(find.text('Sort your decisions every morning'), findsOneWidget);
      expect(find.text('09:00 · summary'), findsOneWidget);
      // What it may do, in plain words.
      expect(_in('may-do-reach', find.text('Watch and suggest')), findsOne);
      expect(_in('may-do-observe', find.text('pirc mobile')), findsOne);
      expect(_in('may-do-dm-send', find.text('All pots')), findsOne);
      expect(
        _in('may-do-dm-receive', find.text('Tester, Researcher')),
        findsOne,
      );
      expect(
        _in(
          'may-do-budget',
          find.text('\$20 a month · 2,000,000 tokens a day'),
        ),
        findsOne,
      );
      expect(_in('may-do-review', find.text('Every 2 days')), findsOne);
      // Only answering or observing: no places to open work.
      expect(find.byKey(const ValueKey('may-do-places')), findsNothing);
      // The five newest activity rows of this pot.
      final read = gateway.sent('GET', '/api/activity').single;
      expect(read.query, {'potId': 'p-butler', 'limit': '5'});
      final rows = tester.widgetList<LogRow>(find.byType(LogRow)).toList();
      expect(rows, hasLength(5));
      expect(
        [for (final row in rows) (row.tag.label, row.tag.tone, row.target)],
        [
          ('Needs approval', LogTagTone.attention, null),
          ('Handed over', LogTagTone.plain, '→ Tester'),
          ('Handed over', LogTagTone.plain, '→ Researcher'),
          ('Needs your OK', LogTagTone.attention, null),
          ('Message', LogTagTone.direct, '→ You'),
        ],
      );
      expect(rows.first.time, '10:45');
      // Its memory.
      expect(
        find.text('The user reads summaries at 09:00 and prefers lists.'),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('forget-n1')), findsOneWidget);
      expect(find.byKey(const ValueKey('forget-n2')), findsOneWidget);
    });

    appTest('a pot that may start work lists where and how many', (
      tester,
    ) async {
      final fixture = PotProfileFixture();
      final permissions = {
        ...fixture.pot['permissions']! as Map<String, Object?>,
        'reach': 'work',
        'workLocations': [
          {'workspaceId': 'laptop:pirc', 'access': 'write'},
        ],
        'budgetMoneyMonthMicros': null,
      };
      fixture.pot = {...fixture.pot, 'permissions': permissions};
      await _pump(tester, fixture);
      expect(_in('may-do-reach', find.text('Can start work')), findsOne);
      expect(
        _in('may-do-places', find.text('pirc mobile (Read and write)')),
        findsOne,
      );
      expect(_in('may-do-works', find.text('At most 2')), findsOne);
      expect(
        _in('may-do-budget', find.text('2,000,000 tokens a day')),
        findsOne,
      );
    });

    appTest('See all and Activity open the Activity tab filtered to the '
        'pot', (tester) async {
      final (_, container) = await _pump(tester, PotProfileFixture());
      await _tapKey(tester, 'profile-see-all');
      expect(_location(container).toString(), '/activity?pot=p-butler');

      container.read(routerProvider).go(_profile);
      await tester.pumpAndSettle();
      await _tap(tester, _action('Activity'));
      expect(_location(container).toString(), '/activity?pot=p-butler');
    });

    appTest('Message opens the conversation, Settings the settings and '
        'Hand over the handover', (tester) async {
      final (_, container) = await _pump(tester, PotProfileFixture());
      await _tap(tester, _action('Message'));
      expect(_location(container).queryParameters, {'open': 'pot:p-butler'});
      expect(find.byType(PotConversationScreen), findsOneWidget);

      container.read(routerProvider).go(_profile);
      await tester.pumpAndSettle();
      await _tapKey(tester, 'profile-settings');
      expect(_location(container).queryParameters, {
        'open': 'settings:p-butler',
      });
      expect(find.byType(PotSettingsScreen), findsOneWidget);

      container.read(routerProvider).go(_profile);
      await tester.pumpAndSettle();
      await _tap(tester, _action('Hand over'));
      expect(_location(container).queryParameters, {
        'open': 'handover-new:p-butler',
      });
    });

    appTest('at tablet width tapping outside the 440 pane closes it', (
      tester,
    ) async {
      final (_, container) = await _pump(
        tester,
        PotProfileFixture(),
        width: 700,
        height: 812,
      );
      expect(find.byType(PotProfileScreen), findsOneWidget);
      // The pane is 440 wide at the right; this point is outside it.
      await tester.tapAt(const Offset(100, 300));
      await tester.pumpAndSettle();
      expect(_location(container).toString(), '/chat?open=pot%3Ap-butler');
      expect(find.byType(PotProfileScreen), findsNothing);
      expect(find.byType(PotConversationScreen), findsOneWidget);
    });

    appTest('Back on a phone returns to the conversation', (tester) async {
      final (_, container) = await _pump(tester, PotProfileFixture());
      await _tap(tester, find.byTooltip('Back').last);
      expect(_location(container).queryParameters, {'open': 'pot:p-butler'});
    });

    appTest('at 1300 it is the right column beside the conversation; ✕ '
        'closes it', (tester) async {
      final (_, container) = await _pump(
        tester,
        PotProfileFixture(),
        width: 1300,
        height: 900,
      );
      expect(find.byType(PotConversationScreen), findsOneWidget);
      expect(find.byType(PotProfileScreen), findsOneWidget);
      final profile = tester.getRect(find.byType(PotProfileScreen));
      expect(profile.right, 1300);
      expect(profile.width, lessThanOrEqualTo(401));
      await _tap(tester, find.byTooltip('Close'));
      expect(_location(container).queryParameters, {'open': 'pot:p-butler'});
      expect(find.byType(PotProfileScreen), findsNothing);
    });

    appTest('reads the activity again on activity_changed and the memory '
        'on pots_changed', (tester) async {
      final fixture = PotProfileFixture();
      final (gateway, _) = await _pump(tester, fixture);
      fixture.activity = fixture.activity.sublist(1);
      _hint(gateway, 'activity_changed');
      await tester.pumpAndSettle();
      expect(gateway.sent('GET', '/api/activity'), hasLength(2));
      expect(find.byType(LogRow), findsNWidgets(4));

      fixture.notes = [
        ...fixture.notes,
        {'id': 'n3', 'content': 'Researcher is out on Fridays.'},
      ];
      _hint(gateway, 'pots_changed');
      await tester.pumpAndSettle();
      expect(find.text('Researcher is out on Fridays.'), findsOneWidget);
    });

    appTest('Forget removes a note and reads the memory again', (tester) async {
      final fixture = PotProfileFixture();
      final (gateway, _) = await _pump(tester, fixture);
      final reads = gateway.sent('GET', '/api/pots/p-butler/memory').length;
      await _tapKey(tester, 'forget-n1');
      expect(
        gateway.sent('DELETE', '/api/pots/p-butler/memory/n1'),
        hasLength(1),
      );
      expect(
        gateway.sent('GET', '/api/pots/p-butler/memory').length,
        greaterThan(reads),
      );
      expect(
        find.text('The user reads summaries at 09:00 and prefers lists.'),
        findsNothing,
      );
      expect(find.byKey(const ValueKey('note-n2')), findsOneWidget);
    });

    appTest('empty responsibilities, activity and memory say so', (
      tester,
    ) async {
      final fixture = PotProfileFixture()
        ..activity = []
        ..notes = [];
      fixture.pot = {
        ...fixture.pot,
        'work': {'intro': 'Manager'},
      };
      await _pump(tester, fixture);
      expect(find.text('No responsibilities yet.'), findsOneWidget);
      expect(find.text('Nothing yet.'), findsOneWidget);
      expect(find.text('No notes yet.'), findsOneWidget);
    });
  });

  group('pause and resume', () {
    appTest('Pause opens the sheet with the settled text; Pause there '
        'pauses with the revision and the profile follows', (tester) async {
      final fixture = PotProfileFixture();
      final (gateway, _) = await _pump(tester, fixture);
      await _tap(tester, _action('Pause'));
      expect(find.text('Pause Butler?'), findsOneWidget);
      for (final line in [
        'While paused',
        'No new messages or events reach it',
        'Its reviews and reminders wait',
        'It starts no work',
        'Goes on',
        'Works it already opened keep running',
        'Its conversations stay readable',
        'Nothing is handed over',
      ]) {
        expect(find.text(line), findsOneWidget, reason: line);
      }
      await _tapKey(tester, 'pause-confirm');
      expect(
        [
          for (final r in gateway.sent('POST', '/api/pots/p-butler/pause'))
            r.json,
        ],
        [
          {'revision': 7},
        ],
      );
      expect(find.byKey(const ValueKey('pause-sheet')), findsNothing);
      final header = tester.widget<ProfileHeader>(find.byType(ProfileHeader));
      expect(header.chips.first.label, 'Paused');
      expect(
        [for (final action in header.actions) action.label],
        ['Message', 'Resume', 'Hand over', 'Activity'],
      );
      expect(find.byKey(const ValueKey('profile-paused')), findsOneWidget);
    });

    appTest('Cancel leaves the pot as it is', (tester) async {
      final (gateway, _) = await _pump(tester, PotProfileFixture());
      await _tap(tester, _action('Pause'));
      await _tap(tester, find.text('Cancel'));
      expect(gateway.sent('POST', '/api/pots/p-butler/pause'), isEmpty);
      expect(find.byKey(const ValueKey('pause-sheet')), findsNothing);
    });

    appTest('a refused pause shows its message in the sheet', (tester) async {
      final fixture = PotProfileFixture();
      final gateway = fixture.install();
      gateway.json['POST /api/pots/p-butler/pause'] = (_) => apiError(
        409,
        'invalid_transition',
        'The pot cannot change to that state',
      );
      await pumpApp(
        tester,
        gateway: gateway,
        width: 375,
        height: 2400,
        location: _profile,
        reduceMotion: true,
      );
      await _tap(tester, _action('Pause'));
      await _tapKey(tester, 'pause-confirm');
      expect(find.text('The pot cannot change to that state'), findsOneWidget);
      expect(find.byKey(const ValueKey('pause-sheet')), findsOneWidget);
    });

    appTest('Resume resumes a paused pot with the revision', (tester) async {
      final fixture = PotProfileFixture();
      fixture.pot = {...fixture.pot, 'state': 'paused'};
      fixture.pots[0]['state'] = 'paused';
      final (gateway, _) = await _pump(tester, fixture);
      expect(find.byKey(const ValueKey('profile-paused')), findsOneWidget);
      expect(
        find.textContaining(
          'It does not observe, suggest or start new work; its '
          'responsibilities and follow-ups stay.',
        ),
        findsOneWidget,
      );
      await _tap(tester, _action('Resume'));
      expect(
        [
          for (final r in gateway.sent('POST', '/api/pots/p-butler/resume'))
            r.json,
        ],
        [
          {'revision': 7},
        ],
      );
      final header = tester.widget<ProfileHeader>(find.byType(ProfileHeader));
      expect(header.actions[1].label, 'Pause');
      expect(find.byKey(const ValueKey('profile-paused')), findsNothing);
    });
  });

  group('settings', () {
    appTest('each section saves on its own with the revision (exact '
        'bodies)', (tester) async {
      final fixture = PotProfileFixture();
      final (gateway, _) = await _pump(tester, fixture, location: _settings);
      expect(find.byType(PotSettingsScreen), findsOneWidget);
      expect(find.text("Butler's settings"), findsOneWidget);
      // Nothing changed: nothing to save.
      for (final section in potSettingsSections) {
        final save = tester.widget<FilledButton>(
          find.byKey(ValueKey('save-$section')),
        );
        expect(save.onPressed, isNull, reason: section);
      }

      // ① the colour.
      await _tapKey(tester, 'swatch-3');
      await _tapKey(tester, 'save-look');
      expect(fixture.patches.last, {
        'revision': 7,
        'profile': _profileJson(color: 3),
      });
      expect(find.byKey(const ValueKey('saved-look')), findsOneWidget);

      // ② the intro, with the next revision.
      await tester.enterText(
        find.byKey(const ValueKey('pot-intro')),
        'Sorts your to-dos',
      );
      await tester.pumpAndSettle();
      await _tapKey(tester, 'save-work');
      expect(fixture.patches.last, {
        'revision': 8,
        'work': _workJson(intro: 'Sorts your to-dos'),
      });

      // ③ the calendar and a weekly review: permissions and autonomy.
      await _tap(tester, _in('observe-calendar', find.byType(PircSwitch)));
      await _tap(tester, _in('review', find.text('1 week')));
      await _tapKey(tester, 'save-reach');
      expect(fixture.patches.last, {
        'revision': 9,
        'permissions': {
          'reach': 'observe',
          'observe': [
            {'kind': 'workspace', 'ref': 'laptop:pirc', 'lead': false},
            {'kind': 'calendar', 'ref': '', 'lead': false},
          ],
          'dm': {
            'send': 'all',
            'receive': 'selected',
            'sendTo': <String>[],
            'receiveFrom': ['p-tester', 'p-research'],
          },
          'workLocations': <Object?>[],
          'maxConcurrentWorks': 2,
          'budgetMoneyMonthMicros': 20000000,
          'budgetTokensDay': 2000000,
        },
        'autonomy': {'intervalS': 604800},
      });

      // ④ "adjust by itself" off.
      await _tapKey(tester, 'thinking-auto');
      await _tapKey(tester, 'save-models');
      expect(fixture.patches.last, {
        'revision': 10,
        'models': {
          'main': {'provider': 'anthropic', 'model': 'claude-sonnet'},
          'fallbacks': <Object?>[],
          'thinking': 'medium',
          'thinkingAuto': false,
          'workModels': <Object?>[],
        },
      });
      expect(fixture.patches, hasLength(4));
      expect(gateway.sent('PATCH', '/api/pots/p-butler'), hasLength(4));
    });

    appTest('an unsaved edit of one section survives saving another', (
      tester,
    ) async {
      final fixture = PotProfileFixture();
      await _pump(tester, fixture, location: _settings);
      await _tapKey(tester, 'swatch-4');
      await tester.enterText(
        find.byKey(const ValueKey('pot-intro')),
        'Sorts your to-dos',
      );
      await tester.pumpAndSettle();
      await _tapKey(tester, 'save-work');
      expect(fixture.patches.single.keys, {'revision', 'work'});
      // ① still has its edit and can be saved with the new revision.
      await _tapKey(tester, 'save-look');
      expect(fixture.patches.last, {
        'revision': 8,
        'profile': _profileJson(color: 4),
      });
    });

    appTest('a problem in a section stops its save', (tester) async {
      final fixture = PotProfileFixture();
      await _pump(tester, fixture, location: _settings);
      await tester.enterText(find.byKey(const ValueKey('pot-name')), ' ');
      await tester.pumpAndSettle();
      await _tapKey(tester, 'save-look');
      expect(fixture.patches, isEmpty);
      expect(find.byKey(const ValueKey('issue-nameMissing')), findsOneWidget);
    });

    Map<String, Object?> models({bool auto = false}) => {
      'models': {
        'main': {'provider': 'anthropic', 'model': 'claude-sonnet'},
        'fallbacks': <Object?>[],
        'thinking': 'medium',
        'thinkingAuto': auto,
        'workModels': <Object?>[],
      },
    };
    final edits =
        <String, (Future<void> Function(WidgetTester), Map<String, Object?>)>{
          'look': (
            (tester) => _tapKey(tester, 'swatch-3'),
            {'profile': _profileJson(color: 3)},
          ),
          'work': (
            (tester) async {
              await tester.enterText(
                find.byKey(const ValueKey('pot-intro')),
                'Sorts your to-dos',
              );
              await tester.pumpAndSettle();
            },
            {'work': _workJson(intro: 'Sorts your to-dos')},
          ),
          'reach': (
            (tester) => _tap(tester, _in('review', find.text('1 week'))),
            {
              'permissions': _permissionsJson(),
              'autonomy': {'intervalS': 604800},
            },
          ),
          'models': ((tester) => _tapKey(tester, 'thinking-auto'), models()),
        };
    for (final MapEntry(key: section, value: (edit, body)) in edits.entries) {
      appTest('a 409 on $section reads the pot again, keeps the edit and '
          'saves with the new revision', (tester) async {
        final fixture = PotProfileFixture()..conflictOnce = true;
        final (gateway, _) = await _pump(tester, fixture, location: _settings);
        final reads = gateway.sent('GET', '/api/pots/p-butler').length;
        await edit(tester);
        // Another device changed a section the user did not touch: the
        // name while ② is edited, else the intro.
        final (field, changed) = section == 'work'
            ? ('pot-name', 'Head butler')
            : ('pot-intro', 'Changed on the phone');
        fixture.pot = section == 'work'
            ? {
                ...fixture.pot,
                'profile': {
                  ...fixture.pot['profile']! as Map<String, Object?>,
                  'name': changed,
                },
              }
            : {
                ...fixture.pot,
                'work': {
                  ...fixture.pot['work']! as Map<String, Object?>,
                  'intro': changed,
                },
              };
        await _tapKey(tester, 'save-$section');
        expect(fixture.patches.single, {'revision': 7, ...body});
        expect(
          gateway.sent('GET', '/api/pots/p-butler').length,
          greaterThan(reads),
        );
        expect(find.byKey(ValueKey('conflict-$section')), findsOneWidget);
        // The section the user did not touch follows the pot.
        expect(_fieldText(tester, field), changed);
        // The edit is still there and saves with the new revision.
        await _tapKey(tester, 'save-$section');
        expect(fixture.patches.last, {'revision': 8, ...body});
        expect(find.byKey(ValueKey('saved-$section')), findsOneWidget);
        expect(find.byKey(ValueKey('conflict-$section')), findsNothing);
      });
    }

    appTest('after a 409, another edited section the pot changed under '
        'says so too and keeps the user\'s value', (tester) async {
      final fixture = PotProfileFixture()..conflictOnce = true;
      await _pump(tester, fixture, location: _settings);
      await _tapKey(tester, 'swatch-3');
      await tester.enterText(find.byKey(const ValueKey('pot-intro')), 'Mine');
      await tester.pumpAndSettle();
      fixture.pot = {
        ...fixture.pot,
        'work': {
          ...fixture.pot['work']! as Map<String, Object?>,
          'intro': 'Changed on the phone',
        },
      };
      await _tapKey(tester, 'save-look');
      expect(find.byKey(const ValueKey('conflict-look')), findsOneWidget);
      expect(find.byKey(const ValueKey('conflict-work')), findsOneWidget);
      expect(_fieldText(tester, 'pot-intro'), 'Mine');
      await _tapKey(tester, 'save-work');
      expect(fixture.patches.last, {
        'revision': 8,
        'work': _workJson(intro: 'Mine'),
      });
    });

    appTest('the other sections take a change from elsewhere; an edited '
        'one keeps the user\'s value', (tester) async {
      final fixture = PotProfileFixture();
      final (gateway, _) = await _pump(tester, fixture, location: _settings);
      await _tapKey(tester, 'swatch-2');
      fixture.pot = {
        ...fixture.pot,
        'revision': 8,
        'work': {
          ...fixture.pot['work']! as Map<String, Object?>,
          'intro': 'Changed on the phone',
        },
      };
      _hint(gateway, 'pots_changed');
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('pot-intro')))
            .controller!
            .text,
        'Changed on the phone',
      );
      expect(
        tester.widget<PotLookForm>(find.byType(PotLookForm)).draft.avatarColor,
        2,
      );
      // Only the work changed, so ① saves with the new revision.
      await _tapKey(tester, 'save-look');
      expect(fixture.patches.last['revision'], 8);
    });

    appTest('a refused save shows the message on its section', (tester) async {
      final fixture = PotProfileFixture();
      final gateway = fixture.install();
      gateway.json['PATCH /api/pots/p-butler'] = (_) =>
          apiError(400, 'invalid_input', 'name is too long');
      await pumpApp(
        tester,
        gateway: gateway,
        width: 375,
        height: 2400,
        location: _settings,
        reduceMotion: true,
      );
      await _tapKey(tester, 'swatch-3');
      await _tapKey(tester, 'save-look');
      expect(_in('error-look', find.text('name is too long')), findsOne);
    });

    appTest('the actions at the bottom: pause, hand over, archive or '
        'delete; Back goes to the profile', (tester) async {
      final (gateway, container) = await _pump(
        tester,
        PotProfileFixture(),
        location: _settings,
      );
      await _tapKey(tester, 'settings-pause');
      expect(find.byKey(const ValueKey('pause-sheet')), findsOneWidget);
      await _tapKey(tester, 'pause-confirm');
      expect(gateway.sent('POST', '/api/pots/p-butler/pause'), hasLength(1));
      expect(_in('settings-pause', find.text('Resume')), findsOne);
      await _tapKey(tester, 'settings-pause');
      expect(gateway.sent('POST', '/api/pots/p-butler/resume'), hasLength(1));
      expect(_in('settings-pause', find.text('Pause…')), findsOne);

      await _tapKey(tester, 'settings-handover');
      expect(_location(container).queryParameters, {
        'open': 'handover-new:p-butler',
      });

      container.read(routerProvider).go(_settings);
      await tester.pumpAndSettle();
      await _tapKey(tester, 'settings-retire');
      expect(_location(container).queryParameters, {'open': 'retire:p-butler'});

      container.read(routerProvider).go(_settings);
      await tester.pumpAndSettle();
      await _tap(tester, find.byTooltip('Back'));
      expect(_location(container).queryParameters, {
        'open': 'pot:p-butler',
        'side': 'profile',
      });
    });

    appTest('section=reach opens the settings at step ③', (tester) async {
      await _pump(
        tester,
        PotProfileFixture(),
        location: '$_settings&section=reach',
        height: 800,
      );
      final top = tester.getTopLeft(
        find.byKey(const ValueKey('section-reach')),
      );
      expect(top.dy, lessThan(120));
    });

    appTest('desktop keeps the settings 720 wide, centred', (tester) async {
      await _pump(
        tester,
        PotProfileFixture(),
        location: _settings,
        width: 1300,
        height: 900,
      );
      final save = tester.getRect(find.byKey(const ValueKey('save-look')));
      final pane = tester.getRect(find.byType(PotSettingsScreen));
      expect(pane.right - save.right, greaterThan(16));
      final section = tester.getRect(
        find.byKey(const ValueKey('section-look')),
      );
      expect(section.width, 720);
      expect(
        (section.left - pane.left - (pane.right - section.right)).abs(),
        lessThan(1),
      );
    });
  });

  group('golden images', () {
    for (final name in ['pot_settings', 'pot_pause']) {
      for (final mode in [ThemeMode.light, ThemeMode.dark]) {
        testWidgets('$name 375 ${mode.name}', (tester) async {
          await tester.runAsync(loadGoldenFonts);
          final (_, container) = await _pump(
            tester,
            PotProfileFixture(),
            location: name == 'pot_settings' ? _settings : _profile,
            height: 812,
          );
          container.read(themeModeProvider.notifier).select(mode);
          await tester.pumpAndSettle();
          if (name == 'pot_pause') {
            // As E13: the profile stays at its top under the sheet.
            await tester.tap(_action('Pause'));
            await tester.pumpAndSettle();
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
