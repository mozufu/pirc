import 'dart:async';
import 'dart:convert';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:html/parser.dart' as html;
import 'package:pirc_mobile/live/gateway.dart';
import 'package:pirc_mobile/live/document_navigation.dart';
import 'package:pirc_mobile/live/document_navigation_state.dart';
import 'package:pirc_render/src/html_form_submission.dart';
import 'document_fragment_scroll_case.dart' show FragmentScrollGateway;
import '../document_navigation_widget_test.dart' show response;

class LateFragmentGateway extends FragmentScrollGateway {
  Completer<Json>? _resource;
  String source = '';
  bool seen = false, released = false;
  int resources = 0;
  void configure(String value) {
    source = value;
    seen = false;
    released = false;
    resources = 0;
    _resource = null;
    calls.clear();
  }

  Json get resourceResponse => {
    'status': 200,
    'url': 'https://gateway.example/late.js',
    'charset': 'UTF-8',
    'bodyBytes': utf8.encode(source),
  };
  void release() {
    released = true;
    if (_resource case final pending?) {
      if (!pending.isCompleted) pending.complete(resourceResponse);
    }
  }

  @override
  Future<dynamic> call(String method, [Json args = const {}]) {
    if (method == 'documentScriptResource') {
      final request = args['request'] as Map;
      if (request['kind'] != 'script' ||
          request['url'] != 'https://gateway.example/late.js') {
        throw StateError('Unexpected synthetic resource: $request');
      }
      seen = true;
      resources++;
      if (released) return Future.value(resourceResponse);
      _resource = Completer<Json>();
      return _resource!.future;
    }
    if (method == 'documentScriptResourceCancel') {
      release();
      return Future.value(null);
    }
    return super.call(method, args);
  }
}

