@Tags(['tier3'])
library;

import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_render_document/src/document_scripts.dart';
import 'support/legacy_scripts_platform.dart';

class _FilePickerGateway extends LegacyScriptsPlatform {
  final calls = <(String, Json)>[];
  final dispatchSources = <String>[];
  final completionSources = <String>[];
  List<Json> initActions = const [];
  List<Json> dispatchActions = const [];
  List<Json> snapshotActions = const [];
  List<Json> pumpActions = const [];
  List<Json> completionActions = const [];
  num? nextDispatchTimerDelay;
  num? activeTimerDelay;

  @override
  Future<dynamic> call(String method, [Json args = const {}]) async {
    calls.add((method, Map<String, dynamic>.of(args)));
    switch (method) {
      case 'documentScriptCapabilities':
        return {'supported': true};
      case 'documentScriptOpen':
        return {'id': 71};
      case 'documentScriptEvaluate':
        final source = '${args['source']}';
        if (source == 'runtime') return {'value': 'loaded'};
        if (source.startsWith('__pircDocument.init')) {
          return {'value': jsonEncode(_response(actions: initActions))};
        }
        if (source.startsWith('__pircDocument.updateVisibility')) {
          return {'value': jsonEncode(_response())};
        }
        if (source.startsWith('__pircDocument.dispatch')) {
          dispatchSources.add(source);
          final actions = dispatchActions;
          dispatchActions = const [];
          final delay = nextDispatchTimerDelay;
          nextDispatchTimerDelay = null;
          activeTimerDelay = delay;
          return {
            'value': jsonEncode(
              _response(
                actions: actions,
                scheduler: {'timerDelayMs': delay, 'animationFrame': false},
                defaultPrevented: false,
                defaultHandled: false,
              ),
            ),
          };
        }
        if (source.startsWith('__pircDocument.filePickerResult')) {
          completionSources.add(source);
          final actions = completionActions;
          completionActions = const [];
          return {'value': jsonEncode(_response(actions: actions))};
        }
        if (source.startsWith('__pircDocument.pump')) {
          final actions = pumpActions;
          pumpActions = const [];
          activeTimerDelay = null;
          return {'value': jsonEncode(_response(actions: actions))};
        }
        if (source.startsWith('__pircDocument.snapshot')) {
          final actions = snapshotActions;
          snapshotActions = const [];
          return {
            'value': jsonEncode(
              _response(
                actions: actions,
                scheduler: {
                  'timerDelayMs': activeTimerDelay,
                  'animationFrame': false,
                },
              ),
            ),
          };
        }
        throw StateError('Unexpected script evaluation: $source');
      case 'documentScriptClose':
        return null;
      default:
        throw StateError('Unexpected gateway call: $method');
    }
  }

  Json _response({
    List<Json> actions = const [],
    Json? scheduler,
    bool? defaultPrevented,
    bool? defaultHandled,
  }) => {
    'html': '<html><body><p>ready</p></body></html>',
    'diagnostics': const [],
    'imageReferences': const [],
    'canvases': const [],
    'resourceRequests': const [],
    'resourceCancellations': const [],
    'formActions': const [],
    'navigationActions': const [],
    'scheduler':
        scheduler ?? const {'timerDelayMs': null, 'animationFrame': false},
    if (actions.isNotEmpty)
      'filePickerActions': actions
          .map((action) => Map<String, dynamic>.of(action))
          .toList(),
    'defaultPrevented': ?defaultPrevented,
    'defaultHandled': ?defaultHandled,
  };
}

class _Clock {
  double now = 0;
}

Json _fileAction(int id, {String controlId = 'pirc-8'}) => {
  'id': id,
  'kind': 'file',
  'controlId': controlId,
  'accept': '.txt,text/plain',
  'multiple': true,
  'resetVersion': '0',
  'actionOrder': id,
};

