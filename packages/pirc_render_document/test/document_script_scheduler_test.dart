@Tags(['tier3'])
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' show AppLifecycleState;
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_render_document/src/document_scripts.dart';
import 'support/legacy_scripts_platform.dart';

class _FakeClock {
  double milliseconds = 0;

  double read() => milliseconds;

  Future<void> advance(WidgetTester tester, Duration duration) async {
    milliseconds += duration.inMicroseconds / 1000;
    await tester.pump(duration);
    await tester.pump(Duration.zero);
  }
}

class _PumpRecord {
  const _PumpRecord({required this.now, required this.animationFrame});

  final double now;
  final bool animationFrame;
}

class _SchedulerGateway extends LegacyScriptsPlatform {
  _SchedulerGateway({this.timerDelayMs, this.animationFrame = false});

  final calls = <(String, Json)>[];
  int? timerDelayMs;
  bool animationFrame;
  bool failPump = false;
  Completer<void>? dispatchGate;
  Completer<void>? dispatchStarted;
  void Function(_PumpRecord record)? onPump;
  final pumps = <_PumpRecord>[];
  int snapshots = 0;
  double now = 0, lastPumpAt = 0;
  int activeEvaluations = 0;
  int maxConcurrentEvaluations = 0;

  void holdNextDispatch() {
    dispatchGate = Completer<void>();
    dispatchStarted = Completer<void>();
  }

  Json _snapshot() => {
    'html': '<!doctype html><html><body>fixture</body></html>',
    'diagnostics': <Json>[],
    'scheduler': {
      'timerDelayMs': timerDelayMs == null
          ? null
          : (timerDelayMs! - (now - lastPumpAt)).clamp(0, double.infinity),
      'animationFrame': animationFrame,
    },
  };

  Json _arguments(String source) {
    final start = source.indexOf('(') + 1;
    final end = source.lastIndexOf(')');
    return obj(jsonDecode(source.substring(start, end)));
  }

  @override
  Future<dynamic> call(String method, [Json args = const {}]) async {
    calls.add((method, args));
    switch (method) {
      case 'documentScriptCapabilities':
        return {'supported': true};
      case 'documentScriptOpen':
        return {'id': 41};
      case 'documentScriptClose':
        return null;
      case 'documentScriptEvaluate':
        activeEvaluations++;
        if (activeEvaluations > maxConcurrentEvaluations) {
          maxConcurrentEvaluations = activeEvaluations;
        }
        try {
          final source = args['source'] as String;
          if (source == 'runtime') return {'value': ''};
          if (source.startsWith('__pircDocument.') && source.endsWith(')')) {
            final value = _arguments(source)['now'];
            if (value is num) now = value.toDouble();
          }
          if (source.startsWith('__pircDocument.snapshot(')) {
            snapshots++;
            return {'value': jsonEncode(_snapshot())};
          }
          if (source.startsWith('__pircDocument.pump(')) {
            final event = _arguments(source);
            final record = _PumpRecord(
              now: (event['now'] as num).toDouble(),
              animationFrame: event['animationFrame'] == true,
            );
            pumps.add(record);
            lastPumpAt = record.now;
            if (failPump) {
              throw PlatformException(
                code: 'SCRIPT_TIMEOUT',
                message: 'timer callback failed',
              );
            }
            onPump?.call(record);
            return {
              'value': jsonEncode({'defaultPrevented': false}),
            };
          }
          if (source.startsWith('__pircDocument.dispatch(')) {
            final gate = dispatchGate;
            if (gate != null) {
              if (!(dispatchStarted?.isCompleted ?? true)) {
                dispatchStarted!.complete();
              }
              await gate.future;
              dispatchGate = null;
            }
            return {
              'value': jsonEncode({'defaultPrevented': false}),
            };
          }
          if (source.startsWith('__pircDocument.init(') ||
              source.startsWith('__pircDocument.updateVisibility(')) {
            return {
              'value': jsonEncode({'defaultPrevented': false}),
            };
          }
          throw StateError('Unexpected document script expression: $source');
        } finally {
          activeEvaluations--;
        }
      default:
        throw StateError('Unexpected gateway method: $method');
    }
  }
}

