import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show debugPrintSynchronously;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:html/parser.dart' as html;
import 'package:integration_test/integration_test.dart';
import 'package:pirc_mobile/live/document_navigation.dart';
import 'package:pirc_mobile/live/document_navigation_state.dart';
import 'package:pirc_mobile/live/gateway.dart';
import 'package:pirc_render/src/html_buttons.dart';
import 'package:pirc_render/src/html_form_submission.dart';
import 'package:pirc_mobile/theme.dart';

import 'document_anchor_activation_expected.dart';
import 'document_anchor_activation_fixture.dart';

class CapturingAnchorActivationGateway extends Gateway {
  CapturingAnchorActivationGateway({this.useSystemSave = false});

  bool useSystemSave;
  final List<Json> saves = [];
  final List<dynamic> saveResults = [];

  @override
  Future<dynamic> call(String method, [Json args = const {}]) async {
    if (method != 'saveDocument') return super.call(method, args);

    final rawBytes = args['bytes'];
    final bytes = rawBytes is Uint8List
        ? Uint8List.fromList(rawBytes)
        : Uint8List.fromList((rawBytes as List).cast<int>());
    final payload = Map<String, dynamic>.from(args)..['bytes'] = bytes;
    saves.add(payload);

    if (useSystemSave) {
      debugPrintSynchronously(
        'NATIVE_ANCHOR_ACTIVATION_SAF_PENDING name=${payload['name']}',
      );
      final nativeResult = await super.call(method, args);
      saveResults.add(nativeResult);
      return nativeResult;
    }

    final mockedResult = {
      'name': payload['name'],
      'bytesWritten': bytes.length,
    };
    saveResults.add(mockedResult);
    return mockedResult;
  }
}

const useSystemSave = bool.fromEnvironment(
  'PIRC_SYSTEM_SAVE',
  defaultValue: false,
);

Map<String, dynamic>? _readJsonElement(
  NativeFetchedDocument? document,
  String selector,
) {
  final source = document?.scripts?.content?.text;
  if (source == null) return null;
  final text = html.parse(source).querySelector(selector)?.text.trim();
  if (text == null ||
      text.isEmpty ||
      text == 'READY' ||
      text == 'WAITING' ||
      text == 'LOADING') {
    return null;
  }
  try {
    final value = jsonDecode(text);
    return value is Map ? Map<String, dynamic>.from(value) : null;
  } catch (_) {
    return null;
  }
}

String _canonicalText(String value, String origin) {
  final withOrigin = value.replaceAll(origin, '<origin>');
  return withOrigin.replaceAllMapped(
    RegExp(r'blob:<origin>/[^#\s]+'),
    (_) => 'blob:<origin>/<blob>',
  );
}

dynamic _canonicalJson(dynamic value, String origin) {
  if (value is String) return _canonicalText(value, origin);
  if (value is List) {
    return value.map((item) => _canonicalJson(item, origin)).toList();
  }
  if (value is Map) {
    return {
      for (final entry in value.entries)
        '${entry.key}': _canonicalJson(entry.value, origin),
    };
  }
  return value;
}

String _visibleRichText(WidgetTester tester) => tester
    .widgetList<RichText>(find.byType(RichText))
    .map((widget) => widget.text.toPlainText())
    .join('\n');

Future<void> _until(
  WidgetTester tester,
  bool Function() condition,
  String label, {
  String Function()? details,
  int maxPumps = 400,
}) async {
  for (var index = 0; index < maxPumps && !condition(); index++) {
    await tester.pump(const Duration(milliseconds: 25));
  }
  expect(
    condition(),
    isTrue,
    reason: '$label${details == null ? '' : ': ${details()}'}',
  );
  await tester.pump();
  expect(tester.takeException(), isNull, reason: label);
}

