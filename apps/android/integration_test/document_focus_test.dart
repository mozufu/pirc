import 'dart:convert';
import 'dart:io' show GZipCodec;
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show debugPrintSynchronously;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:html/parser.dart' as html;
import 'package:integration_test/integration_test.dart';
import 'package:pirc_mobile/live/document_navigation.dart';
import 'package:pirc_mobile/live/document_navigation_state.dart';
import 'package:pirc_mobile/live/gateway.dart';
import 'package:pirc_render/src/html_document_content.dart';
import 'package:pirc_mobile/theme.dart';

import 'document_focus_fixture.dart';

// Gzip-compressed normalized raw Chrome 155 output. Source JSON:
// ../../packages/pirc_render/test/fixtures/parity/document-focus-chrome155.json
// SHA-256: fd4f722ce9c1f53de81e8333ca0b09d04289e92b41b2ecaccf8265118c6506cf
const _chromeCasesGzipBase64 =
    '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';
const _fixtureSha256 =
    '2a40f988f2e6f9449c0e0d269d33b48efad18d5be01603ba09d4ca49126363e8';
const _runnerSha256 =
    '34db006bf620fc61f5b6f6ad6f102138a523272943e59c9364899e843b7f66f1';

const _excludedCases = <String>{
  'focus-prevent-scroll',
  'dirty-user-edit-script-focus',
};
const _unsupportedObservations = <String>[
  'focus-prevent-scroll is omitted because the native script host does not support window.scrollTo; the root widget test checks preventScroll scrolling separately.',
  'dirty-user-edit-script-focus is omitted from this startup matrix; it requires real text entry and has a separate native test.',
  'External script sources, iframes, and layout or window-scroll observations are not asserted by this inline-source focus matrix.',
];

Map<String, dynamic> _map(Object? value) =>
    Map<String, dynamic>.from(value! as Map);

// Compare every stable authored observation, including shared dispatch identity.
// Timestamp clocks and scroll/layout APIs have separately named scope.
dynamic _normalize(Object? value) {
  if (value is List) return value.map(_normalize).toList();
  if (value is Map) {
    return <String, dynamic>{
      for (final entry in value.entries)
        if (!const {'timeStamp', 'scroll', 'invocation'}.contains(entry.key))
          '${entry.key}': _normalize(entry.value),
    };
  }
  return value;
}

Map<String, dynamic> _normalizedResult(Object? value) =>
    _map(_normalize(value));

List<Map<String, dynamic>> _chromeCases() {
  final compressed = base64Decode(_chromeCasesGzipBase64);
  final decoded = utf8.decode(GZipCodec().decode(compressed));
  return (jsonDecode(decoded) as List)
      .map((item) => _map(item))
      .toList(growable: false);
}

Map<String, dynamic>? _readResult(NativeFetchedDocument document) {
  final source = document.scripts?.content?.text;
  if (source == null) return null;
  final text = html.parse(source).querySelector('#result')?.text.trim();
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
  NativeFetchedDocument document,
  bool Function() condition,
  String label, {
  int maxPumps = 160,
}) async {
  for (var attempt = 0; attempt < maxPumps && !condition(); attempt++) {
    await tester.pump(const Duration(milliseconds: 25));
  }
  expect(
    condition(),
    isTrue,
    reason: '$label: ${document.scripts?.diagnostics}',
  );
  expect(tester.takeException(), isNull, reason: label);
}

String _sourceFor(String caseId) {
  final bootstrap =
      '<script>prepareDocumentFocusCase(${jsonEncode(caseId)});'
      'runDocumentFocusCase(${jsonEncode(caseId)},\'programmatic\');</script>';
  final source = documentFocusFixture.replaceFirst(
    '</body>',
    '$bootstrap</body>',
  );
  if (source == documentFocusFixture) {
    throw StateError('Could not append startup focus case $caseId.');
  }
  return source;
}

NativeFetchedDocument _newDocument(int id, String caseId, String source) {
  final bytes = Uint8List.fromList(utf8.encode(source));
  return NativeFetchedDocument(
    id: id,
    url: 'https://example.test/document-focus/$caseId/$id',
    status: 200,
    bytes: bytes,
    mimeType: 'text/html',
    headers: const {},
    content: NativeHtmlDocumentContent.fromBytes(
      bytes,
      mimeType: 'text/html',
      charset: 'utf-8',
    ),
  );
}

Map<String, dynamic> _focusManagerSnapshot() {
  final primary = FocusManager.instance.primaryFocus;
  return <String, dynamic>{
    'debugLabel': primary?.debugLabel,
    'hasPrimaryFocus': primary?.hasPrimaryFocus ?? false,
    'hasFocus': primary?.hasFocus ?? false,
    'canRequestFocus': primary?.canRequestFocus ?? false,
  };
}

