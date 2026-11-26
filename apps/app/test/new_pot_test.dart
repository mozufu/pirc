import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_app/src/chat/pot_draft.dart';
import 'package:pirc_app/src/format.dart';
import 'package:pirc_app/src/preferences.dart';
import 'package:pirc_app/src/router.dart';
import 'package:pirc_client/pirc_client.dart';
import 'package:pirc_ui/pirc_ui.dart';

import 'support/chat_fixtures.dart';
import 'support/fonts.dart';
import 'support/harness.dart';
import 'support/work_fixtures.dart';

const _rigorous =
    'Precise and careful. Checks facts before answering, says when unsure, '
    'and prefers correctness over speed.';
const _concise =
    'Brief and direct. Answers in as few words as possible and skips '
    'pleasantries.';

Map<String, Object?> _model(
  String provider,
  String id,
  String name, [
  List<String> levels = const [],
]) => {
  'provider': provider,
  'id': id,
  'name': name,
  'reasoning': levels.isNotEmpty,
  'thinkingLevels': levels,
};

/// The chat fixture with the models, the picture upload and the create
/// route; [created] records each create body.
class _NewPot {
  final fixture = ChatFixture();
  final created = <Object?>[];
  final uploads = <ApiRequest>[];

  /// Answers the create with this instead of the new pot.
  ApiResponse? refuse;

  Map<String, Object?> models = {
    'models': [
      _model('anthropic', 'claude-sonnet', 'Claude Sonnet', [
        'low',
        'medium',
        'high',
        'max',
      ]),
      _model('anthropic', 'claude-opus', 'Claude Opus', [
        'low',
        'medium',
        'high',
        'xhigh',
        'max',
      ]),
      _model('openai', 'gpt-5', 'GPT-5', ['minimal', 'low', 'high']),
      _model('ollama', 'qwen3', 'qwen3'),
    ],
    'defaultModel': {
      'provider': 'anthropic',
      'id': 'claude-sonnet',
      'thinking': 'high',
    },
  };

  FakeGateway install() {
    final g = fixture.install();
    g.json['GET /api/models'] = (_) => models;
    g.json['POST /api/images'] = (request) {
      uploads.add(request);
      return {'imageId': 'img-1'};
    };
    g.json['POST /api/pots'] = (request) {
      created.add(jsonDecode(jsonEncode(request.json)));
      if (refuse != null) return refuse;
      return {
        'pot': {...potJson('p-new', 'Researcher', color: 3), 'revision': 1},
      };
    };
    return g;
  }
}

final _picture = Uint8List.fromList([137, 80, 78, 71, 1, 2, 3]);

Future<(FakeGateway, _NewPot, ProviderContainer)> _pump(
  WidgetTester tester, {
  _NewPot? newPot,
  double width = 375,
}) async {
  final n = newPot ?? _NewPot();
  final gateway = n.install();
  final container = await pumpApp(
    tester,
    gateway: gateway,
    width: width,
    height: 812,
    location: '/chat?open=new-pot',
    reduceMotion: true,
    overrides: [
      clockProvider.overrideWithValue(() => fixedNow),
      avatarPicturePickerProvider.overrideWithValue(() async => _picture),
    ],
  );
  return (gateway, n, container);
}

