import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_mobile/live/document_navigation.dart';
import 'package:pirc_mobile/live/document_navigation_state.dart';
import 'package:pirc_render/src/document_element_scroll.dart';
import 'package:pirc_render/src/native_html.dart' show NativeHtmlLink;
import 'package:pirc_render/src/html_form_submission.dart';
import 'document_navigation_widget_test.dart' show DocumentGateway, response;
import 'live_test.dart' show theme;

final _fixture =
    jsonDecode(
          File(
            'tool/parity/fixtures/document-scroll-retention-chromium153.json',
          ).readAsStringSync(),
        )
        as Map;

Map<String, NativeDocumentElementScroll> _ports(WidgetTester tester) {
  final result = <String, NativeDocumentElementScroll>{};
  for (final match in find.byType(NativeDocumentElementScroll).evaluate()) {
    final widget = match.widget as NativeDocumentElementScroll;
    if (widget.overflowX != NativeDocumentOverflow.auto ||
        widget.overflowY != NativeDocumentOverflow.auto) {
      continue;
    }
    final width = (match.renderObject! as RenderBox).size.width;
    if ((width - 220).abs() < .01) result['outer'] = widget;
    if ((width - 180).abs() < .01) result['inner'] = widget;
  }
  expect(result.keys.toSet(), {'outer', 'inner'});
  return result;
}

void _set(WidgetTester tester, NativeFetchedDocument document, Map state) {
  final ports = _ports(tester);
  for (final entry in (state['scroll'] as Map).entries) {
    final port = ports[entry.key]!;
    port.controller.applyActions([
      {
        'id': port.id,
        'op': 'scrollTo',
        'left': entry.value['left'],
        'top': entry.value['top'],
      },
    ]);
  }
  document.scroll.jumpTo((state['root'] as num).toDouble());
}

void _expect(
  WidgetTester tester,
  NativeFetchedDocument document,
  Map state, {
  bool root = true,
}) {
  if (root) {
    expect(
      document.scroll.offset,
      closeTo((state['root'] as num).toDouble(), .01),
    );
  }
  final ports = _ports(tester);
  for (final entry in (state['scroll'] as Map).entries) {
    final port = ports[entry.key]!,
        metrics = port.controller.metricsFor(port.id)!;
    for (final key in ['left', 'top', 'width', 'height']) {
      expect(
        metrics[key],
        closeTo((entry.value[key] as num).toDouble(), .01),
        reason: '${state['name']} ${entry.key}.$key',
      );
    }
  }
}

