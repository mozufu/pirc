import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_app/src/chat/handover_parts.dart';
import 'package:pirc_app/src/chat/handover_screen.dart';
import 'package:pirc_app/src/chat/pot_settings_screen.dart';
import 'package:pirc_app/src/chat/retire_screen.dart';
import 'package:pirc_app/src/format.dart';
import 'package:pirc_app/src/preferences.dart';
import 'package:pirc_app/src/router.dart';
import 'package:pirc_ui/pirc_ui.dart';

import 'support/chat_fixtures.dart';
import 'support/fonts.dart';
import 'support/harness.dart';
import 'support/work_fixtures.dart';

const _start = '/chat?open=handover-new:p-butler';
const _proposal = '/chat?open=handover:h1';
const _retire = '/chat?open=retire:p-butler';

Future<(FakeGateway, ProviderContainer)> _pump(
  WidgetTester tester,
  HandoverFixture fixture, {
  required String location,
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

HandoverItem _item(WidgetTester tester, String key) =>
    tester.widget<HandoverItem>(find.byKey(ValueKey('held-$key')));

bool _enabled(WidgetTester tester, String key) =>
    tester.widget<FilledButton>(find.byKey(ValueKey(key))).onPressed != null;

/// A Chat tab row: its name and intro are one rich text.
Finder _chatRow(String name) =>
    find.textContaining(RegExp('^$name\uFFFC'), findRichText: true);

Map<String, Object?> _to(String kind, [String? potId]) => {
  'kind': kind,
  'potId': ?potId,
};

/// The retire targets in the held order: works go to the user, the rest
/// nowhere, unless [changes] says otherwise (by ref).
List<Map<String, Object?>> _targets([
  Map<String, Map<String, Object?>> changes = const {},
]) => [
  for (final (kind, ref) in [
    ('responsibility', 'r1'),
    ('responsibility', 'r2'),
    ('reminder', 'rem1'),
    ('work', 'w-sched'),
    ('group_host', 't-mobile'),
  ])
    {
      'kind': kind,
      'ref': ref,
      'to': changes[ref] ?? (kind == 'work' ? _to('user') : _to('none')),
    },
];

/// Opens the pick sheet of [ref] (or "Give everything to…") and picks
/// [choice] (`p-tester`, `user`, `none`, …).
Future<void> _pick(WidgetTester tester, String? ref, String choice) async {
  await _tap(
    tester,
    ref == null
        ? find.byKey(const ValueKey('retire-give-all'))
        : find.byKey(
            ValueKey(
              'target-${switch (ref) {
                'r1' || 'r2' => 'responsibility',
                'rem1' => 'reminder',
                'w-sched' => 'work',
                _ => 'group_host',
              }}:$ref',
            ),
          ),
  );
  await _tap(tester, find.byKey(ValueKey('pick-$choice')));
}

/// E15/E16's targets: the morning summary to Researcher, the rest to
/// Tester, the work to you; then back to the top of the list.
Future<void> _e15Targets(WidgetTester tester, {bool reminder = false}) async {
  await _pick(tester, null, 'p-tester');
  await _pick(tester, 'r1', 'p-research');
  await _pick(tester, 'w-sched', 'user');
  if (reminder) await _pick(tester, 'rem1', 'p-research');
  await tester.drag(
    find.byKey(const ValueKey('retire-scroll')),
    const Offset(0, 3000),
  );
  await tester.pumpAndSettle();
}

