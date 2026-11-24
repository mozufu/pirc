import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:html/parser.dart' as html;
import 'package:integration_test/integration_test.dart';
import 'package:pirc_mobile/live/document_navigation.dart';
import 'package:pirc_mobile/live/document_navigation_state.dart';
import 'package:pirc_mobile/live/gateway.dart';
import 'package:pirc_mobile/live/markdown_image.dart';
import 'package:pirc_render/src/html_buttons.dart';
import 'package:pirc_render/src/html_form_submission.dart';
import 'package:pirc_mobile/theme.dart';

import 'document_blob_navigation_fixture.dart';

String _instrumentBlobNavigationHtml(String source) {
  const appendix = r'''
<p><a id="native-no-referrer" href="#" target="_blank"
      referrerpolicy="no-referrer">HTML no-referrer</a></p>
<button id="native-revoke-html-blob" type="button">Revoke original HTML blob</button>
<pre id="native-blob-revoke-result">NOT_REVOKED</pre>
<script>
  document.querySelector('#prepare-blob-links').addEventListener('click', () => {
    const urls = window.__blobNavigationUrls;
    document.querySelector('#native-no-referrer').href = urls.htmlUrl;
  });
  document.querySelector('#native-revoke-html-blob').addEventListener('click', () => {
    const url = window.__blobNavigationUrls?.htmlUrl;
    if (!url) {
      document.querySelector('#native-blob-revoke-result').textContent = 'MISSING';
      return;
    }
    URL.revokeObjectURL(url);
    document.querySelector('#native-blob-revoke-result').textContent = 'REVOKED';
  });
</script>
''';
  if (!source.contains('</body>')) {
    throw StateError('Shared blob navigation fixture has no body end tag.');
  }
  final end = source.lastIndexOf('</body>');
  return source.replaceRange(end, end, appendix);
}

Map<String, dynamic>? _readJsonElement(
  NativeFetchedDocument? document,
  String selector,
) {
  final source = document?.scripts?.content?.text;
  if (source == null) return null;
  final text = html.parse(source).querySelector(selector)?.text.trim();
  if (text == null ||
      text.isEmpty ||
      text == 'WAITING' ||
      text == 'LOADING' ||
      text == 'CORE_LOADING') {
    return null;
  }
  try {
    final value = jsonDecode(text);
    return value is Map ? Map<String, dynamic>.from(value) : null;
  } catch (_) {
    return null;
  }
}

String? _readElementText(NativeFetchedDocument? document, String selector) {
  final source = document?.scripts?.content?.text;
  if (source == null) return null;
  return html.parse(source).querySelector(selector)?.text.trim();
}

String _visibleRichText(WidgetTester tester) => tester
    .widgetList<RichText>(find.byType(RichText))
    .map((widget) => widget.text.toPlainText())
    .join('\n');

