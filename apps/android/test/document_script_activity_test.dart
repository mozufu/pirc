import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_mobile/live/document_navigation.dart';
import 'package:pirc_mobile/live/document_navigation_state.dart';
import 'package:pirc_mobile/live/document_scripts.dart';
import 'package:pirc_mobile/live/gateway.dart';
import 'package:pirc_render/src/html_document_content.dart';
import 'live_test.dart' show theme;

typedef _Activity = ({bool attached, bool visible});

class _RecordingScripts extends NativeDocumentScripts {
  _RecordingScripts() : super(Gateway());

  final activities = <_Activity>[];

  @override
  void setActivity({
    required bool attached,
    required bool visible,
    Object? owner,
    bool preserveFilePicker = false,
  }) {
    activities.add((attached: attached, visible: visible));
  }

  @override
  Future<void> start({
    required String source,
    required String url,
    String? referrerPolicy,
    String? blobCreatorUrl,
    String? storageSessionKey,
    String referrer = '',
    Json? history,
  }) async {}
}

NativeFetchedDocument _document(int id, _RecordingScripts scripts) {
  final bytes = Uint8List.fromList(
    utf8.encode(
      '<html><body><script>document.body.dataset.ready="yes"</script></body></html>',
    ),
  );
  return NativeFetchedDocument(
    id: id,
    url: 'https://example.test/$id',
    status: 200,
    bytes: bytes,
    mimeType: 'text/html',
    content: NativeHtmlDocumentContent.fromBytes(
      bytes,
      mimeType: 'text/html',
      charset: 'utf-8',
    ),
    headers: const {},
  )..scripts = scripts;
}

Widget _view(
  NativeFetchedDocument document, {
  required bool visible,
  NativeDocumentScope? scope,
}) => MaterialApp(
  theme: theme.build(Brightness.light),
  home: TickerMode(
    enabled: visible,
    child: scope == null
        ? NativeFetchedDocumentView(
            key: const ValueKey('document-view'),
            document: document,
            gateway: Gateway(),
            onLink: (_) {},
            onSubmit: (_) {},
          )
        : NativeDocumentScope(
            windows: scope.windows,
            documentUrl: scope.documentUrl,
            window: scope.window,
            sourceIdentity: scope.sourceIdentity,
            child: NativeFetchedDocumentView(
              key: const ValueKey('document-view'),
              document: document,
              gateway: Gateway(),
              onLink: (_) {},
              onSubmit: (_) {},
            ),
          ),
  ),
);

void main() {
  testWidgets(
    'TickerMode controls visibility and document replacement detaches',
    (t) async {
      final firstScripts = _RecordingScripts();
      final first = _document(1, firstScripts);
      final secondScripts = _RecordingScripts();
      final second = _document(2, secondScripts);
      addTearDown(first.dispose);
      addTearDown(second.dispose);

      await t.pumpWidget(_view(first, visible: false));
      expect(firstScripts.activities.last, (attached: true, visible: false));

      await t.pumpWidget(_view(first, visible: true));
      expect(firstScripts.activities.last, (attached: true, visible: true));

      await t.pumpWidget(_view(second, visible: true));
      expect(firstScripts.activities.last, (attached: false, visible: false));
      expect(secondScripts.activities.last, (attached: true, visible: true));

      await t.pumpWidget(const SizedBox.shrink());
      expect(secondScripts.activities.last, (attached: false, visible: false));
    },
  );

  testWidgets('history and window changes freeze scripts while hidden', (
    t,
  ) async {
    final firstScripts = _RecordingScripts();
    final first = _document(1, firstScripts);
    final secondScripts = _RecordingScripts();
    final second = _document(2, secondScripts);
    final windows = NativeDocumentWindows(Gateway());
    addTearDown(windows.dispose);
    final window = windows.target(
      '/first',
      null,
      sourceUrl: 'https://example.test/',
    );
    window.history.add(NativeDocumentHistoryItem('/first', first));
    window.history.add(NativeDocumentHistoryItem('/second', second));
    window.index = 0;
    final scope = NativeDocumentScope(
      windows: windows,
      documentUrl: first.url,
      window: window,
      sourceIdentity: windows.accountIdentity,
      child: const SizedBox.shrink(),
    );

    await t.pumpWidget(_view(first, visible: false, scope: scope));
    expect(firstScripts.activities.last, (attached: true, visible: false));

    // The listener must update activity even though TickerMode stays false.
    window.index = 1;
    window.notifyListeners();
    expect(firstScripts.activities.last, (attached: false, visible: false));

    window.index = 0;
    window.historyPostResubmissionRequired = true;
    window.notifyListeners();
    expect(firstScripts.activities.last, (attached: false, visible: false));

    window.historyPostResubmissionRequired = false;
    window.setClosing(true);
    expect(firstScripts.activities.last, (attached: false, visible: false));

    window.setClosing(false);
    expect(firstScripts.activities.last, (attached: true, visible: false));
    windows.close(window);
    expect(firstScripts.activities.last, (attached: false, visible: false));

    await t.pumpWidget(const SizedBox.shrink());
  });
}
