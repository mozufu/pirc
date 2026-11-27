@Tags(['tier3'])
library;

import 'dart:async';
import 'dart:convert';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_render_document/src/document_scripts.dart';
import 'support/legacy_scripts_platform.dart';

class _VisibilityGateway extends LegacyScriptsPlatform {
  final initial = <bool>[], updates = <bool>[], calls = <String>[];
  Completer<void>? hold, entered, initHold, initEntered;
  @override
  Future<dynamic> call(String method, [Json args = const {}]) async {
    if (method == 'documentScriptCapabilities') return {'supported': true};
    if (method == 'documentScriptOpen') return {'id': 7};
    if (method == 'documentScriptClose') return null;
    if (method != 'documentScriptEvaluate') throw StateError(method);
    final source = args['source'] as String;
    calls.add(source);
    if (source == 'runtime') return {'value': ''};
    final init = source.startsWith('__pircDocument.init('),
        update = source.startsWith('__pircDocument.updateVisibility(');
    if (init || update) {
      final payload = obj(
        jsonDecode(
          source.substring(source.indexOf('(') + 1, source.lastIndexOf(')')),
        ),
      );
      if (init) {
        initial.add(payload['hidden'] == true);
        if (initHold != null) {
          initEntered?.complete();
          await initHold!.future;
        }
      }
      if (update) {
        final gate = hold;
        hold = null;
        if (gate != null) {
          entered?.complete();
          await gate.future;
        }
        updates.add(payload['hidden'] == true);
      }
    }
    return {
      'value': jsonEncode({
        'html': '<html><body>ready</body></html>',
        'diagnostics': [],
      }),
    };
  }
}

Future<void> settle() async {
  for (var i = 0; i < 24; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'initial hidden document starts hidden without fabricating an edge',
    () async {
      final g = _VisibilityGateway();
      final state = NativeDocumentScripts(g);
      state.setActivity(attached: false, visible: false);
      await state.start(source: '', url: 'https://example.test/visibility');
      await settle();
      expect(g.initial, [true]);
      expect(g.updates, isEmpty);
      state.setActivity(attached: true, visible: true);
      await settle();
      expect(g.updates, [false]);
      expect(state.ready, isTrue);
      state.dispose();
      await state.closed;
    },
  );
  test(
    'window activity and app lifecycle publish only effective visibility edges',
    () async {
      final g = _VisibilityGateway();
      final s = NativeDocumentScripts(g);
      await s.start(source: '', url: 'https://example.test/visibility');
      s.setActivity(attached: true, visible: false);
      s.setActivity(attached: true, visible: false);
      s.didChangeAppLifecycleState(AppLifecycleState.paused);
      s.setActivity(attached: true, visible: true);
      await settle();
      expect(g.updates, [true]);
      s.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await settle();
      expect(g.updates, [true, false]);
      s.setActivity(attached: false, visible: true);
      await settle();
      expect(g.updates, [true, false, true]);
      s.setActivity(attached: true, visible: true);
      await settle();
      expect(g.updates, [true, false, true, false]);
      expect(s.ready, isTrue);
      expect(s.diagnostics, isEmpty);
      s.dispose();
      await s.closed;
    },
  );
  test('inactive app remains visible and startup edges are retained', () async {
    final g = _VisibilityGateway();
    final s = NativeDocumentScripts(g);
    g.initHold = Completer<void>();
    g.initEntered = Completer<void>();
    final starting = s.start(
      source: '',
      url: 'https://example.test/visibility',
    );
    await g.initEntered!.future;
    s.setActivity(attached: true, visible: false);
    s.setActivity(attached: true, visible: true);
    g.initHold!.complete();
    await starting;
    await settle();
    expect(g.updates, [true, false]);
    s.didChangeAppLifecycleState(AppLifecycleState.inactive);
    await settle();
    expect(g.updates, [true, false]);
    s.didChangeAppLifecycleState(AppLifecycleState.hidden);
    await settle();
    expect(g.updates, [true, false, true]);
    s.didChangeAppLifecycleState(AppLifecycleState.resumed);
    await settle();
    expect(g.updates, [true, false, true, false]);
    expect(s.ready, isTrue);
    s.dispose();
    await s.closed;
  });
  test(
    'rapid hide/show edges survive an in-flight visibility evaluation',
    () async {
      final g = _VisibilityGateway();
      final s = NativeDocumentScripts(g);
      await s.start(source: '', url: 'https://example.test/visibility');
      final gate = Completer<void>();
      g.hold = gate;
      g.entered = Completer<void>();
      s.setActivity(attached: true, visible: false);
      await g.entered!.future;
      s.setActivity(attached: true, visible: true);
      gate.complete();
      await settle();
      expect(g.updates, [true, false]);
      expect(
        g.calls.where((c) => c.startsWith('__pircDocument.pump(')),
        isEmpty,
      );
      expect(
        g.calls.where(
          (c) => c.startsWith('__pircDocument.continueAnimationFrame('),
        ),
        isEmpty,
      );
      expect(s.ready, isTrue);
      s.dispose();
      await s.closed;
    },
  );
}
