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
import 'package:pirc_mobile/live/gateway.dart';
import 'package:pirc_render/src/html_buttons.dart';
import 'package:pirc_render/src/html_file.dart';
import 'package:pirc_render/src/html_form_submission.dart';
import 'package:pirc_mobile/theme.dart';

import 'document_file_picker_expected.dart';
import 'document_file_picker_fixture.dart';

final Uint8List _pickedTextBytes = Uint8List.fromList(
  utf8.encode('PICKED_SNOW_✅'),
);
final Uint8List _pickedBinaryBytes = Uint8List.fromList([
  0,
  127,
  128,
  255,
  13,
  10,
]);

class CapturingFilePickerGateway extends Gateway {
  CapturingFilePickerGateway({required this.useSystemPicker});

  final bool useSystemPicker;
  String? currentCaseId;
  final List<Json> requests = [];
  final List<dynamic> results = [];

  @override
  Future<dynamic> call(String method, [Json args = const {}]) async {
    if (method != 'pickAttachments') return super.call(method, args);

    final request = <String, dynamic>{
      'caseId': currentCaseId,
      'accept': (args['accept'] as List? ?? const <dynamic>[])
          .map((item) => '$item')
          .toList(growable: false),
      'multiple': args['multiple'] == true,
    };
    requests.add(request);

    if (useSystemPicker) {
      debugPrintSynchronously(
        'NATIVE_FILE_PICKER_SYSTEM_PENDING ${jsonEncode(request)}',
      );
      final nativeResult = await super.call(method, args);
      results.add(nativeResult);
      return nativeResult;
    }

    final selected = <Map<String, dynamic>>[
      {
        'name': 'picked-雪.txt',
        'mimeType': 'text/plain',
        'bytes': Uint8List.fromList(_pickedTextBytes),
      },
      if (request['multiple'] == true)
        {
          'name': 'picked-binary.bin',
          'mimeType': 'application/macbinary',
          'bytes': Uint8List.fromList(_pickedBinaryBytes),
        },
    ];
    results.add(selected);
    return selected;
  }
}

const bool _useSystemPicker = bool.fromEnvironment(
  'PIRC_SYSTEM_PICKER',
  defaultValue: false,
);

Map<String, dynamic>? _readJsonElement(
  NativeFetchedDocument? document,
  String selector,
) {
  final source = document?.scripts?.content?.text;
  if (source == null) return null;
  final text = html.parse(source).querySelector(selector)?.text.trim();
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
  NativeFetchedDocument? document,
  bool Function() condition,
  String label, {
  int maxPumps = 400,
}) async {
  for (var index = 0; index < maxPumps && !condition(); index++) {
    await tester.pump(const Duration(milliseconds: 25));
  }
  expect(
    condition(),
    isTrue,
    reason: '$label: ${document?.scripts?.diagnostics}',
  );
  expect(tester.takeException(), isNull, reason: label);
}

bool _resultHasExpectedShape(
  Map<String, dynamic>? actual,
  Map<String, dynamic> expected,
) {
  if (actual == null || actual['status'] != 'DONE') return false;
  final actualEvents = actual['events'];
  final expectedEvents = expected['events'];
  final actualFiles = actual['files'];
  final expectedFiles = expected['files'];
  return actualEvents is List &&
      expectedEvents is List &&
      actualEvents.length == expectedEvents.length &&
      actualFiles is List &&
      expectedFiles is List &&
      actualFiles.length == expectedFiles.length;
}

Finder _runButton(String caseId) => find.byWidgetPredicate(
  (widget) =>
      widget is NativeHtmlButtonWidget && widget.button.label == 'Run $caseId',
  description: 'Native HTML trigger for $caseId',
);

Finder _labelGlyph() => find.byWidgetPredicate(
  (widget) =>
      widget is RichText && widget.text.toPlainText().contains('Choose a file'),
  description: 'HTML label glyph Choose a file',
);

Future<void> _tapFinder(
  WidgetTester tester,
  Finder finder,
  String label,
) async {
  expect(finder, findsOneWidget, reason: '$label is rendered');
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  expect(finder.hitTestable(), findsOneWidget, reason: '$label is hittable');
  await tester.tap(finder);
  await tester.pump();
}

