import 'package:pirc_client/pirc_client.dart';
import 'package:test/test.dart';

import 'support/fakes.dart';

/// A client whose every request is answered with [json] and [status].
(ApiClient, FakeTransport) _answering(Object? json, {int status = 200}) {
  final transport = FakeTransport(onSend: (_) async => reply(status, json));
  return (ApiClient(transport), transport);
}

Map<String, Object?> _potJson({Map<String, Object?> extra = const {}}) => {
  'id': 'pot1',
  'state': 'active',
  'revision': 4,
  'createdAt': 100,
  'updatedAt': 200,
  'sessionId': 'sess1',
  'profile': {'name': 'Ada', 'avatarColor': 3, 'personality': 'Precise.'},
  'work': {
    'intro': 'Keeps the build green',
    'description': 'Watches CI.',
    'responsibilities': [
      {'title': 'Fix flakes', 'detail': 'Retry once'},
    ],
  },
  'permissions': {
    'reach': 'work',
    'observe': [
      {'kind': 'workspace', 'ref': 'n:w', 'lead': true},
    ],
    'dm': {
      'send': 'selected',
      'receive': 'all',
      'sendTo': ['pot2'],
      'receiveFrom': <String>[],
    },
    'workLocations': [
      {'workspaceId': 'n:w', 'access': 'write'},
    ],
    'maxConcurrentWorks': 2,
    'budgetMoneyMonthMicros': 20000000,
    'budgetTokensDay': 2000000,
  },
  'models': {
    'main': {'provider': 'anthropic', 'model': 'opus'},
    'fallbacks': [
      {'provider': 'openai', 'model': 'gpt'},
    ],
    'thinking': 'high',
    'thinkingAuto': true,
    'workModels': [
      {'provider': 'anthropic', 'model': 'opus', 'mode': 'ask'},
    ],
  },
  'autonomy': {'intervalS': 86400},
  ...extra,
};

const _input = PotInput(
  profile: PotProfile(name: 'Ada', avatarColor: 2),
  work: PotWorkSection(intro: 'Hi'),
  permissions: PotPermissions(budgetMoneyMonthMicros: null),
  models: PotModels(
    main: PotModelChoice(provider: 'p', model: 'm'),
  ),
);

Map<String, Object?> _messageJson(
  int seq, {
  Object? card,
  String? authorName,
}) => {
  'id': 'm$seq',
  'threadId': 't1',
  'seq': seq,
  'authorKind': card == null ? 'pot' : 'system',
  'authorId': card == null ? 'pot1' : null,
  'authorName': ?authorName,
  'body': 'Line one\nLine two',
  'mentions': <String>[],
  'all': false,
  'createdAt': 1000 + seq,
  'card': ?card,
};

