import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_mobile/live/document_navigation_state.dart';
import 'package:pirc_mobile/live/document_window_manager.dart';
import 'package:pirc_mobile/live/gateway.dart';
import 'package:pirc_mobile/live/web_controls.dart';
import 'package:pirc_render/src/html_document_content.dart';

import 'live_test.dart' show theme;

NativeDocumentWindow _addWindow(
  NativeDocumentWindows windows, {
  required String name,
  required String url,
  required String title,
}) {
  final window = windows.target(
    name,
    null,
    sourceUrl: 'https://gateway.example/start',
  );
  final bytes = Uint8List.fromList(
    utf8.encode('<!doctype html><title>$title</title><body>content</body>'),
  );
  final content = NativeHtmlDocumentContent.fromBytes(
    bytes,
    mimeType: 'text/html',
  );
  final document = NativeFetchedDocument(
    id: 0,
    url: url,
    status: 200,
    bytes: bytes,
    mimeType: 'text/html',
    content: content,
    headers: const {},
  );
  window.history.add(NativeDocumentHistoryItem(url, document));
  window.index = 0;
  window.notifyListeners();
  return window;
}

Widget _page(
  NativeDocumentWindows windows, {
  Future<void> Function(NativeDocumentWindow?)? onSelect,
  Future<void> Function(NativeDocumentWindow)? onClose,
  Future<void> Function(NativeDocumentWindow)? onBack,
  Future<void> Function(NativeDocumentWindow)? onForward,
}) => MaterialApp(
  theme: theme.build(Brightness.light),
  home: NativeDocumentWindowManagerPage(
    windows: windows,
    onSelect: onSelect ?? (_) async {},
    onClose: onClose ?? (_) async {},
    onBack: onBack ?? (_) async {},
    onForward: onForward ?? (_) async {},
  ),
);

void main() {
  testWidgets('selects the main App source and a specific document window', (
    tester,
  ) async {
    final windows = NativeDocumentWindows(
      Gateway(),
      appDocumentUrl: () => 'https://gateway.example/index.html?session=one',
    );
    addTearDown(windows.dispose);
    final first = _addWindow(
      windows,
      name: '',
      url: 'https://gateway.example/first',
      title: 'First document',
    );
    final second = _addWindow(
      windows,
      name: 'reports',
      url: 'https://gateway.example/reports',
      title: 'Reports',
    );
    windows.select(first);
    final selected = <NativeDocumentWindow?>[];

    await tester.pumpWidget(
      _page(
        windows,
        onSelect: (window) async {
          selected.add(window);
          if (window == null) {
            windows.activeId = null;
            windows.notifyListeners();
          } else {
            windows.select(window);
          }
        },
      ),
    );
    expect(find.text("Main app"), findsOneWidget);
    expect(find.text('First document'), findsOneWidget);
    expect(find.text("Name: reports"), findsOneWidget);

    await tester.tap(find.byKey(const Key('document-window-source-select')));
    await tester.pump();
    expect(selected, [null]);
    expect(windows.active, isNull);

    await tester.tap(find.byKey(Key('document-window-select-${second.id}')));
    await tester.pump();
    expect(selected, [null, second]);
    expect(windows.active, same(second));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'close targets one row and disables duplicate actions while busy',
    (tester) async {
      final windows = NativeDocumentWindows(Gateway());
      addTearDown(windows.dispose);
      final first = _addWindow(
        windows,
        name: 'first',
        url: 'https://gateway.example/first',
        title: 'First',
      );
      final second = _addWindow(
        windows,
        name: 'second',
        url: 'https://gateway.example/second',
        title: 'Second',
      );
      final closeGate = Completer<void>();
      final closed = <int>[];

      await tester.pumpWidget(
        _page(
          windows,
          onClose: (window) async {
            closed.add(window.id);
            await closeGate.future;
            windows.close(window);
          },
        ),
      );

      final closeFirst = find.byKey(Key('document-window-close-${first.id}'));
      await tester.tap(closeFirst);
      await tester.pump();
      expect(closed, [first.id]);
      expect(tester.widget<WebIconButton>(closeFirst).onPressed, isNull);

      closeGate.complete();
      await tester.pump();
      await tester.pump();
      expect(closed, [first.id]);
      expect(windows.windows, [second]);
      expect(first.disposed, isTrue);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'account identity change invalidates a pending close completion',
    (tester) async {
      final owner = LiveController(Gateway())
        ..origin = 'https://gateway.example'
        ..clientId = 'phone'
        ..pairingStamp = 'before';
      final windows = NativeDocumentWindows(Gateway(), owner: owner);
      addTearDown(() {
        windows.dispose();
        owner.dispose();
      });
      final window = _addWindow(
        windows,
        name: 'pending',
        url: 'https://gateway.example/pending',
        title: 'Pending close',
      );
      final closeGate = Completer<void>();
      final callbackPassedGate = Completer<void>();

      await tester.pumpWidget(
        _page(
          windows,
          onClose: (target) async {
            expect(target, same(window));
            await closeGate.future;
            callbackPassedGate.complete();
            throw StateError('stale close completion');
          },
        ),
      );
      await tester.tap(find.byKey(Key('document-window-close-${window.id}')));
      await tester.pump();

      owner.pairingStamp = 'after';
      owner.notifyListeners();
      await tester.pump();
      expect(windows.windows, isEmpty);
      expect(window.disposed, isTrue);

      closeGate.complete();
      await callbackPassedGate.future;
      await tester.pump();
      expect(find.textContaining('stale close completion'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  for (final width in [390.0, 650.0, 651.0, 768.0, 860.0, 861.0, 1024.0]) {
    for (final brightness in [Brightness.light, Brightness.dark]) {
      for (final scale in [1.0, 2.0]) {
        testWidgets(
          'fits width $width, ${brightness.name} theme, text scale $scale',
          (tester) async {
            tester.view.devicePixelRatio = 1;
            tester.view.physicalSize = Size(width, 900);
            addTearDown(tester.view.reset);
            final windows = NativeDocumentWindows(Gateway());
            addTearDown(windows.dispose);
            _addWindow(
              windows,
              name: 'a long named target for narrow screens',
              url:
                  'https://gateway.example/a/very/long/path/with/a/query?and=more&values=here',
              title:
                  'A long page title that must wrap without overflowing its row',
            );
            windows.target(
              'another named window',
              null,
              sourceUrl: 'https://gateway.example/start',
            );

            await tester.pumpWidget(
              MaterialApp(
                theme: theme.build(brightness),
                builder: (context, child) => MediaQuery(
                  data: MediaQuery.of(
                    context,
                  ).copyWith(textScaler: TextScaler.linear(scale)),
                  child: child!,
                ),
                home: NativeDocumentWindowManagerPage(
                  windows: windows,
                  onSelect: (_) async {},
                  onClose: (_) async {},
                  onBack: (_) async {},
                  onForward: (_) async {},
                ),
              ),
            );
            await tester.pumpAndSettle();
            expect(tester.takeException(), isNull);
          },
        );
      }
    }
  }
}
