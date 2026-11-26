import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_app/src/connection/connection.dart';
import 'package:pirc_app/src/connection/connection_screens.dart';
import 'package:pirc_app/src/connection/hints.dart';
import 'package:pirc_app/src/platform/media.dart';
import 'package:pirc_app/src/work/panels/browser_panel.dart';
import 'package:pirc_app/src/work/panels/panel_container.dart';
import 'package:pirc_app/src/work/panels/terminal_panel.dart';
import 'package:pirc_client/pirc_client.dart';

import 'support/harness.dart';
import 'support/session_fixture.dart';

const _base = '/api/sessions/s2';

/// Panel replies with content.
final _full = <String, Object?>{
  'files': {
    'path': '',
    'entries': [
      {'name': 'lib', 'kind': 'dir'},
      {'name': 'README.md', 'kind': 'file', 'size': 12},
    ],
    'truncated': false,
  },
  'git/status': {
    'repo': true,
    'root': '',
    'branch': 'main',
    'upstream': 'origin/main',
    'ahead': 1,
    'behind': 0,
    'files': [
      {'path': 'a.dart', 'index': 'M', 'worktree': ' '},
      {'path': 'new.txt', 'index': '?', 'worktree': '?'},
    ],
    'truncated': false,
  },
  'terminals': {
    'terminals': [
      {
        'id': 'ab12cd34',
        'sessionId': 's2',
        'title': 'zsh',
        'cwd': '/w',
        'cols': 80,
        'rows': 24,
        'createdAt': 1,
        'exitCode': null,
        'exited': false,
      },
    ],
  },
  'panel/state': {
    'agentRunning': true,
    'backgroundTasks': [
      {'id': 't1', 'command': 'npm run dev', 'status': 'running'},
    ],
    'team': {'agents': <Object?>[]},
  },
  'panel/context': {
    'agentRunning': true,
    'source': 'live',
    'snapshot': {
      'model': {'provider': 'anthropic', 'id': 'opus', 'contextWindow': 200000},
      'sections': [
        {
          'id': 's',
          'title': 'System prompt',
          'text': 'You are pi.',
          'estimatedTokens': 5,
        },
      ],
      'tools': <Object?>[],
      'usage': {
        'estimatedInput': 1200,
        'buckets': {'system': 5},
      },
    },
  },
  'checkpoints': {
    'version': 1,
    'enabled': true,
    'captures': [
      {
        'id': 'cap1',
        'coverage': 'full',
        'pinned': false,
        'created': 1,
        'operations': [
          {'id': 'op1', 'path': 'a.dart', 'tool': 'edit', 'state': 'observed'},
        ],
      },
    ],
    'jobs': <Object?>[],
    'more': false,
  },
};

/// Empty replies.
final _empty = <String, Object?>{
  'files': {'path': '', 'entries': <Object?>[], 'truncated': false},
  'git/status': {'repo': true, 'files': <Object?>[], 'ahead': 0, 'behind': 0},
  'terminals': {'terminals': <Object?>[]},
  'panel/state': {
    'backgroundTasks': <Object?>[],
    'team': {'agents': <Object?>[]},
  },
  'panel/context': null,
  'checkpoints': {
    'enabled': true,
    'captures': <Object?>[],
    'jobs': <Object?>[],
  },
};

/// The route each panel reads first, and its empty text.
const _panels = {
  PanelSection.files: ('files', 'This folder is empty.'),
  PanelSection.git: ('git/status', 'No changes.'),
  PanelSection.terminal: ('terminals', 'No terminals.'),
  PanelSection.tasks: ('panel/state', 'No background tasks or teammates.'),
  PanelSection.context: (
    'panel/context',
    'Send a message first to see its context.',
  ),
  PanelSection.checkpoints: ('checkpoints', 'No checkpoints yet.'),
};

