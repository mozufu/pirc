import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_app/src/chat/handover_screen.dart';
import 'package:pirc_app/src/chat/pot_conversation_screen.dart';
import 'package:pirc_app/src/chat/pot_profile_screen.dart';
import 'package:pirc_app/src/format.dart';
import 'package:pirc_app/src/router.dart';
import 'package:pirc_client/pirc_client.dart';
import 'package:pirc_ui/pirc_ui.dart';

import 'support/chat_fixtures.dart';
import 'support/harness.dart';
import 'support/work_fixtures.dart';

/// Tall enough for the E11 fixture in the test font.
const _height = 2000.0;

Future<(FakeGateway, ProviderContainer)> _pump(
  WidgetTester tester,
  ConversationFixture fixture, {
  String location = '/chat?open=pot:p-butler',
  double width = 375,
}) async {
  final gateway = fixture.install();
  final container = await pumpApp(
    tester,
    gateway: gateway,
    width: width,
    height: _height,
    location: location,
    overrides: [clockProvider.overrideWithValue(() => fixedNow)],
    reduceMotion: true,
  );
  return (gateway, container);
}

final _potBubble = find.byWidgetPredicate((w) => w is Bubble && !w.mine);
final _myBubble = find.byWidgetPredicate((w) => w is Bubble && w.mine);

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

Finder _inCard(String key, Finder matching) =>
    find.descendant(of: find.byKey(ValueKey(key)), matching: matching);

List<Map<String, Object?>> _reads(FakeGateway gateway) => [
  for (final request in gateway.sent('POST', '/api/threads/t-butler/read'))
    (request.json! as Map).cast(),
];

/// Answers each decision route, records its body in [bodies] and changes
/// the fixture's item as the Gateway would.
void _answering(
  FakeGateway gateway,
  ConversationFixture fixture,
  List<(String, Object?)> bodies,
) {
  gateway.json['POST /api/budget-requests/b1/answer'] = (request) {
    bodies.add(('budget', request.json));
    final answer = (request.json! as Map)['answer'];
    fixture.budget['state'] = answer == 'deny' ? 'denied' : 'approved';
    return {'budgetRequest': fixture.budget};
  };
  gateway.json['POST /api/causal-roots/root1/resume'] = (request) {
    bodies.add(('resume', request.json));
    fixture.root['state'] = 'active';
    return {'causalRoot': fixture.root, 'kicked': <String>[]};
  };
  gateway.json['POST /api/causal-roots/root1/stop'] = (request) {
    bodies.add(('stop', request.json));
    fixture.root['state'] = 'stopped';
    return {'causalRoot': fixture.root};
  };
  gateway.json['POST /api/pots/p-butler/pause'] = (request) {
    bodies.add(('pause', request.json));
    fixture.pots.first['state'] = 'paused';
    return {'pot': fullPotJson(fixture.pots.first)};
  };
}

ConversationFixture _withCard(Map<String, Object?> card) =>
    ConversationFixture()
      ..messages.add(messageJson(6, '', authorKind: 'system', card: card));