Future<int> checkLateFragmentCase(
  WidgetTester tester,
  Map row,
  ThemeData theme,
  LateFragmentGateway gateway,
) async {
  final dpr = (row['dpr'] as num).toDouble(),
      screen = row['screen'] as Map,
      mode = row['mode'] as String;
  tester.view.devicePixelRatio = dpr;
  tester.view.physicalSize = Size(
    (screen['width'] as num).toDouble() * dpr,
    (screen['height'] as num).toDouble() * dpr,
  );
  tester.view.padding = const FakeViewPadding();
  tester.view.viewPadding = const FakeViewPadding();
  tester.view.viewInsets = const FakeViewPadding();
  gateway.configure(row['resource'] as String);
  gateway.responses.add(
    response('/late-fragment?mode=$mode#target', row['html'] as String),
  );
  final windows = NativeDocumentWindows(gateway),
      window = windows.target(
        'late',
        null,
        sourceUrl: 'https://gateway.example/',
      );
  await window.load(
    NativeHtmlFormRequest(
      url: '/late-fragment?mode=$mode#target',
      method: 'GET',
      target: '',
    ),
    baseUrl: window.sourceUrl,
  );
  windows.select(window);
  final document = window.currentDocument!;
  Widget workspace() => MaterialApp(
    theme: theme,
    home: NativeDocumentWorkspace(windows: windows),
  );
  const held = {
    'parser',
    'defer',
    'module',
    'async',
    'parser-scroll',
    'parser-remount',
  };
  Future<void> settle({bool initial = false}) async {
    String? last;
    var stable = 0;
    for (var i = 0; i < 500; i++) {
      await tester.pump(const Duration(milliseconds: 30));
      final scripts = document.scripts;
      final value = jsonEncode([
        scripts?.content?.text,
        scripts?.layoutRevision,
        scripts?.fragmentTargetReady,
        scripts?.fragmentTargetId,
        document.initialFragmentRevealPending,
        document.scroll.hasClients ? document.scroll.offset : null,
      ]);
      final ready =
          scripts?.ready == true &&
          scripts?.hasPendingPublication == false &&
          (!held.contains(mode) || gateway.seen) &&
          scripts!.focusActions.isEmpty &&
          scripts.scrollActions.isEmpty &&
          document.elementScroll.anchoringSettled &&
          document.scroll.hasClients &&
          !document.scroll.position.isScrollingNotifier.value &&
          (!initial || !document.initialFragmentRevealPending);
      stable = ready && value == last ? stable + 1 : 0;
      last = value;
      if (stable >= 4) return;
    }
    fail(
      'Late fragment did not settle $mode initial=$initial targetReady=${document.scripts?.fragmentTargetReady} initialPending=${document.initialFragmentRevealPending} diagnostics=${document.scripts?.diagnostics} difference=${document.viewport.lastFragmentDifference}',
    );
  }

  Future<void> compare(String phase) async {
    final expected = row['result'][phase] as Map;
    expect(
      document.scroll.offset,
      closeTo((expected['top'] as num).toDouble(), 1 / 32),
      reason:
          '$mode $phase actual root pending=${document.initialFragmentRevealPending} targetReady=${document.scripts?.fragmentTargetReady} selected=${document.scripts?.fragmentTargetId} reveals=${document.viewport.completedFragmentReveals} diff=${document.viewport.lastFragmentDifference} diagnostics=${document.scripts?.diagnostics}',
    );
    await tester.tap(find.text('Read', findRichText: true));
    await settle(initial: phase != 'before');
    final report = html
        .parse(document.scripts!.content!.text)
        .getElementById('probe')!
        .text;
    final actual = jsonDecode(report) as Map;
    expect(
      actual['ready'],
      expected['ready'],
      reason: '$mode $phase readiness',
    );
    expect(
      actual['target'],
      expected['target'],
      reason: '$mode $phase target identity',
    );
    final items = actual['items'] as List,
        reference = expected['items'] as List;
    expect(items, hasLength(reference.length));
    for (var i = 0; i < items.length; i++) {
      for (final key in ['key', 'color', 'background', 'height']) {
        expect(
          items[i][key],
          reference[i][key],
          reason: '$mode $phase $i $key',
        );
      }
      for (var axis = 0; axis < 4; axis++) {
        expect(
          items[i]['rect'][axis],
          closeTo((reference[i]['rect'][axis] as num).toDouble(), 1 / 32),
          reason: '$mode $phase $i rect$axis',
        );
      }
    }
    expect(tester.takeException(), isNull);
  }

  try {
    await tester.pumpWidget(workspace());
    await settle(initial: !held.contains(mode));
    if (held.contains(mode)) {
      expect(gateway.seen, isTrue);
      expect(gateway.resources, 1);
    }
    if (mode == 'parser-scroll') {
      await tester.sendEventToBinding(
        const PointerScrollEvent(
          position: Offset(120, 300),
          scrollDelta: Offset(0, 240),
          kind: PointerDeviceKind.mouse,
        ),
      );
      await settle();
    }
    await compare('before');
    if (mode == 'parser-remount') {
      final scripts = document.scripts;
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      await tester.pumpWidget(workspace());
      await settle();
      expect(document.scripts, same(scripts));
      expect(document.scroll.offset, 0);
      expect(document.initialFragmentRevealPending, isTrue);
    }
    // Keep a parser request pending beyond the old 128-frame retry limit.
    if (mode == 'parser-remount') {
      for (var i = 0; i < 160; i++) {
        await tester.pump(const Duration(milliseconds: 30));
      }
    }
    gateway.release();
    await settle(initial: true);
    await compare('loaded');
    await tester.tap(find.text('Shift', findRichText: true));
    await settle(initial: true);
    await compare('shifted');
    expect(gateway.calls, hasLength(1));
    expect(gateway.resources, held.contains(mode) ? 1 : 0);
    expect(document.initialFragmentRevealPending, isFalse);
    return 3;
  } finally {
    gateway.release();
    await tester.pumpWidget(const SizedBox());
    windows.dispose();
    if (document.scripts != null) await document.scripts!.closed;
    await tester.pumpAndSettle();
    tester.view.reset();
  }
}