Future<FixtureSession> _open(
  WidgetTester tester,
  PanelSection section, {
  Map<String, Object?>? replies,
  Map<String, Object?>? lease,
  double width = 1300,
  List overrides = const [],
  FutureOr<ApiResponse?> Function(ApiRequest request)? route,
  bool settle = true,
  Map<String, Object> socketErrors = const {},
  MediaPlayers? media,
  double height = 900,
}) async {
  final s = FixtureSession('joined-mid-stream.json')..lease = lease;
  final gateway = s.install();
  gateway.connectErrors.addAll(socketErrors);
  s.gateway = gateway;
  if (route != null) gateway.routes.add(route);
  gateway.routes.add((request) {
    if (!request.path.startsWith('$_base/')) return null;
    final rest = request.path.substring(_base.length + 1);
    final data = (replies ?? _full);
    if (!data.containsKey(rest)) return null;
    final value = data[rest];
    if (rest == 'panel/context' && value == null) {
      return apiError(404, 'no_context', 'Send a message first');
    }
    return reply(200, value);
  });
  await pumpApp(
    tester,
    gateway: gateway,
    width: width,
    height: height,
    location: '/work?open=s2&side=panel:${section.name}',
    overrides: [
      terminalPollProvider.overrideWithValue(const Duration(milliseconds: 10)),
      ...overrides,
    ],
    settle: settle,
    media: media,
  );
  if (!settle) {
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }
  return s;
}

