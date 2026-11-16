import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_mobile/live/first_send_recovery.dart';
import 'package:pirc_mobile/live/gateway.dart';
import 'package:pirc_mobile/live/app.dart';
import 'first_send_test.dart' show FirstPort;
import 'live_test.dart' show FakeGateway, theme;

void main() {
  Future<(LiveController, FakeGateway, FirstPort)> setup() async {
    final g = FakeGateway();
    final p = FirstPort(g);
    final c = LiveController(g);
    await c.boot();
    await c.create('w');
    c.editDraft('One line\nOriginal details stay folded');
    await c.flushDraft();
    return (c, g, p);
  }

  Widget page(LiveController c, Widget Function() content) => MaterialApp(
    theme: theme.build(Brightness.light),
    home: Scaffold(
      body: ListenableBuilder(
        listenable: c,
        builder: (context, _) => content(),
      ),
    ),
  );
  testWidgets(
    'unknown results keep the original folded and Check never sends or takes control',
    (tester) async {
      final (c, g, p) = await setup();
      final row = p.records.values.single;
      row['frozen'] = true;
      row['prepareAttempted'] = true;
      row['revision']++;
      row['preparation'] = {
        'operationId': row['operationId'],
        'sessionId': 'pending',
        'workspaceId': 'w',
        'accepted': true,
        'state': 'outcome_unknown',
        'cleanupPending': false,
      };
      await c.firstSend.check();
      await tester.pumpWidget(page(c, () => FirstSendRecovery(controller: c)));
      expect(find.text('First message outcome is unknown'), findsOneWidget);
      expect(find.text('Continue sending'), findsNothing);
      expect(find.byType(SelectableText), findsNothing);
      g.calls.clear();
      await tester.tap(find.text('Check result'));
      await tester.pumpAndSettle();
      expect(g.calls.map((call) => call.$1), ['firstSendCheck']);
      await tester.tap(find.byKey(const ValueKey('first-send-original')));
      await tester.pumpAndSettle();
      expect(find.byType(SelectableText), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      c.dispose();
      await g.stream.close();
    },
  );
  testWidgets(
    'a stale Discard action refreshes acceptance and asks before deleting the chat and memories',
    (tester) async {
      final (c, g, p) = await setup();
      c.workspaces = c.workspaces.map((w) => {...w, 'kind': 'chat'}).toList();
      final row = p.records.values.single;
      row['frozen'] = true;
      row['prepareAttempted'] = true;
      row['revision']++;
      row['preparation'] = {
        'operationId': row['operationId'],
        'sessionId': 'pending',
        'workspaceId': 'w',
        'accepted': true,
        'state': 'accepted',
        'cleanupPending': false,
      };
      await tester.pumpWidget(
        page(
          c,
          () => SingleChildScrollView(
            child: Column(
              children: [
                SavedFirstSends(controller: c),
                if (c.firstSend.frozen) FirstSendRecovery(controller: c),
              ],
            ),
          ),
        ),
      );
      await tester.tap(find.byKey(const ValueKey('saved-first-sends')));
      await tester.pumpAndSettle();
      g.calls.clear();
      await tester.tap(find.text('Discard draft'));
      await tester.pumpAndSettle();
      expect(find.text('Delete chat?'), findsOneWidget);
      expect(
        find.textContaining('USER memories and MEMORY notes'),
        findsOneWidget,
      );
      expect(g.calls.where((call) => call.$1 == 'firstSendCancel'), isEmpty);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(g.calls.where((call) => call.$1 == 'firstSendCancel'), isEmpty);
      expect(
        p.records.values.single['message'],
        'One line\nOriginal details stay folded',
      );
      await tester.pumpWidget(const SizedBox());
      c.dispose();
      await g.stream.close();
    },
  );
  testWidgets(
    'the actual App replaces the pending composer with recovery controls',
    (tester) async {
      tester.view.physicalSize = const Size(1024, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final g = FakeGateway();
      final p = FirstPort(g);
      final c = LiveController(g);
      await tester.pumpWidget(MobileApp(theme: theme, controller: c));
      await tester.pumpAndSettle();
      await c.create('w');
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('live-draft')),
        'From the App',
      );
      p.loseSubmit = true;
      await c.send('prompt');
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('first-send-recovery')), findsOneWidget);
      expect(find.byKey(const Key('live-draft')), findsNothing);
      expect(find.byKey(const ValueKey('saved-first-sends')), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await g.stream.close();
    },
  );

  testWidgets(
    'unmapped pending input offers scoped Stop and confirmed Stop opens only by explicit release',
    (tester) async {
      final (c, g, p) = await setup();
      final row = p.records.values.single;
      row['frozen'] = true;
      row['prepareAttempted'] = true;
      row['revision']++;
      row['preparation'] = {
        'operationId': row['operationId'],
        'sessionId': 's',
        'workspaceId': 'w',
        'state': 'accepted',
        'accepted': true,
        'nodeMapped': false,
        'cleanupPending': false,
      };
      await c.firstSend.check();
      expect(c.firstSend.hasMapping, false);
      expect(c.firstSend.canStop, true);
      await tester.pumpWidget(page(c, () => FirstSendRecovery(controller: c)));
      expect(find.text('Stop pending message'), findsOneWidget);
      g.calls.clear();
      await tester.tap(find.text('Stop pending message'));
      await tester.pumpAndSettle();
      expect(g.calls.map((call) => call.$1), ['firstSendStop']);
      expect(find.text('Stopping first message'), findsOneWidget);
      expect(find.text('Take control'), findsNothing);
      expect(find.text('Stop pending message'), findsNothing);
      row['revision']++;
      row['preparation'] = {
        ...obj(row['preparation']),
        'state': 'stopped',
        'messageAdmission': {
          'outcome': 'not_admitted',
          'stopRequested': true,
          'stopConfirmed': true,
        },
      };
      await c.firstSend.check();
      await tester.pumpAndSettle();
      expect(find.text('First message stopped'), findsOneWidget);
      expect(c.firstSend.hasMapping, false);
      g.calls.clear();
      await tester.tap(find.text('Open conversation'));
      await tester.pumpAndSettle();
      expect(g.calls.first.$1, 'firstSendRelease');
      expect(g.calls.where((call) => call.$1 == 'firstSendSubmit'), isEmpty);
      expect(row['message'], 'One line\nOriginal details stay folded');
      await tester.pumpWidget(const SizedBox());
      c.dispose();
      await g.stream.close();
    },
  );
  testWidgets(
    'an attempt the Node refused for good reads as not executed and keeps Retry enabled',
    (tester) async {
      final (c, g, p) = await setup();
      final row = p.records.values.single;
      row['frozen'] = true;
      row['prepareAttempted'] = true;
      row['revision']++;
      row['preparation'] = {
        'operationId': row['operationId'],
        'sessionId': 'pending',
        'workspaceId': 'w',
        'accepted': true,
        'nodeMapped': true,
        'state': 'admission_failed',
        'cleanupPending': false,
        'messageAdmission': {
          'commandId': 'cmd',
          'attemptNumber': 0,
          'outcome': 'not_admitted',
          'retryEligible': true,
          'stopRequested': false,
          'stopConfirmed': false,
          'recovery': 'voided',
        },
      };
      await c.firstSend.check();
      await tester.pumpWidget(page(c, () => FirstSendRecovery(controller: c)));
      expect(
        find.text('First message was not executed. You can retry.'),
        findsOneWidget,
      );
      expect(find.text('First message admitted'), findsNothing);
      expect(find.text('First message outcome is unknown'), findsNothing);
      expect(find.text('Retry original message'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      c.dispose();
      await g.stream.close();
    },
  );
  testWidgets(
    'a Node that cannot recover an unknown outcome says it needs an upgrade',
    (tester) async {
      final (c, g, p) = await setup();
      final row = p.records.values.single;
      row['frozen'] = true;
      row['prepareAttempted'] = true;
      row['revision']++;
      row['preparation'] = {
        'operationId': row['operationId'],
        'sessionId': 'pending',
        'workspaceId': 'w',
        'accepted': true,
        'nodeMapped': true,
        'state': 'outcome_unknown',
        'cleanupPending': false,
        'deliveryError': 'recovery_unsupported',
        'messageAdmission': {
          'commandId': 'cmd',
          'attemptNumber': 0,
          'outcome': 'outcome_unknown',
          'retryEligible': false,
          'stopRequested': false,
          'stopConfirmed': false,
          'recovery': 'recovery_unsupported',
        },
      };
      await c.firstSend.check();
      await tester.pumpWidget(page(c, () => FirstSendRecovery(controller: c)));
      expect(find.text('First message outcome is unknown'), findsOneWidget);
      expect(find.textContaining('This Node must be upgraded'), findsOneWidget);
      expect(find.text('Retry original message'), findsNothing);
      await tester.pumpWidget(const SizedBox());
      c.dispose();
      await g.stream.close();
    },
  );
  testWidgets(
    'confirmed rejection offers Retry and a lost native reply restores pending status',
    (tester) async {
      final (c, g, p) = await setup();
      final row = p.records.values.single;
      row['frozen'] = true;
      row['prepareAttempted'] = true;
      row['revision']++;
      row['preparation'] = {
        'operationId': row['operationId'],
        'sessionId': 'pending',
        'workspaceId': 'w',
        'accepted': true,
        'nodeMapped': true,
        'state': 'admission_failed',
        'cleanupPending': false,
        'messageAdmission': {
          'commandId': 'cmd',
          'attemptNumber': 0,
          'outcome': 'not_admitted',
          'retryEligible': true,
          'stopRequested': false,
          'stopConfirmed': false,
        },
      };
      await c.firstSend.check();
      final original = p.call;
      g.handler = (method, args) async {
        if (method == 'firstSendRetry') {
          expect(args['operationId'], row['operationId']);
          expect(args['ownerUser'], 'alice');
          row['revision']++;
          row['uncertain'] = true;
          row['retryAttempt'] = {
            'retryId': 'nonce',
            'previousCommandId': 'cmd',
            'previousAttemptNumber': 0,
          };
          throw StateError('synthetic lost reply');
        }
        return original(method, args);
      };
      await tester.pumpWidget(page(c, () => FirstSendRecovery(controller: c)));
      expect(find.text('Retry original message'), findsOneWidget);
      g.calls.clear();
      await tester.tap(find.text('Retry original message'));
      await tester.pumpAndSettle();
      expect(
        g.calls.where((item) => item.$1 == 'firstSendRetry'),
        hasLength(1),
      );
      expect(find.text('Retry original message'), findsNothing);
      expect(find.text('First message outcome is unknown'), findsOneWidget);
      expect(
        g.calls.any(
          (item) => item.$1 == 'firstSendSubmit' || item.$1 == 'command',
        ),
        false,
      );
      await tester.pumpWidget(const SizedBox());
      c.dispose();
      await g.stream.close();
    },
  );
  testWidgets(
    'interrupted retry recovery updates the saved journal without sending',
    (tester) async {
      final (c, g, p) = await setup();
      final row = p.records.values.single;
      row['frozen'] = true;
      row['prepareAttempted'] = true;
      row['uncertain'] = true;
      row['revision']++;
      row['retryAttempt'] = {
        'retryId': 'nonce',
        'previousCommandId': 'cmd',
        'previousAttemptNumber': 0,
      };
      row['preparation'] = {
        'operationId': row['operationId'],
        'sessionId': 'pending',
        'workspaceId': 'w',
        'accepted': true,
        'nodeMapped': true,
        'state': 'admission_failed',
        'cleanupPending': false,
        'messageAdmission': {
          'commandId': 'cmd',
          'attemptNumber': 0,
          'outcome': 'not_admitted',
          'retryEligible': true,
          'stopRequested': false,
          'stopConfirmed': false,
        },
      };
      await c.firstSend.check();
      final original = p.call;
      g.handler = (method, args) async {
        if (method == 'firstSendRecoverRetry') {
          expect(args['ownerUser'], 'alice');
          expect(args['operationId'], row['operationId']);
          row['revision']++;
          row['uncertain'] = false;
          row['retryAttempt'] = {
            ...obj(row['retryAttempt']),
            'resolved': true,
            'notReserved': true,
          };
          return p.clone(row);
        }
        return original(method, args);
      };
      await tester.pumpWidget(page(c, () => FirstSendRecovery(controller: c)));
      expect(find.text('Recover interrupted retry'), findsOneWidget);
      expect(find.text('Retry original message'), findsNothing);
      g.calls.clear();
      await tester.tap(find.text('Recover interrupted retry'));
      await tester.pumpAndSettle();
      expect(g.calls.map((call) => call.$1), ['firstSendRecoverRetry']);
      expect(find.text('Recover interrupted retry'), findsNothing);
      expect(find.text('Retry original message'), findsOneWidget);
      expect(find.byType(SelectableText), findsNothing);
      expect(row['message'], 'One line\nOriginal details stay folded');
      await tester.pumpWidget(const SizedBox());
      c.dispose();
      await g.stream.close();
    },
  );
}
