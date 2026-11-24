import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show debugPrintSynchronously;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:html/parser.dart' as html;
import 'package:integration_test/integration_test.dart';
import 'package:pirc_mobile/live/document_navigation.dart';
import 'package:pirc_mobile/live/document_navigation_state.dart';
import 'package:pirc_mobile/live/document_referrer.dart';
import 'package:pirc_mobile/live/gateway.dart';
import 'package:pirc_render/src/html_buttons.dart';
import 'package:pirc_render/src/html_form_submission.dart';
import 'package:pirc_mobile/theme.dart';

import 'document_referrer_navigation_fixture.dart';

class CapturingDocumentReferrerGateway extends Gateway {
  final List<Map<String, dynamic>> saves = [];
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
    final result = {'name': payload['name'], 'bytesWritten': bytes.length};
    saveResults.add(result);
    return result;
  }
}

String _pathAndQuery(String url) {
  final uri = Uri.parse(url);
  return '${uri.path}${uri.hasQuery ? '?${uri.query}' : ''}';
}

String _originOf(String url) {
  final uri = Uri.parse(url);
  final defaultPort = uri.scheme == 'https' ? 443 : 80;
  final authority = uri.port == defaultPort
      ? uri.host
      : '${uri.host}:${uri.port}';
  return '${uri.scheme}://$authority';
}

String _normalize(
  String value, {
  required String oracleSameOrigin,
  required String oracleCrossOrigin,
  required String localSameOrigin,
  required String localCrossOrigin,
}) {
  var normalized = value
      .replaceAll(oracleSameOrigin, localSameOrigin)
      .replaceAll(oracleCrossOrigin, localCrossOrigin);
  normalized = normalized.replaceAllMapped(
    RegExp(r'blob:(https?://127\.0\.0\.1:\d+)/[^#\s]+'),
    (_) => 'blob:<loopback-origin>/<blob-nonce>',
  );
  return normalized;
}