void main() {
  group('the container', () {
    for (final (width, beside) in [
      (375.0, false),
      (700.0, false),
      (1000.0, false),
      (1300.0, true),
    ]) {
      appTest(
        '$width wide: ${beside ? 'beside' : 'in place of'} the conversation',
        (tester) async {
          await _open(tester, PanelSection.files, width: width);
          final panels = tester.getRect(find.byType(PanelContainer));
          expect(panels.width, beside ? 400 : greaterThan(width * 0.6));
          expect(find.text('README.md'), findsOneWidget);
          // Tabs switch the section; "More" holds Context and Checkpoints.
          await tester.tap(find.text('Git'));
          await tester.pumpAndSettle();
          expect(find.text('main'), findsOneWidget);
          await tester.tap(find.byTooltip('More'));
          await tester.pumpAndSettle();
          await tester.tap(find.text('Context').last);
          await tester.pumpAndSettle();
          expect(find.text('System prompt'), findsOneWidget);
          await tester.tap(find.byTooltip('Close'));
          await tester.pumpAndSettle();
          expect(find.byType(PanelContainer), findsNothing);
        },
      );
    }
  });

  group('states', () {
    for (final MapEntry(key: section, value: (rest, emptyText))
        in _panels.entries) {
      appTest('${section.name}: loading', (tester) async {
        final never = Completer<ApiResponse?>();
        await _open(
          tester,
          section,
          route: (r) => r.path == '$_base/$rest' ? never.future : null,
          settle: false,
        );
        expect(
          find.descendant(
            of: find.byType(PanelContainer),
            matching: find.byType(CircularProgressIndicator),
          ),
          findsOneWidget,
        );
        never.complete(reply(200, _full[rest]));
        await tester.pumpAndSettle();
      });

      appTest('${section.name}: empty', (tester) async {
        await _open(tester, section, replies: _empty);
        expect(find.text(emptyText), findsOneWidget);
      });

      appTest('${section.name}: failed, then retried', (tester) async {
        var fail = true;
        final s = await _open(
          tester,
          section,
          route: (r) => r.path == '$_base/$rest' && fail
              ? apiError(500, 'internal', 'boom')
              : null,
        );
        expect(find.text('This panel could not be loaded.'), findsOneWidget);
        fail = false;
        await tester.tap(find.text('Try again'));
        await tester.pumpAndSettle();
        expect(find.text('This panel could not be loaded.'), findsNothing);
        expect(s.gateway!.sent('GET', '$_base/$rest').length, greaterThan(1));
      });

      appTest('${section.name}: offline', (tester) async {
        final never = Completer<ApiResponse?>();
        await _open(
          tester,
          section,
          route: (r) => r.path == '$_base/$rest' ? never.future : null,
          settle: false,
          overrides: [
            appConnectionStateProvider.overrideWithValue(
              AppConnectionState.offline,
            ),
          ],
        );
        expect(
          find.text('Offline. This panel loads when the Gateway is reachable.'),
          findsOneWidget,
        );
        never.complete(reply(200, _full[rest]));
        await tester.pumpAndSettle();
      });
    }

    appTest('terminal: read-only without the lease', (tester) async {
      await _open(
        tester,
        PanelSection.terminal,
        lease: {'clientId': 'other-phone', 'generation': 3},
      );
      expect(
        find.text('Read only: another device controls this work.'),
        findsOneWidget,
      );
      final create = tester.widget<FilledButton>(
        find.ancestor(
          of: find.text('New terminal'),
          matching: find.byType(FilledButton),
        ),
      );
      expect(create.onPressed, isNull);
    });

    appTest('tasks: read-only without the lease; Stop is disabled', (
      tester,
    ) async {
      await _open(
        tester,
        PanelSection.tasks,
        lease: {'clientId': 'other-phone', 'generation': 3},
        route: (r) => r.path == '$_base/panel/background/t1'
            ? reply(200, {
                'task': {'id': 't1', 'status': 'running'},
                'output': 'listening on :5173',
              })
            : null,
      );
      await tester.tap(find.text('npm run dev'));
      await tester.pumpAndSettle();
      expect(find.text('listening on :5173'), findsOneWidget);
      expect(
        find.text('Read only: another device controls this work.'),
        findsOneWidget,
      );
      final stop = tester.widget<TextButton>(
        find.ancestor(
          of: find.text('Stop'),
          matching: find.byWidgetPredicate((w) => w is TextButton),
        ),
      );
      expect(stop.onPressed, isNull);
    });

    appTest('checkpoints: read-only without the lease; Recover is disabled', (
      tester,
    ) async {
      final s = await _open(
        tester,
        PanelSection.checkpoints,
        lease: {'clientId': 'other-phone', 'generation': 3},
        route: (r) => r.path == '$_base/checkpoints/cap1/preview'
            ? reply(200, {
                'version': 1,
                'revision': 'rev1',
                'copiedBytes': 10,
                'exclusions': <String, Object?>{},
              })
            : null,
      );
      await tester.tap(find.textContaining('1 files'));
      await tester.pumpAndSettle();
      expect(
        find.text('Read only: another device controls this work.'),
        findsOneWidget,
      );
      // A preview only reads, so it stays open to every device.
      await tester.tap(find.text('Preview').last);
      await tester.pumpAndSettle();
      final recover = tester.widget<FilledButton>(
        find.ancestor(
          of: find.text('Recover'),
          matching: find.byType(FilledButton),
        ),
      );
      expect(recover.onPressed, isNull);
      expect(
        s.gateway!.sent('POST', '$_base/checkpoints/cap1/recoveries'),
        isEmpty,
      );
    });

    appTest('browser: before any state, nothing is open', (tester) async {
      await _open(tester, PanelSection.browser);
      // The socket opened but sent no state yet.
      expect(find.text('No browser is open for this work.'), findsOneWidget);
    });

    appTest('browser: a closed stream says the browser is unavailable', (
      tester,
    ) async {
      final s = await _open(tester, PanelSection.browser);
      s.gateway!.socket('$_base/browser/stream')!.serverClose(1011);
      await tester.pumpAndSettle();
      expect(
        find.text('The browser is not available on this host.'),
        findsOneWidget,
      );
    });

    appTest('browser: a refused stream shows the reason', (tester) async {
      await _open(
        tester,
        PanelSection.browser,
        socketErrors: {
          '$_base/browser/stream': const ApiError(
            503,
            'node_offline',
            'Host is offline',
          ),
        },
      );
      expect(find.text('Host is offline'), findsOneWidget);
    });

    appTest('browser: a 401 on the stream opens pairing', (tester) async {
      await _open(
        tester,
        PanelSection.browser,
        socketErrors: {
          '$_base/browser/stream': const EventSocketRefused(
            401,
            'Event socket refused (401)',
          ),
        },
      );
      expect(find.byType(PairingScreen), findsOneWidget);
    });

    appTest('terminal: a 426 on the stream opens the update screen', (
      tester,
    ) async {
      final terminal = (_full['terminals']! as Map)['terminals'][0];
      await _open(
        tester,
        PanelSection.terminal,
        route: (r) => r.method == 'POST' && r.path == '$_base/terminals'
            ? reply(200, {'terminal': terminal})
            : null,
        socketErrors: {
          '$_base/terminals/ab12cd34/stream': const EventSocketRefused(
            426,
            'Event socket refused (426)',
          ),
        },
      );
      await tester.tap(find.text('New terminal'));
      await tester.pumpAndSettle();
      expect(find.byType(UpgradeScreen), findsOneWidget);
    });

    appTest('browser: open, waiting for the first frame', (tester) async {
      final s = await _open(tester, PanelSection.browser);
      s.gateway!.socket('$_base/browser/stream')!.push({
        'type': 'state',
        'state': {'active': true, 'url': 'https://example.test/'},
      });
      await tester.pumpAndSettle();
      expect(find.text('Waiting for the page…'), findsOneWidget);
    });

    appTest('browser: an error frame is shown', (tester) async {
      final s = await _open(tester, PanelSection.browser);
      final stream = s.gateway!.socket('$_base/browser/stream')!;
      stream
        ..push({
          'type': 'state',
          'state': {'active': true, 'url': 'https://example.test/'},
        })
        ..push({'type': 'error', 'message': 'Navigation failed'});
      await tester.pumpAndSettle();
      expect(find.text('Navigation failed'), findsOneWidget);
    });

    appTest('browser: read-only without the lease', (tester) async {
      final s = await _open(
        tester,
        PanelSection.browser,
        lease: {'clientId': 'other-phone', 'generation': 3},
      );
      s.gateway!.socket('$_base/browser/stream')!.push({
        'type': 'state',
        'state': {
          'active': true,
          'url': 'https://example.test/',
          'mode': 'agent',
        },
      });
      await tester.pumpAndSettle();
      expect(
        find.text('Read only: another device controls this work.'),
        findsOneWidget,
      );
      final take = tester.widget<FilledButton>(
        find.byKey(const Key('browser-control')),
      );
      expect(take.onPressed, isNull);
      expect(find.text('Take control'), findsOneWidget);
    });
  });

  appTest('panel_changed for a section reads that panel again', (tester) async {
    final s = await _open(tester, PanelSection.context);
    final before = s.gateway!.sent('GET', '$_base/panel/context').length;
    s.gateway!.socket('/api/events')!.push({
      'sessionId': 's2',
      'epoch': 1,
      'sequence': 5,
      'type': 'pi_event',
      'timestamp': 1,
      'data': {
        'type': 'panel_changed',
        'sections': ['context'],
      },
    });
    await tester.pumpAndSettle();
    expect(s.gateway!.sent('GET', '$_base/panel/context').length, before + 1);
  });

  for (final (section, route) in [
    (PanelSection.files, 'files'),
    (PanelSection.git, 'git/status'),
    (PanelSection.terminal, 'terminals'),
  ]) {
    appTest('${section.name} reads again on any panel_changed and run end', (
      tester,
    ) async {
      final s = await _open(tester, section);
      int count() => s.gateway!.sent('GET', '$_base/$route').length;
      final before = count();
      final events = s.gateway!.socket('/api/events')!;
      events.push({
        'sessionId': 's2',
        'epoch': 1,
        'sequence': 5,
        'type': 'pi_event',
        'timestamp': 1,
        'data': {
          'type': 'panel_changed',
          'sections': ['background'],
        },
      });
      await tester.pumpAndSettle();
      expect(count(), before + 1);
      events.push({
        'sessionId': 's2',
        'epoch': 1,
        'sequence': 6,
        'type': 'pi_event',
        'timestamp': 2,
        'data': {'type': 'agent_settled'},
      });
      await tester.pumpAndSettle();
      expect(count(), greaterThanOrEqualTo(before + 2));
    });
  }

  appTest('files: a folder opens, then a file', (tester) async {
    final s = await _open(
      tester,
      PanelSection.files,
      route: (r) {
        if (r.path == '$_base/files' && r.query['path'] == 'lib') {
          return reply(200, {
            'path': 'lib',
            'entries': [
              {'name': 'main.dart', 'kind': 'file', 'size': 20},
            ],
          });
        }
        if (r.path == '$_base/files/content') {
          return reply(200, {
            'path': r.query['path'],
            'size': 20,
            'binary': false,
            'truncated': false,
            'content': 'void main() {}',
          });
        }
        return null;
      },
    );
    await tester.tap(find.text('lib'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('main.dart'));
    await tester.pumpAndSettle();
    expect(find.text('void main() {}'), findsOneWidget);
    expect(s.gateway!.sent('GET', '$_base/files/content').single.query, {
      'path': 'lib/main.dart',
    });
  });

  appTest('git: a staged file asks for the staged diff', (tester) async {
    final s = await _open(
      tester,
      PanelSection.git,
      route: (r) => r.path == '$_base/git/diff'
          ? reply(200, {'diff': '+added\n-removed', 'truncated': false})
          : null,
    );
    await tester.tap(find.text('a.dart'));
    await tester.pumpAndSettle();
    expect(find.text('+added'), findsOneWidget);
    expect(s.gateway!.sent('GET', '$_base/git/diff').single.query, {
      'path': 'a.dart',
      'staged': '1',
    });
  });

  appTest('terminal: a new one waits while prepared, then streams', (
    tester,
  ) async {
    var reads = 0;
    final s = await _open(
      tester,
      PanelSection.terminal,
      route: (r) {
        final terminal = (_full['terminals']! as Map)['terminals'][0];
        if (r.method == 'POST' && r.path == '$_base/terminals') {
          return reply(202, {
            'workRequest': {'state': 'preparing'},
            'terminal': null,
          });
        }
        if (r.method == 'GET' &&
            r.path == '$_base/terminals' &&
            r.query.containsKey('workRequestId')) {
          reads++;
          return reply(200, {
            'workRequest': {'state': reads < 2 ? 'preparing' : 'running'},
            'terminal': reads < 2 ? null : terminal,
          });
        }
        return null;
      },
    );
    await tester.tap(find.text('New terminal'));
    await tester.pumpAndSettle();
    final create =
        s.gateway!.sent('POST', '$_base/terminals').single.json! as Map;
    expect(create['executionPath'], 'isolated_work');
    expect(create['clientId'], isNotEmpty);
    expect(find.byType(TerminalPage), findsOneWidget);
    final stream = s.gateway!.socket('$_base/terminals/ab12cd34/stream')!;
    stream.push({'type': 'ready', 'terminal': {}, 'replay': r'$ '});
    await tester.pump();
    await tester.tap(find.text('Esc'));
    await tester.pump();
    final input = stream.sent.whereType<Map>().firstWhere(
      (m) => m['type'] == 'input',
    );
    expect(input['data'], '\x1b');
    expect(input['clientId'], isNotEmpty);
    expect(input['generation'], 1);
    stream.push({'type': 'exit', 'exitCode': 0});
    await tester.pumpAndSettle();
    expect(find.text('Exited (0)'), findsOneWidget);
  });

  appTest('browser: frames show; Take control sends takeover with the lease', (
    tester,
  ) async {
    final s = await _open(tester, PanelSection.browser);
    final stream = s.gateway!.socket('$_base/browser/stream')!;
    stream.push({
      'type': 'state',
      'state': {
        'active': true,
        'url': 'https://example.test/',
        'mode': 'agent',
      },
    });
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('browser-control')));
    await tester.pump();
    final takeover = stream.sent.whereType<Map>().single;
    expect(takeover['type'], 'takeover');
    expect(takeover['generation'], 1);
  });

  appTest('browser: a saved recording loads from the recording route', (
    tester,
  ) async {
    final s = await _open(
      tester,
      PanelSection.browser,
      route: (r) => r.path == '$_base/browser/recording'
          ? (r.query['path'] == '.pirc/recordings/a.webm'
                ? ApiResponse(200, List.filled(3 * 1024 * 1024, 7))
                : apiError(404, 'not_found'))
          : null,
    );
    final stream = s.gateway!.socket('$_base/browser/stream')!;
    stream
      ..push({
        'type': 'state',
        'state': {'active': true, 'url': 'https://example.test/'},
      })
      ..push({
        'type': 'log',
        'entries': [
          {'action': 'Saved recording .pirc/recordings/a.webm'},
          {'action': 'Saved recording ../secret.webm'},
          {'action': 'Clicked'},
        ],
      })
      ..push({
        'type': 'log_entry',
        'entry': {'action': 'Saved recording .pirc/recordings/b.webm'},
      });
    await tester.pumpAndSettle();
    expect(find.text('Recordings'), findsOneWidget);
    expect(find.text('a.webm'), findsOneWidget);
    expect(find.text('b.webm'), findsOneWidget);
    expect(find.text('secret.webm'), findsNothing);
    await tester.tap(
      find.descendant(
        of: find.byKey(const ValueKey('recording:.pirc/recordings/a.webm')),
        matching: find.text('Load'),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('3.0 MB'), findsOneWidget);
    expect(find.byTooltip('Open in another app'), findsOneWidget);
    await tester.tap(
      find.descendant(
        of: find.byKey(const ValueKey('recording:.pirc/recordings/b.webm')),
        matching: find.text('Load'),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('The recording could not be loaded.'), findsOneWidget);
  });

  group('browser: recordings play in the app on Android', () {
    final recording = List.filled(3 * 1024 * 1024, 7);

    /// Taps [finder] after scrolling it into the recordings area.
    Future<void> tap(WidgetTester tester, Finder finder) async {
      await tester.ensureVisible(finder);
      await tester.pump();
      await tester.tap(finder);
    }

    /// Opens the browser panel with one loaded recording, `a.webm`.
    Future<void> load(
      WidgetTester tester,
      FakeMediaPlayers media, {
      double height = 900,
    }) async {
      final s = await _open(
        tester,
        PanelSection.browser,
        media: media,
        height: height,
        route: (r) => r.path == '$_base/browser/recording'
            ? ApiResponse(200, recording)
            : null,
      );
      s.gateway!.socket('$_base/browser/stream')!
        ..push({
          'type': 'state',
          'state': {'active': true, 'url': 'https://example.test/'},
        })
        ..push({
          'type': 'log',
          'entries': [
            {'action': 'Saved recording .pirc/recordings/a.webm'},
          ],
        });
      await tester.pumpAndSettle();
      await tester.tap(find.text('Load'));
      await tester.pumpAndSettle();
      // Android keeps the share sheet next to the in-app player.
      expect(find.byTooltip('Open in another app'), findsOneWidget);
      await tester.tap(find.byTooltip('Play in the app'));
      await tester.pumpAndSettle();
    }

    appTest('play, seek, speed and save', (tester) async {
      final media = FakeMediaPlayers();
      await load(tester, media);

      final id = media.players.keys.single;
      expect(media.opened[id], recording);
      expect(tester.widget<Texture>(find.byType(Texture)).textureId, id);
      expect(find.text('0:00 / 0:10'), findsOneWidget);

      await tap(tester, find.byTooltip('Play'));
      await tester.pump();
      expect(find.byTooltip('Pause'), findsOneWidget);

      await tester.ensureVisible(find.byKey(const Key('recording-seek')));
      await tester.pump();
      await tester.drag(
        find.byKey(const Key('recording-seek')),
        const Offset(400, 0),
      );
      await tester.pump();
      expect(media.actions.last, startsWith('seek '));
      expect(media.players[id]!.position, greaterThan(Duration.zero));

      await tap(tester, find.byKey(const Key('recording-speed')));
      await tester.pumpAndSettle();
      expect(find.text('0.25×'), findsOneWidget);
      await tester.tap(find.text('1.5×').last);
      await tester.pumpAndSettle();
      expect(media.actions.last, 'rate 1.5');
      expect(find.text('1.5×'), findsOneWidget);

      await tap(tester, find.byTooltip('Save to Downloads'));
      await tester.pump();
      expect(find.text('Saved to Downloads as a.webm.'), findsOneWidget);
      expect(media.saved['a.webm'], recording);

      await tap(tester, find.byTooltip('Close the player'));
      await tester.pump();
      expect(find.byType(Texture), findsNothing);
      expect(media.players, isEmpty);
    });

    appTest('the seek bar reads out the position', (tester) async {
      final media = FakeMediaPlayers();
      await load(tester, media);
      final semantics = tester.ensureSemantics();
      await tester.ensureVisible(find.byKey(const Key('recording-seek')));
      await tester.pump();
      final values = <String>[];
      void walk(SemanticsNode node) {
        values.add(node.value);
        node.visitChildren((child) {
          walk(child);
          return true;
        });
      }

      walk(tester.getSemantics(find.byKey(const Key('recording-seek'))));
      expect(values, contains('0:00 of 0:10'));
      semantics.dispose();
    });

    appTest('a player that goes away stops being read', (tester) async {
      final media = FakeMediaPlayers();
      await load(tester, media);
      await tap(tester, find.byTooltip('Play'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(media.statusReads, greaterThan(0));
      // A decoder error, a seek timeout or unpairing closed it on Android.
      await media.closeAll();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump();
      expect(find.text('The recording could not be played.'), findsOneWidget);
      final reads = media.statusReads;
      await tester.pump(const Duration(seconds: 2));
      expect(media.statusReads, reads);
    });

    appTest('a short screen scrolls the recordings', (tester) async {
      final media = FakeMediaPlayers();
      await load(tester, media, height: 480);
      expect(tester.takeException(), isNull);
      expect(find.byType(Texture), findsOneWidget);
      final area = find.ancestor(
        of: find.byType(Texture),
        matching: find.byType(SingleChildScrollView),
      );
      final panel = find.ancestor(
        of: area.first,
        matching: find.byType(BrowserPanel),
      );
      expect(
        tester.getSize(area.first).height,
        lessThanOrEqualTo(tester.getSize(panel).height / 3 + 0.5),
      );
    });

    appTest('a WebM file without a length has no seek bar', (tester) async {
      final media = FakeMediaPlayers(duration: Duration.zero);
      await load(tester, media);
      expect(find.byType(Texture), findsOneWidget);
      expect(find.byKey(const Key('recording-seek')), findsNothing);
      expect(find.text('0:00'), findsOneWidget);
      await tap(tester, find.byTooltip('Play'));
      await tester.pump();
      expect(find.byTooltip('Pause'), findsOneWidget);
    });

    appTest('a file Android cannot play says so', (tester) async {
      final media = FakeMediaPlayers()..failNextOpen = true;
      await load(tester, media);
      expect(find.byType(Texture), findsNothing);
      expect(find.text('The recording could not be played.'), findsOneWidget);
    });

    appTest('play in the background is refused quietly', (tester) async {
      final media = FakeMediaPlayers()..background = true;
      await load(tester, media);
      await tap(tester, find.byTooltip('Play'));
      await tester.pump();
      expect(find.byTooltip('Play'), findsOneWidget);
      expect(find.text('The recording could not be played.'), findsNothing);
    });

    appTest('unpairing closes the players', (tester) async {
      final media = FakeMediaPlayers();
      await load(tester, media);
      final container = ProviderScope.containerOf(
        tester.element(find.byType(BrowserPanel)),
      );
      await container.read(connectionProvider.notifier).unpair();
      await tester.pumpAndSettle();
      expect(media.closedAll, 1);
      expect(media.players, isEmpty);
    });
  });

  appTest('tasks: statuses are words, not codes', (tester) async {
    await _open(
      tester,
      PanelSection.tasks,
      replies: {
        ..._full,
        'panel/state': {
          'backgroundTasks': [
            {'id': 't1', 'command': 'npm run dev', 'status': 'running'},
            {'id': 't2', 'command': 'npm test', 'status': 'timed_out'},
            {'id': 't3', 'command': 'make', 'status': 'some_new_state'},
          ],
          'team': {
            'agents': [
              {'id': 'a1', 'name': 'Reviewer', 'status': 'in_progress'},
            ],
          },
        },
      },
    );
    expect(find.text('Running'), findsWidgets);
    expect(find.text('Timed out'), findsOneWidget);
    expect(find.text('some_new_state'), findsOneWidget);
    expect(find.text('In progress'), findsOneWidget);
    expect(find.text('timed_out'), findsNothing);
  });

  appTest('checkpoints: preview, recover with the lease, continue', (
    tester,
  ) async {
    final s = await _open(
      tester,
      PanelSection.checkpoints,
      route: (r) => switch (r.path) {
        '$_base/checkpoints/cap1/preview' => reply(200, {
          'version': 1,
          'revision': 'rev1',
          'copiedBytes': 10,
          'exclusions': <String, Object?>{},
          'coverage': 'full',
        }),
        '$_base/checkpoints/cap1/recoveries' => reply(200, {
          'id': 'job1',
          'state': 'ready',
          'revision': 2,
          'manifest': {'paths': <Object?>[]},
        }),
        '$_base/checkpoints/cap1/recoveries/job1/continue' => reply(200, {
          'session': {'id': 's-recovered', 'workspaceId': 'n:w', 'name': 'r'},
          'workspaceId': 'n:w',
        }),
        _ => null,
      },
    );
    await tester.tap(find.textContaining('1 files'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Preview').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Recover'));
    await tester.pumpAndSettle();
    final recover =
        s.gateway!
                .sent('POST', '$_base/checkpoints/cap1/recoveries')
                .single
                .json!
            as Map;
    expect(recover['previewRevision'], 'rev1');
    expect(recover['operations'], ['op1']);
    expect(recover['generation'], 1);
    // States are words, not codes.
    expect(find.text('Recovery: Ready'), findsOneWidget);
    expect(find.text('edit · Recorded'), findsOneWidget);
    await tester.tap(find.text('Continue in a new conversation'));
    await tester.pumpAndSettle();
    final cont =
        s.gateway!
                .sent(
                  'POST',
                  '$_base/checkpoints/cap1/recoveries/job1/continue',
                )
                .single
                .json!
            as Map;
    expect(cont['revision'], 2);
  });

  test('every panel route is under the session', () {
    expect(appHintKinds, contains('sessions'));
  });
}