Future<void> _tapText(WidgetTester tester, String text) async {
  final exact = find.byWidgetPredicate(
    (widget) => widget is RichText && widget.text.toPlainText().trim() == text,
  );
  final finder = exact.evaluate().isNotEmpty
      ? exact
      : find
            .byWidgetPredicate(
              (widget) =>
                  widget is RichText &&
                  widget.text.toPlainText().contains(text),
            )
            .first;
  expect(finder, findsOneWidget, reason: 'Visible HTML anchor: $text');
  await tester.ensureVisible(finder);
  await tester.pump();
  final paragraph = tester.renderObject<RenderParagraph>(finder);
  final plainText = paragraph.text.toPlainText();
  final start = plainText.indexOf(text);
  final boxes = paragraph.getBoxesForSelection(
    TextSelection(baseOffset: start, extentOffset: start + text.length),
  );
  expect(boxes, isNotEmpty, reason: 'Selection boxes for anchor: $text');
  await tester.tapAt(paragraph.localToGlobal(boxes.first.toRect().center));
  await tester.pump();
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'native blob document navigation follows the Chrome core oracle',
    (tester) async {
      final chromeExpected =
          jsonDecode(blobNavigationExpectedJson) as Map<String, dynamic>;
      final parentSetupExpected = Map<String, dynamic>.from(
        chromeExpected['parentSetup'] as Map,
      );
      final coreExpected =
          jsonDecode(blobNavigationCoreExpectedJson) as Map<String, dynamic>;
      final baseCoreExpected =
          jsonDecode(blobNavigationBaseCoreExpectedJson)
              as Map<String, dynamic>;
      final noReferrerExpected = Map<String, dynamic>.from(coreExpected)
        ..['referrerMatchesCreator'] = false;
      final theme = await PircTheme.load();
      final fixtureHtml = _instrumentBlobNavigationHtml(blobNavigationHtml);
      final receipts = <Map<String, Object?>>[];
      final failures = <Object>[];
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final origin = 'http://127.0.0.1:${server.port}';
      final token = 'pirc_dev_${List.filled(43, 'A').join()}';
      final listener = server.listen((request) async {
        final authorization = request.headers.value('authorization');
        final referer = request.headers.value('referer');
        receipts.add({
          'method': request.method,
          'path': request.uri.path,
          'authorization': authorization,
          'referer': referer,
        });
        try {
          if (authorization != 'Bearer $token') {
            failures.add(
              StateError(
                'Missing local fixture bearer for ${request.method} ${request.uri.path}.',
              ),
            );
          }
          if (request.method == 'GET' && request.uri.path == '/api/sessions') {
            request.response.headers.contentType = ContentType.json;
            request.response.write('{"sessions":[]}');
          } else if (request.method == 'GET' &&
              request.uri.path == '/fixture') {
            request.response.headers.contentType = ContentType(
              'text',
              'html',
              charset: 'utf-8',
            );
            request.response.write(fixtureHtml);
          } else if (request.method == 'GET' &&
              request.uri.path == '/absolute.txt') {
            request.response.headers.contentType = ContentType(
              'text',
              'plain',
              charset: 'utf-8',
            );
            request.response.write('ABSOLUTE_BLOB_FETCH_OK');
          } else if (request.method == 'GET' &&
              request.uri.path == '/base/relative.txt') {
            request.response.headers.contentType = ContentType(
              'text',
              'plain',
              charset: 'utf-8',
            );
            request.response.write('BASE_RELATIVE_FETCH_OK');
          } else {
            failures.add(
              StateError(
                'Unexpected local fixture request: ${request.method} ${request.uri}',
              ),
            );
            request.response.statusCode = HttpStatus.notFound;
          }
          await request.response.close();
        } catch (error) {
          failures.add(error);
          try {
            request.response.statusCode = HttpStatus.internalServerError;
            await request.response.close();
          } catch (_) {}
        }
      });

      final gateway = Gateway();
      final allDocuments = <NativeFetchedDocument>{};
      var matrixIndex = 0;
      try {
        // The only synthetic operation is local pairing; document and fetch
        // traffic below uses the real native transport against this loopback.
        await gateway.call('pair', {
          'link': Uri(
            scheme: 'pirc',
            host: 'pair',
            queryParameters: {'url': origin, 'token': token},
          ).toString(),
        });

        for (final width in [390.0, 860.0]) {
          for (final brightness in Brightness.values) {
            for (final scale in [1.0, 2.0]) {
              matrixIndex++;
              final windows = NativeDocumentWindows(gateway);
              final sourceUrl = '$origin/fixture';
              final sourceWindow = windows.target(
                '',
                null,
                sourceUrl: sourceUrl,
              );
              final boundaryKey = GlobalKey();
              tester.view.devicePixelRatio = 1;
              tester.view.physicalSize = Size(width, 844);

              Future<void> until(
                bool Function() condition,
                String label,
              ) async {
                for (var index = 0; index < 400 && !condition(); index++) {
                  await tester.pump(const Duration(milliseconds: 25));
                }
                expect(
                  condition(),
                  isTrue,
                  reason:
                      '$label: ${windows.active?.currentDocument?.scripts?.diagnostics}',
                );
                await tester.pump();
                expect(tester.takeException(), isNull, reason: label);
              }

              void rememberDocuments() {
                for (final window in windows.windows) {
                  allDocuments.addAll(
                    window.history
                        .map((entry) => entry.document)
                        .whereType<NativeFetchedDocument>(),
                  );
                }
              }

              Finder button(String label) => find.byWidgetPredicate(
                (widget) =>
                    widget is NativeHtmlButtonWidget &&
                    widget.button.label == label,
              );

              Future<void> tapButton(String label) async {
                await until(
                  () => windows.active?.currentDocument?.scripts?.ready == true,
                  'JavaScript document ready before $label',
                );
                final finder = button(label);
                expect(finder, findsOneWidget, reason: 'HTML button: $label');
                await tester.ensureVisible(finder);
                await tester.pump();
                expect(finder.hitTestable(), findsOneWidget);
                await tester.tap(finder);
                await tester.pump();
              }

              Future<NativeDocumentWindow> tapBlobAnchor(
                String label, {
                Map<String, dynamic>? expectedCore,
              }) async {
                final before = windows.active?.currentDocument;
                await _tapText(tester, label);
                await until(() {
                  final active = windows.active;
                  final current = active?.current;
                  return active != null &&
                      !active.loading &&
                      current?.url.startsWith('blob:') == true &&
                      !identical(active.currentDocument, before) &&
                      (expectedCore == null ||
                          _readJsonElement(
                                active.currentDocument,
                                '#blob-navigation-core-result',
                              ) !=
                              null);
                }, 'Blob navigation completed: $label');
                rememberDocuments();
                final active = windows.active!;
                if (expectedCore != null) {
                  expect(
                    _readJsonElement(
                      active.currentDocument,
                      '#blob-navigation-core-result',
                    ),
                    expectedCore,
                    reason: 'Chrome core probe for $label',
                  );
                }
                return active;
              }

              Future<void> selectSource() async {
                if (sourceWindow.index > 0) {
                  final result = await sourceWindow.traverseHistory(0);
                  expect(
                    result,
                    anyOf(
                      NativeDocumentLoadResult.committed,
                      NativeDocumentLoadResult.retained,
                    ),
                  );
                }
                expect(windows.select(sourceWindow), isTrue);
                await tester.pump();
                await until(
                  () =>
                      windows.active == sourceWindow &&
                      !sourceWindow.loading &&
                      sourceWindow.current?.url == sourceUrl &&
                      sourceWindow.currentDocument?.scripts?.ready == true,
                  'Return to the original HTTP parent document',
                );
              }

              Future<void> closePopup(NativeDocumentWindow popup) async {
                if (!popup.disposed) windows.close(popup);
                await tester.pump();
              }

              try {
                final loadResult = await sourceWindow.load(
                  NativeHtmlFormRequest(
                    url: sourceUrl,
                    method: 'GET',
                    target: '',
                  ),
                  baseUrl: sourceUrl,
                );
                expect(loadResult, NativeDocumentLoadResult.committed);
                expect(windows.select(sourceWindow), isTrue);
                rememberDocuments();

                await tester.pumpWidget(
                  MaterialApp(
                    theme: theme.build(brightness),
                    home: MediaQuery(
                      data: MediaQueryData(
                        size: Size(width, 844),
                        devicePixelRatio: 1,
                        textScaler: TextScaler.linear(scale),
                        platformBrightness: brightness,
                      ),
                      child: RepaintBoundary(
                        key: boundaryKey,
                        child: NativeDocumentWorkspace(windows: windows),
                      ),
                    ),
                  ),
                );
                await until(
                  () => sourceWindow.currentDocument?.scripts?.ready == true,
                  'Loopback parent JavaScript runtime ready',
                );
                await tapButton('Prepare blob navigation links');
                await until(
                  () =>
                      _readJsonElement(
                        sourceWindow.currentDocument,
                        '#blob-navigation-result',
                      ) !=
                      null,
                  'Parent creates blob URL links',
                );
                expect(
                  _readJsonElement(
                    sourceWindow.currentDocument,
                    '#blob-navigation-result',
                  ),
                  parentSetupExpected,
                );

                final self = await tapBlobAnchor(
                  'HTML self',
                  expectedCore: coreExpected,
                );
                expect(self, same(sourceWindow));
                expect(
                  sourceWindow.currentDocument?.referrer,
                  sourceUrl,
                  reason:
                      'Default same-origin blob referrer is the creator URL.',
                );
                expect(
                  _visibleRichText(tester),
                  contains('Blob child document 雪 café'),
                  reason: 'The HTML blob child rendered its Unicode heading.',
                );
                expect(sourceWindow.history.length, greaterThan(1));
                await selectSource();

                final blank = await tapBlobAnchor(
                  'HTML blank',
                  expectedCore: coreExpected,
                );
                expect(blank, isNot(same(sourceWindow)));
                expect(blank.name, isEmpty);
                expect(blank.currentDocument?.referrer, sourceUrl);
                expect(windows.select(sourceWindow), isTrue);
                await tester.pump();
                await closePopup(blank);

                final named = await tapBlobAnchor(
                  'HTML named',
                  expectedCore: coreExpected,
                );
                expect(named.name, 'blob-navigation-named');
                final namedWindowId = named.id;
                expect(windows.select(sourceWindow), isTrue);
                await tester.pump();
                await _tapText(tester, 'HTML named second');
                await until(() {
                  final active = windows.active;
                  return active != null &&
                      active.id == namedWindowId &&
                      !active.loading &&
                      _readJsonElement(
                            active.currentDocument,
                            '#blob-navigation-core-result',
                          ) !=
                          null;
                }, 'The second named-target navigation reuses its window');
                rememberDocuments();
                expect(
                  windows.windows.where(
                    (window) => window.name == 'blob-navigation-named',
                  ),
                  hasLength(1),
                );
                expect(
                  _readJsonElement(
                    named.currentDocument,
                    '#blob-navigation-core-result',
                  ),
                  baseCoreExpected,
                );
                expect(named.id, namedWindowId);
                expect(windows.select(sourceWindow), isTrue);
                await tester.pump();
                await closePopup(named);

                if (matrixIndex == 1) {
                  final privateChild = await tapBlobAnchor(
                    'HTML no-referrer',
                    expectedCore: noReferrerExpected,
                  );
                  expect(privateChild.currentDocument?.referrer, isEmpty);
                  expect(windows.select(sourceWindow), isTrue);
                  await tester.pump();
                  await closePopup(privateChild);

                  final plain = await tapBlobAnchor('Plain UTF-8 charset');
                  expect(plain, same(sourceWindow));
                  expect(plain.currentDocument?.mimeType, 'text/plain');
                  final editable = tester.state<EditableTextState>(
                    find.byType(EditableText),
                  );
                  expect(
                    editable.renderEditable.text!.toPlainText(),
                    'Blob plain text café 雪',
                  );
                  expect(editable.renderEditable.size.height, greaterThan(0));
                  expect(editable.renderEditable.size.width, greaterThan(0));
                  await selectSource();

                  final image = await tapBlobAnchor('Image self');
                  expect(image, same(sourceWindow));
                  expect(image.currentDocument?.mimeType, 'image/png');
                  final imageFinder = find.byWidgetPredicate(
                    (widget) => widget is NativeMarkdownImage,
                  );
                  expect(imageFinder, findsOneWidget);
                  bool hasDecodedImage() => tester
                      .widgetList<RawImage>(find.byType(RawImage))
                      .any((raw) => raw.image != null);
                  await until(
                    hasDecodedImage,
                    'The PNG blob decodes in Flutter',
                  );
                  final decodedImage = find.descendant(
                    of: imageFinder,
                    matching: find.byWidgetPredicate(
                      (widget) => widget is RawImage && widget.image != null,
                    ),
                  );
                  expect(decodedImage, findsOneWidget);
                  await tester.pump();
                  final imageRect = tester.getRect(decodedImage);
                  expect(imageRect.width, greaterThan(0));
                  expect(imageRect.height, greaterThan(0));
                  final boundaryRect = tester.getRect(find.byKey(boundaryKey));
                  final point = imageRect.center - boundaryRect.topLeft;
                  final boundary = tester.renderObject<RenderRepaintBoundary>(
                    find.byKey(boundaryKey),
                  );
                  final capture = await boundary.toImage(pixelRatio: 4);
                  try {
                    final data = (await capture.toByteData(
                      format: ui.ImageByteFormat.rawStraightRgba,
                    ))!;
                    final pixels = data.buffer.asUint8List(
                      data.offsetInBytes,
                      data.lengthInBytes,
                    );
                    final x = (point.dx * 4).floor();
                    final y = (point.dy * 4).floor();
                    expect(x, inInclusiveRange(0, capture.width - 1));
                    expect(y, inInclusiveRange(0, capture.height - 1));
                    final offset = (y * capture.width + x) * 4;
                    expect(
                      pixels.sublist(offset, offset + 4),
                      [255, 0, 0, 255],
                      reason: 'The navigated PNG blob paints its red pixel.',
                    );
                  } finally {
                    capture.dispose();
                  }
                  await selectSource();
                }

                if (matrixIndex == 1) {
                  final reloadChild = await tapBlobAnchor(
                    'HTML self',
                    expectedCore: coreExpected,
                  );
                  final beforeReload = reloadChild.currentDocument;
                  final tooltipReload = find.byTooltip('重新載入');
                  expect(tooltipReload, findsOneWidget);
                  await tester.tap(tooltipReload);
                  await tester.pump();
                  await until(
                    () =>
                        !reloadChild.loading &&
                        reloadChild.currentDocument != null &&
                        !identical(reloadChild.currentDocument, beforeReload) &&
                        _readJsonElement(
                              reloadChild.currentDocument,
                              '#blob-navigation-core-result',
                            ) !=
                            null,
                    'Reload reads the still-registered blob URL',
                  );
                  final reloadedDocument = reloadChild.currentDocument;
                  final reloadedIndex = reloadChild.index;
                  rememberDocuments();
                  expect(
                    _readJsonElement(
                      reloadedDocument,
                      '#blob-navigation-core-result',
                    ),
                    coreExpected,
                  );

                  await selectSource();
                  await tapButton('Revoke original HTML blob');
                  await until(
                    () =>
                        _readElementText(
                          sourceWindow.currentDocument,
                          '#native-blob-revoke-result',
                        ) ==
                        'REVOKED',
                    'The parent revokes its original HTML blob URL',
                  );

                  final historyResult = await sourceWindow.traverseHistory(
                    reloadedIndex,
                  );
                  expect(
                    historyResult,
                    anyOf(
                      NativeDocumentLoadResult.committed,
                      NativeDocumentLoadResult.retained,
                    ),
                  );
                  expect(windows.select(sourceWindow), isTrue);
                  await tester.pump();
                  await until(
                    () =>
                        !sourceWindow.loading &&
                        identical(
                          sourceWindow.currentDocument,
                          reloadedDocument,
                        ),
                    'The cached blob child remains visible after revocation',
                  );
                  await tester.tap(find.byTooltip('重新載入'));
                  await tester.pump();
                  await until(
                    () => !sourceWindow.loading && sourceWindow.error != null,
                    'Reload of a revoked blob reports a read error',
                  );
                  expect(sourceWindow.currentDocument, same(reloadedDocument));
                  expect(
                    sourceWindow.current?.url,
                    startsWith('blob:'),
                    reason:
                        'Failed reload retains the existing child document.',
                  );
                  await selectSource();
                  expect(
                    _readJsonElement(
                      sourceWindow.currentDocument,
                      '#blob-navigation-result',
                    ),
                    parentSetupExpected,
                    reason:
                        'The source remains navigable after blob revocation.',
                  );
                }

                debugPrint(
                  'BLOB_NAVIGATION:${width.toInt()}:${brightness.name}:$scale:core-pass',
                );
              } finally {
                rememberDocuments();
                await tester.pumpWidget(const SizedBox());
                windows.dispose();
                final closed = allDocuments
                    .map((document) => document.scripts?.closed)
                    .whereType<Future<void>>()
                    .toList(growable: false);
                if (closed.isNotEmpty) await Future.wait(closed);
                tester.view.reset();
              }
            }
          }
        }

        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(failures, isEmpty, reason: 'Loopback server request failures.');
        expect(receipts, isNotEmpty);
        for (final receipt in receipts) {
          expect(
            receipt['authorization'],
            'Bearer $token',
            reason: 'Native same-origin request: ${receipt['path']}',
          );
        }
        final absoluteRequests = receipts
            .where((receipt) => receipt['path'] == '/absolute.txt')
            .toList();
        expect(absoluteRequests, isNotEmpty);
        expect(
          absoluteRequests.every((receipt) => receipt['referer'] == null),
          isTrue,
          reason: 'Fetch from the blob document sends no Referer header.',
        );
        final baseRelativeRequests = receipts
            .where((receipt) => receipt['path'] == '/base/relative.txt')
            .toList();
        expect(baseRelativeRequests, isNotEmpty);
        expect(
          baseRelativeRequests.every((receipt) => receipt['referer'] == null),
          isTrue,
          reason: 'Fetch from a blob document sends no Referer header.',
        );
        expect(
          receipts.any((receipt) => receipt['path'] == '/relative.txt'),
          isFalse,
          reason: 'A blob-relative URL without base is rejected before HTTP.',
        );
      } finally {
        try {
          await gateway.call('unpair');
        } finally {
          await listener.cancel();
          await server.close(force: true);
        }
      }
    },
    timeout: const Timeout(Duration(minutes: 12)),
  );
}