String? _normalizeNullable(
  String? value, {
  required String oracleSameOrigin,
  required String oracleCrossOrigin,
  required String localSameOrigin,
  required String localCrossOrigin,
}) => value == null
    ? null
    : _normalize(
        value,
        oracleSameOrigin: oracleSameOrigin,
        oracleCrossOrigin: oracleCrossOrigin,
        localSameOrigin: localSameOrigin,
        localCrossOrigin: localCrossOrigin,
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

Future<void> _until(
  WidgetTester tester,
  bool Function() condition,
  String label, {
  String Function()? details,
  int maxPumps = 500,
}) async {
  for (var index = 0; index < maxPumps && !condition(); index++) {
    await tester.pump(const Duration(milliseconds: 20));
  }
  expect(
    condition(),
    isTrue,
    reason: '$label${details == null ? '' : ': ${details()}'}',
  );
  await tester.pump();
  expect(tester.takeException(), isNull, reason: label);
}

Future<void> _tapHtmlText(WidgetTester tester, String text) async {
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
  expect(finder, findsOneWidget, reason: 'Visible HTML link: $text');
  await tester.ensureVisible(finder);
  await tester.pump();
  final paragraph = tester.renderObject<RenderParagraph>(finder);
  final plainText = paragraph.text.toPlainText();
  final start = plainText.indexOf(text);
  final boxes = paragraph.getBoxesForSelection(
    TextSelection(baseOffset: start, extentOffset: start + text.length),
  );
  expect(boxes, isNotEmpty, reason: 'Selection boxes for link: $text');
  await tester.tapAt(paragraph.localToGlobal(boxes.first.toRect().center));
  await tester.pump();
}

Map<String, dynamic> _map(Object? value) =>
    Map<String, dynamic>.from(value! as Map);

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'native document navigation matches the Chrome referrer lifecycle oracle',
    (tester) async {
      final oracle =
          jsonDecode(documentReferrerNavigationChromeExpectedJson)
              as Map<String, dynamic>;
      final oracleOrigins = _map(oracle['origins']);
      final oracleSameOrigin = oracleOrigins['sameOrigin'] as String;
      final oracleCrossOrigin = oracleOrigins['crossOrigin'] as String;
      final cases = (oracle['cases'] as List)
          .map((item) => _map(item))
          .toList(growable: false);
      expect(cases, hasLength(16));

      final theme = await PircTheme.load();
      final sameServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final crossServer = await HttpServer.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      final sameOrigin = 'http://127.0.0.1:${sameServer.port}';
      final crossOrigin = 'http://127.0.0.1:${crossServer.port}';
      final token = 'pirc_dev_${List.filled(43, 'A').join()}';
      final receipts = <Map<String, dynamic>>[];
      final serverFailures = <String>[];
      final pairingAuthorizations = <String?>[];
      final crossOriginAuthorizations = <String?>[];
      final gateway = CapturingDocumentReferrerGateway();
      Map<String, dynamic>? activeCase;
      final usedExpectedRequests = <int>{};

      Future<void> respond(HttpRequest request, {required bool same}) async {
        try {
          final requestBytes = await request.fold<List<int>>(
            <int>[],
            (bytes, chunk) => bytes..addAll(chunk),
          );
          final requestBody = utf8.decode(requestBytes, allowMalformed: true);
          final path = _pathAndQuery(request.uri.toString());
          final authorization = request.headers.value('authorization');
          if (same && request.uri.path == '/api/sessions') {
            pairingAuthorizations.add(authorization);
            if (authorization != 'Bearer $token') {
              serverFailures.add(
                'Same-origin pairing request missing synthetic bearer: '
                '${request.method} $path',
              );
            }
            request.response.headers.set(
              HttpHeaders.contentTypeHeader,
              'application/json; charset=utf-8',
            );
            request.response.write('{"sessions":[]}');
            await request.response.close();
            return;
          }

          final currentCase = activeCase;
          if (currentCase == null) {
            serverFailures.add(
              'Request arrived outside a case: ${request.uri}',
            );
            request.response.statusCode = HttpStatus.notFound;
            await request.response.close();
            return;
          }

          if (same) {
            if (authorization != 'Bearer $token') {
              serverFailures.add(
                'Same-origin request missing synthetic bearer: '
                '${request.method} $path',
              );
            }
          } else {
            crossOriginAuthorizations.add(authorization);
            if (authorization != null) {
              serverFailures.add(
                'Cross-origin request leaked Authorization: '
                '${request.method} $path',
              );
            }
          }

          final expectedRequests = (currentCase['requests'] as List)
              .map((item) => _map(item))
              .toList(growable: false);
          int? expectedIndex;
          for (var index = 0; index < expectedRequests.length; index++) {
            final expected = expectedRequests[index];
            if (usedExpectedRequests.contains(index) ||
                expected['method'] != request.method ||
                _pathAndQuery(expected['url'] as String) != path) {
              continue;
            }
            final expectedSameOrigin =
                _originOf(expected['url'] as String) == oracleSameOrigin;
            if (expectedSameOrigin != same) continue;
            expectedIndex = index;
            break;
          }

          if (expectedIndex == null) {
            for (var index = 0; index < expectedRequests.length; index++) {
              final expected = expectedRequests[index];
              if (usedExpectedRequests.contains(index) ||
                  expected['method'] != request.method ||
                  Uri.parse(expected['url'] as String).path !=
                      request.uri.path) {
                continue;
              }
              expectedIndex = index;
              serverFailures.add(
                'Request differed from the Chrome method/path/query sequence: '
                '${request.method} $path',
              );
              break;
            }
          }

          if (expectedIndex == null) {
            serverFailures.add(
              'Unexpected navigation request: ${request.method} $path',
            );
            receipts.add({
              'caseId': currentCase['caseId'],
              'origin': same ? 'same' : 'cross',
              'method': request.method,
              'path': path,
              'referer': request.headers.value('referer'),
              'originHeader': request.headers.value('origin'),
              'authorization': authorization,
              'body': requestBody,
              'expectedIndex': -1,
            });
            request.response.statusCode = HttpStatus.notFound;
            await request.response.close();
            return;
          }

          usedExpectedRequests.add(expectedIndex);
          final expected = expectedRequests[expectedIndex];
          final responseSpec = _map(expected['response']);
          receipts.add({
            'caseId': currentCase['caseId'],
            'origin': same ? 'same' : 'cross',
            'method': request.method,
            'path': path,
            'referer': request.headers.value('referer'),
            'originHeader': request.headers.value('origin'),
            'authorization': authorization,
            'body': requestBody,
            'expectedIndex': expectedIndex,
            'expectedOrigin': _originOf(expected['url'] as String),
          });

          request.response.statusCode =
              responseSpec['statusCode'] as int? ?? HttpStatus.ok;
          final contentType = responseSpec['contentType'] as String?;
          if (contentType != null) {
            request.response.headers.set(
              HttpHeaders.contentTypeHeader,
              contentType,
            );
          }
          final cacheControl = responseSpec['cacheControl'] as String?;
          if (cacheControl != null) {
            request.response.headers.set('Cache-Control', cacheControl);
          }
          final referrerPolicy = responseSpec['referrerPolicy'] as String?;
          if (referrerPolicy != null) {
            request.response.headers.set('Referrer-Policy', referrerPolicy);
          }
          final contentDisposition =
              responseSpec['contentDisposition'] as String?;
          if (contentDisposition != null) {
            request.response.headers.set(
              'Content-Disposition',
              contentDisposition,
            );
          }
          final location = responseSpec['location'] as String?;
          if (location != null) {
            request.response.headers.set(
              'Location',
              location
                  .replaceAll(oracleSameOrigin, sameOrigin)
                  .replaceAll(oracleCrossOrigin, crossOrigin),
            );
          }
          final isSourceDocument =
              Uri.parse(expected['url'] as String).path == '/source';
          final bodyText = isSourceDocument
              ? currentCase['sourceHtml'] as String
              : responseSpec['bodyText'] as String? ?? '';
          request.response.write(
            bodyText
                .replaceAll(oracleSameOrigin, sameOrigin)
                .replaceAll(oracleCrossOrigin, crossOrigin),
          );
          await request.response.close();
        } catch (error, stack) {
          serverFailures.add('Fixture response error: $error\n$stack');
          try {
            request.response.statusCode = HttpStatus.internalServerError;
            await request.response.close();
          } catch (_) {}
        }
      }

      final sameListener = sameServer.listen(
        (request) => unawaited(respond(request, same: true)),
      );
      final crossListener = crossServer.listen(
        (request) => unawaited(respond(request, same: false)),
      );

      Future<void> tapButton(WidgetTester tester, String label) async {
        final finder = find.byWidgetPredicate(
          (widget) =>
              widget is NativeHtmlButtonWidget && widget.button.label == label,
        );
        expect(finder, findsOneWidget, reason: 'HTML button: $label');
        await tester.ensureVisible(finder);
        await tester.pump();
        expect(finder.hitTestable(), findsOneWidget, reason: label);
        await tester.tap(finder);
        await tester.pump();
      }

      try {
        // Pairing is the only synthetic gateway call. All navigation, form,
        // history, reload and download requests use the real HTTP transport.
        await gateway.call('pair', {
          'link': Uri(
            scheme: 'pirc',
            host: 'pair',
            queryParameters: {'url': sameOrigin, 'token': token},
          ).toString(),
        });

        var matrixIndex = 0;
        for (final width in [390.0, 860.0]) {
          for (final brightness in Brightness.values) {
            for (final scale in [1.0, 2.0]) {
              matrixIndex++;
              tester.view.devicePixelRatio = 1;
              tester.view.physicalSize = Size(width, 844);

              for (final oracleCase in cases) {
                final caseId = oracleCase['caseId'] as String;
                if (caseId == 'pushstate-query-before-link') {
                  // Retain the Chrome baseline: the native script runtime does
                  // not yet implement the History API. See history-api-before.json.
                  if (matrixIndex == 1) {
                    debugPrintSynchronously(
                      'DOCUMENT_REFERRER_DEFERRED ${jsonEncode({'caseId': caseId, 'reason': 'Native History API is not implemented; frozen Chrome case remains an explicit parity gap.'})}',
                    );
                  }
                  continue;
                }
                activeCase = oracleCase;
                usedExpectedRequests.clear();
                final receiptStart = receipts.length;
                final saveStart = gateway.saves.length;
                final sourceUrl = (oracleCase['sourceUrl'] as String)
                    .replaceAll(oracleSameOrigin, sameOrigin)
                    .replaceAll(oracleCrossOrigin, crossOrigin);
                final expectedSnapshots = (oracleCase['snapshots'] as List)
                    .map((item) => _map(item))
                    .toList(growable: false);
                final sourceRequest = (oracleCase['requests'] as List)
                    .map((item) => _map(item))
                    .firstWhere(
                      (item) =>
                          Uri.parse(item['url'] as String).path == '/source',
                    );
                expect(
                  oracleCase['sourceHtml'],
                  _map(sourceRequest['response'])['bodyText'],
                  reason: '$caseId captured sourceHtml matches HTTP response',
                );
                final expectedFinal = expectedSnapshots.last;
                final expectedFinalUrl = (expectedFinal['url'] as String)
                    .replaceAll(oracleSameOrigin, sameOrigin)
                    .replaceAll(oracleCrossOrigin, crossOrigin);
                final windows = NativeDocumentWindows(gateway);
                final sourceWindow = windows.target(
                  '',
                  null,
                  sourceUrl: sourceUrl,
                );

                try {
                  final initialResult = await sourceWindow.load(
                    NativeHtmlFormRequest(
                      url: sourceUrl,
                      method: 'GET',
                      target: '',
                    ),
                    baseUrl: sourceUrl,
                    referrer: const NativeDocumentReferrer('', 'no-referrer'),
                  );
                  expect(
                    initialResult,
                    NativeDocumentLoadResult.committed,
                    reason: '$caseId initial source load',
                  );
                  expect(windows.select(sourceWindow), isTrue);

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
                        child: NativeDocumentWorkspace(windows: windows),
                      ),
                    ),
                  );

                  await _until(
                    tester,
                    () =>
                        windows.active?.currentDocument?.scripts?.ready == true,
                    '$caseId source script runtime ready',
                    details: () =>
                        '${windows.active?.currentDocument?.scripts?.diagnostics}',
                  );

                  Future<void> tapLinkAndWait(String label) async {
                    await _tapHtmlText(tester, label);
                    await _until(
                      tester,
                      () =>
                          windows.active != null &&
                          !windows.active!.loading &&
                          windows.active!.current?.url != null &&
                          _normalize(
                                windows.active!.current!.url,
                                oracleSameOrigin: oracleSameOrigin,
                                oracleCrossOrigin: oracleCrossOrigin,
                                localSameOrigin: sameOrigin,
                                localCrossOrigin: crossOrigin,
                              ) ==
                              _normalize(
                                expectedFinalUrl,
                                oracleSameOrigin: oracleSameOrigin,
                                oracleCrossOrigin: oracleCrossOrigin,
                                localSameOrigin: sameOrigin,
                                localCrossOrigin: crossOrigin,
                              ) &&
                          windows.active?.currentDocument?.scripts?.ready ==
                              true,
                      '$caseId navigation after link: $label',
                      details: () =>
                          'active=${windows.active?.current?.url}, '
                          'history=${windows.active?.history.map((item) => item.url).toList()}',
                    );
                  }

                  switch (caseId) {
                    case 'form-get-same-origin':
                      await tapButton(tester, 'Submit GET');
                      break;
                    case 'form-post-cross-origin':
                      await tapButton(tester, 'Submit POST');
                      break;
                    case 'form-rel-noreferrer-cross-origin':
                      await tapButton(tester, 'Submit noreferrer form');
                      break;
                    case 'form-referrerpolicy-no-referrer':
                      await tapButton(tester, 'Submit policy form');
                      break;
                    case 'location-assign-same-origin':
                      await tapButton(tester, 'Assign');
                      break;
                    case 'location-replace-cross-origin':
                      await tapButton(tester, 'Replace');
                      break;
                    case 'dynamic-meta-before-link':
                      await tapButton(tester, 'Add no-referrer meta');
                      await tapLinkAndWait('Follow link');
                      break;
                    case 'base-href-cross-origin-link':
                      await tapLinkAndWait('Follow relative link');
                      break;
                    case 'download-anchor-no-referrer':
                      await _tapHtmlText(tester, 'Download');
                      await _until(
                        tester,
                        () =>
                            gateway.saves.length > saveStart &&
                            gateway.saveResults.length > saveStart,
                        '$caseId HTTP download saved',
                      );
                      expect(windows.active, same(sourceWindow));
                      expect(sourceWindow.current?.url, sourceUrl);
                      break;
                    case 'download-cross-origin-redirect':
                      await _tapHtmlText(tester, 'Download through redirect');
                      await _until(
                        tester,
                        () =>
                            gateway.saves.length > saveStart &&
                            gateway.saveResults.length > saveStart,
                        '$caseId redirected HTTP download saved',
                      );
                      expect(windows.active, same(sourceWindow));
                      expect(sourceWindow.current?.url, sourceUrl);
                      break;
                    case 'named-target-window':
                      await tapLinkAndWait('Open named target');
                      expect(windows.active, isNot(same(sourceWindow)));
                      break;
                    case 'reload-after-link-navigation':
                      await tapLinkAndWait('Open reload destination');
                      final beforeReload = windows.active!.currentDocument;
                      final expectedRequestCount =
                          (oracleCase['requests'] as List).length;
                      await tester.tap(find.byTooltip('重新載入'));
                      await _until(
                        tester,
                        () =>
                            windows.active?.currentDocument != beforeReload &&
                            windows.active?.currentDocument?.scripts?.ready ==
                                true &&
                            receipts.length - receiptStart >=
                                expectedRequestCount,
                        '$caseId destination reload',
                      );
                      break;
                    case 'destination-meta-change-after-load':
                      await _tapHtmlText(
                        tester,
                        'Open destination with meta policy',
                      );
                      await _until(
                        tester,
                        () =>
                            windows.active != null &&
                            !windows.active!.loading &&
                            windows.active!.current?.url ==
                                expectedSnapshots[1]['url']
                                    .toString()
                                    .replaceAll(oracleSameOrigin, sameOrigin) &&
                            windows.active?.currentDocument?.scripts?.ready ==
                                true,
                        '$caseId destination page load',
                      );
                      await tapButton(
                        tester,
                        'Change destination meta to unsafe-url',
                      );
                      await _tapHtmlText(tester, 'Continue to cross origin');
                      await _until(
                        tester,
                        () =>
                            windows.active != null &&
                            !windows.active!.loading &&
                            windows.active!.current?.url == expectedFinalUrl &&
                            windows.active?.currentDocument?.scripts?.ready ==
                                true,
                        '$caseId cross-origin destination',
                      );
                      break;
                    case 'back-forward-no-store':
                      await _tapHtmlText(tester, 'Open history destination');
                      await _until(
                        tester,
                        () =>
                            windows.active?.current?.url == expectedFinalUrl &&
                            windows.active?.currentDocument?.scripts?.ready ==
                                true,
                        '$caseId initial destination',
                      );
                      await tester.tap(find.byTooltip('返回'));
                      await _until(
                        tester,
                        () =>
                            windows.active == sourceWindow &&
                            windows.active?.current?.url == sourceUrl &&
                            windows.active?.currentDocument?.scripts?.ready ==
                                true &&
                            receipts.length - receiptStart >= 3,
                        '$caseId no-store back refetch',
                      );
                      await tester.tap(find.byTooltip('下一頁'));
                      await _until(
                        tester,
                        () =>
                            windows.active == sourceWindow &&
                            windows.active?.current?.url == expectedFinalUrl &&
                            windows.active?.currentDocument?.scripts?.ready ==
                                true &&
                            receipts.length - receiptStart >= 4,
                        '$caseId no-store forward refetch',
                      );
                      break;
                    case 'pushstate-query-before-link':
                      await tapButton(tester, 'Change current query');
                      await tapLinkAndWait('Follow ordinary link');
                      break;
                    case 'blob-document-http-link':
                      await tapButton(tester, 'Open Blob HTML');
                      await _until(
                        tester,
                        () =>
                            windows.active?.current?.url.startsWith('blob:') ==
                                true &&
                            windows.active?.currentDocument?.scripts?.ready ==
                                true,
                        '$caseId Blob HTML document load',
                      );
                      await _tapHtmlText(tester, 'Follow HTTP link');
                      await _until(
                        tester,
                        () =>
                            windows.active != null &&
                            !windows.active!.loading &&
                            windows.active!.current?.url == expectedFinalUrl &&
                            windows.active?.currentDocument?.scripts?.ready ==
                                true,
                        '$caseId HTTP link from Blob document',
                      );
                      break;
                    default:
                      fail('Unimplemented Chrome replay case: $caseId');
                  }

                  await _until(
                    tester,
                    () =>
                        windows.active != null &&
                        !windows.active!.loading &&
                        windows.active!.current?.url != null &&
                        _normalize(
                              windows.active!.current!.url,
                              oracleSameOrigin: oracleSameOrigin,
                              oracleCrossOrigin: oracleCrossOrigin,
                              localSameOrigin: sameOrigin,
                              localCrossOrigin: crossOrigin,
                            ) ==
                            _normalize(
                              expectedFinalUrl,
                              oracleSameOrigin: oracleSameOrigin,
                              oracleCrossOrigin: oracleCrossOrigin,
                              localSameOrigin: sameOrigin,
                              localCrossOrigin: crossOrigin,
                            ) &&
                        windows.active?.currentDocument?.scripts?.ready == true,
                    '$caseId final document selected',
                    details: () =>
                        'expected=$expectedFinalUrl, '
                        'actual=${windows.active?.current?.url}',
                  );

                  final finalDocument = windows.active?.currentDocument;
                  expect(
                    finalDocument,
                    isNotNull,
                    reason: '$caseId final page',
                  );
                  final expectedFinalReferrer =
                      expectedFinal['documentReferrer'] as String? ?? '';
                  expect(
                    _normalize(
                      finalDocument!.referrer,
                      oracleSameOrigin: oracleSameOrigin,
                      oracleCrossOrigin: oracleCrossOrigin,
                      localSameOrigin: sameOrigin,
                      localCrossOrigin: crossOrigin,
                    ),
                    _normalize(
                      expectedFinalReferrer,
                      oracleSameOrigin: oracleSameOrigin,
                      oracleCrossOrigin: oracleCrossOrigin,
                      localSameOrigin: sameOrigin,
                      localCrossOrigin: crossOrigin,
                    ),
                    reason: '$caseId NativeFetchedDocument.referrer',
                  );
                  final observation = _readJsonElement(
                    finalDocument,
                    '#referrer-observation',
                  );
                  expect(
                    observation,
                    isNotNull,
                    reason: '$caseId JavaScript referrer observation exists',
                  );
                  expect(
                    _normalize(
                      observation!['referrer'] as String? ?? '',
                      oracleSameOrigin: oracleSameOrigin,
                      oracleCrossOrigin: oracleCrossOrigin,
                      localSameOrigin: sameOrigin,
                      localCrossOrigin: crossOrigin,
                    ),
                    _normalize(
                      _map(expectedFinal['referrerObservation'])['referrer']
                              as String? ??
                          '',
                      oracleSameOrigin: oracleSameOrigin,
                      oracleCrossOrigin: oracleCrossOrigin,
                      localSameOrigin: sameOrigin,
                      localCrossOrigin: crossOrigin,
                    ),
                    reason: '$caseId JavaScript document.referrer',
                  );
                  expect(
                    _normalize(
                      observation['url'] as String? ?? '',
                      oracleSameOrigin: oracleSameOrigin,
                      oracleCrossOrigin: oracleCrossOrigin,
                      localSameOrigin: sameOrigin,
                      localCrossOrigin: crossOrigin,
                    ),
                    _normalize(
                      expectedFinalUrl,
                      oracleSameOrigin: oracleSameOrigin,
                      oracleCrossOrigin: oracleCrossOrigin,
                      localSameOrigin: sameOrigin,
                      localCrossOrigin: crossOrigin,
                    ),
                    reason: '$caseId JavaScript location.href',
                  );

                  final actualRequests = receipts
                      .skip(receiptStart)
                      .map((item) => Map<String, dynamic>.from(item))
                      .toList(growable: false);
                  final expectedRequests = (oracleCase['requests'] as List)
                      .map((item) => _map(item))
                      .toList(growable: false);
                  expect(
                    actualRequests,
                    hasLength(expectedRequests.length),
                    reason: '$caseId actual HTTP request count',
                  );
                  for (
                    var index = 0;
                    index < expectedRequests.length;
                    index++
                  ) {
                    final expected = expectedRequests[index];
                    final actual = actualRequests[index];
                    final label = '$caseId HTTP[$index]';
                    expect(actual['expectedIndex'], index, reason: label);
                    expect(actual['method'], expected['method'], reason: label);
                    expect(
                      actual['path'],
                      _pathAndQuery(expected['url'] as String),
                      reason: '$label path and query',
                    );
                    expect(
                      _normalizeNullable(
                        actual['referer'] as String?,
                        oracleSameOrigin: oracleSameOrigin,
                        oracleCrossOrigin: oracleCrossOrigin,
                        localSameOrigin: sameOrigin,
                        localCrossOrigin: crossOrigin,
                      ),
                      _normalizeNullable(
                        expected['referer'] as String?,
                        oracleSameOrigin: oracleSameOrigin,
                        oracleCrossOrigin: oracleCrossOrigin,
                        localSameOrigin: sameOrigin,
                        localCrossOrigin: crossOrigin,
                      ),
                      reason: '$label Referer header',
                    );
                    expect(
                      actual['body'],
                      expected['body'] as String? ?? '',
                      reason: '$label request body',
                    );
                    expect(
                      _normalizeNullable(
                        actual['originHeader'] as String?,
                        oracleSameOrigin: oracleSameOrigin,
                        oracleCrossOrigin: oracleCrossOrigin,
                        localSameOrigin: sameOrigin,
                        localCrossOrigin: crossOrigin,
                      ),
                      _normalizeNullable(
                        expected['origin'] as String?,
                        oracleSameOrigin: oracleSameOrigin,
                        oracleCrossOrigin: oracleCrossOrigin,
                        localSameOrigin: sameOrigin,
                        localCrossOrigin: crossOrigin,
                      ),
                      reason: '$label Origin header',
                    );
                    if (actual['origin'] == 'same') {
                      expect(
                        actual['authorization'],
                        'Bearer $token',
                        reason: '$label same-origin synthetic bearer',
                      );
                    } else {
                      expect(
                        actual['authorization'],
                        isNull,
                        reason: '$label cross-origin bearer isolation',
                      );
                    }
                  }

                  if (caseId.startsWith('download-')) {
                    expect(gateway.saves.length, saveStart + 1);
                    final save = gateway.saves.last;
                    final expectedDownloadRequest = expectedRequests.last;
                    final expectedBytes = utf8.encode(
                      _map(expectedDownloadRequest['response'])['bodyText']
                              as String? ??
                          '',
                    );
                    expect(
                      base64Encode(save['bytes'] as Uint8List),
                      base64Encode(expectedBytes),
                      reason: '$caseId bytes',
                    );
                    expect(
                      save['pairingStamp'],
                      (await windows.connection())['pairingStamp'],
                      reason: '$caseId save uses the active local pairing',
                    );
                  } else {
                    expect(
                      gateway.saves.length,
                      saveStart,
                      reason: '$caseId does not invoke native file saving',
                    );
                  }

                  debugPrintSynchronously(
                    'DOCUMENT_REFERRER_NAVIGATION ${jsonEncode({
                      'runnerSha256': oracle['runnerSha256'],
                      'fixtureSha256': oracle['fixtureSha256'],
                      'matrix': {'width': width.toInt(), 'brightness': brightness.name, 'textScale': scale},
                      'caseId': caseId,
                      'http': actualRequests,
                      'finalUrl': windows.active?.current?.url,
                      'nativeReferrer': finalDocument.referrer,
                      'javascriptObservation': observation,
                      'saveCount': gateway.saves.length - saveStart,
                    })}',
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
                  activeCase = null;
                }
              }
            }
          }
        }

        expect(serverFailures, isEmpty, reason: 'Loopback oracle servers');
        expect(pairingAuthorizations, isNotEmpty);
        expect(
          pairingAuthorizations.every((value) => value == 'Bearer $token'),
          isTrue,
          reason:
              'The paired same-origin server requires its synthetic bearer.',
        );
        expect(crossOriginAuthorizations, isNotEmpty);
        expect(
          crossOriginAuthorizations.every((value) => value == null),
          isTrue,
          reason: 'The cross-origin server records no Authorization header.',
        );
        debugPrintSynchronously(
          'DOCUMENT_REFERRER_MATRIX_COMPLETE ${jsonEncode({
            'caseCount': cases.length - 1,
            'oracleCaseCount': cases.length,
            'deferredCaseIds': ['pushstate-query-before-link'],
            'configurationCount': matrixIndex,
            'requestCount': receipts.length,
            'sameOriginPairingRequests': pairingAuthorizations.length,
            'crossOriginRequestsWithoutAuthorization': crossOriginAuthorizations.length,
            'originHeaderCompared': true,
          })}',
        );
      } finally {
        try {
          await gateway.call('unpair');
        } finally {
          await sameListener.cancel();
          await crossListener.cancel();
          await sameServer.close(force: true);
          await crossServer.close(force: true);
          tester.view.reset();
        }
      }
    },
    timeout: const Timeout(Duration(minutes: 15)),
  );
}
