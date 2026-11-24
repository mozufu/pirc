import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:html/parser.dart' as html;
import 'package:pirc_mobile/live/document_navigation.dart';
import 'package:pirc_mobile/live/document_navigation_state.dart';
import 'package:pirc_render/src/html_form_submission.dart';
import 'package:pirc_render/src/native_html.dart';
import '../document_navigation_widget_test.dart' show DocumentGateway, response;

Future<int> checkDocumentTargetState(
  WidgetTester tester,
  Map row,
  ThemeData theme, {
  DocumentGateway? sharedGateway,
}) async {
  final dpr = (row['dpr'] as num).toDouble(),
      screen = row['screen'] as Map,
      viewport = Size(
        (row['viewport']['width'] as num).toDouble(),
        (row['viewport']['height'] as num).toDouble(),
      );
  tester.view.devicePixelRatio = dpr;
  tester.view.physicalSize = Size(
    (screen['width'] as num).toDouble() * dpr,
    (screen['height'] as num).toDouble() * dpr,
  );
  tester.view.padding = const FakeViewPadding();
  tester.view.viewPadding = const FakeViewPadding();
  tester.view.viewInsets = const FakeViewPadding();
  final gateway = sharedGateway ?? DocumentGateway();
  gateway.calls.clear();
  gateway.responses.add(response('/target-state#one', row['html'] as String));
  final windows = NativeDocumentWindows(gateway),
      window = windows.target(
        'target-state',
        null,
        sourceUrl: 'https://gateway.example/',
      );
  await window.load(
    const NativeHtmlFormRequest(
      url: '/target-state#one',
      method: 'GET',
      target: '',
    ),
    baseUrl: window.sourceUrl,
  );
  windows.select(window);
  final document = window.currentDocument!;
  Future<void> settle() async {
    String? previous;
    var stable = 0;
    for (var i = 0; i < 400; i++) {
      await tester.pump(const Duration(milliseconds: 30));
      final scripts = document.scripts;
      final stamp = jsonEncode([
        document.scroll.hasClients ? document.scroll.offset : null,
        scripts?.layoutRevision,
        scripts?.fragmentTargetId,
        scripts?.content?.text,
        window.current?.url,
        window.fragmentRevealRevision,
      ]);
      final ready =
          !window.loading &&
          !window.hasPendingFragmentReveal &&
          scripts?.hasPendingPublication != true &&
          (scripts == null || scripts.ready) &&
          (scripts?.scrollActions.isEmpty ?? true) &&
          (scripts?.focusActions.isEmpty ?? true) &&
          document.elementScroll.anchoringSettled &&
          document.scroll.hasClients &&
          !document.scroll.position.isScrollingNotifier.value;
      stable = ready && stamp == previous ? stable + 1 : 0;
      previous = stamp;
      if (stable >= 4) return;
    }
    fail(
      'Target did not settle: ${window.current?.url}, pending=${window.hasPendingFragmentReveal}, diagnostics=${document.scripts?.diagnostics}',
    );
  }

  final labels = {
    'one-link': 'One',
    'two-link': 'Two',
    'named-link': 'Named',
    'encoded-link': 'Encoded',
    'hidden-link': 'Hidden',
    'missing-link': 'Missing',
    'top-link': 'Top',
    'clear-link': 'Clear',
    'rename': 'Rename',
    'push': 'Push',
    'replace': 'Replace',
    'remove': 'Remove',
    'reinsert': 'Reinsert',
    'duplicate': 'Duplicate',
  };
  final basic = <List<String>>[
    ['initial'],
    ['link', 'one-link'],
    ['link', 'one-link'],
    ['link', 'two-link'],
    ['link', 'named-link'],
    ['link', 'encoded-link'],
    ['link', 'hidden-link'],
    ['link', 'missing-link'],
    ['link', 'top-link'],
    ['link', 'clear-link'],
  ];
  final steps = row['scripted'] == true
      ? [
          ...basic,
          ['link', 'one-link'],
          ['button', 'rename'],
          ['button', 'push'],
          ['button', 'replace'],
          ['back'],
          ['forward'],
          ['button', 'remove'],
          ['button', 'reinsert'],
          ['link', 'one-link'],
          ['link', 'two-link'],
          ['button', 'duplicate'],
          ['link', 'two-link'],
        ]
      : basic;
  try {
    await tester.pumpWidget(
      MaterialApp(
        theme: theme,
        home: NativeDocumentWorkspace(windows: windows),
      ),
    );
    await settle();
    expect(document.scroll.position.viewportDimension, viewport.height);
    for (var i = 0; i < steps.length; i++) {
      final step = steps[i];
      if (step.first == 'link' || step.first == 'button') {
        await tester.tap(find.text(labels[step[1]]!, findRichText: true));
      }
      if (step.first == 'back') window.back();
      if (step.first == 'forward') window.forward();
      await settle();
      if (row['scripted'] == true && step.length == 2 && step[1] == 'push') {
        final runtime = document.scripts;
        await tester.pumpWidget(const SizedBox());
        await tester.pump(const Duration(milliseconds: 30));
        await tester.pumpWidget(
          MaterialApp(
            theme: theme,
            home: NativeDocumentWorkspace(windows: windows),
          ),
        );
        await settle();
        expect(
          document.scripts,
          same(runtime),
          reason: 'target identity survives workspace remount after pushState',
        );
      }
      final expected = (row['results'] as List)[i] as Map;
      final location = Uri.parse(window.current!.url);
      expect(
        location.hasFragment && location.fragment.isNotEmpty
            ? '#${window.current!.url.split('#').last}'
            : '',
        expected['hash'],
        reason: 'step $i $step URL',
      );
      expect(
        document.scroll.offset,
        closeTo((expected['rootTop'] as num).toDouble(), 1 / 32),
        reason: 'step $i $step root scroll',
      );
      final rendered = tester.widget<NativeHtmlDocument>(
        find.byType(NativeHtmlDocument),
      );
      final parsed = html.parse(
        document.scripts?.content?.text ?? document.content.text,
      );
      if (document.scripts == null) {
        var j = 0;
        for (final e in parsed.querySelectorAll('*')) {
          e.attributes['data-pirc-script-id'] = 'native-static-${j++}';
        }
      }
      final items = parsed.querySelectorAll('.item');
      final packet = rendered.layoutController!.capture(
        revision: rendered.layoutRevision,
        generation: i + 1,
        viewport: viewport,
        scrollOffset: Offset(0, document.scroll.offset),
        requestedIds: items
            .map((e) => e.attributes['data-pirc-script-id']!)
            .toSet(),
      );
      expect(packet, isNotNull);
      final boxes = {
        for (final box in packet!['boxes'] as List) box['id']: box as Map,
      };
      final actual = <List<dynamic>>[];
      for (final item in items) {
        final box = boxes[item.attributes['data-pirc-script-id']]!,
            s = box['computedStyle'] as Map;
        actual.add([
          item.attributes['data-key'],
          s['display'],
          s['color'],
          s['background-color'],
          s['height'],
          s['border-left-width'],
        ]);
      }
      final expectedStyles = (expected['styles'] as List)
          .map((r) => (r as List).take(6).toList())
          .toList();
      expect(
        actual,
        expectedStyles,
        reason: 'step $i $step actual native computed style',
      );
      for (var j = 0; j < items.length; j++) {
        final box = boxes[items[j].attributes['data-pirc-script-id']]!,
            rect = (expected['styles'][j] as List)[6] as List;
        final measured = box['kind'] == 'none'
            ? [0, 0, 0, 0]
            : [
                box['x'],
                (box['y'] as num) - document.scroll.offset,
                box['width'],
                box['height'],
              ];
        for (var axis = 0; axis < 4; axis++) {
          expect(
            measured[axis],
            closeTo((rect[axis] as num).toDouble(), 1 / 32),
            reason:
                'step $i $step ${items[j].attributes['data-key']} rect $axis',
          );
        }
      }
      if (row['scripted'] == true) {
        await tester.tap(find.text('Read', findRichText: true));
        await settle();
        final report = html
            .parse(document.scripts!.content!.text)
            .getElementById('report')!
            .text;
        expect(
          jsonDecode(report),
          expected['script'],
          reason: 'step $i $step actual Sandbox selector and style report',
        );
      }
      expect(tester.takeException(), isNull);
    }
    expect(gateway.calls, hasLength(1));
    return steps.length;
  } finally {
    await tester.pumpWidget(const SizedBox());
    windows.dispose();
    if (document.scripts != null) await document.scripts!.closed;
    await tester.pumpAndSettle();
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
    tester.view.resetPadding();
    tester.view.resetViewPadding();
    tester.view.resetViewInsets();
  }
}
