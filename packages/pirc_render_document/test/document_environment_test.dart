@Tags(['tier3'])
library;

import 'dart:async';
import 'dart:convert';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_render_document/src/document_environment.dart';
import 'package:pirc_render_document/src/document_scripts.dart';
import 'support/legacy_scripts_platform.dart';

class _EnvironmentGateway extends LegacyScriptsPlatform {
  final initial = <Json>[];
  final updates = <Json>[];
  Json current = {};
  Completer<void>? hold, entered;
  @override
  Future<dynamic> call(String method, [Json args = const {}]) async {
    switch (method) {
      case 'documentScriptCapabilities':
        return {'supported': true};
      case 'documentScriptOpen':
        return {'id': 7};
      case 'documentScriptClose':
        return null;
      case 'documentScriptEvaluate':
        final expression = args['source'] as String;
        if (expression == 'runtime') return {'value': 'ready'};
        if (expression.startsWith('__pircDocument.init(')) {
          final payload = obj(
            jsonDecode(
              expression.substring(
                '__pircDocument.init('.length,
                expression.length - 1,
              ),
            ),
          );
          current = obj(payload['environment']);
          initial.add(current);
        } else if (expression.startsWith('__pircDocument.updateEnvironment(')) {
          final payload = obj(
            jsonDecode(
              expression.substring(
                '__pircDocument.updateEnvironment('.length,
                expression.length - 1,
              ),
            ),
          );
          final gate = hold;
          hold = null;
          if (gate != null) {
            entered?.complete();
            await gate.future;
          }
          current = obj(payload['environment']);
          updates.add(current);
        }
        return {
          'value': jsonEncode({
            'html':
                '<html><body>${current['width']}:${current['dark']}</body></html>',
            'diagnostics': [],
          }),
        };
    }
    throw StateError(method);
  }
}

Future<void> _settle() async {
  for (var n = 0; n < 16; n++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('initial viewport is captured before scripts execute', () async {
    final g = _EnvironmentGateway();
    final s = NativeDocumentScripts(g);
    const env = NativeDocumentEnvironment(
      width: 768,
      height: 1024,
      devicePixelRatio: 2,
      dark: true,
      reducedMotion: true,
      screenWidth: 1200,
      screenHeight: 1400,
    );
    await s.updateEnvironment(env);
    expect(g.initial, isEmpty);
    expect(g.updates, isEmpty);
    await s.start(source: '<script></script>', url: 'https://example.test/');
    expect(s.ready, true);
    expect(g.initial.single, env.toJson());
    expect(g.updates, isEmpty);
    expect(s.content!.text, contains('768.0:true'));
    s.dispose();
    await s.closed;
  });
  test('viewport changes coalesce while an evaluation is in flight', () async {
    final g = _EnvironmentGateway();
    final s = NativeDocumentScripts(g);
    await s.start(source: '', url: 'https://example.test/');
    final gate = Completer<void>();
    g.hold = gate;
    g.entered = Completer<void>();
    final first = s.updateEnvironment(
      const NativeDocumentEnvironment(width: 400),
    );
    await g.entered!.future;
    final second = s.updateEnvironment(
      const NativeDocumentEnvironment(width: 600),
    );
    final third = s.updateEnvironment(
      const NativeDocumentEnvironment(width: 768, dark: true),
    );
    gate.complete();
    await Future.wait([first, second, third]);
    expect(g.updates.map((e) => e['width']).toList(), [400.0, 768.0]);
    expect(s.content!.text, contains('768.0:true'));
    s.dispose();
    await s.closed;
  });
  test(
    'retained documents and paused apps publish only their latest environment on resume',
    () async {
      final g = _EnvironmentGateway();
      final s = NativeDocumentScripts(g);
      await s.start(source: '', url: 'https://example.test/');
      s.setActivity(attached: false, visible: false);
      await s.updateEnvironment(const NativeDocumentEnvironment(width: 500));
      await s.updateEnvironment(
        const NativeDocumentEnvironment(width: 768, dark: true),
      );
      expect(g.updates, isEmpty);
      s.setActivity(attached: true, visible: true);
      await _settle();
      expect(g.updates.map((e) => e['width']).toList(), [768.0]);
      s.didChangeAppLifecycleState(AppLifecycleState.paused);
      await s.updateEnvironment(
        const NativeDocumentEnvironment(width: 390, height: 700),
      );
      expect(g.updates, hasLength(1));
      s.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await _settle();
      expect(g.updates.last['width'], 390.0);
      expect(g.updates.last['height'], 700.0);
      s.dispose();
      await s.closed;
    },
  );
  test('disposed environments cannot publish a late evaluation', () async {
    final g = _EnvironmentGateway();
    final s = NativeDocumentScripts(g);
    await s.start(source: '', url: 'https://example.test/');
    final before = s.content;
    final gate = Completer<void>();
    g.hold = gate;
    g.entered = Completer<void>();
    final pending = s.updateEnvironment(
      const NativeDocumentEnvironment(width: 768),
    );
    await g.entered!.future;
    s.dispose();
    gate.complete();
    await pending;
    expect(s.content, same(before));
    expect(s.ready, false);
    await s.closed;
  });
  test('invalid display metrics cannot cross the JSON/native boundary', () {
    final g = _EnvironmentGateway();
    final s = NativeDocumentScripts(g);
    expect(
      () => s.updateEnvironment(
        const NativeDocumentEnvironment(width: double.nan),
      ),
      throwsArgumentError,
    );
    expect(
      () => s.updateEnvironment(
        const NativeDocumentEnvironment(devicePixelRatio: 0),
      ),
      throwsArgumentError,
    );
    expect(
      () => s.updateEnvironment(
        const NativeDocumentEnvironment(pointer: 'unknown'),
      ),
      throwsArgumentError,
    );
    expect(g.initial, isEmpty);
    s.dispose();
  });
}