void main() {
  group('a new handover', () {
    appTest('pick the receiver and tick items; Next proposes them, and each '
        'item then shows its fit (ok, narrowed, stop) and the reason', (
      tester,
    ) async {
      final fixture = HandoverFixture();
      final (gateway, container) = await _pump(
        tester,
        fixture,
        location: _start,
      );
      expect(find.byType(HandoverScreen), findsOneWidget);
      // The other pots (not archived) and you.
      for (final key in ['p-research', 'p-tester', 'user']) {
        expect(find.byKey(ValueKey('receiver-$key')), findsOneWidget);
      }
      expect(find.byKey(const ValueKey('receiver-p-old')), findsNothing);
      expect(
        _in(
          'receiver-p-tester',
          find.text('Can open work · 1.2M tokens left today'),
        ),
        findsOneWidget,
      );
      expect(_in('receiver-p-research', find.text('Observing')), findsOne);
      // Subtitles: a responsibility's detail and a group's size.
      expect(
        _in('held-responsibility:r1', find.text('09:00 · summary')),
        findsOne,
      );
      expect(_in('held-group_host:t-mobile', find.text('4 people')), findsOne);
      expect(_enabled(tester, 'handover-next'), isFalse);

      await _tapKey(tester, 'receiver-p-research');
      expect(find.text('Butler → Researcher'), findsOneWidget);
      expect(_enabled(tester, 'handover-next'), isFalse);
      for (final key in [
        'responsibility:r1',
        'responsibility:r2',
        'work:w-sched',
      ]) {
        await _tap(
          tester,
          _in('held-$key', find.bySemanticsLabel('Hand over this item')),
        );
      }
      await _tapKey(tester, 'handover-next');

      expect(fixture.handoverBodies, [
        {
          'fromPotId': 'p-butler',
          'to': _to('pot', 'p-research'),
          'items': [
            {'kind': 'responsibility', 'ref': 'r1'},
            {'kind': 'responsibility', 'ref': 'r2'},
            {'kind': 'work', 'ref': 'w-sched'},
          ],
        },
      ]);
      expect(_location(container).queryParameters, {'open': 'handover:h2'});
      expect(_item(tester, 'responsibility:r1').fit, HandoverFit.narrowed);
      expect(
        _item(tester, 'responsibility:r1').fitText,
        'Researcher may do less',
      );
      expect(_item(tester, 'responsibility:r2').fit, HandoverFit.ok);
      expect(_item(tester, 'responsibility:r2').fitText, 'Enough permissions');
      expect(_item(tester, 'work:w-sched').fit, HandoverFit.stop);
      expect(
        _item(tester, 'work:w-sched').fitText,
        'Researcher may not work there',
      );
      expect(find.text('Researcher may not work there'), findsOneWidget);
      // Only the user's proposal: no banner; Cancel and Confirm.
      expect(find.byKey(const ValueKey('handover-banner')), findsNothing);
      expect(_in('handover-reject', find.text('Cancel')), findsOne);
      expect(
        _in('handover-confirm', find.text('Hand over 2 items to Researcher')),
        findsOne,
      );
      expect(gateway.sent('POST', '/api/handovers/h2/confirm'), isEmpty);
    });

    appTest('Confirm sends the revision and goes back to the profile', (
      tester,
    ) async {
      final fixture = HandoverFixture();
      final (_, container) = await _pump(tester, fixture, location: _start);
      await _tapKey(tester, 'receiver-p-tester');
      await _tap(
        tester,
        _in(
          'held-responsibility:r2',
          find.bySemanticsLabel('Hand over this item'),
        ),
      );
      await _tapKey(tester, 'handover-next');
      await _tapKey(tester, 'handover-confirm');
      expect(fixture.confirms, {
        'h2': {'revision': 1},
      });
      expect(fixture.created['h2']!['state'], 'applied');
      expect(_location(container).queryParameters, {
        'open': 'pot:p-butler',
        'side': 'profile',
      });
    });

    appTest('Cancel withdraws the user\'s own proposal', (tester) async {
      final fixture = HandoverFixture();
      final (_, container) = await _pump(tester, fixture, location: _start);
      await _tapKey(tester, 'receiver-user');
      await _tap(
        tester,
        _in('held-work:w-sched', find.bySemanticsLabel('Hand over this item')),
      );
      await _tapKey(tester, 'handover-next');
      expect(_item(tester, 'work:w-sched').fitText, startsWith('You manage'));
      await _tapKey(tester, 'handover-reject');
      expect(fixture.rejects, ['h2']);
      expect(fixture.confirms, isEmpty);
      expect(_location(container).queryParameters, {
        'open': 'pot:p-butler',
        'side': 'profile',
      });
    });

    appTest('a refused proposal shows the Gateway\'s message', (tester) async {
      final fixture = HandoverFixture();
      final (gateway, _) = await _pump(tester, fixture, location: _start);
      gateway.json['POST /api/handovers'] = (_) =>
          apiError(409, 'pot_archived', 'That pot is archived');
      await _tapKey(tester, 'receiver-p-tester');
      await _tap(
        tester,
        _in(
          'held-responsibility:r2',
          find.bySemanticsLabel('Hand over this item'),
        ),
      );
      await _tapKey(tester, 'handover-next');
      expect(
        _in('handover-error', find.text('That pot is archived')),
        findsOne,
      );
      expect(find.byType(HandoverScreen), findsOneWidget);
    });

    appTest('Cancel leaves for the profile; held items are read again on '
        'pots_changed', (tester) async {
      final fixture = HandoverFixture();
      final (gateway, container) = await _pump(
        tester,
        fixture,
        location: _start,
      );
      fixture.held.removeLast();
      _hint(gateway, 'pots_changed');
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('held-group_host:t-mobile')),
        findsNothing,
      );
      await _tapKey(tester, 'handover-cancel');
      expect(_location(container).queryParameters, {
        'open': 'pot:p-butler',
        'side': 'profile',
      });
    });
  });

  group('a pot\'s proposal', () {
    appTest('the banner, the receiver and only Confirm / Reject; Confirm '
        'sends the revision and the card says it is confirmed', (tester) async {
      final fixture = HandoverFixture();
      final (gateway, container) = await _pump(
        tester,
        fixture,
        location: _proposal,
      );
      expect(
        _in(
          'handover-banner',
          find.textContaining(
            'Butler proposes a handover. It wants to give “Watch for stuck '
            'work in pirc mobile” to Tester; nothing changes until you '
            'confirm.',
            findRichText: true,
          ),
        ),
        findsOne,
      );
      expect(
        _in(
          'handover-banner',
          find.text('Tester already watches the nightly runs'),
        ),
        findsOne,
      );
      expect(find.byType(ReceiverCard), findsOneWidget);
      expect(find.byKey(const ValueKey('handover-next')), findsNothing);
      expect(_in('handover-reject', find.text('Reject')), findsOne);
      expect(_item(tester, 'responsibility:r2').checked, isTrue);
      expect(_item(tester, 'responsibility:r2').onChecked, isNull);
      expect(_item(tester, 'responsibility:r2').fit, HandoverFit.ok);

      await _tapKey(tester, 'handover-confirm');
      expect(fixture.confirms, {
        'h1': {'revision': 3},
      });
      expect(gateway.sent('POST', '/api/handovers/h1/reject'), isEmpty);
      expect(_location(container).queryParameters, {'open': 'pot:p-butler'});
      expect(
        _in('card-handover-h1', find.text('Handover confirmed')),
        findsOne,
      );
    });

    appTest('Reject rejects it and the card says so', (tester) async {
      final fixture = HandoverFixture();
      final (_, container) = await _pump(tester, fixture, location: _proposal);
      await _tapKey(tester, 'handover-reject');
      expect(fixture.rejects, ['h1']);
      expect(fixture.confirms, isEmpty);
      expect(_location(container).queryParameters, {'open': 'pot:p-butler'});
      expect(_in('card-handover-h1', find.text('Handover rejected')), findsOne);
    });

    appTest('Cancel leaves it waiting', (tester) async {
      final fixture = HandoverFixture();
      final (_, container) = await _pump(tester, fixture, location: _proposal);
      await _tapKey(tester, 'handover-cancel');
      expect(fixture.rejects, isEmpty);
      expect(_location(container).queryParameters, {'open': 'pot:p-butler'});
      expect(_in('card-handover-h1', find.text('Review')), findsOne);
    });

    appTest('rule 1: an item handed back too soon stops with the Gateway\'s '
        'reason as it is, and nothing can be confirmed', (tester) async {
      final fixture = HandoverFixture();
      const reason = 'Tester had this recently; only the user can hand it back';
      fixture.handover['items'] = [
        {
          'kind': 'responsibility',
          'ref': 'r2',
          'label': 'Watch for stuck work in pirc mobile',
          'fit': 'stop',
          'reason': reason,
        },
      ];
      await _pump(tester, fixture, location: _proposal);
      expect(find.text(reason), findsOneWidget);
      expect(_item(tester, 'responsibility:r2').fit, HandoverFit.stop);
      expect(_enabled(tester, 'handover-confirm'), isFalse);
      expect(_enabled(tester, 'handover-reject'), isTrue);
      expect(
        find.byKey(const ValueKey('handover-nothing-fits')),
        findsOneWidget,
      );
    });

    appTest('a refused confirm shows the message and reads it again', (
      tester,
    ) async {
      final fixture = HandoverFixture()
        ..confirmRefusal = apiError(
          409,
          'already_decided',
          'This handover was already decided',
        );
      final (gateway, _) = await _pump(tester, fixture, location: _proposal);
      final reads = gateway.sent('GET', '/api/handovers/h1').length;
      fixture.handover['state'] = 'applied';
      await _tapKey(tester, 'handover-confirm');
      expect(
        _in('handover-error', find.text('This handover was already decided')),
        findsOne,
      );
      expect(gateway.sent('GET', '/api/handovers/h1').length, reads + 1);
      expect(_in('handover-result', find.text('Handed over.')), findsOne);
      expect(find.byKey(const ValueKey('handover-confirm')), findsNothing);
    });

    appTest('another device\'s answer arrives with threads_changed', (
      tester,
    ) async {
      final fixture = HandoverFixture();
      final (gateway, _) = await _pump(tester, fixture, location: _proposal);
      fixture.handover['state'] = 'rejected';
      _hint(gateway, 'threads_changed');
      await tester.pumpAndSettle();
      expect(
        _in('handover-result', find.text('Rejected; nothing was handed over.')),
        findsOne,
      );
      expect(find.byKey(const ValueKey('handover-confirm')), findsNothing);
    });

    appTest('System Back goes to the pot\'s profile', (tester) async {
      final (_, container) = await _pump(
        tester,
        HandoverFixture(),
        location: _proposal,
      );
      expect(find.byType(HandoverScreen), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(_location(container).queryParameters, {
        'open': 'pot:p-butler',
        'side': 'profile',
      });
      expect(find.byType(HandoverScreen), findsNothing);
    });
  });

  group('archive or delete', () {
    appTest('the preview asks with the chosen targets and shows each fit, '
        'Will stop and Kept', (tester) async {
      final fixture = HandoverFixture();
      await _pump(tester, fixture, location: _retire);
      expect(find.byType(RetireScreen), findsOneWidget);
      expect(find.text('Remove Butler'), findsOneWidget);
      expect(find.text('Can hand over · 5'), findsOneWidget);
      expect(fixture.previews.last, {'mode': 'archive', 'targets': _targets()});
      expect(_item(tester, 'responsibility:r1').fit, HandoverFit.stop);
      expect(
        _item(tester, 'responsibility:r1').fitText,
        'stays with the archived pot',
      );
      expect(_item(tester, 'work:w-sched').fitText, startsWith('You manage'));
      expect(
        _in(
          'retire-stops',
          find.text('Butler takes no wakes and does nothing until restored'),
        ),
        findsOne,
      );
      expect(
        _in('retire-kept', find.textContaining('restoring does not take')),
        findsOne,
      );

      // One item to another pot: the preview follows.
      await _pick(tester, 'r1', 'p-research');
      expect(fixture.previews.last, {
        'mode': 'archive',
        'targets': _targets({'r1': _to('pot', 'p-research')}),
      });
      expect(_item(tester, 'responsibility:r1').fit, HandoverFit.narrowed);
      expect(
        _item(tester, 'responsibility:r1').fitText,
        'Researcher may do less',
      );
      expect(
        _in('target-responsibility:r1', find.text('Researcher')),
        findsOne,
      );

      // Delete changes the preview's mode and its sentences.
      await _tap(tester, _in('retire-mode', find.text('Delete')));
      expect(fixture.previews.last['mode'], 'delete');
      expect(
        _in(
          'retire-stops',
          find.text(
            'Its session, memory, personality and settings are deleted',
          ),
        ),
        findsOne,
      );
      expect(_item(tester, 'responsibility:r2').fitText, 'is removed');
      expect(find.text('Hand over and delete Butler'), findsOneWidget);
    });

    appTest('the pick sheet shows each choice\'s fit (E17)', (tester) async {
      final fixture = HandoverFixture();
      await _pump(tester, fixture, location: _retire);
      await _tapKey(tester, 'target-responsibility:r1');
      expect(
        find.text('Who takes “Sort your decisions every morning”?'),
        findsOneWidget,
      );
      expect(
        _in('pick-p-research', find.text('Researcher may do less')),
        findsOne,
      );
      expect(_in('pick-p-tester', find.text('Enough permissions')), findsOne);
      expect(
        _in(
          'pick-user',
          find.text('The user does not hold a pot\'s responsibilities'),
        ),
        findsOne,
      );
      expect(
        _in('pick-none', find.text('stays with the archived pot')),
        findsOne,
      );
      // One preview per choice, each giving it everything.
      for (final to in [
        _to('pot', 'p-research'),
        _to('pot', 'p-tester'),
        _to('user'),
      ]) {
        expect(
          fixture.previews.where(
            (body) => (body['targets']! as List).every(
              (t) => (t as Map)['to'].toString() == to.toString(),
            ),
          ),
          isNotEmpty,
        );
      }
    });

    appTest('Give everything to… sets every item to one receiver', (
      tester,
    ) async {
      final fixture = HandoverFixture();
      await _pump(tester, fixture, location: _retire);
      await _tapKey(tester, 'retire-give-all');
      expect(find.text('Give everything to whom?'), findsOneWidget);
      expect(find.byKey(const ValueKey('pick-none')), findsNothing);
      expect(_in('pick-p-tester', find.text('Every item fits')), findsOne);
      expect(
        _in('pick-p-research', find.text('2 items don\'t fully fit')),
        findsOne,
      );
      await _tapKey(tester, 'pick-p-tester');
      final tester_ = _to('pot', 'p-tester');
      // The sheet already read this plan's preview; the screen reuses it.
      expect(
        fixture.previews,
        contains(
          equals({
            'mode': 'archive',
            'targets': _targets({
              for (final ref in ['r1', 'r2', 'rem1', 'w-sched', 't-mobile'])
                ref: tester_,
            }),
          }),
        ),
      );
      for (final key in [
        'responsibility:r1',
        'responsibility:r2',
        'reminder:rem1',
        'work:w-sched',
        'group_host:t-mobile',
      ]) {
        expect(_in('target-$key', find.text('Tester')), findsOne);
        expect(_item(tester, key).fit, HandoverFit.ok);
      }
    });

    appTest('an item opens what it needs and does; "Adjust ○○\'s '
        'permissions…" opens that pot\'s settings at step ③ and changes '
        'nothing', (tester) async {
      final fixture = HandoverFixture();
      final (gateway, container) = await _pump(
        tester,
        fixture,
        location: _retire,
      );
      await _pick(tester, 'r1', 'p-research');
      expect(
        find.text('Needs: “Watch and suggest”, as Butler has'),
        findsNothing,
      );
      await _tap(
        tester,
        _in(
          'held-responsibility:r1',
          find.text('Sort your decisions every morning'),
        ),
      );
      expect(
        find.text('Needs: “Watch and suggest”, as Butler has'),
        findsOneWidget,
      );
      expect(find.text('Will do: 09:00 · summary'), findsOneWidget);
      // An ok item has no button.
      await _tap(
        tester,
        _in('held-work:w-sched', find.text('Tidy the schedule report')),
      );
      expect(find.byKey(const ValueKey('adjust-work:w-sched')), findsNothing);

      await _tap(tester, find.text('Adjust Researcher\'s permissions…'));
      expect(_location(container).queryParameters, {
        'open': 'settings:p-research',
        'section': 'reach',
      });
      expect(find.byType(PotSettingsScreen), findsOneWidget);
      expect(gateway.requests.where((r) => r.method == 'PATCH'), isEmpty);
      expect(fixture.retires, isEmpty);
    });

    appTest('archive: the exact request; the app returns to the Chat tab '
        'without the pot', (tester) async {
      final fixture = HandoverFixture();
      final (_, container) = await _pump(tester, fixture, location: _retire);
      await _pick(tester, 'r2', 'p-tester');
      await _tapKey(tester, 'retire-confirm');
      expect(fixture.retires, [
        {
          'mode': 'archive',
          'revision': 7,
          'targets': _targets({'r2': _to('pot', 'p-tester')}),
        },
      ]);
      expect(_location(container).toString(), '/chat');
      expect(_chatRow('Butler'), findsNothing);
      expect(_chatRow('Tester'), findsOne);
    });

    appTest('delete asks for the name typed; the exact request; the app '
        'returns to the Chat tab and the conversation is read-only', (
      tester,
    ) async {
      final fixture = HandoverFixture();
      final (_, container) = await _pump(tester, fixture, location: _retire);
      await _tap(tester, _in('retire-mode', find.text('Delete')));
      await _tapKey(tester, 'retire-confirm');
      expect(find.byKey(const ValueKey('retire-delete-dialog')), findsOne);
      expect(_enabled(tester, 'retire-delete-confirm'), isFalse);
      await tester.enterText(
        find.byKey(const ValueKey('retire-delete-name')),
        'Butle',
      );
      await tester.pump();
      expect(_enabled(tester, 'retire-delete-confirm'), isFalse);
      expect(fixture.retires, isEmpty);
      await tester.enterText(
        find.byKey(const ValueKey('retire-delete-name')),
        'Butler',
      );
      await tester.pump();
      await _tapKey(tester, 'retire-delete-confirm');
      expect(fixture.retires, [
        {'mode': 'delete', 'revision': 7, 'targets': _targets()},
      ]);
      expect(_location(container).toString(), '/chat');
      expect(_chatRow('Butler'), findsNothing);
      expect(_chatRow('Tester'), findsOne);

      // The deleted pot's thread, by its ID, is read-only.
      container.read(routerProvider).go('/chat?open=t-butler');
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('thread-read-only')), findsOneWidget);
      expect(find.byType(TextField), findsNothing);
    });

    appTest('cancelling the typed name deletes nothing', (tester) async {
      final fixture = HandoverFixture();
      await _pump(tester, fixture, location: _retire);
      await _tap(tester, _in('retire-mode', find.text('Delete')));
      await _tapKey(tester, 'retire-confirm');
      await _tap(tester, _in('retire-delete-dialog', find.text('Cancel')));
      expect(fixture.retires, isEmpty);
      expect(find.byType(RetireScreen), findsOneWidget);
    });

    appTest('a 409 shows the message and reads the preview again', (
      tester,
    ) async {
      final fixture = HandoverFixture()
        ..retireRefusal = apiError(
          409,
          'revision_conflict',
          'The pot changed; read it again',
        );
      final (_, container) = await _pump(tester, fixture, location: _retire);
      final previews = fixture.previews.length;
      await _tapKey(tester, 'retire-confirm');
      expect(
        _in('retire-error', find.text('The pot changed; read it again')),
        findsOne,
      );
      expect(fixture.previews.length, previews + 1);
      expect(_location(container).queryParameters, {'open': 'retire:p-butler'});
    });

    appTest('the preview is read again on pots_changed and threads_changed', (
      tester,
    ) async {
      final fixture = HandoverFixture();
      final (gateway, _) = await _pump(tester, fixture, location: _retire);
      for (final hint in ['pots_changed', 'threads_changed']) {
        final count = fixture.previews.length;
        _hint(gateway, hint);
        await tester.pumpAndSettle();
        expect(fixture.previews.length, greaterThan(count));
      }
    });

    appTest('an archived pot can only be deleted', (tester) async {
      final fixture = HandoverFixture();
      fixture.pot = {...fixture.pot, 'state': 'archived'};
      await _pump(tester, fixture, location: _retire);
      expect(fixture.previews.last['mode'], 'delete');
      expect(find.text('Hand over and delete Butler'), findsOneWidget);
      expect(
        tester
            .widget<Segmented<String>>(find.byType(Segmented<String>))
            .onSelected,
        isNull,
      );
    });

    appTest('Cancel goes back to the settings', (tester) async {
      final (_, container) = await _pump(
        tester,
        HandoverFixture(),
        location: _retire,
      );
      await _tapKey(tester, 'retire-cancel');
      expect(_location(container).queryParameters, {
        'open': 'settings:p-butler',
      });
    });
  });

  group('golden images', () {
    Future<ProviderContainer> golden(
      WidgetTester tester,
      String location,
      ThemeMode mode, {
      double width = 375,
      double height = 812,
    }) async {
      await tester.runAsync(loadGoldenFonts);
      final (_, container) = await _pump(
        tester,
        HandoverFixture(),
        location: location,
        width: width,
        height: height,
      );
      container.read(themeModeProvider.notifier).select(mode);
      await tester.pumpAndSettle();
      return container;
    }

    for (final width in goldenWidths) {
      final w = width.toInt();
      for (final mode in [ThemeMode.light, ThemeMode.dark]) {
        testWidgets('handover $w ${mode.name}', (tester) async {
          await golden(
            tester,
            _proposal,
            mode,
            width: width,
            height: goldenHeight(width),
          );
          await expectLater(
            find.byType(MaterialApp),
            matchesGoldenFile('goldens/handover_${w}_${mode.name}.png'),
          );
          await disposeApp(tester);
        }, tags: ['golden']);

        testWidgets('retire $w ${mode.name}', (tester) async {
          await golden(
            tester,
            _retire,
            mode,
            width: width,
            height: goldenHeight(width),
          );
          await _e15Targets(tester);
          await expectLater(
            find.byType(MaterialApp),
            matchesGoldenFile('goldens/retire_${w}_${mode.name}.png'),
          );
          await disposeApp(tester);
        }, tags: ['golden']);

        testWidgets('retire detail $w ${mode.name}', (tester) async {
          await golden(
            tester,
            _retire,
            mode,
            width: width,
            height: goldenHeight(width),
          );
          await _e15Targets(tester, reminder: true);
          for (final (key, title) in [
            ('responsibility:r1', 'Sort your decisions every morning'),
            ('reminder:rem1', 'Start “Tidy the API docs” after task A'),
          ]) {
            await _tap(tester, _in('held-$key', find.text(title)));
          }
          await tester.drag(
            find.byKey(const ValueKey('retire-scroll')),
            const Offset(0, 3000),
          );
          await tester.pumpAndSettle();
          await expectLater(
            find.byType(MaterialApp),
            matchesGoldenFile('goldens/retire_detail_${w}_${mode.name}.png'),
          );
          await disposeApp(tester);
        }, tags: ['golden']);

        testWidgets('retire pick $w ${mode.name}', (tester) async {
          await golden(
            tester,
            _retire,
            mode,
            width: width,
            height: goldenHeight(width),
          );
          await _e15Targets(tester);
          await tester.tap(find.byKey(const ValueKey('target-reminder:rem1')));
          await tester.pumpAndSettle();
          await expectLater(
            find.byType(MaterialApp),
            matchesGoldenFile('goldens/retire_pick_${w}_${mode.name}.png'),
          );
          await disposeApp(tester);
        }, tags: ['golden']);
      }
    }
  });
}
