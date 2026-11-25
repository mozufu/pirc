import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_app/src/format.dart';
import 'package:pirc_app/src/work/project_screen.dart';

import 'support/harness.dart';
import 'support/work_fixtures.dart';

Future<FakeGateway> _project(
  WidgetTester tester, {
  bool rules = true,
  double width = 1300,
}) async {
  final fixture = WorkFixture();
  final g = fixture.install();
  g.json['GET /api/workspaces'] = (_) => {
    'workspaces': [
      {
        'id': 'laptop:pirc',
        'hostId': 'h',
        'displayName': 'pirc mobile',
        'mode': 'default',
        'kind': 'directory',
      },
    ],
  };
  g.json['GET /api/modes'] = (_) => {
    'modes': [
      {'id': 'default', 'label': 'Coding', 'project_config': rules},
    ],
  };
  g.json['GET /api/workspaces/laptop%3Apirc/capabilities'] = (_) => {
    'capabilities': {
      'version': 1,
      'memory_search': true,
      'remote_recall': true,
      'schedules': true,
      'web_search': false,
    },
  };
  g.json['PATCH /api/workspaces/laptop%3Apirc/capabilities'] = (r) => {
    'capabilities': (r.json! as Map)['capabilities'],
  };
  g.json['GET /api/workspaces/laptop%3Apirc/project-config'] = (_) => {
    'project': {
      'hooks': {
        'beforeTool': [
          {'command': 'npm run lint', 'timeoutMs': 1000},
        ],
      },
      'env': {'CI': '1'},
      'allowedPaths': ['/tmp/cache'],
      'hash': 'a' * 64,
      'trustedHash': null,
      'trusted': false,
      'empty': false,
    },
  };
  g.json['POST /api/workspaces/laptop%3Apirc/project-trust'] = (_) => {
    'project': {'hash': 'a' * 64, 'trusted': true, 'empty': false},
  };
  await pumpApp(
    tester,
    gateway: g,
    location: '/work',
    width: width,
    overrides: [clockProvider.overrideWithValue(() => fixedNow)],
  );
  // Default G: the group header opens the project.
  await tester.tap(find.text('pirc mobile').first);
  await tester.pumpAndSettle();
  return g;
}

void main() {
  appTest('a group header opens the project with its conversations', (
    tester,
  ) async {
    await _project(tester);
    expect(find.byType(ProjectScreen), findsOneWidget);
    expect(find.text('Conversations'), findsOneWidget);
    final page = find.byType(ProjectScreen);
    expect(
      find.descendant(
        of: page,
        matching: find.textContaining(
          'Fix the login keyboard',
          findRichText: true,
        ),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: page,
        matching: find.textContaining(
          'Weekend trip budget',
          findRichText: true,
        ),
      ),
      findsNothing,
      reason: 'another project',
    );
  });

  appTest('Back from a conversation opened on the project page returns there', (
    tester,
  ) async {
    await _project(tester, width: 375);
    await tester.tap(
      find.descendant(
        of: find.byType(ProjectScreen),
        matching: find.textContaining(
          'Fix the login keyboard',
          findRichText: true,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(ProjectScreen), findsNothing);
    await tester.tap(find.byTooltip('Back'));
    await tester.pumpAndSettle();
    expect(find.byType(ProjectScreen), findsOneWidget);
    // And Back from the project goes to the Work list.
    await tester.tap(find.byTooltip('Back'));
    await tester.pumpAndSettle();
    expect(find.byType(ProjectScreen), findsNothing);
  });

  appTest('resources: a capability switch patches only that key', (
    tester,
  ) async {
    final g = await _project(tester);
    await tester.tap(find.text('Resources'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Search the web'));
    await tester.pumpAndSettle();
    expect(
      g.sent('PATCH', '/api/workspaces/laptop%3Apirc/capabilities').single.json,
      {
        'capabilities': {'web_search': true},
      },
    );
  });

  appTest('rules: the config shows its hooks and trust sends its hash', (
    tester,
  ) async {
    final g = await _project(tester);
    await tester.tap(find.text('Rules'));
    await tester.pumpAndSettle();
    expect(find.text('npm run lint'), findsOneWidget);
    expect(find.text('/tmp/cache'), findsOneWidget);
    expect(find.textContaining('Not trusted'), findsOneWidget);
    await tester.tap(find.text('Trust'));
    await tester.pumpAndSettle();
    expect(
      g.sent('POST', '/api/workspaces/laptop%3Apirc/project-trust').single.json,
      {'trusted': true, 'hash': 'a' * 64},
    );
  });

  appTest('a mode without a project config has no Rules tab', (tester) async {
    await _project(tester, rules: false);
    expect(find.text('Rules'), findsNothing);
  });

  appTest('removing a project asks first; an offline host asks to retry', (
    tester,
  ) async {
    final g = await _project(tester);
    var offline = true;
    g.json['DELETE /api/workspaces/laptop%3Apirc'] = (_) => offline
        ? apiError(503, 'node_offline', 'Connect the device')
        : reply(204);
    await tester.tap(find.byTooltip('More actions').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Remove project…'));
    await tester.pumpAndSettle();
    expect(find.text('Remove pirc mobile?'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Remove'));
    await tester.pumpAndSettle();
    expect(find.textContaining('The host is offline'), findsOneWidget);
    offline = false;
    await tester.tap(find.text('Try again'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Remove'));
    await tester.pumpAndSettle();
    expect(g.sent('DELETE', '/api/workspaces/laptop%3Apirc'), hasLength(2));
    expect(find.byType(ProjectScreen), findsNothing);
  });

  appTest('a new project is a folder on a connected host', (tester) async {
    final g = FakeGateway();
    g.json['GET /api/sessions'] = (_) => {'sessions': <Object?>[]};
    g.json['GET /api/nodes'] = (_) => {
      'nodes': [
        {'id': 'laptop', 'workspaces': <Object?>[]},
      ],
    };
    g.json['POST /api/workspaces'] = (_) => reply(201, {
      'workspace': {
        'id': 'laptop:app',
        'hostId': 'h',
        'displayName': 'app',
        'mode': 'directory',
      },
    });
    await pumpApp(tester, gateway: g, location: '/work');
    await tester.tap(find.byTooltip('New project'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('project-host')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('laptop').last);
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('project-name')), 'app');
    await tester.enterText(find.byKey(const Key('project-path')), '~/code/app');
    await tester.pump();
    await tester.tap(find.byKey(const Key('project-create')));
    await tester.pumpAndSettle();
    expect(g.sent('POST', '/api/workspaces').single.json, {
      'nodeId': 'laptop',
      'displayName': 'app',
      'path': '~/code/app',
    });
    expect(find.byType(ProjectScreen), findsOneWidget);
  });
}
