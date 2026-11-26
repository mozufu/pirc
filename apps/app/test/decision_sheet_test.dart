import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pirc_app/src/format.dart';
import 'package:pirc_app/src/preferences.dart';
import 'package:pirc_app/src/router.dart';

import 'support/chat_fixtures.dart';
import 'support/fonts.dart';
import 'support/harness.dart';
import 'support/work_fixtures.dart';

Map<String, Object?> _approval({
  String state = 'pending',
  int? remaining = 15800000,
  String? denyReason,
}) => {
  'id': 'a-api',
  'potId': 'p-butler',
  'workTitle': 'Compare three API specs',
  'workspaceId': 'laptop:pirc',
  'provider': 'anthropic',
  'model': 'Claude Opus',
  'thinking': 'high',
  'reason': 'Sonnet gave two different answers',
  'estimateMicros': 800000,
  'remainingMicros': remaining,
  'state': state,
  'denyReason': ?denyReason,
  'createdAt': at(10, 45),
};

Map<String, Object?> _budget({
  String state = 'pending',
  bool tokens = false,
  int? approvedAmountMicros,
}) => {
  'id': 'b1',
  'potId': 'p-butler',
  'window': tokens ? 'day' : 'month',
  if (tokens) 'tokens': 500000 else 'amountMicros': 10000000,
  'reason': 'The API comparison needs two more runs',
  'state': state,
  'approvedAmountMicros': ?approvedAmountMicros,
  'createdAt': at(10, 50),
};

/// The chat fixture (Butler waiting on the user) with the approval and a
/// budget request; [answers] records each answer's body.
class _Decisions {
  _Decisions() {
    fixture.pots[0]['budgetLeft'] = {
      'moneyMicros': 15800000,
      'tokens': 1200000,
    };
  }

  final fixture = ChatFixture();
  Map<String, Object?> approval = _approval();
  Map<String, Object?> budget = _budget();
  final answers = <String, List<Map<String, Object?>>>{};

  /// Answers with this reply instead of the updated item.
  int? answerStatus;

  FakeGateway install() {
    final g = fixture.install();
    g.json['GET /api/model-approvals/a-api'] = (_) => {'approval': approval};
    g.json['GET /api/budget-requests/b1'] = (_) => {'budgetRequest': budget};
    for (final (path, key) in [
      ('/api/model-approvals/a-api/answer', 'approval'),
      ('/api/budget-requests/b1/answer', 'budgetRequest'),
    ]) {
      g.json['POST $path'] = (request) {
        final body = request.json! as Map;
        answers.putIfAbsent(path, () => []).add(body.cast());
        if (answerStatus != null) {
          return apiError(answerStatus!, 'conflict', 'already answered');
        }
        return {key: key == 'approval' ? approval : budget};
      };
    }
    return g;
  }
}

Future<(FakeGateway, _Decisions, ProviderContainer)> _pump(
  WidgetTester tester, {
  _Decisions? decisions,
  String location = '/work',
  double width = 375,
}) async {
  final d = decisions ?? _Decisions();
  final gateway = d.install();
  final container = await pumpApp(
    tester,
    gateway: gateway,
    width: width,
    location: location,
    reduceMotion: true,
    overrides: [clockProvider.overrideWithValue(() => fixedNow)],
  );
  return (gateway, d, container);
}

Future<void> _openFromWork(WidgetTester tester) async {
  await tester.tap(
    find.textContaining('Compare three API specs', findRichText: true),
  );
  await tester.pumpAndSettle();
}

Finder _sheetTitle() => find.text('Butler wants to use Claude Opus');