Future<void> _waitForSystemPickerResult(
  WidgetTester tester,
  CapturingFilePickerGateway gateway,
  int expectedResults,
  String caseId,
) async {
  await tester.runAsync(() async {
    for (
      var attempt = 0;
      attempt < 240 && gateway.results.length < expectedResults;
      attempt++
    ) {
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
  });
  expect(
    gateway.results.length,
    greaterThanOrEqualTo(expectedResults),
    reason: '$caseId native file-picker result is pending',
  );
  await tester.pump();
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'native file-picker activation matches Chrome across viewport and theme',
    (tester) async {
      final oracle =
          jsonDecode(documentFilePickerChromeExpectedJson)
              as Map<String, dynamic>;
      expect(oracle['browserVersion'], '155.0.8059.40');
      expect(
        oracle['fixtureSha256'],
        'a000e3871cb27aca865fc9633700a6d74d4d8b4d031e7f8e030c33852a113789',
      );
      expect(
        oracle['runnerSha256'],
        '7a0302b82030eac62aa76f0a048c24b101b714455977bfc27221c05c70656fd7',
      );
      final cases = (oracle['cases'] as List)
          .map((item) => Map<String, dynamic>.from(item as Map))
          .toList(growable: false);
      expect(cases, hasLength(24));

      final theme = await PircTheme.load();
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final origin = 'http://127.0.0.1:${server.port}';
      final token = 'pirc_dev_${List.filled(43, 'A').join()}';
      final receipts = <Json>[];
      final unexpectedRequests = <String>[];
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
              request.response.write(documentFilePickerFixture);
            } else if (request.method == 'GET' &&
                request.uri.path == '/favicon.ico') {
              request.response.statusCode = HttpStatus.noContent;
            } else {
              unexpectedRequests.add('${request.method} ${request.uri.path}');
              request.response.statusCode = HttpStatus.notFound;
              request.response.write('unexpected file-picker fixture request');
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

      final gateway = CapturingFilePickerGateway(
        useSystemPicker: _useSystemPicker,
      );
      try {
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
              if (_useSystemPicker &&
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
                if (_useSystemPicker && caseId != 'connected-click') continue;

                final sourceUrl = '$origin/fixture?case=$caseId';
                final receiptStart = receipts.length;
                final pickerRequestStart = gateway.requests.length;
                final pickerResultStart = gateway.results.length;
                gateway.currentCaseId = caseId;
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
                    sourceDocument,
                    () => sourceDocument?.scripts?.ready == true,
                    '$caseId native script runtime ready',
                  );

                  final startup =
                      caseId == 'startup-click' ||
                      caseId == 'startup-showPicker';
                  final physical =
                      caseId == 'physical-file' ||
                      caseId == 'physical-label-explicit' ||
                      caseId == 'physical-label-implicit';
                  if (!startup) {
                    if (caseId == 'physical-file') {
                      await _tapFinder(
                        tester,
                        find.byType(NativeHtmlFileInputWidget),
                        '$caseId native file input',
                      );
                    } else if (caseId == 'physical-label-explicit' ||
                        caseId == 'physical-label-implicit') {
                      final glyph = _labelGlyph();
                      expect(glyph, findsOneWidget, reason: '$caseId label');
                      await tester.ensureVisible(glyph);
                      await tester.pumpAndSettle();
                      final paragraph = tester.renderObject<RenderParagraph>(
                        glyph,
                      );
                      final labelText = paragraph.text.toPlainText();
                      final offset = labelText.indexOf('Choose a file');
                      expect(
                        offset,
                        isNonNegative,
                        reason: '$caseId label glyph',
                      );
                      final boxes = paragraph.getBoxesForSelection(
                        TextSelection(
                          baseOffset: offset,
                          extentOffset: offset + 1,
                        ),
                      );
                      expect(boxes, isNotEmpty, reason: '$caseId label glyph');
                      final point = paragraph.localToGlobal(
                        boxes.first.toRect().center,
                      );
                      expect(point.dy, inInclusiveRange(0, 844));
                      expect(
                        tester
                            .hitTestOnBinding(point)
                            .path
                            .any((entry) => entry.target is RenderParagraph),
                        isTrue,
                        reason: '$caseId actual label glyph hit target',
                      );
                      await tester.tapAt(point);
                    } else {
                      await _tapFinder(
                        tester,
                        _runButton(caseId),
                        '$caseId trigger',
                      );
                    }
                  }

                  final expectedResult = Map<String, dynamic>.from(
                    expectedCase['result'] as Map,
                  );
                  final expectedPickerCount =
                      expectedCase['pickerRequestCount'] as int;
                  if (_useSystemPicker && expectedPickerCount > 0) {
                    await _waitForSystemPickerResult(
                      tester,
                      gateway,
                      pickerResultStart + expectedPickerCount,
                      caseId,
                    );
                  }
                  await _until(
                    tester,
                    sourceDocument,
                    () => _resultHasExpectedShape(
                      _readJsonElement(sourceDocument, '#result'),
                      expectedResult,
                    ),
                    '$caseId DOM file-picker result',
                  );
                  await tester.pump(const Duration(milliseconds: 100));

                  final actualResult = _readJsonElement(
                    sourceDocument,
                    '#result',
                  )!;
                  expect(
                    actualResult,
                    expectedResult,
                    reason: '$caseId complete Chrome DOM event/file result',
                  );

                  final pickerRequests = gateway.requests
                      .skip(pickerRequestStart)
                      .map((request) => Map<String, dynamic>.from(request))
                      .toList(growable: false);
                  final pickerResults = gateway.results
                      .skip(pickerResultStart)
                      .toList(growable: false);
                  expect(
                    pickerRequests,
                    hasLength(expectedPickerCount),
                    reason: '$caseId exact host picker request count',
                  );
                  expect(
                    pickerResults,
                    hasLength(expectedPickerCount),
                    reason: '$caseId picker response count',
                  );
                  if (expectedPickerCount == 1) {
                    expect(pickerRequests.single['caseId'], caseId);
                    expect(
                      pickerRequests.single['accept'],
                      expectedCase['pickerAccept'],
                      reason: '$caseId picker accept tokens',
                    );
                    expect(
                      pickerRequests.single['multiple'],
                      expectedCase['pickerMultiple'],
                      reason: '$caseId picker multiple flag',
                    );
                  }

                  expect(sourceDocument?.scripts?.diagnostics, isEmpty);
                  final caseReceipts = receipts
                      .skip(receiptStart)
                      .map((receipt) => Map<String, dynamic>.from(receipt))
                      .toList(growable: false);
                  expect(
                    caseReceipts.every(
                      (receipt) => receipt['authorization'] == 'Bearer $token',
                    ),
                    isTrue,
                    reason: '$caseId loopback requests authenticated',
                  );
                  expect(
                    caseReceipts.every(
                      (receipt) =>
                          receipt['path'] == '/api/sessions' ||
                          receipt['path'] == '/fixture' ||
                          receipt['path'] == '/favicon.ico',
                    ),
                    isTrue,
                    reason: '$caseId only expected loopback HTTP requests',
                  );

                  debugPrintSynchronously(
                    'NATIVE_FILE_PICKER ${jsonEncode({'fixtureSha256': oracle['fixtureSha256'], 'systemPicker': _useSystemPicker, 'width': width.toInt(), 'brightness': brightness.name, 'textScale': scale, 'caseId': caseId, 'physicalInteraction': physical, 'eventResult': actualResult, 'pickerRequests': pickerRequests, 'http': caseReceipts, 'diagnostics': sourceDocument?.scripts?.diagnostics})}',
                  );
                  expect(tester.takeException(), isNull, reason: caseId);
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
        expect(unexpectedRequests, isEmpty, reason: 'Unexpected fixture HTTP');
        expect(receipts, isNotEmpty);
        expect(
          receipts.every(
            (receipt) => receipt['authorization'] == 'Bearer $token',
          ),
          isTrue,
          reason: 'Every request uses the synthetic pairing token',
        );
        expect(
          gateway.requests.length,
          _useSystemPicker ? 1 : 17 * 8,
          reason: 'Picker calls equal successful Chrome cases/configurations',
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
