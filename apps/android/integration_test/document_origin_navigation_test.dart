import 'dart:async';
import 'dart:convert';
import 'dart:io';

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

import 'document_origin_navigation_fixture.dart';

Map<String, dynamic> _map(Object? value) =>
    Map<String, dynamic>.from(value! as Map);

String _pathAndQuery(String value) {
  final uri = Uri.parse(value);
  return '${uri.path}${uri.hasQuery ? '?${uri.query}' : ''}';
}

String _normalize(String value, Map<String, String> originMap) {
  var normalized = value;
  final entries = originMap.entries.toList()
    ..sort((left, right) => right.key.length.compareTo(left.key.length));
  for (final entry in entries) {
    normalized = normalized
        .replaceAll(entry.key, entry.value)
        .replaceAll(
          Uri.encodeComponent(entry.key),
          Uri.encodeComponent(entry.value),
        )
        .replaceAll(
          Uri.encodeQueryComponent(entry.key),
          Uri.encodeQueryComponent(entry.value),
        );
  }
  return normalized.replaceAllMapped(
    RegExp(r'blob:https?://127\.0\.0\.1:\d+/[^#\s"<>]+'),
    (_) => 'blob:<loopback-origin>/<blob-nonce>',
  );
}

String? _normalizeNullable(Object? value, Map<String, String> originMap) =>
    value == null ? null : _normalize(value as String, originMap);