void main() {
  for (final row in _fixture['cases'] as List) {
    testWidgets(
      'fetched-document offsets survive real unmount and identity changes ${row['viewport']['width']} dpr${row['dpr']} ${row['theme']}',
      (tester) async {
        final dpr = (row['dpr'] as num).toDouble();
        tester.view.devicePixelRatio = dpr;
        tester.view.physicalSize =
            Size(
              (row['viewport']['width'] as num).toDouble(),
              (row['viewport']['height'] as num).toDouble(),
            ) *
            dpr;
        addTearDown(tester.view.reset);
        final gateway = DocumentGateway()
          ..responses.addAll([
            response('/first', _fixture['html'] as String),
            response('/second', _fixture['html'] as String),
          ]);
        final windows = NativeDocumentWindows(gateway);
        final window = windows.target(
          '',
          null,
          sourceUrl: 'https://gateway.example/',
        );
        final followed = <NativeHtmlLink>[];
        Widget view(NativeFetchedDocument document) => MaterialApp(
          theme: theme.build(
            row['theme'] == 'dark' ? Brightness.dark : Brightness.light,
          ),
          home: Scaffold(
            body: NativeFetchedDocumentView(
              key: const ValueKey('same-view'),
              document: document,
              gateway: gateway,
              onLink: followed.add,
              onSubmit: (_) {},
            ),
          ),
        );
        await window.load(
          const NativeHtmlFormRequest(url: '/first', method: 'GET', target: ''),
          baseUrl: window.sourceUrl,
        );
        final first = window.currentDocument!, states = row['states'] as List;
        try {
          await tester.pumpWidget(view(first));
          await tester.pumpAndSettle();
          _set(tester, first, states[0] as Map);
          await tester.pumpAndSettle();
          _expect(tester, first, states[0] as Map);
          final previous = _ports(tester)['outer']!.controller;
          await tester.pumpWidget(const SizedBox());
          await tester.pumpAndSettle();
          await tester.pumpWidget(view(first));
          await tester.pumpAndSettle();
          _expect(tester, first, states[0] as Map);
          expect(_ports(tester)['outer']!.controller, same(previous));
          await tester.tap(find.text('Tap target', findRichText: true));
          await tester.pumpAndSettle();
          expect(followed, hasLength(1));

          await window.load(
            const NativeHtmlFormRequest(
              url: '/second',
              method: 'GET',
              target: '',
            ),
            baseUrl: window.sourceUrl,
          );
          final second = window.currentDocument!;
          await tester.pumpWidget(view(second));
          await tester.pumpAndSettle();
          _expect(tester, second, states.last as Map, root: false);
          _set(tester, second, states[1] as Map);
          await tester.pumpAndSettle();
          await tester.pumpWidget(view(first));
          await tester.pumpAndSettle();
          _expect(tester, first, states[0] as Map);
          await tester.pumpWidget(view(second));
          await tester.pumpAndSettle();
          _expect(tester, second, states[1] as Map);
          expect(tester.takeException(), isNull);
        } finally {
          await tester.pumpWidget(const SizedBox());
          await tester.pumpAndSettle();
          windows.dispose();
        }
      },
    );
    testWidgets(
      'native history matches browser scroll scope ${row['viewport']['width']} dpr${row['dpr']} ${row['theme']}',
      (tester) async {
        final dpr = (row['dpr'] as num).toDouble();
        tester.view.devicePixelRatio = dpr;
        tester.view.physicalSize =
            Size(
              (row['viewport']['width'] as num).toDouble(),
              (row['viewport']['height'] as num).toDouble(),
            ) *
            dpr;
        addTearDown(tester.view.reset);
        final gateway = DocumentGateway()
          ..responses.addAll([
            response('/first', _fixture['html'] as String),
            response('/other', '<!doctype html><body>Other document'),
            response('/first', _fixture['html'] as String),
          ]);
        final windows = NativeDocumentWindows(gateway);
        final window = windows.target(
          'report',
          null,
          sourceUrl: 'https://gateway.example/',
        );
        await window.load(
          const NativeHtmlFormRequest(url: '/first', method: 'GET', target: ''),
          baseUrl: window.sourceUrl,
        );
        windows.select(window);
        final document = window.currentDocument!,
            states = row['states'] as List;
        Widget workspace() => MaterialApp(
          theme: theme.build(
            row['theme'] == 'dark' ? Brightness.dark : Brightness.light,
          ),
          home: NativeDocumentWorkspace(windows: windows),
        );
        void push(int revision, String url, {String mode = 'auto'}) =>
            window.applyHistoryApiMutation(
              document: document,
              method: 'pushState',
              revision: revision,
              url: url,
              stateGraph: {'version': 1, 'root': null, 'nodes': []},
              scrollRestoration: mode,
            );
        Future<void> check(int index) async {
          await tester.pumpAndSettle();
          _expect(tester, window.currentDocument!, states[index] as Map);
        }

        try {
          await tester.pumpWidget(workspace());
          await tester.pumpAndSettle();
          _set(tester, document, states[0] as Map);
          await check(0);
          push(1, 'https://gateway.example/first#two');
          await tester.pumpAndSettle();
          _set(tester, document, states[1] as Map);
          await check(1);
          window.back();
          await check(2);
          await tester.pumpWidget(const SizedBox());
          await tester.pumpAndSettle();
          await tester.pumpWidget(workspace());
          await check(2);
          window.forward();
          await check(3);
          window.setHistoryScrollRestoration(document, 'manual', 2);
          push(3, 'https://gateway.example/first#three', mode: 'manual');
          await tester.pumpAndSettle();
          _set(tester, document, states[4] as Map);
          await check(4);
          window.back();
          await check(5);
          window.back();
          await check(6);
          await window.load(
            const NativeHtmlFormRequest(
              url: '/other',
              method: 'GET',
              target: '',
            ),
            baseUrl: window.sourceUrl,
          );
          await tester.pumpAndSettle();
          expect(window.history.first.requiresHistoryRefetch, isTrue);
          await window.traverseHistory(0);
          await check(7);
          expect(window.currentDocument, isNot(same(document)));
          expect(gateway.calls, hasLength(3));
          expect(tester.takeException(), isNull);
        } finally {
          await tester.pumpWidget(const SizedBox());
          await tester.pumpAndSettle();
          windows.dispose();
        }
      },
    );
    testWidgets(
      'same-entry workspace remount does not replay its original fragment ${row['viewport']['width']} dpr${row['dpr']} ${row['theme']}',
      (tester) async {
        final dpr = (row['dpr'] as num).toDouble();
        tester.view.devicePixelRatio = dpr;
        tester.view.physicalSize =
            Size(
              (row['viewport']['width'] as num).toDouble(),
              (row['viewport']['height'] as num).toDouble(),
            ) *
            dpr;
        addTearDown(tester.view.reset);
        final gateway = DocumentGateway()
          ..responses.add(response('/first#outer', _fixture['html'] as String));
        final windows = NativeDocumentWindows(gateway),
            windowSource = 'https://gateway.example/';
        final window = windows.target('report', null, sourceUrl: windowSource);
        await window.load(
          const NativeHtmlFormRequest(
            url: '/first#outer',
            method: 'GET',
            target: '',
          ),
          baseUrl: windowSource,
        );
        windows.select(window);
        final document = window.currentDocument!;
        Widget workspace() => MaterialApp(
          theme: theme.build(
            row['theme'] == 'dark' ? Brightness.dark : Brightness.light,
          ),
          home: NativeDocumentWorkspace(windows: windows),
        );
        try {
          await tester.pumpWidget(workspace());
          await tester.pumpAndSettle();
          _set(tester, document, row['retainedEntry'] as Map);
          await tester.pumpAndSettle();
          await tester.pumpWidget(const SizedBox());
          await tester.pumpAndSettle();
          await tester.pumpWidget(workspace());
          await tester.pumpAndSettle();
          _expect(tester, document, row['retainedEntry'] as Map);
          await tester.pumpWidget(const SizedBox());
          await tester.pumpAndSettle();
          await window.load(
            const NativeHtmlFormRequest(
              url: '/first#top',
              method: 'GET',
              target: '',
            ),
            baseUrl: windowSource,
            fragmentAllowed: true,
          );
          expect(window.error, isNull);
          expect(window.current!.url, 'https://gateway.example/first#top');
          expect(window.currentDocument, same(document));
          await tester.pumpWidget(workspace());
          await tester.pumpAndSettle();
          _expect(tester, document, row['movedEntry'] as Map);
          expect(gateway.calls, hasLength(1));
          expect(tester.takeException(), isNull);
        } finally {
          await tester.pumpWidget(const SizedBox());
          await tester.pumpAndSettle();
          windows.dispose();
        }
      },
    );
  }
}