Future<void> _tap(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

Future<void> _type(WidgetTester tester, String key, String text) async {
  final field = find.byKey(ValueKey(key));
  await tester.ensureVisible(field);
  await tester.enterText(field, text);
  await tester.pumpAndSettle();
}

Future<void> _next(WidgetTester tester) =>
    _tap(tester, find.byKey(const ValueKey('pot-next')));

Future<void> _back(WidgetTester tester) =>
    _tap(tester, find.byKey(const ValueKey('pot-back')));

Finder _step(int n) => find.textContaining('$n / 4 ·');

String _location(ProviderContainer container) => container
    .read(routerProvider)
    .routeInformationProvider
    .value
    .uri
    .toString();

Future<void> _unfocus(WidgetTester tester) async {
  FocusManager.instance.primaryFocus?.unfocus();
  await tester.pumpAndSettle();
}

Future<void> _addResponsibility(
  WidgetTester tester,
  String title, [
  String detail = '',
]) async {
  await _tap(tester, find.byKey(const ValueKey('add-responsibility')));
  await tester.enterText(
    find.byKey(const ValueKey('responsibility-title')),
    title,
  );
  if (detail.isNotEmpty) {
    await tester.enterText(
      find.byKey(const ValueKey('responsibility-detail')),
      detail,
    );
  }
  await tester.pump();
  await _tap(tester, find.byKey(const ValueKey('responsibility-save')));
}

/// Every step left at its defaults, with only a name: the settled defaults
/// of a new pot.
Map<String, Object?> _defaults({String name = 'Researcher'}) => {
  'profile': {'name': name, 'avatarColor': 1, 'personality': _rigorous},
  'work': {'intro': '', 'description': '', 'responsibilities': <Object?>[]},
  'permissions': {
    'reach': 'answer',
    'observe': <Object?>[],
    'dm': {
      'send': 'all',
      'receive': 'all',
      'sendTo': <Object?>[],
      'receiveFrom': <Object?>[],
    },
    'workLocations': <Object?>[],
    'maxConcurrentWorks': 2,
    'budgetMoneyMonthMicros': 20000000,
    'budgetTokensDay': 2000000,
  },
  'models': {
    'main': {'provider': 'anthropic', 'model': 'claude-sonnet'},
    'fallbacks': <Object?>[],
    'thinking': 'medium',
    'thinkingAuto': false,
    'workModels': <Object?>[],
  },
  'autonomy': {'intervalS': 172800},
};

void main() {
  group('the draft', () {
    test('thinking follows the model: kept, nearest lower, lowest, off', () {
      expect(fitThinking('medium', ['low', 'medium', 'high']), 'medium');
      expect(fitThinking('medium', ['minimal', 'low', 'high']), 'low');
      expect(fitThinking('xhigh', ['low', 'medium', 'high', 'max']), 'high');
      expect(fitThinking('minimal', ['medium', 'high']), 'medium');
      expect(fitThinking('high', const []), 'off');
      expect(fitThinking('off', ['low', 'medium', 'max']), 'medium');
      expect(fitThinking('off', ['high', 'max']), 'high');
    });

    test('a 400 is placed on the step it concerns', () {
      int? step(String message, {String code = 'invalid_input'}) =>
          potErrorStep(ApiError(400, code, message));
      expect(step('name must be 1 to 40 characters'), PotStep.look);
      expect(step('avatarColor must be 1 to 5'), PotStep.look);
      expect(step('personality must be 0 to 8000 characters'), PotStep.look);
      expect(step('Upload the picture first'), PotStep.look);
      expect(step('intro must be 0 to 200 characters'), PotStep.work);
      expect(step('description must be 0 to 8000 characters'), PotStep.work);
      expect(
        step('responsibility title must be 1 to 200 characters'),
        PotStep.work,
      );
      expect(step('Too many responsibilities'), PotStep.work);
      expect(step('maxConcurrentWorks must be 0 to 16'), PotStep.reach);
      expect(
        step('Turn off at most one limit: tokens or money must apply'),
        PotStep.reach,
      );
      expect(step('A pot that only answers observes nothing'), PotStep.reach);
      expect(step('Message peers must be your other pots'), PotStep.reach);
      expect(step('An observed session must be one of yours'), PotStep.reach);
      expect(
        step('The autonomy interval is 1 hour to 1 year, or off'),
        PotStep.reach,
      );
      expect(step('Work locations must be your workspaces'), PotStep.reach);
      expect(
        potErrorStep(const ApiError(404, 'not_found', 'Workspace not found')),
        PotStep.reach,
      );
      expect(step('Unknown thinking level'), PotStep.models);
      expect(step('Too many models'), PotStep.models);
      expect(
        step('x/y is not a model this Gateway serves', code: 'unknown_model'),
        PotStep.models,
      );
      expect(step('Something else'), isNull);
      expect(
        potErrorStep(
          const ApiError(409, 'limit_reached', 'You have the most pots'),
        ),
        isNull,
      );
    });

    test('lengths count characters after trimming, as the Gateway does', () {
      expect(potTextLength('  ab  '), 2);
      expect(potTextLength('😀' * 40), 40);
      expect(
        PotDraft(name: '😀' * 40).issues(PotStep.look),
        isNot(contains(PotIssue.nameTooLong)),
      );
      expect(
        PotDraft(name: '😀' * 41).issues(PotStep.look),
        contains(PotIssue.nameTooLong),
      );
    });

    testWidgets('a picture is cropped to a centred square of 512', (
      tester,
    ) async {
      await tester.runAsync(() async {
        final recorder = ui.PictureRecorder();
        final canvas = ui.Canvas(recorder);
        canvas.drawRect(
          const ui.Rect.fromLTWH(0, 0, 30, 10),
          ui.Paint()..color = const ui.Color(0xFFFF0000),
        );
        canvas.drawRect(
          const ui.Rect.fromLTWH(10, 0, 10, 10),
          ui.Paint()..color = const ui.Color(0xFF0000FF),
        );
        final source = await recorder.endRecording().toImage(30, 10);
        final png = (await source.toByteData(
          format: ui.ImageByteFormat.png,
        ))!.buffer.asUint8List();
        final out = await squareAvatarPng(png);
        final codec = await ui.instantiateImageCodec(out);
        final image = (await codec.getNextFrame()).image;
        expect((image.width, image.height), (512, 512));
        final pixels = (await image.toByteData())!;
        // The centre third (blue) fills the square (away from the edges,
        // where scaling blends in the next source pixel).
        for (final (x, y) in [(100, 256), (411, 256), (256, 100), (256, 411)]) {
          final at = (y * 512 + x) * 4;
          expect(pixels.getUint8(at), 0, reason: 'red at $x,$y');
          expect(pixels.getUint8(at + 2), 255, reason: 'blue at $x,$y');
        }
      });
    });
  });

  group('the steps', () {
    appTest('an untouched pot is created with the settled defaults', (
      tester,
    ) async {
      final (gateway, n, container) = await _pump(tester);
      expect(find.text('New pot'), findsOneWidget);
      expect(_step(1), findsOneWidget);
      await _type(tester, 'pot-name', '  Researcher ');
      await _next(tester);
      expect(_step(2), findsOneWidget);
      await _next(tester);
      expect(_step(3), findsOneWidget);
      await _next(tester);
      expect(_step(4), findsOneWidget);
      expect(find.text('Create Researcher'), findsOneWidget);
      final potReads = gateway.sent('GET', '/api/pots').length;
      await _next(tester);
      expect(n.created, [_defaults()]);
      expect(gateway.sent('GET', '/api/pots').length, greaterThan(potReads));
      expect(_location(container), '/chat?open=pot%3Ap-new');
    });

    appTest('step ① needs a name of 1 to 40 characters', (tester) async {
      final (_, n, _) = await _pump(tester);
      await _next(tester);
      expect(find.text('Give it a name'), findsOneWidget);
      expect(_step(1), findsOneWidget);
      await _type(tester, 'pot-name', 'x' * 41);
      expect(find.text('At most 40 characters'), findsOneWidget);
      await _next(tester);
      expect(_step(1), findsOneWidget);
      await _type(tester, 'pot-name', 'x' * 40);
      expect(find.text('At most 40 characters'), findsNothing);
      await _next(tester);
      expect(_step(2), findsOneWidget);
      expect(n.created, isEmpty);
    });

    appTest('templates fill the personality; Custom empties it', (
      tester,
    ) async {
      await _pump(tester);
      String personality() => tester
          .widget<TextField>(find.byKey(const ValueKey('pot-personality')))
          .controller!
          .text;
      expect(personality(), _rigorous);
      expect(find.textContaining('Found it: with the iPad'), findsOneWidget);
      await _tap(tester, find.byKey(const ValueKey('template-concise')));
      expect(personality(), _concise);
      expect(find.text('Floating keyboard: viewInsets is 0.'), findsOneWidget);
      await _type(tester, 'pot-personality', '$_concise Uses lists.');
      expect(personality(), '$_concise Uses lists.');
      await _tap(tester, find.byKey(const ValueKey('template-custom')));
      expect(personality(), '');
      expect(find.text('Preview, not a real reply'), findsOneWidget);
    });

    appTest('a picked picture is uploaded at once; the colour stays', (
      tester,
    ) async {
      final (_, n, _) = await _pump(tester);
      await _tap(tester, find.byKey(const ValueKey('swatch-4')));
      await _tap(tester, find.byKey(const ValueKey('swatch-upload')));
      expect(n.uploads, hasLength(1));
      expect(n.uploads.single.bytes, _picture);
      expect(n.uploads.single.contentType, 'image/png');
      await _tap(tester, find.byKey(const ValueKey('swatch-upload')));
      await _tap(tester, find.text('Remove the picture'));
      await _tap(tester, find.byKey(const ValueKey('swatch-upload')));
      expect(n.uploads, hasLength(2));
    });

    appTest('step ② checks lengths and edits responsibilities', (tester) async {
      await _pump(tester);
      await _type(tester, 'pot-name', 'Researcher');
      await _next(tester);
      await _type(tester, 'pot-intro', 'i' * 201);
      await _next(tester);
      expect(find.text('At most 200 characters'), findsOneWidget);
      expect(_step(2), findsOneWidget);
      await _type(tester, 'pot-intro', 'Looks things up');
      await _type(tester, 'pot-description', 'd' * 8001);
      expect(find.text('At most 8000 characters'), findsOneWidget);
      await _type(tester, 'pot-description', 'Reads the docs first.');
      await _addResponsibility(tester, 'Answer questions', 'When asked');
      await _addResponsibility(tester, 'Weekly Flutter news');
      await _addResponsibility(tester, 'Drop me');
      expect(find.text('Answer questions'), findsOneWidget);
      expect(find.text('When asked'), findsOneWidget);
      // Move the second one up, then remove the third.
      await _tap(tester, find.text('Weekly Flutter news'));
      await _tap(tester, find.text('Move up'));
      await _tap(tester, find.text('Drop me'));
      await _tap(tester, find.text('Remove'));
      expect(find.text('Drop me'), findsNothing);
      // Edit the first one.
      await _tap(tester, find.text('Weekly Flutter news'));
      expect(
        tester
            .widget<FilledButton>(
              find.byKey(const ValueKey('responsibility-save')),
            )
            .onPressed,
        isNotNull,
      );
      await tester.enterText(
        find.byKey(const ValueKey('responsibility-title')),
        '',
      );
      await tester.pump();
      expect(
        tester
            .widget<FilledButton>(
              find.byKey(const ValueKey('responsibility-save')),
            )
            .onPressed,
        isNull,
        reason: 'a title is needed',
      );
      await tester.enterText(
        find.byKey(const ValueKey('responsibility-title')),
        'Flutter news on Mondays',
      );
      await tester.pump();
      await _tap(tester, find.byKey(const ValueKey('responsibility-save')));
      final titles = [
        for (var i = 0; i < 2; i++)
          tester
              .widget<GroupedRow>(find.byKey(ValueKey('responsibility-$i')))
              .title,
      ];
      expect(titles, ['Flutter news on Mondays', 'Answer questions']);
      await _next(tester);
      expect(_step(3), findsOneWidget);
    });

    appTest('step ③ shows what the reach allows', (tester) async {
      await _pump(tester);
      await _type(tester, 'pot-name', 'Researcher');
      await _next(tester);
      await _next(tester);
      // Only answer: nothing to observe, no work section; it still
      // reviews itself, and that can be turned off.
      expect(find.byKey(const ValueKey('observe-off')), findsOneWidget);
      expect(find.byKey(const ValueKey('observe-calendar')), findsNothing);
      expect(find.text('Budget'), findsNothing);
      expect(
        find.byKey(const ValueKey('review'), skipOffstage: false),
        findsOneWidget,
      );
      await _tap(tester, find.byKey(const ValueKey('reach-observe')));
      expect(find.byKey(const ValueKey('observe-calendar')), findsOneWidget);
      expect(find.byKey(const ValueKey('observe-add')), findsOneWidget);
      expect(find.text('Budget'), findsNothing);
      expect(find.byKey(const ValueKey('location-add')), findsNothing);
      await _tap(tester, find.byKey(const ValueKey('reach-work')));
      expect(find.byKey(const ValueKey('location-add')), findsOneWidget);
      expect(find.text('Budget'), findsOneWidget);
      expect(find.byKey(const ValueKey('review')), findsOneWidget);
      expect(find.text('At most 2'), findsOneWidget);
      // DMs to selected pots pick from the other pots.
      await _tap(tester, find.text('Selected').first);
      expect(find.byKey(const ValueKey('dm-send-p-butler')), findsOneWidget);
      expect(find.byKey(const ValueKey('dm-send-p-old')), findsNothing);
    });

    appTest('the last budget limit on cannot be turned off', (tester) async {
      await _pump(tester);
      await _type(tester, 'pot-name', 'Researcher');
      await _next(tester);
      await _next(tester);
      await _tap(tester, find.byKey(const ValueKey('reach-work')));
      final money = find.byKey(const ValueKey('budget-money-switch'));
      final tokens = find.byKey(const ValueKey('budget-tokens-switch'));
      await _tap(tester, money);
      expect(find.byKey(const ValueKey('budget-money')), findsNothing);
      await _tap(tester, tokens);
      expect(
        find.byKey(const ValueKey('budget-tokens')),
        findsOneWidget,
        reason: 'the token limit stays on',
      );
      await _tap(tester, money);
      await _tap(tester, tokens);
      expect(find.byKey(const ValueKey('budget-tokens')), findsNothing);
      await _type(tester, 'budget-money', '0');
      await _next(tester);
      expect(find.text('Enter a number above 0'), findsOneWidget);
      expect(_step(3), findsOneWidget);
      await _type(tester, 'budget-money', '12.5');
      await _next(tester);
      expect(_step(4), findsOneWidget);
    });

    appTest('step ④ lists the model\'s levels and the work models', (
      tester,
    ) async {
      await _pump(tester);
      await _type(tester, 'pot-name', 'Researcher');
      for (var i = 0; i < 3; i++) {
        await _next(tester);
      }
      expect(find.text('Anthropic · Claude Sonnet'), findsOneWidget);
      for (final level in ['Low', 'Medium', 'High', 'Max']) {
        expect(find.text(level), findsOneWidget);
      }
      expect(find.text('Extra high'), findsNothing);
      expect(find.byKey(const ValueKey('work-models-off')), findsOneWidget);
      expect(
        find.textContaining('In the last step you chose “Only answer you”'),
        findsOneWidget,
      );
      // A model without thinking disables the row.
      await _tap(tester, find.byKey(const ValueKey('main-model')));
      await _tap(tester, find.byKey(const ValueKey('pick-ollama-qwen3')));
      expect(find.byKey(const ValueKey('thinking-none')), findsOneWidget);
      expect(find.byKey(const ValueKey('thinking')), findsNothing);
      // Back to a thinking model: Medium again.
      await _tap(tester, find.byKey(const ValueKey('main-model')));
      await _tap(
        tester,
        find.byKey(const ValueKey('pick-anthropic-claude-opus')),
      );
      expect(find.text('Extra high'), findsOneWidget);
      expect(
        find.text('Always “Medium”; it doesn\'t change it by itself.'),
        findsOneWidget,
      );
      // Work models appear when it may start work.
      await _back(tester);
      await _tap(tester, find.byKey(const ValueKey('reach-work')));
      await _next(tester);
      expect(find.byKey(const ValueKey('work-models-off')), findsNothing);
      expect(
        find.byKey(const ValueKey('work-model-openai-gpt-5')),
        findsOneWidget,
      );
    });

    appTest('step ④ with an empty model catalog refuses to create', (
      tester,
    ) async {
      final n = _NewPot()..models = {'models': <Object?>[]};
      final (gateway, _, _) = await _pump(tester, newPot: n);
      await _type(tester, 'pot-name', 'Researcher');
      for (var i = 0; i < 3; i++) {
        await _next(tester);
      }
      expect(_step(4), findsOneWidget);
      expect(find.text('The Gateway serves no models yet.'), findsOneWidget);
      await _tap(tester, find.byKey(const ValueKey('pot-next')));
      expect(_step(4), findsOneWidget, reason: 'no model, no Create');
      expect(find.text('The Gateway serves no models yet.'), findsOneWidget);
      expect(gateway.sent('POST', '/api/pots'), isEmpty);
    });

    appTest('a full create sends every step once', (tester) async {
      final (gateway, n, container) = await _pump(tester);
      // ①
      await _tap(tester, find.byKey(const ValueKey('swatch-3')));
      await _tap(tester, find.byKey(const ValueKey('swatch-upload')));
      await _type(tester, 'pot-name', 'Researcher');
      await _tap(tester, find.byKey(const ValueKey('template-concise')));
      await _next(tester);
      // ②
      await _type(tester, 'pot-intro', 'Looks things up ');
      await _type(tester, 'pot-description', 'Reads the docs first.');
      await _addResponsibility(tester, 'Answer questions', 'When asked');
      await _next(tester);
      // ③
      await _tap(tester, find.byKey(const ValueKey('reach-work')));
      await _tap(tester, find.byKey(const ValueKey('observe-add')));
      await _tap(
        tester,
        find.byKey(const ValueKey('observe-workspace-laptop:pirc')),
      );
      await _tap(tester, find.byKey(const ValueKey('observe-add')));
      await _tap(tester, find.byKey(const ValueKey('observe-session-s-fix')));
      await _tap(
        tester,
        find.descendant(
          of: find.byKey(const ValueKey('observe-calendar')),
          matching: find.byType(PircSwitch),
        ),
      );
      await _tap(
        tester,
        find.descendant(
          of: find.byKey(const ValueKey('dm-receive')),
          matching: find.text('Selected'),
        ),
      );
      await _tap(tester, find.byKey(const ValueKey('dm-receive-p-butler')));
      await _tap(tester, find.byKey(const ValueKey('dm-receive-p-tester')));
      await _tap(
        tester,
        find.descendant(
          of: find.byKey(const ValueKey('dm-send')),
          matching: find.text('Off'),
        ),
      );
      await _tap(tester, find.byKey(const ValueKey('location-add')));
      await _tap(tester, find.byKey(const ValueKey('location-ci:pirc')));
      await _tap(tester, find.byKey(const ValueKey('access-ci:pirc')));
      await _tap(tester, find.byKey(const ValueKey('max-works-more')));
      await _tap(tester, find.byKey(const ValueKey('budget-money-switch')));
      await _type(tester, 'budget-tokens', '500000');
      await _tap(
        tester,
        find.descendant(
          of: find.byKey(const ValueKey('review')),
          matching: find.text('1 week'),
        ),
      );
      await _next(tester);
      // ④
      await _tap(tester, find.byKey(const ValueKey('main-model')));
      await _tap(tester, find.byKey(const ValueKey('pick-openai-gpt-5')));
      await _tap(tester, find.byKey(const ValueKey('add-fallback')));
      await _tap(
        tester,
        find.byKey(const ValueKey('pick-anthropic-claude-opus')),
      );
      await _tap(tester, find.byKey(const ValueKey('thinking-auto')));
      await _tap(
        tester,
        find.byKey(const ValueKey('work-model-anthropic-claude-sonnet')),
      );
      await _tap(
        tester,
        find.byKey(const ValueKey('work-model-anthropic-claude-opus')),
      );
      await _tap(
        tester,
        find.descendant(
          of: find.byKey(const ValueKey('work-model-anthropic-claude-opus')),
          matching: find.text('Direct'),
        ),
      );
      expect(find.text('Create Researcher'), findsOneWidget);
      await _next(tester);
      expect(gateway.sent('POST', '/api/pots'), hasLength(1));
      expect(n.created.single, {
        'profile': {
          'name': 'Researcher',
          'avatarColor': 3,
          'personality': _concise,
          'avatarImage': 'img-1',
        },
        'work': {
          'intro': 'Looks things up',
          'description': 'Reads the docs first.',
          'responsibilities': [
            {'title': 'Answer questions', 'detail': 'When asked'},
          ],
        },
        'permissions': {
          'reach': 'work',
          'observe': [
            {'kind': 'workspace', 'ref': 'laptop:pirc', 'lead': false},
            {'kind': 'session', 'ref': 's-fix', 'lead': false},
            {'kind': 'calendar', 'ref': '', 'lead': false},
          ],
          'dm': {
            'send': 'off',
            'receive': 'selected',
            'sendTo': <Object?>[],
            'receiveFrom': ['p-butler', 'p-tester'],
          },
          'workLocations': [
            {'workspaceId': 'ci:pirc', 'access': 'write'},
          ],
          'maxConcurrentWorks': 3,
          'budgetMoneyMonthMicros': null,
          'budgetTokensDay': 500000,
        },
        'models': {
          'main': {'provider': 'openai', 'model': 'gpt-5'},
          'fallbacks': [
            {'provider': 'anthropic', 'model': 'claude-opus'},
          ],
          'thinking': 'low',
          'thinkingAuto': true,
          'workModels': [
            {
              'provider': 'anthropic',
              'model': 'claude-sonnet',
              'mode': 'direct',
            },
            {'provider': 'anthropic', 'model': 'claude-opus', 'mode': 'ask'},
          ],
        },
        'autonomy': {'intervalS': 604800},
      });
      expect(_location(container), '/chat?open=pot%3Ap-new');
    });

    appTest('choices kept for a wider reach are not sent with a smaller one', (
      tester,
    ) async {
      final (_, n, _) = await _pump(tester);
      await _type(tester, 'pot-name', 'Researcher');
      await _next(tester);
      await _next(tester);
      await _tap(tester, find.byKey(const ValueKey('reach-work')));
      await _tap(tester, find.byKey(const ValueKey('location-add')));
      await _tap(tester, find.byKey(const ValueKey('location-ci:pirc')));
      await _tap(
        tester,
        find.descendant(
          of: find.byKey(const ValueKey('observe-calendar')),
          matching: find.byType(PircSwitch),
        ),
      );
      await _tap(tester, find.byKey(const ValueKey('reach-answer')));
      await _next(tester);
      await _next(tester);
      expect(n.created, [_defaults()]);
    });
  });

  group('refusals', () {
    appTest('a 400 opens its step with the message; Back keeps the input', (
      tester,
    ) async {
      final n = _NewPot()
        ..refuse = apiError(
          400,
          'invalid_input',
          'intro must be 0 to 200 characters',
        );
      final (_, _, container) = await _pump(tester, newPot: n);
      await _type(tester, 'pot-name', 'Researcher');
      await _tap(tester, find.byKey(const ValueKey('swatch-2')));
      await _next(tester);
      await _type(tester, 'pot-intro', 'Looks things up');
      await _next(tester);
      await _tap(tester, find.byKey(const ValueKey('reach-observe')));
      await _next(tester);
      await _next(tester);
      expect(n.created, hasLength(1));
      expect(_step(2), findsOneWidget);
      expect(find.text('intro must be 0 to 200 characters'), findsOneWidget);
      expect(find.text('Looks things up'), findsOneWidget);
      await _back(tester);
      expect(_step(1), findsOneWidget);
      expect(find.text('Researcher'), findsOneWidget);
      await _next(tester);
      await _next(tester);
      expect(
        tester
            .widget<RadioRow>(find.byKey(const ValueKey('reach-observe')))
            .selected,
        isTrue,
      );
      await _next(tester);
      n.refuse = null;
      await _next(tester);
      expect(n.created, hasLength(2));
      expect(
        (n.created.last! as Map)['work'],
        containsPair('intro', 'Looks things up'),
      );
      expect(((n.created.last! as Map)['profile'] as Map)['avatarColor'], 2);
      expect(_location(container), '/chat?open=pot%3Ap-new');
    });

    appTest('the pot limit shows the Gateway\'s message as is', (tester) async {
      final n = _NewPot()
        ..refuse = apiError(
          409,
          'limit_reached',
          'You have the most pots allowed',
        );
      final (_, _, container) = await _pump(tester, newPot: n);
      await _type(tester, 'pot-name', 'Researcher');
      for (var i = 0; i < 4; i++) {
        await _next(tester);
      }
      expect(_step(4), findsOneWidget);
      expect(find.text('You have the most pots allowed'), findsOneWidget);
      expect(_location(container), '/chat?open=new-pot');
    });

    appTest('Cancel returns to the Chat tab', (tester) async {
      final (_, _, container) = await _pump(tester);
      await _tap(tester, find.byKey(const ValueKey('pot-cancel')));
      expect(_location(container), '/chat');
    });
  });

  group('wide layouts', () {
    appTest('desktop keeps the steps 720 wide beside the list', (tester) async {
      await _pump(tester, width: 1300);
      expect(find.byKey(const ValueKey('pot-cancel')), findsNothing);
      final next = tester.getSize(find.byKey(const ValueKey('pot-next')));
      expect(next.width, lessThanOrEqualTo(720 - 32));
      await _type(tester, 'pot-name', 'Researcher');
      await _next(tester);
      expect(find.byKey(const ValueKey('pot-back')), findsOneWidget);
    });
  });

  group('golden images', () {
    for (final step in [1, 2, 3, 4]) {
      for (final mode in [ThemeMode.light, ThemeMode.dark]) {
        testWidgets('new pot $step 375 ${mode.name}', (tester) async {
          await tester.runAsync(loadGoldenFonts);
          final (_, _, container) = await _pump(tester);
          container.read(themeModeProvider.notifier).select(mode);
          await tester.pumpAndSettle();
          await _goldenState(tester, step);
          await _unfocus(tester);
          await tester.pumpAndSettle();
          await expectLater(
            find.byType(MaterialApp),
            matchesGoldenFile('goldens/new_pot_${step}_375_${mode.name}.png'),
          );
          await disposeApp(tester);
        }, tags: ['golden']);
      }
    }
  });
}

/// The E7–E10 screenshots' state: Researcher in colour 3 with Rigorous;
/// an intro, a description and two responsibilities; may start work,
/// watching one project and taking DMs from two pots; Sonnet with two
/// fallbacks, Medium, adjusting by itself, two work models.
Future<void> _goldenState(WidgetTester tester, int step) async {
  await _tap(tester, find.byKey(const ValueKey('swatch-3')));
  await _type(tester, 'pot-name', 'Researcher');
  if (step == 1) return _scrollTop(tester);
  await _next(tester);
  await _type(tester, 'pot-intro', 'Looks things up and answers with sources');
  await _type(
    tester,
    'pot-description',
    'Starts with the project docs and the official docs; lists the '
        'differences between sources. Doesn\'t edit files: hands that to '
        'Tester or asks you to open a work. Replies in lists, with sources '
        'at the end.',
  );
  await _addResponsibility(
    tester,
    'Answer technical questions with sources',
    'When you or a group asks',
  );
  await _addResponsibility(
    tester,
    'Sum up Flutter news every Monday',
    'Mondays 09:00 · in the calendar',
  );
  if (step == 2) return _scrollTop(tester);
  await _next(tester);
  await _tap(tester, find.byKey(const ValueKey('reach-work')));
  await _tap(tester, find.byKey(const ValueKey('observe-add')));
  await _tap(
    tester,
    find.byKey(const ValueKey('observe-workspace-laptop:pirc')),
  );
  await _tap(
    tester,
    find.descendant(
      of: find.byKey(const ValueKey('dm-receive')),
      matching: find.text('Selected'),
    ),
  );
  await _tap(tester, find.byKey(const ValueKey('dm-receive-p-butler')));
  await _tap(tester, find.byKey(const ValueKey('dm-receive-p-tester')));
  if (step == 3) return _scrollTop(tester);
  await _next(tester);
  await _tap(tester, find.byKey(const ValueKey('add-fallback')));
  await _tap(tester, find.byKey(const ValueKey('pick-openai-gpt-5')));
  await _tap(tester, find.byKey(const ValueKey('add-fallback')));
  await _tap(tester, find.byKey(const ValueKey('pick-ollama-qwen3')));
  await _tap(tester, find.byKey(const ValueKey('thinking-auto')));
  await _tap(
    tester,
    find.byKey(const ValueKey('work-model-anthropic-claude-sonnet')),
  );
  await _tap(
    tester,
    find.byKey(const ValueKey('work-model-anthropic-claude-opus')),
  );
  await _tap(
    tester,
    find.descendant(
      of: find.byKey(const ValueKey('work-model-anthropic-claude-opus')),
      matching: find.text('Direct'),
    ),
  );
  return _scrollTop(tester);
}

Future<void> _scrollTop(WidgetTester tester) async {
  final scrollable = find
      .descendant(
        of: find.byKey(const ValueKey('pot-scroll')),
        matching: find.byType(Scrollable),
      )
      .first;
  final position = tester.state<ScrollableState>(scrollable).position;
  position.jumpTo(0);
  await tester.pumpAndSettle();
}
