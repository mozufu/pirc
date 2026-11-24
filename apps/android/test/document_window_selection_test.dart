import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_mobile/live/document_navigation_state.dart';
import 'package:pirc_mobile/live/gateway.dart';
import 'package:pirc_render/src/html_document_urls.dart';
import 'package:pirc_render/src/html_form_submission.dart';

class _DocumentGateway extends Gateway {
  @override
  Future<dynamic> call(String method, [Json args = const {}]) async {
    if (method == 'documentPrepareRequest') {
      return {
        'nativeCookieRequestKey':
            'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
      };
    }
    switch (method) {
      case 'boot':
        return {'origin': 'https://gateway.example', 'pairingStamp': 'stamp'};
      case 'resolveDocumentUrl':
        return resolveNativeDocumentUrl(
          args['reference'] as String,
          args['baseUrl'] as String,
        );
      case 'document':
        final url = args['url'] as String;
        return {
          'status': 200,
          'finalUrl': url,
          'finalMethod': args['method'],
          'mimeType': 'text/html',
          'charset': 'utf-8',
          'bytes': Uint8List.fromList(
            utf8.encode('<!doctype html><html><body>document</body></html>'),
          ),
          'headersRelevant': <String, dynamic>{'content-type': 'text/html'},
        };
      default:
        throw StateError('Unexpected gateway call: $method');
    }
  }
}

NativeDocumentWindow _root(NativeDocumentWindows windows) =>
    windows.target('', null, sourceUrl: 'https://gateway.example/');

NativeDocumentWindow _child(
  NativeDocumentWindows windows,
  NativeDocumentWindow opener,
  String name,
) => windows.target(name, opener, sourceUrl: 'https://gateway.example/');

void main() {
  test('selection revision rejects late, closed, and foreign selections', () {
    final windows = NativeDocumentWindows(_DocumentGateway());
    final foreignWindows = NativeDocumentWindows(_DocumentGateway());
    addTearDown(windows.dispose);
    addTearDown(foreignWindows.dispose);

    final root = _root(windows);
    final child = _child(windows, root, 'child');
    final foreign = _root(foreignWindows);

    final beforeSelection = windows.selectionRevision;
    expect(windows.select(root), isTrue);
    final selectedRevision = windows.selectionRevision;
    expect(selectedRevision, beforeSelection + 1);

    // A delayed load may only select against the revision captured when it
    // began. This must not steal focus after the user picked another window.
    expect(
      windows.select(child, expectedSelectionRevision: beforeSelection),
      isFalse,
    );
    expect(windows.active, same(root));

    expect(windows.select(child), isTrue);
    windows.close(child);
    expect(windows.select(child), isFalse);
    expect(windows.select(foreign), isFalse);
    expect(windows.active, same(root));
  });

  test('selecting the same window records a newer user intention', () {
    final windows = NativeDocumentWindows(_DocumentGateway());
    addTearDown(windows.dispose);
    final root = _root(windows);

    expect(windows.select(root), isTrue);
    final firstRevision = windows.selectionRevision;
    expect(
      windows.select(root, expectedSelectionRevision: firstRevision),
      isTrue,
    );
    expect(windows.selectionRevision, firstRevision + 1);

    final secondRevision = windows.selectionRevision;
    expect(
      windows.select(null, expectedSelectionRevision: secondRevision),
      isTrue,
    );
    final appRevision = windows.selectionRevision;
    expect(
      windows.select(null, expectedSelectionRevision: appRevision),
      isTrue,
    );
    expect(windows.selectionRevision, appRevision + 1);
    expect(windows.active, isNull);
  });

  test('named target reuse preserves the window original opener', () {
    final windows = NativeDocumentWindows(_DocumentGateway());
    addTearDown(windows.dispose);
    final root = _root(windows);
    final secondOpener = _child(windows, root, 'second-opener');
    final named = _child(windows, root, 'named-report');

    final reused = windows.target(
      'named-report',
      secondOpener,
      sourceUrl: 'https://gateway.example/other',
    );

    expect(reused, same(named));
    expect(named.returnWindowId, root.id);
  });

  test(
    'closing a background window leaves the current selection intact',
    () async {
      final windows = NativeDocumentWindows(_DocumentGateway());
      addTearDown(windows.dispose);
      final root = _root(windows);
      await root.load(
        const NativeHtmlFormRequest(url: '/start', method: 'GET', target: ''),
        baseUrl: 'https://gateway.example/',
      );
      final retainedEntry = root.current;
      final retainedDocument = retainedEntry!.document;
      final active = _child(windows, root, 'active');
      final background = _child(windows, root, 'background');

      expect(windows.select(active), isTrue);
      final revision = windows.selectionRevision;
      windows.close(background);

      expect(windows.active, same(active));
      expect(windows.selectionRevision, revision);
      expect(windows.windows, isNot(contains(background)));

      expect(windows.select(null), isTrue);
      expect(windows.active, isNull);
      expect(root.current, same(retainedEntry));
      expect(root.current!.document, same(retainedDocument));
      expect(root.history, hasLength(1));
      expect(windows.windows, contains(root));
    },
  );

  test(
    'closing active children follows the opener chain, then returns to App',
    () {
      final windows = NativeDocumentWindows(_DocumentGateway());
      addTearDown(windows.dispose);
      final root = _root(windows);
      final parent = _child(windows, root, 'parent');
      final nested = _child(windows, parent, 'nested');
      // This later-created sibling must not replace the recorded opener target.
      _child(windows, root, 'sibling');

      expect(parent.returnWindowId, root.id);
      expect(nested.returnWindowId, parent.id);
      expect(windows.select(nested), isTrue);
      windows.close(nested);
      expect(windows.active, same(parent));

      // Repeating close is harmless and does not disturb the active opener.
      windows.close(nested);
      expect(windows.active, same(parent));
      windows.close(parent);
      expect(windows.active, same(root));

      windows.close(root);
      expect(windows.active, isNull);
    },
  );
}