Future<NativeDocumentScripts> _start(
  _FilePickerGateway gateway, {
  _Clock? clock,
}) async {
  final scripts = NativeDocumentScripts(
    gateway,
    clockMilliseconds: clock == null ? null : () => clock.now,
  );
  await scripts.start(
    source: '<script>test()</script>',
    url: 'https://example.test/document',
  );
  return scripts;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'host click queues one file action and completion is one-shot',
    () async {
      final gateway = _FilePickerGateway();
      final scripts = await _start(gateway);
      addTearDown(() async {
        scripts.dispose();
        await scripts.closed;
      });
      gateway
        ..dispatchActions = [_fileAction(3)]
        ..snapshotActions = [_fileAction(3)];

      expect(await scripts.dispatch('host-button', 'click', const []), isFalse);
      expect(scripts.filePickerActions, hasLength(1));
      final action = scripts.filePickerActions.single;
      expect(action['id'], 3);
      expect(action['sequence'], 1);
      expect(action['controlId'], 'pirc-8');

      // A caller cannot complete an action until the painted queue grants a
      // lease, and an unrelated ID cannot use that lease.
      await scripts.completeFilePicker(3, cancelled: true);
      expect(gateway.completionSources, isEmpty);
      expect(scripts.takeFilePickerActions([action['sequence'] as int]), [
        action,
      ]);
      expect(
        scripts.takeFilePickerActions([action['sequence'] as int]),
        isEmpty,
      );
      await scripts.completeFilePicker(404, cancelled: true);
      expect(gateway.completionSources, isEmpty);

      final selected = <String, dynamic>{
        'name': 'résumé.txt',
        'type': 'text/plain',
        'size': 3,
        'lastModified': 42,
        'bytesBase64': 'YWJj',
      };
      await scripts.completeFilePicker(3, files: [selected]);
      final resultSource = gateway.completionSources.single;
      final payloadStart =
          resultSource.indexOf('filePickerResult(') +
          'filePickerResult('.length;
      final payload =
          jsonDecode(
                resultSource.substring(payloadStart, resultSource.length - 1),
              )
              as Map;
      expect(payload['id'], 3);
      expect(payload['cancelled'], false);
      expect(payload['files'], [selected]);
      await scripts.completeFilePicker(3, cancelled: true);
      expect(gateway.completionSources, hasLength(1));
    },
  );

  test('startup and non-click events cannot authorize a chooser', () async {
    final gateway = _FilePickerGateway()..initActions = [_fileAction(1)];
    final scripts = await _start(gateway);
    addTearDown(() async {
      scripts.dispose();
      await scripts.closed;
    });
    expect(scripts.filePickerActions, isEmpty);

    gateway.dispatchActions = [_fileAction(2)];
    await scripts.dispatch('field', 'input', const []);
    expect(scripts.filePickerActions, isEmpty);

    gateway.dispatchActions = [_fileAction(3)];
    await scripts.dispatch('field', 'change', const []);
    expect(scripts.filePickerActions, isEmpty);
  });

  test('one click consumes permission on its first action only', () async {
    final gateway = _FilePickerGateway();
    final scripts = await _start(gateway);
    addTearDown(() async {
      scripts.dispose();
      await scripts.closed;
    });
    gateway.dispatchActions = [
      _fileAction(4),
      _fileAction(5, controlId: 'pirc-9'),
    ];

    await scripts.dispatch('host-button', 'click', const []);
    expect(scripts.filePickerActions.map((action) => action['id']), [4]);
    final action = scripts.filePickerActions.single;
    final taken = scripts.takeFilePickerActions([action['sequence'] as int]);
    expect(taken.single['id'], 4);
    await scripts.completeFilePicker(4, cancelled: true);

    // The second action was not retained for a later click or chooser.
    expect(scripts.filePickerActions, isEmpty);
    expect(gateway.completionSources, hasLength(1));
  });

  test(
    'queued completion uses transient click permission only inside window',
    () async {
      final gateway = _FilePickerGateway();
      final clock = _Clock();
      final scripts = await _start(gateway, clock: clock);
      addTearDown(() async {
        scripts.dispose();
        await scripts.closed;
      });
      gateway.nextDispatchTimerDelay = 0;
      await scripts.dispatch('host-button', 'click', const []);

      gateway.pumpActions = [_fileAction(6)];
      await Future<void>.delayed(const Duration(milliseconds: 5));
      expect(scripts.filePickerActions.map((action) => action['id']), [6]);

      final action = scripts.filePickerActions.single;
      final taken = scripts.takeFilePickerActions([action['sequence'] as int]);
      await scripts.completeFilePicker(6, cancelled: true);

      // Expire a new, unused permission, rather than merely observing that the
      // previous successful picker already consumed its permission.
      clock.now = 100;
      await scripts.dispatch('host-button', 'click', const []);
      clock.now = 5100;
      gateway.dispatchActions = [_fileAction(7)];
      await scripts.dispatch('host-button', 'blur', const []);
      expect(scripts.filePickerActions, isEmpty);
      expect(taken.single['id'], 6);
    },
  );

  test(
    'hidden or detached document invalidates pending and in-flight actions',
    () async {
      final gateway = _FilePickerGateway();
      final scripts = await _start(gateway);
      addTearDown(() async {
        scripts.dispose();
        await scripts.closed;
      });
      gateway.dispatchActions = [_fileAction(8)];
      await scripts.dispatch('host-button', 'click', const []);
      final queued = scripts.filePickerActions.single;

      scripts.setActivity(attached: true, visible: false);
      expect(scripts.filePickerActions, isEmpty);
      expect(
        scripts.takeFilePickerActions([queued['sequence'] as int]),
        isEmpty,
      );

      scripts.setActivity(attached: true, visible: true);
      gateway.dispatchActions = [_fileAction(9)];
      await scripts.dispatch('host-button', 'click', const []);
      final action = scripts.filePickerActions.single;
      final selected = scripts.takeFilePickerActions([
        action['sequence'] as int,
      ]);
      expect(selected.single['id'], 9);
      scripts.setActivity(attached: false, visible: false);
      await scripts.completeFilePicker(9, cancelled: true);
      expect(gateway.completionSources, isEmpty);
    },
  );

  test(
    'view detach retains only the already-authorized picker lease',
    () async {
      final gateway = _FilePickerGateway();
      final scripts = await _start(gateway);
      addTearDown(() async {
        scripts.dispose();
        await scripts.closed;
      });
      final owner = Object();
      scripts.bindLayout(owner, (revision, generation) async => null);
      gateway.dispatchActions = [_fileAction(60)];
      await scripts.dispatch('host-button', 'click', const []);
      final action = scripts.filePickerActions.single;
      expect(
        scripts.takeFilePickerActions([action['sequence'] as int]),
        hasLength(1),
      );
      scripts.detachView(owner, preserveFilePicker: true);
      expect(scripts.filePickerActions, isEmpty);
      expect(
        scripts.takeFilePickerActions([action['sequence'] as int]),
        isEmpty,
      );
      await scripts.completeFilePicker(
        60,
        files: [
          {
            'name': 'fixture.txt',
            'type': 'text/plain',
            'size': 1,
            'lastModified': 1,
            'bytesBase64': 'YQ==',
          },
        ],
      );
      expect(gateway.completionSources, hasLength(1));
      expect(gateway.completionSources.single, contains('fixture.txt'));
      await scripts.completeFilePicker(60, cancelled: true);
      expect(gateway.completionSources, hasLength(1));
      scripts.bindLayout(owner, (revision, generation) async => null);
      scripts.setActivity(owner: owner, attached: true, visible: true);
      gateway.dispatchActions = [_fileAction(61)];
      await scripts.dispatch('host-button', 'click', const []);
      expect(
        scripts.takeFilePickerActions([
          scripts.filePickerActions.single['sequence'] as int,
        ]),
        hasLength(1),
      );
    },
  );

  test('retired view cannot detach or hide its replacement owner', () async {
    final gateway = _FilePickerGateway();
    final scripts = await _start(gateway);
    addTearDown(() async {
      scripts.dispose();
      await scripts.closed;
    });
    final previous = Object(), next = Object();
    scripts.bindLayout(previous, (revision, generation) async => null);
    scripts.bindLayout(next, (revision, generation) async => null);
    scripts.detachView(previous);
    scripts.setActivity(owner: previous, attached: false, visible: false);
    gateway.dispatchActions = [_fileAction(62)];
    await scripts.dispatch('host-button', 'click', const []);
    expect(
      scripts.takeFilePickerActions([
        scripts.filePickerActions.single['sequence'] as int,
      ]),
      hasLength(1),
    );
    scripts.detachView(next, preserveFilePicker: true);
    scripts.dispose();
    await scripts.completeFilePicker(62, cancelled: true);
    expect(gateway.completionSources, isEmpty);
  });

  test(
    'native picker lifecycle interruption still completes its selection',
    () async {
      final gateway = _FilePickerGateway();
      final scripts = await _start(gateway);
      addTearDown(() async {
        scripts.dispose();
        await scripts.closed;
      });
      gateway.dispatchActions = [_fileAction(10)];
      await scripts.dispatch('host-button', 'click', const []);
      final action = scripts.filePickerActions.single;
      scripts.takeFilePickerActions([action['sequence'] as int]);

      scripts.didChangeAppLifecycleState(AppLifecycleState.inactive);
      await scripts.completeFilePicker(10, cancelled: true);
      expect(gateway.completionSources, hasLength(1));
      expect(gateway.completionSources.single, contains('"cancelled":true'));
    },
  );
  test(
    'invalid completion can report an error under the same picker lease',
    () async {
      final gateway = _FilePickerGateway();
      final scripts = await _start(gateway);
      addTearDown(() async {
        scripts.dispose();
        await scripts.closed;
      });
      gateway.dispatchActions = [_fileAction(40)];
      await scripts.dispatch('host-button', 'click', const []);
      scripts.takeFilePickerActions([
        scripts.filePickerActions.single['sequence'] as int,
      ]);
      await expectLater(
        scripts.completeFilePicker(
          40,
          files: [
            {'name': 'invalid'},
          ],
          cancelled: true,
        ),
        throwsFormatException,
      );
      expect(gateway.completionSources, isEmpty);
      await scripts.completeFilePicker(40, error: 'Too many files');
      expect(gateway.completionSources, hasLength(1));
      expect(gateway.completionSources.single, contains('Too many files'));
      await scripts.completeFilePicker(40, cancelled: true);
      expect(gateway.completionSources, hasLength(1));
    },
  );
}
