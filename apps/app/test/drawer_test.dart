import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_app/src/router.dart';
import 'package:pirc_app/src/shell/app_drawer.dart';
import 'package:pirc_ui/pirc_ui.dart';

import 'support/harness.dart';

FakeGateway _gateway() {
  final gateway = FakeGateway();
  gateway.json['GET /api/nodes'] = (_) => {
    'nodes': [
      {'id': 'Laptop', 'workspaces': <Object?>[]},
      {'id': 'CI-runner', 'workspaces': <Object?>[]},
    ],
  };
  gateway.json['GET /api/sessions'] = (_) => {
    'sessions': [
      for (final (id, node, status) in [
        ('a', 'Laptop', 'running'),
        ('b', 'Laptop', 'running'),
        ('c', 'CI-runner', 'waiting_input'),
      ])
        {
          'id': id,
          'workspaceId': '$node:w',
          'nodeId': node,
          'name': id,
          'runStatus': status,
        },
    ],
  };
  return gateway;
}

void main() {
  for (final (width, drawerWidth) in [
    (375.0, 310.0),
    (700.0, 396.0),
    (1000.0, 396.0),
    (1300.0, 412.0),
  ]) {
    testWidgets('$width wide: the drawer opens, pushes the page and closes', (
      tester,
    ) async {
      final container = await pumpApp(
        tester,
        gateway: _gateway(),
        width: width,
        location: '/work',
      );
      expect(find.text('Hosts'), findsNothing);
      final pageBefore = tester.getTopLeft(find.byType(AdaptiveScaffold));
      await tester.tap(find.byTooltip('Open the menu'));
      await tester.pumpAndSettle();
      expect(container.read(drawerOpenProvider), isTrue);
      expect(find.text('Hosts'), findsOneWidget);
      expect(find.text('Gateway connected'), findsOneWidget);
      expect(find.text('Laptop'), findsOneWidget);
      expect(find.text('2 sessions running'), findsOneWidget);
      expect(find.text('No work running'), findsOneWidget);
      expect(find.text('ana'), findsOneWidget, reason: 'the account name');
      expect(tester.getSize(find.byType(AppDrawer)).width, drawerWidth);
      final pageAfter = tester.getTopLeft(find.byType(AdaptiveScaffold));
      expect(pageAfter.dx - pageBefore.dx, drawerWidth, reason: 'pushed');
      expect(
        tester.getSize(find.byType(AdaptiveScaffold)).width,
        width,
        reason: 'the page keeps its width',
      );
      // A tap on the visible part of the page closes it.
      await tester.tapAt(Offset(width - 10, 450));
      await tester.pumpAndSettle();
      expect(container.read(drawerOpenProvider), isFalse);
      expect(find.text('Hosts'), findsNothing);
      final scaffold = tester.widget<AdaptiveScaffold>(
        find.byType(AdaptiveScaffold),
      );
      expect(scaffold.selectedIndex, AppTab.work.index, reason: 'kept tab');
    });
  }

  testWidgets('Settings opens from the drawer; the switch changes appearance', (
    tester,
  ) async {
    final container = await pumpApp(tester, gateway: _gateway(), width: 375);
    await tester.tap(find.byTooltip('Open the menu'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Switch to dark'));
    await tester.pumpAndSettle();
    final context = tester.element(find.byType(AppDrawer));
    expect(Theme.of(context).brightness, Brightness.dark);
    await tester.tap(find.text('Settings'));
    await tester.pumpAndSettle();
    expect(container.read(drawerOpenProvider), isFalse);
    expect(find.text('Language'), findsOneWidget);
  });

  testWidgets('the drawer keeps the selected tab across a resize', (
    tester,
  ) async {
    await pumpApp(
      tester,
      gateway: _gateway(),
      width: 1300,
      location: '/calendar',
    );
    await tester.tap(find.byTooltip('Open the menu'));
    await tester.pumpAndSettle();
    tester.view.physicalSize = const Size(375, 900);
    await tester.pumpAndSettle();
    expect(find.text('Hosts'), findsOneWidget);
    await tester.tapAt(const Offset(360, 450));
    await tester.pumpAndSettle();
    final scaffold = tester.widget<AdaptiveScaffold>(
      find.byType(AdaptiveScaffold),
    );
    expect(scaffold.selectedIndex, AppTab.calendar.index);
  });
}