Future<void> _waitForSaveResult(
  WidgetTester tester,
  CapturingAnchorActivationGateway gateway,
  int expectedCount,
  String label,
) async {
  bool complete() =>
      gateway.saves.length >= expectedCount &&
      gateway.saveResults.length >= expectedCount;
  if (!gateway.useSystemSave) {
    await _until(tester, complete, label);
    return;
  }

  // ACTION_CREATE_DOCUMENT is a real Android activity. Give the external ADB
  // driver wall-clock time to choose a destination while the test runner keeps
  // servicing the pending platform-channel future.
  await tester.runAsync(() async {
    for (var attempt = 0; attempt < 240 && !complete(); attempt++) {
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
  });
  expect(complete(), isTrue, reason: '$label (native picker result pending)');
  await tester.pump();
  expect(tester.takeException(), isNull, reason: label);
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'native anchor activation matches Chrome and preserves download bytes',
    (tester) async {
      final oracle =
          jsonDecode(documentAnchorActivationChromeExpectedJson)
              as Map<String, dynamic>;
      final oracleOrigin = oracle['oracleOrigin'] as String;
      final cases = (oracle['cases'] as List)
          .map((item) => Map<String, dynamic>.from(item as Map))
          .toList(growable: false);
      expect(cases, hasLength(23));
      final theme = await PircTheme.load();
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final origin = 'http://127.0.0.1:${server.port}';
      final token = 'pirc_dev_${List.filled(43, 'A').join()}';
      const serverDownloadText = 'SERVER_ANCHOR_BYTES_雪_OK';
      final receipts = <Json>[];
      final serverFailures = <Object>[];
      final listener = server.listen((request) {
        unawaited(() async {
          try {
            await request.drain<void>();
            final receipt = <String, dynamic>{
              'method': request.method,
              'path': request.uri.path,
              'authorization': request.headers.value('authorization'),
              'referer': request.headers.value('referer'),
              'userAgent': request.headers.value('user-agent'),
            };
            receipts.add(receipt);
            if (receipt['authorization'] != 'Bearer $token') {
              serverFailures.add(
                StateError(
                  'Loopback request lacked its synthetic pairing token: '
                  '${request.method} ${request.uri.path}',
                ),
              );
            }

            if (request.method == 'GET' &&
                request.uri.path == '/api/sessions') {
              request.response.headers.contentType = ContentType.json;
              request.response.write('{"sessions":[]}');
            } else if (request.method == 'GET' &&
                request.uri.path == '/fixture') {
              request.response.headers.contentType = ContentType(
                'text',
                'html',
                charset: 'utf-8',
              );
              request.response.write(documentAnchorActivationFixture);
            } else if (request.method == 'GET' &&
                request.uri.path == '/download/server-bytes.txt') {
              request.response.headers.contentType = ContentType(
                'text',
                'plain',
                charset: 'utf-8',
              );
              request.response.write(serverDownloadText);
            } else if (request.method == 'GET' &&
                request.uri.path.startsWith('/destination/')) {
              final marker = request.uri.pathSegments.last;
              request.response.headers.contentType = ContentType(
                'text',
                'html',
                charset: 'utf-8',
              );
              request.response.write(
                '<!doctype html><html><body><p id="destination-marker">'
                'DESTINATION $marker</p></body></html>',
              );
            } else if (request.method == 'GET' &&
                request.uri.path == '/favicon.ico') {
              request.response.statusCode = HttpStatus.noContent;
            } else {
              serverFailures.add(
                StateError(
                  'Unexpected anchor fixture request: '
                  '${request.method} ${request.uri}',
                ),
              );
              request.response.statusCode = HttpStatus.notFound;
            }
            await request.response.close();
          } catch (error) {
            serverFailures.add(error);
            try {
              request.response.statusCode = HttpStatus.internalServerError;
              await request.response.close();
            } catch (_) {}
          }
        }());
      });

      final gateway = CapturingAnchorActivationGateway(
        useSystemSave: useSystemSave,
      );
      expect(gateway.useSystemSave, useSystemSave);
      try {
        // Pairing is synthetic; document and destination traffic uses the real
        // NativeDocumentWindows/Gateway transport and script-runtime pipeline.
        await gateway.call('pair', {
          'link': Uri(
            scheme: 'pirc',
            host: 'pair',
            queryParameters: {'url': origin, 'token': token},
          ).toString(),
        });

        for (final width in [390.0, 860.0]) {
          for (final brightness in [Brightness.light, Brightness.dark]) {
            for (final scale in [1.0, 2.0]) {
              if (useSystemSave &&
                  (width != 390.0 ||
                      brightness != Brightness.light ||
                      scale != 1.0)) {
                continue;
              }
              tester.view.devicePixelRatio = 1;
              tester.view.physicalSize = Size(width, 844);
              tester.view.viewInsets = const FakeViewPadding();

              for (final expectedCase in cases) {
                final caseId = expectedCase['caseId'] as String;
                if (useSystemSave && caseId != 'blob-download-revoke') {
                  continue;
                }
                final sourceUrl = '$origin/fixture?case=$caseId';
                final receiptStart = receipts.length;
                final saveStart = gateway.saves.length;
                final windows = NativeDocumentWindows(gateway);
                final sourceWindow = windows.target(
                  '',
                  null,
                  sourceUrl: sourceUrl,
                );

                try {
                  final loadResult = await sourceWindow.load(
                    NativeHtmlFormRequest(
                      url: sourceUrl,
                      method: 'GET',
                      target: '',
                    ),
                    baseUrl: sourceUrl,
                  );
                  expect(
                    loadResult,
                    NativeDocumentLoadResult.committed,
                    reason: '$caseId source document load',
                  );
                  expect(windows.select(sourceWindow), isTrue);
                  final sourceDocument = sourceWindow.currentDocument;
                  expect(sourceDocument, isNotNull);

                  await tester.pumpWidget(
                    MaterialApp(
                      theme: theme.build(brightness),
                      home: MediaQuery(
                        data: MediaQueryData(
                          size: Size(width, 844),
                          devicePixelRatio: 1,
                          textScaler: TextScaler.linear(scale),
                          platformBrightness: brightness,
                          viewInsets: EdgeInsets.zero,
                        ),
                        child: NativeDocumentWorkspace(windows: windows),
                      ),
                    ),
                  );

                  await _until(
                    tester,
                    () => sourceDocument?.scripts?.ready == true,
                    '$caseId native script runtime ready',
                    details: () => '${sourceDocument?.scripts?.diagnostics}',
                  );

                  if (caseId != 'startup-popup' && caseId != 'timer-popup') {
                    final button = find.byWidgetPredicate(
                      (widget) =>
                          widget is NativeHtmlButtonWidget &&
                          widget.button.label == 'Run $caseId',
                    );
                    expect(button, findsOneWidget, reason: '$caseId trigger');
                    await tester.ensureVisible(button);
                    await tester.pump();
                    expect(
                      button.hitTestable(),
                      findsOneWidget,
                      reason: 'Visible native trigger for $caseId',
                    );
                    await tester.tap(button);
                    await tester.pump();
                  }

                  await _until(
                    tester,
                    () => _readJsonElement(sourceDocument, '#result') != null,
                    '$caseId DOM result published',
                    details: () => '${sourceDocument?.scripts?.diagnostics}',
                  );

                  // Capture the complete DOM result before checking the host
                  // default; source documents remain retained in history.
                  final actualResult = _readJsonElement(
                    sourceDocument,
                    '#result',
                  )!;
                  final expectedResult = Map<String, dynamic>.from(
                    expectedCase['eventResult'] as Map,
                  );
                  expect(
                    _canonicalJson(actualResult, origin),
                    _canonicalJson(expectedResult, oracleOrigin),
                    reason: '$caseId Chrome DOM event result',
                  );

                  final expectedPageUrl =
                      expectedCase['currentPageUrl'] as String;
                  final expectedPageIsSource =
                      _canonicalText(expectedPageUrl, oracleOrigin) ==
                      _canonicalText(sourceUrl, origin);
                  final popupUrls = (expectedCase['popupUrls'] as List)
                      .cast<String>();
                  final expectedDownloadValue = expectedCase['download'];
                  final expectedDownload = expectedDownloadValue == null
                      ? null
                      : Map<String, dynamic>.from(expectedDownloadValue as Map);

                  if (popupUrls.isNotEmpty) {
                    expect(popupUrls, hasLength(1));
                    final expectedPopupUrl = popupUrls.single;
                    await _until(
                      tester,
                      () {
                        final active = windows.active;
                        return windows.windows.length == 2 &&
                            active != null &&
                            !identical(active, sourceWindow) &&
                            !active.loading &&
                            active.current?.url != null &&
                            _canonicalText(active.current!.url, origin) ==
                                _canonicalText(expectedPopupUrl, oracleOrigin);
                      },
                      '$caseId popup navigation completed',
                      details: () =>
                          'windows=${windows.windows.map((w) => w.current?.url).toList()}',
                    );
                    final popup = windows.active!;
                    final marker =
                        'DESTINATION ${Uri.parse(expectedPopupUrl).pathSegments.last}';
                    await _until(
                      tester,
                      () =>
                          popup.currentDocument?.content.text.contains(
                            marker,
                          ) ==
                          true,
                      '$caseId popup destination document loaded',
                    );
                    await tester.pump();
                    expect(
                      _visibleRichText(tester),
                      contains(marker),
                      reason: '$caseId visible native popup destination',
                    );
                    expect(sourceWindow.currentDocument, same(sourceDocument));
                    expect(sourceWindow.current?.url, sourceUrl);
                    expect(sourceWindow.history, hasLength(1));
                    expect(popup.history, hasLength(1));
                  } else if (expectedDownload != null) {
                    expect(expectedPageIsSource, isTrue);
                    await _waitForSaveResult(
                      tester,
                      gateway,
                      saveStart + 1,
                      '$caseId download reached saveDocument',
                    );
                    expect(
                      gateway.saves,
                      hasLength(saveStart + 1),
                      reason: '$caseId produces exactly one save request',
                    );
                    final save = gateway.saves.last;
                    final result = gateway.saveResults.last;
                    final bytes = save['bytes'] as Uint8List;
                    final expectedBytes = utf8.encode(
                      expectedDownload['utf8Text'] as String,
                    );
                    expect(bytes.toList(), expectedBytes, reason: caseId);
                    expect(
                      bytes.length,
                      expectedDownload['byteLength'],
                      reason: '$caseId Chrome byte length',
                    );
                    expect(
                      save['name'],
                      expectedDownload['suggestedFilename'],
                      reason: '$caseId suggested save filename',
                    );
                    expect(
                      save['mimeType'],
                      'text/plain',
                      reason: '$caseId normalized save MIME',
                    );
                    final connection = await windows.connection();
                    expect(
                      save['pairingStamp'],
                      connection['pairingStamp'],
                      reason: '$caseId save belongs to the current pairing',
                    );
                    expect(result, isNotNull);
                    expect(
                      sourceWindow.currentDocument,
                      same(sourceDocument),
                      reason: '$caseId download preserves its source document',
                    );
                    expect(sourceWindow.current?.url, sourceUrl);
                    expect(sourceWindow.history, hasLength(1));
                    expect(windows.windows, hasLength(1));
                  } else if (!expectedPageIsSource) {
                    await _until(
                      tester,
                      () =>
                          !sourceWindow.loading &&
                          sourceWindow.current?.url != null &&
                          _canonicalText(sourceWindow.current!.url, origin) ==
                              _canonicalText(expectedPageUrl, oracleOrigin),
                      '$caseId same-window navigation completed',
                      details: () =>
                          'current=${sourceWindow.current?.url}, '
                          'history=${sourceWindow.history.map((e) => e.url).toList()}',
                    );
                    final destination = sourceWindow.currentDocument;
                    expect(destination, isNotNull);
                    final marker =
                        'DESTINATION ${Uri.parse(expectedPageUrl).pathSegments.last}';
                    await _until(
                      tester,
                      () => destination?.content.text.contains(marker) == true,
                      '$caseId same-window destination document loaded',
                    );
                    await tester.pump();
                    expect(
                      _visibleRichText(tester),
                      contains(marker),
                      reason: '$caseId visible native destination',
                    );
                    expect(windows.windows, hasLength(1));
                    expect(windows.active, same(sourceWindow));
                    expect(sourceWindow.currentDocument, isNot(sourceDocument));
                    expect(sourceWindow.history.length, greaterThan(1));
                    expect(
                      sourceWindow.history.first.document,
                      same(sourceDocument),
                    );
                  } else {
                    await tester.pump(const Duration(milliseconds: 100));
                    expect(windows.windows, hasLength(1));
                    expect(windows.active, same(sourceWindow));
                    expect(sourceWindow.currentDocument, same(sourceDocument));
                    expect(sourceWindow.current?.url, sourceUrl);
                    expect(sourceWindow.history, hasLength(1));
                    expect(
                      gateway.saves.length,
                      saveStart,
                      reason: '$caseId does not save a file',
                    );
                  }

                  final popupBlocked =
                      caseId == 'startup-popup' || caseId == 'timer-popup';
                  if (popupBlocked) {
                    await _until(
                      tester,
                      () => sourceDocument?.scripts?.diagnostics.length == 1,
                      '$caseId blocked popup diagnostic',
                    );
                    expect(sourceDocument?.scripts?.diagnostics, [
                      'A new-window navigation requires a host-dispatched user event.',
                    ]);
                  } else {
                    expect(
                      sourceDocument?.scripts?.diagnostics,
                      isEmpty,
                      reason: '$caseId script diagnostics',
                    );
                  }

                  final caseReceipts = receipts
                      .skip(receiptStart)
                      .map((receipt) => Map<String, dynamic>.from(receipt))
                      .toList(growable: false);
                  final actualDestinationUrls = windows.windows
                      .map((window) => window.current?.url)
                      .whereType<String>()
                      .toList(growable: false);
                  final capturedSaves = <Json>[];
                  for (
                    var index = saveStart;
                    index < gateway.saves.length;
                    index++
                  ) {
                    final save = gateway.saves[index];
                    capturedSaves.add({
                      'name': save['name'],
                      'mimeType': save['mimeType'],
                      'pairingStampMatchesCurrent':
                          save['pairingStamp'] ==
                          (await windows.connection())['pairingStamp'],
                      'bytesBase64': base64Encode(save['bytes'] as Uint8List),
                      'nativeOrMockResult': gateway.saveResults[index],
                    });
                  }
                  debugPrintSynchronously(
                    'NATIVE_ANCHOR_ACTIVATION ${jsonEncode({'fixtureSha256': oracle['fixtureSha256'], 'systemSave': useSystemSave, 'width': width.toInt(), 'brightness': brightness.name, 'textScale': scale, 'caseId': caseId, 'eventResult': actualResult, 'http': caseReceipts, 'saves': capturedSaves, 'windows': actualDestinationUrls, 'sourceHistoryLength': sourceWindow.history.length, 'diagnostics': sourceDocument?.scripts?.diagnostics})}',
                  );
                  expect(
                    caseReceipts.every(
                      (receipt) => receipt['authorization'] == 'Bearer $token',
                    ),
                    isTrue,
                    reason: '$caseId loopback request authentication',
                  );
                } finally {
                  final documents = windows.windows
                      .expand((window) => window.history)
                      .map((entry) => entry.document)
                      .whereType<NativeFetchedDocument>()
                      .toSet();
                  await tester.pumpWidget(const SizedBox.shrink());
                  windows.dispose();
                  final closed = documents
                      .map((document) => document.scripts?.closed)
                      .whereType<Future<void>>()
                      .toList(growable: false);
                  if (closed.isNotEmpty) await Future.wait(closed);
                  expect(tester.takeException(), isNull, reason: caseId);
                }
              }
            }
          }
        }

        expect(serverFailures, isEmpty, reason: 'Loopback fixture server');
        expect(receipts, isNotEmpty);
        for (final receipt in receipts) {
          expect(
            receipt['authorization'],
            'Bearer $token',
            reason: 'Authenticated fixture request ${receipt['path']}',
          );
        }
        expect(
          gateway.saves,
          hasLength(useSystemSave ? 1 : 4 * 8),
          reason: 'Four download actions per each of eight configurations',
        );
      } finally {
        try {
          await gateway.call('unpair');
        } finally {
          await listener.cancel();
          await server.close(force: true);
          tester.view.reset();
        }
      }
    },
    timeout: const Timeout(Duration(minutes: 12)),
  );
}