void main() {
  group('pots', () {
    test('the summary reads step 0 fields and defaults without them', () async {
      final (api, transport) = _answering({
        'pots': [
          _potJson(
            extra: {
              'status': 'working',
              'needsYou': 3,
              'budgetLeft': {'moneyMicros': 5000000, 'tokens': null},
            },
          ),
          {
            'id': 'pot2',
            'profile': {'name': 'Bo'},
          },
        ],
      });
      final pots = await PotsApi(api).pots();
      expect(transport.requests.single.method, 'GET');
      expect(transport.requests.single.path, '/api/pots');
      expect(pots.first.intro, 'Keeps the build green');
      expect(pots.first.status, 'working');
      expect(pots.first.needsYou, 3);
      expect(pots.first.budgetLeft?.moneyMicros, 5000000);
      expect(pots.first.budgetLeft?.tokens, isNull);
      expect(pots.first.sessionId, 'sess1');
      expect(pots.last.status, 'idle');
      expect(pots.last.needsYou, 0);
      expect(pots.last.budgetLeft, isNull);
      expect(pots.last.avatarColor, 1);
    });

    test('a full pot is parsed section by section', () async {
      final (api, transport) = _answering({'pot': _potJson()});
      final pot = await PotsApi(api).read('pot 1');
      expect(transport.requests.single.path, '/api/pots/pot%201');
      expect(pot.name, 'Ada');
      expect(pot.revision, 4);
      expect(pot.profile.personality, 'Precise.');
      expect(pot.profile.avatarImage, isNull);
      expect(pot.work.responsibilities.single.detail, 'Retry once');
      expect(pot.permissions.reach, 'work');
      expect(pot.permissions.observe.single.lead, isTrue);
      expect(pot.permissions.dm.sendTo, ['pot2']);
      expect(pot.permissions.workLocations.single.access, 'write');
      expect(pot.permissions.budgetTokensDay, 2000000);
      expect(pot.models.main.model, 'opus');
      expect(pot.models.fallbacks.single.provider, 'openai');
      expect(pot.models.thinkingAuto, isTrue);
      expect(pot.models.workModels.single.mode, 'ask');
      expect(pot.autonomy.intervalS, 86400);
      expect(pot.status, 'idle');
      expect(pot.needsYou, 0);
    });

    test('a pot input needs at least one budget limit', () {
      const input = PotInput(
        profile: PotProfile(name: 'Ada'),
        work: PotWorkSection(),
        permissions: PotPermissions(
          budgetMoneyMonthMicros: null,
          budgetTokensDay: null,
        ),
        models: PotModels(
          main: PotModelChoice(provider: 'p', model: 'm'),
        ),
      );
      expect(input.toJson, throwsArgumentError);
      // One limit off is fine.
      const oneOff = PotPermissions(budgetMoneyMonthMicros: null);
      expect(oneOff.toJson()['budgetTokensDay'], 2000000);
    });

    test('list reads every pot in full', () async {
      final (api, _) = _answering({
        'pots': [_potJson()],
      });
      expect((await PotsApi(api).list()).single.models.thinking, 'high');
    });

    test('create posts the whole input', () async {
      final (api, transport) = _answering({'pot': _potJson()}, status: 201);
      await PotsApi(api).create(_input);
      final request = transport.requests.single;
      expect(request.method, 'POST');
      expect(request.path, '/api/pots');
      final body = request.json! as Map<String, Object?>;
      expect(body['profile'], {
        'name': 'Ada',
        'avatarColor': 2,
        'personality': '',
      });
      expect(body['work'], {
        'intro': 'Hi',
        'description': '',
        'responsibilities': <Object?>[],
      });
      final permissions = body['permissions']! as Map<String, Object?>;
      expect(permissions['budgetMoneyMonthMicros'], isNull);
      expect(permissions.containsKey('budgetMoneyMonthMicros'), isTrue);
      expect(permissions['budgetTokensDay'], 2000000);
      expect(permissions['dm'], {
        'send': 'all',
        'receive': 'all',
        'sendTo': <String>[],
        'receiveFrom': <String>[],
      });
      expect(body['models'], {
        'main': {'provider': 'p', 'model': 'm'},
        'fallbacks': <Object?>[],
        'thinking': 'medium',
        'thinkingAuto': false,
        'workModels': <Object?>[],
      });
      expect(body['autonomy'], {'intervalS': 172800});
    });

    test('update sends only the given sections with the revision', () async {
      final (api, transport) = _answering({'pot': _potJson()});
      await PotsApi(api).update(
        'pot1',
        revision: 4,
        profile: const PotProfile(name: 'Ada', avatarImage: 'img1'),
        autonomy: const PotAutonomy(intervalS: null),
      );
      final request = transport.requests.single;
      expect(request.method, 'PATCH');
      expect(request.path, '/api/pots/pot1');
      expect(request.json, {
        'revision': 4,
        'profile': {
          'name': 'Ada',
          'avatarColor': 1,
          'personality': '',
          'avatarImage': 'img1',
        },
        'autonomy': {'intervalS': null},
      });
    });

    test('pause, resume and restore send the revision', () async {
      final (api, transport) = _answering({'pot': _potJson()});
      final pots = PotsApi(api);
      await pots.pause('pot1', revision: 1);
      await pots.resume('pot1', revision: 2);
      final restored = await pots.restore('pot1', revision: 3);
      expect(
        [for (final r in transport.requests) '${r.method} ${r.path} ${r.json}'],
        [
          'POST /api/pots/pot1/pause {revision: 1}',
          'POST /api/pots/pot1/resume {revision: 2}',
          'POST /api/pots/pot1/restore {revision: 3}',
        ],
      );
      expect(restored.id, 'pot1');
    });

    test('held items are listed', () async {
      final (api, transport) = _answering({
        'items': [
          {'kind': 'group_host', 'ref': 't9', 'label': 'Release group'},
        ],
      });
      final items = await PotsApi(api).held('pot1');
      expect(transport.requests.single.path, '/api/pots/pot1/held');
      expect(items.single.kind, 'group_host');
      expect(items.single.label, 'Release group');
      expect(items.single.toRef(), {'kind': 'group_host', 'ref': 't9'});
    });

    test('memory is read and a note forgotten', () async {
      final (api, transport) = _answering({
        'notes': [
          {
            'id': 'n1',
            'content': 'Likes tabs',
            'revision': 2,
            'createdAt': 5,
            'updatedAt': 6,
          },
        ],
        'budget': 20000,
      });
      final memory = await PotsApi(api).memory('pot1');
      expect(transport.requests.single.path, '/api/pots/pot1/memory');
      expect(memory.notes.single.content, 'Likes tabs');
      expect(memory.budget, 20000);

      final (api2, transport2) = _answering(null, status: 204);
      await PotsApi(api2).forget('pot1', 'n/1');
      expect(transport2.requests.single.method, 'DELETE');
      expect(transport2.requests.single.path, '/api/pots/pot1/memory/n%2F1');
    });

    test('retire preview sends the targets and reads the plan', () async {
      final (api, transport) = _answering({
        'mode': 'delete',
        'revision': 7,
        'items': [
          {
            'kind': 'reminder',
            'ref': 'r1',
            'label': 'Standup',
            'to': {'kind': 'none'},
            'fit': 'stop',
            'reason': 'the reminder is cancelled',
          },
          {
            'kind': 'work',
            'ref': 'w1',
            'label': 'Fix CI',
            'to': {'kind': 'pot', 'potId': 'pot2'},
            'fit': 'narrowed',
            'reason': null,
          },
        ],
        'stops': ['0 waiting messages and events are dropped'],
        'kept': ['Its activity'],
      });
      final preview = await PotsApi(api).retirePreview(
        'pot1',
        mode: 'delete',
        targets: const [
          RetireTarget(
            item: HeldItem(kind: 'work', ref: 'w1'),
            to: HandoverTo.pot('pot2'),
          ),
          RetireTarget(
            item: HeldItem(kind: 'reminder', ref: 'r1'),
            to: HandoverTo.none(),
          ),
        ],
      );
      final request = transport.requests.single;
      expect(request.path, '/api/pots/pot1/retire/preview');
      expect(request.json, {
        'mode': 'delete',
        'targets': [
          {
            'kind': 'work',
            'ref': 'w1',
            'to': {'kind': 'pot', 'potId': 'pot2'},
          },
          {
            'kind': 'reminder',
            'ref': 'r1',
            'to': {'kind': 'none'},
          },
        ],
      });
      expect(preview.revision, 7);
      expect(preview.items.first.to.kind, 'none');
      expect(preview.items.first.fit, 'stop');
      expect(preview.items.last.to.potId, 'pot2');
      expect(preview.items.last.item.label, 'Fix CI');
      expect(preview.stops, hasLength(1));
      expect(preview.kept, ['Its activity']);
    });

    test('retire archives or deletes', () async {
      final (api, transport) = _answering({
        'pot': _potJson(extra: {'state': 'archived'}),
        'handovers': [
          {
            'id': 'h1',
            'to': {'kind': 'user'},
            'state': 'applied',
          },
        ],
      });
      final archived = await PotsApi(
        api,
      ).retire('pot1', mode: 'archive', revision: 7);
      expect(transport.requests.single.path, '/api/pots/pot1/retire');
      expect(transport.requests.single.json, {
        'mode': 'archive',
        'revision': 7,
        'targets': <Object?>[],
      });
      expect(archived.deleted, isFalse);
      expect(archived.pot?.state, 'archived');
      expect(archived.handovers.single.to.kind, 'user');

      final (api2, _) = _answering({'deleted': true, 'handovers': <Object?>[]});
      final deleted = await PotsApi(
        api2,
      ).retire('pot1', mode: 'delete', revision: 8);
      expect(deleted.deleted, isTrue);
      expect(deleted.pot, isNull);
    });

    test('settings are read and saved whole with the revision', () async {
      final settingsJson = {
        'capMoneyMonthMicros': 0,
        'capTokensDay': 5,
        'onExhausted': 'pause_all',
        'activityRetentionDays': 30,
        'countSubscriptionMoney': true,
        'loopDepth': 6,
        'loopFanout': 4,
        'loopNoProgressWakes': 12,
        'loopNoProgressMessages': 20,
        'loopPairMessagesMinute': 6,
        'loopPairMessagesHour': 60,
        'loopRootWakesMinute': 10,
        'handbackCooldownS': 3600,
        'revision': 2,
      };
      final (api, transport) = _answering({'settings': settingsJson});
      final pots = PotsApi(api);
      final settings = await pots.settings();
      expect(transport.requests.single.path, '/api/pots/settings');
      expect(settings.onExhausted, 'pause_all');
      expect(settings.toJson(), settingsJson);

      await pots.updateSettings(settings.copyWith(activityRetentionDays: 60));
      final saved = transport.requests.last;
      expect(saved.method, 'PATCH');
      expect(saved.path, '/api/pots/settings');
      expect(saved.json, {...settingsJson, 'activityRetentionDays': 60});
    });

    test('works filter by pot and keep their old call', () async {
      final (api, transport) = _answering({
        'works': [
          {
            'id': 'w1',
            'potId': 'pot1',
            'sessionId': 's1',
            'workspaceId': 'n:w',
            'title': 'Fix',
            'causalRoot': 'root1',
          },
        ],
      });
      final pots = PotsApi(api);
      await pots.works();
      final works = await pots.works(potId: 'pot1');
      expect(transport.requests.first.query, isEmpty);
      expect(transport.requests.last.query, {'potId': 'pot1'});
      expect(works.single.causalRoot, 'root1');
    });

    test('one work is read by ID', () async {
      final (api, transport) = _answering({
        'work': {
          'id': 'w1',
          'potId': 'pot1',
          'sessionId': 's1',
          'workspaceId': 'n:w',
          'title': 'Fix',
          'provider': 'anthropic',
          'model': 'opus',
          'thinking': 'high',
          'state': 'taken_over',
          'createdAt': 9,
        },
      });
      final work = await PotsApi(api).work('w1');
      expect(transport.requests.single.method, 'GET');
      expect(transport.requests.single.path, '/api/pot-works/w1');
      expect(work.id, 'w1');
      expect(work.title, 'Fix');
      expect(work.model, 'opus');
      expect(work.open, isFalse);
    });
  });

  group('threads', () {
    test('the list reads unread and the last message', () async {
      final (api, transport) = _answering({
        'threads': [
          {
            'id': 't1',
            'kind': 'group',
            'name': 'Release',
            'avatarColor': 4,
            'hostPotId': 'pot1',
            'projectId': null,
            'pots': ['pot1', 'pot2'],
            'lastSeq': 9,
            'updatedAt': 900,
            'revision': 3,
            'unread': 2,
            'lastMessage': {
              'authorKind': 'pot',
              'authorId': 'pot2',
              'authorName': 'Tester',
              'body': 'Done\nSecond line',
              'createdAt': 899,
            },
          },
          {
            'id': 't2',
            'kind': 'direct',
            'name': '',
            'pots': ['pot1'],
            'lastSeq': 0,
            'updatedAt': 10,
          },
        ],
      });
      final threads = await ThreadsApi(api).list();
      expect(transport.requests.single.path, '/api/threads');
      expect(threads.first.isGroup, isTrue);
      expect(threads.first.pots, ['pot1', 'pot2']);
      expect(threads.first.revision, 3);
      expect(threads.first.unread, 2);
      expect(threads.first.lastMessage?.firstLine, 'Done');
      expect(threads.first.lastMessage?.authorId, 'pot2');
      expect(threads.first.lastMessage?.authorName, 'Tester');
      expect(threads.last.isDirect, isTrue);
      expect(threads.last.unread, 0);
      expect(threads.last.lastMessage, isNull);
      expect(threads.last.avatarColor, isNull);
    });

    test('a pot direct thread and a thread are read', () async {
      final (api, transport) = _answering({
        'thread': {
          'id': 't2',
          'kind': 'direct',
          'pots': ['pot1'],
        },
      });
      final threads = ThreadsApi(api);
      expect((await threads.direct('pot1')).id, 't2');
      expect((await threads.read('t2')).isDirect, isTrue);
      expect(
        [for (final r in transport.requests) r.path],
        ['/api/pots/pot1/thread', '/api/threads/t2'],
      );
    });

    test('a group is created', () async {
      final (api, transport) = _answering({
        'thread': {'id': 't3', 'kind': 'group', 'name': 'Release'},
      }, status: 201);
      await ThreadsApi(api).createGroup(
        name: 'Release',
        hostPotId: 'pot1',
        memberPotIds: ['pot1', 'pot2'],
        avatarColor: 2,
      );
      final request = transport.requests.single;
      expect(request.method, 'POST');
      expect(request.path, '/api/threads');
      expect(request.json, {
        'name': 'Release',
        'hostPotId': 'pot1',
        'memberPotIds': ['pot1', 'pot2'],
        'avatarColor': 2,
      });
    });

    test('a group is created with a picture', () async {
      final (api, transport) = _answering({
        'thread': {
          'id': 't4',
          'kind': 'group',
          'name': 'Design',
          'avatarImage': 'img7',
        },
      }, status: 201);
      final thread = await ThreadsApi(api).createGroup(
        name: 'Design',
        hostPotId: 'pot1',
        memberPotIds: ['pot1', 'pot2'],
        avatarImage: 'img7',
      );
      expect(thread.avatarImage, 'img7');
      expect(transport.requests.single.json, {
        'name': 'Design',
        'hostPotId': 'pot1',
        'memberPotIds': ['pot1', 'pot2'],
        'avatarImage': 'img7',
      });
    });

    test('a group is edited, deleted and read up to a seq', () async {
      final (api, transport) = _answering({
        'thread': {'id': 't3', 'kind': 'group'},
      });
      final threads = ThreadsApi(api);
      await threads.update(
        't3',
        revision: 3,
        name: 'New',
        removeAvatarImage: true,
        memberPotIds: ['pot1', 'pot3'],
      );
      await threads.update('t3', revision: 4, avatarImage: 'img2');
      await threads.delete('t3');
      await threads.markRead('t3', 41);
      await threads.update('t3', revision: 5, removeAvatarColor: true);
      await threads.update('t3', revision: 6, avatarColor: 2);
      final requests = transport.requests;
      expect(requests[0].method, 'PATCH');
      expect(requests[0].path, '/api/threads/t3');
      expect(requests[0].json, {
        'revision': 3,
        'name': 'New',
        'avatarImage': null,
        'memberPotIds': ['pot1', 'pot3'],
      });
      expect(requests[1].json, {'revision': 4, 'avatarImage': 'img2'});
      expect(
        '${requests[2].method} ${requests[2].path}',
        'DELETE /api/threads/t3',
      );
      expect(requests[3].method, 'POST');
      expect(requests[3].path, '/api/threads/t3/read');
      expect(requests[3].json, {'seq': 41});
      expect(requests[4].json, {'revision': 5, 'avatarColor': null});
      expect(requests[5].json, {'revision': 6, 'avatarColor': 2});
    });

    test('messages page back and read every card kind', () async {
      final (api, transport) = _answering({
        'messages': [
          _messageJson(1, card: {'kind': 'model_approval', 'approvalId': 'a1'}),
          _messageJson(2, card: {'kind': 'budget_request', 'requestId': 'b1'}),
          _messageJson(
            3,
            card: {'kind': 'work', 'workId': 'w1', 'sessionId': 's1'},
          ),
          _messageJson(4, card: {'kind': 'handover', 'handoverId': 'h1'}),
          _messageJson(5, card: {'kind': 'loop_guard', 'rootId': 'r1'}),
          _messageJson(6, card: {'kind': 'future_card', 'x': 1}),
          _messageJson(7),
          _messageJson(8, authorName: 'Ada'),
        ],
      });
      final messages = await ThreadsApi(api).messages('t1', before: 60);
      expect(transport.requests.single.path, '/api/threads/t1/messages');
      expect(transport.requests.single.query, {'before': '60'});
      final cards = [for (final m in messages) m.card];
      expect(
        cards[0],
        isA<ModelApprovalCard>().having((c) => c.approvalId, 'id', 'a1'),
      );
      expect(
        cards[1],
        isA<BudgetRequestCard>().having((c) => c.requestId, 'id', 'b1'),
      );
      expect(
        cards[2],
        isA<WorkSessionCard>()
            .having((c) => c.workId, 'workId', 'w1')
            .having((c) => c.sessionId, 'sessionId', 's1'),
      );
      expect(
        cards[3],
        isA<HandoverCard>().having((c) => c.handoverId, 'id', 'h1'),
      );
      expect(
        cards[4],
        isA<LoopGuardCard>().having((c) => c.rootId, 'id', 'r1'),
      );
      expect(
        cards[5],
        isA<UnknownCard>()
            .having((c) => c.kind, 'kind', 'future_card')
            .having((c) => c.raw['x'], 'raw', 1),
      );
      expect(cards[6], isNull);
      expect(messages[0].isSystem, isTrue);
      expect(messages[6].fromPot, isTrue);
      expect(messages[6].authorDeleted, isFalse);
      expect(messages[6].body, 'Line one\nLine two');
      // A deleted pot keeps its ID on the message and adds its name.
      expect(messages[7].authorId, 'pot1');
      expect(messages[7].authorName, 'Ada');
      expect(messages[7].authorDeleted, isTrue);
    });

    test('the first page has no cursor', () async {
      final (api, transport) = _answering({'messages': <Object?>[]});
      expect(await ThreadsApi(api).messages('t1'), isEmpty);
      expect(transport.requests.single.query, isEmpty);
    });

    test('a post sends mentions and all and reads who woke', () async {
      final (api, transport) = _answering({
        'message': {
          'id': 'm9',
          'threadId': 't1',
          'seq': 9,
          'authorKind': 'user',
          'authorId': null,
          'body': 'Ship it',
          'mentions': ['pot2'],
          'all': true,
          'createdAt': 5,
        },
        'woken': ['pot1', 'pot2'],
        'refused': [
          {'potId': 'pot3', 'code': 'paused', 'reason': 'Bo is paused'},
        ],
      }, status: 201);
      final threads = ThreadsApi(api);
      final posted = await threads.post(
        't1',
        'Ship it',
        mentions: ['pot2'],
        all: true,
      );
      await threads.post('t1', 'Hello');
      expect(transport.requests.first.method, 'POST');
      expect(transport.requests.first.path, '/api/threads/t1/messages');
      expect(transport.requests.first.json, {
        'body': 'Ship it',
        'mentions': ['pot2'],
        'all': true,
      });
      expect(transport.requests.last.json, {'body': 'Hello'});
      expect(posted.message.fromUser, isTrue);
      expect(posted.message.mentions, ['pot2']);
      expect(posted.message.all, isTrue);
      expect(posted.woken, ['pot1', 'pot2']);
      expect(posted.refused.single.code, 'paused');
    });
  });

  group('decisions', () {
    final approvalJson = {
      'id': 'a1',
      'potId': 'pot1',
      'workTitle': 'Refactor',
      'workspaceId': 'n:w',
      'provider': 'anthropic',
      'model': 'opus',
      'thinking': 'high',
      'reason': 'Big change',
      'estimateMicros': 300000,
      'remainingMicros': null,
      'state': 'denied',
      'denyReason': 'Too costly',
      'createdAt': 1,
      'answeredAt': 2,
      'usedAt': null,
    };

    test('model approvals are listed, read and answered', () async {
      final (api, transport) = _answering({
        'approvals': [approvalJson],
        'approval': approvalJson,
      });
      final decisions = DecisionsApi(api);
      final list = await decisions.approvals(state: 'pending');
      final one = await decisions.approval('a1');
      final answered = await decisions.answerApproval(
        'a1',
        answer: 'deny',
        reason: 'Too costly',
      );
      await decisions.answerApproval('a1', answer: 'allow_once');
      final requests = transport.requests;
      expect(requests[0].path, '/api/model-approvals');
      expect(requests[0].query, {'state': 'pending'});
      expect(requests[1].path, '/api/model-approvals/a1');
      expect(requests[2].method, 'POST');
      expect(requests[2].path, '/api/model-approvals/a1/answer');
      expect(requests[2].json, {'answer': 'deny', 'reason': 'Too costly'});
      expect(requests[3].json, {'answer': 'allow_once'});
      expect(list.single.thinking, 'high');
      expect(one.estimateMicros, 300000);
      expect(one.remainingMicros, isNull);
      expect(answered.denyReason, 'Too costly');
      expect(answered.answeredAt, 2);
      expect(answered.pending, isFalse);

      final (api2, transport2) = _answering({'approvals': <Object?>[]});
      await PotsApi(api2).approvals(state: 'pending');
      expect(transport2.requests.single.query, {'state': 'pending'});
    });

    test('budget requests are listed, read and answered', () async {
      final requestJson = {
        'id': 'b1',
        'potId': 'pot1',
        'window': 'day',
        'amountMicros': null,
        'tokens': 500000,
        'reason': 'Long run',
        'state': 'approved_amount',
        'approvedAmountMicros': null,
        'approvedTokens': 250000,
        'createdAt': 1,
        'answeredAt': 2,
      };
      final (api, transport) = _answering({
        'budgetRequests': [requestJson],
        'budgetRequest': requestJson,
      });
      final decisions = DecisionsApi(api);
      final list = await decisions.budgetRequests(state: 'pending');
      await decisions.budgetRequest('b1');
      final answered = await decisions.answerBudgetRequest(
        'b1',
        answer: 'approve_amount',
        amount: 250000,
      );
      await decisions.answerBudgetRequest('b1', answer: 'deny');
      final requests = transport.requests;
      expect(requests[0].path, '/api/budget-requests');
      expect(requests[0].query, {'state': 'pending'});
      expect(requests[1].path, '/api/budget-requests/b1');
      expect(requests[2].path, '/api/budget-requests/b1/answer');
      expect(requests[2].json, {'answer': 'approve_amount', 'amount': 250000});
      expect(requests[3].json, {'answer': 'deny'});
      expect(list.single.unit, 'tokens');
      expect(list.single.window, 'day');
      expect(answered.approvedTokens, 250000);
    });

    test(
      'handovers are listed, read, created, confirmed and rejected',
      () async {
        final handoverJson = {
          'id': 'h1',
          'fromPotId': 'pot1',
          'to': {'kind': 'pot', 'potId': 'pot2'},
          'proposedBy': 'pot',
          'reason': 'Leaving',
          'state': 'proposed',
          'revision': 5,
          'items': [
            {
              'kind': 'responsibility',
              'ref': '0',
              'label': 'Fix flakes',
              'fit': 'narrowed',
              'reason': 'Bo cannot write to n:w',
            },
          ],
          'createdAt': 1,
          'appliedAt': null,
        };
        final (api, transport) = _answering({
          'handovers': [handoverJson],
          'handover': handoverJson,
        });
        final decisions = DecisionsApi(api);
        final list = await decisions.handovers(state: 'proposed');
        await decisions.handover('h1');
        await decisions.createHandover(
          fromPotId: 'pot1',
          to: const HandoverTo.user(),
          items: const [HeldItem(kind: 'work', ref: 'w1', label: 'Fix')],
          reason: 'Mine now',
        );
        await decisions.createHandover(
          fromPotId: 'pot1',
          to: const HandoverTo.pot('pot2'),
        );
        await decisions.confirmHandover('h1', revision: 5);
        await decisions.rejectHandover('h1');
        final requests = transport.requests;
        expect(requests[0].path, '/api/handovers');
        expect(requests[0].query, {'state': 'proposed'});
        expect(requests[1].path, '/api/handovers/h1');
        expect(
          '${requests[2].method} ${requests[2].path}',
          'POST /api/handovers',
        );
        expect(requests[2].json, {
          'fromPotId': 'pot1',
          'to': {'kind': 'user'},
          'items': [
            {'kind': 'work', 'ref': 'w1'},
          ],
          'reason': 'Mine now',
        });
        expect(requests[3].json, {
          'fromPotId': 'pot1',
          'to': {'kind': 'pot', 'potId': 'pot2'},
        });
        expect(requests[4].path, '/api/handovers/h1/confirm');
        expect(requests[4].json, {'revision': 5});
        expect(requests[5].path, '/api/handovers/h1/reject');
        final handover = list.single;
        expect(handover.to.potId, 'pot2');
        expect(handover.proposedBy, 'pot');
        expect(handover.revision, 5);
        expect(handover.items.single.fit, 'narrowed');
        expect(handover.items.single.item.label, 'Fix flakes');
        expect(handover.items.single.reason, 'Bo cannot write to n:w');
      },
    );

    test('a causal root is read, resumed and stopped', () async {
      final rootJson = {
        'id': 'r1',
        'originKind': 'user_message',
        'originRef': 'm1',
        'threadId': 't1',
        'initiatorPot': 'pot1',
        'depthLimit': 6,
        'fanoutLimit': 4,
        'budgetMoneyMicros': 1000,
        'budgetTokens': 2000,
        'spentMoneyMicros': 10,
        'spentTokens': 20,
        'reservedMoneyMicros': 1,
        'reservedTokens': 2,
        'state': 'suspended',
        'suspendReason': 'no progress',
        'suspendedAt': 50,
        'lastProgressAt': 40,
        'createdAt': 30,
        'wakesSinceProgress': 12,
        'messagesSinceProgress': 20,
      };
      final (api, transport) = _answering({
        'causalRoot': rootJson,
        'kicked': ['pot1'],
      });
      final decisions = DecisionsApi(api);
      final root = await decisions.causalRoot('r1');
      final resumed = await decisions.resumeCausalRoot('r1');
      await decisions.stopCausalRoot('r1');
      expect(
        [for (final r in transport.requests) '${r.method} ${r.path}'],
        [
          'GET /api/causal-roots/r1',
          'POST /api/causal-roots/r1/resume',
          'POST /api/causal-roots/r1/stop',
        ],
      );
      expect(root.suspended, isTrue);
      expect(root.originKind, 'user_message');
      expect(root.wakesSinceProgress, 12);
      expect(root.suspendReason, 'no progress');
      expect(resumed.root.id, 'r1');
      expect(resumed.kicked, ['pot1']);
    });
  });

  group('activity', () {
    test('filters, the cursor and rows of a deleted pot', () async {
      final (api, transport) = _answering({
        'activity': [
          {
            'id': 'act2',
            'potId': null,
            'potName': 'Ada',
            'potAvatarColor': 3,
            'at': 500,
            'kind': 'work_opened',
            'counterpart': {'kind': 'work_session', 'id': 's1'},
            'summary': 'Opened Fix CI',
            'refs': {'session': 's1', 'root': 'r1'},
            'causalRoot': 'r1',
          },
        ],
        'nextBefore': 'act2',
      });
      final page = await ActivityApi(api).activity(
        potId: 'pot1',
        kinds: ['dm', 'work_opened'],
        since: 100,
        until: 900,
        before: 'act9',
        limit: 20,
      );
      final request = transport.requests.single;
      expect(request.path, '/api/activity');
      expect(request.query, {
        'potId': 'pot1',
        'kind': 'dm,work_opened',
        'since': '100',
        'until': '900',
        'before': 'act9',
        'limit': '20',
      });
      final entry = page.entries.single;
      expect(entry.potId, isNull);
      expect(entry.potName, 'Ada');
      expect(entry.at, 500);
      expect(entry.counterpart?.kind, 'work_session');
      expect(entry.counterpart?.id, 's1');
      expect(entry.refs.session, 's1');
      expect(entry.refs.root, 'r1');
      expect(entry.refs.thread, isNull);
      expect(page.nextBefore, 'act2');

      final (api2, transport2) = _answering({'activity': <Object?>[]});
      final last = await ActivityApi(api2).activity();
      expect(transport2.requests.single.query, isEmpty);
      expect(last.nextBefore, isNull);
    });

    test('a pot view reads threads, sent messages and instructions', () async {
      final (api, transport) = _answering({
        'potId': 'pot1',
        'threads': [
          {
            'id': 't1',
            'kind': 'pot_dm',
            'pots': ['pot1', 'pot2'],
          },
        ],
        'sent': [_messageJson(3)],
        'instructions': [
          {
            'id': 'i1',
            'workId': 'w1',
            'title': 'Fix CI',
            'sessionId': 's1',
            'body': 'Run the tests',
            'delivery': 'delivered',
            'createdAt': 7,
          },
        ],
        'nextBefore': 'm3',
      });
      final view = await ActivityApi(api).view('pot1', before: 'm9');
      expect(transport.requests.single.path, '/api/pots/pot1/view');
      expect(transport.requests.single.query, {'before': 'm9'});
      expect(view.threads.single.isPotDm, isTrue);
      expect(view.sent.single.seq, 3);
      expect(view.instructions.single.workTitle, 'Fix CI');
      expect(view.instructions.single.sessionId, 's1');
      expect(view.instructions.single.body, 'Run the tests');
      expect(view.instructions.single.delivery, 'delivered');
      expect(view.nextBefore, 'm3');

      final (api2, _) = _answering({'potId': 'pot1'});
      final bare = await ActivityApi(api2).view('pot1');
      expect(bare.instructions, isEmpty);
      expect(bare.nextBefore, isNull);
    });

    test('notifications are listed and marked read', () async {
      final notificationJson = {
        'id': 'n1',
        'eventId': 'e1',
        'sourceKind': 'session',
        'sourceRef': 's1',
        'condition': 'tests failed',
        'issuerPotId': null,
        'observations': [
          {
            'potId': 'pot1',
            'potName': 'Ada',
            'note': 'CI broke',
            'evidence': ['log line'],
            'createdAt': 3,
          },
        ],
        'state': 'open',
        'createdAt': 3,
        'updatedAt': 4,
      };
      final (api, transport) = _answering({
        'notifications': [notificationJson],
        'notification': {...notificationJson, 'state': 'read'},
      });
      final activity = ActivityApi(api);
      final list = await activity.notifications(state: 'open');
      final read = await activity.markNotificationRead('n1');
      expect(transport.requests.first.path, '/api/observation-notifications');
      expect(transport.requests.first.query, {'state': 'open'});
      expect(transport.requests.last.method, 'POST');
      expect(
        transport.requests.last.path,
        '/api/observation-notifications/n1/read',
      );
      expect(list.single.open, isTrue);
      expect(list.single.issuerPotId, isNull);
      expect(list.single.observations.single.evidence, ['log line']);
      expect(read.open, isFalse);
    });
  });

  group('me, images and usage', () {
    test('me is read and patched', () async {
      final (api, transport) = _answering({
        'profile': {
          'displayName': 'Kim',
          'avatarColor': 5,
          'avatarImage': 'img1',
          'revision': 7,
        },
      });
      final me = MeApi(api);
      final profile = await me.read();
      await me.update(
        revision: 7,
        displayName: 'Kim L',
        removeAvatarImage: true,
      );
      await me.update(revision: 8, avatarColor: 2, avatarImage: 'img2');
      expect(transport.requests.first.path, '/api/me');
      expect(profile.displayName, 'Kim');
      expect(profile.avatarImage, 'img1');
      expect(profile.revision, 7);
      expect(transport.requests[1].method, 'PATCH');
      expect(transport.requests[1].json, {
        'revision': 7,
        'displayName': 'Kim L',
        'avatarImage': null,
      });
      expect(transport.requests[2].json, {
        'revision': 8,
        'avatarColor': 2,
        'avatarImage': 'img2',
      });

      final (api2, _) = _answering({
        'profile': {'displayName': 'Flat', 'avatarColor': 3, 'revision': 2},
      });
      final flat = await MeApi(api2).read();
      expect(flat.displayName, 'Flat');
      expect(flat.revision, 2);
    });

    test('an image is uploaded as raw bytes and read back', () async {
      final (api, transport) = _answering({'imageId': 'img9'});
      final images = ImagesApi(api);
      final id = await images.upload([1, 2, 3], contentType: 'image/png');
      final request = transport.requests.single;
      expect(request.method, 'POST');
      expect(request.path, '/api/images');
      expect(request.bytes, [1, 2, 3]);
      expect(request.contentType, 'image/png');
      expect(request.json, isNull);
      expect(id, 'img9');
      expect(ImagesApi.path('img 9'), '/api/images/img%209');

      final transport2 = FakeTransport(
        onSend: (_) async => const ApiResponse(200, [9, 8, 7]),
      );
      expect(await ImagesApi(ApiClient(transport2)).read('img9'), [9, 8, 7]);
      expect(transport2.requests.single.path, '/api/images/img9');

      final (api3, _) = _answering({
        'error': {'code': 'not_found', 'message': 'No image'},
      }, status: 404);
      await expectLater(ImagesApi(api3).read('gone'), throwsA(isA<ApiError>()));
    });

    test('usage asks for local dates and reads each group', () async {
      final sums = {
        'requests': 2,
        'tokens': {
          'input': 10,
          'output': 20,
          'cacheRead': 1,
          'cacheWrite': 2,
          'total': 33,
        },
        'billedMicros': 500,
        'subscriptionApiEquivalentMicros': 900,
        'subscriptionTokens': 7,
      };
      final (api, transport) = _answering({
        'days': [
          {...sums, 'date': '2026-11-01'},
        ],
        'byModel': [
          {
            ...sums,
            'provider': 'anthropic',
            'model': 'opus',
            'authKind': 'subscription',
            'plan': 'max',
          },
        ],
        'byActor': [
          {...sums, 'actorKind': 'pot', 'actorId': 'pot1'},
        ],
        'byPurpose': [
          {...sums, 'purpose': 'pot_wake'},
        ],
        'total': sums,
        'streakDays': 4,
        'pricingRevision': '0.9.1',
        'timezone': 'Asia/Taipei',
      });
      final report = await UsageApi(api).usage(
        from: DateTime(2026, 11, 1),
        to: DateTime(2026, 11, 30),
        tz: 'Asia/Taipei',
      );
      final request = transport.requests.single;
      expect(request.path, '/api/usage');
      expect(request.query, {
        'from': '2026-11-01',
        'to': '2026-11-30',
        'tz': 'Asia/Taipei',
      });
      expect(report.days.single.date, '2026-11-01');
      expect(report.days.single.tokens.total, 33);
      expect(report.byModel.single.authKind, 'subscription');
      expect(report.byActor.single.actorId, 'pot1');
      expect(report.byPurpose.single.purpose, 'pot_wake');
      expect(report.total.subscriptionApiEquivalentMicros, 900);
      expect(report.streakDays, 4);
      expect(report.timezone, 'Asia/Taipei');
    });
  });

  group('models', () {
    test('the catalog reads the default model and thinking levels', () async {
      final (api, transport) = _answering({
        'models': [
          {
            'provider': 'anthropic',
            'id': 'opus',
            'reasoning': true,
            'thinkingLevels': ['low', 'medium', 'high', 'max'],
          },
          {'provider': 'local', 'id': 'tiny'},
        ],
        'defaultModel': {
          'provider': 'anthropic',
          'id': 'opus',
          'thinking': 'medium',
        },
      });
      final models = ModelsApi(api);
      final catalog = await models.catalog();
      expect(transport.requests.single.path, '/api/models');
      expect(catalog.defaultModel?.id, 'opus');
      expect(catalog.defaultModel?.thinking, 'medium');
      expect(catalog.models.first.thinkingLevels, [
        'low',
        'medium',
        'high',
        'max',
      ]);
      expect(catalog.models.last.thinkingLevels, isEmpty);
      expect(await models.list(), hasLength(2));

      final (api2, _) = _answering({'models': <Object?>[]});
      expect((await ModelsApi(api2).catalog()).defaultModel, isNull);
    });
  });

  group('hints', () {
    test('causal roots are a hint kind', () {
      expect(
        EventMessage.fromJson({'type': 'causal_roots_changed'}),
        isA<HintMessage>(),
      );
      final stream = HintStream(
        transport: FakeTransport(),
        kinds: const {
          'pots',
          'threads',
          'approvals',
          'activity',
          'budgetRequests',
          'notifications',
          'causalRoots',
        },
      );
      expect(stream.target.queryParameters, {
        'pots': '1',
        'threads': '1',
        'approvals': '1',
        'activity': '1',
        'budgetRequests': '1',
        'notifications': '1',
        'causalRoots': '1',
      });
    });
  });
}