Map<String, dynamic>? _readReferrerObservation(
  NativeFetchedDocument? document,
) {
  final source = document?.scripts?.content?.text;
  if (source == null) return null;
  final text = html
      .parse(source)
      .querySelector('#referrer-observation')
      ?.text
      .trim();
  if (text == null || text.isEmpty || text == 'READY') return null;
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
  int maxPumps = 600,
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

Future<void> _tapHtmlButton(WidgetTester tester, String label) async {
  final finder = find.byWidgetPredicate(
    (widget) =>
        widget is NativeHtmlButtonWidget && widget.button.label == label,
  );
  expect(finder, findsOneWidget, reason: 'Visible HTML form button: $label');
  await tester.ensureVisible(finder);
  await tester.pump();
  expect(finder.hitTestable(), findsOneWidget, reason: label);
  await tester.tap(finder);
  await tester.pump();
}

Future<void> _tapControl(WidgetTester tester, String label) async {
  final button = find.byWidgetPredicate(
    (widget) =>
        widget is NativeHtmlButtonWidget && widget.button.label == label,
  );
  if (button.evaluate().isNotEmpty) {
    await _tapHtmlButton(tester, label);
  } else {
    await _tapHtmlText(tester, label);
  }
}

String _expectedRequestPath(
  Map<String, dynamic> expected,
  Map<String, String> originMap,
) => _normalize(_pathAndQuery(expected['url'] as String), originMap);

Object? _expectedOriginHeader(Map<String, dynamic> expected) {
  if (expected.containsKey('requestOrigin')) return expected['requestOrigin'];
  return expected['origin'];
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'native Origin navigation matches the Chrome HTTP and document oracle',
    (tester) async {
      final oracle =
          jsonDecode(documentOriginChromeExpectedJson) as Map<String, dynamic>;
      expect(oracle['caseCount'], 42, reason: 'Frozen Chrome case count');
      expect(
        oracle['runnerSha256'],
        'c2388f232f7459555793e28e973e83678ae863f60d3b064a908ac93d90805b14',
        reason: 'Frozen Chrome Origin runner',
      );
      final oracleOrigins = _map(oracle['origins']);
      final fixtureOriginByServer = <String, String>{
        'a': oracleOrigins['a'] as String,
        'b': oracleOrigins['b'] as String,
        'c': oracleOrigins['c'] as String,
      };
      expect(Uri.parse(fixtureOriginByServer['a']!).host, '127.0.0.1');
      expect(Uri.parse(fixtureOriginByServer['b']!).host, 'localhost');
      expect(Uri.parse(fixtureOriginByServer['c']!).host, '127.0.0.1');
      final cases = (oracle['cases'] as List)
          .map((item) => _map(item))
          .toList(growable: false);
      final caseIds = cases.map((item) => item['caseId'] as String).toSet();
      const deferredCaseIds = <String>{'post-opaque-sandbox-null-origin'};
      expect(
        caseIds,
        containsAll(<String>{
          'post-same-origin',
          'post-cross-site',
          'get-form-same-origin',
          'get-anchor-cross-site',
          'post-origin-guard-cross-site',
          'post-opaque-sandbox-null-origin',
          'post-referrer-header-only',
          'post-referrer-meta-only',
          'post-referrer-header-meta-conflict',
          'post-referrer-meta-over-header',
          'post-referrer-element-over-meta',
          'post-referrer-element-unsafe-url-only',
          'post-referrer-rel-noreferrer',
          'post-redirect-301',
          'post-redirect-302',
          'post-redirect-303',
          'post-redirect-307',
          'post-redirect-308',
          'post-redirect-taint-a-b-a',
          'post-redirect-taint-a-b-a-c',
          'post-reload-cross-site',
          'post-reload-after-307-to-a',
          'post-reload-no-referrer-meta-unsafe',
          'post-blob-creator-cross-site',
          'post-blob-creator-no-referrer-cross-site',
          'post-named-target-source-origin',
        }),
        reason: 'Frozen Chrome fixture covers required Origin scenarios.',
      );
      for (final policy in <String>[
        'no-referrer',
        'no-referrer-when-downgrade',
        'origin',
        'origin-when-cross-origin',
        'same-origin',
        'strict-origin',
        'strict-origin-when-cross-origin',
        'unsafe-url',
      ]) {
        expect(
          caseIds,
          contains('post-policy-$policy'),
          reason: 'Chrome fixture includes the $policy response-header case.',
        );
        expect(
          caseIds,
          contains('post-policy-element-$policy'),
          reason: 'Chrome fixture includes the $policy form-attribute case.',
        );
      }

      final theme = await PircTheme.load();
      final gateway = Gateway();
      final servers = <String, HttpServer>{};
      final localOriginByFixtureOrigin = <String, String>{};
      final subscriptions = <StreamSubscription<HttpRequest>>[];
      final serverFailures = <String>[];
      final pairingAuthorizations = <String?>[];
      final originAAuthorizations = <String?>[];
      final otherOriginAuthorizations = <String?>[];
      final receipts = <Map<String, dynamic>>[];
      Map<String, dynamic>? activeCase;
      final usedExpectedRequests = <int>{};
      final token = 'pirc_dev_${List.filled(43, 'A').join()}';

      for (final entry in fixtureOriginByServer.entries) {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        servers[entry.key] = server;
        final fixtureHost = Uri.parse(entry.value).host;
        localOriginByFixtureOrigin[entry.value] =
            'http://$fixtureHost:${server.port}';
      }

      final localOriginByServer = <String, String>{
        for (final entry in servers.entries)
          entry.key:
              'http://${Uri.parse(fixtureOriginByServer[entry.key]!).host}:${entry.value.port}',
      };

      Future<void> respond(
        HttpRequest request, {
        required String server,
      }) async {
        try {
          final requestBytes = await request.fold<List<int>>(
            <int>[],
            (bytes, chunk) => bytes..addAll(chunk),
          );
          final requestBody = utf8.decode(requestBytes, allowMalformed: true);
          final path = _pathAndQuery(request.uri.toString());
          final authorization = request.headers.value('authorization');

          if (request.uri.path == '/favicon.ico') {
            request.response.statusCode = HttpStatus.noContent;
            await request.response.close();
            return;
          }

          if (server == 'a' && request.uri.path == '/api/sessions') {
            pairingAuthorizations.add(authorization);
            if (authorization != 'Bearer $token') {
              serverFailures.add(
                'Same-origin pairing request missed the synthetic bearer.',
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
              'Request arrived outside a case: ${request.method} $path',
            );
            request.response.statusCode = HttpStatus.notFound;
            await request.response.close();
            return;
          }

          final expectedRequests = (currentCase['requestHops'] as List)
              .map((item) => _map(item))
              .toList(growable: false);
          final actualBody = _normalize(
            requestBody,
            localOriginByFixtureOrigin,
          );
          int? expectedIndex;
          for (var index = 0; index < expectedRequests.length; index++) {
            final expected = expectedRequests[index];
            if (usedExpectedRequests.contains(index)) continue;
            final expectedBody = _normalize(
              expected['body'] as String? ?? '',
              localOriginByFixtureOrigin,
            );
            if (expected['server'] != server ||
                expected['method'] != request.method ||
                _expectedRequestPath(expected, localOriginByFixtureOrigin) !=
                    path ||
                expectedBody != actualBody) {
              continue;
            }
            expectedIndex = index;
            break;
          }

          if (expectedIndex == null) {
            serverFailures.add(
              'Unexpected request for ${currentCase['caseId']}: '
              '${request.method} $path on server $server',
            );
            receipts.add({
              'caseId': currentCase['caseId'],
              'server': server,
              'method': request.method,
              'url': '${localOriginByServer[server]}$path',
              'path': path,
              'body': requestBody,
              'origin': request.headers.value('origin'),
              'referer': request.headers.value('referer'),
              'authorization': authorization,
              'expectedIndex': -1,
            });
            request.response.statusCode = HttpStatus.notFound;
            await request.response.close();
            return;
          }

          usedExpectedRequests.add(expectedIndex);
          final expected = expectedRequests[expectedIndex];
          final fixtureOrigin = fixtureOriginByServer[server]!;
          final isPairedOrigin = fixtureOrigin == fixtureOriginByServer['a'];
          if (isPairedOrigin) {
            originAAuthorizations.add(authorization);
            if (authorization != 'Bearer $token') {
              serverFailures.add(
                'Origin A request missed the synthetic bearer: '
                '${request.method} $path',
              );
            }
          } else {
            otherOriginAuthorizations.add(authorization);
            if (authorization != null) {
              serverFailures.add(
                'Synthetic bearer leaked to origin $server: '
                '${request.method} $path',
              );
            }
          }

          final actualOrigin = request.headers.value('origin');
          final originGuard = expected['responseOriginGuard'] == true;
          final guardExpectedOriginRaw =
              expected['responseGuardExpectedOrigin'];
          final guardExpectedOrigin = guardExpectedOriginRaw == null
              ? null
              : _normalize(
                  guardExpectedOriginRaw as String,
                  localOriginByFixtureOrigin,
                );
          final guardAllowed =
              !originGuard || actualOrigin == guardExpectedOrigin;

          var responseStatus =
              expected['responseStatus'] as int? ?? HttpStatus.ok;
          var responseBody = expected['responseBody'] as String? ?? '';
          if (!guardAllowed) {
            responseStatus = HttpStatus.forbidden;
            responseBody = 'Origin guard rejected this request.';
            serverFailures.add(
              'Origin guard denied ${currentCase['caseId']} because '
              'Origin was $actualOrigin, expected $guardExpectedOrigin.',
            );
          }

          final responseLocation = expected['responseLocation'] as String?;
          request.response.statusCode = responseStatus;
          request.response.headers.set(
            HttpHeaders.contentTypeHeader,
            expected['responseContentType'] as String? ??
                'text/html; charset=utf-8',
          );
          request.response.headers.set('Cache-Control', 'no-store');
          final referrerPolicy = expected['responseReferrerPolicy'] as String?;
          if (referrerPolicy != null) {
            request.response.headers.set('Referrer-Policy', referrerPolicy);
          }
          if (responseLocation != null) {
            request.response.headers.set(
              HttpHeaders.locationHeader,
              _normalize(responseLocation, localOriginByFixtureOrigin),
            );
          }
          final responseBodyExpected = expected['responseBody'] as String?;
          if (Uri.parse(expected['url'] as String).path == '/source' &&
              responseBodyExpected != currentCase['sourceHtml']) {
            serverFailures.add(
              'Fixture sourceHtml differs from its source server response '
              'for ${currentCase['caseId']}.',
            );
          }
          request.response.write(
            _normalize(responseBody, localOriginByFixtureOrigin),
          );
          await request.response.close();

          receipts.add({
            'caseId': currentCase['caseId'],
            'expectedIndex': expectedIndex,
            'server': server,
            'fixtureOrigin': fixtureOrigin,
            'method': request.method,
            'url': '${localOriginByServer[server]}$path',
            'path': path,
            'body': requestBody,
            'origin': actualOrigin,
            'referer': request.headers.value('referer'),
            'authorization': authorization,
            'responseStatus': responseStatus,
            'responseLocation': responseLocation == null
                ? null
                : _normalize(responseLocation, localOriginByFixtureOrigin),
            'responseBody': _normalize(
              responseBody,
              localOriginByFixtureOrigin,
            ),
            'originGuard': originGuard,
            'guardAllowed': guardAllowed,
          });
        } catch (error, stack) {
          serverFailures.add('Fixture response failure: $error\n$stack');
          try {
            request.response.statusCode = HttpStatus.internalServerError;
            await request.response.close();
          } catch (_) {}
        }
      }

      for (final entry in servers.entries) {
        subscriptions.add(
          entry.value.listen(
            (request) => unawaited(respond(request, server: entry.key)),
          ),
        );
      }

      Future<void> tapAndWaitForNavigation({
        required WidgetTester tester,
        required NativeDocumentWindows windows,
        required String action,
        required String label,
      }) async {
        final beforeWindow = windows.active;
        final beforeUrl = beforeWindow?.current?.url;
        await _tapControl(tester, label);
        await _until(
          tester,
          () {
            final active = windows.active;
            final navigated =
                active != null &&
                (active != beforeWindow || active.current?.url != beforeUrl);
            return navigated &&
                !active.loading &&
                active.currentDocument?.scripts?.ready == true;
          },
          '$action navigation after control: $label',
          details: () =>
              'active=${windows.active?.current?.url}, '
              'history=${windows.active?.history.map((item) => item.url).toList()}',
        );
      }

      try {
        await gateway.call('pair', {
          'link': Uri(
            scheme: 'pirc',
            host: 'pair',
            queryParameters: {'url': localOriginByServer['a'], 'token': token},
          ).toString(),
        });

        var matrixIndex = 0;
        for (final width in <double>[390, 860]) {
          for (final brightness in Brightness.values) {
            for (final scale in <double>[1, 2]) {
              matrixIndex++;
              tester.view.devicePixelRatio = 1;
              tester.view.physicalSize = Size(width, 844);

              for (final oracleCase in cases) {
                final caseId = oracleCase['caseId'] as String;
                if (deferredCaseIds.contains(caseId)) {
                  final opaquePost = (oracleCase['requestHops'] as List)
                      .map((item) => _map(item))
                      .firstWhere((hop) => hop['method'] == 'POST');
                  expect(
                    _expectedOriginHeader(opaquePost),
                    'null',
                    reason: '$caseId frozen Chrome baseline has opaque Origin',
                  );
                  if (matrixIndex == 1) {
                    debugPrintSynchronously(
                      'DOCUMENT_ORIGIN_DEFERRED ${jsonEncode({'caseId': caseId, 'reason': 'NativeDocumentWorkspace has no frame tree for '
                          'the sandboxed source; the Chrome source and '
                          'request baseline is retained without fabricating '
                          'a main-page form interaction.', 'chromePostOrigin': _expectedOriginHeader(opaquePost)})}',
                    );
                  }
                  continue;
                }
                final sourceUrl = _normalize(
                  oracleCase['sourceUrl'] as String,
                  localOriginByFixtureOrigin,
                );
                final interaction = _map(oracleCase['interaction']);
                final steps = (interaction['steps'] as List)
                    .map((item) => _map(item))
                    .toList(growable: false);
                final expectedRequests = (oracleCase['requestHops'] as List)
                    .map((item) => _map(item))
                    .toList(growable: false);
                final expectedFinal = _map(oracleCase['finalDocument']);
                final expectedFinalUrl = _normalize(
                  expectedFinal['url'] as String,
                  localOriginByFixtureOrigin,
                );
                activeCase = oracleCase;
                usedExpectedRequests.clear();
                final receiptStart = receipts.length;
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
                    '$caseId source scripts ready',
                    details: () =>
                        '${windows.active?.currentDocument?.scripts?.diagnostics}',
                  );

                  for (
                    var stepIndex = 0;
                    stepIndex < steps.length;
                    stepIndex++
                  ) {
                    final step = steps[stepIndex];
                    final action = step['action'] as String;
                    switch (action) {
                      case 'tap-button':
                        await _tapHtmlButton(tester, step['label'] as String);
                        if (stepIndex + 1 < steps.length &&
                            steps[stepIndex + 1]['action'] == 'reload') {
                          await _until(
                            tester,
                            () =>
                                windows.active != null &&
                                !windows.active!.loading &&
                                _normalize(
                                      windows.active!.current?.url ?? '',
                                      localOriginByFixtureOrigin,
                                    ) ==
                                    expectedFinalUrl &&
                                windows
                                        .active
                                        ?.currentDocument
                                        ?.scripts
                                        ?.ready ==
                                    true,
                            '$caseId POST response before reload',
                          );
                        }
                        break;
                      case 'tap-link':
                        await tapAndWaitForNavigation(
                          tester: tester,
                          windows: windows,
                          action: action,
                          label: step['label'] as String,
                        );
                        break;
                      case 'select-source':
                        expect(windows.select(sourceWindow), isTrue);
                        await tester.pump();
                        expect(
                          windows.active,
                          same(sourceWindow),
                          reason:
                              '$caseId reselects the original source window',
                        );
                        break;
                      case 'reload':
                        final beforeReload = windows.active?.currentDocument;
                        final requestCountBeforeReload = receipts.length;
                        await tester.tap(find.byTooltip('重新載入'));
                        await tester.pump();
                        await _until(
                          tester,
                          () => find.text('重新送出表單？').evaluate().isNotEmpty,
                          '$caseId POST reload confirmation',
                        );
                        final confirmation = find.text('重新送出');
                        expect(confirmation, findsOneWidget);
                        await tester.tap(confirmation);
                        await _until(
                          tester,
                          () =>
                              windows.active?.currentDocument != beforeReload &&
                              windows.active?.currentDocument?.scripts?.ready ==
                                  true &&
                              receipts.length - receiptStart >=
                                  expectedRequests.length,
                          '$caseId POST reload completed',
                          details: () =>
                              'requests=${receipts.length - receiptStart}/'
                              '${expectedRequests.length}, '
                              'before=${beforeReload?.referrer}, '
                              'current=${windows.active?.current?.url}',
                        );
                        expect(
                          receipts.length,
                          greaterThan(requestCountBeforeReload),
                          reason: '$caseId reload performed real HTTP requests',
                        );
                        break;
                      default:
                        fail('$caseId has an unsupported UI step: $action');
                    }
                  }

                  await _until(
                    tester,
                    () =>
                        windows.active != null &&
                        !windows.active!.loading &&
                        _normalize(
                              windows.active!.current?.url ?? '',
                              localOriginByFixtureOrigin,
                            ) ==
                            expectedFinalUrl &&
                        windows.active?.currentDocument?.scripts?.ready ==
                            true &&
                        usedExpectedRequests.length == expectedRequests.length,
                    '$caseId final document selected',
                    details: () =>
                        'expected=$expectedFinalUrl, '
                        'actual=${windows.active?.current?.url}, '
                        'requests=${usedExpectedRequests.length}/'
                        '${expectedRequests.length}',
                  );

                  final finalDocument = windows.active?.currentDocument;
                  expect(
                    finalDocument,
                    isNotNull,
                    reason: '$caseId final page',
                  );
                  final document = finalDocument!;
                  expect(
                    _normalize(document.url, localOriginByFixtureOrigin),
                    expectedFinalUrl,
                    reason: '$caseId final document URL',
                  );
                  expect(
                    _normalize(document.referrer, localOriginByFixtureOrigin),
                    _normalize(
                      expectedFinal['documentReferrer'] as String? ?? '',
                      localOriginByFixtureOrigin,
                    ),
                    reason: '$caseId NativeFetchedDocument.referrer',
                  );
                  final observation = _readReferrerObservation(document);
                  expect(
                    observation,
                    isNotNull,
                    reason: '$caseId JavaScript referrer observation exists',
                  );
                  final actualObservation = observation!;
                  final expectedObservation = _map(
                    expectedFinal['referrerObservation'],
                  );
                  expect(
                    _normalize(
                      actualObservation['referrer'] as String? ?? '',
                      localOriginByFixtureOrigin,
                    ),
                    _normalize(
                      expectedObservation['referrer'] as String? ?? '',
                      localOriginByFixtureOrigin,
                    ),
                    reason: '$caseId JavaScript document.referrer',
                  );
                  expect(
                    _normalize(
                      actualObservation['url'] as String? ?? '',
                      localOriginByFixtureOrigin,
                    ),
                    _normalize(
                      expectedObservation['url'] as String? ?? '',
                      localOriginByFixtureOrigin,
                    ),
                    reason: '$caseId JavaScript location.href',
                  );

                  final actualRequests =
                      receipts
                          .skip(receiptStart)
                          .map((item) => Map<String, dynamic>.from(item))
                          .toList()
                        ..sort(
                          (left, right) => (left['expectedIndex'] as int)
                              .compareTo(right['expectedIndex'] as int),
                        );
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
                    expect(actual['server'], expected['server'], reason: label);
                    expect(actual['method'], expected['method'], reason: label);
                    expect(
                      actual['path'],
                      _expectedRequestPath(
                        expected,
                        localOriginByFixtureOrigin,
                      ),
                      reason: '$label path/query',
                    );
                    expect(
                      actual['fixtureOrigin'],
                      expected['serverOrigin'],
                      reason: '$label fixture origin mapping',
                    );
                    expect(
                      actual['body'],
                      _normalize(
                        expected['body'] as String? ?? '',
                        localOriginByFixtureOrigin,
                      ),
                      reason: '$label request body',
                    );
                    expect(
                      _normalizeNullable(
                        actual['origin'],
                        localOriginByFixtureOrigin,
                      ),
                      _normalizeNullable(
                        _expectedOriginHeader(expected),
                        localOriginByFixtureOrigin,
                      ),
                      reason: '$label actual HTTP Origin header',
                    );
                    expect(
                      _normalizeNullable(
                        actual['referer'],
                        localOriginByFixtureOrigin,
                      ),
                      _normalizeNullable(
                        expected['referer'],
                        localOriginByFixtureOrigin,
                      ),
                      reason: '$label actual HTTP Referer header',
                    );

                    final fixtureOrigin = expected['serverOrigin'] as String;
                    final paired = fixtureOrigin == fixtureOriginByServer['a'];
                    expect(
                      actual['authorization'],
                      paired ? 'Bearer $token' : isNull,
                      reason: paired
                          ? '$label same-origin synthetic bearer'
                          : '$label cross-origin bearer isolation',
                    );
                    expect(
                      actual['responseStatus'],
                      expected['responseStatus'],
                      reason: '$label response status',
                    );
                    expect(
                      _normalizeNullable(
                        actual['responseLocation'],
                        localOriginByFixtureOrigin,
                      ),
                      _normalizeNullable(
                        expected['responseLocation'],
                        localOriginByFixtureOrigin,
                      ),
                      reason: '$label redirect Location',
                    );
                    expect(
                      actual['guardAllowed'],
                      isTrue,
                      reason:
                          '$label Origin guard returned 200 only for the '
                          'expected Origin header',
                    );
                    if (expected['responseOriginGuard'] == true) {
                      expect(
                        actual['responseStatus'],
                        HttpStatus.ok,
                        reason:
                            '$label guarded response accepted Chrome Origin',
                      );
                      expect(
                        _normalize(
                          actual['responseBody'] as String,
                          localOriginByFixtureOrigin,
                        ),
                        _normalize(
                          expected['responseBody'] as String? ?? '',
                          localOriginByFixtureOrigin,
                        ),
                        reason: '$label guarded response body matches Chrome',
                      );
                    }
                  }

                  debugPrintSynchronously(
                    'DOCUMENT_ORIGIN_NAVIGATION ${jsonEncode({
                      'runnerSha256': oracle['runnerSha256'],
                      'fixtureSha256': 'dcc5baa37cc7565614c2371560865897d12ff7c8f5d90a70e3de42880f9c83f0',
                      'matrix': {'width': width.toInt(), 'brightness': brightness.name, 'textScale': scale},
                      'caseId': caseId,
                      'http': actualRequests.map((r) => Map<String, dynamic>.of(r)..remove('responseBody')).toList(),
                      'finalUrl': windows.active?.current?.url,
                      'nativeReferrer': document.referrer,
                      'javascriptObservation': actualObservation,
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

        expect(
          serverFailures,
          isEmpty,
          reason: 'Loopback Origin oracle servers',
        );
        expect(pairingAuthorizations, isNotEmpty);
        expect(
          pairingAuthorizations.every((value) => value == 'Bearer $token'),
          isTrue,
          reason: 'Pairing requests carry the synthetic same-origin bearer.',
        );
        expect(originAAuthorizations, isNotEmpty);
        expect(
          originAAuthorizations.every((value) => value == 'Bearer $token'),
          isTrue,
          reason: 'Origin A requests carry the paired synthetic bearer.',
        );
        expect(otherOriginAuthorizations, isNotEmpty);
        expect(
          otherOriginAuthorizations.every((value) => value == null),
          isTrue,
          reason: 'Other origins never receive the synthetic bearer.',
        );
        debugPrintSynchronously(
          'DOCUMENT_ORIGIN_MATRIX_COMPLETE ${jsonEncode({'testedCaseCount': cases.length - deferredCaseIds.length, 'oracleCaseCount': cases.length, 'deferredCaseIds': deferredCaseIds.toList(), 'configurationCount': matrixIndex, 'requestCount': receipts.length, 'sameOriginRequestsWithAuthorization': originAAuthorizations.length, 'crossOriginRequestsWithoutAuthorization': otherOriginAuthorizations.length})}',
        );
      } finally {
        try {
          await gateway.call('unpair');
        } finally {
          for (final subscription in subscriptions) {
            await subscription.cancel();
          }
          for (final server in servers.values) {
            await server.close(force: true);
          }
          tester.view.reset();
        }
      }
    },
    timeout: const Timeout(Duration(minutes: 30)),
  );
}