void _expectFocusManagerState(
  String caseId,
  Map<String, dynamic> result,
  Map<String, dynamic> snapshot,
) {
  final primary = FocusManager.instance.primaryFocus;
  expect(primary, isNotNull, reason: '$caseId Flutter primaryFocus exists');
  expect(
    snapshot['hasPrimaryFocus'],
    isTrue,
    reason: '$caseId Flutter primaryFocus=${jsonEncode(snapshot)}',
  );
  final label = snapshot['debugLabel'] as String?;
  final activeId = _map(result['activeElement'])['id'];
  if (activeId == 'origin') {
    expect(label, 'starting focus', reason: '$caseId Flutter focus node');
  } else if (activeId == 'redirect') {
    expect(label, 'redirect focus', reason: '$caseId Flutter focus node');
  } else if (activeId == 'target') {
    final expected = switch (caseId) {
      'button-focus-blur' => 'Case button',
      'file-focus-blur' => 'HTML file input ',
      'link-href' || 'tabindex-negative' => 'HTML script focus ',
      _ => 'case target',
    };
    if (expected.endsWith(' ')) {
      expect(
        label?.startsWith(expected),
        isTrue,
        reason: '$caseId Flutter focus node=${jsonEncode(snapshot)}',
      );
    } else {
      expect(label, expected, reason: '$caseId Flutter focus node');
    }
  } else {
    expect(activeId, 'body', reason: '$caseId normalized DOM activeElement');
    expect(
      label == 'starting focus' ||
          label == 'redirect focus' ||
          label == 'case target' ||
          label == 'Case button' ||
          (label?.startsWith('HTML file input ') ?? false) ||
          (label?.startsWith('HTML script focus ') ?? false),
      isFalse,
      reason:
          '$caseId blurred DOM still has a control FocusNode: ${jsonEncode(snapshot)}',
    );
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'native programmatic document focus and blur match Chrome across viewport and theme',
    (tester) async {
      final oracleCases = _chromeCases();
      expect(oracleCases, hasLength(27));
      final caseIds = oracleCases
          .map((item) => item['caseId'] as String)
          .toList(growable: false);
      expect(caseIds.toSet().intersection(_excludedCases), isEmpty);
      expect(caseIds.toSet(), hasLength(27));
      expect(
        _fixtureSha256,
        '2a40f988f2e6f9449c0e0d269d33b48efad18d5be01603ba09d4ca49126363e8',
      );
      expect(
        _runnerSha256,
        '34db006bf620fc61f5b6f6ad6f102138a523272943e59c9364899e843b7f66f1',
      );
      debugPrintSynchronously(
        'DOCUMENT_FOCUS_UNSUPPORTED ${jsonEncode(_unsupportedObservations)}',
      );

      final theme = await PircTheme.load();
      var documentId = 0;

      for (final width in [390.0, 860.0]) {
        for (final brightness in [Brightness.light, Brightness.dark]) {
          for (final scale in [1.0, 2.0]) {
            tester.view.devicePixelRatio = 1;
            tester.view.physicalSize = Size(width, 844);
            tester.view.viewInsets = const FakeViewPadding();

            for (final expectedCase in oracleCases) {
              final caseId = expectedCase['caseId'] as String;
              final source = _sourceFor(caseId);
              final document = _newDocument(++documentId, caseId, source);
              final actualViewData = MediaQueryData(
                size: Size(width, 844),
                devicePixelRatio: 1,
                textScaler: TextScaler.linear(scale),
                platformBrightness: brightness,
                viewInsets: EdgeInsets.zero,
              );
              try {
                await tester.pumpWidget(
                  MaterialApp(
                    theme: theme.build(brightness),
                    home: MediaQuery(
                      data: actualViewData,
                      child: Scaffold(
                        body: NativeFetchedDocumentView(
                          key: ValueKey('document-focus-$documentId'),
                          document: document,
                          gateway: Gateway(),
                          onLink: (_) {},
                          onSubmit: (_) {},
                        ),
                      ),
                    ),
                  ),
                );
                await _until(
                  tester,
                  document,
                  () => document.scripts?.ready == true,
                  '$caseId native script runtime ready',
                );
                await _until(
                  tester,
                  document,
                  () => _readResult(document)?['status'] == 'DONE',
                  '$caseId startup focus case completed',
                );
                await tester.pump();

                final actualResult = _readResult(document);
                expect(
                  actualResult,
                  isNotNull,
                  reason: '$caseId result snapshot',
                );
                expect(actualResult!['caseId'], caseId);
                expect(actualResult['invocation'], 'programmatic');
                final expectedResult = _map(expectedCase);
                final actualNormalized = _normalizedResult(actualResult);
                expect(
                  actualNormalized,
                  equals(expectedResult),
                  reason:
                      '$caseId Chrome 155 normalized DOM focus result; '
                      'viewport=$width brightness=${brightness.name} scale=$scale',
                );

                final focusSnapshot = _focusManagerSnapshot();
                _expectFocusManagerState(caseId, actualResult, focusSnapshot);
                final observation = jsonEncode({
                  'caseId': caseId,
                  'width': width,
                  'brightness': brightness.name,
                  'textScale': scale,
                  'result': actualNormalized,
                  'primaryFocus': focusSnapshot,
                });
                final encoded = base64Encode(
                  GZipCodec().encode(utf8.encode(observation)),
                );
                const chunkSize = 2000;
                final total = (encoded.length + chunkSize - 1) ~/ chunkSize;
                for (var index = 0; index < total; index++) {
                  final stop = (index + 1) * chunkSize < encoded.length
                      ? (index + 1) * chunkSize
                      : encoded.length;
                  debugPrintSynchronously(
                    'DOCUMENT_FOCUS_CHUNK ${jsonEncode({'document': documentId, 'index': index, 'total': total, 'data': encoded.substring(index * chunkSize, stop)})}',
                  );
                }
              } finally {
                final scripts = document.scripts;
                await tester.pumpWidget(const SizedBox.shrink());
                document.dispose();
                final closed = scripts?.closed;
                if (closed != null) await closed;
              }
            }
          }
        }
      }
      tester.view.reset();
    },
    timeout: const Timeout(Duration(minutes: 20)),
  );
}
