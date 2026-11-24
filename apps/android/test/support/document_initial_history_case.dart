import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:html/parser.dart' as html;
import 'package:pirc_mobile/live/document_navigation.dart';
import 'package:pirc_mobile/live/document_navigation_state.dart';
import 'package:pirc_render/src/html_form_submission.dart';
import 'document_fragment_scroll_case.dart' show FragmentScrollGateway;
import '../document_navigation_widget_test.dart' show response;

Future<int> checkInitialHistoryCase(
  WidgetTester tester,
  Map row,
  ThemeData theme,
  FragmentScrollGateway gateway,
) async {
  final dpr = (row['dpr'] as num).toDouble(),
      screen = row['screen'] as Map,
      spec = row['spec'] as Map;
  tester.view.devicePixelRatio = dpr;
  tester.view.physicalSize = Size(
    (screen['width'] as num).toDouble() * dpr,
    (screen['height'] as num).toDouble() * dpr,
  );
  tester.view.padding = const FakeViewPadding();
  tester.view.viewPadding = const FakeViewPadding();
  tester.view.viewInsets = const FakeViewPadding();
  final path = '/initial-history?case=${spec['id']}${spec['initialHash']}';
  gateway.calls.clear();
  gateway.responses.add(response(path, row['html'] as String));
  final windows = NativeDocumentWindows(gateway),
      window = windows.target(
        'initial-history',
        null,
        sourceUrl: 'https://gateway.example/',
      );
  await window.load(
    NativeHtmlFormRequest(url: path, method: 'GET', target: ''),
    baseUrl: window.sourceUrl,
  );
  windows.select(window);
  final document = window.currentDocument!,
      initialLength = window.scriptHistoryLength;
  Widget workspace() => MaterialApp(
    theme: theme,
    home: NativeDocumentWorkspace(windows: windows),
  );
  Future<void> settle(String phase) async {
    final expected = row['result'][phase] as Map;
    String? last;
    var stable = 0;
    for (var i = 0; i < 500; i++) {
      await tester.pump(const Duration(milliseconds: 30));
      final scripts = document.scripts;
      final value = jsonEncode([
        scripts?.content?.text,
        scripts?.layoutRevision,
        scripts?.fragmentTargetId,
        window.current?.url,
        window.fragmentRevealRevision,
        document.initialFragmentRevealPending,
        document.scroll.hasClients ? document.scroll.offset : null,
      ]);
      final ready =
          scripts?.ready == true &&
          scripts?.hasPendingPublication == false &&
          scripts!.focusActions.isEmpty &&
          scripts.scrollActions.isEmpty &&
          scripts.navigationActions.isEmpty &&
          !document.initialFragmentRevealPending &&
          window.current?.scrollOffsetBeforeInitialFragment != true &&
          window.current?.url == expected['url'] &&
          document.elementScroll.anchoringSettled &&
          document.scroll.hasClients &&
          !document.scroll.position.isScrollingNotifier.value;
      stable = ready && value == last ? stable + 1 : 0;
      last = value;
      if (stable >= 4) return;
    }
    fail(
      'Initial History did not settle ${spec['id']} $phase url=${window.current?.url} pending=${document.initialFragmentRevealPending} target=${document.scripts?.fragmentTargetId} diagnostics=${document.scripts?.diagnostics}',
    );
  }

  Future<void> compare(String phase) async {
    final expected = row['result'][phase] as Map;
    expect(
      document.scroll.offset,
      closeTo((expected['top'] as num).toDouble(), 1 / 32),
      reason:
          '${spec['id']} $phase actual root index=${window.index} entries=${window.history.map((e) => {'url': e.url, 'offset': e.scrollOffset, 'before': e.scrollOffsetBeforeInitialFragment}).toList()} selected=${document.scripts?.fragmentTargetId} one=${html.parse(document.scripts?.content?.text ?? '').getElementById('one')?.attributes['data-pirc-script-id']} reveals=${document.viewport.completedFragmentReveals} difference=${document.viewport.lastFragmentDifference}',
    );
    expect(window.current!.url, expected['url']);
    expect(window.scriptHistoryLength - initialLength, expected['growth']);
    await tester.tap(find.text('Read', findRichText: true));
    await settle(phase);
    final text = html
            .parse(document.scripts!.content!.text)
            .getElementById('probe')!
            .text,
        actual = jsonDecode(text) as Map;
    for (final key in ['url', 'target', 'state', 'growth', 'events']) {
      expect(actual[key], expected[key], reason: '${spec['id']} $phase $key');
    }
    final items = actual['items'] as List,
        reference = expected['items'] as List;
    expect(items, hasLength(reference.length));
    for (var i = 0; i < items.length; i++) {
      for (final key in ['id', 'color', 'background', 'height']) {
        expect(
          items[i][key],
          reference[i][key],
          reason: '${spec['id']} $phase $i $key',
        );
      }
      for (var axis = 0; axis < 4; axis++) {
        expect(
          items[i]['rect'][axis],
          closeTo((reference[i]['rect'][axis] as num).toDouble(), 1 / 32),
          reason: '${spec['id']} $phase $i rect$axis',
        );
      }
    }
    expect(tester.takeException(), isNull);
  }

  try {
    await tester.pumpWidget(workspace());
    await settle('loaded');
    await compare('loaded');
    if (spec['phase'] == 'inline' && spec['next'] == '#two') {
      final scripts = document.scripts;
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      await tester.pumpWidget(workspace());
      await settle('loaded');
      expect(document.scripts, same(scripts));
      expect(
        document.scroll.offset,
        closeTo((row['result']['loaded']['top'] as num).toDouble(), 1 / 32),
      );
    }
    await tester.tap(find.text('Rewrite', findRichText: true));
    await settle('rewritten');
    await compare('rewritten');
    var states = 2;
    if (row['result']['back'] != null) {
      final backIndex = window.index - 1;
      await window.traverseHistory(backIndex);
      expect(
        window.index,
        backIndex,
        reason: 'actual back traversal ${window.error}',
      );
      await settle('back');
      await compare('back');
      await window.traverseHistory(window.index + 1);
      await settle('forward');
      await compare('forward');
      states += 2;
    }
    expect(gateway.calls, hasLength(1));
    return states;
  } finally {
    await tester.pumpWidget(const SizedBox());
    windows.dispose();
    if (document.scripts != null) await document.scripts!.closed;
    await tester.pumpAndSettle();
    tester.view.reset();
  }
}