void main() {
  group('the conversation', () {
    appTest('bubbles: mine on the right without an avatar, the pot\'s on '
        'the left with its avatar; a system message is a notice', (
      tester,
    ) async {
      await _pump(tester, ConversationFixture());
      expect(find.byType(Bubble), findsNWidgets(2));
      final mine = tester.widget<Bubble>(_myBubble);
      expect(mine.avatar, isNull);
      expect(mine.text, 'Anything from last night?');
      expect(
        find.descendant(of: _myBubble, matching: find.byType(Avatar)),
        findsNothing,
      );
      expect(
        find.descendant(of: _potBubble, matching: find.byType(Avatar)),
        findsOneWidget,
      );
      // Mine is at the right edge, the pot's at the left.
      final screen = tester.getRect(find.byType(PotConversationScreen));
      expect(tester.getRect(_myBubble).right, greaterThan(screen.right - 40));
      expect(tester.getRect(_potBubble).left, lessThan(screen.left + 40));
      expect(find.text('Today 08:58'), findsOneWidget);
      final notice = tester.widget<HandoffLine>(find.byType(HandoffLine));
      expect(
        [for (final p in notice.parts) (p.text, p.strong)],
        [
          ('Butler', true),
          ('asked', false),
          ('Tester', true),
          ('to handle “Check the nightly test”', false),
        ],
      );
    });

    appTest('the header shows the avatar, name, intro, reach and this '
        'month\'s money, and opens the profile', (tester) async {
      final (_, container) = await _pump(
        tester,
        ConversationFixture(),
        width: 1300,
      );
      expect(
        find.text('Manager · Observing · This month \$4.20 / \$20'),
        findsOneWidget,
      );
      await _tap(tester, find.byKey(const ValueKey('thread-header')));
      expect(_location(container).queryParameters, {
        'open': 'pot:p-butler',
        'side': 'profile',
      });
      expect(find.byType(PotProfileScreen), findsOneWidget);
    });

    appTest('on a phone the profile is a page; Back returns to the '
        'conversation', (tester) async {
      final (_, container) = await _pump(tester, ConversationFixture());
      await _tap(tester, find.byTooltip("Butler's profile"));
      expect(_location(container).queryParameters['side'], 'profile');
      expect(find.byType(PotProfileScreen), findsOneWidget);
      await _tap(tester, find.byTooltip('Back').last);
      expect(_location(container).queryParameters, {'open': 'pot:p-butler'});
      expect(find.byType(PotConversationScreen), findsOneWidget);
    });

    appTest('the status says when the pot is paused or working', (
      tester,
    ) async {
      final fixture = ConversationFixture();
      fixture.pots[0]['state'] = 'paused';
      await _pump(tester, fixture, width: 1300);
      expect(
        find.text('Manager · Paused · This month \$4.20 / \$20'),
        findsOneWidget,
      );
    });

    appTest('a new message arrives with threads_changed', (tester) async {
      final fixture = ConversationFixture();
      final (gateway, _) = await _pump(tester, fixture);
      fixture.messages.add(
        messageJson(
          6,
          'The three failures are flaky timeouts.',
          authorId: 'p-butler',
          createdAt: at(10, 30),
        ),
      );
      _hint(gateway, 'threads_changed');
      await tester.pumpAndSettle();
      expect(
        find.text('The three failures are flaky timeouts.'),
        findsOneWidget,
      );
      // The older messages stay.
      expect(find.text('Anything from last night?'), findsOneWidget);
      expect(find.text('Today 10:30'), findsOneWidget);
    });

    appTest('an unknown card kind is a plain notice', (tester) async {
      await _pump(
        tester,
        _withCard({'kind': 'calendar_hold', 'id': 'x'})
          ..messages.last['body'] = 'Butler held Friday afternoon',
      );
      expect(find.text('Butler held Friday afternoon'), findsNothing);
      expect(
        find.textContaining('held Friday afternoon', findRichText: true),
        findsOneWidget,
      );
    });

    appTest('an unknown card without text says it cannot be shown', (
      tester,
    ) async {
      await _pump(tester, _withCard({'kind': 'calendar_hold'}));
      expect(
        find.textContaining(
          "can't show this item (calendar_hold)",
          findRichText: true,
        ),
        findsOneWidget,
      );
    });
  });

  group('paging', () {
    ConversationFixture long() {
      final fixture = ConversationFixture()..unread = 0;
      fixture.messages = [
        for (var seq = 51; seq <= 100; seq++)
          messageJson(
            seq,
            'Message $seq',
            authorId: 'p-butler',
            createdAt: at(9) + seq * 1000,
          ),
      ];
      fixture.older[51] = [
        for (var seq = 31; seq <= 50; seq++)
          messageJson(
            seq,
            'Message $seq',
            authorId: 'p-butler',
            createdAt: at(9) + seq * 1000,
          ),
      ];
      return fixture;
    }

    List<String?> befores(FakeGateway gateway) => [
      for (final r in gateway.sent('GET', '/api/threads/t-butler/messages'))
        r.query['before'],
    ];

    appTest('scrolling up loads the page before the oldest seq, once; a '
        'short page is the last', (tester) async {
      final (gateway, _) = await _pump(tester, long());
      expect(befores(gateway), [null]);
      expect(find.text('Message 100'), findsOneWidget);
      await tester.dragUntilVisible(
        find.text('Message 31'),
        find.byKey(const ValueKey('thread-list')),
        const Offset(0, 400),
      );
      await tester.pumpAndSettle();
      expect(find.text('Message 31'), findsOneWidget);
      await tester.drag(
        find.byKey(const ValueKey('thread-list')),
        const Offset(0, 2000),
      );
      await tester.pumpAndSettle();
      expect(befores(gateway), [null, '51']);
    });

    appTest('a hint keeps the older pages loaded', (tester) async {
      final fixture = long();
      final (gateway, _) = await _pump(tester, fixture);
      await tester.dragUntilVisible(
        find.text('Message 31'),
        find.byKey(const ValueKey('thread-list')),
        const Offset(0, 400),
      );
      await tester.pumpAndSettle();
      _hint(gateway, 'threads_changed');
      await tester.pumpAndSettle();
      expect(find.text('Message 31'), findsOneWidget);
    });
  });

  group('the read position', () {
    appTest('is sent once when the newest message is shown, and again only '
        'when it moves forward', (tester) async {
      final fixture = ConversationFixture();
      final (gateway, _) = await _pump(tester, fixture);
      expect(_reads(gateway), [
        {'seq': 5},
      ]);
      _hint(gateway, 'threads_changed');
      await tester.pumpAndSettle();
      expect(_reads(gateway), hasLength(1));
      fixture.messages.add(
        messageJson(6, 'One more thing.', authorId: 'p-butler'),
      );
      fixture.unread = 1;
      _hint(gateway, 'threads_changed');
      await tester.pumpAndSettle();
      expect(_reads(gateway), [
        {'seq': 5},
        {'seq': 6},
      ]);
    });

    appTest('is not sent when everything is read already', (tester) async {
      final (gateway, _) = await _pump(
        tester,
        ConversationFixture()..unread = 0,
      );
      expect(_reads(gateway), isEmpty);
    });

    appTest('waits while the newest message is scrolled away', (tester) async {
      final fixture = ConversationFixture()..unread = 0;
      fixture.messages = [
        for (var seq = 1; seq <= 80; seq++)
          messageJson(seq, 'Message $seq', authorId: 'p-butler'),
      ];
      final (gateway, _) = await _pump(tester, fixture);
      expect(_reads(gateway), isEmpty);
      final list = find.byKey(const ValueKey('thread-list'));
      await tester.drag(list, const Offset(0, 600));
      await tester.pumpAndSettle();
      fixture.messages.add(messageJson(81, 'Newest', authorId: 'p-butler'));
      fixture.unread = 1;
      _hint(gateway, 'threads_changed');
      await tester.pumpAndSettle();
      expect(_reads(gateway), isEmpty);
      await tester.drag(list, const Offset(0, -3000));
      await tester.pumpAndSettle();
      expect(_reads(gateway), [
        {'seq': 81},
      ]);
    });
  });

  group('posting', () {
    appTest('the composer posts { body }, shows the message and empties '
        'the field', (tester) async {
      final (gateway, _) = await _pump(tester, ConversationFixture());
      final field = find.byKey(const ValueKey('thread-composer-field'));
      expect(
        tester.widget<TextField>(field).decoration!.hintText,
        'Message Butler…',
      );
      await tester.enterText(field, '  Start the docs work  ');
      await tester.pump();
      await _tap(tester, find.byKey(const ValueKey('thread-send')));
      expect(
        gateway.sent('POST', '/api/threads/t-butler/messages').single.json,
        {'body': 'Start the docs work'},
      );
      expect(find.text('Start the docs work'), findsOneWidget);
      expect(tester.widget<TextField>(field).controller!.text, isEmpty);
    });

    appTest('a refused wake is shown', (tester) async {
      final fixture = ConversationFixture()
        ..refused = [
          {'potId': 'p-butler', 'code': 'paused', 'reason': 'It is paused'},
        ];
      await _pump(tester, fixture);
      await tester.enterText(
        find.byKey(const ValueKey('thread-composer-field')),
        'Hello',
      );
      await tester.pump();
      await _tap(tester, find.byKey(const ValueKey('thread-send')));
      expect(find.text('Butler was not woken: It is paused'), findsOneWidget);
    });

    appTest('a failed post keeps the draft and shows the error', (
      tester,
    ) async {
      final fixture = ConversationFixture();
      final gateway = fixture.install();
      gateway.json['POST /api/threads/t-butler/messages'] = (_) =>
          apiError(400, 'invalid_body', 'The message is too long');
      await pumpApp(
        tester,
        gateway: gateway,
        width: 375,
        height: _height,
        location: '/chat?open=pot:p-butler',
        overrides: [clockProvider.overrideWithValue(() => fixedNow)],
        reduceMotion: true,
      );
      final field = find.byKey(const ValueKey('thread-composer-field'));
      await tester.enterText(field, 'Hello');
      await tester.pump();
      await _tap(tester, find.byKey(const ValueKey('thread-send')));
      expect(find.text('The message is too long'), findsOneWidget);
      expect(tester.widget<TextField>(field).controller!.text, 'Hello');
    });

    appTest('sending is disabled while offline', (tester) async {
      final (gateway, _) = await _pump(tester, ConversationFixture());
      final field = find.byKey(const ValueKey('thread-composer-field'));
      await tester.enterText(field, 'Hello');
      await tester.pump();
      gateway.socket('/api/hints')!.serverClose(1006);
      await tester.pump();
      await tester.pump();
      expect(tester.widget<TextField>(field).enabled, isFalse);
      expect(
        tester
            .widget<IconButton>(find.byKey(const ValueKey('thread-send')))
            .onPressed,
        isNull,
      );
      expect(find.text('Offline. Your draft is kept.'), findsOneWidget);
    });
  });

  group('a deleted pot\'s thread', () {
    ConversationFixture gone() {
      final fixture = ConversationFixture();
      final thread = threadJson(
        't-gone',
        pots: ['p-gone'],
        name: 'Old friend',
        avatarColor: 3,
      );
      fixture.threads.add(thread);
      return fixture;
    }

    appTest('is read-only and uses authorName', (tester) async {
      final fixture = gone();
      final gateway = fixture.install();
      gateway.json['GET /api/threads/t-gone'] = (_) => {
        'thread': fixture.threads.last,
      };
      gateway.json['GET /api/threads/t-gone/messages'] = (_) => {
        'messages': [
          messageJson(1, 'See you', threadId: 't-gone', authorKind: 'user'),
          messageJson(
            2,
            'Goodbye, and thanks.',
            threadId: 't-gone',
            authorId: 'p-gone',
            authorName: 'Old friend',
          ),
        ],
      };
      await pumpApp(
        tester,
        gateway: gateway,
        width: 375,
        height: _height,
        location: '/chat?open=t-gone',
        overrides: [clockProvider.overrideWithValue(() => fixedNow)],
        reduceMotion: true,
      );
      expect(find.byType(PotConversationScreen), findsOneWidget);
      expect(
        find.text('Old friend was deleted. This conversation is read-only.'),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('thread-composer-field')), findsNothing);
      expect(find.text('Old friend'), findsOneWidget);
      final avatar = tester.widget<Avatar>(
        find.descendant(of: _potBubble, matching: find.byType(Avatar)),
      );
      expect(avatar.name, 'Old friend');
      expect(find.byTooltip("Old friend's profile"), findsNothing);
      expect(gateway.sent('POST', '/api/threads/t-gone/read'), hasLength(1));
    });

    appTest('an archived pot\'s conversation is read-only too', (tester) async {
      final fixture = ConversationFixture();
      fixture.pots[0]['state'] = 'archived';
      await _pump(tester, fixture);
      expect(
        find.text('Butler is archived. This conversation is read-only.'),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('thread-composer-field')), findsNothing);
    });

    appTest('a group\'s thread ID stays on the placeholder', (tester) async {
      final fixture = ConversationFixture();
      final gateway = fixture.install();
      gateway.json['GET /api/threads/t-mobile'] = (_) => {
        'thread': fixture.threads[1],
      };
      gateway.json['GET /api/threads/t-mobile/messages'] = (_) => {
        'messages': <Object?>[],
      };
      await pumpApp(
        tester,
        gateway: gateway,
        width: 375,
        height: _height,
        location: '/chat?open=t-mobile',
        overrides: [clockProvider.overrideWithValue(() => fixedNow)],
        reduceMotion: true,
      );
      expect(find.text('Item t-mobile'), findsOneWidget);
      expect(find.byKey(const ValueKey('thread-composer-field')), findsNothing);
    });
  });

  group('model_approval card', () {
    appTest('pending: shows the ask and opens the approval sheet', (
      tester,
    ) async {
      await _pump(tester, ConversationFixture());
      expect(
        _inCard(
          'card-approval-a1',
          find.text('Butler wants to use Claude Opus'),
        ),
        findsOneWidget,
      );
      expect(
        _inCard(
          'card-approval-a1',
          find.text('Tidy the API docs · Three specs disagree'),
        ),
        findsOneWidget,
      );
      await _tap(tester, _inCard('card-approval-a1', find.text('Review')));
      expect(find.text('Allow once'), findsOneWidget);
      expect(find.text('Deny with a reason'), findsOneWidget);
    });

    appTest('decided: one line; a second device\'s answer arrives with '
        'approvals_changed', (tester) async {
      final fixture = ConversationFixture();
      final (gateway, _) = await _pump(tester, fixture);
      fixture.approval['state'] = 'denied';
      _hint(gateway, 'approvals_changed');
      await tester.pumpAndSettle();
      expect(
        _inCard(
          'card-approval-a1',
          find.text('Denied · Claude Opus · Tidy the API docs'),
        ),
        findsOneWidget,
      );
      expect(_inCard('card-approval-a1', find.text('Review')), findsNothing);
    });

    appTest('allowing it in the sheet updates the card', (tester) async {
      final fixture = ConversationFixture();
      final gateway = fixture.install();
      gateway.json['POST /api/model-approvals/a1/answer'] = (_) {
        fixture.approval['state'] = 'allowed_once';
        return {'approval': fixture.approval};
      };
      await pumpApp(
        tester,
        gateway: gateway,
        width: 375,
        height: _height,
        location: '/chat?open=pot:p-butler',
        overrides: [clockProvider.overrideWithValue(() => fixedNow)],
        reduceMotion: true,
      );
      await _tap(tester, _inCard('card-approval-a1', find.text('Review')));
      await _tap(tester, find.text('Allow once'));
      expect(
        _inCard(
          'card-approval-a1',
          find.text('Allowed once · Claude Opus · Tidy the API docs'),
        ),
        findsOneWidget,
      );
    });
  });

  group('budget_request card', () {
    ConversationFixture pending() =>
        ConversationFixture()..budget['state'] = 'pending';

    appTest('pending: the ask, the reason and what is left', (tester) async {
      await _pump(tester, pending());
      expect(
        _inCard('card-budget-b1', find.text('Butler asks for more budget')),
        findsOneWidget,
      );
      expect(
        _inCard(
          'card-budget-b1',
          find.text('\$10.00 more this month · Two more comparison runs'),
        ),
        findsOneWidget,
      );
      expect(
        _inCard('card-budget-b1', find.text('\$15.80 left this month')),
        findsOneWidget,
      );
    });

    for (final (label, answer, shown) in [
      ('Approve', 'approve', 'Approved'),
      ('Deny', 'deny', 'Denied'),
    ]) {
      appTest('$label answers $answer', (tester) async {
        final fixture = pending();
        final gateway = fixture.install();
        final bodies = <(String, Object?)>[];
        _answering(gateway, fixture, bodies);
        await pumpApp(
          tester,
          gateway: gateway,
          width: 375,
          height: _height,
          location: '/chat?open=pot:p-butler',
          overrides: [clockProvider.overrideWithValue(() => fixedNow)],
          reduceMotion: true,
        );
        await _tap(tester, _inCard('card-budget-b1', find.text(label)));
        expect(bodies.map((b) => b.$1), ['budget']);
        expect(bodies.single.$2, {'answer': answer});
        // The request is read again and shows the answer.
        expect(
          _inCard(
            'card-budget-b1',
            find.text('$shown · \$10.00 more this month'),
          ),
          findsOneWidget,
        );
      });
    }

    appTest('Approve another amount opens the sheet on its field', (
      tester,
    ) async {
      await _pump(tester, pending());
      await _tap(
        tester,
        _inCard('card-budget-b1', find.text('Approve another amount')),
      );
      expect(find.byKey(const ValueKey('budget-amount')), findsOneWidget);
      expect(find.text('Approve this amount'), findsOneWidget);
    });

    appTest('decided: one line for each answer', (tester) async {
      final fixture = ConversationFixture();
      final (gateway, _) = await _pump(tester, fixture);
      expect(
        _inCard(
          'card-budget-b1',
          find.text('Approved · \$10.00 more this month'),
        ),
        findsOneWidget,
      );
      fixture.budget
        ..['state'] = 'approved_amount'
        ..['approvedAmountMicros'] = 5000000;
      _hint(gateway, 'budget_requests_changed');
      await tester.pumpAndSettle();
      expect(
        _inCard('card-budget-b1', find.text('Approved \$5.00 more this month')),
        findsOneWidget,
      );
      fixture.budget['state'] = 'denied';
      _hint(gateway, 'budget_requests_changed');
      await tester.pumpAndSettle();
      expect(
        _inCard(
          'card-budget-b1',
          find.text('Denied · \$10.00 more this month'),
        ),
        findsOneWidget,
      );
    });
  });

  group('work card', () {
    appTest('shows the title and state and opens the work conversation', (
      tester,
    ) async {
      final (_, container) = await _pump(tester, ConversationFixture());
      expect(
        _inCard('card-work-w1', find.text('Check the nightly test')),
        findsOneWidget,
      );
      expect(
        _inCard(
          'card-work-w1',
          find.textContaining(
            'Coordinated by Tester · CI-runner · ',
            findRichText: true,
          ),
        ),
        findsOneWidget,
      );
      expect(
        _inCard(
          'card-work-w1',
          find.textContaining('Waiting for your answer', findRichText: true),
        ),
        findsOneWidget,
      );
      await _tap(tester, find.byKey(const ValueKey('card-work-w1')));
      expect(_location(container).path, '/work');
      expect(_location(container).queryParameters['open'], 's-nightly');
    });

    appTest('a work taken over says so (pots_changed)', (tester) async {
      final fixture = ConversationFixture();
      final (gateway, _) = await _pump(tester, fixture);
      fixture.work['state'] = 'taken_over';
      _hint(gateway, 'pots_changed');
      await tester.pumpAndSettle();
      expect(
        _inCard(
          'card-work-w1',
          find.textContaining('You took it over', findRichText: true),
        ),
        findsOneWidget,
      );
    });
  });

  group('handover card', () {
    appTest('pending: the proposal; Review opens the handover', (tester) async {
      final (_, container) = await _pump(
        tester,
        _withCard({'kind': 'handover', 'handoverId': 'h1'}),
      );
      expect(
        _inCard('card-handover-h1', find.text('Butler proposes a handover')),
        findsOneWidget,
      );
      expect(
        _inCard('card-handover-h1', find.text('To You · Release notes')),
        findsOneWidget,
      );
      await _tap(tester, _inCard('card-handover-h1', find.text('Review')));
      expect(_location(container).queryParameters, {'open': 'handover:h1'});
      expect(find.byType(HandoverScreen), findsOneWidget);
      expect(
        find.textContaining('Butler proposes a handover.', findRichText: true),
        findsOneWidget,
      );
    });

    appTest('decided: one line', (tester) async {
      final fixture = _withCard({'kind': 'handover', 'handoverId': 'h1'});
      fixture.handover['state'] = 'applied';
      final (gateway, _) = await _pump(tester, fixture);
      expect(
        _inCard('card-handover-h1', find.text('Handover confirmed')),
        findsOneWidget,
      );
      fixture.handover['state'] = 'rejected';
      _hint(gateway, 'pots_changed');
      await tester.pumpAndSettle();
      expect(
        _inCard('card-handover-h1', find.text('Handover rejected')),
        findsOneWidget,
      );
    });
  });

  group('loop_guard card', () {
    ConversationFixture loop() =>
        _withCard({'kind': 'loop_guard', 'rootId': 'root1'});

    Future<(FakeGateway, List<(String, Object?)>)> pumpLoop(
      WidgetTester tester, [
      ConversationFixture? given,
    ]) async {
      final fixture = given ?? loop();
      final gateway = fixture.install();
      final bodies = <(String, Object?)>[];
      _answering(gateway, fixture, bodies);
      await pumpApp(
        tester,
        gateway: gateway,
        width: 375,
        height: _height,
        location: '/chat?open=pot:p-butler',
        overrides: [clockProvider.overrideWithValue(() => fixedNow)],
        reduceMotion: true,
      );
      return (gateway, bodies);
    }

    appTest('suspended: who started it and what happened since the last '
        'progress', (tester) async {
      await pumpLoop(tester);
      expect(
        _inCard('card-loop-root1', find.text('Chain paused')),
        findsOneWidget,
      );
      expect(
        _inCard(
          'card-loop-root1',
          find.text(
            'Butler started it. Since the last progress: 12 wakes and 30 '
            'messages.',
          ),
        ),
        findsOneWidget,
      );
      expect(
        _inCard('card-loop-root1', find.text('Last progress 08:30')),
        findsOneWidget,
      );
    });

    appTest('Resume resumes the causal root', (tester) async {
      final (gateway, bodies) = await pumpLoop(tester);
      await _tap(tester, _inCard('card-loop-root1', find.text('Resume')));
      expect(bodies.map((b) => b.$1), ['resume']);
      expect(
        gateway.sent('POST', '/api/causal-roots/root1/resume'),
        hasLength(1),
      );
    });

    appTest('Stop the chain asks first, then stops the root', (tester) async {
      final (gateway, bodies) = await pumpLoop(tester);
      await _tap(
        tester,
        _inCard('card-loop-root1', find.text('Stop the chain')),
      );
      await _tap(tester, find.text('Cancel'));
      expect(bodies, isEmpty);
      await _tap(
        tester,
        _inCard('card-loop-root1', find.text('Stop the chain')),
      );
      await _tap(tester, find.byKey(const ValueKey('confirm-stop-chain')));
      expect(bodies.map((b) => b.$1), ['stop']);
      expect(
        gateway.sent('POST', '/api/causal-roots/root1/stop'),
        hasLength(1),
      );
    });

    appTest('Pause the pots involved pauses each with its revision', (
      tester,
    ) async {
      final (gateway, bodies) = await pumpLoop(tester);
      await _tap(
        tester,
        _inCard('card-loop-root1', find.text('Pause the pots involved')),
      );
      expect(gateway.sent('GET', '/api/pots/p-butler'), isNotEmpty);
      expect(bodies.map((b) => b.$1), ['pause']);
      expect(bodies.single.$2, {'revision': 7});
    });

    appTest('paused pots: the button goes and the card says so', (
      tester,
    ) async {
      final fixture = loop();
      fixture.pots[0]['state'] = 'paused';
      await pumpLoop(tester, fixture);
      expect(
        _inCard('card-loop-root1', find.text('Pause the pots involved')),
        findsNothing,
      );
      expect(
        _inCard(
          'card-loop-root1',
          find.text('Last progress 08:30 · The pots involved are paused'),
        ),
        findsOneWidget,
      );
    });

    appTest('decided: one line, read again on causal_roots_changed', (
      tester,
    ) async {
      final fixture = loop();
      final (gateway, _) = await pumpLoop(tester, fixture);
      fixture.root['state'] = 'active';
      _hint(gateway, 'causal_roots_changed');
      await tester.pumpAndSettle();
      expect(_inCard('card-loop-root1', find.text('Resumed')), findsOneWidget);
      fixture.root['state'] = 'stopped';
      _hint(gateway, 'causal_roots_changed');
      await tester.pumpAndSettle();
      expect(
        _inCard('card-loop-root1', find.text('Chain stopped')),
        findsOneWidget,
      );
    });
  });

  test('dollars drop whole cents; tokens are short', () {
    expect(dollars(20000000), '\$20');
    expect(dollars(4200000), '\$4.20');
    expect(compactTokens(2000000), '2M');
    expect(compactTokens(800000), '0.8M');
    expect(compactTokens(12000), '12K');
    expect(compactTokens(950), '950');
  });

  test('a thread message keeps a deleted author\'s name', () {
    final message = ThreadMessage.fromJson(
      messageJson(1, 'x', authorId: 'p', authorName: 'Gone'),
    );
    expect(message.authorDeleted, isTrue);
  });
}