void main() {
  group('model approval', () {
    appTest('the Work tab\'s row opens the sheet with the facts', (
      tester,
    ) async {
      await _pump(tester);
      await _openFromWork(tester);
      expect(_sheetTitle(), findsOneWidget);
      expect(find.text('pirc mobile · h · Not started'), findsOneWidget);
      expect(find.text('Anthropic · Claude Opus · High'), findsOneWidget);
      expect(find.text('Sonnet gave two different answers'), findsOneWidget);
      expect(
        find.text('Estimated \$0.80 · Butler has \$15.80 left this month'),
        findsOneWidget,
      );
      expect(find.textContaining('“Ask you”'), findsOneWidget);
    });

    appTest('without a money limit the estimate says so', (tester) async {
      final d = _Decisions()..approval = _approval(remaining: null);
      await _pump(tester, decisions: d);
      await _openFromWork(tester);
      expect(find.text('Estimated \$0.80 · no money limit'), findsOneWidget);
    });

    appTest('Allow once answers allow_once and closes', (tester) async {
      final (_, d, _) = await _pump(tester);
      await _openFromWork(tester);
      await tester.tap(find.text('Allow once'));
      await tester.pumpAndSettle();
      expect(d.answers['/api/model-approvals/a-api/answer'], [
        {'answer': 'allow_once'},
      ]);
      expect(_sheetTitle(), findsNothing);
    });

    appTest('Deny answers deny without a reason', (tester) async {
      final (_, d, _) = await _pump(tester);
      await _openFromWork(tester);
      await tester.tap(find.text('Deny'));
      await tester.pumpAndSettle();
      expect(d.answers['/api/model-approvals/a-api/answer'], [
        {'answer': 'deny'},
      ]);
    });

    appTest('Deny with a reason opens a field of at most 2000 characters; '
        'Back keeps the choice open', (tester) async {
      final (_, d, _) = await _pump(tester);
      await _openFromWork(tester);
      await tester.tap(find.text('Deny with a reason'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('deny-reason')), findsOneWidget);
      final send = find.widgetWithText(
        FilledButton,
        'Deny and send the reason',
      );
      expect(tester.widget<FilledButton>(send).onPressed, isNull);
      await tester.enterText(
        find.byKey(const ValueKey('deny-reason')),
        'x' * 2100,
      );
      await tester.pump();
      final field = tester.widget<TextField>(
        find.byKey(const ValueKey('deny-reason')),
      );
      expect(field.controller!.text.length, 2000);
      final back = find.widgetWithText(FilledButton, 'Back');
      await tester.ensureVisible(back);
      await tester.pumpAndSettle();
      await tester.tap(back);
      await tester.pumpAndSettle();
      expect(find.text('Allow once'), findsOneWidget);
      await tester.tap(find.text('Deny with a reason'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('deny-reason')),
        '  Compare once more with Sonnet  ',
      );
      await tester.pump();
      await tester.ensureVisible(send);
      await tester.pumpAndSettle();
      await tester.tap(send);
      await tester.pumpAndSettle();
      expect(d.answers['/api/model-approvals/a-api/answer'], [
        {'answer': 'deny', 'reason': 'Compare once more with Sonnet'},
      ]);
      expect(_sheetTitle(), findsNothing);
    });

    appTest('a 409 shows what was already decided', (tester) async {
      final d = _Decisions()..answerStatus = 409;
      final (_, decisions, _) = await _pump(tester, decisions: d);
      await _openFromWork(tester);
      decisions.approval = _approval(state: 'denied', denyReason: 'Not today');
      await tester.tap(find.text('Allow once'));
      await tester.pumpAndSettle();
      expect(_sheetTitle(), findsOneWidget);
      expect(find.text('Answered · Denied: Not today'), findsOneWidget);
      expect(find.text('Allow once'), findsNothing);
      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();
      expect(_sheetTitle(), findsNothing);
    });

    appTest('another device\'s answer shows "Answered" with the result', (
      tester,
    ) async {
      final (gateway, d, _) = await _pump(tester);
      await _openFromWork(tester);
      d.approval = _approval(state: 'allowed_once');
      gateway.socket('/api/hints')!.push({'type': 'approvals_changed'});
      await tester.pumpAndSettle();
      expect(find.text('Answered · Allowed once'), findsOneWidget);
      expect(find.text('Deny'), findsNothing);
    });

    appTest('a push opens the sheet over its tab and leaves the location', (
      tester,
    ) async {
      final (_, _, container) = await _pump(
        tester,
        location: '/work?approval=a-api',
      );
      expect(_sheetTitle(), findsOneWidget);
      final router = container.read(routerProvider);
      expect(router.routeInformationProvider.value.uri.toString(), '/work');
      await tester.tap(find.text('Allow once'));
      await tester.pumpAndSettle();
      expect(_sheetTitle(), findsNothing);
    });
  });

  group('budget request', () {
    appTest('shows the ask and what is left; Approve answers approve', (
      tester,
    ) async {
      final (_, d, _) = await _pump(tester, location: '/chat?budget=b1');
      expect(find.text('Butler asks for more budget'), findsOneWidget);
      expect(find.text('\$10.00 more this month'), findsOneWidget);
      expect(find.text('\$15.80 left this month'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, 'Approve'));
      await tester.pumpAndSettle();
      expect(d.answers['/api/budget-requests/b1/answer'], [
        {'answer': 'approve'},
      ]);
    });

    appTest('another amount is sent in micro-dollars', (tester) async {
      final (_, d, _) = await _pump(tester, location: '/chat?budget=b1');
      await tester.tap(find.text('Approve another amount'));
      await tester.pumpAndSettle();
      final confirm = find.widgetWithText(FilledButton, 'Approve this amount');
      expect(tester.widget<FilledButton>(confirm).onPressed, isNull);
      await tester.enterText(
        find.byKey(const ValueKey('budget-amount')),
        '12.5',
      );
      await tester.pump();
      await tester.tap(confirm);
      await tester.pumpAndSettle();
      expect(d.answers['/api/budget-requests/b1/answer'], [
        {'answer': 'approve_amount', 'amount': 12500000},
      ]);
    });

    appTest('a token request asks in tokens', (tester) async {
      final d = _Decisions()..budget = _budget(tokens: true);
      await _pump(tester, decisions: d, location: '/chat?budget=b1');
      expect(find.text('500,000 more tokens today'), findsOneWidget);
      expect(find.text('1,200,000 tokens left today'), findsOneWidget);
      await tester.tap(find.text('Approve another amount'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('budget-amount')),
        '200000',
      );
      await tester.pump();
      await tester.tap(find.text('Approve this amount'));
      await tester.pumpAndSettle();
      expect(d.answers['/api/budget-requests/b1/answer'], [
        {'answer': 'approve_amount', 'amount': 200000},
      ]);
    });

    appTest('Deny answers deny; an answered request shows its result', (
      tester,
    ) async {
      final (_, d, container) = await _pump(
        tester,
        location: '/chat?budget=b1',
      );
      await tester.tap(find.text('Deny'));
      await tester.pumpAndSettle();
      expect(d.answers['/api/budget-requests/b1/answer'], [
        {'answer': 'deny'},
      ]);
      d.budget = _budget(
        state: 'approved_amount',
        approvedAmountMicros: 5000000,
      );
      container.read(routerProvider).go('/chat?budget=b1');
      await tester.pumpAndSettle();
      expect(
        find.text('Answered · Approved \$5.00 more this month'),
        findsOneWidget,
      );
    });
  });

  group('golden images', () {
    for (final reason in [false, true]) {
      for (final width in goldenWidths) {
        for (final mode in [ThemeMode.light, ThemeMode.dark]) {
          final name = reason ? 'approval_reason' : 'approval';
          testWidgets('$name ${width.toInt()} ${mode.name}', (tester) async {
            await tester.runAsync(loadGoldenFonts);
            final d = _Decisions();
            final container = await pumpApp(
              tester,
              gateway: d.install(),
              width: width,
              height: goldenHeight(width),
              location: '/work',
              reduceMotion: true,
              overrides: [clockProvider.overrideWithValue(() => fixedNow)],
            );
            container.read(themeModeProvider.notifier).select(mode);
            await tester.pumpAndSettle();
            await _openFromWork(tester);
            if (reason) {
              await tester.tap(find.text('Deny with a reason'));
              await tester.pumpAndSettle();
            }
            await expectLater(
              find.byType(MaterialApp),
              matchesGoldenFile(
                'goldens/${name}_${width.toInt()}_${mode.name}.png',
              ),
            );
            await disposeApp(tester);
          }, tags: ['golden']);
        }
      }
    }
  });
}