Future<NativeDocumentScripts> _start(
  WidgetTester tester,
  _SchedulerGateway gateway,
  _FakeClock clock,
) async {
  final scripts = NativeDocumentScripts(gateway, clockMilliseconds: clock.read);
  await scripts.start(source: '<p>fixture</p>', url: 'https://example.test/');
  expect(scripts.ready, isTrue);
  await tester.pump(Duration.zero);
  return scripts;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('runs the earliest timer once and does not poll without work', (
    tester,
  ) async {
    final clock = _FakeClock();
    final gateway = _SchedulerGateway(timerDelayMs: 30);
    gateway.onPump = (_) {
      gateway.timerDelayMs = null;
    };
    final scripts = await _start(tester, gateway, clock);

    await clock.advance(tester, const Duration(milliseconds: 29));
    expect(gateway.pumps, isEmpty);
    await clock.advance(tester, const Duration(milliseconds: 1));
    expect(gateway.pumps, hasLength(1));
    expect(gateway.pumps.single.now, 30);
    expect(gateway.pumps.single.animationFrame, isFalse);

    await clock.advance(tester, const Duration(seconds: 1));
    expect(gateway.pumps, hasLength(1));
    scripts.dispose();
    await tester.pump(Duration.zero);
  });

  testWidgets('detached documents resume one expired timer without catch-up', (
    tester,
  ) async {
    final clock = _FakeClock();
    final gateway = _SchedulerGateway(timerDelayMs: 10);
    final scripts = await _start(tester, gateway, clock);
    scripts.setActivity(attached: false, visible: true);

    await clock.advance(tester, const Duration(seconds: 5));
    expect(gateway.pumps, isEmpty);

    scripts.setActivity(attached: true, visible: true);
    await tester.pump(Duration.zero);
    expect(gateway.pumps, hasLength(1));
    expect(gateway.pumps.single.now, 5000);
    await tester.pump(Duration.zero);
    expect(gateway.pumps, hasLength(1));

    await clock.advance(tester, const Duration(milliseconds: 9));
    expect(gateway.pumps, hasLength(1));
    await clock.advance(tester, const Duration(milliseconds: 1));
    expect(gateway.pumps, hasLength(2));
    expect(gateway.pumps.last.now, 5010);
    scripts.dispose();
    await tester.pump(Duration.zero);
  });

  testWidgets('app pause suspends timers and dispose prevents later pumps', (
    tester,
  ) async {
    final clock = _FakeClock();
    final gateway = _SchedulerGateway(timerDelayMs: 10);
    final scripts = await _start(tester, gateway, clock);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await clock.advance(tester, const Duration(seconds: 3));
    expect(gateway.pumps, isEmpty);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump(Duration.zero);
    expect(gateway.pumps, hasLength(1));
    expect(gateway.pumps.single.now, 3000);

    scripts.dispose();
    await clock.advance(tester, const Duration(seconds: 1));
    expect(gateway.pumps, hasLength(1));
    expect(
      gateway.calls.where((call) => call.$1 == 'documentScriptClose'),
      hasLength(1),
    );
  });

  testWidgets('hidden documents throttle timers and resume RAF when visible', (
    tester,
  ) async {
    final clock = _FakeClock();
    final gateway = _SchedulerGateway(timerDelayMs: 25, animationFrame: true);
    final scripts = NativeDocumentScripts(
      gateway,
      clockMilliseconds: clock.read,
    );
    scripts.setActivity(attached: true, visible: false);
    await scripts.start(source: '<p>fixture</p>', url: 'https://example.test/');
    expect(scripts.ready, isTrue);
    await tester.pump(Duration.zero);

    await clock.advance(tester, const Duration(milliseconds: 999));
    expect(gateway.pumps, isEmpty);
    await clock.advance(tester, const Duration(milliseconds: 1));
    expect(gateway.pumps, hasLength(1));
    expect(gateway.pumps.single.now, 1000);
    expect(gateway.pumps.single.animationFrame, isFalse);

    scripts.setActivity(attached: true, visible: true);
    await tester.pump(Duration.zero);
    expect(gateway.pumps, hasLength(2));
    expect(gateway.pumps.last.animationFrame, isTrue);
    scripts.dispose();
    await tester.pump(Duration.zero);
  });

  testWidgets('timer waits behind a pending event without overlapping it', (
    tester,
  ) async {
    final clock = _FakeClock();
    final gateway = _SchedulerGateway(timerDelayMs: 5)..holdNextDispatch();
    final scripts = await _start(tester, gateway, clock);

    final event = scripts.dispatch('button', 'click', const []);
    await gateway.dispatchStarted!.future;
    await clock.advance(tester, const Duration(milliseconds: 5));
    expect(gateway.pumps, isEmpty);
    expect(gateway.maxConcurrentEvaluations, 1);

    gateway.dispatchGate!.complete();
    expect(await event, isFalse);
    await tester.pump(Duration.zero);
    expect(gateway.pumps, hasLength(1));
    expect(gateway.maxConcurrentEvaluations, 1);
    scripts.dispose();
    await tester.pump(Duration.zero);
  });

  testWidgets(
    'failed scheduler callback closes the runtime and stops scheduling',
    (tester) async {
      final clock = _FakeClock();
      final gateway = _SchedulerGateway(timerDelayMs: 20)..failPump = true;
      final scripts = await _start(tester, gateway, clock);

      await clock.advance(tester, const Duration(milliseconds: 20));
      expect(scripts.ready, isFalse);
      expect(gateway.pumps, hasLength(1));
      expect(scripts.diagnostics.single, contains('timer callback failed'));
      expect(
        gateway.calls.where((call) => call.$1 == 'documentScriptClose'),
        hasLength(1),
      );
      await clock.advance(tester, const Duration(seconds: 1));
      expect(gateway.pumps, hasLength(1));
      expect(
        gateway.calls.where((call) => call.$1 == 'documentScriptClose'),
        hasLength(1),
      );
      scripts.dispose();
      await tester.pump(Duration.zero);
    },
  );

  testWidgets('slow frame evaluations still yield to overdue timers', (
    tester,
  ) async {
    final clock = _FakeClock();
    final gateway = _SchedulerGateway(timerDelayMs: 0, animationFrame: true);
    gateway.onPump = (_) {
      // Model a native evaluation taking longer than the frame interval.
      clock.milliseconds += 50;
      if (gateway.pumps.length == 4) {
        gateway.timerDelayMs = null;
        gateway.animationFrame = false;
      }
    };
    final scripts = await _start(tester, gateway, clock);
    await tester.pump(Duration.zero);
    expect(gateway.pumps.map((p) => p.animationFrame), [
      true,
      false,
      true,
      false,
    ]);
    scripts.dispose();
    await tester.pump(Duration.zero);
  });

  testWidgets(
    'repeated RAF yields to a due timer, and repeated timers yield to RAF',
    (tester) async {
      final clock = _FakeClock();
      final rafGateway = _SchedulerGateway(
        timerDelayMs: 50,
        animationFrame: true,
      );
      double? timerDue = 50;
      rafGateway.onPump = (record) {
        if (!record.animationFrame &&
            record.now >= (timerDue ?? double.infinity)) {
          timerDue = null;
        }
        rafGateway
          ..timerDelayMs = timerDue == null
              ? null
              : (timerDue! - record.now).ceil()
          ..animationFrame = true;
      };
      final rafScripts = await _start(tester, rafGateway, clock);
      expect(rafGateway.pumps.first.animationFrame, isTrue);
      await clock.advance(tester, const Duration(milliseconds: 17));
      await clock.advance(tester, const Duration(milliseconds: 17));
      await clock.advance(tester, const Duration(milliseconds: 16));
      expect(rafGateway.pumps.any((pump) => !pump.animationFrame), isTrue);
      expect(rafGateway.pumps.where((pump) => pump.animationFrame), isNotEmpty);
      rafScripts.dispose();
      await tester.pump(Duration.zero);

      double timerDueAt = clock.milliseconds + 5;
      final timerGateway = _SchedulerGateway(
        timerDelayMs: 5,
        animationFrame: true,
      );
      timerGateway.onPump = (record) {
        if (!record.animationFrame && record.now >= timerDueAt) {
          timerDueAt = record.now + 5;
        }
        timerGateway
          ..timerDelayMs = (timerDueAt - record.now).ceil()
          ..animationFrame = true;
      };
      final timerScripts = await _start(tester, timerGateway, clock);
      await clock.advance(tester, const Duration(milliseconds: 5));
      await clock.advance(tester, const Duration(milliseconds: 5));
      await clock.advance(tester, const Duration(milliseconds: 5));
      await clock.advance(tester, const Duration(milliseconds: 2));
      expect(
        timerGateway.pumps.where((pump) => !pump.animationFrame),
        isNotEmpty,
      );
      expect(
        timerGateway.pumps.any(
          (pump) => pump.animationFrame && pump.now >= clock.milliseconds - 2,
        ),
        isTrue,
      );
      timerScripts.dispose();
      await tester.pump(Duration.zero);
    },
  );
}
