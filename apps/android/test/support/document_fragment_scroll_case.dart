import 'dart:convert';
import 'package:html/parser.dart' as html;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_mobile/live/document_navigation.dart';
import 'package:pirc_mobile/live/document_navigation_state.dart';
import 'package:pirc_mobile/live/gateway.dart';
import 'package:pirc_render/src/document_element_scroll.dart';
import 'package:pirc_render/src/html_form_submission.dart';
import 'package:pirc_render/src/native_html.dart';
import '../document_navigation_widget_test.dart' show DocumentGateway, response;

Future<Map<String, dynamic>> checkFragmentScrollCase(
  WidgetTester tester,
  Map row,
  ThemeData theme, {
  bool initial = false,
  bool checkFocus = false,
  String documentPath = '/fragment-scroll',
  FragmentScrollGateway? sharedGateway,
}) async {
  final dpr = (row['dpr'] as num).toDouble(),
      screen = Size(
        (row['screen']['width'] as num).toDouble(),
        (row['screen']['height'] as num).toDouble(),
      ),
      viewport = Size(
        (row['viewport']['width'] as num).toDouble(),
        (row['viewport']['height'] as num).toDouble(),
      );
  tester.view.devicePixelRatio = dpr;
  tester.view.physicalSize = screen * dpr;
  tester.view.padding = const FakeViewPadding();
  tester.view.viewPadding = const FakeViewPadding();
  tester.view.viewInsets = const FakeViewPadding();
  final path =
      '$documentPath${initial ? (row['result']['initial']['hash'] ?? '#target') : ''}';
  final gateway = (sharedGateway ?? FragmentScrollGateway())
        ..calls.clear()
        ..responses.add(response(path, row['html'] as String)),
      windows = NativeDocumentWindows(gateway),
      window = windows.target(
        'report',
        null,
        sourceUrl: 'https://gateway.example/',
      );
  await window.load(
    NativeHtmlFormRequest(url: path, method: 'GET', target: ''),
    baseUrl: window.sourceUrl,
  );
  windows.select(window);
  final document = window.currentDocument!;
  Future<void> settle({int? afterReveal}) async {
    String? previous;
    var stable = 0;
    for (var attempt = 0; attempt < 300; attempt++) {
      await tester.pump(const Duration(milliseconds: 30));
      final positions = [
        for (final state in tester.stateList<ScrollableState>(
          find.byType(Scrollable),
        ))
          {
            'pixels': state.position.pixels,
            'active': state.position.isScrollingNotifier.value,
          },
      ];
      final scripts = document.scripts;
      final stamp = jsonEncode([
        positions,
        document.viewport.focusedNativeElementId,
        scripts?.layoutRevision,
        scripts?.content?.text,
      ]);
      final ready =
          scripts?.hasPendingPublication != true &&
          (scripts?.scrollActions.isEmpty ?? true) &&
          (scripts?.focusActions.isEmpty ?? true) &&
          document.elementScroll.anchoringSettled &&
          !window.hasPendingFragmentReveal &&
          positions.every((p) => p['active'] == false) &&
          (afterReveal == null ||
              document.viewport.completedFragmentReveals > afterReveal);
      stable = ready && stamp == previous ? stable + 1 : 0;
      previous = stamp;
      if (stable >= 3) return;
    }
    fail(
      'Document did not stabilize: ${row['mode']} scripted=${row['scripted']} initial=$initial viewport=${row['viewport']} dpr=$dpr ${row['theme']} '
      'completed=${document.viewport.completedFragmentReveals} pending=${window.hasPendingFragmentReveal} difference=${document.viewport.lastFragmentDifference} publication=${document.scripts?.hasPendingPublication} '
      'focus=${document.viewport.focusedNativeElementId} diagnostics=${document.scripts?.diagnostics}',
    );
  }

  try {
    await tester.pumpWidget(
      MaterialApp(
        theme: theme,
        home: NativeDocumentWorkspace(windows: windows),
      ),
    );
    if (row['scripted'] == true) {
      for (var i = 0; i < 200; i++) {
        await tester.pump(const Duration(milliseconds: 30));
        if (document.scripts?.ready == true) break;
      }
      expect(
        document.scripts?.ready,
        isTrue,
        reason: '${document.scripts?.diagnostics}',
      );
    }
    await settle(afterReveal: initial ? 0 : null);
    expect(
      document.scroll.position.viewportDimension,
      viewport.height,
      reason: 'same document viewport as Chromium',
    );
    NativeHtmlDocument rendered() =>
        tester.widget<NativeHtmlDocument>(find.byType(NativeHtmlDocument));
    final ports = tester
        .widgetList<NativeDocumentElementScroll>(
          find.byType(NativeDocumentElementScroll),
        )
        .toList();
    expect(ports, isNotEmpty);
    final controller = ports.first.controller;
    final source = rendered();
    String named(String name) {
      final index = source.fragmentIndex!, selection = index.select(name)!;
      return index.nativeIdFor(selection.anchor!)!;
    }

    final outerId = named('outer'),
        innerId = named('inner'),
        targetId = named('target');
    Map position(String id) {
      final metrics = controller.metricsFor(id)!;
      return {'left': metrics['left'], 'top': metrics['top']};
    }

    Map read() {
      final widget = rendered();
      final packet = widget.layoutController!.capture(
        revision: widget.layoutRevision,
        generation: 1,
        viewport: viewport,
        requestedIds: {targetId},
        scrollOffset: Offset(0, document.scroll.offset),
      );
      expect(packet, isNotNull, reason: 'capture actual laid-out target');
      final box = (packet!['boxes'] as List).single as Map;
      final focused = document.viewport.focusedNativeElementId;
      final active =
          [
            'target',
            'jump',
          ].where((name) => named(name) == focused).firstOrNull ??
          'body';
      final probe = checkFocus && row['scripted'] == true
          ? html
                .parse(document.scripts?.content?.text ?? '')
                .getElementById('focusprobe')
          : null;
      return {
        if (checkFocus) 'active': active,
        if (checkFocus) 'events': probe == null ? null : jsonDecode(probe.text),
        'positions': {
          'root': {'left': 0.0, 'top': document.scroll.offset},
          'outer': position(outerId),
          'inner': position(innerId),
        },
        'rect': box['kind'] == 'none'
            ? [0.0, 0.0, 0.0, 0.0]
            : [
                box['x'],
                (box['y'] as num) - document.scroll.offset,
                box['width'],
                box['height'],
              ],
      };
    }

    void compare(Map actual, Map expected, String phase) {
      if (checkFocus) {
        expect(
          actual['active'],
          expected['active'],
          reason: '${row['mode']} $phase native focus',
        );
        expect(
          actual['events'],
          expected['events'],
          reason: '${row['mode']} $phase trusted focus events',
        );
      }
      for (final owner in ['root', 'outer', 'inner']) {
        for (final axis in ['left', 'top']) {
          expect(
            actual['positions'][owner][axis],
            closeTo(
              (expected['positions'][owner][axis] as num).toDouble(),
              1 / 32,
            ),
            reason:
                '${row['mode']} scripted=${row['scripted']} $phase $owner $axis',
          );
        }
      }
      for (var i = 0; i < 4; i++) {
        expect(
          actual['rect'][i],
          closeTo((expected['rect'][i] as num).toDouble(), 1 / 32),
          reason: '${row['mode']} $phase rect[$i]',
        );
      }
    }

    if (initial) {
      // Initial navigation may run before the renderer has bound its DOM index.
      // The native callback must wait for the matching frame rather than consume it.
      for (
        var i = 0;
        i < 200 && document.viewport.completedFragmentReveals == 0;
        i++
      ) {
        await tester.pump(const Duration(milliseconds: 30));
      }
      await settle();
      expect(document.viewport.completedFragmentReveals, greaterThan(0));
      expect(window.hasPendingFragmentReveal, isFalse);
      expect(document.viewport.lastFragmentDifference, isNull);
      final actual = read();
      compare(actual, row['result']['initial'] as Map, 'initial');
      expect(window.history, hasLength(1));
      expect(gateway.calls, hasLength(1));
      expect(window.current!.url, endsWith('#target'));
      expect(tester.takeException(), isNull);
      return {
        'mode': row['mode'],
        'scripted': row['scripted'],
        'viewport': row['viewport'],
        'dpr': dpr,
        'theme': row['theme'],
        'phase': 'initial',
        'settled': actual,
      };
    }
    document.scroll.jumpTo(240);
    await settle();
    compare(read(), row['result']['before'] as Map, 'before');
    final initialCount = window.history.length,
        before = row['result']['before'] as Map;
    Map last = {};
    for (final phase in ['first', 'repeated']) {
      if (phase == 'repeated') {
        document.scroll.jumpTo(480);
        controller.applyActions([
          for (final id in [outerId, innerId])
            {'id': id, 'op': 'to', 'left': 0, 'top': 0, 'behavior': 'instant'},
        ]);
        await settle();
      }
      final completed = document.viewport.completedFragmentReveals;
      await tester.tap(find.text('Jump', findRichText: true));
      await settle(afterReveal: completed);
      if (row['scripted'] == true) {
        for (
          var i = 0;
          i < 200 && document.viewport.completedFragmentReveals == completed;
          i++
        ) {
          await tester.pump(const Duration(milliseconds: 30));
        }
        await settle();
      }
      expect(
        document.viewport.completedFragmentReveals,
        greaterThan(completed),
      );
      expect(
        document.viewport.lastFragmentDifference,
        isNull,
        reason: 'must use certified native geometry',
      );
      expect(window.hasPendingFragmentReveal, isFalse);
      last = read();
      final expected = row['result'][phase] as Map;
      compare(last, expected, phase);
      expect(window.error, isNull);
      expect(window.currentDocument, same(document));
      expect(window.current!.url, endsWith(expected['hash'] as String));
      expect(
        window.history.length,
        initialCount + (expected['length'] as int) - (before['length'] as int),
      );
      expect(gateway.calls, hasLength(row['result']['requestCount'] as int));
      if (row['scripted'] == true) {
        expect(document.scripts!.diagnostics, isEmpty);
      }
      expect(tester.takeException(), isNull);
    }
    return {
      'mode': row['mode'],
      'scripted': row['scripted'],
      'viewport': row['viewport'],
      'dpr': dpr,
      'theme': row['theme'],
      'settled': last,
    };
  } finally {
    await tester.pumpWidget(const SizedBox());
    final scripts = document.scripts;
    windows.dispose();
    if (scripts != null) await scripts.closed;
    await tester.pumpAndSettle();
    tester.view.reset();
  }
}

// Only document HTTP is synthesized. Script calls use the real Android plugin.
class FragmentScrollGateway extends DocumentGateway {
  @override
  Future<dynamic> call(String method, [Json args = const {}]) {
    if (method.startsWith('documentScript')) {
      return Gateway.channel.invokeMethod(method, args);
    }
    return super.call(method, args);
  }
}
